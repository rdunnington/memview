const std = @import("std");
const builtin = @import("builtin");
const network = @import("network");
const common = @import("common.zig");

const Message = common.Message;

const c_context: ?*HostContext = null;

pub fn memview_calc_min_required_memory(bytes_for_stacktrace: c_ulonglong) callconv(.C) c_ulonglong {
    const opts = HostContextOpts{
        .bytes_for_stacktrace = bytes_for_stacktrace,
        .max_instrumented_allocators = 0,
    };
    return HostContext.calcMinRequiredMemory(opts);
}

pub fn memview_init(memview_resource_buffer: [*]u8, buffer_size: c_ulonglong, bytes_for_stacktrace: c_ulonglong) callconv(.C) bool {
    const opts = HostContextOpts{
        .bytes_for_stacktrace = bytes_for_stacktrace,
        .max_instrumented_allocators = 0,
    };

    c_context = HostContext.init(memview_resource_buffer[0..buffer_size], opts) catch {
        std.log.err("[Memview] Failed to initialize. Service will be unavailable.\n", .{});
        return false;
    };
    std.log.info("[Memview] Initialized successfully.\n", .{});

    return true;
}

pub fn memview_deinit() callconv(.C) void {
    if (c_context) |context| {
        context.deinit();
    }
    c_context = null;
}

pub fn memview_wait_for_connection() callconv(.C) void {
    if (c_context) |context| {
        context.waitForConnection();
    }
}

pub fn memview_pump_message_queue() callconv(.C) void {
    if (c_context) |context| {
        context.pumpMsgQueue();
    }
}

pub fn memview_msg_frame() callconv(.C) void {
    if (c_context) |context| {
        context.msgFrame();
    }
}

pub fn memview_msg_region(address: c_ulonglong, size: c_ulonglong, name: [*]u8, name_length: c_ushort) callconv(.C) c_ulonglong { // TODO callstack
    if (c_context) |context| {
        return context.msgRegion(size, address, name[0..name_length]);
    }
    return 0;
}

pub fn memview_msg_alloc(address: c_ulonglong, size: c_ulonglong, region_id: c_ulonglong) callconv(.C) void {
    if (c_context) |context| {
        context.msgAlloc(size, address, region_id);
    }
}

