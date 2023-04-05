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
    mouse_pos_x: f64 = 0.0,
    mouse_pos_y: f64 = 0.0,
    mouse_delta_x: f64 = 0.0,
    mouse_delta_y: f64 = 0.0,
    scroll_delta_x: f64 = 0.0,
    scroll_delta_y: f64 = 0.0,
    is_dragging_viewport: bool = false,
    is_dragging_cursor: bool = false,

    timeline_zoom: f32 = 1.0,
    timeline_zoom_target: f32 = 1.0,

    mem_zoom: f32 = 1.0,
    mem_zoom_target: f32 = 1.0,

    cursor_timestamp: u64 = 0,
    viewport_timestamp: u64 = 0,

    cursors: struct {
        arrow: *zglfw.Cursor = undefined,
        hand: *zglfw.Cursor = undefined,
    },

    fn tweenZoom(zoom: f32, zoom_target: f32) f32 {
        var zoom_diff: f32 = zoom_target - zoom;
        if (zm.abs(zoom_diff) < 0.01) {
            return zoom_target;
        } else {
            return zoom + (0.5 * zoom_diff);
        }
    }
};

const MemoryStats = struct {
    const MemBlock = struct {
        address: usize,
        size: usize,

        fn lessThan(_: void, lhs: MemBlock, rhs: MemBlock) bool {
            return lhs.address < rhs.address;
        }
    };

    const Cache = struct {
        timestamp: u64 = 0,
        lowest_address: u64 = 0,
        highest_address: u64 = 0,
        selected_block: ?*const MemBlock = null,
        blocks: std.ArrayList(MemBlock),
    };

    first_timestamp: u64 = std.math.maxInt(u64),
    last_timestamp: u64 = 0,

    all_messages: std.ArrayList(common.Message),
    new_messages: std.ArrayList(common.Message),

    cache: Cache,

    fn init(allocator: std.mem.Allocator) MemoryStats {
        return MemoryStats{ .all_messages = std.ArrayList(common.Message).init(allocator), .new_messages = std.ArrayList(common.Message).init(allocator), .cache = Cache{
            .blocks = std.ArrayList(MemBlock).init(allocator),
        } };
    }

    fn deinit(self: *MemoryStats) void {
        self.all_messages.deinit();
        self.new_messages.deinit();
        self.cache.blocks.deinit();
    }

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

    fn updateCache(self: *MemoryStats, timestamp: u64) !void {
        if (self.cache.timestamp == timestamp) {
            return;
        }

        self.cache.timestamp = timestamp;

        const num_old = self.cache.blocks.items.len;

        self.cache.blocks.clearRetainingCapacity();
        self.cache.selected_block = null;

        self.cache.lowest_address = std.math.maxInt(u64);
        self.cache.highest_address = 0;

        for (self.all_messages.items) |msg| {
            switch (msg) {
                .Alloc => |v| {
                    if (v.timestamp <= timestamp) {
                        try self.cache.blocks.append(MemBlock{
                            .address = v.address,
                            .size = v.size,
                        });
                    }

                    self.cache.lowest_address = std.math.min(self.cache.lowest_address, v.address);
                    self.cache.highest_address = std.math.max(self.cache.lowest_address, v.address);
                },
                .Free => |v| {
                    if (v.timestamp <= timestamp) {
                        for (self.cache.blocks.items, 0..) |block, i| {
                            if (block.address == v.address) {
                                _ = self.cache.blocks.swapRemove(i);
                                break;
                            }
                        }
                    }
                },
                else => {},
            }
        }

        std.sort.sort(MemBlock, self.cache.blocks.items, {}, MemBlock.lessThan);

        std.debug.print("cache blocks: {} -> {}\n", .{ num_old, self.cache.blocks.items.len });
    }
};

const AppContext = struct {
    allocator: std.mem.Allocator,
    window: *zglfw.Window,
    gfx: GfxState,
    client: ClientContext,

    mem_stats: MemoryStats,
    gui: GuiState,

    fn init(window: *zglfw.Window, allocator: std.mem.Allocator) !*AppContext {
        var app = try allocator.create(AppContext);
        app.gfx = try GfxState.init(window, allocator);
        app.window = window;
        app.client = try ClientContext.init(allocator);
        app.mem_stats = MemoryStats.init(allocator);
        app.gui = GuiState{ .cursors = .{} };

        app.gui.cursors.arrow = try zglfw.Cursor.createStandard(.arrow);
        app.gui.cursors.hand = try zglfw.Cursor.createStandard(.hand);

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
        self.mem_stats.deinit();
    }
};

