//! Exercise the actual map and battle setup paths over a supplied game catalog.
const std = @import("std");
const data = @import("src/data/database.zig");
const vfs_mod = @import("src/filesystem/vfs.zig");
const game_mod = @import("src/mv/game.zig");
const dm_mod = @import("src/mv/data_manager.zig");
const battle = @import("src/mv/battle.zig");

pub fn main() !void {
    const a = std.heap.smp_allocator;
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    if (args.len != 2) return error.ExpectedGameRoot;
    var vfs = vfs_mod.Vfs.init(a, args[1], "");
    defer vfs.deinit();
    var db = data.Database.init(a, &vfs);
    defer db.deinit();
    for (data.boot_database_files) |file| _ = try db.loadFile(.database, file);
    var dm = dm_mod.DataManager.init(a, &db);
    defer dm.deinit();
    var game = game_mod.GameObjects.init(a, &db);
    defer game.deinit();
    try dm.setupNewGame(&game);
    var maps: usize = 0;
    var absent: usize = 0;
    var tiled: usize = 0;
    var events: usize = 0;
    var commands: usize = 0;
    for (db.get("data/MapInfos.json").?.value.arrayItems(), 0..) |info, i| {
        if (info == .null) continue;
        const id: u32 = @intCast(i);
        var buf: [48]u8 = undefined;
        const raw_path = try std.fmt.bufPrint(&buf, "data/Map{d:0>3}.json", .{id});
        if (!vfs.existsSync(raw_path)) {
            std.debug.print("catalog entry {d} has no supplied map file\n", .{id});
            absent += 1;
            continue;
        }
        dm.resetMapArena();
        try dm.loadMapData(&vfs, id);
        const raw = &dm.data_map.?;
        try game.map.setup(raw, id);
        const path = try std.fmt.bufPrint(&buf, "maps/Map{d}.json", .{id});
        if (dm.tiled_map) |*map| {
            game.map.setupTiled(raw, map);
            tiled += 1;
        } else if (vfs.existsSync(path)) return error.TiledMapFailed;
        if (game.map.map_id != id or game.map.width <= 0 or game.map.height <= 0) return error.InvalidMap;
        events += raw.eventCount();
        commands += raw.totalCommandCount();
        maps += 1;
    }
    var troops: usize = 0;
    var empty: usize = 0;
    var enemies: usize = 0;
    for (db.get("data/Troops.json").?.value.arrayItems(), 0..) |record, i| {
        if (record == .null) continue;
        const members = record.get("members").?.arrayItems();
        if (members.len == 0) {
            empty += 1;
            continue;
        }
        var troop = battle.Troop.init(a, &db);
        defer troop.deinit();
        var manager = battle.Manager.init(a, &db, &game, &troop, 1);
        defer manager.deinit();
        manager.setup(@intCast(i), true, false);
        if (troop.enemies.items.len != members.len) {
            std.debug.print("troop {d} expected {d} members, initialized {d}\n", .{i, members.len, troop.enemies.items.len});
            return error.IncompleteTroop;
        }
        manager.startBattle();
        enemies += members.len;
        troops += 1;
    }
    if (maps == 0 or troops == 0) return error.EmptyCatalog;
    std.debug.print("CATALOG PASS supplied_maps={d} missing_catalog_files={d} tiled={d} events={d} event_commands={d} populated_troops={d} enemy_instances={d} empty_troop_records={d}\n", .{maps,absent,tiled,events,commands,troops,enemies,empty});
}
