//! Bounded JPEG bridge. Return allocator-owned RGBA just like PNG/VP8L.
const std = @import("std");
const Image = @import("vp8l.zig").Image;
extern fn stbi_info_from_memory(data: [*]const u8, len: c_int, x: *c_int, y: *c_int, channels: *c_int) c_int;
extern fn stbi_load_from_memory(data: [*]const u8, len: c_int, x: *c_int, y: *c_int, channels: *c_int, desired: c_int) ?[*]u8;
extern fn stbi_image_free(data: ?*anyopaque) void;

pub fn decode(a: std.mem.Allocator, encoded: []const u8) !Image {
    if (encoded.len > std.math.maxInt(c_int)) return error.TooLarge;
    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;
    const len: c_int = @intCast(encoded.len);
    if (stbi_info_from_memory(encoded.ptr, len, &w, &h, &channels) == 0) return error.BadJpeg;
    if (w <= 0 or h <= 0 or w > 16384 or h > 16384 or @as(u64, @intCast(w)) * @as(u64, @intCast(h)) > 64 * 1024 * 1024) return error.TooLarge;
    const pixels = stbi_load_from_memory(encoded.ptr, len, &w, &h, &channels, 4) orelse return error.BadJpeg;
    defer stbi_image_free(pixels);
    const bytes: usize = @as(usize, @intCast(w)) * @as(usize, @intCast(h)) * 4;
    return .{ .width = @intCast(w), .height = @intCast(h), .pixels = try a.dupe(u8, pixels[0..bytes]) };
}

test "JPEG: truncated data is rejected" {
    try std.testing.expectError(error.BadJpeg, decode(std.testing.allocator, "\xff\xd8\xff\xe0\x00"));
}
