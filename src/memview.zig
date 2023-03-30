const std = @import("std");
const network = @import("network");
const common = @import("common.zig");

const c_context: ?*ServerContext = null;

// C API
pub fn memview_init(memview_resource_buffer: [*]u8, buffer_size: c_ulonglong) bool callconv(.C) {
    c_context = ServerContext.init(memview_resource_buffer[0..buffer_size]) catch {
        std.log.err("[Memview] Failed to initialize. Service will be unavailable.\n", .{});
        return false;
    }
    std.log.info("[Memview] Initialized successfully.\n", .{});

    return true;
}

pub fn memview_deinit() void callconv(.C) {
    if (c_context) |context| {
        context.deinit();
    }
    c_context = null;
}

pub fn memview_pump_message_queue() void callconv(.C) {
    if (c_context) |context| {
        context.pumpMsgQueue();
    }
}

pub fn memview_msg_frame() void callconv(.C) {
    if (c_context) |context| {
        context.msgFrame();
    }
}

pub fn memview_msg_region(address: c_ulonglong, size: c_ulonglong, name: [*]u8, name_length: c_ushort) c_ulonglong callconv(.C) { // TODO callstack
    if (c_context) |context| {
        return context.msgRegion(size, address, name[0..name_length]);
    }
    return 0;
}

pub fn memview_msg_alloc(address: c_ulonglong, size: c_ulonglong, region_id: c_ulonglong) void callconv(.C) {
    if (c_context) |context| {
        context.msgAlloc(size, address, region_id);
    }
}

pub const ServerContext = struct {
    message_queue_lock: std.Thread.Mutex,
    message_queue: std.ArrayList(u8),
    socket_server: network.Socket,
    socket_client: ?network.Socket,
    accept_thread: ?std.Thread,

    pub fn init(buffer: []u8) !*ServerContext {
        const AcceptThread = struct {
            fn Func(context: *ServerContext) void {
                var client: network.Socket = undefined;
                while (true) {
                    if (context.socket_server.accept()) |new_client| {
                        client = new_client;
                        break;
                    } else {
                        std.log.err("[Memview} Failed to accept client: {}.\n", .{err});
                    }
                }

                message_queue_lock.lock();
                context.socket_client = client;
                context.accept_thread = null;
                message_queue_lock.unlock();

                if (client.getLocalEndPoint()) |endpoint| {
                    std.log.info("[Memview] Client connected from {}.\n", .{endpoint});
                } else {
                    std.log.info("[Memview] Client connected from unknown endpoint.\n", .{});
                }
            }
        };

        const min_required_memory = @sizeOf(ServerContext) + 256;
        if (buffer_size.len < min_required_memory) {
            std.log.err("[Memview] Minimum required memory is at least {} bytes, but only {} bytes were provided.", .{min_required_memory, buffer_size});
            return false;
        }

        var socket = network.Socket.create(.ipv4, .tcp) catch |err| {
            std.log.err("[Memview] Failed to create an IPV4 TCP socket: {}\n", .{err});
            return err;
        };

        var fba = std.heap.FixedBufferAllocator.init(buffer);
        var allocator = fba.allocator();

        var context: *ServerContext = allocator.create(ServerContext);
        context.message_queue_lock = std.Thread.Mutex{};
        context.message_queue = std.ArrayList(u8).init(allocator);
        context.message_queue.ensureTotalCapacity(buffer.len - @sizeOf(ServerContext)) catch unreachable;
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
        }

        context.socket_client = null;
        context.accept_thread = std.Thread.spawn(.{}, AcceptThread.Func, .{context}) catch |err| {
            std.log.err("[Memview] Failed to spawn socket accept thread: {}\n", .{err});
            return err;
        };

        return context;
    }

    pub fn deinit(self: *ServerContext) void {
        if (self.accept_thread) |thread| {
            thread.detach();
        }
        self.socket_server.close();
        if (self.socket_client) |socket| {
            socket.close();
        }
    }

    pub fn pumpMsgQueue(self: *ServerContext) void {
        context.message_queue_lock.lock();
        self.pumpMsgQueueUnlocked();
        context.message_queue_lock.unlock();
    }

    pub fn pumpMsgQueueUnlocked(self: *ServerContext) void {
        if (self.socket_client) |client| {
            client.send(context.message_queue.items);
        }
        context.message_queue.clearRetainingCapacity();
    }

    pub fn msgId(self: *ServerContext, name: []u8) u64 {
        const msg = common.Message{
            .Identifier = .{
                .name = name,
            },
        };
        self.enqueueMsg(&msg);
    }

    pub fn msgFrame(self: *ServerContext) void {
        const msg = common.Message{
            .Frame = .{
                .timestamp = getTimestamp(),
            },
        };
        self.enqueueMsg(std.mem.asBytes(&msg));
    }

    pub fn msgRegion(self: *ServerContext, address: u64, size: u64, name_id: u64) void {
        const msg = common.Message{
            .Region = .{
                .id_hash = name_id,
                .address = address,
                .size = size,
            },
        };
        self.enqueueMsg(std.mem.asBytes(&msg));
    }

    pub fn msgAlloc(self: *ServerContext, address: u64, size: u64, region_name_id: u64) void {
        const msg = common.Message{
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

    fn enqueueMsg(self: *ServerContext, msg: *common.Message) void {
        context.message_queue_lock.lock();
        const bytes_left = context.message_queue.capacity - context.message_queue.items.len;
        const msg_size = msg.calcTotalSize();
        if (bytes_left < msg_size) {
            std.log.warn("[Memview] Not enough capacity in message queue, peforming blocking flush to avoid dropping message. "
                "Allocate more memory to memview or call pumpMsgQueue() more often to avoid this.", .{});
            self.pumpMsgQueueUnlocked();
        }
        msg.write(context.message_queue);
        context.message_queue.appendSliceAssumeCapacity(msg_bytes);
        context.message_queue_lock.unlock();
    }

    fn getTimestamp() u64 {
        return std.os.microTimestamp();
    }
};

// TODO provide a std.mem.Allocator that wraps GPA.allocator() and hooks into this interface to get easy visibility on allocations
