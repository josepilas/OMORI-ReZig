//! Raw $dataMap structure + event/page/command shapes (milestone 4).
//!
//! Faithful port of what `Map###.json` contains (verified against the real
//! OMORI payload: Map001/011/504/986 spot-checked — event pages carry the
//! command lists; ~87 % of all parameters are integers, the rest strings,
//! a few booleans; command 505 carries nested command objects).
//!
//! Design: parsed with the tolerant JSON tree, then shallow-typed into
//! these structures (views over the arena — no copying of strings). The
//! event interpreter (M5) consumes `commands()` exactly like
//! `Game_Interpreter` consumes `list`.

const std = @import("std");
const json = @import("../data/json.zig");
const log = @import("../core/log.zig");

fn int32(v: i64) i32 {
    return @intCast(v);
}

/// MV note metadata: `<key>` → present, `<key: value>` → string value.
pub const Metadata = struct {
    alloc: std.mem.Allocator,
    keys: std.ArrayList([]const u8) = .empty,
    values: std.ArrayList([]const u8) = .empty,

    pub fn init(alloc: std.mem.Allocator) Metadata {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *Metadata) void {
        for (self.keys.items) |k| self.alloc.free(k);
        for (self.values.items) |v| self.alloc.free(v);
        self.keys.deinit(self.alloc);
        self.values.deinit(self.alloc);
    }

    pub fn put(self: *Metadata, key: []const u8, value: []const u8) void {
        const k = self.alloc.dupe(u8, key) catch return;
        const v = self.alloc.dupe(u8, value) catch {
            self.alloc.free(k);
            return;
        };
        self.keys.append(self.alloc, k) catch return;
        self.values.append(self.alloc, v) catch return;
    }

    pub fn get(self: *const Metadata, key: []const u8) ?[]const u8 {
        for (self.keys.items, 0..) |k, i| {
            if (std.mem.eql(u8, k, key)) return self.values.items[i];
        }
        return null;
    }

    pub fn count(self: *const Metadata) usize {
        return self.keys.items.len;
    }
};

/// A single event command (`{code, indent, parameters}`).
pub const Command = struct {
    code: i32,
    indent: i32,
    /// Raw parameter views (arena-owned JSON values).
    parameters: []const json.Value = &.{},
    /// Nested command objects (code 505 custom-move routes carry
    /// `{code, indent, parameters}` objects inside parameters).
    raw: ?json.Value = null,
};

pub const MoveRoute = struct {
    repeat: bool = false,
    skippable: bool = false,
    wait: bool = false,
    list: []Command = &.{},
};

pub const PageCondition = struct {
    actor_id: i32 = 0,
    actor_valid: bool = false,
    item_id: i32 = 0,
    item_valid: bool = false,
    self_switch_ch: []const u8 = "A",
    self_switch_valid: bool = false,
    switch1_id: i32 = 0,
    switch1_valid: bool = false,
    switch2_id: i32 = 0,
    switch2_valid: bool = false,
    variable_id: i32 = 0,
    variable_valid: bool = false,
    variable_value: i32 = 0,
};

pub const Page = struct {
    condition: PageCondition = .{},
    direction_fix: bool = false,
    image: ?json.Value = null,
    list: []Command = &.{},
    move_frequency: i32 = 3,
    move_route: MoveRoute = .{},
    move_speed: i32 = 3,
    move_type: i32 = 0,
    priority_type: i32 = 1,
    step_anime: bool = false,
    through: bool = false,
    trigger: i32 = 0,
    note: []const u8 = "",
    meta: Metadata,
};

pub const RawEvent = struct {
    id: i32,
    name: []const u8,
    x: i32,
    y: i32,
    pages: std.ArrayList(Page) = .empty,
    note: []const u8 = "",
    meta: Metadata,
};

pub const Encounter = struct {
    troop_id: i32,
    weight: i32,
    region_set: []const i32 = &.{},
};

pub const Bgm = struct {
    name: []const u8 = "",
    pan: i32 = 0,
    pitch: i32 = 100,
    volume: i32 = 90,
};

