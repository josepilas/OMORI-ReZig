//! Native hybrid virtual filesystem for OMORI.
//!
//! **This module is the semantic port of the V21 hybrid filesystem.** The
//! existing project discovered that OMORI's Android payload requires a
//! single `fs` object that is BOTH standard Node fs AND the Android
//! nwcompat fs (the payload's own `js/porting/compat/nwjs.js`). The
//! behaviors reproduced here, with their evidence trail:
//!
//! * `readdirSync(dir)` — the Android layer returns the JSON array stored
//!   in `dir/_DIRECTORY.json`. Physical directories are listed with the
//!   `_DIRECTORY` / `_DIRECTORY.json` markers filtered out (v14 policy;
//!   listings verified byte-identical in the payload).
//! * `statSync("X/_DIRECTORY")` — must resolve to the physical
//!   `X/_DIRECTORY.json` and MUST NOT throw ENOENT. The v13 failure chain
//!   was exactly: `stat("Languages/_DIRECTORY")` → ENOENT →
//!   Text_Language_Processor failure → GTP_OmoriFixes IIFE aborted →
//!   `$atlasData` undefined → Scene_Boot dead.
//! * `statSync(X)` — Android semantics: probe `X/_DIRECTORY.json`;
//!   success ⇒ directory; otherwise fall back to physical stat. statSync
//!   reports non-existence instead of throwing (Android behavior).
//! * `readFileSync(path)` — Android case-variant fallback: exact,
//!   first-letter-capitalized, all-lowercase. `save/` paths route to the
//!   persistent save root (the NativeFunctions bridge equivalent).
//! * `writeFileSync` — only legal inside `save/` (Android forbids writes
//!   elsewhere; the game never attempts them in normal operation).
//! * `existsSync`, `cachedAlternativeName`, `findAlternativeName` —
//!   case-insensitive resolution used by `Bitmap._requestImage`.
//!
//! Not ported: XHR transport, prototype delegation, Node Buffer objects.
//! Those are environment machinery — the semantics above are the behavior.

const std = @import("std");
const p = @import("path.zig");
const log = @import("../core/log.zig");
const fs_compat = @import("../core/fs_compat.zig");

pub const Error = error{
    NotFound,
    WriteOutsideSave,
    AccessDenied,
    OutOfMemory,
};

pub const Stat = struct {
    exists: bool,
    is_directory: bool,
};

