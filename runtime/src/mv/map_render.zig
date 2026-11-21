//! v28 — the field renderer: MV tilemap + events + player/followers,
//! composed into the shared draw list each frame.
//!
//! MV rendering semantics implemented:
//!   * Tile grid 48x48, 6 map layers (0-2 lower, 3-5 upper) with a
//!     painter's-order draw (lower → upper) and events interleaved at
//!     "same as characters" priority between them (priorityType 1),
//!     above-characters events (priorityType 2) after, below (0) before.
//!   * Tile ID decode (rpg_core.js constants, best-effort — see notes):
//!       B=0, C=256, D=512, E=768, A5=1024, A1=1536, A2=2048, A3=2560,
//!       A4=3072 pages; sheet = tilesetNames[A1..E]; A1 first frame.
//!     Autotiles (A1/A2/A3/A4) draw the pattern block's first tile
//!     (v28 approximation, documented).
//!   * Event character sprites: MV sheet layout ($-sheets = 1 char
//!     3×4; plain sheets = 8 chars, 12 cols × 8 rows), pattern cycle
//!     {1,2,1,0} while walking, direction rows 2/4/6/8 → 0/1/2/3.
//!   * Camera: v36 — MV display pos (GameLoop's per-frame scroll
//!     accumulation), tilemap origin = floor(display * tile). Small
//!     maps center via setDisplayPos's endX/2 branch.
//!   * v36 Tiled path: YED TiledTilemap over ShaderTilemap — 32px
//!     grid, margin-20 paint window, layers as ONE sorted item list
//!     (YED _compareChildOrder: z, y, priority, spriteId), priority
//!     tiles + objectgroup objects through the 256-sprite pool, map
//!     level (hideOnLevel) gating. Characters join the same sort at
//!     screenZ = priority*2+1, y = screenY.
//!
//! Everything image-shaped flows through sprites.Loader (atlas-aware).

const std = @import("std");
const balloons = @import("balloons.zig");
const log = @import("../core/log.zig");
const draw_mod = @import("../renderer/draw.zig");
const json = @import("../data/json.zig");
const map_mod = @import("map.zig");
const game_mod = @import("game.zig");
const tiled_mod = @import("tiled.zig");
const sprites_mod = @import("sprites.zig");
const data_manager_mod = @import("data_manager.zig");
const database = @import("../data/database.zig");
const CharacterAnimation = @import("character_animation.zig").CharacterAnimation;

pub const TILE: i32 = 48;
pub const GAME_W: i32 = draw_mod.GAME_W;
pub const GAME_H: i32 = draw_mod.GAME_H;

/// MV tile page bases (rpg_core.js).
const PAGE_B: i32 = 0;
const PAGE_C: i32 = 256;
const PAGE_D: i32 = 512;
const PAGE_E: i32 = 768;
const PAGE_A5: i32 = 1024;
const PAGE_A1: i32 = 1536;
const PAGE_A2: i32 = 2048;
const PAGE_A3: i32 = 2560;
const PAGE_A4: i32 = 3072;

/// One unresolved tile id logged once (device feedback → v29 fixes).
var warned_unknown: ?i32 = null;

const SpriteOffset = struct { x: i32 = 0, y: i32 = 0 };

/// YEP_EventSpriteOffset: note tags establish the defaults, then page
/// comment tags (108/408) override them in command order. Offsets affect
/// the sprite's screen position/sort key, never its collision tile.
fn eventSpriteOffset(event: *const map_mod.RawEvent, page: *const map_mod.Page) SpriteOffset {
    var result: SpriteOffset = .{};
    applySpriteOffsetTags(&result, event.note);
    for (page.list) |command| {
        if ((command.code == 108 or command.code == 408) and command.parameters.len > 0) {
            applySpriteOffsetTags(&result, valStr(command.parameters[0]));
        }
    }
    return result;
}

fn signedSpriteOffset(text: []const u8) ?i32 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len < 2 or (trimmed[0] != '+' and trimmed[0] != '-')) return null;
    const value = std.fmt.parseInt(i32, trimmed, 10) catch return null;
    // A malformed authored tag must not overflow integer draw coordinates.
    if (value < -1_000_000 or value > 1_000_000) return null;
    return value;
}

fn applySpriteOffsetTags(result: *SpriteOffset, text: []const u8) void {
    var x: ?i32 = null;
    var y: ?i32 = null;
    var pair: ?SpriteOffset = null;
    var cursor: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, cursor, '<')) |start| {
        const end = std.mem.indexOfScalarPos(u8, text, start + 1, '>') orelse break;
        cursor = end + 1;
        const tag = text[start + 1 .. end];
        const colon = std.mem.indexOfScalar(u8, tag, ':') orelse continue;
        const label = std.mem.trim(u8, tag[0..colon], " \t");
        const value = tag[colon + 1 ..];
        if (x == null and std.ascii.eqlIgnoreCase(label, "sprite offset x")) {
            x = signedSpriteOffset(value);
        } else if (y == null and std.ascii.eqlIgnoreCase(label, "sprite offset y")) {
            y = signedSpriteOffset(value);
        } else if (pair == null and std.ascii.eqlIgnoreCase(label, "sprite offset")) {
            const comma = std.mem.indexOfScalar(u8, value, ',') orelse continue;
            const px = signedSpriteOffset(value[0..comma]) orelse continue;
            const py = signedSpriteOffset(value[comma + 1 ..]) orelse continue;
            pair = .{ .x = px, .y = py };
        }
    }
    // The plugin checks individual X, Y, then the combined tag per text.
    if (x) |value| result.x = value;
    if (y) |value| result.y = value;
    if (pair) |value| result.* = value;
}

fn characterSign(name: []const u8, sign: u8) bool {
    for (name) |character| {
        if (character != '!' and character != '$') break;
        if (character == sign) return true;
    }
    return false;
}

/// ImageManager.isObjectCharacter + Game_CharacterBase.shiftY.
fn characterShiftY(name: []const u8) i32 {
    return if (characterSign(name, '!')) 0 else 6;
}

const EventAnimation = struct {
    page: *const map_mod.Page,
    clock: CharacterAnimation,
    offset: SpriteOffset,
};

