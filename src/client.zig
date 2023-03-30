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
    context.shared_message_buffer_lock.unlock();
}

fn clientThreadFunc(context: *ClientContext) !void {
    var socket = network.Socket.create(.ipv4, .tcp) catch |err| {
        std.debug.print("Failed to create an IPV4 TCP socket: {}\n", .{err});
        return;
    };
    defer socket.close();
    try socket.bindToPort(9000);
    try socket.listen();
    var client: network.Socket = socket.accept() catch |err| {
        std.debug.print("Failed to accept a new client with {}. Giving up...\n", .{err});
        return;
    };
    defer client.close();

    std.debug.print("Client connected: {}.\n", .{try client.getLocalEndPoint()});

    mainClientThread(context, &client) catch |err| {
        std.debug.print("Client disconnected: {}\n", .{err});
    };
}

fn mainClientThread(context: *ClientContext, client: *network.Socket) !void {
    while (context.run) {
        const recieved_bytes = try client.receive(context.receive_buffer);
        if (recieved_bytes == 0) {
            std.debug.print("Client disconnected. Exiting thread...\n", .{});
            break;
        }

        std.debug.print("got {} bytes...\n", .{recieved_bytes});

        context.shared_message_buffer_lock.lock();
        const read_bytes = try Message.read(context.receive_buffer, &context.shared_message_buffer, &context.stringpool);
        context.shared_message_buffer_lock.unlock();

        if (read_bytes < recieved_bytes) {
            unreachable;
        }
    }
}
