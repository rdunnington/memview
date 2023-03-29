const std = @import("std");
const network = @import("network");
const common = @import("common.zig");

pub const ServerContext = struct {
    shared_message_buffer_lock: std.Thread.Mutex,
    shared_message_buffer: std.ArrayList(common.Message),

    receive_buffer: []u8,
    thread: ?std.Thread = null,
    run: bool = true,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !ServerContext {
        var shared_message_buffer = std.ArrayList(common.Message).init(allocator);
        var receive_buffer = try allocator.alloc(u8, 1024 * 16); // 16K

        return ServerContext{
            .shared_message_buffer_lock = std.Thread.Mutex{},
            .shared_message_buffer = shared_message_buffer,
            .receive_buffer = receive_buffer,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ServerContext) void {
        self.shared_message_buffer.deinit();
        self.allocator.free(self.receive_buffer);
    }
};

pub fn spawnThread(context: *ServerContext) !void {
    const config = std.Thread.SpawnConfig{};
    context.thread = try std.Thread.spawn(config, serverThreadFunc, .{context});
}

pub fn joinThread(context: *ServerContext) void {
    context.run = false;
    context.thread.?.detach();
    context.thread = null;
}

pub fn fetchMessages(context: *ServerContext, fetched: *std.ArrayList(common.Message)) !void {
    context.shared_message_buffer_lock.lock();
    try fetched.appendSlice(context.shared_message_buffer.items);
    context.shared_message_buffer_lock.unlock();
}

fn serverThreadFunc(context: *ServerContext) !void {
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

    mainServerThread(context, &client) catch |err| {
        std.debug.print("Client disconnected: {}\n", .{err});
    };
}

fn mainServerThread(context: *ServerContext, client: *network.Socket) !void {
    var receive_offset: usize = 0;
    while (context.run) {
        const len = try client.receive(context.receive_buffer[receive_offset..]);
        if (len == 0) {
            std.debug.print("Client disconnected. Exiting thread...\n", .{});
            break;
        }

        std.debug.print("got {} bytes...\n", .{len});
        _ = try client.send(context.receive_buffer[receive_offset..len]);

        context.shared_message_buffer_lock.lock();
        // TODO process recieved messages, moving the leftover bytes to the beginning of the buffer
        context.shared_message_buffer_lock.unlock();
    }
}

// TODO try integrating zig-network and get the server reading messages from the client
// each message has a standard header:
//