pub const Vfs = struct {
    allocator: std.mem.Allocator,
    /// Root of the extracted game payload (the `assets/www` directory).
    game_root: []const u8,
    /// Persistent save root (the `omori/saves` directory).
    save_root: []const u8,
    /// `cachedAlternativeName` memo table (mirrors window.ALT_CACHE).
    alt_cache: std.StringHashMap(?[]const u8),

    pub fn init(alloc: std.mem.Allocator, game_root: []const u8, save_root: []const u8) Vfs {
        return .{
            .allocator = alloc,
            .game_root = game_root,
            .save_root = save_root,
            .alt_cache = std.StringHashMap(?[]const u8).init(alloc),
        };
    }

    pub fn deinit(self: *Vfs) void {
        var it = self.alt_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*) |v| self.allocator.free(v);
        }
        self.alt_cache.deinit();
    }

    // ------------------------------------------------------------------
    // Resolution helpers
    // ------------------------------------------------------------------

    /// Is `path` an exact virtual-directory marker path (`X/_DIRECTORY`)?
    fn isMarkerPath(path: []const u8) bool {
        return std.mem.eql(u8, p.basename(path), "_DIRECTORY");
    }

    /// Does the second-to-last path component equal `save`? (The payload's
    /// `tmparr[tmparr.length - 2] === "save"` check, applied after
    /// `_solve_dots`.)
    fn isInSaveDir(path: []const u8) bool {
        const solved = p.dirname(path);
        return std.mem.eql(u8, p.basename(solved), "save");
    }

    /// Physical path for a game-relative virtual path (caller frees).
    fn physicalPath(self: *Vfs, path: []const u8) ![]u8 {
        const solved = try p.solveDots(self.allocator, path);
        defer self.allocator.free(solved);
        if (solved.len == 0) return self.allocator.dupe(u8, self.game_root);
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.game_root, solved });
    }

    /// Physical path inside the save root for `.../save/<name>` (caller frees).
    fn savePath(self: *Vfs, path: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.save_root, p.basename(path) });
    }

    // ------------------------------------------------------------------
    // readdirSync
    // ------------------------------------------------------------------

    /// `readdirSync`: virtual listing from `_DIRECTORY.json` when present,
    /// otherwise the filtered physical listing. Result entries are owned by
    /// the caller (free the slice and each entry).
    pub fn readdirSync(self: *Vfs, path: []const u8) ![][]const u8 {
        const phys = try self.physicalPath(path);
        defer self.allocator.free(phys);

        // 1. Virtual listing (Android semantics).
        {
            const dir_listing = try std.fmt.allocPrint(self.allocator, "{s}/_DIRECTORY.json", .{phys});
            defer self.allocator.free(dir_listing);
            if (fs_compat.readFileAlloc(std.fs.cwd(), self.allocator, dir_listing, 16 * 1024 * 1024)) |json_text| {
                defer self.allocator.free(json_text);
                if (self.parseNameArray(json_text)) |names| {
                    log.detail(.vfs, "readdir '{s}' → virtual _DIRECTORY.json ({d} names)", .{ path, names.len });
                    return names;
                }
            } else |_| {}
        }

        // 2. Physical listing with markers filtered (v14 policy).
        var names = std.ArrayList([]const u8).empty;
        errdefer {
            for (names.items) |n| self.allocator.free(n);
            names.deinit(self.allocator);
        }
        var dir = std.fs.cwd().openDir(phys, .{ .iterate = true }) catch {
            log.detail(.vfs, "readdir '{s}' → NotFound (no _DIRECTORY.json, no physical dir)", .{path});
            return Error.NotFound;
        };
        defer dir.close();
        var it = dir.iterate();
        while (it.next() catch return Error.AccessDenied) |entry| {
            const base = p.basename(entry.name);
            if (std.mem.eql(u8, base, "_DIRECTORY") or std.mem.eql(u8, base, "_DIRECTORY.json")) continue;
            // The Android payload stores plain names; skip the on-device
            // APK extraction control files that never appear in listings.
            if (std.mem.eql(u8, base, ".gitkeep")) continue;
            try names.append(self.allocator, try self.allocator.dupe(u8, entry.name));
        }
        const out = try names.toOwnedSlice(self.allocator);
        log.detail(.vfs, "readdir '{s}' → physical listing ({d} names, markers filtered)", .{ path, out.len });
        return out;
    }

    /// Parse a `_DIRECTORY.json` JSON string array.
    fn parseNameArray(self: *Vfs, json_text: []const u8) ?[][]const u8 {
        const json = @import("../data/json.zig");
        var parser = json.Parser.init(self.allocator, json_text) catch return null;
        defer parser.deinit();
        const value = parser.parse() catch return null;
        const arr = switch (value) {
            .array => |a| a,
            else => return null,
        };
        var names = std.ArrayList([]const u8).empty;
        for (arr.items) |item| {
            switch (item) {
                .string => |s| names.append(self.allocator, self.allocator.dupe(u8, s) catch return null) catch return null,
                else => return null,
            }
        }
        return names.toOwnedSlice(self.allocator) catch null;
    }

    // ------------------------------------------------------------------
    // statSync / existsSync
    // ------------------------------------------------------------------

    /// `statSync` — never throws for missing paths (Android semantics).
    pub fn statSync(self: *Vfs, path: []const u8) Stat {
        // save/ special cases (Android statSync):
        //   .../save        -> directory
        //   .../save/<file> -> file
        const base = p.basename(path);
        if (std.mem.eql(u8, base, "save")) return .{ .exists = true, .is_directory = true };
        if (isInSaveDir(path)) {
            const spath = self.savePath(path) catch return .{ .exists = false, .is_directory = false };
            defer self.allocator.free(spath);
            const exists = blk: {
                std.fs.cwd().access(spath, .{}) catch break :blk false;
                break :blk true;
            };
            return .{ .exists = exists, .is_directory = false };
        }

        // Exact marker path: resolve to the physical `<dir>/_DIRECTORY.json`.
        if (isMarkerPath(path)) {
            const phys = self.markerJsonPath(path) catch return .{ .exists = false, .is_directory = false };
            defer self.allocator.free(phys);
            const st = fs_compat.statFile(std.fs.cwd(), phys) catch {
                log.detail(.vfs, "stat '{s}' → marker → MISS (no physical _DIRECTORY.json)", .{path});
                return .{ .exists = false, .is_directory = false };
            };
            log.detail(.vfs, "stat '{s}' → marker → file (is_directory={s})", .{ path, if (st.kind == .directory) "true" else "false" });
            return .{ .exists = true, .is_directory = st.kind == .directory };
        }

        const phys = self.physicalPath(path) catch return .{ .exists = false, .is_directory = false };
        defer self.allocator.free(phys);

        // Android semantic: probe `<path>/_DIRECTORY.json` first — success
        // means the path IS a directory (the virtual-directory contract).
        {
            const probe = std.fmt.allocPrint(self.allocator, "{s}/_DIRECTORY.json", .{phys}) catch
                return .{ .exists = false, .is_directory = false };
            defer self.allocator.free(probe);
            if (fs_compat.statFile(std.fs.cwd(), probe)) |_| {
                log.detail(.vfs, "stat '{s}' → dir (via _DIRECTORY.json probe)", .{path});
                return .{ .exists = true, .is_directory = true };
            } else |_| {}
        }

        // Physical stat fallback (a directory without a marker, or a file).
        // (fs_compat: fstatat — the R36S's 4.4 kernel has no statx; std's
        // statFile failed with ENOSYS there and killed boot at the very
        // first verification entry, "index.html is missing".)
        const st = fs_compat.statFile(std.fs.cwd(), phys) catch {
            log.detail(.vfs, "stat '{s}' → MISS", .{path});
            return .{ .exists = false, .is_directory = false };
        };
        log.detail(.vfs, "stat '{s}' → physical (is_directory={s})", .{ path, if (st.kind == .directory) "true" else "false" });
        return .{ .exists = true, .is_directory = st.kind == .directory };
    }

    pub fn existsSync(self: *Vfs, path: []const u8) bool {
        return self.statSync(path).exists;
    }

    /// The physical path of the `_DIRECTORY.json` backing a marker path
    /// `X/_DIRECTORY` (caller frees).
    fn markerJsonPath(self: *Vfs, path: []const u8) ![]u8 {
        const dir = p.dirname(path);
        const solved = try p.solveDots(self.allocator, dir);
        defer self.allocator.free(solved);
        if (solved.len == 0) return std.fmt.allocPrint(self.allocator, "{s}/_DIRECTORY.json", .{self.game_root});
        return std.fmt.allocPrint(self.allocator, "{s}/{s}/_DIRECTORY.json", .{ self.game_root, solved });
    }

    // ------------------------------------------------------------------
    // readFileSync
    // ------------------------------------------------------------------

    /// `readFileSync` — save routing + the three Android case variants
    /// (exact / capitalized / lowercased). Caller owns the result.
    pub fn readFileSync(self: *Vfs, path: []const u8) ![]u8 {
        if (isInSaveDir(path)) {
            const spath = self.savePath(path) catch return Error.OutOfMemory;
            defer self.allocator.free(spath);
            const data = fs_compat.readFileAlloc(std.fs.cwd(), self.allocator, spath, 512 * 1024 * 1024) catch {
                log.detail(.vfs, "read '{s}' → save-root MISS", .{path});
                return Error.NotFound;
            };
            log.detail(.vfs, "read '{s}' → save-root ({d} bytes)", .{ path, data.len });
            return data;
        }

        // Exact marker path resolves to the physical JSON file.
        if (isMarkerPath(path)) {
            const phys = try self.markerJsonPath(path);
            defer self.allocator.free(phys);
            const data = fs_compat.readFileAlloc(std.fs.cwd(), self.allocator, phys, 16 * 1024 * 1024) catch {
                log.detail(.vfs, "read '{s}' → marker MISS", .{path});
                return Error.NotFound;
            };
            log.detail(.vfs, "read '{s}' → marker _DIRECTORY.json ({d} bytes)", .{ path, data.len });
            return data;
        }

        const dir = p.dirname(path);
        const base = p.basename(path);
        const cap = try p.capitalizeFirst(self.allocator, base);
        defer self.allocator.free(cap);
        const lower = try p.toLowerAscii(self.allocator, base);
        defer self.allocator.free(lower);

        // Root the variants at the game root (never the process CWD).
        const phys_dir = try self.physicalPath(dir);
        defer self.allocator.free(phys_dir);

        const variants = [_][]const u8{ base, cap, lower };
        const variant_names = [_][]const u8{ "exact", "capitalized", "lowercased" };
        for (variants, 0..) |v, vi| {
            const full = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ phys_dir, v });
            defer self.allocator.free(full);
            if (fs_compat.readFileAlloc(std.fs.cwd(), self.allocator, full, 512 * 1024 * 1024)) |data| {
                log.detail(.vfs, "read '{s}' → {s} variant ({d} bytes)", .{ path, variant_names[vi], data.len });
                return data;
            } else |_| {}
        }
        log.event(.vfs, .note, "read '{s}' → MISS after all 3 case variants", .{path});
        return Error.NotFound;
    }

    // ------------------------------------------------------------------
    // writeFileSync (save-only)
    // ------------------------------------------------------------------

    /// `writeFileSync` — Android contract: only `save/` paths are writable
    /// (routed to the persistent save root); everything else errors.
    /// Writes are atomic: temp file + rename, so a crash mid-write can
    /// never corrupt an existing save.
    pub fn writeFileSync(self: *Vfs, path: []const u8, data: []const u8) !void {
        if (!isInSaveDir(path)) return Error.WriteOutsideSave;
        const spath = self.savePath(path) catch return Error.OutOfMemory;
        defer self.allocator.free(spath);

        const tmp = std.fmt.allocPrint(self.allocator, "{s}.tmp", .{spath}) catch return Error.OutOfMemory;
        defer self.allocator.free(tmp);

        fs_compat.makePath(std.fs.cwd(), self.save_root) catch {};
        errdefer std.fs.cwd().deleteFile(tmp) catch {};
        {
            var file = std.fs.cwd().createFile(tmp, .{}) catch return Error.AccessDenied;
            defer file.close();
            file.writeAll(data) catch return Error.AccessDenied;
            // Do not publish a rename while the completed save is still
            // only buffered in memory on the removable card.
            file.sync() catch return Error.AccessDenied;
        }
        std.fs.cwd().rename(tmp, spath) catch return Error.AccessDenied;
    }

    // ------------------------------------------------------------------
    // Android alternative-name resolution
    // ------------------------------------------------------------------

    /// Resolve a miss against the directory listing. If an ancestor also
    /// differs in case, resolve it first through the same cache.
    pub fn findAlternativeName(self: *Vfs, path: []const u8) std.mem.Allocator.Error!?[]u8 {
        var dir = p.dirname(path);
        const base = p.basename(path);
        const names = self.readdirSync(dir) catch blk: {
            if (std.mem.eql(u8, dir, path)) return null;
            dir = (try self.cachedAlternativeName(dir)) orelse return null;
            break :blk self.readdirSync(dir) catch return null;
        };
        defer {
            for (names) |n| self.allocator.free(n);
            self.allocator.free(names);
        }
        var match: ?[]const u8 = null;
        for (names) |name| {
            if (std.mem.eql(u8, name, base)) {
                match = name;
                break;
            }
            if (match == null and p.eqlIgnoreCase(name, base)) match = name;
        }
        const name = match orelse return null;
        return try p.join(self.allocator, if (std.mem.eql(u8, dir, ".")) "" else dir, name);
    }

    /// `cachedAlternativeName`: if the path exists, return it unchanged;
    /// otherwise return the case-insensitive alternative (or null).
    /// Both the key and a non-null value are owned by the VFS cache.
    pub fn cachedAlternativeName(self: *Vfs, path: []const u8) std.mem.Allocator.Error!?[]const u8 {
        if (self.alt_cache.get(path)) |cached| {
            return cached;
        }
        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        const value = if (self.existsSync(path))
            try self.allocator.dupe(u8, path)
        else
            try self.findAlternativeName(path);
        errdefer if (value) |resolved| self.allocator.free(resolved);
        try self.alt_cache.put(key, value);
        return value;
    }
};

