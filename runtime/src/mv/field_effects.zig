//! Field weather and screen-space picture transforms on the logical canvas.
const std = @import("std");
const draw = @import("../renderer/draw.zig");
const game = @import("game.zig");
const sprites = @import("sprites.zig");

pub fn drawPicture(dl: *draw.DrawList, picture: *const game.GameScreen.Picture, image: sprites.Sprite) void {
    const width = scaledSize(image.width, picture.scale_x);
    const height = scaledSize(image.height, picture.scale_y);
    if (width == 0 or height == 0 or picture.opacity <= 0) return;
    const centered = picture.origin == 1;
    const left = if (centered) @divTrunc(width, 2) else if (picture.scale_x < 0) width else 0;
    const top = if (centered) @divTrunc(height, 2) else if (picture.scale_y < 0) height else 0;
    dl.pushTransformed(image.handle, image.src, .{ .x = picture.x -| left, .y = picture.y -| top, .w = width, .h = height }, @intCast(@min(picture.opacity, 255)), .{
        .angle = picture.angle,
        .pivot = .{ .x = left, .y = top },
        .flip = @as(c_int, @intFromBool(picture.scale_x < 0)) + 2 * @as(c_int, @intFromBool(picture.scale_y < 0)),
        .additive = picture.blend_mode == 1,
    });
}

fn scaledSize(size: i32, scale: i32) i32 {
    return @intCast(@min(@abs(@divTrunc(@as(i64, size) * scale, 100)), std.math.maxInt(i32)));
}

// One small immutable texture per shape. A full-strength effect is at most
// ninety sprites and all drops share a single texture upload.
fn weatherPixels(comptime snow: bool) [4 * 12 * 4]u8 {
    var pixels = [_]u8{0} ** (4 * 12 * 4);
    for (0..12) |y| for (0..4) |x| {
        const visible = if (snow) y < 4 and ((x == 1 or x == 2) or (y == 1 or y == 2)) else x == 3 - y / 3;
        if (visible) pixels[(y * 4 + x) * 4 ..][0..4].* = .{255,255,255, if (snow) 225 else @intCast(80 + y * 14)};
    };
    return pixels;
}
const rain_pixels = weatherPixels(false);
const snow_pixels = weatherPixels(true);

pub fn drawWeather(dl: *draw.DrawList, screen: *const game.GameScreen, frame: u64, camera_x: f64, camera_y: f64) void {
    if (screen.weather_power <= 0) return;
    const snow = std.mem.eql(u8, screen.weather_type, "snow");
    const storm = std.mem.eql(u8, screen.weather_type, "storm");
    if (!snow and !storm and !std.mem.eql(u8, screen.weather_type, "rain")) return;
    const count: usize = @intFromFloat(@floor(std.math.clamp(screen.weather_power, 0, 9) * 10));
    if (count == 0) return;
    dl.pushFill(0, 0, 0, @intCast(count * 6 / 10));
    const surface = draw.Surface{ .width = 4, .height = 12, .pixels = if (snow) &snow_pixels else &rain_pixels };
    const handle = dl.addSurface(&surface);
    const tick: i64 = @intCast(frame % (656 * 512));
    const ox: i64 = @intFromFloat(@mod(camera_x, 656));
    const oy: i64 = @intFromFloat(@mod(camera_y, 512));
    for (0..count) |index| {
        const seed = (@as(u32,@intCast(index)) + 1) *% 2654435761;
        const speed: i64 = if (snow) 2 else if (storm) 11 else 7;
        const drift = if (snow) @divTrunc(tick, 2) else tick * @divTrunc(speed, 3);
        const x: i32 = @intCast(@mod(@as(i64,seed >> 16) - drift - ox, 656) - 8);
        const y: i32 = @intCast(@mod(@as(i64,seed & 65535) + tick * speed - oy, 512) - 24);
        const h: i32 = if (snow) 3 else if (storm) 22 else 12;
        dl.pushSpriteStable(handle, .{ .x = 0, .y = 0, .w = 4, .h = if (snow) 4 else 12 }, .{ .x=x,.y=y,.w=if (storm) 7 else if (snow) 3 else 4,.h=h }, @intCast(100 + seed % 151));
    }
}
