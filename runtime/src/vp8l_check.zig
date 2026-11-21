//! VP8L decoder validation harness — decodes a payload image to raw RGBA
//! and prints a checksum per row band for byte-level comparison with the
//! reference decode (Pillow/libwebp). Usage:
//!   ./vp8l_check <file.webp-in-png-clothing> [--first N]
const std = @import("std");
const vp8l = @import("codec/vp8l.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const argv = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, argv);
    if (argv.len < 2) {
        std.debug.print("usage: vp8l_check <image> [max_bytes]\n", .{});
        return;
    }
    const path = argv[1];
    if (argv.len > 2 and std.mem.eql(u8, argv[2], "--debug")) {
        vp8l.debug_trace = true;
    }
    const data = try std.fs.cwd().readFileAlloc(alloc, path, 512 * 1024 * 1024);

    const dump_path = std.posix.getenv("VP8L_DUMP");
    if (std.posix.getenv("VP8L_TRACE_CODES") != null) vp8l.debug_trace = true;
    if (std.posix.getenv("VP8L_TRACE_ALL") != null) vp8l.trace_all = true;
    if (std.posix.getenv("VP8L_DUMP_PALETTE") != null) vp8l.dump_palette = true;
    if (std.posix.getenv("VP8L_DUMP_RAW") != null) vp8l.dump_raw_path = std.posix.getenv("VP8L_DUMP_RAW");

    const t0 = std.time.milliTimestamp();
    const img = vp8l.decode(alloc, data) catch |e| {
        std.debug.print("DECODE FAILED: {s}\n", .{@errorName(e)});
        std.process.exit(1);
    };
    const dt = std.time.milliTimestamp() - t0;

    // FNV-1a over the whole RGBA buffer + per-band checksums.
    var h: u64 = 0xcbf29ce484222325;
    for (img.pixels) |b| {
        h ^= b;
        h *%= 0x100000001b3;
    }
    var band_hashes: [16]u64 = .{0} ** 16;
    const band_size = img.pixels.len / 16 + 1;
    for (img.pixels, 0..) |b, i| {
        const band = i / band_size;
        if (band < 16) {
            band_hashes[band] ^= b;
            band_hashes[band] *%= 0x100000001b3;
        }
    }

    if (dump_path) |dp| {
        if (std.fs.createFileAbsolute(dp, .{})) |f| {
            var file = f;
            defer file.close();
            file.writeAll(img.pixels) catch {};
        } else |_| {}
    }
    std.debug.print("OK {d}x{d} rgba={d}B time={d}ms\n", .{ img.width, img.height, img.pixels.len, dt });
    std.debug.print("HASH fnv1a=0x{x:0>16}\n", .{h});
    for (band_hashes, 0..) |bh, i| {
        std.debug.print("BAND {d:0>2} 0x{x:0>16}\n", .{ i, bh });
    }
    // Sample pixels for quick eyeball checks.
    const samples = [_][2]u32{ .{ 0, 0 }, .{ 1, 0 }, .{ 100, 50 }, .{ 500, 300 } };
    for (samples) |pt| {
        if (pt[0] < img.width and pt[1] < img.height) {
            const idx = (pt[1] * img.width + pt[0]) * 4;
            std.debug.print("PX {d},{d} = {d},{d},{d},{d}\n", .{
                pt[0], pt[1], img.pixels[idx], img.pixels[idx + 1], img.pixels[idx + 2], img.pixels[idx + 3],
            });
        }
    }
}
