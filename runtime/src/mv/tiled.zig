//! v36 — the YED_Tiled subsystem: OMORI's Tiled maps, ported from
//! `js/plugins/YED_Tiled.js` against the real payload (`maps/MapNNN.json`
//! + external tileset JSONs in the same directory).
//!
//! What lives here:
//!   * parsing — tolerant JSON tree → typed structures, EVERYTHING
//!     allocated from the map arena (TiledMap has no deinit; the arena
//!     reset frees it wholesale — see data_manager.resetMapArena).
//!   * external tileset merge — `source` → basename → `maps/<base>`,
//!     Object.assign semantics (external fields win, parent `firstgid`
//!     survives because the external file has none).
//!   * the per-level arrays — collision (0/1), arrow bits (left=1 up=2
//!     right=4 down=8, initialized ALL-PASS = 15), regions, level_change
//!     (−1 = none) — built by the four `_setupXxx` passes in FILE ORDER
//!     with `!!data[x]` gating and `parseInt(props) || 0` levels.
//!   * queries — isPassable (arrow gate + collision), regionId,
//!     levelChangeAt — the Game_Map Tiled overrides.
//!   * tile animation — flat state (frame + duration, f64, decremented
//!     every frame), keyed by LOCAL tile id with last-tileset-wins merge,
//!     `_getAnimTileId` resolution at draw time.
//!   * paint classification — paintable tilelayer / priority layer /
//!     hideOnLevel, for the renderer.
//!
//! Faithfulness notes (verified against the plugin source, module 76):
//!   * OOB map writes (idx ≥ width*height) are SKIPPED — the JS writes
//!     them into a sparse array, but every read is bounds-gated, so the
//!     observable behavior is identical.
//!   * a `toLevel` prop that fails parseInt is SKIPPED — JS writes NaN,
//!     and NaN < 0 is false, so checkMapLevelChanging would "succeed"
//!     with NaN; the payload never does this.
//!   * an animation frame out of range AT DRAW returns the local tile id
//!     — the JS would throw (`animation[frame].tileid` on undefined);
//!     only reachable when two tilesets animate the same local id.
//!   * levels are built contiguously 0..max — the JS builds them lazily
//!     in file order and would crash reading an undefined level; the
//!     payload never skips a level.

const std = @import("std");
const log = @import("../core/log.zig");
const json = @import("../data/json.zig");
const vfs_mod = @import("../filesystem/vfs.zig");

// ---------------------------------------------------------------------------
// YED_Tiled plugin parameters (payload `js/plugins.js`, verified verbatim).
// ---------------------------------------------------------------------------

pub const Z_PLAYER: i32 = 3;
pub const Z_BELOW_PLAYER: i32 = 1;
pub const Z_ABOVE_PLAYER: i32 = 5;
pub const PRIORITY_TILES_LIMIT: usize = 256;
pub const MAP_LEVEL_VAR: i32 = 26;

/// MV direction codes → arrow bit (`_getArrowBit`: left 1, up 2,
/// right 4, down 8).
pub fn arrowBitForDirection(d: i32) u8 {
    return switch (d) {
        4 => 1,
        8 => 2,
        6 => 4,
        2 => 8,
        else => 0,
    };
}

// ---------------------------------------------------------------------------
// JS number-string helpers
// ---------------------------------------------------------------------------

/// JS `parseInt(str)` semantics: leading whitespace skipped, optional
/// sign, decimal digits (or 0x hex); null when no parseable prefix (NaN).
pub fn parseIntJs(str: []const u8) ?i32 {
    var i: usize = 0;
    while (i < str.len and (str[i] == ' ' or str[i] == '\t' or str[i] == '\r' or str[i] == '\n')) : (i += 1) {}
    var neg = false;
    if (i < str.len and (str[i] == '+' or str[i] == '-')) {
        neg = str[i] == '-';
        i += 1;
    }
    if (i + 1 < str.len and str[i] == '0' and (str[i + 1] == 'x' or str[i + 1] == 'X')) {
        i += 2;
        var acc: i64 = 0;
        var any = false;
        while (i < str.len) : (i += 1) {
            const d = std.fmt.charToDigit(str[i], 16) catch break;
            acc = acc * 16 + @as(i64, @intCast(d));
            if (acc > std.math.maxInt(i32)) acc = std.math.maxInt(i32);
            any = true;
        }
        if (!any) return null;
        return @intCast(if (neg) -acc else acc);
    }
    var acc: i64 = 0;
    var any = false;
    while (i < str.len and str[i] >= '0' and str[i] <= '9') : (i += 1) {
        acc = acc * 10 + @as(i64, str[i] - '0');
        if (acc > std.math.maxInt(i32)) acc = std.math.maxInt(i32);
        any = true;
    }
    if (!any) return null;
    return @intCast(if (neg) -acc else acc);
}

/// `parseInt(x) || 0` — the `|| 0` folds NaN and 0 together, so a failed
/// parse is exactly the default.
pub fn parseIntOr(v: json.Value, default: i32) i32 {
    return switch (v) {
        .number => |n| blk: {
            if (std.math.isNan(n) or std.math.isInf(n)) break :blk default;
            const t: f64 = @trunc(n);
            if (t > std.math.maxInt(i32) or t < std.math.minInt(i32)) break :blk default;
            break :blk @intFromFloat(t);
        },
        .string => |s| parseIntJs(s) orelse default,
        .boolean => |b| if (b) 1 else 0,
        else => default,
    };
}

/// JSON scalar → string view (numbers/booleans formatted into the arena,
/// so callers can run the JS string ops on them verbatim).
fn valStr(arena: std.mem.Allocator, v: json.Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        .number => |n| std.fmt.allocPrint(arena, "{d}", .{n}) catch "",
        .boolean => |b| if (b) "true" else "false",
        else => "",
    };
}

// ---------------------------------------------------------------------------
// Property bags (object style in the payload; array style tolerated)
// ---------------------------------------------------------------------------

pub const Prop = struct { key: []const u8, val: []const u8 };

pub const Props = struct {
    entries: []Prop = &.{},

    pub fn has(self: Props, key: []const u8) bool {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.key, key)) return true;
        }
        return false;
    }

    pub fn str(self: Props, key: []const u8) []const u8 {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.key, key)) return e.val;
        }
        return "";
    }

    pub fn int(self: Props, key: []const u8, default: i32) i32 {
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.key, key)) return parseIntJs(e.val) orelse default;
        }
        return default;
    }

    fn fromValue(arena: std.mem.Allocator, v: ?json.Value) Props {
        const pv = v orelse return .{};
        switch (pv) {
            .object => {
                const entries = pv.objectEntries();
                const out = arena.alloc(Prop, entries.len) catch return .{};
                for (entries, 0..) |e, i| {
                    out[i] = .{ .key = e.key, .val = valStr(arena, e.value) };
                }
                return .{ .entries = out };
            },
            .array => {
                const items = pv.arrayItems();
                const out = arena.alloc(Prop, items.len) catch return .{};
                for (items, 0..) |item, i| {
                    const name = item.getString("name") orelse "";
                    out[i] = .{ .key = name, .val = valStr(arena, item.get("value") orelse .null) };
                }
                return .{ .entries = out };
            },
            else => return .{},
        }
    }
};