pub const RawMap = struct {
    alloc: std.mem.Allocator,
    /// Tile data rows (height rows × width columns × 6 layers), arena view.
    data: []const i32 = &.{},
    width: i32 = 0,
    height: i32 = 0,
    tileset_id: i32 = 0,
    display_name: []const u8 = "",
    note: []const u8 = "",
    meta: Metadata,
    events: std.ArrayList(?RawEvent) = .empty,
    encounter_list: []const Encounter = &.{},
    encounter_step: i32 = 30,
    autoplay_bgm: bool = false,
    autoplay_bgs: bool = false,
    bgm: Bgm = .{},
    bgs: Bgm = .{},
    disable_dashing: bool = false,
    parallax_name: []const u8 = "",
    parallax_loop_x: bool = false,
    parallax_loop_y: bool = false,
    parallax_sx: i32 = 0,
    parallax_sy: i32 = 0,
    parallax_show: bool = false,
    scroll_type: i32 = 0,
    specify_battleback: bool = false,
    battleback1_name: []const u8 = "",
    battleback2_name: []const u8 = "",

    pub fn deinit(self: *RawMap) void {
        self.meta.deinit();
        for (self.events.items) |*ev_opt| {
            if (ev_opt.*) |*ev| {
                ev.meta.deinit();
                for (ev.pages.items) |*page| {
                    page.meta.deinit();
                }
                ev.pages.deinit(self.alloc);
            }
        }
        self.events.deinit(self.alloc);
    }

    pub fn eventCount(self: *const RawMap) usize {
        var n: usize = 0;
        for (self.events.items) |e| {
            if (e != null) n += 1;
        }
        return n;
    }

    pub fn totalCommandCount(self: *const RawMap) usize {
        var n: usize = 0;
        for (self.events.items) |e_opt| {
            if (e_opt) |e| {
                for (e.pages.items) |p| n += p.list.len;
            }
        }
        return n;
    }

    // -----------------------------------------------------------------
    // Parsing (shallow views over the arena-parsed JSON tree)
    // -----------------------------------------------------------------

    pub fn fromJson(alloc: std.mem.Allocator, v: json.Value) !RawMap {
        var map = RawMap{
            .alloc = alloc,
            .meta = Metadata.init(alloc),
        };
        map.width = int32(v.getInt("width", 0));
        map.height = int32(v.getInt("height", 0));
        map.tileset_id = int32(v.getInt("tilesetId", 0));
        map.display_name = v.getString("displayName") orelse "";
        map.note = v.getString("note") orelse "";
        map.encounter_step = int32(v.getInt("encounterStep", 30));
        map.autoplay_bgm = v.getBool("autoplayBgm", false);
        map.autoplay_bgs = v.getBool("autoplayBgs", false);
        map.disable_dashing = v.getBool("disableDashing", false);
        map.parallax_name = v.getString("parallaxName") orelse "";
        map.parallax_loop_x = v.getBool("parallaxLoopX", false);
        map.parallax_loop_y = v.getBool("parallaxLoopY", false);
        map.parallax_sx = int32(v.getInt("parallaxSx", 0));
        map.parallax_sy = int32(v.getInt("parallaxSy", 0));
        map.parallax_show = v.getBool("parallaxShow", false);
        map.scroll_type = int32(v.getInt("scrollType", 0));
        map.specify_battleback = v.getBool("specifyBattleback", false);
        map.battleback1_name = v.getString("battleback1Name") orelse "";
        map.battleback2_name = v.getString("battleback2Name") orelse "";
        if (v.get("bgm")) |bgm| {
            map.bgm = .{
                .name = bgm.getString("name") orelse "",
                .pan = int32(bgm.getInt("pan", 0)),
                .pitch = int32(bgm.getInt("pitch", 100)),
                .volume = int32(bgm.getInt("volume", 90)),
            };
        }
        if (v.get("bgs")) |bgs| {
            map.bgs = .{
                .name = bgs.getString("name") orelse "",
                .pan = int32(bgs.getInt("pan", 0)),
                .pitch = int32(bgs.getInt("pitch", 100)),
                .volume = int32(bgs.getInt("volume", 90)),
            };
        }

        // data: array of numbers (height×width×6)
        if (v.get("data")) |d| {
            const items = d.arrayItems();
            var tiles = try alloc.alloc(i32, items.len);
            for (items, 0..) |item, i| tiles[i] = int32(item.asInt());
            map.data = tiles;
            const expected: usize = @as(usize, @intCast(@max(map.width, 0))) *
                @as(usize, @intCast(@max(map.height, 0))) * 6;
            if (expected != 0 and items.len != expected) {
                log.event(.data, .warn, "map data size {d} != expected {d} (w={d} h={d})", .{ items.len, expected, map.width, map.height });
            }
        }

        // encounterList
        if (v.get("encounterList")) |el| {
            const items = el.arrayItems();
            var encs = try alloc.alloc(Encounter, items.len);
            for (items, 0..) |item, i| {
                encs[i] = .{
                    .troop_id = int32(item.getInt("troopId", 0)),
                    .weight = int32(item.getInt("weight", 0)),
                };
            }
            map.encounter_list = encs;
        }

        // events (sparse array, index 0 null)
        if (v.get("events")) |evs| {
            const items = evs.arrayItems();
            try map.events.ensureTotalCapacity(alloc, items.len);
            for (items, 0..) |item, idx| {
                if (item == .null) {
                    try map.events.append(alloc, null);
                    continue;
                }
                var ev = RawEvent{
                    .id = int32(item.getInt("id", @intCast(idx))),
                    .name = item.getString("name") orelse "",
                    .x = int32(item.getInt("x", 0)),
                    .y = int32(item.getInt("y", 0)),
                    .note = item.getString("note") orelse "",
                    .meta = Metadata.init(alloc),
                };
                if (item.get("pages")) |pages| {
                    for (pages.arrayItems()) |pv| {
                        var page = Page{
                            .meta = Metadata.init(alloc),
                            .image = pv.get("image"),
                        };
                        // The flags and their IDs belong to the same MV
                        // conditions object. Some older fixtures use top-level fields.
                        const actor_item = pv.get("conditions") orelse pv;
                        page.condition = .{
                            .actor_id = int32(actor_item.getInt("actorId", pv.getInt("actorId", 0))),
                            .actor_valid = actor_item.getBool("actorValid", false),
                            .item_id = int32(actor_item.getInt("itemId", pv.getInt("itemId", 0))),
                            .item_valid = actor_item.getBool("itemValid", false),
                            .self_switch_ch = if (pv.get("conditions")) |c| (c.getString("selfSwitchCh") orelse "A") else "A",
                            .self_switch_valid = if (pv.get("conditions")) |c| c.getBool("selfSwitchValid", false) else false,
                            .switch1_id = if (pv.get("conditions")) |c| int32(c.getInt("switch1Id", 0)) else 0,
                            .switch1_valid = if (pv.get("conditions")) |c| c.getBool("switch1Valid", false) else false,
                            .switch2_id = if (pv.get("conditions")) |c| int32(c.getInt("switch2Id", 0)) else 0,
                            .switch2_valid = if (pv.get("conditions")) |c| c.getBool("switch2Valid", false) else false,
                            .variable_id = if (pv.get("conditions")) |c| int32(c.getInt("variableId", 0)) else 0,
                            .variable_valid = if (pv.get("conditions")) |c| c.getBool("variableValid", false) else false,
                            .variable_value = if (pv.get("conditions")) |c| int32(c.getInt("variableValue", 0)) else 0,
                        };
                        page.direction_fix = pv.getBool("directionFix", false);
                        page.move_frequency = int32(pv.getInt("moveFrequency", 3));
                        page.move_speed = int32(pv.getInt("moveSpeed", 3));
                        page.move_type = int32(pv.getInt("moveType", 0));
                        page.priority_type = int32(pv.getInt("priorityType", 1));
                        page.step_anime = pv.getBool("stepAnime", false);
                        page.through = pv.getBool("through", false);
                        page.trigger = int32(pv.getInt("trigger", 0));
                        page.note = pv.getString("note") orelse "";
                        if (pv.get("list")) |list| {
                            page.list = try parseCommands(alloc, list);
                        }
                        if (pv.get("moveRoute")) |mr| {
                            page.move_route = .{
                                .repeat = mr.getBool("repeat", false),
                                .skippable = mr.getBool("skippable", false),
                                .wait = mr.getBool("wait", false),
                                .list = if (mr.get("list")) |l| try parseCommands(alloc, l) else &.{},
                            };
                        }
                        try ev.pages.append(alloc, page);
                    }
                }
                try map.events.append(alloc, ev);
            }
        }
        return map;
    }
};

