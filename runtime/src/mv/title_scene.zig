//! Scene_OmoriTitleScreen — the native title presentation (M6).
//!
//! **Behavioral oracle:** `js/plugins/Omori Title Screen.js` — the
//! create() sequence, the worldType-0 sprite layout (from the plugin's
//! exact coordinates), the command list from the language file
//! (`XX_BLUE.Omori_Title_Screen.commands`), the input handling
//! (up/down/ok), commandNewGame → DataManager.setupNewGame →
//! SceneManager.goto(Scene_Map), and the title BGM.
//!
//! Layout (worldType 0 = new game, verified from the plugin source):
//!   * background: full-canvas WHITE fill (640x480)
//!   * OMORI sprite: three 306x350 animation frames in the 918x351
//!     OMO_WS strip, bottom-centered at (320, 480)
//!   * title text container settles at (167, -30) after the intro:
//!       - lightbulb OMO_BULB_WS at (120, -2) [65x130 cut]
//!       - OMO_TITLE_WS (277x150) at the container origin
//!   * title commands: NEW GAME / CONTINUE / OPTIONS / PORTED BY
//!     (28px labels, start x=43, row y=428, 30px gaps; the selected
//!     command uses white text on a black box)
//!   * version text "V1.0.8" top-left
//!   * BGM: user_title (audio milestone M10 plays it for real in v30)
//!
//! The headless validation drives scripted input (select NEW GAME) and
//! proves the draw list + the transition; the windowed mode renders it.

const std = @import("std");
const log = @import("../core/log.zig");
const atlas_mod = @import("../assets/atlas.zig");
const manager_mod = @import("../assets/manager.zig");
const font_mod = @import("../text/font.zig");
const draw_mod = @import("../renderer/draw.zig");
const text_mod = @import("../omori/text.zig");
const image_codec = @import("../codec/image.zig");
const game_mod = @import("game.zig");
const audio_mixer = @import("../audio/mixer.zig");

pub const CommandKind = enum(u8) {
    new_game = 0,
    continue_ = 1,
    options = 2,
    ported_by = 3,

    fn fromIndex(i: usize) CommandKind {
        return switch (i) {
            0 => .new_game,
            1 => .continue_,
            2 => .options,
            else => .ported_by,
        };
    }
};

/// The four title commands from the language data (en: NEW GAME /
/// CONTINUE / OPTIONS / PORTED BY).
pub const COMMAND_COUNT = 4;
pub const COMMAND_HEIGHT: i32 = 30;
pub const COMMAND_Y: i32 = draw_mod.GAME_H - COMMAND_HEIGHT - 22;
pub const COMMAND_START_X: i32 = 43;
const command_white_px = [_]u8{ 255, 255, 255, 255 };

fn frameAnimation(frame: u64, delay: u64, frames: []const i32) i32 {
    // The plugin increments immediately, then counts delay down through
    // zero, so delay20 means21 updates and delay15 means16 updates.
    const index = (((@max(frame, 1) - 1) / (delay + 1)) + 1) % frames.len;
    return frames[@intCast(index)];
}

test "title animation: OMORI and bulb lines retain the authored delays and frame order" {
    for ([_]u64{ 1, 21, 22, 42, 43, 63, 64 }, [_]i32{ 1, 1, 2, 2, 0, 0, 1 }) |frame, expected|
        try std.testing.expectEqual(expected, frameAnimation(frame, 20, &.{ 0, 1, 2 }));
    for ([_]u64{ 1, 16, 17, 32, 33, 48, 49, 64, 65 }, [_]i32{ 1, 1, 2, 2, 1, 1, 0, 0, 1 }) |frame, expected|
        try std.testing.expectEqual(expected, frameAnimation(frame, 15, &.{ 0, 1, 2, 1 }));
}

pub const Input = struct {
    up: bool = false,
    down: bool = false,
    /// v31: MV key-repeat variants (held direction walks the list).
    up_rep: bool = false,
    down_rep: bool = false,
    ok: bool = false,
    cancel: bool = false,
};

