//! PC PNG decoder: checked chunks, bounded zlib expansion, all row filters,
//! palette/transparency and 1/2/4/8/16-bit samples. Returns RGBA8 pixels.
const std = @import("std");
pub const signature = "\x89PNG\r\n\x1a\n";
pub const Image = struct { width: u32, height: u32, pixels: []u8 };
pub const Error = error{ OutOfMemory, BadSignature, Truncated, BadCrc, BadHeader, Unsupported, BadPalette, BadData, TooLarge };
const max_pixels = 64 * 1024 * 1024;
const max_bytes = 512 * 1024 * 1024;
const Pass = struct { x: usize, y: usize, dx: usize, dy: usize };
const adam7 = [_]Pass{
    .{ .x = 0, .y = 0, .dx = 8, .dy = 8 }, .{ .x = 4, .y = 0, .dx = 8, .dy = 8 },
    .{ .x = 0, .y = 4, .dx = 4, .dy = 8 }, .{ .x = 2, .y = 0, .dx = 4, .dy = 4 },
    .{ .x = 0, .y = 2, .dx = 2, .dy = 4 }, .{ .x = 1, .y = 0, .dx = 2, .dy = 2 },
    .{ .x = 0, .y = 1, .dx = 1, .dy = 2 },
};
const plain = [_]Pass{.{ .x = 0, .y = 0, .dx = 1, .dy = 1 }};