pub const MapRenderer = struct {
    alloc: std.mem.Allocator,
    loader: *sprites_mod.Loader,
    db: *database.Database,
    /// Current map's tileset sheet names (9, A1..E order; empty = none).
    sheet_names: [9][]const u8 = .{ "", "", "", "", "", "", "", "", "" },
    /// Pixel-per-frame camera (the tilemap origin, floor(display*tile)).
    cam_x: i32 = 0,
    cam_y: i32 = 0,
    player_animation: CharacterAnimation = .{},
    animation_map_id: u32 = 0,
    event_animations: std.AutoHashMap(i32, EventAnimation),
    /// v36: the Tiled path's per-frame sorted item scratch (reused).
    tiled_items: std.ArrayList(TiledItem) = .empty,

    pub fn init(alloc: std.mem.Allocator, loader: *sprites_mod.Loader, db: *database.Database) MapRenderer {
        return .{ .alloc = alloc, .loader = loader, .db = db, .event_animations = std.AutoHashMap(i32, EventAnimation).init(alloc) };
    }

    /// v36: release the Tiled item scratch.
    pub fn deinit(self: *MapRenderer) void {
        self.tiled_items.deinit(self.alloc);
        self.event_animations.deinit();
    }

    fn resetAnimations(self: *MapRenderer) void {
        self.player_animation = .{};
        self.animation_map_id = 0;
        self.event_animations.clearRetainingCapacity();
    }

    /// Character clocks advance once per field update, never per draw.
    /// MV events with stepAnime animate while standing; directionFix
    /// controls facing and does not turn an idle event into a walker.
    pub fn updateAnimations(self: *MapRenderer, raw: *const map_mod.RawMap, game: *game_mod.GameObjects, player_moving: bool, player_speed: i32) void {
        if (self.animation_map_id != game.map.map_id) {
            self.resetAnimations();
            self.animation_map_id = game.map.map_id;
        }
        self.player_animation.update(player_moving, false, player_speed);
        for (raw.events.items) |entry| {
            const event = entry orelse continue;
            const page = game.map.currentPage(raw, event.id, game) orelse {
                game.map.visual_routes.remove(game.map.alloc, event.id);
                continue;
            };
            game.map.visual_routes.tick(game.map.alloc, &event, page, .{
                .dx = @as(i64, game.player.x) - event.x,
                .dy = @as(i64, game.player.y) - event.y,
            });
            const pose = game.map.visual_routes.pose(&event, page);
            const original: i32 = if (page.image) |image| @intCast(image.getInt("pattern", 1)) else 1;
            const state = self.event_animations.getOrPut(event.id) catch continue;
            if (!state.found_existing or state.value_ptr.page != page) {
                state.value_ptr.* = .{ .page = page, .clock = CharacterAnimation.init(original), .offset = eventSpriteOffset(&event, page) };
            }
            state.value_ptr.clock.update(false, if (pose) |p| p.stepping else page.step_anime, if (pose) |p| p.speed else page.move_speed);
        }
    }

    fn eventPattern(self: *const MapRenderer, id: i32, page: *const map_mod.Page, fallback: i32) i32 {
        if (self.event_animations.get(id)) |state| {
            if (state.page == page) return state.clock.pattern();
        }
        return fallback;
    }

    fn eventOffset(self: *const MapRenderer, event: *const map_mod.RawEvent, page: *const map_mod.Page) SpriteOffset {
        if (self.event_animations.get(event.id)) |state| {
            if (state.page == page) return state.offset;
        }
        return eventSpriteOffset(event, page);
    }

    /// Load the tileset sheet names for the current map (Tilesets.json).
    pub fn setTileset(self: *MapRenderer, tileset_id: i32, dm: *data_manager_mod.DataManager) void {
        self.resetAnimations();
        var names: [9][]const u8 = .{ "", "", "", "", "", "", "", "", "" };
        if (db_tileset(self.db, tileset_id)) |ts| {
            if (ts.get("tilesetNames")) |tn| {
                const arr = tn.arrayItems();
                for (arr, 0..) |n, i| {
                    if (i < 9) names[i] = valStr(n);
                }
            }
        }
        self.sheet_names = names;
        log.event(.res, .info, "map renderer: tileset {d} sheets A1='{s}' A2='{s}' A5='{s}' B='{s}'", .{
            tileset_id, names[0], names[1], names[4], names[5],
        });
        _ = dm;
    }

    /// Draw the whole field frame. `raw` + `game` describe the map state;
    /// `player_real_x/y` is the player's glide position (MV _realX/_realY
    /// in tiles). Tiled maps branch to drawTiled (32px path).
    pub fn draw(
        self: *MapRenderer,
        dl: *draw_mod.DrawList,
        raw: *const map_mod.RawMap,
        game: *game_mod.GameObjects,
        player_dir: i32,
        player_moving: bool,
        player_real_x: f64,
        player_real_y: f64,
    ) void {
        // v36: YED — Tiled maps render through the Tiled path.
        if (game.map.isTiled()) {
            if (game.map.tiled) |t| {
                self.drawTiled(dl, raw, game, t, player_dir, player_moving, player_real_x, player_real_y);
                self.drawBalloons(dl, raw, game, player_real_x, player_real_y);
                return;
            }
        }

        // --- background (MV: black behind everything; parallax name if
        // present draws a picture instead — OMORI whitespace is black) ---
        dl.pushClear(0, 0, 0);
        if (raw.parallax_name.len > 0) {
            const key = std.fmt.allocPrint(self.alloc, "img/parallaxes/{s}.png", .{raw.parallax_name}) catch null;
            if (key) |k| {
                defer self.alloc.free(k);
                if (self.loader.get(dl, k)) |bg| {
                    dl.pushSpriteStable(bg.handle, bg.src, .{ .x = 0, .y = 0, .w = GAME_W, .h = GAME_H }, 255);
                }
            }
        }

        // --- camera (v36: MV display pos — GameLoop's scroll accumulation
        // keeps display_x/y; the tilemap origin is floor(display * 48)).
        // Small maps center via setDisplayPos's endX/2 branch (display
        // goes negative) — the old naive clamp + centering is replaced. ---
        self.cam_x = @intFromFloat(@floor(game.map.display_x * @as(f64, TILE)));
        self.cam_y = @intFromFloat(@floor(game.map.display_y * @as(f64, TILE)));

        // --- tiles: lower layers, then below-chars events, then same-level
        // events + player + followers, then upper layers, then above events ---
        const x0 = @max(@divTrunc(self.cam_x, TILE), 0);
        const y0 = @max(@divTrunc(self.cam_y, TILE), 0);
        const x1 = @min(x0 + @divTrunc(GAME_W, TILE) + 1, raw.width - 1);
        const y1 = @min(y0 + @divTrunc(GAME_H, TILE) + 1, raw.height - 1);

        // lower (z 0-2)
        var z: usize = 0;
        while (z < 3) : (z += 1) self.drawLayer(dl, raw, x0, y0, x1, y1, z);

        // below-characters events (priorityType 0)
        self.drawEvents(dl, raw, game, 0);

        // same-level (1): player + followers among them (sorted by y)
        self.drawEvents(dl, raw, game, 1);

        // player + followers
        self.drawPlayer(dl, game, player_dir, player_moving, player_real_x, player_real_y);

        // upper (z 3-5)
        z = 3;
        while (z < 6) : (z += 1) self.drawLayer(dl, raw, x0, y0, x1, y1, z);

        // above-characters events (priorityType 2)
        self.drawEvents(dl, raw, game, 2);
        self.drawBalloons(dl, raw, game, player_real_x, player_real_y);
    }

    fn drawBalloons(self: *MapRenderer, dl: *draw_mod.DrawList, raw: *const map_mod.RawMap, game: *game_mod.GameObjects, player_x: f64, player_y: f64) void {
        if (game.map.balloons.count() == 0) return;
        if (game.map.balloons.get(-1)) |cue| {
            const leader = game.party.leader();
            const name = if (leader) |actor| actor.character_name else "OMORI";
            const index = if (leader) |actor| actor.character_index else 0;
            const frame = self.charFrame(dl, name, index, game.player.direction, self.player_animation.pattern());
            self.drawBalloon(dl, &game.map, cue, player_x, player_y, .{}, name, if (frame) |sprite| sprite.fh else 0);
        }
        for (raw.events.items) |entry| {
            const event = entry orelse continue;
            const cue = game.map.balloons.get(event.id) orelse continue;
            var name: []const u8 = "";
            var height: i32 = 0;
            var offset: SpriteOffset = .{};
            if (game.map.currentPage(raw, event.id, game)) |page| {
                offset = self.eventOffset(&event, page);
                if (self.eventSprite(game, &event, page)) |sprite| {
                    name = sprite.name;
                    offset = sprite.offset;
                    if (self.charFrame(dl, name, sprite.index, sprite.dir, sprite.pattern)) |frame| height = frame.fh;
                }
            }
            self.drawBalloon(dl, &game.map, cue, @floatFromInt(event.x), @floatFromInt(event.y), offset, name, height);
        }
    }

    fn drawBalloon(self: *MapRenderer, dl: *draw_mod.DrawList, game_map: *const game_mod.GameMap, cue: balloons.Cue, x: f64, y: f64, offset: SpriteOffset, name: []const u8, target_height: i32) void {
        const key = switch (cue.sheet) {
            .standard => "img/system/Balloon.png",
            .do_re_mi => "img/system/BalloonDoReMi.png",
        };
        const sheet = self.loader.get(dl, key) orelse return;
        const w = balloons.cell_width;
        const h = balloons.cell_height;
        const col = cue.column() * w;
        const row = @as(i32, cue.row) * h;
        if (col + w > sheet.width or row + h > sheet.height) return;
        const tile_w: f64 = @floatFromInt(game_map.tileWidth());
        const tile_h: f64 = @floatFromInt(game_map.tileHeight());
        const cx: i32 = @intFromFloat(@round(game_map.scrolledX(x) * tile_w + tile_w / 2.0));
        const bottom: i32 = @intFromFloat(@round(game_map.scrolledY(y) * tile_h + tile_h));
        const src = draw_mod.Rect{ .x = sheet.src.x + col, .y = sheet.src.y + row, .w = w, .h = h };
        const dst = draw_mod.Rect{
            .x = cx + offset.x - w / 2,
            .y = bottom + offset.y - characterShiftY(name) - target_height - h,
            .w = w,
            .h = h,
        };
        dl.pushSpriteStable(sheet.handle, src, dst, 255);
    }

    fn drawLayer(self: *MapRenderer, dl: *draw_mod.DrawList, raw: *const map_mod.RawMap, x0: i32, y0: i32, x1: i32, y1: i32, z: usize) void {
        var ty = y0;
        while (ty <= y1) : (ty += 1) {
            var tx = x0;
            while (tx <= x1) : (tx += 1) {
                const idx = (z * @as(usize, @intCast(raw.height)) + @as(usize, @intCast(ty))) * @as(usize, @intCast(raw.width)) + @as(usize, @intCast(tx));
                if (idx >= raw.data.len) continue;
                const tile_id = raw.data[idx];
                if (tile_id <= 0) continue;
                self.drawTile(dl, tile_id, tx * TILE - self.cam_x, ty * TILE - self.cam_y);
            }
        }
    }

    /// One 48x48 tile. Best-effort mapping (see module doc).
    fn drawTile(self: *MapRenderer, dl: *draw_mod.DrawList, tile_id: i32, dx: i32, dy: i32) void {
        if (tile_id >= 61440) return; // shadow/region overlays: not drawn

        // page decode
        var sheet_idx: usize = 0; // index into tilesetNames[A1..E]
        var page_offset: i32 = 0;
        var grid_cols: i32 = 16; // B-E/A sheets: 16 cols
        if (tile_id < PAGE_C) {
            sheet_idx = 5;
            page_offset = PAGE_B; // B
            grid_cols = 16;
        } else if (tile_id < PAGE_D) {
            sheet_idx = 6;
            page_offset = PAGE_C;
        } else if (tile_id < PAGE_E) {
            sheet_idx = 7;
            page_offset = PAGE_D;
        } else if (tile_id < PAGE_A5) {
            sheet_idx = 8;
            page_offset = PAGE_E;
        } else if (tile_id < PAGE_A1) {
            sheet_idx = 4;
            page_offset = PAGE_A5;
            grid_cols = 8; // A5: 8 columns
        } else if (tile_id < PAGE_A2) {
            sheet_idx = 0;
            page_offset = PAGE_A1;
            grid_cols = 16;
        } else if (tile_id < PAGE_A3) {
            sheet_idx = 1;
            page_offset = PAGE_A2;
            grid_cols = 4; // A2: 2x3 autotile blocks → 4 block cols
        } else if (tile_id < PAGE_A4) {
            sheet_idx = 2;
            page_offset = PAGE_A3;
            grid_cols = 8;
        } else if (tile_id < 3584) {
            sheet_idx = 3;
            page_offset = PAGE_A4;
            grid_cols = 8;
        } else {
            if (warned_unknown == null or warned_unknown.? != tile_id) {
                warned_unknown = tile_id;
                log.event(.res, .warn, "map renderer: unmapped tile id {d} skipped (v28 best-effort decode)", .{tile_id});
            }
            return;
        }

        const name = self.sheet_names[sheet_idx];
        if (name.len == 0) return;
        const key = std.fmt.allocPrint(self.alloc, "img/tilesets/{s}.png", .{name}) catch return;
        defer self.alloc.free(key);
        const sheet = self.loader.get(dl, key) orelse return;

        // index inside the page
        const rel = tile_id - page_offset;
        // A1 animation: 512-range = 2 frames × 256; use frame 0
        const rel_eff: i32 = if (sheet_idx == 0) @mod(rel, 256) else rel;

        // Sheet-local tile index. Autotile pages (A2/A3/A4) carry 48
        // sub-variants per pattern block — v28 draws the block's origin
        // tile (approximation, documented in the module doc).
        const sheet_index_eff: i32 = if (sheet_idx >= 1 and sheet_idx <= 3)
            @divTrunc(rel_eff, 48) * 48 + 46
        else
            rel_eff;

        const sheet_cols: i32 = switch (sheet_idx) {
            1 => 4, // A2: autotile blocks 4 per row
            2, 3 => 8, // A3/A4 blocks
            4 => 8, // A5
            else => 16, // B..E, A1
        };
        const col = @mod(sheet_index_eff, sheet_cols);
        const row = @divTrunc(sheet_index_eff, sheet_cols);

        var src = sheet.src;
        src.x += col * TILE;
        src.y += row * TILE;
        src.w = TILE;
        src.h = TILE;
        if (src.x + TILE > sheet.src.x + sheet.src.w or src.y + TILE > sheet.src.y + sheet.src.h) {
            if (warned_unknown == null) {
                log.event(.res, .warn, "map renderer: tile {d} src rect outside sheet '{s}' — clipped", .{ tile_id, name });
            }
            return;
        }
        dl.pushSpriteStable(sheet.handle, src, .{ .x = dx, .y = dy, .w = TILE, .h = TILE }, 255);
    }

    /// Draw events with the given priority tier (0 below, 1 same, 2 above).
    fn drawEvents(self: *MapRenderer, dl: *draw_mod.DrawList, raw: *const map_mod.RawMap, game: *game_mod.GameObjects, tier: i32) void {
        for (raw.events.items) |ev_opt| {
            const ev = ev_opt orelse continue;
            if (game.map.isEventErased(ev.id)) continue;
            const page = game.map.currentPage(raw, ev.id, game) orelse continue;
            const pt = page.priority_type;
            if ((tier == 0 and pt != 0) or (tier == 1 and pt != 1) or (tier == 2 and pt != 2)) continue;

            const sprite = self.eventSprite(game, &ev, page) orelse continue;
            self.drawCharacterOffset(dl, sprite.name, sprite.index, ev.x, ev.y, sprite.dir, sprite.pattern, sprite.offset, sprite.alpha);
        }
    }

    const EventSprite = struct { name: []const u8, index: i32, dir: i32, pattern: i32, offset: SpriteOffset, alpha: u8 = 255 };
    fn eventSprite(self: *const MapRenderer, game: *const game_mod.GameObjects, ev: *const map_mod.RawEvent, page: *const map_mod.Page) ?EventSprite {
        const img = page.image orelse return null;
        var sprite = EventSprite{
            .name = img.getString("characterName") orelse "",
            .index = @intCast(img.getInt("characterIndex", 0)),
            .dir = @intCast(img.getInt("direction", 2)),
            .pattern = self.eventPattern(ev.id, page, @intCast(img.getInt("pattern", 1))),
            .offset = self.eventOffset(ev, page),
        };
        const pose = game.map.visual_routes.pose(ev, page);
        if (img.getInt("tileId", 0) > 0 and (pose == null or pose.?.graphic == null)) return null;
        if (pose) |state| {
            if (state.hidden or state.alpha == 0) return null;
            sprite.alpha = state.alpha;
            sprite.dir = state.dir;
            sprite.offset.y -= state.height();
            if (state.graphic) |*graphic| {
                sprite.name = graphic.name();
                sprite.index = graphic.index;
            }
            if (state.frame) |cell| {
                const single = characterSign(sprite.name, '$');
                if (cell.x >= @as(u8, if (single) 3 else 12) or cell.y >= @as(u8, if (single) 4 else 8)) return null;
                sprite.index = @as(i32, cell.y / 4) * 4 + cell.x / 3;
                sprite.dir = (cell.y % 4 + 1) * 2;
                sprite.pattern = cell.x % 3;
            }
        }
        if (sprite.name.len == 0) return null;
        return sprite;
    }

    /// The update clock owns the pattern. Extra draws must not speed it up.
    fn walkPattern(self: *const MapRenderer, moving: bool) i32 {
        _ = moving;
        return self.player_animation.pattern();
    }

    /// Player + followers (party trail). `real_x/y` is the glide
    /// position (v36) — MV draws the leader at screenX/screenY of
    /// _realX/_realY, not the destination tile.
    fn drawPlayer(self: *MapRenderer, dl: *draw_mod.DrawList, game: *game_mod.GameObjects, dir: i32, moving: bool, real_x: f64, real_y: f64) void {
        // pattern: standing = 1; walking cycle {1,2,1,0}
        const pattern = self.walkPattern(moving);

        const leader = game.party.leader();
        const char_name = if (leader) |actor| actor.character_name else "OMORI";
        const char_idx = if (leader) |actor| actor.character_index else 0;
        if (game.player.transparent) return;

        // followers first (drawn behind by order: trail reversed)
        var fi: usize = game.followers_trail.len;
        while (fi > 0) {
            fi -= 1;
            const t = game.followers_trail[fi];
            const actor = game.followerActor(fi) orelse continue;
            self.drawCharacterScreen(dl, actor.character_name, actor.character_index, t.direction, t.animation.pattern(), game.map.scrolledX(t.real_x), game.map.scrolledY(t.real_y), game.map.tileWidth(), game.map.tileHeight());
        }

        // v36: the leader glides — MV Game_CharacterBase.screenX/screenY
        // at the real position (48px grid on plain maps).
        self.drawCharacterScreen(dl, char_name, char_idx, dir, pattern, game.map.scrolledX(real_x), game.map.scrolledY(real_y), game.map.tileWidth(), game.map.tileHeight());
    }

    /// MV Game_CharacterBase.screenX/screenY — round(scrolled*tw + tw/2),
    /// round(scrolledY*th + th − shiftY − jumpHeight(0)); the sprite
    /// anchors bottom-center (Sprite_Character.updatePosition).
    pub fn drawCharacterScreen(self: *MapRenderer, dl: *draw_mod.DrawList, name: []const u8, char_idx: i32, dir: i32, pattern: i32, scrolled_x: f64, scrolled_y: f64, tw: i32, th: i32) void {
        const f = self.charFrame(dl, name, char_idx, dir, pattern) orelse return;
        const twf: f64 = @floatFromInt(tw);
        const thf: f64 = @floatFromInt(th);
        const sx_px: i32 = @intFromFloat(@round(scrolled_x * twf + twf / 2.0));
        const sy_px: i32 = @intFromFloat(@round(scrolled_y * thf + thf - @as(f64, @floatFromInt(characterShiftY(name)))));
        dl.pushSpriteStable(f.handle, f.src, .{
            .x = sx_px - @divTrunc(f.fw, 2),
            .y = sy_px - f.fh,
            .w = f.fw,
            .h = f.fh,
        }, 255);
    }

    /// One character's resolved sheet frame (texture + rect + frame size).
    const CharFrame = struct {
        handle: u32,
        src: draw_mod.Rect,
        fw: i32,
        fh: i32,
    };

    /// Resolve the character's sheet frame — $-sheets = 1 char 3×4,
    /// plain sheets = 8 chars (12 cols × 8 rows), direction rows
    /// 2/4/6/8 → 0..3, pattern columns 0/1/2. Shared by the MV tile
    /// path and the v36 screen paths.
    fn charFrame(self: *MapRenderer, dl: *draw_mod.DrawList, name: []const u8, char_idx: i32, dir: i32, pattern: i32) ?CharFrame {
        // SpaghettiCode.js overrides Game_CharacterBase.isTransparent:
        // DEV_TEST is an editor marker sheet, never visible game art.
        // Keep this shared by plain-map, Tiled, and screen-position paths.
        if (name.len == 0 or std.mem.eql(u8, name, "DEV_TEST")) return null;
        const key = std.fmt.allocPrint(self.alloc, "img/characters/{s}.png", .{name}) catch return null;
        defer self.alloc.free(key);
        const sheet = self.loader.get(dl, key) orelse return null;

        const frame = characterFrameRect(sheet.width, sheet.height, name, char_idx, dir, pattern) orelse return null;
        var src = sheet.src;
        src.x += frame.x;
        src.y += frame.y;
        src.w = frame.w;
        src.h = frame.h;
        return .{ .handle = sheet.handle, .src = src, .fw = frame.w, .fh = frame.h };
    }

    /// Sprite_Character.patternWidth/Height + characterBlockX/Y.
    /// Kept independent of textures so sheet geometry can be checked.
    pub fn characterFrameRect(width: i32, height: i32, name: []const u8, char_idx: i32, dir: i32, pattern: i32) ?draw_mod.Rect {
        const dollar = characterSign(name, '$');
        if (!dollar and (char_idx < 0 or char_idx > 7)) return null;
        const fw: i32 = @divTrunc(width, if (dollar) @as(i32, 3) else 12);
        const fh: i32 = @divTrunc(height, if (dollar) @as(i32, 4) else 8);
        if (fw <= 0 or fh <= 0) return null;

        const dir_row: i32 = switch (dir) {
            2 => 0,
            4 => 1,
            6 => 2,
            8 => 3,
            else => 0,
        };
        var frame_col: i32 = pattern;
        if (pattern < 0 or pattern > 2) frame_col = 1;

        var sx: i32 = 0;
        var sy: i32 = 0;
        if (dollar) {
            sx = frame_col * fw;
            sy = dir_row * fh;
        } else {
            const block_col = @mod(char_idx, 4);
            const block_row = @divTrunc(char_idx, 4);
            sx = (block_col * 3 + frame_col) * fw;
            sy = (block_row * 4 + dir_row) * fh;
        }

        if (sx + fw > width or sy + fh > height) return null;
        return .{ .x = sx, .y = sy, .w = fw, .h = fh };
    }

    /// Draw one MV character sprite at tile position (the 48px path).
    pub fn drawCharacter(self: *MapRenderer, dl: *draw_mod.DrawList, name: []const u8, char_idx: i32, tx: i32, ty: i32, dir: i32, pattern: i32, animate: bool, through: bool) void {
        _ = animate;
        _ = through;
        self.drawCharacterOffset(dl, name, char_idx, tx, ty, dir, pattern, .{}, 255);
    }

    fn drawCharacterOffset(self: *MapRenderer, dl: *draw_mod.DrawList, name: []const u8, char_idx: i32, tx: i32, ty: i32, dir: i32, pattern: i32, offset: SpriteOffset, alpha: u8) void {
        const f = self.charFrame(dl, name, char_idx, dir, pattern) orelse return;
        // MV: character anchored bottom-center of tile, sprite height may
        // exceed 48 → y offset = 48 - fh.
        const dx = tx * TILE + @divTrunc(TILE - f.fw, 2) - self.cam_x + offset.x;
        const dy = ty * TILE + (TILE - f.fh) - self.cam_y - characterShiftY(name) + offset.y;
        dl.pushSpriteStable(f.handle, f.src, .{ .x = dx, .y = dy, .w = f.fw, .h = f.fh }, alpha);
    }

    // ------------------------------------------------------------------
    // v36: the Tiled path — YED TiledTilemap (over ShaderTilemap)
    // ------------------------------------------------------------------

    /// One sorted draw item — the keys are YED `_compareChildOrder`
    /// (z, y, priority, spriteId), evaluated in screen space. `y` is
    /// the owning child's screen y (the whole layer's position for
    /// rect layers, the anchored sprite's y for priority tiles,
    /// objects and characters).
    const TiledItem = struct {
        handle: u32,
        src: draw_mod.Rect,
        dx: i32,
        dy: i32,
        w: i32,
        h: i32,
        z: i32,
        y: i32,
        priority: i32,
        alpha: u8 = 255,
        sprite_id: u32,
    };

    fn tiledItemLess(_: void, a: TiledItem, b: TiledItem) bool {
        if (a.z != b.z) return a.z < b.z;
        if (a.y != b.y) return a.y < b.y;
        if (a.priority != b.priority) return a.priority < b.priority;
        return a.sprite_id < b.sprite_id;
    }

    /// A rect tile layer's screen origin x — its position.x:
    /// startX*tw − ox + offsetX.
    fn layerBaseX(start_x: i32, tw: i32, ox: i32, off_x: i32) i32 {
        return start_x * tw - ox + off_x;
    }

    /// YED `_paintPriorityTile` — the 256-sprite pool caps priority
    /// tiles + objectgroup objects per repaint (overflows are dropped
    /// by the real game too).
    fn pushTiledItem(self: *MapRenderer, item: TiledItem, pool: *usize, sprite_id: *u32) void {
        if (pool.* >= tiled_mod.PRIORITY_TILES_LIMIT) return;
        pool.* += 1;
        self.tiled_items.append(self.alloc, item) catch return;
        sprite_id.* += 1;
    }

    /// One frame of the Tiled path. The MV renderer draws layer rects
    /// directly; here every drawable becomes a TiledItem sorted by
    /// (z, y, priority, spriteId) — characters included (they are
    /// tilemap children in MV, sorted with the layers).
    fn drawTiled(
        self: *MapRenderer,
        dl: *draw_mod.DrawList,
        raw: *const map_mod.RawMap,
        game: *game_mod.GameObjects,
        tiled: *const tiled_mod.TiledMap,
        player_dir: i32,
        player_moving: bool,
        player_real_x: f64,
        player_real_y: f64,
    ) void {
        // This is reused scratch, not a scene history. Retaining old
        // items redraws every prior frame and makes frame cost grow
        // quadratically over an otherwise idle map.
        self.tiled_items.clearRetainingCapacity();
        dl.pushClear(0, 0, 0);

        const tw: i32 = tiled.tile_w; // map grid (Game_Map.tileWidth)
        const th: i32 = tiled.tile_h;

        // Tilemap origin (ShaderTilemap roundPixels = true) —
        // Spriteset_Map.updateTilemap: origin = display * tileWidth.
        const ox: i32 = @intFromFloat(@floor(game.map.display_x * @as(f64, @floatFromInt(tw))));
        const oy: i32 = @intFromFloat(@floor(game.map.display_y * @as(f64, @floatFromInt(th))));

        // ShaderTilemap.updateTransform — paint window start (margin 20):
        // startX = floor((ox − margin) / tile).
        const start_x: i32 = @divFloor(ox - 20, tw);
        const start_y: i32 = @divFloor(oy - 20, th);
        // _paintAllTiles — the window spans _width/_height = screen +
        // margin*2, plus one extra column/row of tiles.
        const win_cols: i32 = @as(i32, @intFromFloat(@ceil(@as(f64, @floatFromInt(GAME_W + 40)) / @as(f64, @floatFromInt(tw))))) + 1;
        const win_rows: i32 = @as(i32, @intFromFloat(@ceil(@as(f64, @floatFromInt(GAME_H + 40)) / @as(f64, @floatFromInt(th))))) + 1;

        const level = game.map.currentMapLevel();
        var sprite_id: u32 = 0; // Sprite._counter — creation order
        var pool: usize = 0; // _priorityTilesCount

        // loadTileset — resolve every tileset's bitmap once per frame.
        var ts_sprites: [64]?sprites_mod.Sprite = @splat(null);
        const ts_count: usize = @min(tiled.tilesets.len, 64);
        for (0..ts_count) |ti| {
            const ts = &tiled.tilesets[ti];
            if (ts.image.len == 0) continue;
            // Tiled image basenames already include their extension.
            const key = std.fmt.allocPrint(self.alloc, "img/tilesets/{s}", .{ts.image}) catch continue;
            defer self.alloc.free(key);
            ts_sprites[ti] = self.loader.get(dl, key);
        }

        // --- tilelayers (file order = spriteId order; row-major scan) ---
        for (tiled.layers) |*layer| {
            if (!layer.isPaintable()) continue;
            // _paintTiles gates on layerData.visible
            if (!layer.visible) continue;
            // hideOnLevel: hidden while the current level equals the prop
            if (layer.hideOnLevel()) |hl| {
                if (hl == level) continue;
            }
            const z = layer.zIndex();
            const priority = layer.priority();
            const off_x: i32 = @intFromFloat(layer.offset_x);
            const off_y: i32 = @intFromFloat(layer.offset_y);
            // the CompositeRectTileLayer's screen position (its sort y)
            const layer_y: i32 = start_y * th - oy + off_y;
            const is_priority = layer.isPriority();

            var wy: i32 = 0;
            while (wy < win_rows) : (wy += 1) {
                var wx: i32 = 0;
                while (wx < win_cols) : (wx += 1) {
                    const mx = start_x + wx;
                    const my = start_y + wy;
                    // _paintTile: out-of-map cells drop (no wrap; the
                    // payload has no looping maps)
                    if (mx < 0 or my < 0 or mx >= tiled.width or my >= tiled.height) continue;
                    const pos: usize = @intCast(my * tiled.width + mx);
                    const gid = layer.data[pos];
                    if (gid == 0) continue;
                    const tex = tiled.textureIndexOf(gid) orelse continue;
                    if (tex >= 64 or ts_sprites[tex] == null) continue;
                    const ts = &tiled.tilesets[tex];
                    const sp = ts_sprites[tex].?;
                    const rid = tiled.animTileId(tex, gid - ts.firstgid);
                    if (ts.columns <= 0) continue;
                    const ux = @mod(rid, ts.columns) * ts.tilewidth;
                    const uy = @divFloor(rid, ts.columns) * ts.tileheight;
                    var src = sp.src;
                    src.x += ux;
                    src.y += uy;
                    src.w = ts.tilewidth;
                    src.h = ts.tileheight;
                    if (src.x + src.w > sp.src.x + sp.src.w or src.y + src.h > sp.src.y + sp.src.h) continue;

                    if (is_priority) {
                        // anchored sprite: drawn at the tile rect, sorted
                        // at its bottom edge (anchor y = 1.0)
                        const dy_p: i32 = my * th - oy + off_y;
                        self.pushTiledItem(.{
                            .handle = sp.handle,
                            .src = src,
                            .dx = mx * tw - ox + off_x,
                            .dy = dy_p,
                            .w = ts.tilewidth,
                            .h = ts.tileheight,
                            .z = z,
                            .y = dy_p + ts.tileheight,
                            .priority = priority,
                            .sprite_id = sprite_id,
                        }, &pool, &sprite_id);
                    } else {
                        self.tiled_items.append(self.alloc, .{
                            .handle = sp.handle,
                            .src = src,
                            .dx = wx * tw + layerBaseX(start_x, tw, ox, off_x),
                            .dy = wy * th + layer_y,
                            .w = ts.tilewidth,
                            .h = ts.tileheight,
                            .z = z,
                            .y = layer_y,
                            .priority = priority,
                            .sprite_id = sprite_id,
                        }) catch continue;
                        sprite_id += 1;
                    }
                }
            }
        }

        // --- objectgroups (file order; NO layer-visible gate — verified:
        // _paintObjectLayers only checks each object's own visible flag,
        // and objects consume the same 256-sprite pool) ---
        for (tiled.layers) |*layer| {
            if (layer.kind != .objectgroup) continue;
            const z = layer.zIndex();
            const priority = layer.priority();
            for (layer.objects) |obj| {
                if (obj.gid == 0) continue;
                if (!obj.visible) continue;
                const tex = tiled.textureIndexOf(obj.gid) orelse continue;
                if (tex >= 64 or ts_sprites[tex] == null) continue;
                const ts = &tiled.tilesets[tex];
                const sp = ts_sprites[tex].?;
                const rid = tiled.animTileId(tex, obj.gid - ts.firstgid);
                if (ts.columns <= 0) continue;
                const ux = @mod(rid, ts.columns) * ts.tilewidth;
                const uy = @divFloor(rid, ts.columns) * ts.tileheight;
                var src = sp.src;
                src.x += ux;
                src.y += uy;
                src.w = ts.tilewidth;
                src.h = ts.tileheight;
                if (src.x + src.w > sp.src.x + sp.src.w or src.y + src.h > sp.src.y + sp.src.h) continue;
                // anchored bottom-center: x = obj.x + offsetX − ox + w/2,
                // y = obj.y − obj.height + offsetY − oy + h
                const fx: i32 = @intFromFloat(obj.x + layer.offset_x - @as(f64, @floatFromInt(ox)) + @as(f64, @floatFromInt(ts.tilewidth)) / 2.0);
                const fy: i32 = @intFromFloat(obj.y - obj.h + layer.offset_y - @as(f64, @floatFromInt(oy)) + @as(f64, @floatFromInt(ts.tileheight)));
                const dx0 = fx - @divTrunc(ts.tilewidth, 2);
                const dy0 = fy - ts.tileheight;
                // off-screen cull (result-identical; frees pool slots for
                // on-screen objects the cap would otherwise eat)
                if (dx0 + ts.tilewidth <= 0 or dx0 >= GAME_W or dy0 + ts.tileheight <= 0 or dy0 >= GAME_H) continue;
                self.pushTiledItem(.{
                    .handle = sp.handle,
                    .src = src,
                    .dx = dx0,
                    .dy = dy0,
                    .w = ts.tilewidth,
                    .h = ts.tileheight,
                    .z = z,
                    .y = fy,
                    .priority = priority,
                    .sprite_id = sprite_id,
                }, &pool, &sprite_id);
            }
        }

        // --- characters (Sprite_Character: z = priority*2+1, y =
        // screenY; created after the layers — events file order,
        // followers, then the player) ---
        for (raw.events.items) |ev_opt| {
            const ev = ev_opt orelse continue;
            if (game.map.isEventErased(ev.id)) continue;
            const page = game.map.currentPage(raw, ev.id, game) orelse continue;
            const sprite = self.eventSprite(game, &ev, page) orelse continue;
            self.pushTiledCharacterItemOffset(dl, game, sprite.name, sprite.index, @floatFromInt(ev.x), @floatFromInt(ev.y), sprite.dir, sprite.pattern, page.priority_type, sprite.offset, sprite.alpha, &sprite_id);
        }

        // followers (MV reverseEach — trail reversed)
        var fi: usize = game.followers_trail.len;
        while (fi > 0) {
            fi -= 1;
            const t = game.followers_trail[fi];
            const actor = game.followerActor(fi) orelse continue;
            self.pushTiledCharacterItem(dl, game, actor.character_name, actor.character_index, t.real_x, t.real_y, t.direction, t.animation.pattern(), 1, &sprite_id);
        }

        // player (MV priority_type 1 → z 3; the glide position)
        if (!game.player.transparent) {
            const leader = game.party.leader();
            const char_name = if (leader) |actor| actor.character_name else "OMORI";
            const char_idx = if (leader) |actor| actor.character_index else 0;
            self.pushTiledCharacterItem(dl, game, char_name, char_idx, player_real_x, player_real_y, player_dir, self.walkPattern(player_moving), 1, &sprite_id);
        }

        // sort (YED _compareChildOrder) + push
        std.sort.pdq(TiledItem, self.tiled_items.items, {}, tiledItemLess);
        for (self.tiled_items.items) |it| {
            dl.pushSpriteStable(it.handle, it.src, .{ .x = it.dx, .y = it.dy, .w = it.w, .h = it.h }, it.alpha);
        }
    }

    /// One character as a sorted item — MV Sprite_Character:
    /// screenX = round(scrolled*tw + tw/2), screenY = round(scrolledY*th
    /// + th − shiftY), z = screenZ = priority*2+1, y = screenY.
    fn pushTiledCharacterItem(self: *MapRenderer, dl: *draw_mod.DrawList, game: *game_mod.GameObjects, name: []const u8, char_idx: i32, rtx: f64, rty: f64, dir: i32, pattern: i32, priority: i32, sprite_id: *u32) void {
        self.pushTiledCharacterItemOffset(dl, game, name, char_idx, rtx, rty, dir, pattern, priority, .{}, 255, sprite_id);
    }

    fn pushTiledCharacterItemOffset(self: *MapRenderer, dl: *draw_mod.DrawList, game: *game_mod.GameObjects, name: []const u8, char_idx: i32, rtx: f64, rty: f64, dir: i32, pattern: i32, priority: i32, offset: SpriteOffset, alpha: u8, sprite_id: *u32) void {
        const tw: f64 = @floatFromInt(game.map.tileWidth());
        const th: f64 = @floatFromInt(game.map.tileHeight());
        const f = self.charFrame(dl, name, char_idx, dir, pattern) orelse return;
        const scrolled_x = game.map.scrolledX(rtx);
        const scrolled_y = game.map.scrolledY(rty);
        const sx_px: i32 = @as(i32, @intFromFloat(@round(scrolled_x * tw + tw / 2.0))) + offset.x;
        const shift_y: f64 = @floatFromInt(characterShiftY(name));
        const sy_px: i32 = @as(i32, @intFromFloat(@round(scrolled_y * th + th - shift_y))) + offset.y;
        self.tiled_items.append(self.alloc, .{
            .handle = f.handle,
            .src = f.src,
            .dx = sx_px - @divTrunc(f.fw, 2),
            .dy = sy_px - f.fh,
            .w = f.fw,
            .h = f.fh,
            .z = priority * 2 + 1,
            .alpha = alpha,
            .y = sy_px,
            .priority = 0,
            .sprite_id = sprite_id.*,
        }) catch return;
        sprite_id.* += 1;
    }
};