pub const TitleScene = struct {
    alloc: std.mem.Allocator,
    atlas: *atlas_mod.AtlasData,
    assets: *manager_mod.Manager,
    font: *font_mod.Font,
    texts: *text_mod.TextStore,

    /// command index (0 = NEW GAME).
    command_index: usize = 0,
    /// Language text of the commands (owned copies).
    command_labels: [COMMAND_COUNT][]const u8 = .{ "", "", "", "" },
    labels_initialized: bool = false,
    labels_owned: bool = false,
    /// Version string bottom-left.
    version: []const u8 = "V1.0.8",
    /// Frames since start (the intro fade-in count).
    frame: u64 = 0,
    /// Set when a command was activated (scene change requested).
    activated: ?CommandKind = null,
    /// BGM name queued at start.
    bgm_name: []const u8 = "user_title",

    /// decoded surfaces for the title sprites (owned pixels).
    omori_pixels: ?[]u8 = null,
    title_pixels: ?[]u8 = null,
    bulb_pixels: ?[]u8 = null,
    sheet_pixels: ?[]u8 = null,
    /// The sheet's decoded size (for sub-rect blits we cut from the sheet
    /// directly — one surface, many src rects).
    sheet_surface: draw_mod.Surface = .{ .width = 0, .height = 0, .pixels = &.{} },
    /// v30: 1x1 solids for the selected-command box (black).
    solid_black: [4]u8 = .{ 20, 20, 20, 255 },
    solid_surface: draw_mod.Surface = .{ .width = 0, .height = 0, .pixels = &.{} },
    /// v33: OMORI_DEBUG_TEXT=1 diagnostics — 1x1 red/green solids so
    /// the debug rects render on any backend (fill ops are full-canvas
    /// only; the sprite path stretches these to arbitrary rects).
    debug_red: [4]u8 = .{ 255, 0, 0, 255 },
    debug_green: [4]u8 = .{ 0, 200, 0, 255 },
    debug_red_surface: draw_mod.Surface = .{ .width = 0, .height = 0, .pixels = &.{} },
    debug_green_surface: draw_mod.Surface = .{ .width = 0, .height = 0, .pixels = &.{} },
    /// v33: first N labels get a TEXT-DIAG log line (measured width,
    /// glyph count, non-empty coverage count, run dims) — the v32 run
    /// had ZERO visibility into the text pipeline while the user saw
    /// no title text.
    text_diag_logged: u32 = 0,

    pub fn init(
        alloc: std.mem.Allocator,
        atlas: *atlas_mod.AtlasData,
        assets: *manager_mod.Manager,
        font: *font_mod.Font,
        texts: *text_mod.TextStore,
    ) TitleScene {
        return .{
            .alloc = alloc,
            .atlas = atlas,
            .assets = assets,
            .font = font,
            .texts = texts,
        };
    }

    pub fn deinit(self: *TitleScene) void {
        if (self.omori_pixels) |p| self.alloc.free(p);
        if (self.title_pixels) |p| self.alloc.free(p);
        if (self.bulb_pixels) |p| self.alloc.free(p);
        if (self.sheet_pixels) |p| self.alloc.free(p);
        if (self.labels_owned) {
            for (self.command_labels) |label| self.alloc.free(label);
        }
    }

    /// Scene start: load command labels from the language file, decode
    /// the title sheet through the full asset/atlas/image pipeline.
    pub fn start(self: *TitleScene) !void {
        log.section("Scene_OmoriTitleScreen.start (native presentation)");

        // Language command list: XX_BLUE.Omori_Title_Screen.commands
        // (a YAML list under the message key `Omori_Title_Screen` in
        // XX_BLUE.yaml; extracted by the raw-file scan below).
        if (!self.labels_initialized) {
            if (self.loadCommandLabels()) {
                log.event(.mv, .info, "title commands loaded from XX_BLUE.yaml", .{});
            } else {
                self.command_labels = .{ "NEW GAME", "CONTINUE", "OPTIONS", "PORTED BY" };
            }
            self.labels_initialized = true;
        }
        log.event(.mv, .info, "title commands: {s} / {s} / {s} / {s}", .{ self.command_labels[0], self.command_labels[1], self.command_labels[2], self.command_labels[3] });

        // Decode the title sheet ONCE (img/atlases/Omori_TitleScreen.png
        // → image decoder → RGBA) — every sprite is a sub-rect of it.
        if (self.sheet_pixels == null) {
            const sheet_path = "img/atlases/Omori_TitleScreen.png";
            const snap = self.assets.load(sheet_path) catch |e| {
                log.err("FATAL_TITLE: atlas sheet '{s}' failed to load ({any})", .{ sheet_path, e });
                return e;
            };
            // re-decode to RGBA through the image codec (the manager caches
            // encoded bytes; pixels are the renderer's business)
            const img = image_codec.decode(self.alloc, snap.encoded) catch |e| {
                log.err("FATAL_TITLE: image decode of '{s}' failed ({any})", .{ sheet_path, e });
                return e;
            };
            self.sheet_pixels = img.pixels;
            self.sheet_surface = .{
                .width = img.width,
                .height = img.height,
                .pixels = img.pixels,
            };

            log.event(.res, .info, "title sheet decoded: {d}x{d} RGBA ({d} KiB)", .{
                self.sheet_surface.width, self.sheet_surface.height, img.pixels.len / 1024,
            });
        }

        // BGM (M10: actually mixed now — the v17 device HTTP log proved
        // the game serves audio/bgm/user_title.ogg for this scene).
        if (audio_mixer.instance != null) {
            audio_mixer.playBgmGlobal(self.bgm_name, 100, 100);
        } else {
            log.event(.audio, .note, "title BGM: '{s}' vol=100 (no audio device — silent)", .{self.bgm_name});
        }

        self.command_index = 0;
        self.frame = 0;
        self.activated = null;
    }

    /// Read `XX_BLUE.yaml`'s `Omori_Title_Screen: commands: [...]` list.
    fn loadCommandLabels(self: *TitleScene) bool {
        const text = self.assets.vfs.readFileSync("Languages/en/XX_BLUE.yaml") catch return false;
        defer self.assets.vfs.allocator.free(text);
        // find "Omori_Title_Screen:" then "commands:" then list items
        var in_block = false;
        var in_commands = false;
        var labels: [COMMAND_COUNT][]const u8 = undefined;
        var label_count: usize = 0;
        defer for (labels[0..label_count]) |label| self.alloc.free(label);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line_raw| {
            const line = std.mem.trim(u8, line_raw, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            if (!in_block) {
                if (std.mem.startsWith(u8, line, "Omori_Title_Screen:")) in_block = true;
                continue;
            }
            if (in_commands) {
                if (line[0] != '-') {
                    break; // list ended
                }
                const item = std.mem.trim(u8, line[1..], " \t-");
                if (label_count == COMMAND_COUNT) break;
                labels[label_count] = self.alloc.dupe(u8, item) catch return false;
                label_count += 1;
                continue;
            }
            if (std.mem.startsWith(u8, line, "commands:")) in_commands = true;
        }
        if (label_count != COMMAND_COUNT) return false;
        self.command_labels = labels;
        self.labels_owned = true;
        label_count = 0; // ownership transferred to the scene
        return true;
    }

    /// One frame: input → command selection; ok activates.
    pub fn update(self: *TitleScene, input: Input) void {
        self.frame += 1;
        // v31: MV key-repeat — held directions walk the commands after
        // the 24-frame delay (isRepeated is true on the press frame too,
        // so single taps behave exactly like v30).
        if (input.down_rep) {
            self.command_index = (self.command_index + 1) % COMMAND_COUNT;
            log.detail(.mv, "title command index → {d} ('{s}')", .{ self.command_index, self.command_labels[self.command_index] });
            audio_mixer.playSeGlobal("cursor", 100);
        }
        if (input.up_rep) {
            self.command_index = (self.command_index + COMMAND_COUNT - 1) % COMMAND_COUNT;
            log.detail(.mv, "title command index → {d} ('{s}')", .{ self.command_index, self.command_labels[self.command_index] });
            audio_mixer.playSeGlobal("cursor", 100);
        }
        if (input.ok) {
            const cmd = CommandKind.fromIndex(self.command_index);
            self.activated = cmd;
            audio_mixer.playSeGlobal("decision", 100);
            log.event(.mv, .note, "title command activated: {s} ('{s}')", .{ @tagName(cmd), self.command_labels[self.command_index] });
        }
        if (input.cancel) {
            audio_mixer.playSeGlobal("cancel", 100);
        }
    }

    /// Emit the draw list for the current frame.
    pub fn draw(self: *TitleScene, dl: *draw_mod.DrawList) !void {
        // Handles belong to one DrawList. Register again even when the
        // scene and its pixel stores are unchanged across frames.
        const sheet_handle = dl.addSurface(&self.sheet_surface);
        self.solid_surface = .{ .width = 1, .height = 1, .pixels = &self.solid_black };
        const solid_handle = dl.addSurface(&self.solid_surface);
        const white_surface = draw_mod.Surface{ .width = 1, .height = 1, .pixels = &command_white_px };
        const white_handle = dl.addSurface(&white_surface);
        var debug_handles: ?[2]u32 = null;
        if (debugTextEnabled()) {
            self.debug_red_surface = .{ .width = 1, .height = 1, .pixels = &self.debug_red };
            self.debug_green_surface = .{ .width = 1, .height = 1, .pixels = &self.debug_green };
            debug_handles = .{ dl.addSurface(&self.debug_red_surface), dl.addSurface(&self.debug_green_surface) };
        }

        // worldType 0 background: white fill.
        dl.pushClear(255, 255, 255);

        // Omori Title Screen.js setupFrameAnimations cuts one pose from
        // this strip. Rendering the full bitmap showed three heads.
        // delay=20 plus the boundary update gives 21 ticks per frame.
        const pose = frameAnimation(self.frame, 20, &.{ 0, 1, 2 });
        dl.pushSpriteStable(sheet_handle, .{ .x = pose * 306, .y = 0, .w = 306, .h = 350 }, .{
            .x = @divTrunc(draw_mod.GAME_W, 2) - 153,
            .y = draw_mod.GAME_H - 350,
            .w = 306,
            .h = 350,
        }, 255);

        // The plugin animates the direct scene child from y=130 to -30
        // before activating commands. Draw its settled coordinates.
        // Title container at (167, -30): lightbulb at (120,-2) [65x130
        // from sheet 1399,20], title text OMO_TITLE_WS (277x150 from
        // sheet 918,0).
        dl.pushSpriteStable(sheet_handle, .{ .x = 1399, .y = 20, .w = 65, .h = 130 }, .{
            .x = 167 + 120,
            .y = -30 - 2 + 20, // Atlas destination rect restores the trimmed20px
            .w = 65,
            .h = 130,
        }, 255);
        const lines_pose = frameAnimation(self.frame, 15, &.{ 0, 1, 2, 1 });
        dl.pushSpriteStable(sheet_handle, .{ .x = 1195 + lines_pose * 68, .y = 0, .w = 68, .h = 150 }, .{
            .x = 167 + 120,
            .y = -30,
            .w = 68,
            .h = 150,
        }, 255);
        dl.pushSpriteStable(sheet_handle, .{ .x = 918, .y = 0, .w = 277, .h = 150 }, .{
            .x = 167,
            .y = -30,
            .w = 277,
            .h = 150,
        }, 255);

        // Window_OmoTitleScreenBox: width = textWidth + padding(4)*6,
        // 30px gaps, x=43, final y=height-30-22. Keep the native high
        // contrast selected box while using the actual game's layout.
        const size = self.commandFontSize();
        var command_x: i32 = COMMAND_START_X;
        var slot: usize = 0;
        while (slot < COMMAND_COUNT) : (slot += 1) {
            const label = self.command_labels[slot];
            const selected = slot == self.command_index;
            const run = try self.rasterizeLabel(dl, label, size);
            const m = self.font.measureText(label, size);
            const text_w: i32 = @max(m.width, 0);
            const slot_x = command_x;
            const slot_w = text_w + 24;
            command_x += slot_w + 30;
            const text_h: i32 = @as(i32, @intCast(if (dl.runs.items.len > 0 and run < dl.runs.items.len) dl.runs.items[run].height else 28));
            const tx: i32 = slot_x + @divTrunc(slot_w - text_w, 2);
            const ty: i32 = COMMAND_Y + @divTrunc(COMMAND_HEIGHT - text_h, 2);
            // Keep the inactive labels readable over the dark shirt art.
            dl.pushSprite(white_handle, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .x = slot_x, .y = COMMAND_Y, .w = slot_w, .h = COMMAND_HEIGHT }, 232);
            // v33: OMORI_DEBUG_TEXT=1 — red box over the whole command
            // slot + green box where the text run should land. If the
            // boxes appear but the glyphs do not, the fault is in the
            // font/glyph/run pipeline; if nothing appears, the draw list
            // itself never reached the renderer.
            if (debug_handles) |handles| {
                dl.pushSprite(handles[0], .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .x = slot_x, .y = COMMAND_Y, .w = slot_w, .h = COMMAND_HEIGHT }, 255);
                dl.pushSprite(handles[1], .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .x = tx, .y = ty, .w = @max(text_w, 2), .h = @max(text_h, 2) }, 255);
            }
            if (selected) {
                dl.pushSprite(solid_handle, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{
                    .x = slot_x + 2,
                    .y = COMMAND_Y + 2,
                    .w = slot_w - 4,
                    .h = COMMAND_HEIGHT - 4,
                }, 255);
                dl.pushText(run, tx, ty, 255, 255, 255);
            } else {
                dl.pushText(run, tx, ty, 90, 90, 90);
            }
        }

        // Version text top-left (v30: moved off the command row).
        const vrun = try self.rasterizeLabel(dl, self.version, 24);
        dl.pushText(vrun, 4, 4, 150, 150, 150);
    }

    /// The actual GameFont fits at 28px. Allow wider replacement fonts
    /// in the standalone renderer check to keep every command on screen.
    pub fn commandFontSize(self: *const TitleScene) u32 {
        var size: u32 = 28;
        while (size > 12) : (size -= 1) {
            var width: i32 = 24 * COMMAND_COUNT + 30 * (COMMAND_COUNT - 1);
            for (self.command_labels) |label| width += self.font.measureText(label, size).width;
            if (width <= draw_mod.GAME_W - COMMAND_START_X * 2) break;
        }
        return size;
    }

    /// Rasterize a label; white glyphs (color applied at tint).
    fn rasterizeLabel(self: *TitleScene, dl: *draw_mod.DrawList, label: []const u8, size: u32) !u32 {
        const m = self.font.measureText(label, size);
        var glyphs: std.ArrayList(draw_mod.DrawList.LaidGlyph) = .empty;
        defer glyphs.deinit(self.alloc);
        var pen_x: i32 = 0;
        var iter = std.unicode.Utf8Iterator{ .bytes = label, .i = 0 };
        var prev_gid: u16 = 0;
        const sc = self.font.scale(size);
        // v33: diagnostics — missing glyph ids and empty coverage are the
        // two ways text silently disappears (invisible-but-counted).
        var missing_gid: u32 = 0;
        var empty_cov: u32 = 0;
        while (iter.nextCodepoint()) |cp| {
            const gid = self.font.glyphId(cp);
            if (gid == 0) missing_gid += 1;
            const kern: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(self.font.kernUnits(prev_gid, gid))) * sc));
            pen_x += kern;
            const g = try self.font.rasterize(gid, size);
            if (g.width == 0 or g.height == 0 or g.coverage.len == 0) empty_cov += 1;
            glyphs.append(self.alloc, .{ .glyph = g.*, .x = pen_x }) catch {};
            pen_x += g.advance;
            prev_gid = gid;
        }
        const height: u32 = @intCast(@max(@as(i32, @intCast(size)), 18));
        const run = dl.addTextRun(glyphs.items, @intCast(@max(m.width, 0)), height);
        if (self.text_diag_logged < 8) {
            self.text_diag_logged += 1;
            log.event(.res, .note, "TEXT-DIAG '{s}' size={d}: measured_w={d} glyphs={d} missing_gid={d} empty_cov={d} run={d}x{d}", .{ label, size, m.width, glyphs.items.len, missing_gid, empty_cov, @max(m.width, 0), height });
        }
        return run;
    }

    /// commandNewGame: DataManager.setupNewGame + goto Scene_Map
    /// (per the plugin: fadeOutAll then SceneManager.goto(Scene_Map)).
    pub fn commandNewGame(self: *TitleScene, game: *game_mod.GameObjects, dm: anytype) !void {
        log.event(.mv, .note, "title commandNewGame: DataManager.setupNewGame → Scene_Map", .{});
        try dm.setupNewGame(game);
        self.activated = .new_game;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// v33: OMORI_DEBUG_TEXT=1 gates the title debug rects (evaluated once).
var debug_text_cache: ?bool = null;
fn debugTextEnabled() bool {
    if (debug_text_cache) |v| return v;
    const v = std.posix.getenv("OMORI_DEBUG_TEXT") != null;
    debug_text_cache = v;
    return v;
}

test "title scene: command cycling and activation" {
    // Input handling needs no payload, font or asset manager.
    var scene = TitleScene.init(testing.allocator, undefined, undefined, undefined, undefined);
    scene.command_labels = .{ "NEW GAME", "CONTINUE", "OPTIONS", "PORTED BY" };

    // down cycling wraps
    scene.update(.{ .down_rep = true });
    try testing.expectEqual(@as(usize, 1), scene.command_index);
    scene.update(.{ .down_rep = true });
    scene.update(.{ .down_rep = true });
    scene.update(.{ .down_rep = true });
    try testing.expectEqual(@as(usize, 0), scene.command_index);
    // up from 0 wraps to last
    scene.update(.{ .up_rep = true });
    try testing.expectEqual(@as(usize, 3), scene.command_index);
    // ok activates
    scene.update(.{ .ok = true });
    try testing.expect(scene.activated != null);
    try testing.expectEqual(CommandKind.ported_by, scene.activated.?);
}

test "title scene: selection and debug surfaces survive fresh frame lists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A deterministic one-pixel glyph supplies visible coverage without
    // requiring a proprietary font or a machine-specific file path.
    const metrics = [_]u8{ 0, 100 };
    var font = font_mod.Font{
        .alloc = a,
        .data = &metrics,
        .upem = 100,
        .num_glyphs = 1,
        .index_to_loc_long = false,
        .num_hmetrics = 1,
        .cache = std.AutoHashMap(u64, font_mod.Glyph).init(a),
    };
    for ([_]u32{ 12, 24, 28 }) |size| {
        try font.cache.put(size, .{
            .width = 1,
            .height = 1,
            .bearing_x = 0,
            .top = 1,
            .advance = @intCast(size),
            .coverage = try a.dupe(u8, &.{255}),
        });
    }
    var scene = TitleScene.init(a, undefined, undefined, &font, undefined);
    scene.command_labels = .{ "NEW GAME", "CONTINUE", "OPTIONS", "PORTED BY" };
    scene.sheet_surface = .{ .width = 1464, .height = 1053, .pixels = &.{} };
    const old_debug = debug_text_cache;
    defer debug_text_cache = old_debug;
    for ([_]bool{ false, true }) |debug| {
        debug_text_cache = debug;
        for (0..3) |frame| {
            var dl = draw_mod.DrawList.init(a);
            defer dl.deinit();
            // A different registration order exposes stale nonzero
            // handles as well as the first-index-zero sentinel bug.
            var dummy_pixels: [3][4]u8 = @splat(.{ 0, 0, 0, 255 });
            for (0..frame) |i| {
                const dummy = draw_mod.Surface{ .width = 1, .height = 1, .pixels = &dummy_pixels[i] };
                _ = dl.addSurface(&dummy);
            }
            scene.command_index = frame;
            try scene.draw(&dl);
            try testing.expectEqual(@as(usize, 0), dl.validate().errors);
            var selections: usize = 0;
            for (dl.ops.items) |op| {
                if (op == .sprite and op.sprite.dst.y == COMMAND_Y + 2) {
                    const surf = dl.surfaces.items[op.sprite.surface];
                    try testing.expectEqual(@as(u32, 1), surf.width);
                    try testing.expectEqualSlices(u8, &scene.solid_black, surf.pixels);
                    var expected_x: i32 = COMMAND_START_X + 2;
                    for (scene.command_labels[0..frame]) |label| expected_x += font.measureText(label, scene.commandFontSize()).width + 24 + 30;
                    try testing.expectEqual(expected_x, op.sprite.dst.x);
                    selections += 1;
                }
            }
            try testing.expectEqual(@as(usize, 1), selections);
            try testing.expectEqual(@as(usize, 5), dl.runs.items.len);
            try testing.expect(std.mem.indexOfScalar(u8, dl.runs.items[0].pixels, 255) != null);
        }
    }
}