const DebugStackTraces = struct {
    const PendingStackTrace = struct {
        addresses: [32]usize,
        last_index: u8,

        fn slice(self: *const PendingStackTrace) []const usize {
            return self.addresses[0..self.last_index];
        }

        fn id(self: *const PendingStackTrace) u64 {
            return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(self.slice()));
        }
    };

    fba: std.heap.FixedBufferAllocator,
    debug_info: ?*std.debug.DebugInfo,
    known_stacks_lock: std.Thread.Mutex,
    known_stacks: std.AutoHashMap(u64, u8), // TODO ideally don't waste needless space on u8s
    resolve_stack_lock: std.Thread.Mutex,
    resolve_stack: std.ArrayList(PendingStackTrace),

    did_warn_no_resolve_stack_mem: bool = false,

    fn init(buffer: []u8) DebugStackTraces {
        // TODO move symbol resolution to the memview app
        var debug_info: ?*std.debug.DebugInfo = std.debug.getSelfDebugInfo() catch |err| blk: {
            std.log.err("[Memview] Failed to initialize debug info structures: {}. Translated stack traces will not be available. Consider ", .{err});
            break :blk null;
        };

        var fba = std.heap.FixedBufferAllocator.init(buffer);
        var allocator = fba.allocator();
        var known_stacks = std.AutoHashMap(u64, u8).init(allocator);
        var resolve_stack = std.ArrayList(PendingStackTrace).init(allocator);

        const bytes_for_known_stacks = @intToFloat(f32, buffer.len - fba.end_index) * 0.1;
        const approx_max_known_stacks = (bytes_for_known_stacks / @intToFloat(f32, @sizeOf(u64) + 1)) * (@intToFloat(f32, std.hash_map.default_max_load_percentage) / 100.0);
        known_stacks.ensureTotalCapacity(@floatToInt(u32, approx_max_known_stacks)) catch unreachable;

        const bytes_for_resolve_stack = buffer.len - fba.end_index;
        const num_stacks = bytes_for_resolve_stack / @sizeOf(PendingStackTrace);
        resolve_stack.ensureTotalCapacityPrecise(num_stacks - 1) catch unreachable;

        return DebugStackTraces{
            .fba = fba,
            .debug_info = debug_info,
            .known_stacks_lock = std.Thread.Mutex{},
            .known_stacks = known_stacks,
            .resolve_stack_lock = std.Thread.Mutex{},
            .resolve_stack = resolve_stack,
        };
    }

    fn capture(self: *DebugStackTraces, return_address: usize) u64 {
        var pending: PendingStackTrace = undefined;
        var stacktrace = std.builtin.StackTrace{
            .instruction_addresses = pending.addresses[0..],
            .index = 0,
        };

        std.debug.captureStackTrace(return_address, &stacktrace);
        pending.last_index = @intCast(u8, stacktrace.index);

        const stack_id = pending.id();

        var needs_resolve: bool = true;
        {
            self.known_stacks_lock.lock();
            if (self.known_stacks.contains(stack_id)) {
                needs_resolve = false;
            } else {
                self.known_stacks.putAssumeCapacity(stack_id, 0);
            }
            self.known_stacks_lock.unlock();
        }

        if (needs_resolve) {
            self.resolve_stack_lock.lock();
            if (self.resolve_stack.items.len < self.resolve_stack.capacity) {
                self.resolve_stack.appendAssumeCapacity(pending);
            } else if (self.did_warn_no_resolve_stack_mem == false) {
                self.did_warn_no_resolve_stack_mem = true;
                std.log.err("[Memview] Failed to enqueue stack for resolving: not enough internal memory. Increase bytes_for_stacktrace when calling init to avoid this warning.\n", .{});
            }
            self.resolve_stack_lock.unlock();
        }

        return stack_id;
    }

    fn resolveNext(self: *DebugStackTraces, context: *HostContext) bool {
        var pending: ?PendingStackTrace = null;
        self.resolve_stack_lock.lock();
        if (self.resolve_stack.items.len > 0) {
            pending = self.resolve_stack.pop();
        }
        self.resolve_stack_lock.unlock();

        if (pending) |p| {
            var stack_string_buffer: [1024 * 4]u8 = undefined;
            var fba = std.io.fixedBufferStream(&stack_string_buffer);
            var writer = fba.writer();

            var addresses = p.slice();
            for (addresses) |address| {
                var module: ?*std.debug.ModuleDebugInfo = null;
                if (self.debug_info) |dbg| {
                    module = dbg.getModuleForAddress(address) catch null;
                }
                var symbol_info: ?std.debug.SymbolInfo = null;
                if (module) |m| {
                    symbol_info = m.getSymbolAtAddress(self.debug_info.?.allocator, address) catch null;
                }

                if (symbol_info) |sym| {
                    defer sym.deinit(self.debug_info.?.allocator);
                    writeSymbolInfo(writer, address, sym.line_info, sym.symbol_name, sym.compile_unit_name) catch break;
                } else {
                    writeSymbolInfo(writer, address, null, "<unknown_symbol>", "<unknown_compile_unit>") catch break;
                }
            }

            const stack_id = p.id();
            const resolved_stack_string = stack_string_buffer[0..fba.pos];

            context.msgStack(stack_id, resolved_stack_string);
            return true;
        }

        return false;
    }

    fn writeSymbolInfo(writer: anytype, address: usize, line_info: ?std.debug.LineInfo, symbol_name: []const u8, compile_unit_name: []const u8) !void {
        if (line_info) |*li| {
            try writer.print("{s}:{d}:{d}", .{ li.file_name, li.line, li.column });
        } else {
            try writer.print("???:?:?", .{});
        }

        try writer.print(": 0x{x} in {s} ({s})\n", .{ address, symbol_name, compile_unit_name });
    }
};

pub const HostContextOpts = struct {
    max_instrumented_allocators: u32 = 1,
    bytes_for_stacktrace: usize = 1024 * 1024 * 2,
};