// ---------------------------------------------------------------------------
// Structures
// ---------------------------------------------------------------------------

pub const LayerKind = enum { tilelayer, objectgroup, other };

pub const TiledObject = struct {
    gid: i32 = 0,
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
    visible: bool = true,
    /// `properties.eventId` — parseInt, 0 when absent (event relocation).
    event_id: i32 = 0,
};

pub const TiledLayer = struct {
    name: []const u8 = "",
    kind: LayerKind = .other,
    visible: bool = true,
    /// tilelayer gid grid (row-major, w*h); 0 = empty. Empty for
    /// objectgroups/other kinds.
    data: []i32 = &.{},
    objects: []TiledObject = &.{},
    props: Props = .{},
    offset_x: f64 = 0,
    offset_y: f64 = 0,

    /// `_getZIndex` — parseInt(props.zIndex) || 0.
    pub fn zIndex(self: TiledLayer) i32 {
        return self.props.int("zIndex", 0);
    }

    /// `_getPriority` — parseInt(props.priority) || 0.
    pub fn priority(self: TiledLayer) i32 {
        return self.props.int("priority", 0);
    }

    /// `_isPriorityTile` — priority > 0 && zIndex == Z-Player param.
    pub fn isPriority(self: TiledLayer) bool {
        return self.priority() > 0 and self.zIndex() == Z_PLAYER;
    }

    /// `_createLayers` paint gate: tilelayer with none of the consumed
    /// property kinds (collision/toLevel/regionId/reflect).
    pub fn isPaintable(self: TiledLayer) bool {
        return self.kind == .tilelayer and
            !self.props.has("collision") and
            !self.props.has("toLevel") and
            !self.props.has("regionId") and
            !self.props.has("reflectionSurface") and
            !self.props.has("reflectionCast");
    }

    /// `_updateHideOnLevel` — the layer hides while the current level
    /// equals this value; null when the prop is absent.
    pub fn hideOnLevel(self: TiledLayer) ?i32 {
        if (!self.props.has("hideOnLevel")) return null;
        return self.props.int("hideOnLevel", 0);
    }
};

pub const AnimFrame = struct { tileid: i32, duration_ms: i32 };

pub const AnimTile = struct {
    local: i32,
    frames: []AnimFrame = &.{},
};

pub const TileProp = struct {
    local: i32,
    collision: []const u8 = "",
    arrow_impassable: []const u8 = "",
    region_id: []const u8 = "",
};

pub const TiledTileset = struct {
    firstgid: i32 = 0,
    /// map-side reference (`"source": "DW_WHITESPACE.json"`); cleared
    /// after the external file is merged.
    source: []const u8 = "",
    name: []const u8 = "",
    columns: i32 = 0,
    tilecount: i32 = 0,
    tilewidth: i32 = 32,
    tileheight: i32 = 32,
    /// `image` basename (e.g. "whitespace.png") — the renderer builds
    /// `img/tilesets/<basename>` from it.
    image: []const u8 = "",
    tiles: []AnimTile = &.{},
    tileprops: []TileProp = &.{},

    pub fn animOf(self: *const TiledTileset, local: i32) ?*const AnimTile {
        for (self.tiles) |*t| {
            if (t.local == local) return t;
        }
        return null;
    }

    pub fn propOf(self: *const TiledTileset, local: i32) ?*const TileProp {
        for (self.tileprops) |*p| {
            if (p.local == local) return p;
        }
        return null;
    }
};

/// One map level (`_initializeMapLevel`): collision 0, arrows all-pass
/// (15), regions 0, level_change −1, each width*height long.
pub const Level = struct {
    collision: []u8 = &.{},
    arrows: []u8 = &.{},
    regions: []i32 = &.{},
    level_change: []i32 = &.{},
};

/// Merged animation state: one slot per animated LOCAL id (last tileset
/// in file order wins a shared id), with the winning tileset's frames.
pub const AnimSlot = struct {
    local: i32,
    ts_index: usize,
    tile_index: usize,
};