// ---------------------------------------------------------------------------
// Tests: the deterministic compatibility battery (§24 of the pivot spec).
// ---------------------------------------------------------------------------

const testing = std.testing;

/// Builds a synthetic tree reproducing the critical payload shapes:
/// marker-filtered listings, marker paths, case-variant files, save dir.
fn makeTestTree(alloc: std.mem.Allocator) ![]const u8 {
    const root = try std.fs.path.join(alloc, &.{ "/tmp", "omori-vfs-test" });
    {
        const fp = try std.fs.path.join(alloc, &.{ root, "Languages", "en" });
        defer alloc.free(fp);
        std.fs.cwd().makePath(fp) catch {};
    }
    // _DIRECTORY.json markers (the payload ships 44 of these).
    {
        const fp = try std.fs.path.join(alloc, &.{ root, "Languages", "_DIRECTORY.json" });
        defer alloc.free(fp);
        try writeFile(fp, "[\"en\"]");
    }
    {
        const fp = try std.fs.path.join(alloc, &.{ root, "Languages", "en", "_DIRECTORY.json" });
        defer alloc.free(fp);
        try writeFile(fp, "[\"00_template.yaml\",\"01_strings.yaml\"]");
    }
    {
        const fp = try std.fs.path.join(alloc, &.{ root, "Languages", "en", "00_template.yaml" });
        defer alloc.free(fp);
        try writeFile(fp, "template");
    }
    {
        const fp = try std.fs.path.join(alloc, &.{ root, "Languages", "en", "01_strings.yaml" });
        defer alloc.free(fp);
        try writeFile(fp, "strings");
    }
    // Case-variant reads: game asks for "Map.JSON", physical is "Map.json".
    {
        const fp = try std.fs.path.join(alloc, &.{ root, "Map.json" });
        defer alloc.free(fp);
        try writeFile(fp, "{}");
    }
    // Capitalized variant: game asks for "img/pictures/a.png".
    {
        const fp = try std.fs.path.join(alloc, &.{ root, "img", "pictures" });
        defer alloc.free(fp);
        std.fs.cwd().makePath(fp) catch {};
    }
    {
        const fp = try std.fs.path.join(alloc, &.{ root, "img", "pictures", "A.png" });
        defer alloc.free(fp);
        try writeFile(fp, "PNGDATA");
    }
    {
        const fp = try std.fs.path.join(alloc, &.{ root, "img", "pictures", "B.png" });
        defer alloc.free(fp);
        try writeFile(fp, "PNGDATA2");
    }
    // Marker-less physical directory.
    {
        const fp = try std.fs.path.join(alloc, &.{ root, "nomarker", "sub" });
        defer alloc.free(fp);
        std.fs.cwd().makePath(fp) catch {};
    }
    // Save root.
    std.fs.cwd().makePath("/tmp/omori-vfs-save") catch {};
    return root;
}

