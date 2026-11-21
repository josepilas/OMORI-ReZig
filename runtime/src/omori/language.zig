//! OMORI language subsystem — native port of the boot-critical
//! `Text_Language_Processor` enumeration semantics.
//!
//! **Behavioral specification (the v13/v14 failure chain):**
//! `LanguageManager.loadAllLanguageFiles()`:
//!   1. `fs.readdirSync('/Languages/')` — the VIRTUAL listing (["en"];
//!      the marker `_DIRECTORY.json` must never appear in it);
//!   2. `fs.statSync('Languages/<name>')` — must not throw;
//!   3. if a directory → enumerate its `.yaml` files.
//!
//! This module runs that exact algorithm against the native VFS and
//! records the outcome; the YAML string-table loading itself is part of
//! the message-window milestone (the load ORDER and file identity are
//! what boot correctness depends on here).

const std = @import("std");
const vfs_mod = @import("../filesystem/vfs.zig");
const path = @import("../filesystem/path.zig");
const log = @import("../core/log.zig");

pub const Language = struct {
    /// Directory name, e.g. "en".
    name: []const u8,
    /// YAML file names inside the language directory (owned).
    files: [][]const u8,
};

pub const LanguageSet = struct {
    allocator: std.mem.Allocator,
    languages: []Language,

    pub fn deinit(self: *LanguageSet) void {
        for (self.languages) |lang| {
            for (lang.files) |f| self.allocator.free(f);
            self.allocator.free(lang.files);
            self.allocator.free(lang.name);
        }
        self.allocator.free(self.languages);
    }

    pub fn count(self: *const LanguageSet) usize {
        return self.languages.len;
    }

    pub fn totalFiles(self: *const LanguageSet) usize {
        var n: usize = 0;
        for (self.languages) |l| n += l.files.len;
        return n;
    }
};

pub const LanguageError = error{
    NoLanguages,
    OutOfMemory,
};

/// The `loadAllLanguageFiles` algorithm, natively: virtual readdir →
/// stat → per-language enumeration. This is the exact call chain whose
/// failure aborted GTP_OmoriFixes and left `$atlasData` undefined.
pub fn loadAllLanguages(alloc: std.mem.Allocator, vfs: *vfs_mod.Vfs) LanguageError!LanguageSet {
    const listing = vfs.readdirSync("Languages") catch {
        log.err("Languages/ listing failed — the payload tree is invalid", .{});
        return LanguageError.NoLanguages;
    };
    defer {
        for (listing) |n| alloc.free(n);
        alloc.free(listing);
    }

    var langs = std.ArrayList(Language).empty;
    errdefer {
        for (langs.items) |l| {
            for (l.files) |f| alloc.free(f);
            alloc.free(l.files);
            alloc.free(l.name);
        }
        langs.deinit(alloc);
    }

    for (listing) |entry| {
        // The game joins the folder prefix before stating: the payload's
        // loadAllLanguageFiles does `fs.statSync(filePath + filename)`.
        const joined = try std.fmt.allocPrint(alloc, "Languages/{s}", .{entry});
        defer alloc.free(joined);
        // statSync must resolve WITHOUT throwing — including for any
        // extension-stripped name (the historical _DIRECTORY crash).
        const st = vfs.statSync(joined);
        if (!st.exists or !st.is_directory) continue;

        const name = try alloc.dupe(u8, entry);
        const dir_listing_path = try std.fmt.allocPrint(alloc, "Languages/{s}", .{entry});
        const files = vfs.readdirSync(dir_listing_path) catch {
            alloc.free(dir_listing_path);
            alloc.free(name);
            log.warn("Languages/{s}: enumeration failed", .{entry});
            continue;
        };
        alloc.free(dir_listing_path);
        // Keep only the language YAMLs (skip markers defensively — the
        // VFS already filters them, this is belt-and-braces).
        var kept = std.ArrayList([]const u8).empty;
        for (files) |f| {
            const base = path.basename(f);
            if (std.mem.eql(u8, base, "_DIRECTORY") or std.mem.eql(u8, base, "_DIRECTORY.json")) {
                alloc.free(f);
                continue;
            }
            try kept.append(alloc, f);
        }
        alloc.free(files);
        try langs.append(alloc, .{ .name = name, .files = try kept.toOwnedSlice(alloc) });
    }

    if (langs.items.len == 0) return LanguageError.NoLanguages;

    return .{ .allocator = alloc, .languages = try langs.toOwnedSlice(alloc) };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn buildTree(alloc: std.mem.Allocator) ![]const u8 {
    const root = "/tmp/omori-lang-test";
    std.fs.cwd().deleteTree(root) catch {};
    {
        const langs = try std.fs.path.join(alloc, &.{ root, "Languages", "en" });
        defer alloc.free(langs);
        try std.fs.cwd().makePath(langs);
    }
    // The virtual listing (["en"]) and one language with two files.
    {
        const p = try std.fs.path.join(alloc, &.{ root, "Languages", "_DIRECTORY.json" });
        defer alloc.free(p);
        try writeF(p, "[\"en\"]");
    }
    {
        const p = try std.fs.path.join(alloc, &.{ root, "Languages", "en", "_DIRECTORY.json" });
        defer alloc.free(p);
        try writeF(p, "[\"00_template.yaml\",\"01_map.yaml\"]");
    }
    {
        const p = try std.fs.path.join(alloc, &.{ root, "Languages", "en", "00_template.yaml" });
        defer alloc.free(p);
        try writeF(p, "a: 1");
    }
    {
        const p = try std.fs.path.join(alloc, &.{ root, "Languages", "en", "01_map.yaml" });
        defer alloc.free(p);
        try writeF(p, "b: 2");
    }
    return root;
}

fn writeF(p: []const u8, data: []const u8) !void {
    var f = try std.fs.cwd().createFile(p, .{});
    defer f.close();
    try f.writeAll(data);
}

test "loadAllLanguages: virtual listing, no ENOENT, files enumerated" {
    const alloc = testing.allocator;
    const root = try buildTree(alloc);
    defer std.fs.cwd().deleteTree(root) catch {}; // root is a literal
    var vfs = vfs_mod.Vfs.init(alloc, root, "/tmp/omori-lang-save");
    defer vfs.deinit();

    var set = try loadAllLanguages(alloc, &vfs);
    defer set.deinit();

    try testing.expectEqual(@as(usize, 1), set.count());
    try testing.expectEqualStrings("en", set.languages[0].name);
    try testing.expectEqual(@as(usize, 2), set.languages[0].files.len);
    try testing.expectEqual(@as(usize, 2), set.totalFiles());
}
