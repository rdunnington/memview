const std = @import("std");
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const zm = @import("zmath");
const wgpu = zgpu.wgpu;

const client = @import("client.zig");
const common = @import("common.zig");

extern fn glfwSetWindowUserPointer(window: *zglfw.Window, ptr: *anyopaque) callconv(.C) void;
extern fn glfwGetWindowUserPointer(window: *zglfw.Window) callconv(.C) *anyopaque;

const ClientContext = client.ClientContext;

const GfxState = struct {
    gctx: *zgpu.GraphicsContext,
    allocator: std.mem.Allocator,

    fn init(window: *zglfw.Window, allocator: std.mem.Allocator) !GfxState {
        const gctx = try zgpu.GraphicsContext.create(allocator, window);

        return GfxState{
            .gctx = gctx,

            .allocator = allocator,
        };
    }

    fn deinit(self: *GfxState) void {
        self.gctx.destroy(self.allocator);
    }
};

const AppContext = struct {
    allocator: std.mem.Allocator,
    gfx: GfxState,
    client: ClientContext,
    all_messages: std.ArrayList(common.Message),
    new_messages: std.ArrayList(common.Message),
    zoom: f32 = -3.0,
    target_zoom: f32 = -3.0,

    fn init(window: *zglfw.Window, allocator: std.mem.Allocator) !*AppContext {
        var app = try allocator.create(AppContext);
        app.gfx = try GfxState.init(window, allocator);
        app.client = try ClientContext.init(allocator);
        app.all_messages = std.ArrayList(common.Message).init(allocator);
        app.new_messages = std.ArrayList(common.Message).init(allocator);
        app.zoom = -3.0;
        app.target_zoom = 3.0;

        zgui.init(allocator);
        zgui.backend.initWithConfig(
            window,
            app.gfx.gctx.device,
            @enumToInt(zgpu.GraphicsContext.swapchain_format),
            .{ .texture_filter_mode = .linear, .pipeline_multisample_count = 1 },
        );

        {
            const scale: [2]f32 = window.getContentScale();
            const scale_factor: f32 = std.math.max(scale[0], scale[1]);
            zgui.getStyle().scaleAllSizes(scale_factor);
        }

        try client.spawnThread(&app.client);

        return app;
    }

    fn deinit(self: *AppContext) void {
        self.gfx.deinit();
        zgui.backend.deinit();
        zgui.deinit();
        self.client.deinit();
    }
};

fn updateMessages(app: *AppContext) !void {
    try client.fetchMessages(&app.client, &app.new_messages);
    // temp for debugging
    // if (app.new_messages.items.len > 0) {
    // std.debug.print(">>> main thread got {} messages:\n", .{app.new_messages.items.len});
    //     for (app.new_messages.items) |msg| {
    //         std.debug.print("\t{any}\n", .{msg});
    //     }
    // }
    // temp for debugging
    try app.all_messages.appendSlice(app.new_messages.items);
    app.new_messages.clearRetainingCapacity();
}

