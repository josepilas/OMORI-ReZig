//! Offline native decoder/reference validation. Pass image paths, or --list
//! with a newline-delimited list of paths. Prints dimensions and RGBA SHA256.
//! Optional OMORI_IMAGE_DUMP writes the last decoded image as raw RGBA.
const std = @import("std");
const image_codec = @import("codec/image.zig");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    if (args.len == 3 and std.mem.eql(u8, args[1], "--list")) {
        const list = try std.fs.cwd().readFileAlloc(a, args[2], 4 * 1024 * 1024);
        defer a.free(list);
        var lines = std.mem.tokenizeAny(u8, list, "\r\n");
        while (lines.next()) |path| try check(a, path);
    } else {
        for (args[1..]) |path| try check(a, path);
    }
}

fn check(a: std.mem.Allocator, path: []const u8) !void {
    const encoded = try std.fs.cwd().readFileAlloc(a, path, 512 * 1024 * 1024);
    defer a.free(encoded);
    const image = image_codec.decode(a, encoded) catch |err| {
        std.debug.print("FAIL\t{s}\t{s}\n", .{ @errorName(err), path });
        return err;
    };
    defer a.free(image.pixels);
    var hash: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(image.pixels, &hash, .{});
    std.debug.print("OK\t{d}\t{d}\t{s}\t{s}\n", .{ image.width, image.height, std.fmt.bytesToHex(hash, .lower), path });
    if (std.posix.getenv("OMORI_IMAGE_DUMP")) |out| {
        var file = try std.fs.cwd().createFile(out, .{});
        defer file.close();
        try file.writeAll(image.pixels);
    }
}
