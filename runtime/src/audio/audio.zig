//! Native audio subsystem — lazy, streaming-oriented design (§11).
//!
//! **Evidence from the existing project:** the global audio preload
//! contributed measurably to the RK3326 memory pressure; the low-memory
//! profile neutralized the system-audio preload while keeping the plugin
//! API. The native design: register audio identities, decode/play on
//! demand, stream BGM, release when unused.
//!
//! Honest milestone scope: the identity/registry/lifetime layer with
//! device probing. Actual mixing output goes through SDL2 audio (dlopen)
//! in the audio milestone; nothing here claims playback yet.

const std = @import("std");
const vfs_mod = @import("../filesystem/vfs.zig");
const omori_paths = @import("../omori/paths.zig");
const log = @import("../core/log.zig");

pub const Channel = enum {
    bgm,
    bgs,
    me,
    se,
};

pub const AudioError = error{
    NotFound,
    OutOfMemory,
};

/// The audio identity registry: which files exist where, lazy by design.
pub const AudioManager = struct {
    allocator: std.mem.Allocator,
    vfs: *vfs_mod.Vfs,
    /// channel/key → resolved physical path (owned).
    resolved: std.StringHashMap([]const u8),
    /// Statistics for the §25 diagnostics contract.
    loads: u64 = 0,
    releases: u64 = 0,
    audio_bytes_current: u64 = 0,
    audio_bytes_peak: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, vfs: *vfs_mod.Vfs) AudioManager {
        return .{
            .allocator = alloc,
            .vfs = vfs,
            .resolved = std.StringHashMap([]const u8).init(alloc),
        };
    }

    pub fn deinit(self: *AudioManager) void {
        var it = self.resolved.iterator();
        while (it.next()) |e| {
            self.allocator.free(e.key_ptr.*);
            self.allocator.free(e.value_ptr.*);
        }
        self.resolved.deinit();
    }

    /// MV audio folder for a channel.
    fn folderFor(channel: Channel) []const u8 {
        return switch (channel) {
            .bgm => "audio/bgm",
            .bgs => "audio/bgs",
            .me => "audio/me",
            .se => "audio/se",
        };
    }

    /// MV tries extensions in order (ogg, m4a, aac, wav...) — the payload
    /// ships ogg + m4a; native probing mirrors `Utils.checkExtension`.
    const extensions = [_][]const u8{ "ogg", "m4a", "aac", "wav", "mp3" };

    /// Resolve (not load) an audio identity — the lazy contract.
    ///
    /// v32 OWNERSHIP CONTRACT (the v31 title-screen crash): the returned
    /// slice is a BORROW from this manager's `resolved` cache map — the
    /// exact same pointer is stored as the map's value. It is freed by
    /// `deinit()` (or `release()`), ONCE. Callers MUST NOT free it
    /// themselves: the v31 mixer's `loadFileBytes` did exactly that
    /// (`defer free(path)` + the map's deinit free) — a double free the
    /// arena masked in v30 and that the GPA turned into a SIGSEGV in v31
    /// (the second free's `Allocator.free` poison-memset hit a page the
    /// GPA had just unmapped).
    pub fn resolve(self: *AudioManager, channel: Channel, name: []const u8) AudioError!?[]const u8 {
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}/{s}", .{ folderFor(channel), name }) catch
            return AudioError.OutOfMemory;
        if (self.resolved.get(key)) |path| return path;

        for (extensions) |ext| {
            var candidate_buf: [640]u8 = undefined;
            const candidate = std.fmt.bufPrint(&candidate_buf, "{s}.{s}", .{ key, ext }) catch
                return AudioError.OutOfMemory;
            if (omori_paths.resolveAssetPath(self.allocator, self.vfs, candidate)) |maybe| {
                if (maybe) |physical| {
                    const key_copy = self.allocator.dupe(u8, key) catch return AudioError.OutOfMemory;
                    self.resolved.put(key_copy, physical) catch {
                        self.allocator.free(key_copy);
                        self.allocator.free(physical);
                        return AudioError.OutOfMemory;
                    };
                    return physical;
                }
            } else |_| {
                return AudioError.OutOfMemory;
            }
        }
        return null;
    }

    /// The explicit lifetime contract (§11 "release when no longer
    /// needed") — placeholder until the SDL mixer milestone; counters
    /// make the policy observable in diagnostics.
    pub fn release(self: *AudioManager, channel: Channel, name: []const u8) void {
        var key_buf: [512]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}/{s}", .{ folderFor(channel), name }) catch return;
        if (self.resolved.fetchRemove(key)) |kv| {
            self.allocator.free(kv.key);
            self.allocator.free(kv.value);
            self.releases += 1;
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "audio resolution is lazy and extension-aware" {
    const alloc = testing.allocator;
    const root = "/tmp/omori-audio-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};
    const bgm_dir = try std.fs.path.join(alloc, &.{ root, "audio", "bgm" });
    defer alloc.free(bgm_dir);
    try std.fs.cwd().makePath(bgm_dir);
    {
        const p = try std.fs.path.join(alloc, &.{ root, "audio", "bgm", "Battle_VS_Good_Ending.ogg" });
        defer alloc.free(p);
        var f = try std.fs.cwd().createFile(p, .{});
        defer f.close();
        try f.writeAll("OggS");
    }

    var vfs = vfs_mod.Vfs.init(alloc, root, "/tmp/omori-audio-save");
    defer vfs.deinit();
    var audio = AudioManager.init(alloc, &vfs);
    defer audio.deinit();

    // Resolution succeeds with extension probing.
    const path = try audio.resolve(.bgm, "Battle_VS_Good_Ending");
    try testing.expect(path != null);
    try testing.expectEqualStrings("audio/bgm/Battle_VS_Good_Ending.ogg", path.?);

    // Unknown track → null (the game's fallback handles it).
    const missing = try audio.resolve(.bgm, "Track_That_Does_Not_Exist");
    try testing.expect(missing == null);

    // Release removes the identity; resolve finds it again (lazily).
    audio.release(.bgm, "Battle_VS_Good_Ending");
    try testing.expectEqual(@as(u64, 1), audio.releases);
    const again = try audio.resolve(.bgm, "Battle_VS_Good_Ending");
    try testing.expect(again != null);
}

test "v32 regression: resolve() result is manager-owned (the v31 double free)" {
    // The v31 mixer did: path = resolve(...); defer free(path);
    // defer resolver.deinit(); — freeing the SAME map-owned pointer twice.
    // With the GPA (v31's mixer allocator) the first free can unmap the
    // bucket page and the second free's Allocator.free poison-memset
    // (unconditional @memset(ptr, undefined)) faults on unmapped memory —
    // the exact v31 title-screen SIGSEGV. The arena (v30) masked it.
    //
    // This test pins the ownership: resolve() hands out a BORROW; deinit()
    // frees it exactly ONCE. std.testing.allocator catches BOTH failure
    // modes: a double free (panic) and a leak (end-of-test check).
    const alloc = testing.allocator;
    const root = "/tmp/omori-audio-dfree-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};
    const bgm_dir = try std.fs.path.join(alloc, &.{ root, "audio", "bgm" });
    defer alloc.free(bgm_dir);
    try std.fs.cwd().makePath(bgm_dir);
    {
        const p = try std.fs.path.join(alloc, &.{ root, "audio", "bgm", "user_title.ogg" });
        defer alloc.free(p);
        var f = try std.fs.cwd().createFile(p, .{});
        defer f.close();
        try f.writeAll("OggS");
    }

    var vfs = vfs_mod.Vfs.init(alloc, root, "/tmp/omori-audio-save-dfree");
    defer vfs.deinit();
    var audio = AudioManager.init(alloc, &vfs);
    defer audio.deinit();

    // The loadFileBytes shape: borrow the path, USE it, never free it.
    const path = try audio.resolve(.bgm, "user_title");
    try testing.expect(path != null);
    try testing.expectEqualStrings("audio/bgm/user_title.ogg", path.?);
    // (deinit above frees the map entry — exactly once. The old code's
    // extra free here is what crashed v31 on the device.)
}
