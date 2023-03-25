const std = @import("std");

// pub const MessageChannel = std.event.Channel(Message);

pub const MessageType = enum(u8) {
    Int64,
    String,
    Int64AndString,
};

pub const Message = union(MessageType) {
    Int64: u64,
    String: []u8,
    Int64AndString: struct {
        v: u64,
        str: []u8,
    },

    // fn write(buffer: []u8, message: *const Message) void {
    //     // write header:
    //     // 1 byte for message type
    //     // 2 bytes for the size of the rest of the message
    // }

    // fn read(buffer: []u8, messages: *std.ArrayList(Message)) usize {
    //     // return num bytes consumed from buffer
    // }
};
