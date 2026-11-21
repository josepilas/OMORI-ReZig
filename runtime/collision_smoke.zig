//! Read-only reproduction of the Map088 table collision trap.
//! zig build-exe collision_smoke.zig -lc -O Debug -femit-bin=/tmp/collision-smoke
//! collision-smoke /external/prepared/assets/www
const std = @import("std");
const tiled_mod = @import("src/mv/tiled.zig");
const vfs_mod = @import("src/filesystem/vfs.zig");
const database = @import("src/data/database.zig");
const json = @import("src/data/json.zig");
const game_mod = @import("src/mv/game.zig");
const map_mod = @import("src/mv/map.zig");
const moves = [_][3]i32{ .{ 0, -1, 8 }, .{ -1, 0, 4 }, .{ 1, 0, 6 }, .{ 0, 1, 2 } };

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    if (args.len != 2) return error.ExpectedExternalGameRoot;
    var vfs = vfs_mod.Vfs.init(a, args[1], "/tmp/omori-collision-smoke-unused");
    defer vfs.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const map = tiled_mod.TiledMap.load(arena.allocator(), &vfs, 88) orelse return error.Map88Missing;
    const width: usize = @intCast(map.width);
    const count: usize = width * @as(usize, @intCast(map.height));
    if (map.isPassable(0, 11, 20, 6)) return error.ExpectedAuthoredSolidTableTile;
    const reachable = try a.alloc(bool, count);
    defer a.free(reachable);
    @memset(reachable, false);
    const queue = try a.alloc([2]i32, count);
    defer a.free(queue);
    queue[0] = .{ 20, 22 }; // Actual White Space door transfer destination.
    reachable[22 * width + 20] = true;
    var head: usize = 0;
    var tail: usize = 1;
    var rejected_solid_entries: usize = 0;
    var exact_table_entry_seen = false;
    while (head < tail) : (head += 1) {
        const pos = queue[head];
        for (moves) |move| {
            const nx = pos[0] + move[0];
            const ny = pos[1] + move[1];
            if (nx < 0 or ny < 0 or nx >= map.width or ny >= map.height) continue;
            const source_only = map.isPassable(0, pos[0], pos[1], move[2]);
            const allowed = map.canStep(0, pos[0], pos[1], move[2]);
            if (source_only and !map.isPassable(0, nx, ny, 10 - move[2])) {
                if (allowed) return error.SolidDestinationEntered;
                rejected_solid_entries += 1;
                if (nx == 11 and ny == 20) {
                    exact_table_entry_seen = true;
                    std.debug.print("table trap rejected: ({d},{d}) -> (11,20), direction {d}\n", .{ pos[0], pos[1], move[2] });
                }
            }
            if (!allowed) continue;
            if (!map.canStep(0, nx, ny, 10 - move[2])) return error.PlayerCouldNotStepBack;
            const index = @as(usize, @intCast(ny)) * width + @as(usize, @intCast(nx));
            if (reachable[index]) continue;
            reachable[index] = true;
            queue[tail] = .{ nx, ny };
            tail += 1;
        }
    }
    if (!exact_table_entry_seen or reachable[20 * width + 11]) return error.TableTrapNotReproduced;
    // The friends' side of the room remains reachable; collision is not
    // disabled to solve the trap. Normal event collision is tested separately.
    if (!reachable[22 * width + 12] or !reachable[18 * width + 14]) return error.FriendsAreaUnreachable;
    std.debug.print("COLLISION SMOKE PASS: Map088 reachable floor {d} cells, {d} invalid solid/arrow entries rejected, table (11,20) never entered, all legal steps reversible\n", .{ tail, rejected_solid_entries });

    // A legacy native save could already be inside the solid table.
    // Use the actual map/events with the intro complete, but no disk save
    // writes: the recovery remains a read-only query until the load hook.
    var db = database.Database.init(a, &vfs);
    defer db.deinit();
    _ = try db.loadFile(.database, "data/System.json");
    var game = game_mod.GameObjects.init(a, &db);
    try game.create();
    defer game.deinit();
    const raw_text = try vfs.readFileSync("data/Map088.json");
    defer a.free(raw_text);
    var parser = try json.Parser.init(arena.allocator(), raw_text);
    var raw = try map_mod.RawMap.fromJson(arena.allocator(), try parser.parse());
    try game.map.setup(&raw, 88);
    game.map.tiled = &map;
    game.self_switches.setValue(88, 23, "C", true); // introCam's completed page.
    game.player.map_id = 88;
    game.player.x = 11;
    game.player.y = 20;
    game.temp.legacy_collision_recovery = true;
    const recovery = (try game.map.findLegacyCollisionRecovery(&raw, &game)) orelse return error.LegacyTableRecoveryMissing;
    if (@abs(recovery[0] - 11) + @abs(recovery[1] - 20) != 1) return error.RecoveryMovedTooFar;
    if (map.isSolid(0, recovery[0], recovery[1])) return error.RecoveryStillSolid;
    if (game.player.x != 11 or game.player.y != 20) return error.RecoveryQueryMutatedPlayer;
    game.temp.legacy_collision_recovery = false;
    if ((try game.map.findLegacyCollisionRecovery(&raw, &game)) != null) return error.NewSaveIncorrectlyRecovered;
    std.debug.print("LEGACY COLLISION SMOKE PASS: Map088 table save (11,20) has safe adjacent recovery ({d},{d}); normal/new-save positions unchanged\n", .{ recovery[0], recovery[1] });
}
