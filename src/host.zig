const std = @import("std");
const network = @import("network");
const common = @import("common.zig");

const Message = common.Message;

const c_context: ?*HostContext = null;

// C API
pub fn memview_init(memview_resource_buffer: [*]u8, buffer_size: c_ulonglong) callconv(.C) bool {
    const opts = HostContextOpts{
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

pub const HostContextOpts = struct {
    max_instrumented_allocators: u32 = 1,
};

pub const HostContext = struct {
    instrumented_allocators_lock: std.Thread.Mutex,
    instrumented_allocators: std.ArrayList(InstrumentedAllocator),
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

        const min_required_memory = @sizeOf(HostContext) + (@sizeOf(InstrumentedAllocator) * opts.max_instrumented_allocators) + 256;
        if (buffer.len < min_required_memory) {
            std.log.err("[Memview] Minimum required memory is at least {} bytes, but only {} bytes were provided.", .{ min_required_memory, buffer.len });
            return error.MoreMemoryRequired;
        }

        var fba = std.heap.FixedBufferAllocator.init(buffer);
        var allocator = fba.allocator();

        var context: *HostContext = allocator.create(HostContext) catch unreachable;
        context.instrumented_allocators_lock = std.Thread.Mutex{};
        context.instrumented_allocators = std.ArrayList(InstrumentedAllocator).init(allocator);
        context.instrumented_allocators.ensureTotalCapacity(opts.max_instrumented_allocators) catch unreachable;
        context.message_queue_lock = std.Thread.Mutex{};
        context.message_queue = std.ArrayList(u8).init(allocator);
        context.message_queue.ensureTotalCapacity(buffer.len - fba.end_index) catch unreachable;
        context.socket_server = network.Socket.create(.ipv4, .tcp) catch |err| {
            std.log.err("[Memview] Failed to create an IPV4 TCP socket: {}\n", .{err});
            return err;
        };
        context.socket_server.bindToPort(9000) catch |err| {
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
        self.message_queue_lock.lock();
        self.pumpMsgQueueUnlocked();
        self.message_queue_lock.unlock();
    }

    pub fn pumpMsgQueueUnlocked(self: *HostContext) void {
        if (self.socket_client) |client| {
            _ = client.send(self.message_queue.items) catch |err| {
                std.log.err("[Memview] Caught {} sending queue items. Client disconnected.", .{err});
                self.socket_client = null;
            };
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

    pub fn msgAlloc(self: *HostContext, address: u64, size: u64, region_name_id: u64) void {
        const msg = Message{
            .Alloc = .{
                .id_hash = 0, // TODO callstack
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