pub const AnimState = struct {
    slots: []AnimSlot = &.{},
    frame: []i32 = &.{},
    duration: []f64 = &.{},

    pub fn slotOf(self: *const AnimState, local: i32) ?usize {
        for (self.slots, 0..) |s, i| {
            if (s.local == local) return i;
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// TiledMap
// ---------------------------------------------------------------------------

pub const TiledMap = struct {
    arena: std.mem.Allocator,
    width: i32 = 0,
    height: i32 = 0,
    tile_w: i32 = 32,
    tile_h: i32 = 32,
    layers: []TiledLayer = &.{},
    tilesets: []TiledTileset = &.{},
    levels: []Level = &.{},
    anim: AnimState = .{},
    props: Props = .{},
    map_id: u32 = 0,

    /// `isTiledMap` guard for callers — always true on a successful load.
    pub fn isTiled(self: *const TiledMap) bool {
        return self.width > 0 and self.height > 0;
    }

    fn ensureLevel(self: *TiledMap, lv: i32) void {
        const want: usize = @intCast(lv + 1);
        if (self.levels.len >= want) return;
        const size: usize = @intCast(self.width * self.height);
        const old = self.levels;
        const out = self.arena.alloc(Level, want) catch return;
        @memcpy(out[0..old.len], old);
        for (out[old.len..]) |*lvl| {
            lvl.collision = self.arena.alloc(u8, size) catch return;
            @memset(lvl.collision, 0);
            lvl.arrows = self.arena.alloc(u8, size) catch return;
            @memset(lvl.arrows, 1 | 2 | 4 | 8);
            lvl.regions = self.arena.alloc(i32, size) catch return;
            @memset(lvl.regions, 0);
            lvl.level_change = self.arena.alloc(i32, size) catch return;
            @memset(lvl.level_change, -1);
        }
        self.levels = out;
    }

    fn levelAt(self: *TiledMap, lv: i32) ?*Level {
        if (lv < 0 or lv >= @as(i32, @intCast(self.levels.len))) return null;
        return &self.levels[@intCast(lv)];
    }

    // -- the four setup passes (file order over layers) --------------------

    fn setupCollisionFull(self: *TiledMap) void {
        const size: usize = @intCast(self.width * self.height);
        const w: usize = @intCast(self.width);
        for (self.layers) |layer| {
            const mode = layer.props.str("collision");
            if (!std.mem.eql(u8, mode, "full") and
                !std.mem.eql(u8, mode, "up-left") and
                !std.mem.eql(u8, mode, "up-right") and
                !std.mem.eql(u8, mode, "down-left") and
                !std.mem.eql(u8, mode, "down-right") and
                !std.mem.eql(u8, mode, "tile-base")) continue;
            const lv = layer.props.int("level", 0);
            self.ensureLevel(lv);
            const lvl = self.levelAt(lv) orelse continue;
            var x: usize = 0;
            while (x < size) : (x += 1) {
                if (x >= layer.data.len or layer.data[x] == 0) continue;
                var id: usize = x; // half-tile OFF → realX == x
                if (std.mem.eql(u8, mode, "up-right")) {
                    id = x + 1;
                } else if (std.mem.eql(u8, mode, "down-left")) {
                    id = x + w;
                } else if (std.mem.eql(u8, mode, "down-right")) {
                    id = x + w + 1;
                } else if (std.mem.eql(u8, mode, "tile-base")) {
                    if (x >= layer.data.len) continue;
                    const props = self.tilePropsOf(layer.data[x]) orelse continue;
                    if (!std.mem.eql(u8, props.collision, "full")) continue;
                }
                if (id < size) lvl.collision[id] = 1;
            }
        }
    }

    fn setupCollisionArrow(self: *TiledMap) void {
        const size: usize = @intCast(self.width * self.height);
        for (self.layers) |layer| {
            const mode = layer.props.str("collision");
            const tile_base = std.mem.eql(u8, mode, "tile-base");
            const arrow_mode = std.mem.eql(u8, mode, "arrow");
            if (!tile_base and !arrow_mode) continue;
            const lv = layer.props.int("level", 0);
            self.ensureLevel(lv);
            const lvl = self.levelAt(lv) orelse continue;
            var x: usize = 0;
            while (x < size) : (x += 1) {
                if (tile_base) {
                    if (x >= layer.data.len) continue;
                    const props = self.tilePropsOf(layer.data[x]) orelse continue;
                    if (props.arrow_impassable.len == 0) continue;
                    const bit = arrowBit(props.arrow_impassable);
                    lvl.arrows[x] ^= bit;
                } else {
                    if (x >= layer.data.len or layer.data[x] == 0) continue;
                    const imp = layer.props.str("arrowImpassable");
                    if (imp.len == 0) continue;
                    const bit = arrowBit(imp);
                    lvl.arrows[x] ^= bit;
                }
            }
        }
    }

    fn setupRegion(self: *TiledMap) void {
        const size: usize = @intCast(self.width * self.height);
        for (self.layers) |layer| {
            const rid = layer.props.str("regionId");
            if (rid.len == 0) continue;
            const lv = layer.props.int("level", 0);
            self.ensureLevel(lv);
            const lvl = self.levelAt(lv) orelse continue;
            const tile_base = std.mem.eql(u8, rid, "tile-base");
            var x: usize = 0;
            while (x < size) : (x += 1) {
                if (tile_base) {
                    if (x >= layer.data.len) continue;
                    const props = self.tilePropsOf(layer.data[x]) orelse continue;
                    if (props.region_id.len == 0) continue;
                    lvl.regions[x] = parseIntJs(props.region_id) orelse 0;
                } else {
                    if (x >= layer.data.len or layer.data[x] == 0) continue;
                    lvl.regions[x] = parseIntJs(rid) orelse 0;
                }
            }
        }
    }

    fn setupMapLevelChange(self: *TiledMap) void {
        const size: usize = @intCast(self.width * self.height);
        for (self.layers) |layer| {
            const tl = layer.props.str("toLevel");
            if (tl.len == 0) continue;
            const lv = layer.props.int("level", 0);
            self.ensureLevel(lv);
            const lvl = self.levelAt(lv) orelse continue;
            const to_level = parseIntJs(tl) orelse continue; // NaN → skip (see notes)
            var x: usize = 0;
            while (x < size) : (x += 1) {
                if (x >= layer.data.len or layer.data[x] == 0) continue;
                lvl.level_change[x] = to_level;
            }
        }
    }

    /// `_getArrowBit` — split on '&', trim+lowercase each term, XOR
    /// accumulate (a repeated term cancels itself).
    pub fn arrowBit(impassable: []const u8) u8 {
        var bit: u8 = 0;
        var it = std.mem.splitScalar(u8, impassable, '&');
        while (it.next()) |raw| {
            const term = std.mem.trim(u8, raw, " \t\r\n");
            if (std.ascii.eqlIgnoreCase(term, "left")) bit ^= 1;
            if (std.ascii.eqlIgnoreCase(term, "up")) bit ^= 2;
            if (std.ascii.eqlIgnoreCase(term, "right")) bit ^= 4;
            if (std.ascii.eqlIgnoreCase(term, "down")) bit ^= 8;
        }
        return bit;
    }

    // -- tileset lookups ----------------------------------------------------

    /// `_getTextureId` — the tileset whose [firstgid, firstgid+tilecount)
    /// covers the gid; null when none does (JS would crash downstream —
    /// callers skip and log).
    pub fn textureIndexOf(self: *const TiledMap, gid: i32) ?usize {
        for (self.tilesets, 0..) |ts, i| {
            if (gid >= ts.firstgid and gid < ts.firstgid + ts.tilecount) return i;
        }
        return null;
    }

    /// `_getTileProperties` — the tileset entry for the gid's LOCAL id.
    pub fn tilePropsOf(self: *const TiledMap, gid: i32) ?*const TileProp {
        if (gid == 0) return null;
        const ti = self.textureIndexOf(gid) orelse return null;
        return self.tilesets[ti].propOf(gid - self.tilesets[ti].firstgid);
    }

    /// Identify visible decoration by its tileset-local ID. Global IDs can
    /// differ when the map author reorders its external tilesets.
    pub fn hasVisibleTile(self: *const TiledMap, x: i32, y: i32, level: i32, name: []const u8, local_id: i32) bool {
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return false;
        const index = @as(usize, @intCast(y)) * @as(usize, @intCast(self.width)) + @as(usize, @intCast(x));
        for (self.layers) |layer| {
            if (!layer.visible or !layer.isPaintable() or index >= layer.data.len or layer.hideOnLevel() == level) continue;
            const gid = layer.data[index];
            const tileset = self.tilesets[self.textureIndexOf(gid) orelse continue];
            if (gid - tileset.firstgid == local_id and std.ascii.eqlIgnoreCase(tileset.name, name)) return true;
        }
        return false;
    }

    // -- queries (Game_Map Tiled overrides) ---------------------------------

    /// `Game_Map.isPassable(x, y, d)` on the given level: the source
    /// tile's arrow bit must allow `d`, then collision must be 0. OOB →
    /// false (the JS reads undefined and fails the bit test).
    pub fn isPassable(self: *const TiledMap, level: i32, x: i32, y: i32, d: i32) bool {
        if (level < 0 or level >= @as(i32, @intCast(self.levels.len))) return false;
        const lvl = &self.levels[@intCast(level)];
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return false;
        const idx: usize = @intCast(x + self.width * y);
        const bit = arrowBitForDirection(d);
        if (bit != 0 and (lvl.arrows[idx] & bit) == 0) return false;
        return lvl.collision[idx] == 0;
    }

    /// MV Game_CharacterBase.isMapPassable checks both sides of a move.
    /// Testing only the source lets a player enter a solid tile and then
    /// become trapped because every subsequent source check rejects it.
    pub fn canStep(self: *const TiledMap, level: i32, x: i32, y: i32, d: i32) bool {
        const dx: i32 = switch (d) {
            4 => -1,
            6 => 1,
            2, 8 => 0,
            else => return false,
        };
        const dy: i32 = switch (d) {
            8 => -1,
            2 => 1,
            else => 0,
        };
        return self.isPassable(level, x, y, d) and self.isPassable(level, x + dx, y + dy, 10 - d);
    }

    /// Distinguish an actual solid cell from arrow restrictions or invalid
    /// positions. Used only to recognize legacy source-only collision saves.
    pub fn isSolid(self: *const TiledMap, level: i32, x: i32, y: i32) bool {
        if (level < 0 or level >= @as(i32, @intCast(self.levels.len))) return false;
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return false;
        return self.levels[@intCast(level)].collision[@intCast(x + self.width * y)] != 0;
    }

    /// `Game_Map.regionId(x, y)` on the given level (OOB → 0).
    pub fn regionId(self: *const TiledMap, level: i32, x: i32, y: i32) i32 {
        if (level < 0 or level >= @as(i32, @intCast(self.levels.len))) return 0;
        const lvl = &self.levels[@intCast(level)];
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return 0;
        return lvl.regions[@intCast(x + self.width * y)];
    }

    /// `Game_Map.checkMapLevelChanging(x, y)` on the given level: the
    /// level the tile switches to, or null (−1 / OOB).
    pub fn levelChangeAt(self: *const TiledMap, level: i32, x: i32, y: i32) ?i32 {
        if (level < 0 or level >= @as(i32, @intCast(self.levels.len))) return null;
        const lvl = &self.levels[@intCast(level)];
        if (x < 0 or y < 0 or x >= self.width or y >= self.height) return null;
        const v = lvl.level_change[@intCast(y * self.width + x)];
        if (v < 0) return null;
        return v;
    }

    // -- animation ----------------------------------------------------------

    /// `_setupAnim` — frame 0 everywhere; duration =
    /// frames[0].duration / 1000 * 60 (f64, exactly as JS computes it).
    /// Local ids merge across tilesets with LAST-TILESET-WINS.
    fn setupAnim(self: *TiledMap) void {
        var list = std.ArrayList(AnimSlot).empty;
        for (self.tilesets, 0..) |ts, tsi| {
            for (ts.tiles, 0..) |t, ti| {
                if (t.frames.len == 0) continue;
                if (slotIndexOf(list.items, t.local)) |si| {
                    list.items[si] = .{ .local = t.local, .ts_index = tsi, .tile_index = ti };
                } else {
                    list.append(self.arena, .{ .local = t.local, .ts_index = tsi, .tile_index = ti }) catch continue;
                }
            }
        }
        const slots = list.items;
        const frames_state = self.arena.alloc(i32, slots.len) catch return;
        const durations = self.arena.alloc(f64, slots.len) catch return;
        self.anim = .{ .slots = slots, .frame = frames_state, .duration = durations };
        @memset(self.anim.frame, 0);
        for (self.anim.slots, 0..) |s, i| {
            const frames = self.tilesets[s.ts_index].tiles[s.tile_index].frames;
            self.anim.duration[i] = @as(f64, @floatFromInt(frames[0].duration_ms)) / 1000.0 * 60.0;
        }
    }

    /// `_updateAnim` + `_updateAnimFrames` — decrement every slot's
    /// duration; on ≤ 0 advance its frame, then wrap (out of range → 0)
    /// and re-arm with the wrapped frame's duration. Per frame, from
    /// TiledTilemap.update. (The JS wrap pass iterates per tileset and
    /// lets the last one win a shared key — identical here, since the
    /// merged slot already stores the last tileset's animation.)
    pub fn updateAnim(self: *TiledMap) void {
        if (self.anim.slots.len == 0) return;
        var need_refresh = false;
        for (self.anim.duration) |*d| {
            d.* -= 1;
            if (d.* <= 0) need_refresh = true;
        }
        if (!need_refresh) return;
        for (self.anim.slots, 0..) |s, i| {
            if (self.anim.duration[i] > 0) continue;
            self.anim.frame[i] += 1;
            const frames = self.tilesets[s.ts_index].tiles[s.tile_index].frames;
            var f = self.anim.frame[i];
            if (f < 0 or f >= @as(i32, @intCast(frames.len))) f = 0;
            self.anim.frame[i] = f;
            self.anim.duration[i] = @as(f64, @floatFromInt(frames[@intCast(f)].duration_ms)) / 1000.0 * 60.0;
        }
    }

    /// `_getAnimTileId(textureId, tileId - firstgid)` — per-tileset
    /// animation lookup with the GLOBAL frame state. No animation /
    /// frame 0 / out of range → the original local id (the JS throws on
    /// the out-of-range case; see module notes).
    pub fn animTileId(self: *const TiledMap, ts_index: usize, local: i32) i32 {
        const ts = &self.tilesets[ts_index];
        const t = ts.animOf(local) orelse return local;
        if (t.frames.len == 0) return local;
        const slot = self.anim.slotOf(local) orelse return local;
        const frame = self.anim.frame[slot];
        if (frame <= 0) return local;
        if (frame >= @as(i32, @intCast(t.frames.len))) return local;
        return t.frames[@intCast(frame)].tileid;
    }

    // -- loading ------------------------------------------------------------

    /// `DataManager.loadTiledMapData` — `maps/Map{mapId}.json` (capital
    /// M, the VFS case variants resolve the payload's lowercase names);
    /// external tilesets merge Object.assign-style. Returns null when
    /// the file is missing/unparsable (the MV fallback path).
    pub fn load(arena: std.mem.Allocator, vfs: *vfs_mod.Vfs, map_id: u32) ?TiledMap {
        var path_buf: [48]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "maps/Map{d}.json", .{map_id}) catch return null;

        const t0 = std.time.milliTimestamp();
        const text = vfs.readFileSync(path) catch |e| {
            log.event(.mv, .note, "tiled: '{s}' unreadable ({s}) — MV map path", .{ path, @errorName(e) });
            return null;
        };
        defer vfs.allocator.free(text);

        var map = parseText(arena, text, path) catch |e| {
            log.event(.mv, .warn, "tiled: '{s}' parse failed ({s}) — MV map path", .{ path, @errorName(e) });
            return null;
        };
        loadExternalTilesets(arena, vfs, &map);
        map.map_id = map_id;
        map.setup();

        log.event(.mv, .info, "tiled map loaded: {s} ({d} ms, {d}x{d} tiles {d}x{d}px, {d} layers, {d} tilesets, {d} levels)", .{
            path,           std.time.milliTimestamp() - t0,
            map.width,      map.height,
            map.tile_w,     map.tile_h,
            map.layers.len, map.tilesets.len,
            map.levels.len,
        });
        return map;
    }

    /// Parse one map JSON text into the arena (no tileset merge, no
    /// level setup — `load` does both; tests use this directly).
    pub fn parseText(arena: std.mem.Allocator, text: []const u8, name: []const u8) !TiledMap {
        var parser = json.Parser.init(arena, text) catch return error.OutOfMemory;
        const value = try parser.parse();
        return fromValue(arena, value, name);
    }

    fn fromValue(arena: std.mem.Allocator, v: json.Value, name: []const u8) !TiledMap {
        if (v != .object) return error.SyntaxError;
        var map = TiledMap{ .arena = arena };
        map.width = @intCast(v.getInt("width", 0));
        map.height = @intCast(v.getInt("height", 0));
        map.tile_w = @intCast(v.getInt("tilewidth", 32));
        map.tile_h = @intCast(v.getInt("tileheight", 32));
        map.props = Props.fromValue(arena, v.get("properties"));

        const layer_items = if (v.get("layers")) |l| l.arrayItems() else &.{};
        const layers = try arena.alloc(TiledLayer, layer_items.len);
        for (layer_items, 0..) |li, i| {
            layers[i] = try layerFromValue(arena, li);
        }
        map.layers = layers;

        const ts_items = if (v.get("tilesets")) |t| t.arrayItems() else &.{};
        const tilesets = try arena.alloc(TiledTileset, ts_items.len);
        for (ts_items, 0..) |ti, i| {
            tilesets[i] = try tilesetFromValue(arena, ti);
        }
        map.tilesets = tilesets;

        _ = name;
        return map;
    }

    fn layerFromValue(arena: std.mem.Allocator, lv: json.Value) !TiledLayer {
        var layer = TiledLayer{};
        layer.name = lv.getString("name") orelse "";
        const type_str = lv.getString("type") orelse "";
        layer.kind = if (std.mem.eql(u8, type_str, "tilelayer"))
            .tilelayer
        else if (std.mem.eql(u8, type_str, "objectgroup"))
            .objectgroup
        else
            .other;
        layer.visible = lv.getBool("visible", true);
        layer.offset_x = switch (lv.get("offsetx") orelse .null) {
            .number => |n| n,
            else => 0,
        };
        layer.offset_y = switch (lv.get("offsety") orelse .null) {
            .number => |n| n,
            else => 0,
        };
        layer.props = Props.fromValue(arena, lv.get("properties"));

        if (layer.kind == .tilelayer) {
            const data_items = if (lv.get("data")) |d| d.arrayItems() else &.{};
            const data = try arena.alloc(i32, data_items.len);
            for (data_items, 0..) |dv, i| {
                data[i] = switch (dv) {
                    .number => |n| @as(i32, @intFromFloat(@trunc(n))),
                    else => 0,
                };
            }
            layer.data = data;
        } else if (layer.kind == .objectgroup) {
            const obj_items = if (lv.get("objects")) |o| o.arrayItems() else &.{};
            const objects = try arena.alloc(TiledObject, obj_items.len);
            for (obj_items, 0..) |ov, i| {
                var obj = TiledObject{};
                obj.gid = @intCast(ov.getInt("gid", 0));
                obj.x = switch (ov.get("x") orelse .null) {
                    .number => |n| n,
                    else => 0,
                };
                obj.y = switch (ov.get("y") orelse .null) {
                    .number => |n| n,
                    else => 0,
                };
                obj.w = switch (ov.get("width") orelse .null) {
                    .number => |n| n,
                    else => 0,
                };
                obj.h = switch (ov.get("height") orelse .null) {
                    .number => |n| n,
                    else => 0,
                };
                obj.visible = ov.getBool("visible", true);
                const oprops = Props.fromValue(arena, ov.get("properties"));
                obj.event_id = oprops.int("eventId", 0);
                objects[i] = obj;
            }
            layer.objects = objects;
        }
        return layer;
    }

    fn tilesetFromValue(arena: std.mem.Allocator, tv: json.Value) !TiledTileset {
        var ts = TiledTileset{};
        if (tv != .object) return ts;
        ts.firstgid = @intCast(tv.getInt("firstgid", 0));
        ts.source = tv.getString("source") orelse "";
        ts.name = tv.getString("name") orelse "";
        ts.columns = @intCast(tv.getInt("columns", 0));
        ts.tilecount = @intCast(tv.getInt("tilecount", 0));
        ts.tilewidth = @intCast(tv.getInt("tilewidth", 32));
        ts.tileheight = @intCast(tv.getInt("tileheight", 32));
        if (tv.getString("image")) |img| {
            ts.image = basename(img);
        }
        ts.tiles = parseAnimTiles(arena, tv.get("tiles"));
        ts.tileprops = parseTileProps(arena, tv.get("tileproperties"));
        return ts;
    }

    fn parseAnimTiles(arena: std.mem.Allocator, tiles_v: ?json.Value) []AnimTile {
        const pv = tiles_v orelse return &.{};
        var list = std.ArrayList(AnimTile).empty;
        switch (pv) {
            .object => {
                for (pv.objectEntries()) |e| {
                    const local = parseIntJs(e.key) orelse continue;
                    const frames = animFrames(arena, e.value) catch continue;
                    list.append(arena, .{ .local = local, .frames = frames }) catch continue;
                }
            },
            .array => {
                for (pv.arrayItems()) |item| {
                    const local: i32 = @intCast(item.getInt("id", 0));
                    const frames = animFrames(arena, item) catch continue;
                    list.append(arena, .{ .local = local, .frames = frames }) catch continue;
                }
            },
            else => {},
        }
        return list.items;
    }

    fn parseTileProps(arena: std.mem.Allocator, tp_v: ?json.Value) []TileProp {
        const pv = tp_v orelse return &.{};
        var list = std.ArrayList(TileProp).empty;
        switch (pv) {
            .object => {
                for (pv.objectEntries()) |e| {
                    const local = parseIntJs(e.key) orelse continue;
                    list.append(arena, tilePropFrom(local, e.value, arena)) catch continue;
                }
            },
            .array => {
                for (pv.arrayItems(), 0..) |item, i| {
                    list.append(arena, tilePropFrom(@intCast(i), item, arena)) catch continue;
                }
            },
            else => {},
        }
        return list.items;
    }

    fn tilePropFrom(local: i32, v: json.Value, arena: std.mem.Allocator) TileProp {
        var p = TileProp{ .local = local };
        if (v == .object) {
            p.collision = valStr(arena, v.get("collision") orelse .null);
            p.arrow_impassable = valStr(arena, v.get("arrowImpassable") orelse .null);
            p.region_id = valStr(arena, v.get("regionId") orelse .null);
        }
        return p;
    }

    fn animFrames(arena: std.mem.Allocator, tile_v: json.Value) ![]AnimFrame {
        const anim_v = tile_v.get("animation") orelse return &.{};
        if (anim_v != .array) return &.{};
        const items = anim_v.arrayItems();
        const frames = try arena.alloc(AnimFrame, items.len);
        for (items, 0..) |fv, i| {
            frames[i] = .{
                .tileid = @intCast(fv.getInt("tileid", 0)),
                .duration_ms = @intCast(fv.getInt("duration", 0)),
            };
        }
        return frames;
    }

    /// `Object.assign(tileset, external)` — external fields win; the
    /// parent's `firstgid` survives because the external file has none.
    fn loadExternalTilesets(arena: std.mem.Allocator, vfs: *vfs_mod.Vfs, map: *TiledMap) void {
        for (map.tilesets) |*ts| {
            if (ts.source.len == 0) continue;
            const name = basename(ts.source);
            ts.source = ""; // merge at most once
            var buf: [64]u8 = undefined;
            const path = std.fmt.bufPrint(&buf, "maps/{s}", .{name}) catch continue;
            const text = vfs.readFileSync(path) catch |e| {
                log.event(.mv, .warn, "tiled: external tileset '{s}' unreadable ({s})", .{ path, @errorName(e) });
                continue;
            };
            defer vfs.allocator.free(text);
            var parser = json.Parser.init(arena, text) catch continue;
            const value = parser.parse() catch continue;
            if (value != .object) continue;
            mergeExternalTileset(arena, ts, value);
            log.event(.mv, .note, "tiled: merged external tileset '{s}' ({d} cols, {d} tiles, {d} props)", .{
                name, ts.columns, ts.tilecount, ts.tileprops.len,
            });
        }
    }

    /// Object.assign semantics for the fields YED actually consumes.
    fn mergeExternalTileset(arena: std.mem.Allocator, ts: *TiledTileset, ext: json.Value) void {
        if (ext.getString("name")) |n| ts.name = n;
        if (ext.get("columns")) |c| ts.columns = @intCast(c.asInt());
        if (ext.get("tilecount")) |c| ts.tilecount = @intCast(c.asInt());
        if (ext.get("tilewidth")) |c| ts.tilewidth = @intCast(c.asInt());
        if (ext.get("tileheight")) |c| ts.tileheight = @intCast(c.asInt());
        if (ext.getString("image")) |img| ts.image = basename(img);
        const tiles = parseAnimTiles(arena, ext.get("tiles"));
        if (tiles.len > 0) ts.tiles = tiles;
        const tprops = parseTileProps(arena, ext.get("tileproperties"));
        if (tprops.len > 0) ts.tileprops = tprops;
    }

    /// The full four-pass build (`_setupTiled`): level 0 first, then the
    /// collision/arrow/region/level-change passes in file order, then
    /// the animation table.
    pub fn setup(self: *TiledMap) void {
        if (self.width <= 0 or self.height <= 0) return;
        self.ensureLevel(0);
        self.setupCollisionFull();
        self.setupCollisionArrow();
        self.setupRegion();
        self.setupMapLevelChange();
        self.setupAnim();
    }
};

// ---------------------------------------------------------------------------
// small helpers
// ---------------------------------------------------------------------------

fn slotIndexOf(slots: []AnimSlot, local: i32) ?usize {
    for (slots, 0..) |s, i| {
        if (s.local == local) return i;
    }
    return null;
}

/// `source.replace(/^.*[\\\/]/, '')` — the basename after the last
/// path separator.
pub fn basename(path: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| return path[i + 1 ..];
    if (std.mem.lastIndexOfScalar(u8, path, '\\')) |i| return path[i + 1 ..];
    return path;
}

// ---------------------------------------------------------------------------
// Tests — embedded fixture mirroring the payload shapes
// ---------------------------------------------------------------------------

const testing = std.testing;

const FIXTURE_MAP =
    \\{ "height":3,
    \\ "layers":[
    \\  {
    \\   "data":[1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1],
    \\   "name":"GROUND",
    \\   "properties":{"zIndex":"1"},
    \\   "type":"tilelayer",
    \\   "visible":true,
    \\   "width":4,
    \\   "x":0,
    \\   "y":0
    \\  },
    \\  {
    \\   "data":[4, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0],
    \\   "name":"COLL",
    \\   "properties":{"collision":"tile-base","level":"0"},
    \\   "type":"tilelayer",
    \\   "visible":true,
    \\   "width":4,
    \\   "x":0,
    \\   "y":0
    \\  },
    \\  {
    \\   "data":[6, 0, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0],
    \\   "name":"ARROWS",
    \\   "properties":{"arrowImpassable":"left & down","collision":"arrow","level":"0"},
    \\   "type":"tilelayer",
    \\   "visible":true,
    \\   "width":4,
    \\   "x":0,
    \\   "y":0
    \\  },
    \\  {
    \\   "data":[8, 0, 0, 0, 0, 8, 0, 0, 0, 0, 0, 0],
    \\   "name":"REGION",
    \\   "properties":{"level":"0","regionId":"tile-base"},
    \\   "type":"tilelayer",
    \\   "visible":true,
    \\   "width":4,
    \\   "x":0,
    \\   "y":0
    \\  },
    \\  {
    \\   "data":[0, 0, 11, 11, 0, 0, 11, 11, 0, 0, 0, 0],
    \\   "name":"TOLEVEL",
    \\   "properties":{"level":"0","toLevel":"2"},
    \\   "type":"tilelayer",
    \\   "visible":true,
    \\   "width":4,
    \\   "x":0,
    \\   "y":0
    \\  },
    \\  {
    \\   "data":[13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13, 13],
    \\   "name":"HIDE",
    \\   "properties":{"hideOnLevel":"1","zIndex":"1"},
    \\   "type":"tilelayer",
    \\   "visible":true,
    \\   "width":4,
    \\   "x":0,
    \\   "y":0
    \\  },
    \\  {
    \\   "draworder":"topdown",
    \\   "name":"OBJECTS",
    \\   "objects":[
    \\    {
    \\     "gid":9,
    \\     "height":32,
    \\     "id":1,
    \\     "name":"",
    \\     "properties":{"eventId":"3"},
    \\     "rotation":0,
    \\     "type":"",
    \\     "visible":true,
    \\     "width":32,
    \\     "x":64,
    \\     "y":96
    \\    }
    \\   ],
    \\   "properties":{"priority":"1","zIndex":"3"},
    \\   "type":"objectgroup",
    \\   "visible":true,
    \\   "x":0,
    \\   "y":0
    \\  }
    \\ ],
    \\ "tileheight":32,
    \\ "tilesets":[
    \\  {
    \\   "firstgid":1,
    \\   "source":"FIX_WHITESPACE.json"
    \\  }
    \\ ],
    \\ "tilewidth":32,
    \\ "type":"map",
    \\ "version":1,
    \\ "width":4
    \\}
;

const FIXTURE_TILESET =
    \\{ "columns":8,
    \\ "image":"../img/tilesets/fixture_whitespace.png",
    \\ "imageheight":256,
    \\ "imagewidth":256,
    \\ "margin":0,
    \\ "name":"fixture_whitespace",
    \\ "spacing":0,
    \\ "tilecount":64,
    \\ "tileheight":32,
    \\ "tiles":
    \\    {
    \\     "15":
    \\        {
    \\         "animation":[
    \\                {
    \\                 "duration":500,
    \\                 "tileid":15
    \\                },
    \\                {
    \\                 "duration":500,
    \\                 "tileid":16
    \\                },
    \\                {
    \\                 "duration":500,
    \\                 "tileid":17
    \\                }]
    \\        }
    \\    },
    \\ "tileproperties":
    \\    {
    \\     "3":{"collision":"full"},
    \\     "5":{"arrowImpassable":"left & down"},
    \\     "7":{"regionId":"9"}
    \\    },
    \\ "tilewidth":32,
    \\ "type":"tileset"
    \\}
;

/// Parse the fixture map and merge the fixture external tileset the way
/// `load()` does (without the VFS).
fn fixtureMap(arena: std.mem.Allocator) !TiledMap {
    var map = try TiledMap.parseText(arena, FIXTURE_MAP, "fixture");
    try testing.expectEqualStrings("FIX_WHITESPACE.json", map.tilesets[0].source);
    var parser = try json.Parser.init(arena, FIXTURE_TILESET);
    const ext = try parser.parse();
    TiledMap.mergeExternalTileset(arena, &map.tilesets[0], ext);
    try testing.expectEqualStrings("fixture_whitespace.png", map.tilesets[0].image);
    try testing.expectEqual(@as(i32, 1), map.tilesets[0].firstgid); // parent survives
    map.setup();
    return map;
}

test "parseIntJs: JS parseInt semantics" {
    try testing.expectEqual(@as(?i32, 12), parseIntJs("12"));
    try testing.expectEqual(@as(?i32, 12), parseIntJs("  12abc"));
    try testing.expectEqual(@as(?i32, -5), parseIntJs(" -5px"));
    try testing.expectEqual(@as(?i32, 31), parseIntJs("0x1F"));
    try testing.expectEqual(@as(?i32, null), parseIntJs("abc"));
    try testing.expectEqual(@as(?i32, null), parseIntJs(""));
}

test "arrowBit: split/trim/lowercase, XOR accumulate" {
    try testing.expectEqual(@as(u8, 9), TiledMap.arrowBit("left & down"));
    try testing.expectEqual(@as(u8, 15), TiledMap.arrowBit("left & up & right & down"));
    try testing.expectEqual(@as(u8, 0), TiledMap.arrowBit("left & left")); // XOR cancels
    try testing.expectEqual(@as(u8, 2), TiledMap.arrowBit(" UP "));
    try testing.expectEqual(@as(u8, 0), TiledMap.arrowBit(""));
    try testing.expectEqual(@as(u8, 0), TiledMap.arrowBit("north"));
}

test "tiled fixture: levels built, queries exact" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var map = try fixtureMap(arena.allocator());

    try testing.expectEqual(@as(i32, 4), map.width);
    try testing.expectEqual(@as(i32, 3), map.height);
    try testing.expectEqual(@as(usize, 1), map.levels.len);

    // GROUND-only tile: no collision and no arrow gate → passable
    // ((0,0) itself carries BOTH a collision tile and an arrow tile)
    try testing.expect(map.isPassable(0, 1, 0, 2));
    // COLL at (0,0) and (2,0): gid 4 → tileprops[3].collision full → blocked
    try testing.expect(!map.isPassable(0, 0, 0, 2));
    try testing.expect(!map.isPassable(0, 2, 0, 2));
    try testing.expect(map.isPassable(0, 1, 0, 2));
    // arrow gate: ARROWS at (1,1) gid 6 → props[5].arrowImpassable
    // "left & down" → bit 9 → moving left(4) or down(2) blocked
    try testing.expect(!map.isPassable(0, 1, 1, 4));
    try testing.expect(!map.isPassable(0, 1, 1, 2));
    try testing.expect(map.isPassable(0, 1, 1, 6));
    try testing.expect(map.isPassable(0, 1, 1, 8));
    // OOB → false
    try testing.expect(!map.isPassable(0, -1, 0, 2));
    try testing.expect(!map.isPassable(0, 4, 0, 2));
    try testing.expect(!map.isPassable(0, 0, 3, 2));
    // bad level → false
    try testing.expect(!map.isPassable(5, 0, 0, 2));

    // region: REGION at (0,0) gid 8 → props[7].regionId = 9
    try testing.expectEqual(@as(i32, 9), map.regionId(0, 0, 0));
    try testing.expectEqual(@as(i32, 9), map.regionId(0, 1, 1));
    try testing.expectEqual(@as(i32, 0), map.regionId(0, 2, 2));

    // level change: TOLEVEL cells (2,0),(3,0),(2,1),(3,1) → 2
    try testing.expectEqual(@as(?i32, 2), map.levelChangeAt(0, 2, 0));
    try testing.expectEqual(@as(?i32, 2), map.levelChangeAt(0, 3, 1));
    try testing.expectEqual(@as(?i32, null), map.levelChangeAt(0, 0, 0));
    try testing.expectEqual(@as(?i32, null), map.levelChangeAt(0, 0, 2));

    // objectgroup relocation data
    const obj_layer = for (map.layers) |l| {
        if (l.kind == .objectgroup) break l;
    } else return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), obj_layer.objects.len);
    try testing.expectEqual(@as(i32, 9), obj_layer.objects[0].gid);
    try testing.expectEqual(@as(i32, 3), obj_layer.objects[0].event_id);
    // event relocation: floor(64/32)=2, floor(96/32)=3
    try testing.expectEqual(@as(i32, 2), @as(i32, @intFromFloat(@floor(obj_layer.objects[0].x / 32))));
    try testing.expectEqual(@as(i32, 3), @as(i32, @intFromFloat(@floor(obj_layer.objects[0].y / 32))));
}