pub fn decode(a: std.mem.Allocator, encoded: []const u8) Error!Image {
    if (!std.mem.startsWith(u8, encoded, signature)) return error.BadSignature;
    var w: usize = 0;
    var h: usize = 0;
    var depth: u8 = 0;
    var color: u8 = 0;
    var interlace: u8 = 0;
    var channels: usize = 0;
    var palette: []const u8 = &.{};
    var alpha: []const u8 = &.{};
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(a);
    var pos: usize = 8;
    var header = false;
    var ended = false;
    var started = false;
    var data_ended = false;
    while (pos < encoded.len) {
        if (encoded.len - pos < 12) return error.Truncated;
        const n: usize = be32(encoded[pos..][0..4]);
        if (n > encoded.len - pos - 12) return error.Truncated;
        const kind = encoded[pos + 4 ..][0..4];
        const bytes = encoded[pos + 8 ..][0..n];
        var crc = std.hash.Crc32.init();
        crc.update(kind);
        crc.update(bytes);
        if (crc.final() != be32(encoded[pos + 8 + n ..][0..4])) return error.BadCrc;
        pos += n + 12;
        if (!header and !std.mem.eql(u8, kind, "IHDR")) return error.BadHeader;
        if (std.mem.eql(u8, kind, "IHDR")) {
            if (header or n != 13) return error.BadHeader;
            w = be32(bytes[0..4]);
            h = be32(bytes[4..8]);
            depth = bytes[8];
            color = bytes[9];
            interlace = bytes[12];
            if (w == 0 or h == 0) return error.BadHeader;
            if (w > 16384 or h > 16384 or w * h > max_pixels) return error.TooLarge;
            if (bytes[10] != 0 or bytes[11] != 0 or interlace > 1) return error.Unsupported;
            channels = switch (color) {
                0 => 1,
                2 => 3,
                3 => 1,
                4 => 2,
                6 => 4,
                else => return error.Unsupported,
            };
            const valid = switch (color) {
                0 => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
                3 => depth == 1 or depth == 2 or depth == 4 or depth == 8,
                else => depth == 8 or depth == 16,
            };
            if (!valid) return error.Unsupported;
            header = true;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            if (started or palette.len > 0 or n == 0 or n > 768 or n % 3 != 0) return error.BadPalette;
            palette = bytes;
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            if (started or alpha.len > 0) return error.BadHeader;
            alpha = bytes;
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            if (data_ended) return error.BadData;
            started = true;
            if (n > max_bytes -| z.items.len) return error.TooLarge;
            try z.appendSlice(a, bytes);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            if (n != 0) return error.BadHeader;
            ended = true;
            break;
        } else {
            if (started) data_ended = true;
            if (kind[0] & 0x20 == 0) return error.Unsupported;
        }
    }
    if (!header or !ended or z.items.len < 6) return error.Truncated;
    if (color == 3 and palette.len == 0) return error.BadPalette;
    if (alpha.len > 0) switch (color) {
        0 => if (alpha.len != 2) return error.BadHeader,
        2 => if (alpha.len != 6) return error.BadHeader,
        3 => if (alpha.len > palette.len / 3) return error.BadPalette,
        else => return error.BadHeader,
    };
    const passes: []const Pass = if (interlace == 0) &plain else &adam7;
    var raw_len: usize = 0;
    for (passes) |p| {
        const pw = span(w, p.x, p.dx);
        const ph = span(h, p.y, p.dy);
        if (pw > 0 and ph > 0) raw_len += (rowBytes(pw, channels, depth) + 1) * ph;
    }
    if (raw_len > max_bytes) return error.TooLarge;
    var input: std.Io.Reader = .fixed(z.items);
    const history = try a.alloc(u8, std.compress.flate.max_window_len);
    defer a.free(history);
    var inflate: std.compress.flate.Decompress = .init(&input, .zlib, history);
    const pixels = try a.alloc(u8, w * h * 4);
    errdefer a.free(pixels);
    // Keep the working set independent of image height: two scanlines and
    // the fixed flate history, rather than a second full image allocation.
    const max_row = rowBytes(w, channels, depth);
    const scanline = try a.alloc(u8, max_row + 1);
    defer a.free(scanline);
    const previous = try a.alloc(u8, max_row);
    defer a.free(previous);
    var checksum: std.hash.Adler32 = .{};
    const bpp = @max(1, (channels * depth + 7) / 8);
    for (passes) |p| {
        const pw = span(w, p.x, p.dx);
        const ph = span(h, p.y, p.dy);
        if (pw == 0 or ph == 0) continue;
        const len = rowBytes(pw, channels, depth);
        for (0..ph) |y| {
            const filtered = scanline[0 .. len + 1];
            inflate.reader.readSliceAll(filtered) catch return error.BadData;
            checksum.update(filtered);
            const row = filtered[1..];
            try unfilter(row, if (y == 0) &.{} else previous[0..len], bpp, filtered[0]);
            for (0..pw) |x| {
                const out = pixels[((p.y + y * p.dy) * w + p.x + x * p.dx) * 4 ..][0..4];
                const r = sample(row, x * channels, depth);
                switch (color) {
                    0 => {
                        const g = eight(r, depth);
                        out.* = .{ g, g, g, if (alpha.len > 0 and r == be16(alpha[0..2])) 0 else 255 };
                    },
                    2 => {
                        const g = sample(row, x * channels + 1, depth);
                        const b = sample(row, x * channels + 2, depth);
                        out.* = .{ eight(r, depth), eight(g, depth), eight(b, depth), if (alpha.len > 0 and r == be16(alpha[0..2]) and g == be16(alpha[2..4]) and b == be16(alpha[4..6])) 0 else 255 };
                    },
                    3 => {
                        const i: usize = r;
                        if (i >= palette.len / 3) return error.BadPalette;
                        out.* = .{ palette[i * 3], palette[i * 3 + 1], palette[i * 3 + 2], if (i < alpha.len) alpha[i] else 255 };
                    },
                    4 => {
                        const g = eight(r, depth);
                        out.* = .{ g, g, g, eight(sample(row, x * channels + 1, depth), depth) };
                    },
                    6 => out.* = .{ eight(r, depth), eight(sample(row, x * channels + 1, depth), depth), eight(sample(row, x * channels + 2, depth), depth), eight(sample(row, x * channels + 3, depth), depth) },
                    else => unreachable,
                }
            }
            @memcpy(previous[0..len], row);
        }
    }
    if (inflate.reader.takeByte()) |_| return error.BadData else |e| {
        if (e != error.EndOfStream or inflate.err != null) return error.BadData;
    }
    const expected = be32(z.items[z.items.len - 4 ..][0..4]);
    // One supplied PC sprite was authored with a non-reduced Adler sum:
    // s1=65521 represents zero modulo 65521. Accept only the equivalent
    // modular representation; chunk CRCs and decoded-length checks remain.
    const canonical = (((expected >> 16) % 65521) << 16) | ((expected & 0xffff) % 65521);
    if (checksum.adler != canonical) return error.BadData;
    return .{ .width = @intCast(w), .height = @intCast(h), .pixels = pixels };
}
fn be32(b: *const [4]u8) u32 {
    return std.mem.readInt(u32, b, .big);
}
fn be16(b: *const [2]u8) u16 {
    return std.mem.readInt(u16, b, .big);
}
fn span(size: usize, start: usize, step: usize) usize {
    return if (size <= start) 0 else (size - start + step - 1) / step;
}
fn rowBytes(w: usize, c: usize, d: u8) usize {
    return (w * c * d + 7) / 8;
}
fn sample(row: []const u8, i: usize, d: u8) u16 {
    if (d == 16) return be16(row[i * 2 ..][0..2]);
    if (d == 8) return row[i];
    const bit = i * d;
    const shift: u3 = @intCast(8 - d - bit % 8);
    return (row[bit / 8] >> shift) & ((@as(u16, 1) << @as(u4, @intCast(d))) - 1);
}
fn eight(v: u16, d: u8) u8 {
    if (d == 16) return @intCast(v >> 8);
    return @intCast(@as(u32, v) * 255 / ((@as(u32, 1) << @as(u5, @intCast(d))) - 1));
}
fn paeth(a: u8, b: u8, c: u8) u8 {
    const p = @as(i32, a) + b - c;
    const da = @abs(p - a);
    const db = @abs(p - b);
    const dc = @abs(p - c);
    return if (da <= db and da <= dc) a else if (db <= dc) b else c;
}
fn unfilter(row: []u8, prev: []const u8, bpp: usize, f: u8) Error!void {
    if (f > 4) return error.BadData;
    for (row, 0..) |*v, i| {
        const a: u8 = if (i >= bpp) row[i - bpp] else 0;
        const b: u8 = if (prev.len > 0) prev[i] else 0;
        const c: u8 = if (i >= bpp and prev.len > 0) prev[i - bpp] else 0;
        v.* +%= switch (f) {
            0 => 0,
            1 => a,
            2 => b,
            3 => @intCast((@as(u16, a) + b) / 2),
            4 => paeth(a, b, c),
            else => unreachable,
        };
    }
}