fn updateGui(app: *AppContext) void {
    var gctx: *zgpu.GraphicsContext = app.gfx.gctx;

    const backbuffer_width = @intToFloat(f32, gctx.swapchain_descriptor.width);
    const backbuffer_height = @intToFloat(f32, gctx.swapchain_descriptor.height);

    zgui.setNextWindowPos(.{ .x = 0.0, .y = 0.0, .cond = .always });
    zgui.setNextWindowSize(.{ .w = backbuffer_width, .h = -1.0, .cond = .always });

    const title_bar_flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
    };

    var next_window_y: f32 = 0;
    if (zgui.begin("menu_bar", .{ .flags = title_bar_flags })) {
        zgui.textUnformattedColored(.{ 0, 0.8, 0, 1 }, "Average :");
        zgui.sameLine(.{});
        zgui.text(
            "{d:.3} ms/frame ({d:.1} fps)",
            .{ gctx.stats.average_cpu_time, gctx.stats.fps },
        );
        next_window_y = zgui.getWindowHeight();
        zgui.end();
    }

    zgui.setNextWindowPos(.{ .x = 0.0, .y = next_window_y, .cond = .always });
    zgui.setNextWindowSize(.{ .w = backbuffer_width, .h = 200, .cond = .once });
    zgui.setNextWindowSizeConstraints(.{ .minx = backbuffer_width, .maxx = backbuffer_width, .miny = 0, .maxy = backbuffer_height - next_window_y });

    const call_tree_flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = false,
        .no_move = true,
    };

    if (zgui.begin("call_tree", .{ .flags = call_tree_flags })) {
        zgui.textUnformatted("Call tree goes here");
        if (zgui.treeNodeStrId("tree_id1", "My Tree {d}", .{1})) {
            if (zgui.treeNodeStrId("tree_id2", "My Tree {d}", .{2})) {
                zgui.textUnformatted("Some content...");
                zgui.treePop();
            }
            zgui.treePop();
        }
        next_window_y += zgui.getWindowHeight();
        zgui.end();
    }

    const draw_list = zgui.getBackgroundDrawList();
    draw_list.pushClipRect(.{ .pmin = .{ 0, next_window_y }, .pmax = .{ backbuffer_width, backbuffer_height } });

    // draw_list.addRectFilled(
    //     .{
    //         .pmin = .{ 0, next_window_y },
    //         .pmax = .{ backbuffer_width, backbuffer_height },
    //         .col = zgui.colorConvertFloat3ToU32([_]f32{ 0.5, 0.5, 0 }),
    //         .rounding = 0,
    //     },
    // );
    draw_list.addText(.{ 130, next_window_y + 20 }, 0xff_00_00_ff, "heyooooo {}", .{7});
    draw_list.addTextUnformatted(.{ 130, next_window_y + 40 }, 0xff_00_00_ff, "heyooooo 2");

    draw_list.popClipRect();
}

fn draw(app: *AppContext) void {
    var gctx: *zgpu.GraphicsContext = app.gfx.gctx;

    const back_buffer_view = gctx.swapchain.getCurrentTextureView();
    defer back_buffer_view.release();

    const commands = commands: {
        const encoder = gctx.device.createCommandEncoder(null);
        defer encoder.release();

        // zgui pass
        {
            const pass = zgpu.beginRenderPassSimple(encoder, .load, back_buffer_view, null, null, null);
            defer zgpu.endReleasePass(pass);
            zgui.backend.draw(pass);
        }

        break :commands encoder.finish(null);
    };
    defer commands.release();

    gctx.submit(&.{commands});
    _ = gctx.present();
}

fn onScrolled(window: *zglfw.Window, xoffset: f64, yoffset: f64) callconv(.C) void {
    _ = xoffset;

    const app = @ptrCast(*AppContext, @alignCast(@alignOf(AppContext), glfwGetWindowUserPointer(window)));
    app.target_zoom = std.math.clamp(app.target_zoom + @floatCast(f32, yoffset), -20.0, -1.0);
}

pub fn main() !void {
    zglfw.init() catch {
        std.log.err("Failed to initialize GLFW library.", .{});
        return;
    };
    defer zglfw.terminate();

    const window = zglfw.Window.create(1280, 720, "memview", null) catch {
        std.log.err("Failed to create demo window.", .{});
        return;
    };
    defer window.destroy();
    window.setSizeLimits(400, 400, -1, -1);
    window.setScrollCallback(onScrolled);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var app = try AppContext.init(window, allocator);
    defer allocator.destroy(app);
    defer app.deinit();

    glfwSetWindowUserPointer(window, app);

    while (!window.shouldClose() and window.getKey(.escape) != .press) {
        zglfw.pollEvents();
        zgui.backend.newFrame(
            app.gfx.gctx.swapchain_descriptor.width,
            app.gfx.gctx.swapchain_descriptor.height,
        );

        var zoom_diff = app.target_zoom - app.zoom;
        if (zm.abs(zoom_diff) < 0.01) {
            app.zoom = app.target_zoom;
        } else {
            app.zoom += 0.25 * zoom_diff;
        }

        try updateMessages(app);
        updateGui(app);
        draw(app);
    }

    client.joinThread(&app.client);
}
