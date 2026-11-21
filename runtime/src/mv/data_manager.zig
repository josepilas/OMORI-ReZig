//! DataManager — the MV `DataManager` semantics OMORI's boot actually
//! exercises (milestone 4). Ported from `js/rpg_managers.js`:
//!
//!   * `loadDatabase` — the 14-file boot list (the V22 Database loader).
//!   * `onLoad` → `extractMetadata` — note strings → `{name, meta}` tags
//!     (MV's `<tag: value>` convention); needed before any event runs.
//!   * `checkPlayerLocation` — $dataSystem.startMapId !== 0.
//!   * `createGameObjects` — the full $gameXxx set.
//!   * `setupNewGame` — createGameObjects + selectSavefileForNewGame +
//!     setupStartingMembers + reserveTransfer(startMapId, startX, startY)
//!     + Graphics.frameCount = 0.
//!   * Map data on demand: `loadMapData(mapId)` → $dataMap semantics
//!     (error classified when the Map file is missing).
//!
//! Honest scope: save-file selection prefers slot 1 (MV's
//! `selectSavefileForNewGame` semantics: the first editable savefile —
//! with no save system yet, always slot 1).

const std = @import("std");
const log = @import("../core/log.zig");
const json = @import("../data/json.zig");
const database = @import("../data/database.zig");
const vfs_mod = @import("../filesystem/vfs.zig");
const game_mod = @import("game.zig");
const map_mod = @import("map.zig");
const tiled_mod = @import("tiled.zig");