test "tiled rendering: idle frames rebuild scratch instead of redrawing history" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var tiled = try tiled_mod.TiledMap.parseText(scratch,
        \\{"width":1,"height":1,"tilewidth":32,"tileheight":32,
        \\ "layers":[{"type":"tilelayer","width":1,"height":1,"visible":true,"data":[1]}],
        \\ "tilesets":[{"firstgid":1,"image":"tile.png","columns":1,"tilecount":1,"tilewidth":32,"tileheight":32}]}
    , "frame-regression");
    var parser = try json.Parser.init(scratch, "{\"width\":1,\"height\":1,\"events\":[null]}");
    var raw = try map_mod.RawMap.fromJson(scratch, try parser.parse());
    var atlas = @import("../assets/atlas.zig").AtlasData{ .entries = &.{}, .index = std.StringHashMap(usize).init(a) };
    defer atlas.index.deinit();
    var loader = sprites_mod.Loader.init(a, undefined, &atlas);
    defer loader.deinit();
    const pixels = try a.alloc(u8, 32 * 32 * 4);
    @memset(pixels, 255);
    const key = try a.dupe(u8, "img/tilesets/tile.png");
    try loader.cache.put(key, .{
        .pixels = pixels,
        .width = 32,
        .height = 32,
        .surface = .{ .width = 32, .height = 32, .pixels = pixels },
        .last_use = 0,
        .bytes = pixels.len,
    });
    loader.used_bytes = pixels.len;
    var game: game_mod.GameObjects = undefined;
    game.map = game_mod.GameMap.init(a, undefined);
    defer game.map.deinit();
    try game.map.setup(&raw, 1);
    game.map.setupTiled(&raw, &tiled);
    game.player = .{ .transparent = true };
    game.followers_trail = .{ .{}, .{}, .{} };
    var painter = MapRenderer.init(a, &loader, undefined);
    defer painter.deinit();
    var list = draw_mod.DrawList.init(a);
    defer list.deinit();
    for (0..6) |_| {
        loader.beginFrame();
        painter.drawTiled(&list, &raw, &game, &tiled, 2, false, 0, 0);
        try std.testing.expectEqual(@as(usize, 1), painter.tiled_items.items.len);
        try std.testing.expectEqual(@as(usize, 2), list.ops.items.len); // clear + one tile
        try std.testing.expectEqual(@as(usize, 0), list.validate().errors);
        list.clear();
    }
}