fn writeFile(path: []const u8, data: []const u8) !void {
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(data);
}

fn cleanupTestTree(alloc: std.mem.Allocator, root: []const u8) void {
    std.fs.cwd().deleteTree(root) catch {};
    alloc.free(root);
    std.fs.cwd().deleteTree("/tmp/omori-vfs-save") catch {};
}

test "readdirSync uses virtual _DIRECTORY.json listing" {
    const alloc = testing.allocator;
    const root = try makeTestTree(alloc);
    defer cleanupTestTree(alloc, root);
    var vfs = Vfs.init(alloc, root, "/tmp/omori-vfs-save");
    defer vfs.deinit();

    const names = try vfs.readdirSync("Languages");
    defer {
        for (names) |n| alloc.free(n);
        alloc.free(names);
    }
    // Exactly the Android listing — the marker itself must NOT appear.
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expectEqualStrings("en", names[0]);
}

test "statSync(Languages/_DIRECTORY) resolves to the marker file — never ENOENT" {
    // This is THE v14 regression: the whole boot chain died here.
    const alloc = testing.allocator;
    const root = try makeTestTree(alloc);
    defer cleanupTestTree(alloc, root);
    var vfs = Vfs.init(alloc, root, "/tmp/omori-vfs-save");
    defer vfs.deinit();

    const st = vfs.statSync("Languages/_DIRECTORY");
    try testing.expect(st.exists);
    try testing.expect(!st.is_directory);
}

