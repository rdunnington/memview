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

const GuiState = struct {
    cursor_timestamp: u64 = 0,

    timeline_zoom: f32 = 1.0,
    timeline_zoom_target: f32 = 1.0,

    mouse_pos_x: f64 = 0.0,
    mouse_pos_y: f64 = 0.0,
    mouse_delta_x: f64 = 0.0,
    mouse_delta_y: f64 = 0.0,
    scroll_delta_x: f64 = 0.0,
    scroll_delta_y: f64 = 0.0,

    viewport_timestamp: u64 = 0,
};

const MemoryStats = struct {
    first_timestamp: u64 = std.math.maxInt(u64),
    last_timestamp: u64 = 0,

    fn timespanUs(self: *MemoryStats) u64 {
        if (self.first_timestamp < self.last_timestamp) {
            return self.last_timestamp - self.first_timestamp;
        }
        return 0;
    }

    fn timespanSecs(self: *MemoryStats) f64 {
        if (self.first_timestamp < self.last_timestamp) {
            const duration_us = self.last_timestamp - self.first_timestamp;
            const duration_s = @intToFloat(f64, duration_us) / @intToFloat(f64, std.time.us_per_s);
            return @floatCast(f32, duration_s);
        }
        return 0;
    }
};

const AppContext = struct {
    allocator: std.mem.Allocator,
    window: *zglfw.Window,
    gfx: GfxState,
    client: ClientContext,
    all_messages: std.ArrayList(common.Message),
    new_messages: std.ArrayList(common.Message),
    mem_stats: MemoryStats,
    gui: GuiState,

    fn init(window: *zglfw.Window, allocator: std.mem.Allocator) !*AppContext {
        var app = try allocator.create(AppContext);
        app.gfx = try GfxState.init(window, allocator);
        app.window = window;
        app.client = try ClientContext.init(allocator);
        app.all_messages = std.ArrayList(common.Message).init(allocator);
        app.new_messages = std.ArrayList(common.Message).init(allocator);
        app.mem_stats = MemoryStats{};
        app.gui = GuiState{};

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
        self.all_messages.deinit();
        self.new_messages.deinit();
    }
};