fn fixture(a: std.mem.Allocator, w: u32, h: u32, d: u8, c: u8, inter: u8, rows: []const u8, pal: []const u8, alpha: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, signature);
    var ihdr: [13]u8 = @splat(0);
    std.mem.writeInt(u32, ihdr[0..4], w, .big);
    std.mem.writeInt(u32, ihdr[4..8], h, .big);
    ihdr[8] = d;
    ihdr[9] = c;
    ihdr[12] = inter;
    try chunk(a, &out, "IHDR", &ihdr);
    if (pal.len > 0) try chunk(a, &out, "PLTE", pal);
    if (alpha.len > 0) try chunk(a, &out, "tRNS", alpha);
    var z: std.ArrayList(u8) = .empty;
    defer z.deinit(a);
    try z.appendSlice(a, &.{ 0x78, 0x01, 0x01 });
    const n: u16 = @intCast(rows.len);
    var lens: [4]u8 = undefined;
    std.mem.writeInt(u16, lens[0..2], n, .little);
    std.mem.writeInt(u16, lens[2..4], ~n, .little);
    try z.appendSlice(a, &lens);
    try z.appendSlice(a, rows);
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, std.hash.Adler32.hash(rows), .big);
    try z.appendSlice(a, &adler);
    try chunk(a, &out, "IDAT", z.items);
    try chunk(a, &out, "IEND", &.{});
    return out.toOwnedSlice(a);
}
fn chunk(a: std.mem.Allocator, out: *std.ArrayList(u8), kind: *const [4]u8, b: []const u8) !void {
    var n: [4]u8 = undefined;
    std.mem.writeInt(u32, &n, @intCast(b.len), .big);
    try out.appendSlice(a, &n);
    try out.appendSlice(a, kind);
    try out.appendSlice(a, b);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(b);
    std.mem.writeInt(u32, &n, crc.final(), .big);
    try out.appendSlice(a, &n);
}

