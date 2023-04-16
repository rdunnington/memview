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

const ButtonState = struct {
    triggered: bool = false,
    release_triggered: bool = false,
    down: bool = false,
};

const InputState = struct {
    mouse_button: [@typeInfo(zglfw.MouseButton).Enum.fields.len]ButtonState = [1]ButtonState{.{}} ** 8,

    fn isMouseDownTriggered(self: *const InputState, button: zglfw.MouseButton) bool {
        const index = @intCast(usize, @enumToInt(button));
        return self.mouse_button[index].triggered;
    }

    fn isMouseReleaseTriggered(self: *const InputState, button: zglfw.MouseButton) bool {
        const index = @intCast(usize, @enumToInt(button));
        return self.mouse_button[index].release_triggered;
    }

    fn isMouseDown(self: *const InputState, button: zglfw.MouseButton) bool {
        const index = @intCast(usize, @enumToInt(button));
        return self.mouse_button[index].down;
    }
};

const GuiState = struct {
    mouse_pos_x: f64 = 0.0,
    mouse_pos_y: f64 = 0.0,
    mouse_delta_x: f64 = 0.0,
    mouse_delta_y: f64 = 0.0,
    scroll_delta_x: f64 = 0.0,
    scroll_delta_y: f64 = 0.0,

    viewport_drag_focus: ?f64 = null,
    is_dragging_cursor: bool = false,
    is_dragging_mem_view: bool = false,

    timeline_zoom: f32 = 1.0,
    timeline_zoom_target: f32 = 1.0,

    mem_zoom: f32 = 1.0,
    mem_zoom_target: f32 = 1.0,

    cursor_timestamp: u64 = 0,
    viewport_timestamp: u64 = 0,
    mem_view_address_base: u64 = 0,

    is_cursor_anchored_to_end: bool = true,

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
        allocating_stack_id: u64,

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

    stacks: std.hash_map.AutoHashMap(u64, []const u8),

    cache: Cache,

    fn init(allocator: std.mem.Allocator) MemoryStats {
        return MemoryStats{
            .all_messages = std.ArrayList(common.Message).init(allocator),
            .new_messages = std.ArrayList(common.Message).init(allocator),
            .stacks = std.hash_map.AutoHashMap(u64, []const u8).init(allocator),
            .cache = Cache{
                .blocks = std.ArrayList(MemBlock).init(allocator),
            },
        };
    }

    fn deinit(self: *MemoryStats) void {
        self.all_messages.deinit();
        self.new_messages.deinit();
        self.stacks.deinit();
        self.cache.blocks.deinit();
    }

    fn timespanUs(self: *MemoryStats) f64 {
        if (self.first_timestamp < self.last_timestamp) {
            return @intToFloat(f64, self.last_timestamp - self.first_timestamp);
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
                            .allocating_stack_id = v.stack_id,
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
    input: InputState,
    gui: GuiState,

    fn init(window: *zglfw.Window, allocator: std.mem.Allocator) !*AppContext {
        var app = try allocator.create(AppContext);
        app.gfx = try GfxState.init(window, allocator);
        app.window = window;
        app.client = try ClientContext.init(allocator);
        app.mem_stats = MemoryStats.init(allocator);
        app.input = InputState{};
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

fn updateInput(input: *InputState) void {
    for (&input.mouse_button) |*state| {
        state.triggered = false;
        state.release_triggered = false;
    }
}

fn updateMessages(app: *AppContext) !void {
    try client.fetchMessages(&app.client, &app.mem_stats.new_messages);
    try app.mem_stats.all_messages.ensureUnusedCapacity(app.mem_stats.new_messages.items.len);

    for (app.mem_stats.new_messages.items) |msg| {
        const timestamp = switch (msg) {
            .Frame => |v| v.timestamp,
            .Alloc => |v| v.timestamp,
            .Free => |v| v.timestamp,
            else => null,
        };

        if (timestamp) |ts| {
            app.mem_stats.first_timestamp = std.math.min(app.mem_stats.first_timestamp, ts);
            app.mem_stats.last_timestamp = std.math.max(app.mem_stats.last_timestamp, ts);
        }

        switch (msg) {
            .Stack => |v| try app.mem_stats.stacks.put(v.stack_id, v.string),
            .Alloc => app.mem_stats.all_messages.appendAssumeCapacity(msg),
            .Free => app.mem_stats.all_messages.appendAssumeCapacity(msg),
            else => {},
        }
    }

    try app.mem_stats.all_messages.appendSlice(app.mem_stats.new_messages.items);
    app.mem_stats.new_messages.clearRetainingCapacity();
}

fn updateGui(app: *AppContext) !void {
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
    zgui.setNextWindowSize(.{ .w = backbuffer_width, .h = 400, .cond = .once });
    zgui.setNextWindowSizeConstraints(.{ .minx = backbuffer_width, .maxx = backbuffer_width, .miny = 0, .maxy = backbuffer_height - next_window_y });

    const call_tree_flags = zgui.WindowFlags{
        .no_title_bar = true,
        .no_resize = false,
        .no_move = true,
    };

    if (zgui.begin("call_tree", .{ .flags = call_tree_flags })) {
        const mem: *MemoryStats = &app.mem_stats;
        if (mem.cache.selected_block) |block| {
            zgui.text("selected_block at 0x{X} with size {} bytes, allocating callstack:", .{ block.address, block.size });

            if (mem.stacks.get(block.allocating_stack_id)) |callstack| {
                var depth: usize = 0;
                var begin_index: usize = 0;
                while (true) {
                    var node_id_buffer: [64]u8 = undefined;
                    var node_id: [:0]u8 = std.fmt.bufPrintZ(&node_id_buffer, "callstack_depth_{}", .{depth}) catch unreachable;

                    var stack_frame = std.mem.sliceTo(callstack[begin_index..], '\n');

                    if (stack_frame.len == 0) {
                        break;
                    }

                    begin_index += stack_frame.len + 1; // +1 to skip newline

                    if (zgui.treeNodeStrId(node_id, "{s}", .{stack_frame}) == false) {
                        break;
                    }

                    depth += 1;
                }

                for (0..depth) |_| {
                    zgui.treePop();
                }
            } else {
                zgui.text("Unavailable.", .{});
            }
        } else {
            zgui.textUnformatted("Select a block in the memory view to view its details.");
        }
        next_window_y += zgui.getWindowHeight();
        zgui.end();
    }

    const draw_list: zgui.DrawList = zgui.getBackgroundDrawList();
    draw_list.pushClipRect(.{ .pmin = .{ 0, next_window_y }, .pmax = .{ backbuffer_width, backbuffer_height } });
    defer draw_list.popClipRect();

    const gui: *GuiState = &app.gui;
    const mem: *MemoryStats = &app.mem_stats;
    const input: *const InputState = &app.input;

    var next_cursor: *zglfw.Cursor = gui.cursors.arrow;
    {
        const COLOR_SECTION_BORDER = 0xFF707070;

        const COLOR_CURSOR_DEFAULT = 0xFF0000A0;
        const COLOR_CURSOR_HOVER = 0xFF0000FF;
        const COLOR_CURSOR_DRAGGED = 0xFF0000FF;

        const COLOR_TIMELINE_VIEWPORT_DEFAULT = 0xFF520096;
        const COLOR_TIMELINE_VIEWPORT_HOVER = 0xFF8C00FF;
        const COLOR_TIMELINE_VIEWPORT_DRAGGED = 0xFF8C00FF;
        const COLOR_TIMELINE_TEXT = 0xFFD0D0D0;

        const timeline_width = backbuffer_width;
        const timeline_height = 22.0;
        const timeline_y_min = next_window_y;
        const timeline_y_max = next_window_y + timeline_height;

        const viewport_timeline_height = 40.0;
        const viewport_timeline_y_min = timeline_y_max + 1;
        const viewport_timeline_y_max = viewport_timeline_y_min + viewport_timeline_height;

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

        const us_per_ms = @intToFloat(f64, std.time.us_per_ms);

        // A note on timestamps... local variables for timestamps are in f64 microseconds, and are always relative to mem.first_timestamp to avoid
        // floating point precision errors. Whenever storing them back in mem/gui structs, they are stored as absolute u64 timestamps.
        const timeline_duration: f64 = mem.timespanUs();
        if (timeline_duration > 0.0) {
            // timeline ticks and labels
            const num_timeline_ticks: usize = 10;
            for (0..num_timeline_ticks + 1) |i| {
                const ratio = @intToFloat(f32, i) / @intToFloat(f32, num_timeline_ticks);
                var x_offset: f32 = 0;
                if (i == num_timeline_ticks) {
                    x_offset = 1;
                }
                const tick_x = ratio * timeline_width - x_offset;
                const us = ratio * timeline_duration;
                draw_list.addLine(.{ .p1 = .{ tick_x, timeline_y_min }, .p2 = .{ tick_x, timeline_y_max }, .col = COLOR_SECTION_BORDER, .thickness = 1 });

                var text_buffer: [32]u8 = undefined;
                const text = std.fmt.bufPrint(&text_buffer, "{d:.2}ms", .{us / us_per_ms}) catch unreachable;

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

            // viewport
            gui.viewport_timestamp = std.math.clamp(gui.viewport_timestamp, mem.first_timestamp, mem.last_timestamp);

            var viewport_duration: f64 = std.math.ceil(timeline_duration / gui.timeline_zoom);
            var timeline_viewport_color: u32 = COLOR_TIMELINE_VIEWPORT_DEFAULT;

            const is_mouse_in_timeline = gui.mouse_pos_y >= timeline_y_min and gui.mouse_pos_y <= timeline_y_max;
            const is_mouse_in_viewport_timeline = gui.mouse_pos_y >= viewport_timeline_y_min and gui.mouse_pos_y <= viewport_timeline_y_max;

            // drag viewport in timeline
            {
                if (input.isMouseDown(.left) == false) {
                    gui.viewport_drag_focus = null;
                }

                if (is_mouse_in_timeline and gui.is_dragging_cursor == false and gui.is_dragging_mem_view == false) {
                    const viewport_timestamp = @intToFloat(f64, gui.viewport_timestamp - mem.first_timestamp);
                    const viewport_x_min = (viewport_timestamp / timeline_duration) * timeline_width;
                    const viewport_x_max = viewport_x_min + (viewport_duration / timeline_duration) * timeline_width;
                    const is_mouse_hovering_viewport = is_mouse_in_timeline and gui.mouse_pos_x >= viewport_x_min and gui.mouse_pos_x <= viewport_x_max;

                    if (is_mouse_hovering_viewport) {
                        next_cursor = gui.cursors.hand;
                        timeline_viewport_color = COLOR_TIMELINE_VIEWPORT_HOVER;

                        if (input.isMouseDownTriggered(.left)) {
                            gui.viewport_drag_focus = (gui.mouse_pos_x - viewport_x_min) / (viewport_x_max - viewport_x_min);
                        }
                    }
                }

                if (gui.viewport_drag_focus) |focus| {
                    next_cursor = gui.cursors.hand;
                    timeline_viewport_color = COLOR_TIMELINE_VIEWPORT_DRAGGED;

                    // reposition the viewport such that the viewport focus is at the mouse x position
                    const mouse_timestamp = (gui.mouse_pos_x / timeline_width) * timeline_duration;
                    const viewport_focus_offset = viewport_duration * focus;
                    const viewport_timestamp = std.math.floor(mouse_timestamp - viewport_focus_offset);
                    const viewport_timestamp_clamped = std.math.clamp(viewport_timestamp, 0, timeline_duration - viewport_duration);
                    gui.viewport_timestamp = @floatToInt(u64, viewport_timestamp_clamped) + mem.first_timestamp;
                }

                // if (input.isMouseDown(.right) == .press) {
                //     // TODO right click and drag to redefine the viewport
                // }
            }

            // handle timeline viewport zoom
            {
                var viewport_zoom_focal_point_normalized: ?f64 = null;
                if (gui.is_dragging_cursor == false) {
                    const viewport_timestamp = @intToFloat(f64, gui.viewport_timestamp - mem.first_timestamp);
                    const viewport_x_min = (viewport_timestamp / timeline_duration) * timeline_width;
                    const viewport_x_max = viewport_x_min + (viewport_duration / timeline_duration) * timeline_width;

                    if (gui.scroll_delta_y != 0) {
                        if (is_mouse_in_timeline) {
                            if (gui.mouse_pos_x >= viewport_x_min and gui.mouse_pos_x <= viewport_x_max) {
                                viewport_zoom_focal_point_normalized = (gui.mouse_pos_x - viewport_x_min) / (viewport_x_max - viewport_x_min);
                            } else {
                                // if the mouse is not inside the current viewport, just make the focal point the middle to make the zoom even on both sides
                                viewport_zoom_focal_point_normalized = 0.5;
                            }
                        } else if (is_mouse_in_viewport_timeline) {
                            viewport_zoom_focal_point_normalized = gui.mouse_pos_x / timeline_width;
                        }

                        if (is_mouse_in_timeline or is_mouse_in_viewport_timeline) {
                            gui.timeline_zoom_target = std.math.max(gui.timeline_zoom_target + @floatCast(f32, gui.scroll_delta_y * 0.25), 1.0);
                        }
                    }
                }

                const prev_zoom = gui.timeline_zoom;
                // gui.timeline_zoom = GuiState.tweenZoom(app.gui.timeline_zoom, app.gui.timeline_zoom_target);
                gui.timeline_zoom = app.gui.timeline_zoom_target;

                viewport_duration = std.math.ceil(timeline_duration / gui.timeline_zoom);

                // shift the viewport timestamp to keep the zoom focal point the same
                if (prev_zoom != gui.timeline_zoom) {
                    if (viewport_zoom_focal_point_normalized) |focus_normalized| {
                        const viewport_timestamp = @intToFloat(f64, gui.viewport_timestamp - mem.first_timestamp);
                        const prev_viewport_duration = std.math.ceil(timeline_duration / prev_zoom);

                        const viewport_focus_us = viewport_timestamp + focus_normalized * prev_viewport_duration;
                        const viewport_focus_offset_us = focus_normalized * viewport_duration;
                        const viewport_timestamp_unclamped = @floatToInt(u64, std.math.max(0, viewport_focus_us - viewport_focus_offset_us)) + mem.first_timestamp;

                        var viewport_timestamp_clamped = std.math.min(viewport_timestamp_unclamped, mem.last_timestamp - @floatToInt(u64, viewport_duration));
                        viewport_timestamp_clamped = std.math.max(viewport_timestamp_clamped, mem.first_timestamp);
                        gui.viewport_timestamp = viewport_timestamp_clamped;
                    }
                }
            }

            // draw viewport in the global timeline
            {
                const viewport_timestamp = @intToFloat(f64, gui.viewport_timestamp - mem.first_timestamp);
                const viewport_x = (viewport_timestamp / timeline_duration) * timeline_width;
                const viewport_width = timeline_width / gui.timeline_zoom;
                const thickness: f32 = if (gui.viewport_drag_focus == null) 1 else 2;

                draw_list.addRect(
                    .{
                        .pmin = .{ @floatCast(f32, viewport_x), timeline_y_min },
                        .pmax = .{ @floatCast(f32, viewport_x + viewport_width), timeline_y_max },
                        .col = timeline_viewport_color,
                        .thickness = thickness,
                    },
                );
            }

            // viewport timeline and cursor
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
                    // clamp the cursor position to the viewport. ensures if the viewport is moved or the cursor is dragged outside that it stays within bounds
                    const viewport_timestamp = @intToFloat(f64, gui.viewport_timestamp - mem.first_timestamp);
                    const viewport_timestamp_end = std.math.ceil(std.math.min(viewport_timestamp + viewport_duration, timeline_duration));
                    gui.cursor_timestamp = std.math.clamp(gui.cursor_timestamp, mem.first_timestamp, mem.last_timestamp);

                    if (gui.is_dragging_cursor) {
                        gui.is_cursor_anchored_to_end = false;
                    }

                    if (gui.is_cursor_anchored_to_end) {
                        gui.cursor_timestamp = mem.last_timestamp;
                    }

                    var cursor_timestamp = std.math.clamp(@intToFloat(f64, gui.cursor_timestamp - mem.first_timestamp), viewport_timestamp, viewport_timestamp_end);

                    var cursor_x = ((cursor_timestamp - viewport_timestamp) / viewport_duration) * timeline_width;

                    if (input.isMouseDown(.left) == false and gui.is_dragging_cursor) {
                        gui.is_dragging_cursor = false;

                        if (gui.mouse_pos_x / timeline_width > 0.95) {
                            gui.is_cursor_anchored_to_end = true;
                        }
                    }

                    const is_mouse_hovering_cursor = gui.mouse_pos_y >= viewport_timeline_y_min and
                        gui.mouse_pos_y <= viewport_timeline_y_max and
                        gui.mouse_pos_x >= (cursor_x - 15.0) and
                        gui.mouse_pos_x <= (cursor_x + 15.0);
                    const can_drag_cursor: bool = (is_mouse_hovering_cursor or gui.is_dragging_cursor) and gui.viewport_drag_focus == null and gui.is_dragging_mem_view == false;
                    if (can_drag_cursor) {
                        next_cursor = gui.cursors.hand;
                        if (input.isMouseDown(.left)) {
                            gui.is_dragging_cursor = true;

                            cursor_timestamp = (gui.mouse_pos_x / timeline_width) * viewport_duration + viewport_timestamp;
                            cursor_timestamp = std.math.clamp(cursor_timestamp, viewport_timestamp, viewport_timestamp_end);
                            cursor_x = ((cursor_timestamp - viewport_timestamp) / viewport_duration) * timeline_width;
                        }
                    }

                    gui.cursor_timestamp = @floatToInt(u64, cursor_timestamp) + mem.first_timestamp;

                    try mem.updateCache(gui.cursor_timestamp);

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
                        .p1 = .{ @floatCast(f32, cursor_x), viewport_timeline_y_min },
                        .p2 = .{ @floatCast(f32, cursor_x), viewport_timeline_y_max },
                        .col = cursor_color, // ABGR
                        .thickness = thickness,
                    });

                    // draw the cursor on the global timeline
                    const cursor_x_timeline = (cursor_timestamp / timeline_duration) * timeline_width;
                    draw_list.addLine(.{
                        .p1 = .{ @floatCast(f32, cursor_x_timeline), timeline_y_min },
                        .p2 = .{ @floatCast(f32, cursor_x_timeline), timeline_y_max },
                        .col = COLOR_CURSOR_DEFAULT, // ABGR
                        .thickness = 1,
                    });

                    const cursor_timestamp_ms = cursor_timestamp / us_per_ms;
                    const viewport_timestamp_ms = viewport_timestamp / us_per_ms;
                    const viewport_timestamp_end_ms = viewport_timestamp_end / us_per_ms;

                    // draw the timestamp on the text
                    var text_buffer: [32]u8 = undefined;
                    var text = std.fmt.bufPrint(&text_buffer, "{d:.2}ms", .{cursor_timestamp_ms}) catch unreachable;
                    const text_size_cursor: [2]f32 = zgui.calcTextSize(text, .{});
                    const text_cursor_x = if (cursor_x + 4 + text_size_cursor[0] <= timeline_width) (cursor_x + 4) else (cursor_x - 2 - text_size_cursor[0]);
                    const text_y = viewport_timeline_y_max - 4 - text_size_cursor[1];
                    draw_list.addTextUnformatted(.{ @floatCast(f32, text_cursor_x), text_y }, cursor_color, text);

                    // draw begin/end timestamps
                    text = std.fmt.bufPrint(&text_buffer, "{d:.2}ms", .{viewport_timestamp_ms}) catch unreachable;
                    const text_size_begin_timestamp: [2]f32 = zgui.calcTextSize(text, .{});
                    const text_begin_x = 4;
                    if (text_begin_x + text_size_begin_timestamp[0] < text_cursor_x - 5) {
                        draw_list.addTextUnformatted(.{ @floatCast(f32, text_begin_x), text_y }, COLOR_TIMELINE_TEXT, text);
                    }

                    text = std.fmt.bufPrint(&text_buffer, "{d:.2}ms", .{viewport_timestamp_end_ms}) catch unreachable;
                    const text_size_end_timestamp: [2]f32 = zgui.calcTextSize(text, .{});
                    const text_end_x = timeline_width - text_size_end_timestamp[0] - 4;
                    if (text_end_x > text_cursor_x + text_size_cursor[0] + 4) {
                        draw_list.addTextUnformatted(.{ @floatCast(f32, text_end_x), text_y }, COLOR_TIMELINE_TEXT, text);
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

                const kb = 1024;
                const kb64 = kb * 64;

                const cache: *MemoryStats.Cache = &mem.cache;
                const cache_first_address = cache.lowest_address - (cache.lowest_address % kb64);
                const cache_last_address = cache.highest_address + (cache.highest_address % kb64);

                const cache_address_space_global = @intToFloat(f64, cache_last_address - cache_first_address);

                {
                    const address_space_zoomed = cache_address_space_global / gui.mem_zoom;
                    gui.mem_view_address_base = std.math.max(gui.mem_view_address_base, cache_first_address);
                    gui.mem_view_address_base = std.math.min(gui.mem_view_address_base, cache_last_address - @floatToInt(u64, address_space_zoomed));
                }

                var mem_viewport_zoom_focal_point_normalized: ?f64 = null;
                const is_mouse_in_mem_viewport = gui.mouse_pos_y >= mem_viewport_y_min and gui.mouse_pos_y <= mem_viewport_y_max;
                if (is_mouse_in_mem_viewport and gui.scroll_delta_y != 0 and gui.viewport_drag_focus == null and gui.is_dragging_cursor == false) {
                    if (gui.mouse_pos_y <= mem_viewport_zoom_bar_y_max) {
                        mem_viewport_zoom_focal_point_normalized = gui.mouse_pos_x / backbuffer_width;
                    } else {
                        const mouse_pos_x_normalized = gui.mouse_pos_x / backbuffer_width;

                        const address_space_zoomed = cache_address_space_global / gui.mem_zoom;
                        const address_offset_begin = @intToFloat(f64, gui.mem_view_address_base - cache_first_address);
                        const focal_address = address_offset_begin + (address_space_zoomed * mouse_pos_x_normalized);

                        mem_viewport_zoom_focal_point_normalized = focal_address / cache_address_space_global;
                    }

                    const delta_multiplier: f64 = if (app.window.getKey(.left_shift) == .press or app.window.getKey(.right_shift) == .press) 4 else 0.25;
                    app.gui.mem_zoom_target = std.math.max(app.gui.mem_zoom_target + @floatCast(f32, gui.scroll_delta_y * delta_multiplier), 1.0);
                }

                if (is_mouse_in_mem_viewport and input.isMouseDown(.left)) {
                    mem.cache.selected_block = null;
                }

                // gui.mem_zoom = GuiState.tweenZoom(gui.mem_zoom, gui.mem_zoom_target);
                {
                    const prev_zoom = gui.mem_zoom;
                    gui.mem_zoom = gui.mem_zoom_target;

                    if (prev_zoom != gui.mem_zoom) {
                        if (mem_viewport_zoom_focal_point_normalized) |focus_normalized| {
                            const address_offset_begin = @intToFloat(f64, gui.mem_view_address_base - cache_first_address);

                            const address_space_zoomed = cache_address_space_global / gui.mem_zoom;
                            const address_space_zoomed_prev = cache_address_space_global / prev_zoom;

                            const focus_address = address_offset_begin + focus_normalized * address_space_zoomed_prev;
                            const focus_offset = focus_normalized * address_space_zoomed;
                            const base_address_unclamped = @floatToInt(u64, std.math.max(0.0, focus_address - focus_offset)) + cache_first_address;
                            gui.mem_view_address_base = std.math.clamp(base_address_unclamped, cache_first_address, cache_last_address);
                            // std.debug.print("focus_address: 0x{X}\n", .{@floatToInt(u64, focus_address)});
                        }
                    }
                }

                const address_space_zoomed = cache_address_space_global / gui.mem_zoom;

                // drag to shift mem view
                const can_drag_mem_view = is_mouse_in_mem_viewport and gui.mouse_delta_x != 0 and gui.viewport_drag_focus == null and gui.is_dragging_cursor == false;
                if (input.isMouseDown(.left) and (can_drag_mem_view or gui.is_dragging_mem_view)) {
                    gui.is_dragging_mem_view = true;

                    const address_delta = gui.mouse_delta_x * (address_space_zoomed / backbuffer_width);
                    const address_offset_begin = @intToFloat(f64, gui.mem_view_address_base - cache_first_address);
                    const new_address_offset_begin = address_offset_begin - address_delta;

                    const base_address_unclamped = @floatToInt(u64, std.math.max(0.0, new_address_offset_begin)) + cache_first_address;
                    gui.mem_view_address_base = std.math.max(base_address_unclamped, cache_first_address);
                    gui.mem_view_address_base = std.math.min(gui.mem_view_address_base, cache_last_address - @floatToInt(u64, address_space_zoomed));
                }

                if (input.isMouseDown(.left) == false and gui.is_dragging_mem_view) {
                    gui.is_dragging_mem_view = false;
                }

                // render memory view zoom
                {
                    draw_list.addRectFilled(.{
                        .pmin = .{ 0, mem_viewport_zoom_bar_y_min },
                        .pmax = .{ backbuffer_width, mem_viewport_zoom_bar_y_max },
                        .col = COLOR_SECTION_BORDER,
                    });

                    const addess_bar_begin_normalized = @intToFloat(f64, gui.mem_view_address_base - cache_first_address) / cache_address_space_global;

                    const mem_zoom_bar_x_min = @floatCast(f32, addess_bar_begin_normalized * backbuffer_width);
                    const mem_zoom_bar_x_max = mem_zoom_bar_x_min + (backbuffer_width / @floatCast(f32, gui.mem_zoom));

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

                if (cache.blocks.items.len > 0) {
                    // draw address space labels and ticks
                    {
                        const num_64k_pages = @floatToInt(u64, @ceil(cache_address_space_global / kb64));

                        draw_list.addLine(.{
                            .p1 = .{ 0, mem_viewport_address_ticks_y_max },
                            .p2 = .{ backbuffer_width, mem_viewport_address_ticks_y_max },
                            .col = COLOR_SECTION_BORDER,
                            .thickness = 1,
                        });

                        for (0..num_64k_pages) |i| {
                            const tick_x = (@intToFloat(f32, i) / @intToFloat(f32, num_64k_pages)) * backbuffer_width;
                            draw_list.addLine(.{
                                .p1 = .{ tick_x, mem_viewport_address_ticks_y_min },
                                .p2 = .{ tick_x, mem_viewport_address_ticks_y_max },
                                .col = COLOR_SECTION_BORDER,
                                .thickness = 1,
                            });
                        }
                    }

                    const mem_view_address_begin = gui.mem_view_address_base;
                    const mem_view_address_end = mem_view_address_begin + @floatToInt(u64, std.math.ceil(address_space_zoomed));

                    const COLOR_MEM_BLOCKS = [_]u32{0xFF56B759};//, 0xFF3B7F3E, 0xFFB58055};
                    // 0xFF3B7F3E

                    var selected_block_x_start: ?f64 = null;
                    var selected_block_x_end: f64 = 0.0;

                    var color_index: usize = 0;
                    for (cache.blocks.items) |*block| {
                        const block_start_address = block.address;
                        const block_end_address = block.address + block.size;

                        // cull blocks that aren't in the view
                        if (block_end_address < mem_view_address_begin or block_start_address > mem_view_address_end) {
                            continue;
                        }

                        const start_address_offset = std.math.max(block_start_address, mem_view_address_begin) - mem_view_address_begin;
                        const end_address_offset = block_end_address - mem_view_address_begin;

                        const block_x_start = (@intToFloat(f64, start_address_offset) / address_space_zoomed) * backbuffer_width;
                        const block_x_end_real = (@intToFloat(f64, end_address_offset) / address_space_zoomed) * backbuffer_width;
                        const block_x_end = std.math.max(block_x_start + 1.0, block_x_end_real);

                        if (is_mouse_in_mem_viewport and input.isMouseDown(.left) and gui.mouse_pos_x >= block_x_start and gui.mouse_pos_x <= block_x_end) {
                            if (gui.is_dragging_cursor == false and gui.viewport_drag_focus == null) {
                                cache.selected_block = block;
                            }
                        }

                        const color = COLOR_MEM_BLOCKS[color_index % COLOR_MEM_BLOCKS.len];
                        color_index += 1;
                        draw_list.addRectFilled(
                            .{
                                .pmin = .{ @floatCast(f32, block_x_start), mem_viewport_blocks_y_min },
                                .pmax = .{ @floatCast(f32, block_x_end), mem_viewport_blocks_y_max },
                                .col = color,
                            },
                        );

                        if (cache.selected_block == block) {
                            selected_block_x_start = block_x_start;
                            selected_block_x_end = block_x_end;
                        } else {
                            draw_list.addRect(
                                .{
                                    .pmin = .{ @floatCast(f32, block_x_start), mem_viewport_blocks_y_min },
                                    .pmax = .{ @floatCast(f32, block_x_end), mem_viewport_blocks_y_max },
                                    .col = 0xFFB58055,
                                },
                            );
                        }
                    }

                    // draw selection after all other blocks have been drawn to avoid other blocks drawing on top of the left/right edges
                    if (selected_block_x_start) |x_start| {
                        draw_list.addRect(
                            .{
                                .pmin = .{ @floatCast(f32, x_start), mem_viewport_blocks_y_min },
                                .pmax = .{ @floatCast(f32, selected_block_x_end), mem_viewport_blocks_y_max },
                                .col = 0xFFFFFFFF,
                            },
                        );
                    }
                }

                // TODO draw ticks and addresses for the current zoomed address space
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

    // TODO move to input
    app.gui.scroll_delta_x = xoffset;
    app.gui.scroll_delta_y = yoffset;
}

fn onCursorPos(window: *zglfw.Window, xpos: f64, ypos: f64) callconv(.C) void {
    const app = @ptrCast(*AppContext, @alignCast(@alignOf(AppContext), glfwGetWindowUserPointer(window)));

    // TODO move to input
    app.gui.mouse_delta_x = xpos - app.gui.mouse_pos_x;
    app.gui.mouse_delta_y = ypos - app.gui.mouse_pos_y;

    app.gui.mouse_pos_x = xpos;
    app.gui.mouse_pos_y = ypos;
}

fn onMouseButton(window: *zglfw.Window, button: zglfw.MouseButton, action: zglfw.Action, _: zglfw.Mods) callconv(.C) void {
    const app = @ptrCast(*AppContext, @alignCast(@alignOf(AppContext), glfwGetWindowUserPointer(window)));

    const index = @intCast(usize, @enumToInt(button));
    const button_state: *ButtonState = &app.input.mouse_button[index];
    button_state.triggered = button_state.down == false and action == .press;
    button_state.release_triggered = action == .release and button_state.down == true;
    button_state.down = action != .release;
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
    window.setMouseButtonCallback(onMouseButton);

    var gpa = std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 16 }){};
    var allocator = gpa.allocator();
    defer _ = gpa.deinit();

    var app = try AppContext.init(window, allocator);
    defer allocator.destroy(app);
    defer app.deinit();

    glfwSetWindowUserPointer(window, app);

    ///// DEBUG ONLY END
    // const RunChildThreadHelper = struct {
    //     fn ThreadFunc(_allocator: *std.mem.Allocator) !void {
    //         const argv = [_][]const u8{ "zig-out/bin/test_host_zig.exe", "test/the_blue_castle.txt" };
    //         var test_process = std.process.Child.init(&argv, _allocator.*);
    //         try test_process.spawn();
    //         _ = try test_process.wait();
    //     }
    // };
    // _ = try std.Thread.spawn(.{}, RunChildThreadHelper.ThreadFunc, .{&allocator});
    /////

    while (!window.shouldClose() and window.getKey(.escape) != .press) {
        zglfw.pollEvents();
        zgui.backend.newFrame(
            app.gfx.gctx.swapchain_descriptor.width,
            app.gfx.gctx.swapchain_descriptor.height,
        );

        try updateMessages(app);
        try updateGui(app);
        updateInput(&app.input);
        draw(app);
    }

    client.joinThread(&app.client);
}