fn updateMessages(app: *AppContext) !void {
    try client.fetchMessages(&app.client, &app.mem_stats.new_messages);
    for (app.mem_stats.new_messages.items) |msg| {
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
    try app.mem_stats.all_messages.appendSlice(app.mem_stats.new_messages.items);
    app.mem_stats.new_messages.clearRetainingCapacity();
}

fn updateGui(app: *AppContext) !void {
    const Helpers = struct {
        fn usToS(timestamp: u64) f64 {
            return @intToFloat(f64, timestamp) / @intToFloat(f64, std.time.us_per_s);
        }
        fn sToUs(timestamp: f64) u64 {
            return @floatToInt(u64, timestamp * @intToFloat(f64, std.time.us_per_s));
        }
    };

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
        if (app.mem_stats.cache.selected_block) |block| {
            zgui.text("selected_block at 0x{X} with size {} bytes", .{ block.address, block.size });
        }
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
    var next_cursor: *zglfw.Cursor = gui.cursors.arrow;

    {
        const COLOR_SECTION_BORDER = 0xFF707070;

        const COLOR_CURSOR_DEFAULT = 0xFF0000A0;
        const COLOR_CURSOR_HOVER = 0xFF0000FF;
        const COLOR_CURSOR_DRAGGED = 0xFF0000FF;

        const COLOR_TIMELINE_VIEWPORT_DEFAULT = 0xFFFCFF4F;
        const COLOR_TIMELINE_VIEWPORT_HOVER = 0xFFFCFF4F;
        const COLOR_TIMELINE_VIEWPORT_DRAGGED = 0xFFFCFF4F;
        const COLOR_TIMELINE_TEXT = 0xFFD0D0D0;

        const timeline_width = backbuffer_width;
        const timeline_height = 22.0;
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

        // timeline top and bottom border
        draw_list.addLine(.{
            .p1 = .{ 0, timeline_y_min },
            .p2 = .{ timeline_width, timeline_y_min },
            .col = COLOR_SECTION_BORDER,
            .thickness = 1,
        });

        draw_list.addLine(.{
            .p1 = .{ 0, timeline_y_max },
            .p2 = .{ timeline_width, timeline_y_max },
            .col = COLOR_SECTION_BORDER,
            .thickness = 1,
        });

        const timeline_duration: f64 = app.mem_stats.timespanSecs();
        if (timeline_duration > 0.0) {
            // const timeline_duration_us = @intToFloat(f64, app.mem_stats.timespanUs());

            // timeline ticks and labels
            const num_timeline_ticks: usize = 10;
            for (0..num_timeline_ticks + 1) |i| {
                const ratio = @intToFloat(f32, i) / @intToFloat(f32, num_timeline_ticks);
                var x_offset: f32 = 0;
                if (i == num_timeline_ticks) {
                    x_offset = 1;
                }
                const tick_x = ratio * timeline_width - x_offset;
                const secs = ratio * timeline_duration;
                draw_list.addLine(.{ .p1 = .{ tick_x, timeline_y_min }, .p2 = .{ tick_x, timeline_y_max }, .col = COLOR_SECTION_BORDER, .thickness = 1 });

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

                draw_list.addTextUnformatted(.{ text_x, timeline_y_min + 4 }, 0xFFD0D0D0, text);
            }

            const timeline_timestamp_begin_s = Helpers.usToS(app.mem_stats.first_timestamp);
            const timeline_timestamp_end_s = Helpers.usToS(app.mem_stats.last_timestamp);

            // viewport
            gui.viewport_timestamp = std.math.clamp(gui.viewport_timestamp, app.mem_stats.first_timestamp, app.mem_stats.last_timestamp);
            gui.is_dragging_viewport = false;

            var viewport_duration: f64 = timeline_duration / gui.timeline_zoom;
            var timeline_viewport_color: u32 = COLOR_TIMELINE_VIEWPORT_DEFAULT;

            var zooming_focal_timestamp_s: ?f64 = null;
            if (gui.mouse_pos_y >= timeline_y_min and gui.mouse_pos_y <= timeline_y_max and gui.is_dragging_cursor == false) {
                // const viewport_duration_us: u64 = @floatToInt(u64, viewport_duration * @intToFloat(f64, std.time.us_per_s));
                // const viewport_width: f64 = (viewport_duration / timeline_duration) * timeline_width;
                const viewport_timestamp_begin_s = Helpers.usToS(gui.viewport_timestamp);
                // const viewport_x_min = ((timeline_timestamp_end_s - viewport_timestamp_begin_s) / timeline_duration) * timeline_width;
                // const viewport_x_max = viewport_x_min + (viewport_duration / timeline_duration) * timeline_width;

                if (gui.scroll_delta_y != 0) {
                    // if (gui.mouse_pos_x >= viewport_x_min and gui.mouse_pos_x <= viewport_x_max) {
                    //     const focal_location_normalized = @intToFloat(f32, gui.mouse_pos_x) / timeline_width;
                    //     zooming_focal_timestamp_s = timeline_timestamp_begin_s + focal_location_normalized * timeline_duration;
                    // } else {
                        // if the mouse is not inside the current viewport, just make the focal point the middle to make the zoom even on both sides
                        zooming_focal_timestamp_s = viewport_timestamp_begin_s + (viewport_duration / 2.0);
                    // }

                    gui.timeline_zoom_target = std.math.max(gui.timeline_zoom_target + @floatCast(f32, gui.scroll_delta_y * 0.25), 1.0);
                }

                timeline_viewport_color = COLOR_TIMELINE_VIEWPORT_HOVER;

                if (app.window.getMouseButton(.left) == .press) {
                    gui.is_dragging_viewport = true;
                    const viewport_timestamp_delta: f64 = viewport_duration * gui.mouse_delta_x * 0.01;
                    const viewport_timestamp_begin_shifted_s = std.math.clamp(viewport_timestamp_begin_s + viewport_timestamp_delta, timeline_timestamp_begin_s, timeline_timestamp_end_s - viewport_duration);
                    const viewport_timestamp_begin = Helpers.sToUs(viewport_timestamp_begin_shifted_s);
                    gui.viewport_timestamp = viewport_timestamp_begin; // std.math.clamp(viewport_timestamp_unclamped, app.mem_stats.first_timestamp, app.mem_stats.last_timestamp - viewport_duration_us);

                    next_cursor = gui.cursors.hand;
                    timeline_viewport_color = COLOR_TIMELINE_VIEWPORT_DRAGGED;
                } else if (app.window.getMouseButton(.right) == .press) {
                    // TODO right click and drag to redefine the viewport
                }
            }

            // animate zoom values and adjust viewport to keep focal point
            {
                // const prev_zoom = app.gui.timeline_zoom;
                gui.timeline_zoom = GuiState.tweenZoom(app.gui.timeline_zoom, app.gui.timeline_zoom_target);

                const prev_viewport_duration = viewport_duration;
                viewport_duration = timeline_duration / gui.timeline_zoom;

                // shift the viewport timestamp to keep the zoom focal point the same
                if (zooming_focal_timestamp_s) |focus_s| {
                    const viewport_timestamp_begin_s = Helpers.usToS(gui.viewport_timestamp);
                    const focus_normalized = (focus_s - viewport_timestamp_begin_s) / prev_viewport_duration;
                    const new_offset_to_viewport_begin_s = focus_normalized * viewport_duration;

                    var viewport_new_begin_s = focus_s - new_offset_to_viewport_begin_s;
                    viewport_new_begin_s = std.math.max(viewport_new_begin_s, timeline_timestamp_begin_s);
                    viewport_new_begin_s = std.math.min(viewport_new_begin_s, timeline_timestamp_end_s - viewport_duration);


                    // const viewport_timestamp_begin_s = Helpers.usToS(gui.viewport_timestamp);
                    // const zoom_diff = gui.timeline_zoom - prev_zoom;
                    // const viewport_timestamp_offset_s = (focus_s - viewport_timestamp_begin_s) * zoom_diff;

                    // var new_viewport_timestamp_begin_s = viewport_timestamp_begin_s + viewport_timestamp_offset_s;
                    // const max_viewport_timestamp_s = timeline_timestamp_end_s - viewport_duration;
                    // if (max_viewport_timestamp_s > timeline_timestamp_begin_s) {
                    //     new_viewport_timestamp_begin_s = std.math.clamp(new_viewport_timestamp_begin_s, timeline_timestamp_begin_s, max_viewport_timestamp_s);
                    // }
                    gui.viewport_timestamp = Helpers.sToUs(viewport_new_begin_s);
                }
            }

            // const viewport_duration: f64 = timeline_duration / gui.timeline_zoom;
            const viewport_duration_us: u64 = Helpers.sToUs(viewport_duration);
            const viewport_timestamp_clamped = std.math.clamp(gui.viewport_timestamp, app.mem_stats.first_timestamp, app.mem_stats.last_timestamp - viewport_duration_us);
            const viewport_timestamp_begin_s = Helpers.usToS(viewport_timestamp_clamped);
            const viewport_timestamp_end_s = Helpers.usToS(viewport_timestamp_clamped) + viewport_duration;

            // draw viewport in the global timeline
            {
                const viewport_x_normalized = (viewport_timestamp_begin_s - timeline_timestamp_begin_s) / timeline_duration;
                const viewport_x: f64 = viewport_x_normalized * timeline_width;
                const viewport_width: f64 = (viewport_duration / timeline_duration) * timeline_width;
                const thickness: f32 = if (gui.is_dragging_viewport) 2 else 1;

                draw_list.addRect(
                    .{
                        .pmin = .{ @floatCast(f32, viewport_x), timeline_y_min },
                        .pmax = .{ @floatCast(f32, viewport_x + viewport_width), timeline_y_max },
                        .col = timeline_viewport_color,
                        .thickness = thickness,
                    },
                );
            }

            const cursor_timestamp_clamped_us: u64 = std.math.clamp(gui.cursor_timestamp, app.mem_stats.first_timestamp, app.mem_stats.last_timestamp);
            var cursor_timestamp_s: f64 = Helpers.usToS(cursor_timestamp_clamped_us);

            // viewport timeline and cursor
            const viewport_timeline_height = 40.0;
            const viewport_timeline_y_min = timeline_y_max + 1;
            const viewport_timeline_y_max = viewport_timeline_y_min + viewport_timeline_height;

            {
                draw_list.addRectFilled(
                    .{
                        .pmin = .{ 0, viewport_timeline_y_min },
                        .pmax = .{ timeline_width, viewport_timeline_y_max },
                        .col = zgui.colorConvertFloat3ToU32([_]f32{ 0.08, 0.08, 0.08 }),
                        .rounding = 0,
                    },
                );

                draw_list.addLine(.{
                    .p1 = .{ 0, viewport_timeline_y_max },
                    .p2 = .{ timeline_width, viewport_timeline_y_max },
                    .col = COLOR_SECTION_BORDER,
                    .thickness = 1,
                });

                {
                    var cursor_x: f32 = @floatCast(f32, 1.0 - ((viewport_timestamp_end_s - cursor_timestamp_s) / viewport_duration)) * timeline_width;

                    const is_mouse_hovering_cursor = gui.mouse_pos_y >= viewport_timeline_y_min and
                        gui.mouse_pos_y <= viewport_timeline_y_max and
                        gui.mouse_pos_x >= (cursor_x - 15.0) and
                        gui.mouse_pos_x <= (cursor_x + 15.0);
                    const can_drag_cursor: bool = (is_mouse_hovering_cursor or gui.is_dragging_cursor) and gui.is_dragging_viewport == false;
                    if (can_drag_cursor and app.window.getMouseButton(.left) == .press) {
                        gui.is_dragging_cursor = true;
                        next_cursor = gui.cursors.hand;

                        cursor_timestamp_s = viewport_timestamp_begin_s + (gui.mouse_pos_x / timeline_width) * viewport_duration;
                    } else {
                        gui.is_dragging_cursor = false;
                    }

                    // clamp the cursor position to the viewport. ensures if the viewport is moved or the cursor is dragged outside that it stays within bounds
                    cursor_timestamp_s = std.math.clamp(cursor_timestamp_s, viewport_timestamp_begin_s, viewport_timestamp_end_s);
                    gui.cursor_timestamp = Helpers.sToUs(cursor_timestamp_s);
                    cursor_x = @floatCast(f32, 1.0 - ((viewport_timestamp_end_s - cursor_timestamp_s) / viewport_duration)) * timeline_width;

                    try app.mem_stats.updateCache(gui.cursor_timestamp);

                    const cursor_color: u32 = blk: {
                        if (gui.is_dragging_cursor) {
                            break :blk COLOR_CURSOR_DRAGGED;
                        }
                        if (can_drag_cursor) {
                            break :blk COLOR_CURSOR_HOVER;
                        }

                        break :blk COLOR_CURSOR_DEFAULT;
                    };

                    const thickness: f32 = if (gui.is_dragging_cursor) 2 else 1;

                    // draw the cursor on the viewport timeline
                    draw_list.addLine(.{
                        .p1 = .{ cursor_x, viewport_timeline_y_min },
                        .p2 = .{ cursor_x, viewport_timeline_y_max },
                        .col = cursor_color, // ABGR
                        .thickness = thickness,
                    });

                    // draw the cursor on the global timeline
                    const cursor_x_timeline = @floatCast(f32, 1.0 - ((timeline_timestamp_end_s - cursor_timestamp_s) / timeline_duration)) * timeline_width;
                    draw_list.addLine(.{
                        .p1 = .{ cursor_x_timeline, timeline_y_min },
                        .p2 = .{ cursor_x_timeline, timeline_y_max },
                        .col = COLOR_CURSOR_DEFAULT, // ABGR
                        .thickness = 1,
                    });

                    // draw the timestamp on the text
                    var text_buffer: [32]u8 = undefined;
                    var text = std.fmt.bufPrint(&text_buffer, "{d:.2}ms", .{(cursor_timestamp_s - timeline_timestamp_begin_s) * 1000.0}) catch unreachable;
                    const text_size_cursor: [2]f32 = zgui.calcTextSize(text, .{});
                    const text_cursor_x = if (cursor_x + 4 + text_size_cursor[0] <= timeline_width) (cursor_x + 4) else (cursor_x - 2 - text_size_cursor[0]);
                    const text_y = viewport_timeline_y_max - 4 - text_size_cursor[1];
                    draw_list.addTextUnformatted(.{ text_cursor_x, text_y }, cursor_color, text);

                    // draw begin/end timestamps
                    text = std.fmt.bufPrint(&text_buffer, "{d:.2}ms", .{(viewport_timestamp_begin_s - timeline_timestamp_begin_s) * 1000.0}) catch unreachable;
                    const text_size_begin_timestamp: [2]f32 = zgui.calcTextSize(text, .{});
                    const text_begin_x = 4;
                    if (text_begin_x + text_size_begin_timestamp[0] < text_cursor_x - 5) {
                        draw_list.addTextUnformatted(.{ text_begin_x, text_y }, COLOR_TIMELINE_TEXT, text);
                    }

                    text = std.fmt.bufPrint(&text_buffer, "{d:.2}ms", .{(viewport_timestamp_end_s - timeline_timestamp_begin_s) * 1000.0}) catch unreachable;
                    const text_size_end_timestamp: [2]f32 = zgui.calcTextSize(text, .{});
                    const text_end_x = timeline_width - text_size_end_timestamp[0] - 4;
                    if (text_end_x > text_cursor_x + text_size_cursor[0] + 4) {
                        draw_list.addTextUnformatted(.{ text_end_x, text_y }, COLOR_TIMELINE_TEXT, text);
                    }
                }

                // TODO draw bookmarks on higher y-level

            }

            // zoomable view of memory state at cursor
            {
                const mem_viewport_y_min = viewport_timeline_y_max + 1;
                const mem_viewport_y_max = backbuffer_height;

                const mem_viewport_zoom_bar_y_min = mem_viewport_y_min;
                const mem_viewport_zoom_bar_y_max = mem_viewport_zoom_bar_y_min + 6;

                const is_mouse_in_mem_viewport = gui.mouse_pos_y >= mem_viewport_y_min and gui.mouse_pos_y <= mem_viewport_y_max;
                if (is_mouse_in_mem_viewport and gui.scroll_delta_y != 0) {
                    app.gui.mem_zoom_target = std.math.max(app.gui.mem_zoom_target + @floatCast(f32, gui.scroll_delta_y * 0.25), 1.0);
                }

                if (is_mouse_in_mem_viewport and app.window.getMouseButton(.left) == .press) {
                    app.mem_stats.cache.selected_block = null;
                }

                gui.mem_zoom = GuiState.tweenZoom(gui.mem_zoom, gui.mem_zoom_target);

                // render memory view zoom
                {
                    draw_list.addRectFilled(.{
                        .pmin = .{ 0, mem_viewport_zoom_bar_y_min },
                        .pmax = .{ backbuffer_width, mem_viewport_zoom_bar_y_max },
                        .col = COLOR_SECTION_BORDER,
                    });

                    const mem_zoom_bar_x_min = 0;
                    const mem_zoom_bar_x_max = backbuffer_width / @floatCast(f32, gui.mem_zoom);

                    draw_list.addRectFilled(.{
                        .pmin = .{ mem_zoom_bar_x_min, mem_viewport_zoom_bar_y_min + 1 },
                        .pmax = .{ mem_zoom_bar_x_max, mem_viewport_zoom_bar_y_max },
                        .col = 0xFFFF1CAB,
                    });
                }

                const mem_viewport_address_ticks_y_min = mem_viewport_zoom_bar_y_max;
                const mem_viewport_address_ticks_y_max = mem_viewport_address_ticks_y_min + 16;

                const mem_viewport_blocks_y_min = mem_viewport_address_ticks_y_max + 1;
                const mem_viewport_blocks_y_max = backbuffer_height;

                const cache: *MemoryStats.Cache = &app.mem_stats.cache;

                if (cache.blocks.items.len > 0) {
                    const kb = 1024;
                    const kb64 = kb * 64;

                    const first_address = cache.lowest_address - (cache.lowest_address % kb64);
                    const last_address = cache.highest_address + (cache.highest_address % kb64);
                    const address_space = @intToFloat(f64, last_address - first_address);

                    // draw address space labels and ticks
                    {
                        const num_64k_pages = @floatToInt(u64, @ceil(address_space / kb64));

                        draw_list.addLine(.{
                            .p1 = .{ 0, mem_viewport_address_ticks_y_max },
                            .p2 = .{ timeline_width, mem_viewport_address_ticks_y_max },
                            .col = COLOR_SECTION_BORDER,
                            .thickness = 1,
                        });

                        for (0..num_64k_pages) |i| {
                            const tick_x = (@intToFloat(f32, i) / @intToFloat(f32, num_64k_pages)) * timeline_width;
                            draw_list.addLine(.{
                                .p1 = .{ tick_x, mem_viewport_address_ticks_y_min },
                                .p2 = .{ tick_x, mem_viewport_address_ticks_y_max },
                                .col = COLOR_SECTION_BORDER,
                                .thickness = 1,
                            });
                        }
                    }

                    for (cache.blocks.items) |*block| {
                        const block_start_address = block.address;
                        const block_end_address = block.address + block.size;

                        const start_address_offset = block_start_address - first_address;
                        const end_address_offset = block_end_address - first_address;

                        const block_x_start = (@intToFloat(f64, start_address_offset) / address_space) * timeline_width;
                        const block_x_end = (@intToFloat(f64, end_address_offset) / address_space) * timeline_width;

                        if (is_mouse_in_mem_viewport and app.window.getMouseButton(.left) == .press and gui.mouse_pos_x >= block_x_start and gui.mouse_pos_x <= block_x_end) {
                            cache.selected_block = block;
                        }

                        draw_list.addRectFilled(
                            .{
                                .pmin = .{ @floatCast(f32, block_x_start), mem_viewport_blocks_y_min },
                                .pmax = .{ @floatCast(f32, block_x_end), mem_viewport_blocks_y_max },
                                .col = 0xFF56B759,
                            },
                        );

                        if (cache.selected_block == block) {
                            draw_list.addRect(
                                .{
                                    .pmin = .{ @floatCast(f32, block_x_start), mem_viewport_blocks_y_min },
                                    .pmax = .{ @floatCast(f32, block_x_end), mem_viewport_blocks_y_max },
                                    .col = 0xFFFFFFFF,
                                },
                            );
                        }
                    }
                }
            }
        }
    }

    app.window.setCursor(next_cursor);

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
        try updateGui(app);
        draw(app);
    }

    client.joinThread(&app.client);
}