test "tiled fixture: layer classification" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var map = try fixtureMap(arena.allocator());

    // file order: GROUND(z1 paintable), COLL, ARROWS, REGION, TOLEVEL,
    // HIDE(z1 paintable, hideOnLevel 1), OBJECTS(objectgroup priority1 z3)
    try testing.expect(map.layers[0].isPaintable());
    try testing.expectEqual(@as(i32, 1), map.layers[0].zIndex());
    try testing.expect(!map.layers[1].isPaintable());
    try testing.expect(!map.layers[2].isPaintable());
    try testing.expect(!map.layers[3].isPaintable());
    try testing.expect(!map.layers[4].isPaintable());
    try testing.expect(map.layers[5].isPaintable());
    try testing.expectEqual(@as(?i32, 1), map.layers[5].hideOnLevel());
    try testing.expectEqual(LayerKind.objectgroup, map.layers[6].kind);
    try testing.expect(map.layers[6].isPriority());
    try testing.expectEqual(@as(i32, 1), map.layers[6].priority());
    try testing.expectEqual(@as(i32, 3), map.layers[6].zIndex());
    try testing.expect(!map.layers[1].isPriority());
}

test "tiled animation: frame state + animTileId resolution" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var map = try fixtureMap(arena.allocator());

    // one animated local id (15), 3 frames, 500 ms = 30.0 frames/slot
    try testing.expectEqual(@as(usize, 1), map.anim.slots.len);
    try testing.expectEqual(@as(i32, 15), map.anim.slots[0].local);

    // frame 0 → original local id
    try testing.expectEqual(@as(i32, 15), map.animTileId(0, 15));
    // non-animated local → itself
    try testing.expectEqual(@as(i32, 12), map.animTileId(0, 12));

    // 500ms @60fps = 30 frames; tick 29 → still frame 0 (duration 1)
    var i: usize = 0;
    while (i < 29) : (i += 1) map.updateAnim();
    try testing.expectEqual(@as(i32, 15), map.animTileId(0, 15));
    // tick 30 → duration hits 0 → frame 1
    map.updateAnim();
    try testing.expectEqual(@as(i32, 1), map.anim.frame[0]);
    try testing.expectEqual(@as(i32, 16), map.animTileId(0, 15));
    // 30 more → frame 2 → tileid 17
    i = 0;
    while (i < 30) : (i += 1) map.updateAnim();
    try testing.expectEqual(@as(i32, 17), map.animTileId(0, 15));
    // 30 more → wraps to 0 → original local id
    i = 0;
    while (i < 30) : (i += 1) map.updateAnim();
    try testing.expectEqual(@as(i32, 0), map.anim.frame[0]);
    try testing.expectEqual(@as(i32, 15), map.animTileId(0, 15));
}