fn updateMessages(app: *AppContext) !void {
    try client.fetchMessages(&app.client, &app.new_messages);
    for (app.new_messages.items) |msg| {
        const timestamp = switch (msg) {
            .Frame => |v| v.timestamp,
            .Alloc => |v| v.timestamp,
            .Free => |v| v.timestamp,
            else => null,
        };
        // std.debug.print("ts: {}\n", .{ts});
        if (timestamp) |ts| {
            app.mem_stats.first_timestamp = std.math.min(app.mem_stats.first_timestamp, ts);
            app.mem_stats.last_timestamp = std.math.max(app.mem_stats.last_timestamp, ts);
        }
    }
    // temp for debugging
    // if (app.new_messages.items.len > 0) {
    //     std.debug.print(">>> main thread got {} messages:\n", .{app.new_messages.items.len});
    //     // for (app.new_messages.items) |msg| {
    //     //     std.debug.print("\t{any}\n", .{msg});
    //     // }
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

    const draw_list: zgui.DrawList = zgui.getBackgroundDrawList();
    draw_list.pushClipRect(.{ .pmin = .{ 0, next_window_y }, .pmax = .{ backbuffer_width, backbuffer_height } });
    defer draw_list.popClipRect();

    const gui: *GuiState = &app.gui;

    // global timeline
    {
        const timeline_width = backbuffer_width;
        const timeline_height = 30.0;
        const timeline_y_min = next_window_y;
        const timeline_y_max = next_window_y + timeline_height;

        draw_list.addRectFilled(
            .{
                .pmin = .{ 0, timeline_y_min },
                .pmax = .{ timeline_width, timeline_y_max },
                .col = zgui.colorConvertFloat3ToU32([_]f32{ 0.08, 0.08, 0.08 }),
                .rounding = 0,
            },
        );

        const timeline_duration = app.mem_stats.timespanSecs();
        if (timeline_duration > 0.0) {
            // const timeline_duration_us = @intToFloat(f64, app.mem_stats.timespanUs());

            // timeline top and bottom border
            draw_list.addLine(.{
                .p1 = .{0, timeline_y_min},
                .p2 = .{timeline_width, timeline_y_min},
                .col = 0xFF707070,
                .thickness = 1,
                });

            draw_list.addLine(.{
                .p1 = .{0, timeline_y_max},
                .p2 = .{timeline_width, timeline_y_max},
                .col = 0xFF707070,
                .thickness = 1,
                });

            // timeline ticks and labels
            const num_timeline_ticks: usize = 10;
            for (0..num_timeline_ticks+1) |i| {
                const ratio = @intToFloat(f32, i) / @intToFloat(f32, num_timeline_ticks);
                var x_offset: f32 = 0;
                if (i == num_timeline_ticks) {
                    x_offset = 1;
                }
                const tick_x = ratio * timeline_width - x_offset;
                const secs = ratio * timeline_duration;
                draw_list.addLine(.{.p1 = .{tick_x, timeline_y_min}, .p2 = .{tick_x, timeline_y_max}, .col = 0xFF707070, .thickness = 1});

                var text_buffer: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&text_buffer, "{d:.2}ms", .{secs * 1000.0}) catch unreachable;

                const text_size: [2]f32 = zgui.calcTextSize(text, .{});
                var text_x = tick_x + 4;
                if (i > 0) {
                    if (i == num_timeline_ticks) {
                        text_x -= text_size[0] + 7;
                    } else {
                        text_x -= text_size[0] / 2.0;
                    }
                }
                
                draw_list.addTextUnformatted(.{text_x, timeline_y_min + 4}, 0xFFD0D0D0, text);
            }

                const timeline_timestamp_begin_s = @intToFloat(f64, app.mem_stats.first_timestamp) / @intToFloat(f64, std.time.us_per_s);
                const timeline_timestamp_end_s = @intToFloat(f64, app.mem_stats.last_timestamp) / @intToFloat(f64, std.time.us_per_s);

            // viewport
            if (gui.mouse_pos_y >= timeline_y_min and gui.mouse_pos_y <= timeline_y_max) {
                const viewport_duration: f64 = timeline_duration / gui.timeline_zoom;
                // const viewport_duration_us: u64 = @floatToInt(u64, viewport_duration * @intToFloat(f64, std.time.us_per_s));
                // const viewport_width: f64 = (viewport_duration / timeline_duration) * timeline_width;
                const viewport_timestamp_begin_s = @intToFloat(f64, gui.viewport_timestamp) / @intToFloat(f64, std.time.us_per_s);
                // const viewport_x_min = ((timeline_timestamp_end_s - viewport_timestamp_begin_s) / timeline_duration) * timeline_width;
                // const viewport_x_max = viewport_x_min + (viewport_duration / timeline_duration) * timeline_width;

                if (gui.scroll_delta_y != 0) {
                    // const mouse_x_in_viewport_normalized = @intToFloat(f32, gui.mouse_pos_x) / timeline_width;
                    // var focal_timestamp_s = undefined;
                    // if (gui.mouse_pos_x >= viewport_x_min and gui.mouse_pos_x <= viewport_x_max) {
                    //     const focal_location_normalized = @intToFloat(f32, gui.mouse_pos_x) / timeline_width;
                    //     const focal_timestamp_s = timeline_timestamp_begin_s + focal_location_normalized * timeline_duration;
                    // } else {
                    //     //middle of current viewport, pull in each side evenly
                    //     const focal_timestamp_s = viewport_timestamp_begin_s + (viewport_duration / 2.0);
                    // }

                    // zoom into the moused-over location
                    // gui.target_zoom += gui.scroll_delta_y * 
                    app.gui.timeline_zoom_target = std.math.max(app.gui.timeline_zoom_target + @floatCast(f32, gui.scroll_delta_y * 0.25), 1.0);
                }

                if (app.window.getMouseButton(.left) == .press) {
                    const viewport_timestamp_delta: f64 = viewport_duration * gui.mouse_delta_x * 0.01;
                    const viewport_timestamp_begin_shifted_s = std.math.clamp(viewport_timestamp_begin_s + viewport_timestamp_delta, timeline_timestamp_begin_s, timeline_timestamp_end_s - viewport_duration);
                    const viewport_timestamp_begin = @floatToInt(u64, viewport_timestamp_begin_shifted_s * @intToFloat(f64, std.time.us_per_s));
                    gui.viewport_timestamp = viewport_timestamp_begin;// std.math.clamp(viewport_timestamp_unclamped, app.mem_stats.first_timestamp, app.mem_stats.last_timestamp - viewport_duration_us);
                }
            }

            var zoom_diff = app.gui.timeline_zoom_target - app.gui.timeline_zoom;
            if (zm.abs(zoom_diff) < 0.01) {
                app.gui.timeline_zoom = app.gui.timeline_zoom_target;
            } else {
                app.gui.timeline_zoom += 0.5 * zoom_diff;
            }

            // const timeline_timestamp_begin = @intToFloat(f64, app.mem_stats.first_timestamp);

            const viewport_timestamp_clamped = std.math.clamp(gui.viewport_timestamp, app.mem_stats.first_timestamp, app.mem_stats.last_timestamp);
            const viewport_timestamp_begin_s = @intToFloat(f64, viewport_timestamp_clamped) / @intToFloat(f64, std.time.us_per_s);
            const viewport_x: f32 = @floatCast(f32, 1.0 - ((timeline_timestamp_end_s - viewport_timestamp_begin_s) / timeline_duration)) * timeline_width;

            const viewport_duration: f64 = timeline_duration / gui.timeline_zoom;
            const viewport_width: f64 = (viewport_duration / timeline_duration) * timeline_width;            

            draw_list.addRect(
                .{
                    .pmin = .{ @floatCast(f32, viewport_x), timeline_y_min },
                    .pmax = .{ @floatCast(f32, viewport_x + viewport_width), timeline_y_max },
                    .col = 0xFFFCFF4F,
                },
            );
        }

        // draw_list.addText(.{ 130, next_window_y + 20 }, 0xff_00_00_ff, "heyooooo {}", .{7});

    }

    // local timeline and cursor
    {
        // const timeline_width = backbuffer_width;
        // const timeline_height = 30.0;
        // const timeline_y_min = next_window_y;
        // const timeline_y_max = next_window_y + timeline_height;
    }

    // zoomable view of memory state at cursor
    {
        //
    }

    app.gui.mouse_delta_x = 0;
    app.gui.mouse_delta_y = 0;
    app.gui.scroll_delta_x = 0;
    app.gui.scroll_delta_y = 0;
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
    const app = @ptrCast(*AppContext, @alignCast(@alignOf(AppContext), glfwGetWindowUserPointer(window)));
    app.gui.scroll_delta_x = xoffset;
    app.gui.scroll_delta_y = yoffset;
}