test "character rendering: DEV_TEST markers stay transparent across map paths" {
    const a = std.testing.allocator;
    // An undefined loader is deliberate: transparent editor markers must
    // be rejected before resolving or decoding their image resource.
    var painter = MapRenderer.init(a, undefined, undefined);
    defer painter.deinit();
    var list = draw_mod.DrawList.init(a);
    defer list.deinit();
    painter.drawCharacter(&list, "DEV_TEST", 3, 15, 16, 2, 2, false, false);
    painter.drawCharacterScreen(&list, "DEV_TEST", 3, 2, 2, 15, 16, 32, 32);
    var game: game_mod.GameObjects = undefined;
    game.map = game_mod.GameMap.init(a, undefined);
    defer game.map.deinit();
    var sprite_id: u32 = 0;
    painter.pushTiledCharacterItem(&list, &game, "DEV_TEST", 3, 15, 16, 2, 2, 1, &sprite_id);
    try std.testing.expectEqual(@as(usize, 0), list.ops.items.len);
    try std.testing.expectEqual(@as(usize, 0), list.surfaces.items.len);
    try std.testing.expectEqual(@as(usize, 0), painter.tiled_items.items.len);
    try std.testing.expectEqual(@as(u32, 0), sprite_id);
}

test "character frames: standard eight-character sheets use 12 by 8 cells" {
    const testing = std.testing;
    // Actual DW_OMORI sheet dimensions. Every one of its eight blocks,
    // four directions, and three walk patterns must resolve a 32px cell.
    for (0..8) |index| {
        for ([_]i32{ 2, 4, 6, 8 }, 0..) |dir, row| {
            for (0..3) |pattern| {
                const r = MapRenderer.characterFrameRect(384, 256, "DW_OMORI", @intCast(index), dir, @intCast(pattern)).?;
                try testing.expectEqual(@as(i32, 32), r.w);
                try testing.expectEqual(@as(i32, 32), r.h);
                try testing.expectEqual(@as(i32, @intCast((index % 4 * 3 + pattern) * 32)), r.x);
                try testing.expectEqual(@as(i32, @intCast((index / 4 * 4 + row) * 32)), r.y);
            }
        }
    }
    const bottom_right = MapRenderer.characterFrameRect(384, 256, "DW_OMORI", 7, 8, 2).?;
    try testing.expectEqual(@as(i32, 352), bottom_right.x);
    try testing.expectEqual(@as(i32, 224), bottom_right.y);
}