test "tiled animation: duration math matches JS f64 (200ms → 12th tick)" {
    // 200/1000*60 rounds to EXACTLY 12.0 in f64 (the product 0.2*60 is
    // closer to 12 than to the next representable) — fires on the 12th
    // decrement, exactly like the JS.
    const dur: f64 = @as(f64, 200.0) / 1000.0 * 60.0;
    try testing.expectEqual(@as(f64, 12.0), dur);
    var d = dur;
    var ticks: usize = 0;
    while (d > 0) : (ticks += 1) d -= 1;
    try testing.expectEqual(@as(usize, 12), ticks);
}

test "tiled passage: solid destination and reverse arrow cannot trap a player" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var map = try TiledMap.parseText(arena.allocator(),
        \\{"width":4,"height":3,"tilewidth":32,"tileheight":32,"tilesets":[],"layers":[
        \\{"type":"tilelayer","properties":{"collision":"full"},"data":[0,0,0,0,0,1,0,0,0,0,0,0]},
        \\{"type":"tilelayer","properties":{"collision":"arrow","arrowImpassable":"left"},"data":[0,0,1,0,0,0,0,0,0,0,0,0]}]}
    , "passage-fixture");
    map.setup();
    // The previous source-only query allows the entry that trapped the
    // handheld player under the neighbors' table. A whole step rejects it.
    try testing.expect(map.isPassable(0, 0, 1, 6));
    try testing.expect(!map.canStep(0, 0, 1, 6));
    try testing.expect(!map.canStep(0, 1, 0, 2));
    // Reject an incoming blocked edge even if the source allows its exit.
    try testing.expect(map.isPassable(0, 1, 0, 6));
    try testing.expect(!map.canStep(0, 1, 0, 6));
    try testing.expect(!map.canStep(0, 2, 0, 4));
    // Walking beside the obstacle and along its unblocked edge still works.
    try testing.expect(map.canStep(0, 0, 1, 2));
    try testing.expect(map.canStep(0, 2, 0, 6));
    try testing.expect(!map.canStep(0, 0, 0, 4));
    try testing.expect(!map.canStep(1, 0, 0, 6));
    try testing.expect(!map.canStep(0, 0, 0, 0));
}

test "tiled passage: upper-right quarter collision uses the adjacent column" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var map = try TiledMap.parseText(arena.allocator(),
        \\{"width":3,"height":3,"tilewidth":32,"tileheight":32,"tilesets":[],"layers":[
        \\{"type":"tilelayer","properties":{"collision":"up-right"},"data":[1,0,0,0,0,0,0,0,0]}]}
    , "quarter-fixture");
    map.setup();
    try testing.expect(!map.isPassable(0, 1, 0, 2));
    try testing.expect(map.isPassable(0, 0, 1, 2));
    try testing.expect(!map.canStep(0, 0, 0, 6));
    try testing.expect(map.canStep(0, 0, 0, 2));
}
