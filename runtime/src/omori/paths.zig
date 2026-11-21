//! OMORI-specific path semantics.
//!
//! **Behavioral specification (from the payload):**
//! `Bitmap._requestImage` (VND_OmoriFixes.js) resolves image paths as:
//!
//! ```js
//! url = replaceSpecialSymbols(url);                 // 1. URL-decode + mangle
//! url = require("fs").cachedAlternativeName(url);   // 2. case-insensitive fs
//! ```
//!
//! The mangling exists because the Android APK physically renamed 748
//! asset files to avoid special characters:
//!   `!` → `_PIDOR_`   `[` → `_SUPER_`   `]` → `_PEDIK_`
//!   `$` → `_SEMENCUM_`  `%` → `_RAZRABI_PIDORASI`  `(` → `_SOSI_`  `)` → `_BEBRA_`
//!
//! The game's event data still references the ORIGINAL names
//! (`img/pictures/!BS_self.png`), so the runtime must translate on every
//! load. URL-decoding happens first (decodeURIComponent), and the result
//! is memoized in the payload (window._MEMO_PATHS).
//!
//! PC data retains the original symbols. Resolution first tries the
//! URL-decoded original name, then the Android replacement chain. It
//! produces the physical game-root
//! relative path (or null when the asset genuinely does not exist).

const std = @import("std");
const vfs_mod = @import("../filesystem/vfs.zig");

/// The special-symbol table in payload replacement order (order matters:
/// `%` is replaced AFTER `!`, and `!`'s replacement contains no `%`, so a
/// single pass in this order reproduces the JS chain result).
pub fn mangleSpecialSymbols(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    for (path) |c| {
        const repl: ?[]const u8 = switch (c) {
            '!' => "_PIDOR_",
            '[' => "_SUPER_",
            ']' => "_PEDIK_",
            '$' => "_SEMENCUM_",
            '%' => "_RAZRABI_PIDORASI",
            '(' => "_SOSI_",
            ')' => "_BEBRA_",
            else => null,
        };
        if (repl) |r| {
            try out.appendSlice(alloc, r);
        } else {
            try out.append(alloc, c);
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Percent-decoding (decodeURIComponent semantics: invalid escapes are
/// left untouched — decodeURIComponent would THROW, but the payload wraps
/// it in try/catch and falls back to the raw string, so "leave as-is" is
/// the observable behavior).
pub fn urlDecode(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    var i: usize = 0;
    while (i < path.len) {
        if (path[i] == '%' and i + 2 < path.len) {
            const hi = std.fmt.charToDigit(path[i + 1], 16) catch {
                try out.append(alloc, path[i]);
                i += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(path[i + 2], 16) catch {
                try out.append(alloc, path[i]);
                i += 1;
                continue;
            };
            const byte = @as(u8, hi) * 16 + lo;
            try out.append(alloc, byte);
            i += 3;
            continue;
        }
        try out.append(alloc, path[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

/// The full native image-path resolution chain:
/// URL-decode → original PC name → Android-mangled fallback, case-insensitive.
/// Returns the game-root-relative physical path (caller frees), or null if
/// the asset does not exist.
pub fn resolveAssetPath(alloc: std.mem.Allocator, vfs: *vfs_mod.Vfs, path: []const u8) !?[]u8 {
    const decoded = try urlDecode(alloc, path);
    defer alloc.free(decoded);
    if (try vfs.cachedAlternativeName(decoded)) |original| return try alloc.dupe(u8, original);
    const mangled = try mangleSpecialSymbols(alloc, decoded);
    defer alloc.free(mangled);
    const resolved = try vfs.cachedAlternativeName(mangled);
    if (resolved) |r| return try alloc.dupe(u8, r);
    return null;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "special symbol mangling matches the payload table" {
    const alloc = testing.allocator;
    {
        const r = try mangleSpecialSymbols(alloc, "img/pictures/!BS_self.png");
        defer alloc.free(r);
        try testing.expectEqualStrings("img/pictures/_PIDOR_BS_self.png", r);
    }
    {
        const r = try mangleSpecialSymbols(alloc, "img/pictures/[2x1].png");
        defer alloc.free(r);
        try testing.expectEqualStrings("img/pictures/_SUPER_2x1_PEDIK_.png", r);
    }
    {
        const r = try mangleSpecialSymbols(alloc, "normal/path.png");
        defer alloc.free(r);
        try testing.expectEqualStrings("normal/path.png", r);
    }
}

test "url decode with invalid escapes left untouched" {
    const alloc = testing.allocator;
    {
        const r = try urlDecode(alloc, "img/a%20b.png");
        defer alloc.free(r);
        try testing.expectEqualStrings("img/a b.png", r);
    }
    {
        // Invalid escape (`%ZZ`) — payload catch → raw string kept.
        const r = try urlDecode(alloc, "img/a%ZZb.png");
        defer alloc.free(r);
        try testing.expectEqualStrings("img/a%ZZb.png", r);
    }
}

test "full chain: mangled + case resolution against a VFS" {
    const alloc = testing.allocator;
    const root = "/tmp/omori-paths-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};
    {
        const dir = try std.fs.path.join(alloc, &.{ root, "img", "pictures" });
        defer alloc.free(dir);
        try std.fs.cwd().makePath(dir);
    }
    {
        const p = try std.fs.path.join(alloc, &.{ root, "img", "pictures", "_PIDOR_BS_self.png" });
        defer alloc.free(p);
        var f = try std.fs.cwd().createFile(p, .{});
        defer f.close();
        try f.writeAll("X");
    }

    var vfs = vfs_mod.Vfs.init(alloc, root, "/tmp/omori-paths-save");
    defer vfs.deinit();

    const r = try resolveAssetPath(alloc, &vfs, "img/pictures/!BS_self.png");
    defer if (r) |v| alloc.free(v);
    try testing.expectEqualStrings("img/pictures/_PIDOR_BS_self.png", r.?);

    // Missing asset resolves to null (the JS loader retries / falls back).
    const r2 = try resolveAssetPath(alloc, &vfs, "img/pictures/!missing.png");
    try testing.expect(r2 == null);
}

test "full chain: PC special-symbol names precede Android fallback" {
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("img/characters");
    try tmp.dir.writeFile(.{ .sub_path = "img/characters/!OBJ_DOORS.png", .data = "PC" });
    try tmp.dir.writeFile(.{ .sub_path = "img/characters/_PIDOR_OBJ_DOORS.png", .data = "Android" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    var vfs = vfs_mod.Vfs.init(a, root, root);
    defer vfs.deinit();
    const path = (try resolveAssetPath(a, &vfs, "IMG/CHARACTERS/%21obj_doors.png")) orelse
        return error.AssetNotResolved;
    defer a.free(path);
    // On a case-insensitive host the VFS can retain the request's casing.
    try testing.expect(std.ascii.eqlIgnoreCase("img/characters/!OBJ_DOORS.png", path));
    const bytes = try vfs.readFileSync(path);
    defer a.free(bytes);
    try testing.expectEqualStrings("PC", bytes);
}
