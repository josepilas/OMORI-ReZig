//! Images are selected by their bytes: Android stores VP8L in .png files,
//! while PC data uses PNG and some JPEG. All produce caller-owned RGBA8 pixels.
const std = @import("std");
const vp8l = @import("vp8l.zig");
const png = @import("png.zig");
const jpeg = @import("jpeg.zig");
pub const Image = vp8l.Image;

pub fn decode(alloc: std.mem.Allocator, encoded: []const u8) !Image {
    if (std.mem.startsWith(u8, encoded, "\xff\xd8\xff")) return jpeg.decode(alloc, encoded);
    if (std.mem.startsWith(u8, encoded, png.signature)) {
        const image = try png.decode(alloc, encoded);
        return .{ .width = image.width, .height = image.height, .pixels = image.pixels };
    }
    return vp8l.decode(alloc, encoded);
}
