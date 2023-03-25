const std = @import("std");
const zgui = @import("zgui");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");

const server = @import("server.zig");
const common = @import("common.zig");

const ServerContext = server.ServerContext;

const AppContext = struct {
    allocator: std.mem.Allocator,
    gctx: *zgpu.GraphicsContext,
    server: ServerContext,
    all_messages: std.ArrayList(common.Message),
    new_messages: std.ArrayList(common.Message),
};

fn updateMessages(app: *AppContext) !void {
    try server.fetchMessages(&app.server, &app.new_messages);
    try app.all_messages.appendSlice(app.new_messages.items);
}

fn updateGui(app: *AppContext) void {
    zgui.setNextWindowPos(.{ .x = 0.0, .y = 0.0, .cond = .always });
    zgui.setNextWindowSize(.{ .w = @intToFloat(f32, app.gctx.swapchain_descriptor.width), .h = -1.0, .cond = .always });

    const title_bar_flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = true,
        .no_move = true,
    };

    if (zgui.begin("menu_bar", .{ .flags = title_bar_flags })) {
        zgui.textUnformattedColored(.{ 0, 0.8, 0, 1 }, "Average :");
        zgui.sameLine(.{});
        zgui.text(
            "{d:.3} ms/frame ({d:.1} fps)",
            .{ app.gctx.stats.average_cpu_time, app.gctx.stats.fps },
        );
        zgui.end();
    }
}

fn draw(app: *AppContext) void {
    const swapchain_texv = app.gctx.swapchain.getCurrentTextureView();
    defer swapchain_texv.release();

    const commands = commands: {
        const encoder = app.gctx.device.createCommandEncoder(null);
        defer encoder.release();

        // Gui pass.
        {
            const pass = zgpu.beginRenderPassSimple(encoder, .load, swapchain_texv, null, null, null);
            defer zgpu.endReleasePass(pass);
            zgui.backend.draw(pass);
        }

        break :commands encoder.finish(null);
    };
    defer commands.release();

    app.gctx.submit(&.{commands});
    _ = app.gctx.present();
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

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var app = AppContext{
        .allocator = allocator,
        .gctx = try zgpu.GraphicsContext.create(allocator, window),
        .server = try ServerContext.init(allocator),

        // temp
        .all_messages = std.ArrayList(common.Message).init(allocator),
        .new_messages = std.ArrayList(common.Message).init(allocator),
    };

    defer app.gctx.destroy(allocator);
    defer app.server.deinit();

    zgui.init(allocator);
    defer zgui.deinit();

    zgui.backend.initWithConfig(
        window,
        app.gctx.device,
        @enumToInt(zgpu.GraphicsContext.swapchain_format),
        .{ .texture_filter_mode = .linear, .pipeline_multisample_count = 1 },
    );
    defer zgui.backend.deinit();

    try server.spawnThread(&app.server);

    while (!window.shouldClose() and window.getKey(.escape) != .press) {
        zglfw.pollEvents();
        zgui.backend.newFrame(
            app.gctx.swapchain_descriptor.width,
            app.gctx.swapchain_descriptor.height,
        );

        try updateMessages(&app);
        updateGui(&app);
        draw(&app);
    }

    server.joinThread(&app.server);
}