fn onCursorPos(window: *zglfw.Window, xpos: f64, ypos: f64) callconv(.C) void {
    const app = @ptrCast(*AppContext, @alignCast(@alignOf(AppContext), glfwGetWindowUserPointer(window)));

    app.gui.mouse_delta_x = xpos - app.gui.mouse_pos_x;
    app.gui.mouse_delta_y = ypos - app.gui.mouse_pos_y;

    app.gui.mouse_pos_x = xpos;
    app.gui.mouse_pos_y = ypos;
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
    window.setCursorPosCallback(onCursorPos);

    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 16 }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var app = try AppContext.init(window, allocator);
    defer allocator.destroy(app);
    defer app.deinit();

    glfwSetWindowUserPointer(window, app);

    ///// DEBUG ONLY END
    const RunChildThreadHelper = struct {
        fn ThreadFunc(_allocator: *std.mem.Allocator) !void {
            const argv = [_][]const u8{ "zig-out/bin/test_host_zig.exe", "test/the_blue_castle.txt" };
            var test_process = std.process.Child.init(&argv, _allocator.*);
            try test_process.spawn();
            _ = try test_process.wait();
        }
    };
    _ = try std.Thread.spawn(.{}, RunChildThreadHelper.ThreadFunc, .{&allocator});
    /////

    while (!window.shouldClose() and window.getKey(.escape) != .press) {
        zglfw.pollEvents();
        zgui.backend.newFrame(
            app.gfx.gctx.swapchain_descriptor.width,
            app.gfx.gctx.swapchain_descriptor.height,
        );

        try updateMessages(app);
        updateGui(app);
        draw(app);
    }

    client.joinThread(&app.client);
}