pub const DataManager = struct {
    alloc: std.mem.Allocator,
    db: *database.Database,
    map_arena: std.heap.ArenaAllocator,

    /// The loaded $dataMap (null until setupMap succeeds).
    data_map: ?map_mod.RawMap = null,
    data_map_id: u32 = 0,

    /// v36: the Tiled subsystem for this map — YED_Tiled's
    /// `$gameMap.tiledData`, loaded alongside the MV map (null for plain
    /// MV maps). Arena-owned, no deinit (reset with the arena).
    tiled_map: ?tiled_mod.TiledMap = null,

    frame_count: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, db: *database.Database) DataManager {
        return .{
            .alloc = alloc,
            .db = db,
            .map_arena = std.heap.ArenaAllocator.init(alloc),
        };
    }

    pub fn deinit(self: *DataManager) void {
        self.map_arena.deinit();
    }

    // -----------------------------------------------------------------
    // System accessors
    // -----------------------------------------------------------------

    pub fn system(self: *const DataManager) ?json.Value {
        const f = self.db.get("data/System.json") orelse return null;
        return f.value;
    }

    pub fn gameTitle(self: *const DataManager) []const u8 {
        if (self.system()) |s| {
            if (s.getString("gameTitle")) |t| return t;
        }
        return "(unknown)";
    }

    pub fn startMapId(self: *const DataManager) u32 {
        if (self.system()) |s| return @intCast(@max(s.getInt("startMapId", 0), 0));
        return 0;
    }

    // -----------------------------------------------------------------
    // Scene_Boot semantics
    // -----------------------------------------------------------------

    /// `checkPlayerLocation` — throws in MV when startMapId === 0.
    pub fn checkPlayerLocation(self: *const DataManager) !void {
        if (self.startMapId() == 0) {
            log.event(.mv, .fatal, "FATAL_MAP: player starting position is not set ($dataSystem.startMapId == 0)", .{});
            return error.NoPlayerStart;
        }
        log.detail(.mv, "checkPlayerLocation ok: startMapId={d}", .{self.startMapId()});
    }

    /// `createGameObjects` — the complete $gameXxx set, MV order.
    pub fn createGameObjects(self: *const DataManager, game: *game_mod.GameObjects) !void {
        _ = self;
        log.event(.mv, .info, "DataManager.createGameObjects", .{});
        try game.create();
    }

    /// `setupNewGame`.
    pub fn setupNewGame(self: *DataManager, game: *game_mod.GameObjects) !void {
        log.section("DataManager.setupNewGame");
        try self.createGameObjects(game);

        // selectSavefileForNewGame: first editable slot (no saves yet → 1).
        game.selectSavefileForNewGame();

        try game.party.setupStartingMembers(self);
        const sys = self.system();
        const map_id: u32 = if (sys) |s| @intCast(@max(s.getInt("startMapId", 0), 0)) else 0;
        const x: i32 = if (sys) |s| @intCast(s.getInt("startX", 0)) else 0;
        const y: i32 = if (sys) |s| @intCast(s.getInt("startY", 0)) else 0;
        game.player.reserveTransfer(map_id, x, y, null, 0);
        self.frame_count = 0;

        log.event(.mv, .info, "new game: startMapId={d} start=({d},{d}) party={d} actor(s)", .{
            map_id, x, y, game.party.members.items.len,
        });
    }

    // -----------------------------------------------------------------
    // Map loading ($dataMap)
    // -----------------------------------------------------------------

    /// `loadMapData` + `onLoad` — loads MapNNN.json through the VFS and
    /// extracts map + event + page metadata (extractMetadata on every
    /// object with a `note`).
    pub fn loadMapData(self: *DataManager, vfs: *vfs_mod.Vfs, map_id: u32) !void {
        var name_buf: [32]u8 = undefined;
        const path = std.fmt.bufPrint(&name_buf, "data/Map{d:0>3}.json", .{map_id}) catch return error.BadMapId;

        const t0 = std.time.milliTimestamp();
        const text = vfs.readFileSync(path) catch |e| {
            log.event(.data, .err, "FATAL_MAP: '{s}' unreadable ({s})", .{ path, @errorName(e) });
            return e;
        };
        defer vfs.allocator.free(text);
        const dt = std.time.milliTimestamp() - t0;

        var parser = json.Parser.init(self.map_arena.allocator(), text) catch return error.OutOfMemory;
        const value = parser.parse() catch |e| {
            log.event(.data, .err, "FATAL_MAP: '{s}' parse failed ({s})", .{ path, @errorName(e) });
            return e;
        };

        var raw = map_mod.RawMap.fromJson(self.map_arena.allocator(), value) catch return error.OutOfMemory;
        // extractMetadata: map note + every event + every page note.
        extractMetadataInto(&raw.meta, raw.note);
        for (raw.events.items) |ev_opt| {
            if (ev_opt) |ev| {
                extractMetadataInto(&raw.events.items[@intCast(ev.id)].?.meta, ev.note);
                for (raw.events.items[@intCast(ev.id)].?.pages.items, 0..) |_, pi| {
                    const page = &raw.events.items[@intCast(ev.id)].?.pages.items[pi];
                    extractMetadataInto(&page.meta, page.note);
                }
            }
        }

        self.data_map = raw;
        self.data_map_id = map_id;
        log.event(.data, .note, "$dataMap loaded: {s} ({d} ms, {d}x{d}, {d} events, {d} commands total)", .{
            path, dt, raw.width, raw.height, raw.eventCount(), raw.totalCommandCount(),
        });

        // v36: YED_Tiled's load hook (DataManager.onLoad →
        // loadTiledMapData): `maps/Map{mapId}.json`. Null when the file
        // is absent — the MV path serves plain maps too; OMORI's payload
        // carries both shapes side by side.
        self.tiled_map = tiled_mod.TiledMap.load(self.map_arena.allocator(), vfs, map_id);
    }

    /// v36: free the map arena between loads — RawMap, TiledMap and the
    /// interpreter's command lists all live there. ONLY legal when the
    /// interpreter chain is idle (GameLoop gates on
    /// `itp.chainRunning()`); skipping the reset leaks that cycle's map
    /// into the arena until the next idle load (retain_capacity keeps
    /// the pages for reuse).
    pub fn resetMapArena(self: *DataManager) void {
        if (self.data_map != null or self.tiled_map != null) {
            log.event(.data, .note, "map arena reset (retain capacity)", .{});
        }
        self.data_map = null;
        self.tiled_map = null;
        _ = self.map_arena.reset(.retain_capacity);
    }

    /// Map infos tree ($dataMapInfos) — name lookup for diagnostics.
    pub fn mapName(self: *DataManager, map_id: u32) []const u8 {
        const f = self.db.get("data/MapInfos.json") orelse return "(no MapInfos)";
        const items = f.value.arrayItems();
        if (map_id < items.len) {
            if (items[map_id] == .object) {
                if (items[map_id].getString("name")) |n| return n;
            }
        }
        return "(unnamed)";
    }
};

