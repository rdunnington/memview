const std = @import("std");
const memview = @import("memview");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    var gpa_allocator = gpa.allocator();

    var memview_buffer = try gpa_allocator.alloc(u8, 1024 * 1024 * 8);
    defer gpa_allocator.free(memview_buffer);

    var memview_host = try memview.HostContext.init(memview_buffer, .{});
    defer memview_host.deinit();

    memview_host.waitForConnection();

    var allocator = memview_host.instrument(gpa_allocator).?;

    // read contents of file into memory and make an allocation for every paragraph
    var args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var paragraphs = std.ArrayList([]u8).init(allocator);
    defer paragraphs.deinit();
    try paragraphs.ensureTotalCapacity(256);

    var file_data = try std.fs.cwd().readFileAlloc(allocator, args[1], 1024 * 1024 * 8);
    defer allocator.free(file_data);

    var iter = std.mem.tokenize(u8, file_data, "\n");
    while (iter.next()) |bytes| {
        if (bytes.len == 0) {
            continue;
        }

        if (paragraphs.items.len < paragraphs.capacity) {
            var duped = try allocator.dupe(u8, bytes);
            paragraphs.appendAssumeCapacity(duped);
        } else {
            var shortest_paragraph_index: usize = std.math.maxInt(usize);
            for (paragraphs.items, 0..) |para, i| {
                if (paragraphs.items.len < shortest_paragraph_index or para.len < paragraphs.items[shortest_paragraph_index].len) {
                    shortest_paragraph_index = i;
                }
            }

            if (paragraphs.items.len < shortest_paragraph_index or paragraphs.items[shortest_paragraph_index].len < bytes.len) {
                if (shortest_paragraph_index < paragraphs.items.len) {
                    allocator.free(paragraphs.items[shortest_paragraph_index]);
                }
                paragraphs.items[shortest_paragraph_index] = try allocator.dupe(u8, bytes);
            }
        }
    }

    for (paragraphs.items) |para| {
        allocator.free(para);
    }
}