test "statSync directory detection via marker probe" {
    const alloc = testing.allocator;
    const root = try makeTestTree(alloc);
    defer cleanupTestTree(alloc, root);
    var vfs = Vfs.init(alloc, root, "/tmp/omori-vfs-save");
    defer vfs.deinit();

    // Marker-backed directory.
    try testing.expect(vfs.statSync("Languages").is_directory);
    // Marker-less physical directory.
    try testing.expect(vfs.statSync("nomarker").is_directory);
    try testing.expect(vfs.statSync("nomarker/sub").is_directory);
    // Regular file: probe of file/_DIRECTORY.json fails → physical stat.
    try testing.expect(vfs.statSync("Map.json").exists);
    try testing.expect(!vfs.statSync("Map.json").is_directory);
    // Missing path: no throw, not exists (Android semantics).
    try testing.expect(!vfs.statSync("missing/nothing").exists);
}

test "readFileSync case variants: exact / capitalized / lowercase" {
    const alloc = testing.allocator;
    const root = try makeTestTree(alloc);
    defer cleanupTestTree(alloc, root);
    var vfs = Vfs.init(alloc, root, "/tmp/omori-vfs-save");
    defer vfs.deinit();

    // Exact.
    {
        const data = try vfs.readFileSync("Map.json");
        defer alloc.free(data);
        try testing.expectEqualStrings("{}", data);
    }
    // Capitalized first letter of the LAST component ("a.png" → "A.png").
    {
        const data = try vfs.readFileSync("img/pictures/a.png");
        defer alloc.free(data);
        try testing.expectEqualStrings("PNGDATA", data);
    }
    // Marker path read resolves to the JSON content.
    {
        const data = try vfs.readFileSync("Languages/_DIRECTORY");
        defer alloc.free(data);
        try testing.expectEqualStrings("[\"en\"]", data);
    }
    // Missing → NotFound.
    try testing.expectError(Error.NotFound, vfs.readFileSync("img/pictures/zz.png"));
}

