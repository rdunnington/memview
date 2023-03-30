const std = @import("std");
const StringPool = @import("stringpool.zig");

// pub const MessageChannel = std.event.Channel(Message);

pub const MessageType = enum(u8) {
    Identifier,
    Region,
    Frame,
    Alloc,
};

// Used for strings such as regions and callstacks
pub const Identifier = struct {
    name: []const u8,

    pub fn calcHash(str: []const u8) u64 {
        return std.hash_map.hashString(str);
    }
};

pub const Region = struct {
    id_hash: u64, // name
    address: u64,
    size: u64,
};

pub const Frame = struct {
    timestamp: u64,
};

pub const Alloc = struct {
    id_hash: u64, // callstack
    address: u64,
    size: u64,
    timestamp: u64,
    region: u64,
};

pub const Message = union(MessageType) {
    Identifier: Identifier,
    Region: Region,
    Frame: Frame,
    Alloc: Alloc,

    pub fn calcTotalSize(self: *const Message) usize {
        return self.calcBodySize() + 1 + 2; // 1 byte for size, 2 bytes for body length
    }

    fn calcBodySize(self: *const Message) usize {
        return switch (self) {
            .Identifier => |v| v.str.len + @sizeOf(u16), // identifier lengths are never longer than a u16 can hold
            .Region => @sizeOf(u64) * 3,
            .Frame => @sizeOf(u64),
            .Alloc => @sizeOf(u64) * 5,
        };
    }

    // returns number of messages written to the buffer
    pub fn write(self: *const Message, buffer: std.ArrayList(u8)) void {
        // var fbs = std.io.fixedBufferStream(buffer);
        var writer = buffer.writer();

        // var messages_written: u32 = 0;

        // for (messages) |*msg| {
        //     const msg_size: usize = msg.calcSize();
        //     const msg_and_header_size = msg_size + @sizeOf(u8) + @sizeOf(u16);
        //     const buffer_bytes_left = fbs.getEndPos() - fbs.pos;
        //     if (buffer_bytes_left < msg_and_header_size) {
        //         return messages_written;
        //     }

        //     if (msg_size > std.math.maxInt(u16)) {
        //         unreachable;
        //     }

        const msg_size = @intCast(u16, self.calcBodySize());

        writer.writeByte(@enumToInt(std.meta.activeTag(self))) catch unreachable;
        writer.writeIntLittle(u16, msg_size) catch unreachable;

        // const pos = fbs.pos;

        switch (self) {
            .Identifier => |v| {
                writer.writeIntLittle(u16, @intCast(u16, v.name.len)) catch unreachable;
                writer.write(v.name) catch unreachable;
            },
            .Region => |v| {
                writer.writeIntLittle(u64, v.id) catch unreachable;
                writer.writeIntLittle(u64, v.address) catch unreachable;
                writer.writeIntLittle(u64, v.size) catch unreachable;
            },
            .Frame => |v| {
                writer.writeIntLittle(u64, v.timestamp) catch unreachable;
            },
            .Alloc => |v| {
                writer.writeIntLittle(u64, v.callstack_id) catch unreachable;
                writer.writeIntLittle(u64, v.address) catch unreachable;
                writer.writeIntLittle(u64, v.size) catch unreachable;
                writer.writeIntLittle(u64, v.timestamp) catch unreachable;
                writer.writeIntLittle(u64, v.region) catch unreachable;
            },
        }

        //     messages_written += 1;

        //     const actual_msg_size = fbs.pos - pos;
        //     std.debug.assert(msg_size == actual_msg_size);
        // }

        // return fbs.pos;
    }

    pub fn read(buffer: []u8, messages: *std.ArrayList(Message), strpool: *StringPool) !usize {
        var fbs = std.io.fixedBufferStream(buffer);
        var reader = fbs.reader();

        var consumed_bytes: usize = 0;

        while (true) {
            const msg_type = @intToEnum(MessageType, reader.readByte() catch unreachable);
            const msg_size = reader.readIntLittle(u16) catch break;
            if (buffer.len - fbs.pos < msg_size) {
                break;
            }

            var msg: Message = undefined;

            switch (msg_type) {
                .Identifier => {
                    const strlen = reader.readIntLittle(u16) catch unreachable;
                    const str = fbs.buffer[fbs.pos .. fbs.pos + strlen];
                    const strpool_str = try strpool.put(str);
                    fbs.seekBy(strlen) catch unreachable;

                    msg = Message{
                        .Identifier = .{
                            .name = strpool_str,
                        },
                    };
                },
                .Region => {
                    const id_hash = reader.readIntLittle(u64) catch unreachable;
                    const address = reader.readIntLittle(u64) catch unreachable;
                    const size = reader.readIntLittle(u64) catch unreachable;
                    msg = Message{
                        .Region = .{
                            .id_hash = id_hash,
                            .address = address,
                            .size = size,
                        },
                    };
                },
                .Frame => {
                    const timestamp = reader.readIntLittle(u64) catch unreachable;
                    msg = Message{
                        .Frame = .{
                            .timestamp = timestamp,
                        },
                    };
                },
                .Alloc => {
                    const callstack_id = reader.readIntLittle(u64) catch unreachable;
                    const address = reader.readIntLittle(u64) catch unreachable;
                    const size = reader.readIntLittle(u64) catch unreachable;
                    const timestamp = reader.readIntLittle(u64) catch unreachable;
                    const region = reader.readIntLittle(u64) catch unreachable;
                    msg = Message{
                        .Alloc = .{
                            .id_hash = callstack_id,
                            .address = address,
                            .size = size,
                            .timestamp = timestamp,
                            .region = region,
                        },
                    };
                },
            }

            try messages.append(msg);

            consumed_bytes = fbs.pos;
        }

        return consumed_bytes;
    }
};

// need a stringpool to hold names
// need a mapping of u64 id -> stringpool string (maybe add findByHash() func for stringpool)

// const DefMappings = struct {
//     regions: std.AutoHashMap(u64, []const u8),
//     bookmarks: std.AutoHashMap(u64, []const u8),
//     regions: std.AutoHashMap(Identifier),
// };
