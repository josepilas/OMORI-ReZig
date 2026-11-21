//! Shared RPG Maker encounter rules for walking and event-command 301.
const std = @import("std");
const map = @import("map.zig");
const json = @import("../data/json.zig");
const database = @import("../data/database.zig");

pub fn rollCountdown(step: i32, random: std.Random) ?f64 {
    if (step <= 0) return null;
    const range: u32 = @intCast(step);
    const first = random.uintLessThan(u32, range);
    const second = random.uintLessThan(u32, range);
    return @floatFromInt(@as(u64, first) + second + 1);
}

pub fn selectTroop(entries: []const map.Encounter, region: i32, random: std.Random) ?i32 {
    var total: u64 = 0;
    for (entries) |entry| total += eligibleWeight(entry, region);
    if (total == 0) return null;

    var pick = random.uintLessThan(u64, total);
    for (entries) |entry| {
        const weight = eligibleWeight(entry, region);
        if (pick < weight) return entry.troop_id;
        pick -= weight;
    }
    unreachable;
}

fn eligibleWeight(entry: map.Encounter, region: i32) u64 {
    if (entry.weight <= 0 or entry.troop_id <= 0) return 0;
    if (entry.region_set.len > 0 and std.mem.indexOfScalar(i32, entry.region_set, region) == null) return 0;
    return @intCast(entry.weight);
}

pub fn plainRegion(raw: *const map.RawMap, x: i32, y: i32) i32 {
    return tileId(raw, x, y, 5);
}

fn tileId(raw: *const map.RawMap, x: i32, y: i32, layer: usize) i32 {
    if (x < 0 or y < 0 or x >= raw.width or y >= raw.height) return 0;
    const width: usize = @intCast(raw.width);
    const height: usize = @intCast(raw.height);
    const row = layer * height + @as(usize, @intCast(y));
    const row_start = std.math.mul(usize, row, width) catch return 0;
    const index = std.math.add(usize, row_start, @intCast(x)) catch return 0;
    if (index >= raw.data.len) return 0;
    return raw.data[index];
}

pub fn isBush(db: *database.Database, raw: *const map.RawMap, x: i32, y: i32) bool {
    const tileset = record(db, "data/Tilesets.json", raw.tileset_id) orelse return false;
    const flags = (tileset.get("flags") orelse return false).arrayItems();
    for (0..4) |layer| {
        const tile = tileId(raw, x, y, layer);
        if (tile >= 0 and tile < flags.len and (flags[@intCast(tile)].asInt() & 0x40) != 0) return true;
    }
    return false;
}

pub fn record(db: *database.Database, path: []const u8, id: i32) ?json.Value {
    if (id <= 0) return null;
    const records = (db.get(path) orelse return null).value.arrayItems();
    if (id >= records.len) return null;
    const value = records[@intCast(id)];
    return if (value == .object) value else null;
}

pub const Traits = packed struct(u2) {
    half: bool = false,
    none: bool = false,

    pub fn addRecord(self: *Traits, source: ?json.Value) void {
        const data = source orelse return;
        const traits = (data.get("traits") orelse return).arrayItems();
        for (traits) |trait| {
            if (trait.getInt("code", 0) != 64) continue;
            switch (trait.getInt("dataId", -1)) {
                0 => self.half = true,
                1 => self.none = true,
                else => {},
            }
        }
    }
};

test "encounter: countdown range and weights use an independent random stream" {
    var rng = std.Random.DefaultPrng.init(0x81f0);
    const random = rng.random();
    try std.testing.expect(rollCountdown(0, random) == null);
    try std.testing.expectEqual(@as(?f64, 1), rollCountdown(1, random));
    var counts: [2]usize = .{ 0, 0 };
    const entries = [_]map.Encounter{
        .{ .troop_id = 1, .weight = 4 },
        .{ .troop_id = 2, .weight = 12, .region_set = &.{7} },
        .{ .troop_id = 3, .weight = 100, .region_set = &.{8} },
        .{ .troop_id = 4, .weight = 0, .region_set = &.{7} },
    };
    for (0..512) |_| {
        const steps = rollCountdown(20, random).?;
        try std.testing.expect(steps >= 1 and steps <= 39);
        const troop = selectTroop(&entries, 7, random).?;
        try std.testing.expect(troop == 1 or troop == 2);
        counts[@intCast(troop - 1)] += 1;
    }
    try std.testing.expect(counts[0] > 80 and counts[0] < 176);
    try std.testing.expectEqual(@as(?i32, 1), selectTroop(&entries, 0, random));
    try std.testing.expect(selectTroop(entries[1..], 0, random) == null);
}
