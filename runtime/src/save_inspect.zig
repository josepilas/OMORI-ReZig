//! Inspect an external native/MV save without modifying it.
const std = @import("std");
const save = @import("mv/save.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = try std.process.argsAlloc(a);
    const encode = args.len == 4 and std.mem.eql(u8, args[1], "--encode");
    if (!encode and args.len != 3) return error.ExpectedInputAndJsonOutput;
    const input = try std.fs.cwd().readFileAlloc(a, args[if (encode) 2 else 1], 32 * 1024 * 1024);
    const output = if (encode) try save.compressToBase64(a, input) else (try save.decompressFromBase64(a, input)) orelse return error.InvalidSave;
    var out = try std.fs.cwd().createFile(args[if (encode) 3 else 2], .{});
    defer out.close();
    try out.writeAll(output);
}