test "PNG: equivalent noncanonical Adler sum in supplied PC sprite" {
    const a = std.testing.allocator;
    var row: [259]u8 = @splat(255);
    row[0] = 0;
    row[1] = 0;
    row[2] = 240;
    try std.testing.expectEqual(@as(u32, 0), std.hash.Adler32.hash(&row) & 0xffff);
    const encoded = try fixture(a, 258, 1, 8, 0, 0, &row, &.{}, &.{});
    defer a.free(encoded);
    const n: usize = be32(encoded[33..37]);
    const footer = encoded[41 + n - 4 ..][0..4];
    std.mem.writeInt(u32, footer, be32(footer) | 65521, .big);
    const crc = std.hash.Crc32.hash(encoded[37 .. 41 + n]);
    std.mem.writeInt(u32, encoded[41 + n ..][0..4], crc, .big);
    const image = try decode(a, encoded);
    defer a.free(image.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 240, 240, 240, 255 }, image.pixels[0..8]);
}

test "PNG: all row filters reconstruct identical RGB pixels" {
    const a = std.testing.allocator;
    const rgb = [_]u8{ 10, 20, 30, 60, 70, 80, 5, 10, 15, 100, 110, 120 };
    const expected = [_]u8{ 10, 20, 30, 255, 60, 70, 80, 255, 5, 10, 15, 255, 100, 110, 120, 255 };
    for (0..5) |f| {
        var rows: [14]u8 = undefined;
        for (0..2) |y| {
            rows[y * 7] = @intCast(f);
            for (0..6) |x| {
                const left: u8 = if (x >= 3) rgb[y * 6 + x - 3] else 0;
                const up: u8 = if (y > 0) rgb[x] else 0;
                const corner: u8 = if (y > 0 and x >= 3) rgb[x - 3] else 0;
                const prediction: u8 = switch (f) {
                    0 => 0,
                    1 => left,
                    2 => up,
                    3 => @intCast((@as(u16, left) + up) / 2),
                    4 => paeth(left, up, corner),
                    else => unreachable,
                };
                rows[y * 7 + x + 1] = rgb[y * 6 + x] -% prediction;
            }
        }
        const file = try fixture(a, 2, 2, 8, 2, 0, &rows, &.{}, &.{});
        defer a.free(file);
        const img = try decode(a, file);
        defer a.free(img.pixels);
        try std.testing.expectEqualSlices(u8, &expected, img.pixels);
    }
}
test "PNG: packed indexed pixels and grayscale transparency" {
    const a = std.testing.allocator;
    const file = try fixture(a, 4, 1, 2, 3, 0, &.{ 0, 0b00011011 }, &.{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 255, 255, 255 }, &.{ 255, 128, 0, 255 });
    defer a.free(file);
    const img = try decode(a, file);
    defer a.free(img.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0, 255, 255, 255, 255 }, img.pixels);
    const gray = try fixture(a, 2, 1, 1, 0, 0, &.{ 0, 0b01000000 }, &.{}, &.{ 0, 1 });
    defer a.free(gray);
    const g = try decode(a, gray);
    defer a.free(g.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255, 255, 255, 255, 0 }, g.pixels);
}
test "PNG: RGBA16 and Adam7 pixels" {
    const a = std.testing.allocator;
    const file = try fixture(a, 1, 1, 16, 6, 0, &.{ 0, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0 }, &.{}, &.{});
    defer a.free(file);
    const img = try decode(a, file);
    defer a.free(img.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 0x12, 0x56, 0x9a, 0xde }, img.pixels);
    const inter = try fixture(a, 2, 2, 8, 6, 1, &.{ 0, 1, 2, 3, 4, 0, 5, 6, 7, 8, 0, 9, 10, 11, 12, 13, 14, 15, 16 }, &.{}, &.{});
    defer a.free(inter);
    const g = try decode(a, inter);
    defer a.free(g.pixels);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }, g.pixels);
}
test "PNG: corrupt chunks and filters fail without leaks" {
    const a = std.testing.allocator;
    const file = try fixture(a, 1, 1, 8, 6, 0, &.{ 0, 1, 2, 3, 4 }, &.{}, &.{});
    defer a.free(file);
    file[29] ^= 1;
    try std.testing.expectError(error.BadCrc, decode(a, file));
    file[29] ^= 1;
    try std.testing.expectError(error.Truncated, decode(a, file[0 .. file.len - 1]));
    const bad = try fixture(a, 1, 1, 8, 6, 0, &.{ 5, 1, 2, 3, 4 }, &.{}, &.{});
    defer a.free(bad);
    try std.testing.expectError(error.BadData, decode(a, bad));
}
