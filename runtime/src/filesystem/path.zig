//! RPG Maker MV / Android-nwcompat path semantics.
//!
//! This is a semantic port of the payload's own `js/porting/compat/nwjs.js`
//! `path` library (not a mechanical translation): `join`, `dirname`,
//! `basename`, `extname` and `_solve_dots` reproduce the behavior the game
//! actually depends on. All functions are UTF-8-safe for the byte-level
//! operations the game performs (case transforms are ASCII-only, exactly
//! like the JS `charAt(0).toUpperCase()` behavior).

const std = @import("std");

/// Split a path into components, dropping empty segments and ".",
/// resolving ".." by popping (the `_solve_dots` semantics: a leading ".."
/// with nothing to pop is silently dropped — the JS implementation pops an
/// empty array which stays empty).
pub fn solveDots(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var parts = std.ArrayList([]const u8).empty;
    defer parts.deinit(alloc);

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (parts.items.len > 0) _ = parts.pop();
        } else {
            try parts.append(alloc, seg);
        }
    }
    return std.mem.join(alloc, "/", parts.items);
}

pub fn dirname(path: []const u8) []const u8 {
    if (path.len == 0) return ".";
    var end = path.len;
    // strip trailing slashes
    while (end > 0 and path[end - 1] == '/') end -= 1;
    if (end == 0) return "/";
    const last_slash = std.mem.lastIndexOfScalar(u8, path[0..end], '/');
    if (last_slash) |idx| {
        if (idx == 0) return "/";
        var cut = idx;
        while (cut > 0 and path[cut - 1] == '/') cut -= 1;
        return path[0..cut];
    }
    return ".";
}

pub fn basename(path: []const u8) []const u8 {
    if (path.len == 0) return "";
    var end = path.len;
    while (end > 0 and path[end - 1] == '/') end -= 1;
    if (end == 0) return "";
    const start = if (std.mem.lastIndexOfScalar(u8, path[0..end], '/')) |i| i + 1 else 0;
    return path[start..end];
}

/// `basename` with the extension removed when it matches (used by
/// Text_Language_Processor: `basename('_DIRECTORY.json', '.json')`).
pub fn basenameWithoutExt(path: []const u8, ext: []const u8) []const u8 {
    const base = basename(path);
    if (ext.len > 0 and base.len >= ext.len and std.mem.eql(u8, base[base.len - ext.len ..], ext)) {
        return base[0 .. base.len - ext.len];
    }
    return base;
}

/// The payload's `extname`-equivalent: last extension including the dot,
/// empty string when none. (The JS version scans a fixed extension list;
/// the observable behavior for game data is the last dot segment.)
pub fn extname(path: []const u8) []const u8 {
    const base = basename(path);
    const idx = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    // A leading dot (hidden file) is not an extension.
    if (idx == 0) return "";
    return base[idx..];
}

pub fn join(alloc: std.mem.Allocator, a: []const u8, b: []const u8) ![]u8 {
    if (a.len == 0) return alloc.dupe(u8, b);
    if (b.len == 0) return alloc.dupe(u8, a);
    if (b[0] == '/') return alloc.dupe(u8, b); // absolute second argument wins
    const a_trim = std.mem.trimRight(u8, a, "/");
    return std.fmt.allocPrint(alloc, "{s}/{s}", .{ a_trim, b });
}

/// ASCII capitalize of the first character (JS `charAt(0).toUpperCase()`
/// + `slice(1)`) — the second variant tried by the Android `readFileSync`.
pub fn capitalizeFirst(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, s);
    if (out.len > 0) out[0] = std.ascii.toUpper(out[0]);
    return out;
}

/// ASCII lowercase of the whole string — the third variant tried by the
/// Android `readFileSync`.
pub fn toLowerAscii(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try alloc.dupe(u8, s);
    for (out) |*c| c.* = std.ascii.toLower(c.*);
    return out;
}

/// ASCII case-insensitive equality (used by `findAlternativeName`).
pub fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

test "solveDots matches _solve_dots semantics" {
    const a = std.testing.allocator;
    {
        const r = try solveDots(a, "/a/b/../c/./d");
        defer a.free(r);
        try std.testing.expectEqualStrings("a/c/d", r);
    }
    {
        // leading .. on empty stack is dropped (JS: pop on empty array)
        const r = try solveDots(a, "../a");
        defer a.free(r);
        try std.testing.expectEqualStrings("a", r);
    }
    {
        const r = try solveDots(a, "a//b/");
        defer a.free(r);
        try std.testing.expectEqualStrings("a/b", r);
    }
}

test "dirname/basename/extname" {
    try std.testing.expectEqualStrings("Languages/en", dirname("Languages/en/00_template.yaml"));
    try std.testing.expectEqualStrings("/", dirname("/Languages"));
    try std.testing.expectEqualStrings(".", dirname("Languages"));
    try std.testing.expectEqualStrings("00_template.yaml", basename("Languages/en/00_template.yaml"));
    try std.testing.expectEqualStrings(".yaml", extname("Languages/en/00_template.yaml"));
    try std.testing.expectEqualStrings(".json", extname("Map.json"));
    try std.testing.expectEqualStrings("", extname("noext"));
    try std.testing.expectEqualStrings("_DIRECTORY", basenameWithoutExt("_DIRECTORY.json", ".json"));
}

test "join behavior" {
    const a = std.testing.allocator;
    {
        const r = try join(a, "base", "sub");
        defer a.free(r);
        try std.testing.expectEqualStrings("base/sub", r);
    }
    {
        const r = try join(a, "base/", "/abs");
        defer a.free(r);
        try std.testing.expectEqualStrings("/abs", r);
    }
}