pub const HostContext = struct {
    instrumented_allocators_lock: std.Thread.Mutex,
    instrumented_allocators: std.ArrayList(InstrumentedAllocator),
    stacks: DebugStackTraces,
    message_queue_lock: std.Thread.Mutex,
    message_queue: std.ArrayList(u8),
    socket_server: network.Socket,
    socket_client: ?network.Socket,
    accept_thread: ?std.Thread,

    const InstrumentedAllocator = struct {
        context: *HostContext,
        allocator: std.mem.Allocator,
    };

    const instrumented_allocator_vtable = std.mem.Allocator.VTable{
        .alloc = instrumentedAlloc,
        .resize = instrumentedResize,
        .free = instrumentedFree,
    };

    pub fn calcMinRequiredMemory(opts: HostContextOpts) usize {
        return @sizeOf(HostContext) + (@sizeOf(InstrumentedAllocator) * opts.max_instrumented_allocators) + opts.bytes_for_stacktrace + 256;
    }

    pub fn init(buffer: []u8, opts: HostContextOpts) !*HostContext {
        const AcceptThread = struct {
            fn Func(context: *HostContext) void {
                var client: network.Socket = undefined;
                while (true) {
                    if (context.socket_server.accept()) |new_client| {
                        client = new_client;
                        break;
                    } else |err| {
                        std.log.err("[Memview] Failed to accept client: {}.\n", .{err});
                    }
                }

                context.message_queue_lock.lock();
                context.socket_client = client;
                context.accept_thread = null;
                context.message_queue_lock.unlock();

                if (client.getLocalEndPoint()) |endpoint| {
                    std.log.info("[Memview] Client connected from {}.\n", .{endpoint});
                } else |_| {
                    std.log.info("[Memview] Client connected from unknown endpoint.\n", .{});
                }
            }
        };

        const min_required_memory = calcMinRequiredMemory(opts);
        if (buffer.len < min_required_memory) {
            std.log.err("[Memview] Minimum required memory is at least {} bytes, but only {} bytes were provided.", .{ min_required_memory, buffer.len });
            return error.MoreMemoryRequired;
        }

        var fba = std.heap.FixedBufferAllocator.init(buffer);
        var allocator = fba.allocator();

        var context: *HostContext = allocator.create(HostContext) catch unreachable;
        context.instrumented_allocators_lock = std.Thread.Mutex{};
        context.instrumented_allocators = std.ArrayList(InstrumentedAllocator).init(allocator);
        context.instrumented_allocators.ensureTotalCapacityPrecise(opts.max_instrumented_allocators) catch unreachable;
        context.stacks = DebugStackTraces.init(buffer[fba.end_index .. fba.end_index + opts.bytes_for_stacktrace]);
        fba.end_index = fba.end_index + opts.bytes_for_stacktrace;
        context.message_queue_lock = std.Thread.Mutex{};
        context.message_queue = std.ArrayList(u8).init(allocator);
        context.message_queue.ensureTotalCapacityPrecise(buffer.len - fba.end_index) catch unreachable;
        context.socket_server = network.Socket.create(.ipv4, .tcp) catch |err| {
            std.log.err("[Memview] Failed to create an IPV4 TCP socket: {}\n", .{err});
            return err;
        };
        context.socket_server.enablePortReuse(true) catch |err| {
            std.log.err("[Memview] Failed to enable port reuse on server socket: {}. Continuing...\n", .{err});
        };
        context.socket_server.bindToPort(8080) catch |err| {
            std.log.err("[Memview] Failed to bind socket to port 9000: {}\n", .{err});
            return err;
        };
        context.socket_server.listen() catch |err| {
            std.log.err("[Memview] Failed to start listening on socket: {}\n", .{err});
            return err;
        };

        context.socket_client = null;
        context.accept_thread = std.Thread.spawn(.{}, AcceptThread.Func, .{context}) catch |err| {
            std.log.err("[Memview] Failed to spawn socket accept thread: {}\n", .{err});
            return err;
        };

        return context;
    }

    pub fn deinit(self: *HostContext) void {
        if (self.accept_thread) |thread| {
            thread.detach();
        }
        self.socket_server.close();
        if (self.socket_client) |socket| {
            socket.close();
        }
    }

    pub fn waitForConnection(self: *HostContext) void {
        if (self.accept_thread) |thread| {
            thread.join();
        }
    }

    pub fn pumpMsgQueue(self: *HostContext) void {
        while (self.stacks.resolveNext(self)) {}

        self.message_queue_lock.lock();
        self.pumpMsgQueueUnlocked();
        self.message_queue_lock.unlock();
    }

    pub fn pumpMsgQueueUnlocked(self: *HostContext) void {
        if (self.socket_client) |client| {
            _ = client.send(self.message_queue.items) catch |err| {
                std.log.err("[Memview] Caught {} sending queue items. Client disconnected.", .{err});
                self.socket_client = null;
                self.message_queue.clearRetainingCapacity();
                return;
            };
            // std.debug.print("num sent bytes: {}\n", .{sent_bytes});
        }
        self.message_queue.clearRetainingCapacity();
    }

    pub fn msgId(self: *HostContext, name: []u8) u64 {
        const msg = Message{
            .Identifier = .{
                .name = name,
            },
        };
        self.enqueueMsg(&msg);

        const name_id = common.Identifier.calcHash(name);
        return name_id;
    }

    pub fn msgFrame(self: *HostContext) void {
        const msg = Message{
            .Frame = .{
                .timestamp = getTimestamp(),
            },
        };
        self.enqueueMsg(std.mem.asBytes(&msg));
    }

    pub fn msgRegion(self: *HostContext, address: u64, size: u64, name_id: u64) void {
        const msg = Message{
            .Region = .{
                .id_hash = name_id,
                .address = address,
                .size = size,
            },
        };
        self.enqueueMsg(std.mem.asBytes(&msg));
    }

    pub fn msgStack(self: *HostContext, stack_id: u64, string: []const u8) void {
        const msg = Message{
            .Stack = .{
                .stack_id = stack_id,
                .string = string,
            },
        };
        self.enqueueMsg(&msg);
    }

    pub fn msgAlloc(self: *HostContext, address: u64, size: u64, region_name_id: u64) void {
        const stack_id: u64 = self.stacks.capture(@returnAddress());
        const msg = Message{
            .Alloc = .{
                .stack_id = stack_id,
                .address = address,
                .size = size,
                .timestamp = getTimestamp(),
                .region = region_name_id,
            },
        };
        self.enqueueMsg(&msg);
    }

    pub fn msgFree(self: *HostContext, address: u64) void {
        const msg = Message{
            .Free = .{
                .address = address,
                .timestamp = getTimestamp(),
            },
        };
        self.enqueueMsg(&msg);
    }

    pub fn instrument(self: *HostContext, allocator: std.mem.Allocator) ?std.mem.Allocator {
        var instrumented_allocator: ?*InstrumentedAllocator = null;

        self.instrumented_allocators_lock.lock();
        if (self.instrumented_allocators.items.len < self.instrumented_allocators.capacity) {
            instrumented_allocator = self.instrumented_allocators.addOneAssumeCapacity();
            instrumented_allocator.?.* = InstrumentedAllocator{
                .context = self,
                .allocator = allocator,
            };
        }
        self.instrumented_allocators_lock.unlock();

        if (instrumented_allocator) |a| {
            return std.mem.Allocator{
                .ptr = a,
                .vtable = &instrumented_allocator_vtable,
            };
        } else {
            std.log.err("[Memview] Not enough capacity in instrumented_allocators. Increase opts.max_instrumented_allocators in HostContext.init() to have more space.", .{});
            return null;
        }
    }

    fn enqueueMsg(self: *HostContext, msg: *const Message) void {
        self.message_queue_lock.lock();
        const bytes_left = self.message_queue.capacity - self.message_queue.items.len;
        const msg_size = msg.calcTotalSize();
        if (bytes_left < msg_size) {
            std.log.warn("[Memview] Not enough capacity in message queue, peforming blocking flush to avoid dropping message. Allocate more memory to memview or call pumpMsgQueue() more often to avoid this.", .{});
            self.pumpMsgQueueUnlocked();
        }
        // std.debug.print("sending msg: {}\n", .{msg});
        msg.write(&self.message_queue);
        self.message_queue_lock.unlock();
    }

    fn getTimestamp() u64 {
        var ts = std.time.microTimestamp();
        if (ts < 0) {
            return 0;
        }
        return @intCast(u64, ts);
    }

    fn instrumentedAlloc(ctx: *anyopaque, len: usize, ptr_align: u8, ret_addr: usize) ?[*]u8 {
        var instrumented_allocator = @ptrCast(*InstrumentedAllocator, @alignCast(@alignOf(InstrumentedAllocator), ctx));
        var ptr: ?[*]u8 = std.mem.Allocator.rawAlloc(instrumented_allocator.allocator, len, ptr_align, ret_addr);
        if (ptr) |p| {
            instrumented_allocator.context.msgAlloc(@ptrToInt(p), len, 0); // TODO bind InstrumentedAllocator to an allocator id?
        }
        return ptr;
    }

    fn instrumentedResize(ctx: *anyopaque, buf: []u8, buf_align: u8, new_len: usize, ret_addr: usize) bool {
        // TODO instrument this
        var instrumented_allocator = @ptrCast(*InstrumentedAllocator, @alignCast(@alignOf(InstrumentedAllocator), ctx));
        return std.mem.Allocator.rawResize(instrumented_allocator.allocator, buf, buf_align, new_len, ret_addr);
    }

    fn instrumentedFree(ctx: *anyopaque, buf: []u8, buf_align: u8, ret_addr: usize) void {
        var instrumented_allocator = @ptrCast(*InstrumentedAllocator, @alignCast(@alignOf(InstrumentedAllocator), ctx));
        instrumented_allocator.context.msgFree(@ptrToInt(buf.ptr));
        return std.mem.Allocator.rawFree(instrumented_allocator.allocator, buf, buf_align, ret_addr);
    }
};