/// Parse a raw JSON array of `{code, indent, parameters}` objects into
/// Command views (arena-owned). Public: the interpreter (M5) uses it for
/// common-event lists and YEP_CallEvent page lists.
pub fn parseCommands(alloc: std.mem.Allocator, list: json.Value) ![]Command {
    const items = list.arrayItems();
    var cmds = try alloc.alloc(Command, items.len);
    for (items, 0..) |item, i| {
        var params: []const json.Value = &.{};
        if (item.get("parameters")) |p| {
            if (p == .array) params = p.array.items;
        }
        cmds[i] = .{
            .code = int32(item.getInt("code", 0)),
            .indent = int32(item.getInt("indent", 0)),
            .parameters = params,
            .raw = item,
        };
    }
    return cmds;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "raw map parses the full shape" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const src =
        \\{"autoplayBgm":true,"autoplayBgs":false,"battleback1Name":"","battleback2Name":"",
        \\"bgm":{"name":"battle1","pan":0,"pitch":100,"volume":90},
        \\"data":[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24],
        \\"disableDashing":false,"displayName":"TEST MAP","encounterList":[],
        \\"encounterStep":30,"height":2,"note":"map note <mkey: mval>",
        \\"parallaxLoopX":false,"parallaxName":"","parallaxShow":true,"parallaxSx":0,
        \\"parallaxSy":0,"scrollType":0,"specifyBattleback":false,"tilesetId":1,"width":2,
        \\"events":[null,{"id":1,"name":"EV001","note":"ev note <etag>","x":3,"y":4,
        \\"pages":[{"conditions":{"actorId":1,"actorValid":false,"itemId":1,"itemValid":false,
        \\"selfSwitchCh":"A","selfSwitchValid":true,"switch1Id":1,"switch1Valid":false,
        \\"switch2Id":2,"switch2Valid":false,"variableId":3,"variableValid":true,"variableValue":5},
        \\"directionFix":false,"image":{"characterIndex":0,"characterName":"","direction":2,
        \\"pattern":1,"tileId":0},"list":[{"code":101,"indent":0,"parameters":["face",0,0,2]},
        \\{"code":401,"indent":0,"parameters":["Hello"]},{"code":0,"indent":0}],
        \\"moveFrequency":3,"moveRoute":{"list":[{"code":0,"indent":null}],"repeat":true,
        \\"skippable":false,"wait":false},"moveSpeed":3,"moveType":0,"priorityType":1,
        \\"stepAnime":false,"through":false,"trigger":0}]}]}
    ;
    var parser = try json.Parser.init(a, src);
    const v = try parser.parse();
    var map = try RawMap.fromJson(a, v);
    defer map.deinit();

    try testing.expectEqual(@as(i32, 2), map.width);
    try testing.expectEqual(@as(i32, 2), map.height);
    try testing.expectEqual(@as(usize, 24), map.data.len);
    try testing.expectEqualStrings("TEST MAP", map.display_name);
    try testing.expectEqual(@as(i32, 1), map.tileset_id);
    try testing.expect(map.autoplay_bgm);
    try testing.expectEqualStrings("battle1", map.bgm.name);
    try testing.expectEqual(@as(usize, 1), map.eventCount());
    try testing.expectEqual(@as(usize, 3), map.totalCommandCount());

    const ev = map.events.items[1].?;
    try testing.expectEqual(@as(i32, 1), ev.id);
    try testing.expectEqualStrings("EV001", ev.name);
    try testing.expectEqual(@as(i32, 3), ev.x);

    const page = ev.pages.items[0];
    try testing.expectEqual(@as(usize, 3), page.list.len);
    try testing.expectEqual(@as(i32, 101), page.list[0].code);
    try testing.expectEqualStrings("Hello", page.list[1].parameters[0].string);
    try testing.expect(page.condition.self_switch_valid);
    try testing.expectEqual(@as(i32, 5), page.condition.variable_value);
    try testing.expect(page.move_route.repeat);
}
