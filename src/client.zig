const std = @import("std");
const network = @import("network");
const common = @import("common.zig");
const StringPool = @import("stringpool.zig");

const Message = common.Message;

pub const ClientContext = struct {
    shared_message_buffer_lock: std.Thread.Mutex,
    shared_message_buffer: std.ArrayList(Message),
    stringpool: StringPool,

    receive_buffer: []u8,
    thread: ?std.Thread = null,
    run: bool = true,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !ClientContext {
        var shared_message_buffer = std.ArrayList(Message).init(allocator);
        try shared_message_buffer.ensureTotalCapacity((1024 * 16) / @sizeOf(Message));
        const max_stringpool_bytes = 16 * 1024 * 1024;
        var stringpool = StringPool.init(max_stringpool_bytes, allocator);
        var receive_buffer = try allocator.alloc(u8, 1024 * 16); // 16K

        return ClientContext{
            .shared_message_buffer_lock = std.Thread.Mutex{},
            .shared_message_buffer = shared_message_buffer,
            .stringpool = stringpool,
            .receive_buffer = receive_buffer,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ClientContext) void {
        self.shared_message_buffer.deinit();
        self.allocator.free(self.receive_buffer);
    }
};

pub fn spawnThread(context: *ClientContext) !void {
    const config = std.Thread.SpawnConfig{};
    context.thread = try std.Thread.spawn(config, clientThreadFunc, .{context});
}

pub fn joinThread(context: *ClientContext) void {
    context.run = false;
    context.thread.?.detach();
    context.thread = null;
}

pub fn fetchMessages(context: *ClientContext, fetched: *std.ArrayList(Message)) !void {
    context.shared_message_buffer_lock.lock();
    try fetched.appendSlice(context.shared_message_buffer.items);
    context.shared_message_buffer.clearRetainingCapacity();
    context.shared_message_buffer_lock.unlock();
}

fn clientThreadFunc(context: *ClientContext) !void {
    var socket: ?network.Socket = null;
    while (socket == null) {
        socket = network.connectToHost(std.heap.page_allocator, "localhost", 8080, .tcp) catch null;
    }
    defer socket.?.close();

    std.debug.print("Connected to host at: {}.\n", .{try socket.?.getRemoteEndPoint()});
    mainClientThread(context, &(socket.?)) catch |err| {
        std.debug.print("Client disconnected with {}. Exiting thread...\n", .{err});
    };
}

fn mainClientThread(context: *ClientContext, client: *network.Socket) !void {
    var begin_offset: usize = 0;
    while (context.run) {
        const receive_buffer = context.receive_buffer[begin_offset..];
        const received_bytes = try client.receive(receive_buffer);
        if (received_bytes == 0) {
            std.debug.print("Client disconnected. Exiting thread...\n", .{});
            break;
        }

        context.shared_message_buffer_lock.lock();
        const concatenated_receive_slice = context.receive_buffer[0 .. begin_offset + received_bytes];
        const read_bytes = try Message.read(concatenated_receive_slice, &context.shared_message_buffer, &context.stringpool);
        context.shared_message_buffer_lock.unlock();

        var leftover_bytes: usize = concatenated_receive_slice.len - read_bytes;
        var dest = context.receive_buffer[0..leftover_bytes];
        var src = concatenated_receive_slice[read_bytes..concatenated_receive_slice.len];
        std.mem.copy(u8, dest, src);

        begin_offset = leftover_bytes;
    }
}
