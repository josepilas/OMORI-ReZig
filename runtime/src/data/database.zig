//! MV data-file loading (milestone 2 / data tier of the architecture).
//!
//! Loads and validates the RPG Maker MV database files OMORI's boot
//! sequence touches (`Scene_Boot` → `DataManager.loadDatabase`):
//! Actors/Classes/Skills/Items/Weapons/Armors/Enemies/States/
//! Troops/Animations/Tilesets/CommonEvents/System/Map###. Values are
//! stored as tolerant-JSON trees (see data/json.zig); typed views over
//! them arrive with the MV-core milestone. The loader uses the SAME
//! virtual filesystem the game uses, so case-variant and marker
//! semantics apply to data files exactly as the Android payload expects.

const std = @import("std");
const json = @import("json.zig");
const vfs_mod = @import("../filesystem/vfs.zig");
const log = @import("../core/log.zig");

pub const FileKind = enum {
    database,
    map,
    plugins,
};

pub const LoadedFile = struct {
    /// Game-root-relative path (owned by the arena).
    path: []const u8,
    kind: FileKind,
    value: json.Value,

    pub fn deinit(self: *LoadedFile) void {
        _ = self; // arena-managed by the Database
    }
};

pub const Database = struct {
    allocator: std.mem.Allocator,
    vfs: *vfs_mod.Vfs,
    arena: std.heap.ArenaAllocator,
    files: std.StringHashMap(usize),
    storage: std.ArrayList(LoadedFile),

    pub fn init(alloc: std.mem.Allocator, vfs: *vfs_mod.Vfs) Database {
        return .{
            .allocator = alloc,
            .vfs = vfs,
            .arena = std.heap.ArenaAllocator.init(alloc),
            .files = std.StringHashMap(usize).init(alloc),
            .storage = .empty,
        };
    }

    pub fn deinit(self: *Database) void {
        var it = self.files.iterator();
        while (it.next()) |e| self.allocator.free(e.key_ptr.*);
        self.files.deinit();
        self.storage.deinit(self.allocator);
        self.arena.deinit();
    }

    /// Load a data file through the VFS and parse it. `path` is the
    /// game-relative path, e.g. "data/Actors.json". Plugins.js is parsed
    /// with the JS-assignment shim.
    pub fn loadFile(self: *Database, kind: FileKind, path: []const u8) !LoadedFile {
        const text = try self.vfs.readFileSync(path);
        defer self.vfs.allocator.free(text);

        var parser = try json.Parser.init(self.arena.allocator(), text);
        const value = switch (kind) {
            .plugins => try parser.parseJsAssignment(),
            else => try parser.parse(),
        };

        const stored = LoadedFile{
            .path = try self.arena.allocator().dupe(u8, path),
            .kind = kind,
            .value = value,
        };
        try self.storage.append(self.allocator, stored);
        const key = try self.allocator.dupe(u8, path);
        const old = self.files.fetchPut(key, self.storage.items.len - 1) catch null;
        if (old) |prev| self.allocator.free(prev.key);
        return stored;
    }

    pub fn get(self: *const Database, path: []const u8) ?LoadedFile {
        const idx = self.files.get(path) orelse return null;
        return self.storage.items[idx];
    }
};

/// The boot-order database list (DataManager.loadDatabase order; Map###
/// loads are demand-driven through setupMap — mirrored here by explicit
/// map requests).
pub const boot_database_files = [_][]const u8{
    "data/Actors.json",
    "data/Classes.json",
    "data/Skills.json",
    "data/Items.json",
    "data/Weapons.json",
    "data/Armors.json",
    "data/Enemies.json",
    "data/Troops.json",
    "data/States.json",
    "data/Animations.json",
    "data/Tilesets.json",
    "data/CommonEvents.json",
    "data/System.json",
    "data/MapInfos.json",
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "database loads MV files through the VFS with case variants" {
    const alloc = testing.allocator;
    const root = "/tmp/omori-db-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};
    const data_dir = try std.fs.path.join(alloc, &.{ root, "data" });
    defer alloc.free(data_dir);
    try std.fs.cwd().makePath(data_dir);
    {
        const p = try std.fs.path.join(alloc, &.{ root, "data", "Actors.json" });
        defer alloc.free(p);
        var f = try std.fs.cwd().createFile(p, .{});
        defer f.close();
        try f.writeAll("[null,{\"id\":1,\"name\":\"OMORI\",\"nickname\":\"...\"}]");
    }
    {
        const p = try std.fs.path.join(alloc, &.{ root, "data", "System.json" });
        defer alloc.free(p);
        var f = try std.fs.cwd().createFile(p, .{});
        defer f.close();
        try f.writeAll("{\"gameTitle\":\"OMORI\",\"switches\":[null,\"SW1\"],\"variables\":[null,\"V1\"]}");
    }

    var vfs = vfs_mod.Vfs.init(alloc, root, "/tmp/omori-db-save");
    defer vfs.deinit();
    var db = Database.init(alloc, &vfs);
    defer db.deinit();

    const actors = try db.loadFile(.database, "data/Actors.json");
    const arr = actors.value.arrayItems();
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expectEqualStrings("OMORI", arr[1].getString("name").?);

    // Case-variant resolution (the Android payload reads mixed case).
    const system = try db.loadFile(.database, "data/system.json");
    try testing.expectEqualStrings("OMORI", system.value.getString("gameTitle").?);

    // Lookup by path.
    try testing.expect(db.get("data/Actors.json") != null);
}