// ---------------------------------------------------------------------------
// extractMetadata — MV's note-tag convention
// ---------------------------------------------------------------------------

/// MV `DataManager.extractMetadata`: `note` → `{ name, meta }` where meta
/// collects `<key: value>` / `<key>` tags. OMORI's maps/events/pages carry
/// notes used by plugins (Yami's, OMORI's own) — the interpreter milestone
/// consumes them; here we only parse faithfully.
pub fn extractMetadataInto(meta: *map_mod.Metadata, note: []const u8) void {
    if (note.len == 0) return;
    var start: ?usize = null;
    var i: usize = 0;
    while (i < note.len) : (i += 1) {
        if (note[i] == '<') {
            start = i + 1;
        } else if (note[i] == '>' and start != null) {
            const tag = std.mem.trim(u8, note[start.?..i], " \t\r\n");
            if (tag.len > 0) {
                if (std.mem.indexOfScalar(u8, tag, ':')) |colon| {
                    const key = std.mem.trim(u8, tag[0..colon], " \t");
                    const val = std.mem.trim(u8, tag[colon + 1 ..], " \t");
                    if (key.len > 0) meta.put(key, val);
                } else {
                    meta.put(tag, "");
                }
            }
            start = null;
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "extractMetadata: MV note tags" {
    const m = struct {
        fn run() !void {
            var meta = map_mod.Metadata.init(testing.allocator);
            defer meta.deinit();
            extractMetadataInto(&meta, "plain <flag1> <key: value2> text <another:multi word>");
            try testing.expectEqual(@as(usize, 3), meta.count());
            try testing.expectEqualStrings("", meta.get("flag1").?);
            try testing.expectEqualStrings("value2", meta.get("key").?);
            try testing.expectEqualStrings("multi word", meta.get("another").?);
        }
    };
    try m.run();
}

test "data manager: game title and start location from System.json" {
    const alloc = testing.allocator;
    const root = "/tmp/omori-dm-test";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};
    const data_dir = try std.fs.path.join(alloc, &.{ root, "data" });
    defer alloc.free(data_dir);
    try std.fs.cwd().makePath(data_dir);
    {
        const p = try std.fs.path.join(alloc, &.{ root, "data", "System.json" });
        defer alloc.free(p);
        var f = try std.fs.cwd().createFile(p, .{});
        defer f.close();
        try f.writeAll("{\"gameTitle\":\"OMORI\",\"startMapId\":999,\"startX\":1,\"startY\":0,\"partyMembers\":[1],\"switches\":[null],\"variables\":[null]}");
    }

    var vfs = vfs_mod.Vfs.init(alloc, root, "/tmp/omori-dm-save");
    defer vfs.deinit();
    var db = database.Database.init(alloc, &vfs);
    defer db.deinit();
    _ = try db.loadFile(.database, "data/System.json");

    var dm = DataManager.init(alloc, &db);
    defer dm.deinit();

    try testing.expectEqualStrings("OMORI", dm.gameTitle());
    try testing.expectEqual(@as(u32, 999), dm.startMapId());
    try dm.checkPlayerLocation();
}
