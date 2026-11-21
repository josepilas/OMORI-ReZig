//! Stream and rewind externally supplied audio without a display/device.
const std = @import("std");
const Decoder = opaque {};
const Info = extern struct { sample_rate: c_uint, channels: c_int };
extern fn omori_audio_open_memory(data: [*]const u8, len: c_int, code: *c_int, unused: ?*anyopaque) ?*Decoder;
extern fn omori_audio_get_info(d: *Decoder) Info;
extern fn omori_audio_read(d: *Decoder, channels: c_int, out: [*]i16, samples: c_int) c_int;
extern fn omori_audio_seek_start(d: *Decoder) c_int;
extern fn omori_audio_close(d: *Decoder) void;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    for (args[1..]) |path| {
        const bytes = try std.fs.cwd().readFileAlloc(a, path, 256 * 1024 * 1024);
        defer a.free(bytes);
        var code: c_int = 0;
        const d = omori_audio_open_memory(bytes.ptr, @intCast(bytes.len), &code, null) orelse return error.DecodeFailed;
        defer omori_audio_close(d);
        const info = omori_audio_get_info(d);
        var pcm: [8192]i16 = undefined;
        var frames: u64 = 0;
        var peak: u32 = 0;
        while (true) {
            const n = omori_audio_read(d, info.channels, &pcm, pcm.len);
            if (n == 0) break;
            if (n < 0) return error.DecodeFailed;
            frames += @intCast(n);
            for (pcm[0..@as(usize, @intCast(n * info.channels))]) |sample| {
                peak = @max(peak, @as(u32, @intCast(@abs(@as(i32, sample)))));
            }
        }
        if (frames == 0 or peak == 0) return error.SilentOrEmpty;
        if (omori_audio_seek_start(d) != 1 or omori_audio_read(d, info.channels, &pcm, pcm.len) <= 0) return error.RewindFailed;
        std.debug.print("OK\t{d} Hz\t{d} channels\t{d} frames\tpeak {d}\t{s}\n", .{ info.sample_rate, info.channels, frames, peak, path });
    }
}
