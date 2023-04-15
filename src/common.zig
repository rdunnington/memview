const std = @import("std");
const StringPool = @import("stringpool.zig");

// pub const MessageChannel = std.event.Channel(Message);

pub const MessageType = enum(u8) {
    Identifier,
    Region,
    Frame,
    Stack,
    Alloc,
    Free,
};

// Used for strings such as regions and callstacks
pub const Identifier = struct {
    name: []const u8,

    pub fn calcHash(str: []const u8) u64 {
        return std.hash_map.hashString(str);
    }
};

// TODO rename to Allocator
pub const Region = struct {
    id_hash: u64, // name
    address: u64,
    size: u64,
};

pub const Frame = struct {
    timestamp: u64,
};

pub const Stack = struct {
    stack_id: u64,
    string: []const u8,
};

pub const Alloc = struct {
    stack_id: u64, // callstack
    address: u64,
    size: u64,
    timestamp: u64,
    region: u64,
};

pub const Free = struct {
    address: u64,
    timestamp: u64,
};

pub const Message = union(MessageType) {
    Identifier: Identifier,
    Region: Region,
    Frame: Frame,
    Stack: Stack,
    Alloc: Alloc,
    Free: Free,

    pub fn calcTotalSize(self: *const Message) usize {
        return self.calcBodySize() + 1 + 2; // 1 byte for size, 2 bytes for body length
    }

    fn calcBodySize(self: *const Message) usize {
        return switch (self.*) {
            .Identifier => |v| v.name.len + @sizeOf(u16), // identifier lengths are never longer than a u16 can hold
            .Region => @sizeOf(u64) * 3,
            .Frame => @sizeOf(u64),
            .Stack => |v| @sizeOf(u64) + @sizeOf(u16) + v.string.len,
            .Alloc => @sizeOf(u64) * 5,
            .Free => @sizeOf(u64) * 2,
        };
    }

    pub fn write(self: *const Message, buffer: *std.ArrayList(u8)) void {
        var writer = buffer.writer();

        const msg_size = @intCast(u16, self.calcBodySize());

        writer.writeByte(@enumToInt(std.meta.activeTag(self.*))) catch unreachable;
        writer.writeIntLittle(u16, msg_size) catch unreachable;

        switch (self.*) {
            .Identifier => |v| {
                writer.writeIntLittle(u16, @intCast(u16, v.name.len)) catch unreachable;
                _ = writer.write(v.name) catch unreachable;
            },
            .Region => |v| {
                writer.writeIntLittle(u64, v.id_hash) catch unreachable;
                writer.writeIntLittle(u64, v.address) catch unreachable;
                writer.writeIntLittle(u64, v.size) catch unreachable;
            },
            .Frame => |v| {
                writer.writeIntLittle(u64, v.timestamp) catch unreachable;
            },
            .Stack => |v| {
                writer.writeIntLittle(u64, v.stack_id) catch unreachable;
                writer.writeIntLittle(u16, @intCast(u16, v.string.len)) catch unreachable;
                _ = writer.write(v.string) catch unreachable;
            },
            .Alloc => |v| {
                writer.writeIntLittle(u64, v.stack_id) catch unreachable;
                writer.writeIntLittle(u64, v.address) catch unreachable;
                writer.writeIntLittle(u64, v.size) catch unreachable;
                writer.writeIntLittle(u64, v.timestamp) catch unreachable;
                writer.writeIntLittle(u64, v.region) catch unreachable;
            },
            .Free => |v| {
                writer.writeIntLittle(u64, v.address) catch unreachable;
                writer.writeIntLittle(u64, v.timestamp) catch unreachable;
            },
        }
    }

    pub fn read(buffer: []u8, messages: *std.ArrayList(Message), strpool: *StringPool) !usize {
        var fbs = std.io.fixedBufferStream(buffer);
        var reader = fbs.reader();

        var consumed_bytes: usize = 0;

        while (true) {
            const msg_type_raw = reader.readByte() catch break;
            // std.debug.print("found raw msg type {} at offset {}\n", .{ msg_type_raw, fbs.pos - 1 });
            const msg_type = @intToEnum(MessageType, msg_type_raw);
            const msg_size = reader.readIntLittle(u16) catch break;
            if (buffer.len - fbs.pos < msg_size) {
                break;
            }

            var msg: Message = undefined;

            switch (msg_type) {
                .Identifier => {
                    const str = try readstr(&fbs, strpool) orelse break;
                    msg = Message{
                        .Identifier = .{
                            .name = str,
                        },
                    };
                },
                .Region => {
                    const id_hash = reader.readIntLittle(u64) catch break;
                    const address = reader.readIntLittle(u64) catch break;
                    const size = reader.readIntLittle(u64) catch break;
                    msg = Message{
                        .Region = .{
                            .id_hash = id_hash,
                            .address = address,
                            .size = size,
                        },
                    };
                },
                .Frame => {
                    const timestamp = reader.readIntLittle(u64) catch break;
                    msg = Message{
                        .Frame = .{
                            .timestamp = timestamp,
                        },
                    };
                },
                .Stack => {
                    const stack_id = reader.readIntLittle(u64) catch break;
                    const str = try readstr(&fbs, strpool) orelse break;
                    std.debug.print("got stack msg with id 0x{X} and str:\n\t{s}\n", .{ stack_id, str });
                    msg = Message{
                        .Stack = .{
                            .stack_id = stack_id,
                            .string = str,
                        },
                    };
                },
                .Alloc => {
                    const stack_id = reader.readIntLittle(u64) catch break;
                    const address = reader.readIntLittle(u64) catch break;
                    const size = reader.readIntLittle(u64) catch break;
                    const timestamp = reader.readIntLittle(u64) catch break;
                    const region = reader.readIntLittle(u64) catch break;
                    msg = Message{
                        .Alloc = .{
                            .stack_id = stack_id,
                            .address = address,
                            .size = size,
                            .timestamp = timestamp,
                            .region = region,
                        },
                    };
                },
                .Free => {
                    const address = reader.readIntLittle(u64) catch break;
                    const timestamp = reader.readIntLittle(u64) catch break;
                    msg = Message{
                        .Free = .{
                            .address = address,
                            .timestamp = timestamp,
                        },
                    };
                },
            }

            // std.debug.print("got msg: {}\n", .{msg});

            try messages.append(msg);

            consumed_bytes = fbs.pos;
        }

        return consumed_bytes;
    }

    fn readstr(fbs: anytype, strpool: *StringPool) !?[]const u8 {
        var reader = fbs.reader();

        const strlen = reader.readIntLittle(u16) catch return null;
        const str = fbs.buffer[fbs.pos .. fbs.pos + strlen];
        const strpool_str = try strpool.put(str);
        fbs.seekBy(strlen) catch null;
        return strpool_str;
    }
};