test "character frames: dollar sheets retain their 3 by 4 layout" {
    for ([_][]const u8{ "$single", "!$object", "$!object", "!!$$object" }) |name| {
        const r = MapRenderer.characterFrameRect(96, 128, name, 0, 8, 2).?;
        try std.testing.expectEqualDeep(draw_mod.Rect{ .x = 64, .y = 96, .w = 32, .h = 32 }, r);
    }
}

test "character offsets: authored notes and page comments reset per page" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const scratch = arena.allocator();
    var parser = try json.Parser.init(scratch,
        \\{"width":20,"height":15,"events":[null,{"id":1,"name":"sparkle","x":8,"y":9,
        \\ "note":"<Sprite Offset X: +4><Sprite Offset Y: +5>",
        \\ "pages":[{"list":[{"code":108,"parameters":["<sprite offset: +0, -64>"]},
        \\                         {"code":408,"parameters":["<Sprite Offset X: -32>"]},
        \\                         {"code":355,"parameters":["<Sprite Offset: +99, +99>"]}]},
        \\          {"list":[]}]}]}
    );
    const raw = try map_mod.RawMap.fromJson(scratch, try parser.parse());
    const event = &raw.events.items[1].?;
    const page = &event.pages.items[0];
    try std.testing.expectEqualDeep(SpriteOffset{ .x = -32, .y = -64 }, eventSpriteOffset(event, page));
    // Entering a page without comments restores note defaults, rather
    // than keeping the previous page's -64px displacement.
    try std.testing.expectEqualDeep(SpriteOffset{ .x = 4, .y = 5 }, eventSpriteOffset(event, &event.pages.items[1]));
    var offset: SpriteOffset = .{ .x = 10, .y = 20 };
    applySpriteOffsetTags(&offset, "<Sprite Offset X: 5><Sprite Offset Y: +999999999999>");
    try std.testing.expectEqualDeep(SpriteOffset{ .x = 10, .y = 20 }, offset);
    // As in the plugin's three regex checks, a pair wins over individual
    // axis tags within a single comment line, regardless of text order.
    applySpriteOffsetTags(&offset, "<Sprite Offset: +1, -2><Sprite Offset X: +8>");
    try std.testing.expectEqualDeep(SpriteOffset{ .x = 1, .y = -2 }, offset);
}