test "save routing: write/read/exists with atomic writes" {
    const alloc = testing.allocator;
    const root = try makeTestTree(alloc);
    defer cleanupTestTree(alloc, root);
    var vfs = Vfs.init(alloc, root, "/tmp/omori-vfs-save");
    defer vfs.deinit();

    // Android write contract: only save/ paths are writable.
    try testing.expectError(Error.WriteOutsideSave, vfs.writeFileSync("data/Map.json", "{}"));

    const save_path = "file0/save/rpg1.rpgsave";
    try vfs.writeFileSync(save_path, "SAVEDATA-v1");
    // existsSync through the virtual save dir.
    try testing.expect(vfs.existsSync(save_path));
    try testing.expect(vfs.existsSync("file0/save"));
    {
        const data = try vfs.readFileSync(save_path);
        defer alloc.free(data);
        try testing.expectEqualStrings("SAVEDATA-v1", data);
    }
    // Round 2: overwrite atomically.
    try vfs.writeFileSync(save_path, "SAVEDATA-v2");
    {
        const data = try vfs.readFileSync(save_path);
        defer alloc.free(data);
        try testing.expectEqualStrings("SAVEDATA-v2", data);
    }
    // No temp files left behind.
    {
        var dir = try std.fs.cwd().openDir("/tmp/omori-vfs-save", .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        var count: usize = 0;
        while (try it.next()) |e| {
            count += 1;
            try testing.expectEqualStrings("rpg1.rpgsave", e.name);
        }
        try testing.expectEqual(@as(usize, 1), count);
    }
}

test "cachedAlternativeName: case-insensitive fallback with caching" {
    const alloc = testing.allocator;
    const root = try makeTestTree(alloc);
    defer cleanupTestTree(alloc, root);
    var vfs = Vfs.init(alloc, root, "/tmp/omori-vfs-save");
    defer vfs.deinit();

    // NOTE: returned values are owned by the VFS cache (deinit frees them).

    // Existing path returns itself.
    {
        const r = try vfs.cachedAlternativeName("img/pictures/A.png");
        try testing.expectEqualStrings("img/pictures/A.png", r.?);
    }
    // Wrong case resolves through the listing scan.
    {
        const r = try vfs.cachedAlternativeName("img/pictures/b.PNG");
        try testing.expectEqualStrings("img/pictures/B.png", r.?);
    }
    // Missing entirely → null.
    {
        const r = try vfs.cachedAlternativeName("img/pictures/missing.png");
        try testing.expect(r == null);
    }
    // Cached: the second lookup does not re-scan.
    const r1 = try vfs.cachedAlternativeName("img/pictures/c.png");
    try testing.expect(r1 == null);
    const r2 = try vfs.cachedAlternativeName("img/pictures/c.png");
    try testing.expect(r2 == null);
}