test "character offsets: object anchors and page offsets affect draw and sort only" {
    const a = std.testing.allocator;
    var atlas = @import("../assets/atlas.zig").AtlasData{ .entries = &.{}, .index = std.StringHashMap(usize).init(a) };
    defer atlas.index.deinit();
    var loader = sprites_mod.Loader.init(a, undefined, &atlas);
    defer loader.deinit();
    for ([_][]const u8{ "actor", "!object" }) |name| {
        const pixels = try a.alloc(u8, 384 * 256 * 4);
        @memset(pixels, 255);
        const key = try std.fmt.allocPrint(a, "img/characters/{s}.png", .{name});
        try loader.cache.put(key, .{
            .pixels = pixels,
            .width = 384,
            .height = 256,
            .surface = .{ .width = 384, .height = 256, .pixels = pixels },
            .last_use = 0,
            .bytes = pixels.len,
        });
        loader.used_bytes += pixels.len;
    }
    var painter = MapRenderer.init(a, &loader, undefined);
    defer painter.deinit();
    var list = draw_mod.DrawList.init(a);
    defer list.deinit();
    painter.drawCharacterScreen(&list, "actor", 0, 2, 1, 2, 3, 32, 32);
    painter.drawCharacterScreen(&list, "!object", 0, 2, 1, 2, 3, 32, 32);
    try std.testing.expectEqual(@as(i32, 90), list.ops.items[0].sprite.dst.y);
    try std.testing.expectEqual(@as(i32, 96), list.ops.items[1].sprite.dst.y);
    painter.drawCharacterOffset(&list, "!object", 0, 2, 3, 2, 1, .{ .x = -32, .y = -64 }, 255);
    try std.testing.expectEqualDeep(draw_mod.Rect{ .x = 72, .y = 96, .w = 32, .h = 32 }, list.ops.items[2].sprite.dst);

    var game: game_mod.GameObjects = undefined;
    game.map = game_mod.GameMap.init(a, undefined);
    defer game.map.deinit();
    game.map.width = 20;
    game.map.height = 15;
    var sprite_id: u32 = 0;
    painter.pushTiledCharacterItemOffset(&list, &game, "!object", 0, 2, 3, 2, 1, 1, .{ .x = -32, .y = -64 }, 255, &sprite_id);
    painter.pushTiledCharacterItem(&list, &game, "!object", 0, 2, 3, 2, 1, 1, &sprite_id);
    painter.pushTiledCharacterItem(&list, &game, "actor", 0, 2, 3, 2, 1, 1, &sprite_id);
    // Default tile geometry is 48px here: anchor y = (3+1)*48.
    try std.testing.expectEqual(@as(i32, 128), painter.tiled_items.items[0].y);
    try std.testing.expectEqual(@as(i32, 192), painter.tiled_items.items[1].y);
    try std.testing.expectEqual(@as(i32, 186), painter.tiled_items.items[2].y);
    try std.testing.expectEqual(@as(i32, 72), painter.tiled_items.items[0].dx);
    try std.testing.expectEqual(@as(i32, 96), painter.tiled_items.items[0].dy);
    try std.testing.expect(MapRenderer.tiledItemLess({}, painter.tiled_items.items[0], painter.tiled_items.items[1]));
    // Rendering never writes back the sprite's shifted pixel coordinates.
    try std.testing.expectEqual(@as(i32, 20), game.map.width);
    try std.testing.expectEqual(@as(i32, 15), game.map.height);
    try std.testing.expectEqual(@as(usize, 0), list.validate().errors);
}

fn valStr(v: json.Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

fn db_tileset(db: *database.Database, tileset_id: i32) ?json.Value {
    const f = db.get("data/Tilesets.json") orelse return null;
    const arr = f.value.arrayItems();
    if (tileset_id <= 0 or tileset_id >= @as(i32, @intCast(arr.len))) return null;
    const ts = arr[@intCast(tileset_id)];
    if (ts == .null) return null;
    return ts;
}
