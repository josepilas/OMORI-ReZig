//! v28 — THE INTERACTIVE GAME SHELL. This is what was missing on the
//! device: v27's milestones ran as a scripted headless self-test and
//! exited after 2 seconds ("the title didn't appear. Nothing."). This
//! module turns the validated engine (interpreter, map, message, battle,
//! save/load) into a real, playable, 60 Hz state machine:
//!
//!   title → (NEW GAME / CONTINUE / OPTIONS / PORTED BY)
//!         → field (walk, events, dialogue, choices, transfers, encounters)
//!           → menu (ITEM / SKILL / SAVE / OPTIONS / QUIT)
//!           → battle (turn-based command window, HP, victory/defeat)
//!
//! Input = the logical Input model (dpad + A/B/X/Y/Start/Select from the
//! R36S pad). Presentation = the draw list (validated headless, rendered
//! windowed). The headless driver replays the SAME interactive path with
//! scripted input, so the real code is what gets tested.

const std = @import("std");
const sdl = @import("../platform/sdl2.zig");
const log = @import("../core/log.zig");
const draw_mod = @import("../renderer/draw.zig");
const renderer_mod = @import("../renderer/renderer.zig");
const input_mod = @import("../input/input.zig");
const font_mod = @import("../text/font.zig");
const text_mod = @import("../omori/text.zig");
const json = @import("../data/json.zig");
const database = @import("../data/database.zig");
const vfs_mod = @import("../filesystem/vfs.zig");
const atlas_mod = @import("../assets/atlas.zig");
const manager_mod = @import("../assets/manager.zig");
const scenes = @import("scenes.zig");
const title_scene_mod = @import("title_scene.zig");
const game_mod = @import("game.zig");
const map_mod = @import("map.zig");
const encounter_mod = @import("encounters.zig");
const interpreter_mod = @import("interpreter.zig");
const battle_mod = @import("battle.zig");
const save_mod = @import("save.zig");
const config_mod = @import("config.zig");
const audio_mixer = @import("../audio/mixer.zig");
const sprites_mod = @import("sprites.zig");
const window_mod = @import("window.zig");
const map_render_mod = @import("map_render.zig");

const GAME_W: i32 = draw_mod.GAME_W;
const GAME_H: i32 = draw_mod.GAME_H;
const TILE: i32 = map_render_mod.TILE;
const LINE_HEIGHT = window_mod.LINE_HEIGHT;

pub const State = enum {
    title,
    load,
    options,
    credits,
    field,
    menu,
    battle,
    battle_result,
    toast,
};

/// Toast message (save confirmation etc.).
const TOAST_FRAMES: u64 = 120;

const ParallelEvent = struct {
    // Positive keys identify map events; negative keys common events.
    key: i32,
    page: ?*const map_mod.Page,
    interpreter: *interpreter_mod.Interpreter,
};

test "movement timing: normal walk is default, dash inverts with always-run, and each tile latches speed" {
    var mgr: scenes.SceneManager = undefined;
    mgr.game.map.disable_dashing = false;
    var input = input_mod.Input{};
    var loop = GameLoop.init(std.testing.allocator, &mgr, undefined, undefined, undefined, undefined, undefined, undefined, &input);
    try std.testing.expect(!loop.always_dash);
    try std.testing.expectEqual(@as(i32, 4), loop.realMoveSpeed());
    input.current.dash = true;
    try std.testing.expectEqual(@as(i32, 5), loop.realMoveSpeed());
    loop.always_dash = true;
    try std.testing.expectEqual(@as(i32, 4), loop.realMoveSpeed());
    input.current.dash = false;
    try std.testing.expectEqual(@as(i32, 5), loop.realMoveSpeed());
    mgr.game.map.disable_dashing = true;
    try std.testing.expectEqual(@as(i32, 4), loop.realMoveSpeed());
    mgr.game.map.disable_dashing = false;
    loop.walk_remaining = 4;
    loop.walk_speed = 4;
    try std.testing.expectEqual(@as(i32, 4), loop.realMoveSpeed());
    loop.walk_speed = 5;
    input.current.dash = true;
    try std.testing.expectEqual(@as(i32, 5), loop.realMoveSpeed());
}

test "movement collision: d-pad cannot enter a solid Tiled cell and can walk around it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loop = try schedulerFixture(a, "{\"width\":3,\"height\":3,\"events\":[null]}", "[null]");
    const tiled_mod = @import("tiled.zig");
    const tiled = try a.create(tiled_mod.TiledMap);
    tiled.* = try tiled_mod.TiledMap.parseText(a,
        \\{"width":3,"height":3,"tilewidth":32,"tileheight":32,"tilesets":[],"layers":[
        \\{"type":"tilelayer","properties":{"collision":"full"},"data":[0,0,0,0,1,0,0,0,0]}]}
    , "player-collision-fixture");
    tiled.setup();
    loop.mgr.game.map.tiled = tiled;
    loop.mgr.game.player.x = 0;
    loop.mgr.game.player.y = 1;
    loop.input.current = .{ .right = true };
    loop.tryPlayerStep();
    try std.testing.expectEqual(@as(i32, 0), loop.mgr.game.player.x);
    try std.testing.expectEqual(@as(i32, 1), loop.mgr.game.player.y);
    try std.testing.expectEqual(@as(i32, 0), loop.walk_remaining);
    loop.input.current = .{ .down = true };
    loop.tryPlayerStep();
    try std.testing.expectEqual(@as(i32, 2), loop.mgr.game.player.y);
    try std.testing.expect(loop.walk_remaining > 0);
    loop.input.current = .{};
    for (0..12) |_| loop.updateFieldCore(false);
    loop.input.current = .{ .right = true };
    loop.tryPlayerStep();
    try std.testing.expectEqual(@as(i32, 1), loop.mgr.game.player.x);
    try std.testing.expectEqual(@as(i32, 2), loop.mgr.game.player.y);
}

test "followers: corners use each member's previous destination and gather waits for landing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try schedulerFixture(arena.allocator(), "{\"width\":10,\"height\":10,\"events\":[null]}", "[null]");
    const game = &loop.mgr.game;
    game.player.x = 2;
    game.player.y = 2;
    game.synchronizeFollowers();
    game.party.members.clearRetainingCapacity();
    try game.party.members.appendSlice(game.alloc, &.{ 1, 2, 3, 4 });
    for (0..4) |step| {
        loop.input.current = if (step == 3) .{ .down = true } else .{ .right = true };
        loop.tryPlayerStep();
        loop.input.current = .{};
        if (step == 3) {
            try std.testing.expectEqual(@as(i32, 5), game.followers_trail[0].x);
            try std.testing.expectEqual(@as(i32, 2), game.followers_trail[0].y);
            try std.testing.expectEqual(@as(i32, 6), game.followers_trail[0].direction);
            try std.testing.expectEqual(@as(i32, 3), game.followers_trail[2].x);
            loop.updateFieldCore(false);
            try std.testing.expect(game.followers_trail[0].real_x > 4 and game.followers_trail[0].real_x < 5);
        }
        while (loop.walk_remaining > 0) loop.updateFieldCore(false);
    }
    game.followers.gathering = true;
    loop.updateFieldCore(false);
    try std.testing.expect(game.followers.gathering and game.followers_trail[0].moving());
    for (0..60) |_| loop.updateFieldCore(false);
    try std.testing.expect(!game.followers.gathering);
    for (game.followers_trail) |slot| {
        try std.testing.expect(!slot.moving());
        try std.testing.expectEqual(game.player.x, slot.x);
        try std.testing.expectEqual(game.player.y, slot.y);
    }
}

test "options: menu returns to its live field session and title returns to title" {
    const a = std.testing.allocator;
    var mgr: scenes.SceneManager = undefined;
    mgr.game.player = .{ .map_id = 88, .x = 20, .y = 22 };
    var input = input_mod.Input{};
    var loop = GameLoop.init(a, &mgr, undefined, undefined, undefined, undefined, undefined, undefined, &input);
    loop.state = .menu;
    loop.menu_index = 3; // OPTIONS
    loop.walk_remaining = 7;
    input.current.confirm = true;
    loop.updateMenu();
    try std.testing.expectEqual(State.options, loop.state);
    input.endFrame();
    input.current = .{ .cancel = true };
    loop.updateOptions();
    try std.testing.expectEqual(State.menu, loop.state);
    try std.testing.expectEqual(@as(usize, 3), loop.menu_index);
    try std.testing.expectEqual(@as(u32, 88), mgr.game.player.map_id);
    try std.testing.expectEqual(@as(i32, 20), mgr.game.player.x);
    try std.testing.expectEqual(@as(i32, 22), mgr.game.player.y);
    try std.testing.expectEqual(@as(i32, 7), loop.walk_remaining);
    input.endFrame();
    input.current = .{};
    input.endFrame();
    input.current.cancel = true;
    loop.updateMenu();
    try std.testing.expectEqual(State.field, loop.state);

    // Use the actual title activation path too: a prior menu visit
    // must not make title OPTIONS return to that stale menu.
    loop.state = .title;
    loop.title = title_scene_mod.TitleScene.init(a, undefined, undefined, undefined, undefined);
    defer loop.title.deinit();
    loop.title.command_index = 2;
    input.current = .{};
    input.endFrame();
    input.current.confirm = true;
    loop.updateTitle();
    try std.testing.expectEqual(State.options, loop.state);
    input.endFrame();
    input.current = .{ .cancel = true };
    loop.updateOptions();
    try std.testing.expectEqual(State.title, loop.state);
    try std.testing.expect(loop.title.activated == null);
}

fn optionsPress(loop: *GameLoop, button: input_mod.LogicalButton) void {
    loop.input.clearAll();
    switch (button) {
        .confirm => loop.input.current.confirm = true,
        .cancel => loop.input.current.cancel = true,
        .left => loop.input.current.left = true,
        .right => loop.input.current.right = true,
        else => unreachable,
    }
    loop.updateOptions();
    loop.input.endFrame();
    loop.input.current = .{};
    loop.input.endFrame();
}

test "port options: controller edits persist without leaving the live menu session" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const loop = try saveUiFixture(a, root);
    loop.options_ready = true;
    loop.state = .menu;
    loop.mgr.game.player = .{ .map_id = 88, .x = 20, .y = 22 };
    loop.openOptions();
    loop.opt_index = @intFromEnum(config_mod.Row.bgm_volume);
    optionsPress(loop, .left);
    loop.opt_index = @intFromEnum(config_mod.Row.flashes);
    optionsPress(loop, .confirm);
    loop.opt_index = @intFromEnum(config_mod.Row.always_run);
    optionsPress(loop, .right);
    try std.testing.expect(loop.always_dash and loop.options_dirty);
    optionsPress(loop, .cancel);
    try std.testing.expectEqual(State.menu, loop.state);
    const fresh = config_mod.Settings.load(loop.vfs);
    try std.testing.expectEqual(@as(u8, 90), fresh.bgm_volume);
    try std.testing.expect(fresh.always_run and !fresh.flashes);
    try std.testing.expectEqual(@as(i32, 20), loop.mgr.game.player.x);
    try std.testing.expectEqual(@as(i32, 22), loop.mgr.game.player.y);
    loop.openOptions();
    loop.opt_index = @intFromEnum(config_mod.Row.reset);
    optionsPress(loop, .confirm);
    try std.testing.expect(!loop.always_dash);
    optionsPress(loop, .cancel);
    try std.testing.expectEqualDeep(config_mod.Settings{}, config_mod.Settings.load(loop.vfs));
}

test "port options: failed preference write reports error and permits leaving" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("saves/port-options.json"); // Rename cannot replace a directory.
    const root = try tmp.dir.realpathAlloc(a, ".");
    const loop = try saveUiFixture(a, root);
    loop.options_ready = true;
    loop.state = .menu;
    loop.openOptions();
    loop.opt_index = @intFromEnum(config_mod.Row.master_volume);
    optionsPress(loop, .left);
    optionsPress(loop, .cancel);
    try std.testing.expectEqual(State.options, loop.state);
    try std.testing.expect(loop.options_save_failed);
    try std.testing.expect(std.mem.indexOf(u8, loop.options_message, "SAVE FAILED") != null);
    optionsPress(loop, .cancel);
    try std.testing.expectEqual(State.menu, loop.state);
}

test "port options: flashes and shake affect world draws while fades and authored timers remain" {
    const a = std.testing.allocator;
    var mgr: scenes.SceneManager = undefined;
    mgr.game.screen = game_mod.GameScreen.init(a);
    defer mgr.game.screen.deinit();
    mgr.game.screen.shake = 4;
    mgr.game.screen.startFlash(.{ 100, 200, 50, 128 }, 10);
    mgr.game.screen.brightness = 0;
    var input: input_mod.Input = .{};
    var loop = GameLoop.init(a, &mgr, undefined, undefined, undefined, undefined, undefined, undefined, &input);
    var dl = draw_mod.DrawList.init(a);
    defer dl.deinit();
    const pixels = [_]u8{ 255, 255, 255, 255 };
    const surface = draw_mod.Surface{ .width = 1, .height = 1, .pixels = &pixels };
    const id = dl.addSurface(&surface);
    dl.pushSprite(id, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .x = 10, .y = 20, .w = 1, .h = 1 }, 255);
    loop.applyScreenOptions(&dl, 0);
    try std.testing.expectEqual(@as(i32, 14), dl.ops.items[0].sprite.dst.x);
    try std.testing.expectEqual(@as(usize, 2), dl.ops.items.len);
    try std.testing.expectEqual(@as(u8, 128), dl.ops.items[1].fill.a);
    loop.port_options.shake = false;
    loop.port_options.flashes = false;
    dl.ops.items[0].sprite.dst.x = 10;
    dl.ops.shrinkRetainingCapacity(1);
    loop.applyScreenOptions(&dl, 0);
    try std.testing.expectEqual(@as(i32, 10), dl.ops.items[0].sprite.dst.x);
    try std.testing.expectEqual(@as(usize, 1), dl.ops.items.len);
    try std.testing.expectEqual(@as(i32, 0), mgr.game.screen.brightness);
    try std.testing.expectEqual(@as(i32, 10), mgr.game.screen.flash_duration);
}

pub const GameLoop = struct {
    alloc: std.mem.Allocator,
    mgr: *scenes.SceneManager,
    vfs: *vfs_mod.Vfs,
    db: *database.Database,
    atlas: *atlas_mod.AtlasData,
    assets: *manager_mod.Manager,
    font: *font_mod.Font,
    renderer: *renderer_mod.Renderer,
    input: *input_mod.Input,

    loader: sprites_mod.Loader,
    win: window_mod.WindowRenderer,
    map_render: map_render_mod.MapRenderer,
    title: title_scene_mod.TitleScene,
    itp: interpreter_mod.Interpreter,
    parallel_events: std.ArrayList(ParallelEvent) = .empty,

    state: State = .title,
    /// v29: previous state — a transition flushes the renderer texture
    /// cache (scenes reallocate their pixel stores on state change).
    last_state: State = .title,
    /// v33: set at a state transition, cleared after the first frame
    /// drawn in the new state (the TRANSITION 99 checkpoint — the v32
    /// crash window was exactly between the flush and the next logged
    /// frame tick, so the first-frame proof now closes that gap).
    transition_first_frame: bool = false,
    frames: u64 = 0,
    /// Interactive frames budget (0 = unlimited; tests set a bound).
    max_frames: u64 = 0,
    quit: bool = false,
    /// Headless scripted-input driver (set only in validation runs).
    scripted: ?*const fn (loop: *GameLoop, frame: u64) void = null,
    /// Set once the CONTINUE path re-enters the field from a save.
    continued_once: bool = false,
    /// Set once a save succeeded through the menu (script observation).
    save_happened: bool = false,

    // field state
    walk_remaining: i32 = 0, // frames left in the current tile step
    walk_dir: i32 = 2,
    walk_speed: i32 = 4, // latched at tile entry, like MV updateDashing
    /// v36: MV _realX/_realY — the glide position between tiles
    /// (approaches the destination tile at distancePerFrame/frame).
    player_real_x: f64 = 0,
    player_real_y: f64 = 0,
    /// v36: MV Game_Player.update's lastScrolledX/Y — captured BEFORE
    /// the frame's movement; the delta drives updateScroll.
    last_scrolled_x: f64 = 0,
    last_scrolled_y: f64 = 0,
    encounter_rng: std.Random.DefaultPrng,
    /// v34 (M8): L1+R1 held-frame counter — the debug battle hotkey.
    debug_battle_frames: u32 = 0,
    tag_active: bool = false,
    tag_index: usize = 0,
    /// Toast text (owned; empty = none).
    toast_text: []const u8 = "",
    toast_frames_left: u64 = 0,

    // menu state
    menu_index: usize = 0,
    menu_calling: bool = false,
    menu_sub: enum { root, item, skill, save } = .root,
    menu_list_index: usize = 0,
    menu_ids: std.ArrayList(i32) = .empty,
    save_slots: [save_mod.max_savefiles]bool = @splat(false),
    slot_info: [save_mod.max_savefiles]save_mod.SavefileInfo = @splat(.{}),
    file_slot_count: usize = 6,
    load_index: usize = 0,
    load_message: []const u8 = "",

    // options state
    opt_index: usize = 0,
    options_return_state: State = .title,
    fast_text: bool = false,
    always_dash: bool = false,
    port_options: config_mod.Settings = .{},
    options_ready: bool = false,
    options_dirty: bool = false,
    options_save_failed: bool = false,
    options_message: []const u8 = "",

    // battle state
    battle: ?battle_mod.Manager = null,
    battle_troop: battle_mod.Troop = undefined,
    battle_troop_is_init: bool = false,
    battle_phase: enum { command, skill_list, item_list, target, resolving, result } = .command,
    battle_command_index: usize = 0,
    battle_target_index: usize = 0,
    battle_skills: std.ArrayList(i32) = .empty,
    battle_list_index: usize = 0,
    battle_action: battle_mod.Action = .{},
    battle_target_return: enum { command, skill_list, item_list } = .command,
    battle_result_text: []const u8 = "",
    battle_result: battle_mod.BattleResult = .win,
    battle_interpreter: ?*interpreter_mod.Interpreter = null,

    // v36: the map audio snapshot for the battle gap (borrows the
    // mixer's owned copies — valid until the next battle's save).
    battle_map_bgm: audio_mixer.SavedAudio = .{},
    battle_map_bgs: audio_mixer.SavedAudio = .{},

    // diagnostics
    frames_drawn: u64 = 0,
    draw_validation_errors: usize = 0,
    last_error: []const u8 = "",

    pub fn init(
        alloc: std.mem.Allocator,
        mgr: *scenes.SceneManager,
        vfs: *vfs_mod.Vfs,
        db: *database.Database,
        atlas: *atlas_mod.AtlasData,
        assets: *manager_mod.Manager,
        font: *font_mod.Font,
        renderer: *renderer_mod.Renderer,
        input: *input_mod.Input,
    ) GameLoop {
        return .{
            .alloc = alloc,
            .mgr = mgr,
            .vfs = vfs,
            .db = db,
            .atlas = atlas,
            .assets = assets,
            .font = font,
            .renderer = renderer,
            .input = input,
            .encounter_rng = std.Random.DefaultPrng.init(std.crypto.random.int(u64)),
            .loader = sprites_mod.Loader.init(alloc, assets, atlas),
            .win = undefined,
            .map_render = undefined,
            .title = undefined,
            .itp = undefined,
            .battle_troop = undefined,
        };
    }
    pub fn deinit(self: *GameLoop) void {
        self.clearParallelEvents();
        self.parallel_events.deinit(self.alloc);
        self.itp.deinit();
        if (self.toast_text.len > 0) self.alloc.free(self.toast_text);
        if (self.battle_result_text.len > 0) self.alloc.free(self.battle_result_text);
        self.title.deinit();
        self.map_render.deinit();
        if (self.battle) |*b| b.deinit();
        if (self.battle_troop_is_init) {
            self.battle_troop.deinit();
        }
        self.battle_skills.deinit(self.alloc);
        self.menu_ids.deinit(self.alloc);
        self.loader.deinit();
    }

    /// Wire the late-bound pointers (TextStore must outlive the loop; it
    /// is stored in a frame-stable place by the caller).
    pub fn bindTexts(self: *GameLoop, texts: *text_mod.TextStore) void {
        self.itp = interpreter_mod.Interpreter.init(self.alloc, &self.mgr.game, self.db, texts);
        self.itp.scene_battles = true;
        self.itp.field_routes = true;
        self.title = title_scene_mod.TitleScene.init(self.alloc, self.atlas, self.assets, self.font, texts);
        self.win = window_mod.WindowRenderer.init(self.alloc, self.font, &self.loader);
        self.win.game = &self.mgr.game;
        self.map_render = map_render_mod.MapRenderer.init(self.alloc, &self.loader, self.db);
        // v36 (B3): loader evictions free pixel stores — the renderer's
        // texture cache keys on the pixel base pointer, so an eviction
        // must flush it (a recycled address would alias a stale texture).
        self.loader.on_evict = loaderEvicted;
        self.loader.evict_ctx = self;
        self.battle_troop = battle_mod.Troop.init(self.alloc, self.db);
        self.battle_troop_is_init = true;
        self.port_options = config_mod.Settings.load(self.vfs);
        self.options_ready = true;
        self.applyPortOptions();
    }

    /// v36 (B3): Loader eviction → renderer texture-cache flush.
    fn loaderEvicted(ctx: ?*anyopaque, bytes: usize) void {
        const self: *GameLoop = @ptrCast(@alignCast(ctx orelse return));
        _ = self.renderer.flushTextureCache("loader-evict");
        log.event(.gpu, .note, "loader evicted {d} B — texture cache flushed", .{bytes});
    }

    // ------------------------------------------------------------------
    // main loop
    // ------------------------------------------------------------------

    /// Run until quit or the frame budget. Returns frames drawn.
    pub fn run(self: *GameLoop) u64 {
        self.enterTitle();
        log.milestone("game loop: interactive shell started (renderer={s})", .{@tagName(self.renderer.mode)});
        while (!self.quit) {
            self.frames += 1;

            // A transition invalidates pointer-keyed sprite textures.
            // v35 passes the live SDL table into the flush rather than
            // retaining a pointer into Renderer.init's temporary value.
            if (self.state != self.last_state) {
                log.event(.mv, .note, "TRANSITION 01: state {s} -> {s} — flushing texture cache", .{ @tagName(self.last_state), @tagName(self.state) });
                const cache_entries = self.renderer.cacheEntryCount();
                log.event(.mv, .note, "TRANSITION 02: before flush — cache=0x{x} renderer=0x{x} entries={d} mode={s} (v33 crash site was inside this call)", .{
                    @intFromPtr(&self.renderer.cache),
                    if (self.renderer.renderer) |r| @intFromPtr(r) else @as(usize, 0),
                    cache_entries,
                    if (renderer_mod.flushDestroyEnabled()) "DESTROY (default)" else "DROP (OMORI_FLUSH_DESTROY=0 diagnostic)",
                });
                log.event(.mv, .note, "TRANSITION 03: entered flush", .{});
                const handled = self.renderer.flushTextureCache("transition");
                log.event(.mv, .note, "TRANSITION 98: flush complete ({d} texture slot(s) handled) — entering {s} update/draw", .{ handled, @tagName(self.state) });
                self.last_state = self.state;
                self.transition_first_frame = true;
            }

            // 1. input
            if (self.scripted) |s| {
                s(self, self.frames); // synthetic pad (headless proof)
            } else if (self.renderer.mode == .windowed) {
                if (!self.renderer.pumpEvents(self.input)) {
                    log.milestone("game loop: quit requested (window closed / combo)", .{});
                    break;
                }
                self.renderer.pollSticks(self.input);
            }

            // 2. update
            self.update();

            // 3. draw
            self.loader.beginFrame();
            var dl = draw_mod.DrawList.init(self.alloc);
            defer dl.deinit();
            self.draw(&dl);
            if (self.renderer.mode == .windowed) {
                self.renderer.presentList(&dl);
            } else {
                // headless: validate invariants instead of presenting
                const v = dl.validate();
                if (v.errors > 0) {
                    self.draw_validation_errors += v.errors;
                    log.err("draw list validation failed at frame {d}: {d} error(s)", .{ self.frames, v.errors });
                }
            }
            self.frames_drawn += 1;
            if (self.transition_first_frame) {
                self.transition_first_frame = false;
                log.event(.mv, .note, "TRANSITION 99: first frame drawn in state {s} (frame {d})", .{ @tagName(self.state), self.frames });
            }

            if (self.max_frames > 0 and self.frames >= self.max_frames) {
                log.milestone("game loop: frame budget reached ({d})", .{self.frames});
                break;
            }
        }
        log.milestone("game loop: ended after {d} frame(s), {d} drawn — state={s}", .{ self.frames, self.frames_drawn, @tagName(self.state) });
        return self.frames_drawn;
    }

    // ------------------------------------------------------------------
    // title
    // ------------------------------------------------------------------

    fn enterTitle(self: *GameLoop) void {
        self.menu_calling = false;
        self.state = .title;
        self.title.start() catch |e| {
            self.last_error = "title scene start failed";
            log.err("FATAL_TITLE: title scene start failed ({any})", .{e});
        };
    }

    fn updateTitle(self: *GameLoop) void {
        self.menu_calling = false;
        const ti = titleInput(self.input);
        self.title.update(ti);
        if (self.title.activated) |cmd| {
            switch (cmd) {
                .new_game => self.startNewGame(),
                .continue_ => {
                    self.openLoad();
                    self.title.activated = null;
                },
                .options => {
                    self.openOptions();
                    self.title.activated = null;
                },
                .ported_by => {
                    self.state = .credits;
                    self.title.activated = null;
                },
            }
        }
    }

    fn openLoad(self: *GameLoop) void {
        self.probeSaveSlots();
        self.load_index = 0;
        var newest: i64 = -2;
        for (self.slot_info[0..self.file_slot_count], 0..) |slot, i| {
            if (slot.exists and slot.timestamp > newest) {
                self.load_index = i;
                newest = slot.timestamp;
            }
        }
        self.load_message = "";
        self.state = .load;
    }

    fn updateLoad(self: *GameLoop) void {
        if (self.input.isTriggered(.cancel)) {
            audio_mixer.playSeGlobal("cancel", 100);
            self.state = .title;
            self.title.activated = null;
            return;
        }
        if (self.input.isRepeated(.down)) {
            self.load_index = (self.load_index + 1) % self.file_slot_count;
            self.load_message = "";
            audio_mixer.playSeGlobal("cursor", 100);
        }
        if (self.input.isRepeated(.up)) {
            self.load_index = (self.load_index + self.file_slot_count - 1) % self.file_slot_count;
            self.load_message = "";
            audio_mixer.playSeGlobal("cursor", 100);
        }
        if (!self.input.isTriggered(.confirm)) return;
        if (!self.slot_info[self.load_index].exists) {
            self.load_message = "THIS FILE IS EMPTY";
            audio_mixer.playSeGlobal("buzzer", 100);
            return;
        }
        var sm = self.saveManager();
        const loaded = sm.loadGame(@intCast(self.load_index + 1)) catch |e| blk: {
            log.warn("load file {d} failed ({any})", .{ self.load_index + 1, e });
            break :blk false;
        };
        if (!loaded) {
            self.load_message = "COULD NOT LOAD THIS FILE";
            audio_mixer.playSeGlobal("buzzer", 100);
            return;
        }
        self.enterFieldFromLoad();
        if (self.state == .field) {
            audio_mixer.playSeGlobal("decision", 100);
            if (sm.loaded_backup) self.toastText("LOADED PREVIOUS SAVE BACKUP");
        } else {
            self.load_message = "COULD NOT LOAD THIS FILE";
            audio_mixer.playSeGlobal("buzzer", 100);
        }
    }

    /// NEW GAME: DataManager.setupNewGame + map load + autorun interpreter.
    fn startNewGame(self: *GameLoop) void {
        self.menu_calling = false;
        self.clearParallelEvents();
        self.itp.setup(&.{}, 0);
        self.itp.setCurrentRawMap(null);
        self.mgr.dm.setupNewGame(&self.mgr.game) catch |e| {
            log.err("FATAL_NEWGAME: setupNewGame failed ({any})", .{e});
            return;
        };
        self.mgr.goto(.map);
        self.loadMapForPlayer(true) catch |e| {
            log.err("FATAL_NEWGAME: start map load failed ({any})", .{e});
            return;
        };
        log.milestone("game loop: NEW GAME — map {d}, player at ({d},{d})", .{ self.mgr.game.player.map_id, self.mgr.game.player.x, self.mgr.game.player.y });
        self.state = .field;
    }

    /// CONTINUE: the save was loaded into mgr.game; set the map up.
    fn enterFieldFromLoad(self: *GameLoop) void {
        self.menu_calling = false;
        self.walk_remaining = 0;
        self.tag_active = false;
        self.mgr.game.message.clear();
        self.mgr.goto(.map);
        self.loadMapForPlayer(false) catch |e| {
            log.err("FATAL_LOAD: map {d} load failed ({any})", .{ self.mgr.game.player.map_id, e });
            return;
        };
        self.continued_once = true;
        log.milestone("game loop: CONTINUE — save loaded, map {d}, player at ({d},{d})", .{ self.mgr.game.player.map_id, self.mgr.game.player.x, self.mgr.game.player.y });
        const system = &self.mgr.game.system;
        if (system.bgm_on_save == null and system.bgs_on_save == null) {
            audio_mixer.stopBgmGlobal(0);
            audio_mixer.stopBgsGlobal(0);
            self.autoplayMapAudio(); // older native files did not capture music
        } else {
            if (system.bgm_on_save) |bgm| audio_mixer.replayBgmGlobal(savedAudio(bgm)) else audio_mixer.stopBgmGlobal(0);
            if (system.bgs_on_save) |bgs| audio_mixer.replayBgsGlobal(savedAudio(bgs)) else audio_mixer.stopBgsGlobal(0);
        }
        self.state = .field;
    }

    fn savedAudio(value: game_mod.GameSystem.BgmSave) audio_mixer.SavedAudio {
        return .{ .name = value.name, .volume = @intCast(std.math.clamp(value.volume, 0, 100)), .pitch = @intCast(std.math.clamp(value.pitch, 25, 400)), .pan = @intCast(std.math.clamp(value.pan, 0, 100)) };
    }

    /// (re)load the map data for the player's current position.
    fn loadMapForPlayer(self: *GameLoop, first: bool) !void {
        self.clearParallelEvents();
        self.itp.setup(&.{}, 0);
        self.itp.setCurrentRawMap(null);
        // v36: the map arena holds RawMap + TiledMap + the interpreter's
        // command lists. Reset it between loads ONLY when the
        // interpreter chain is idle (its lists point into the arena);
        // a running chain defers the reset and leaks that cycle's map
        // into the arena until the next idle load.
        if (!self.itp.chainRunning()) {
            self.mgr.dm.resetMapArena();
        } else {
            log.event(.mv, .note, "map arena kept: interpreter chain running (deferred reset)", .{});
        }
        const game = &self.mgr.game;
        const saved_level = game.map.currentMapLevel();
        const saved_scroll = game.map.scripted_scroll;
        const saved_display = [2]f64{ game.map.display_x, game.map.display_y };
        const recover_player_position = !first and game.temp.legacy_collision_recovery;
        // New game follows its pending transfer. Continue follows the
        // restored current map, never the fresh process's boot transfer.
        const map_id = if (first) game.player.new_map_id else game.player.map_id;
        var erased = std.ArrayList(i32).empty;
        defer erased.deinit(self.alloc);
        if (!first) {
            var saved = game.map.erased_events.iterator();
            while (saved.next()) |entry| try erased.append(self.alloc, entry.key_ptr.*);
        }
        try self.mgr.dm.loadMapData(self.vfs, map_id);
        try self.mgr.game.map.setup(&self.mgr.dm.data_map.?, map_id);
        // v36: YED_Tiled — attach the Tiled data (dims replace the MV
        // ones, level variable resets, events relocate) when the map
        // has a Tiled file.
        if (self.mgr.dm.tiled_map) |*t| {
            self.mgr.game.map.setupTiled(&self.mgr.dm.data_map.?, t);
        } else {
            self.mgr.game.map.tiled = null;
        }
        if (!first) for (erased.items) |event_id| try game.map.erased_events.put(event_id, true);
        if (!first) game.map.setCurrentMapLevel(saved_level);
        if (self.db.get("data/CommonEvents.json")) |ce| {
            self.mgr.game.map.setupParallelCommonEvents(ce.value.arrayItems());
        }
        _ = self.mgr.game.player.performTransfer();
        if (!first and game.temp.legacy_collision_recovery) {
            defer game.temp.legacy_collision_recovery = false;
            if (try game.map.findLegacyCollisionRecovery(&self.mgr.dm.data_map.?, game)) |position| {
                log.warn("load: recovered legacy collision position ({d},{d}) -> ({d},{d})", .{ game.player.x, game.player.y, position[0], position[1] });
                game.player.x = position[0];
                game.player.y = position[1];
                game.player.new_x = position[0];
                game.player.new_y = position[1];
                game.synchronizeFollowers();
            }
        }
        // v36: MV Game_Player.locate → center — the camera starts on
        // the player's tile (clamped into the map).
        self.centerCameraOnPlayer();
        if (!first and !recover_player_position and saved_scroll.remaining > 0) {
            game.map.setDisplayPos(saved_display[0], saved_display[1]);
            game.map.scripted_scroll = saved_scroll;
        }
        self.map_render.setTileset(self.mgr.game.map.tileset_id, &self.mgr.dm);
        if (first) game.synchronizeFollowers();
        // v36: MV Scene_Map.start (transfer branch) — map BGM/BGS
        // autoplay on NEW GAME and transfers, never on continue-load.
        if (first) self.autoplayMapAudio();
        if (first) {
            // autorun intro (Map999's "SET IMPORTANT OBJECTS / PLAY
            // SLIDES" etc.) — the MV new-game boot behavior.
            if (self.mgr.game.map.findAutorunEvent(&self.mgr.dm.data_map.?, &self.mgr.game)) |found| {
                log.milestone("game loop: autorun event {d} ({d} commands) — intro starts", .{ found.event_id, found.page.list.len });
                self.itp.setup(found.page.list, found.event_id);
                self.itp.setCurrentRawMap(&self.mgr.dm.data_map.?);
            }
        }
    }

    // ------------------------------------------------------------------
    // options / credits
    // ------------------------------------------------------------------

    fn openOptions(self: *GameLoop) void {
        self.options_return_state = self.state;
        self.options_message = "";
        self.options_save_failed = false;
        self.opt_index %= config_mod.row_count;
        self.state = .options;
    }

    fn applyPortOptions(self: *GameLoop) void {
        self.always_dash = self.port_options.always_run;
        audio_mixer.setVolumesGlobal(.{
            .master = self.port_options.master_volume,
            .bgm = self.port_options.bgm_volume,
            .bgs = self.port_options.bgs_volume,
            .me = self.port_options.me_volume,
            .se = self.port_options.se_volume,
        });
    }

    fn updateOptions(self: *GameLoop) void {
        if (self.input.isRepeated(.down)) {
            self.opt_index = (self.opt_index + 1) % config_mod.row_count;
            if (!self.options_save_failed) self.options_message = "";
            audio_mixer.playSeGlobal("cursor", 100);
        }
        if (self.input.isRepeated(.up)) {
            self.opt_index = (self.opt_index + config_mod.row_count - 1) % config_mod.row_count;
            if (!self.options_save_failed) self.options_message = "";
            audio_mixer.playSeGlobal("cursor", 100);
        }
        const row: config_mod.Row = @enumFromInt(self.opt_index);
        const volume = config_mod.isVolume(row);
        const left = if (volume) self.input.isRepeated(.left) else self.input.isTriggered(.left);
        const right = if (volume) self.input.isRepeated(.right) else self.input.isTriggered(.right);
        const confirm = self.input.isTriggered(.confirm);
        if (confirm or ((left or right) and row != .reset)) {
            const changed = self.port_options.adjust(row, if (left) -1 else 1, confirm);
            if (changed or row == .reset) {
                self.options_dirty = true;
                self.options_save_failed = false;
                self.options_message = if (row == .reset) "DEFAULTS RESTORED" else "";
                self.applyPortOptions();
                // Preview reflects the new SE/master gain, including mute.
                audio_mixer.playSeGlobal("decision", 100);
            }
        }
        if (self.input.isTriggered(.cancel)) {
            if (self.options_ready and self.options_dirty and !self.options_save_failed) {
                self.port_options.save(self.vfs) catch |err| {
                    log.warn("options: cannot save preferences ({any})", .{err});
                    self.options_message = "SAVE FAILED - B: LEAVE WITHOUT SAVING";
                    self.options_save_failed = true;
                    audio_mixer.playSeGlobal("buzzer", 100);
                    return;
                };
                self.options_dirty = false;
            }
            audio_mixer.playSeGlobal("cancel", 100);
            self.state = self.options_return_state;
        }
    }

    fn updateCredits(self: *GameLoop) void {
        if (self.input.isTriggered(.cancel) or self.input.isTriggered(.confirm)) self.state = .title;
    }

    // ------------------------------------------------------------------
    // field
    // ------------------------------------------------------------------

    fn update(self: *GameLoop) void {
        switch (self.state) {
            .title => self.updateTitle(),
            .load => self.updateLoad(),
            .options => self.updateOptions(),
            .credits => self.updateCredits(),
            .field => self.updateField(),
            .menu => self.updateMenu(),
            .battle => self.updateBattle(),
            .battle_result => self.updateBattleResult(),
            .toast => {
                self.toast_frames_left -= 1;
                if (self.toast_frames_left == 0) {
                    self.state = .field;
                } else {
                    self.updateFieldCore(false);
                }
            },
        }
        self.input.endFrame();
    }

    fn updateField(self: *GameLoop) void {
        self.updateFieldCore(true);
    }

    fn updateFieldCore(self: *GameLoop, allow_player: bool) void {
        const game = &self.mgr.game;
        game.frame_count_global += 1;

        // 1. screen effects advance every frame
        game.screen.update();
        game.timer.update();
        @import("balloons.zig").tick(&game.map.balloons);

        // 2. choice navigation (before the interpreter consumes input).
        // v31: MV key-repeat — a held direction walks the choices after
        // the 24-frame delay instead of moving one entry per press.
        const msg = &game.message;
        // A confirm used by a message/event belongs to that interaction
        // for the whole frame. Its final command may finish below; the
        // same press must not immediately reopen the facing event.
        const interaction_at_frame_start = msg.isBusy() or self.itp.chainRunning();
        msg.instant_text = self.port_options.instant_text;
        if (msg.busy and msg.choicesVisible()) {
            if (self.input.isRepeated(.up)) {
                msg.choice_index = @intCast(@mod(@as(i32, @intCast(msg.choice_index)) - 1 + @as(i32, @intCast(msg.choices.items.len)), @as(i32, @intCast(msg.choices.items.len))));
            }
            if (self.input.isRepeated(.down)) {
                msg.choice_index = @intCast(@mod(@as(i32, @intCast(msg.choice_index)) + 1, @as(i32, @intCast(msg.choices.items.len))));
            }
        }

        // A single Window_Message belongs to the map, not to each
        // interpreter. Tick once, then deliver a choice to its issuer.
        self.updateEventInterpreters(.{
            .ok = self.input.isTriggered(.confirm),
            .cancel = self.input.isTriggered(.cancel),
            .held = self.input.frameState(),
            .player_moving = self.walk_remaining > 0,
        });

        // Scroll commands run with the map clock, before the player's
        // camera follow takes its movement-only snapshot.
        game.map.updateScriptedScroll();

        if (self.startRequestedBattle()) return;

        // 4. transfer (requested by the interpreter's commands 201/353/354)
        if (game.player.isTransferring()) {
            self.performTransfer();
            return;
        }

        // 5. message advance is handled inside the interpreter flow; the
        // message window pause consumes ok/cancel (already fed above).

        if (self.tag_active) {
            self.menu_calling = false;
            if (self.itp.chainRunning() or msg.isBusy()) self.tag_active = false else self.updateTagSelection();
            if (self.mgr.dm.tiled_map) |*t| t.updateAnim();
            return;
        }

        // 6. player movement (blocked while a message is visible, an
        // interpreter runs, a fade is in progress, or followers gather)
        const blocked = interaction_at_frame_start or msg.isBusy() or self.itp.chainRunning() or
            game.screen.isFading() or game.temp.player_movement_stopped or game.followers.gathering;
        // MV Scene_Map keeps a menu tap until the current glide ends.
        // Story locks and newly started interactions cancel that request.
        if (!allow_player or blocked or !game.system.menu_enabled) {
            self.menu_calling = false;
        } else if (self.input.isTriggered(.cancel)) {
            self.menu_calling = true;
        }
        // v36: MV Game_Player.update — capture the scrolled position
        // BEFORE this frame's movement; the delta drives updateScroll.
        self.last_scrolled_x = game.map.scrolledX(self.player_real_x);
        self.last_scrolled_y = game.map.scrolledY(self.player_real_y);
        if (allow_player and !blocked and self.walk_remaining == 0) {
            if (self.input.isTriggered(.tag) and self.canOpenTag()) {
                self.tag_active = true;
                self.tag_index = 0;
                if (self.mgr.dm.tiled_map) |*t| t.updateAnim();
                return;
            }
            // v34 (M8): the debug battle hotkey — hold L1+R1 (page_up +
            // page_down, 20 frames) to force an encounter with a real
            // troop from the database. Makes the battle systems
            // device-testable ANYWHERE (the intro maps have no encounter
            // lists), which is how Milestone 8 gets verified on the R36S
            // without grinding to a random-encounter region.
            if (self.input.isPressed(.page_up) and self.input.isPressed(.page_down)) {
                self.debug_battle_frames += 1;
                if (self.debug_battle_frames == 20) {
                    self.debug_battle_frames = 0;
                    self.forceDebugBattle();
                }
            } else {
                self.debug_battle_frames = 0;
            }
            // action button: trigger action events (confirm)
            if (self.input.isTriggered(.confirm)) {
                self.tryActionEvents();
            }
            // A confirm interaction can start after the snapshot above;
            // it takes priority over a pending gameplay-menu request.
            if (self.itp.chainRunning() or msg.isBusy() or game.player.isTransferring()) self.menu_calling = false;
            if (self.menu_calling) {
                if (game.system.menu_enabled) {
                    self.menu_calling = false;
                    self.state = .menu;
                    self.menu_sub = .root;
                    self.menu_index = 0;
                    self.menu_list_index = 0;
                    log.event(.mv, .note, "menu opened", .{});
                    return;
                }
            }
            if (!self.itp.isRunning() and !msg.isBusy()) self.tryPlayerStep();
        }
        game.updateFollowers(self.distancePerFrame(), self.realMoveSpeed());
        if (self.walk_remaining > 0) {
            // v36: MV Game_CharacterBase.updateMove — advance the glide
            // position, then updateScroll (before the arrival events,
            // which see the settled camera).
            self.updateMoveReal();
            self.walk_remaining -= 1;
            self.updateScrollCamera();
            if (self.walk_remaining == 0) {
                self.onPlayerArrived();
            }
        } else {
            self.updateScrollCamera(); // idle: no-op (real == destination)
        }

        // v36: YED Game_Player.update → checkEventTriggerHere →
        // checkMapLevelChanging — the player's tile may switch map
        // levels every frame (writes the Map Level Variable, 26).
        _ = game.map.checkMapLevelChanging(game.player.x, game.player.y);

        // v36: TiledTilemap.update → _updateAnim — the tile animation
        // clock ticks every frame (renderer reads animTileId at draw).
        if (self.mgr.dm.tiled_map) |*t| t.updateAnim();
        if (self.mgr.dm.data_map) |*raw| {
            self.map_render.updateAnimations(raw, game, self.walk_remaining > 0, self.realMoveSpeed());
        }
    }

    fn canOpenTag(self: *GameLoop) bool {
        const game = &self.mgr.game;
        return self.state == .field and game.party.members.items.len > 1 and
            !game.switches.value(16) and !self.itp.chainRunning() and !game.message.isBusy() and
            self.walk_remaining == 0 and !game.temp.player_movement_stopped and
            !self.input.isPressed(.left) and !self.input.isPressed(.right) and
            !self.input.isPressed(.up) and !self.input.isPressed(.down);
    }

    fn updateTagSelection(self: *GameLoop) void {
        const count = self.mgr.game.party.members.items.len;
        if (count <= 1 or self.mgr.game.switches.value(16) or self.input.isTriggered(.cancel)) {
            self.tag_active = false;
            return;
        }
        if (self.input.isRepeated(.right) or self.input.isRepeated(.down)) self.tag_index = (self.tag_index + 1) % count;
        if (self.input.isRepeated(.left) or self.input.isRepeated(.up)) self.tag_index = (self.tag_index + count - 1) % count;
        if (!self.input.isPressed(.tag) or self.input.isTriggered(.confirm)) {
            if (self.tag_index > 0 and self.tag_index < count) {
                const id = self.mgr.game.party.members.items[self.tag_index];
                self.applyTagLeader(id);
            }
            self.tag_active = false;
        }
    }

    fn applyTagLeader(self: *GameLoop, selected: i32) void {
        const game = &self.mgr.game;
        // Omori BASE.sortMembersForTag: real-world canonical party,
        // otherwise selected leader followed by ascending actor IDs.
        if (game.variables.value(22) == 2) {
            game.party.members.ensureTotalCapacity(self.alloc, 4) catch return;
            game.party.members.clearRetainingCapacity();
            game.party.members.appendSlice(self.alloc, &.{ 8, 10, 9, 11 }) catch return;
        }
        const members = game.party.members.items;
        const selected_index = std.mem.indexOfScalar(i32, members, selected) orelse return;
        std.mem.swap(i32, &members[0], &members[selected_index]);
        var i: usize = 2;
        while (i < members.len) : (i += 1) {
            var j = i;
            while (j > 1 and members[j] < members[j - 1]) : (j -= 1) std.mem.swap(i32, &members[j], &members[j - 1]);
        }
        if (game.variables.value(22) == 2) {
            // Preserve the authored real-world tail order 8,10,9,11.
            var tail: usize = 1;
            for ([_]i32{ 8, 10, 9, 11 }) |id| {
                if (id != selected) {
                    members[tail] = id;
                    tail += 1;
                }
            }
        }
        game.variables.setValue(20, selected);
        audio_mixer.playSeGlobal("SYS_tag1", 90);
        log.event(.mv, .note, "tag: leader actor{d}; variable20 updated and follower graphics refreshed", .{selected});
    }

    fn clearParallelEvents(self: *GameLoop) void {
        for (self.parallel_events.items) |entry| {
            entry.interpreter.setCurrentRawMap(null);
            entry.interpreter.deinit();
            self.alloc.destroy(entry.interpreter);
        }
        self.parallel_events.clearRetainingCapacity();
    }

    fn parallelIndex(self: *GameLoop, key: i32) ?usize {
        for (self.parallel_events.items, 0..) |entry, index| {
            if (entry.key == key) return index;
        }
        return null;
    }

    fn commonEventActive(self: *GameLoop, id: i32, trigger: i64) bool {
        const file = self.db.get("data/CommonEvents.json") orelse return false;
        const events = file.value.arrayItems();
        if (id <= 0 or id >= events.len) return false;
        const event = events[@intCast(id)];
        const switch_id = event.getInt("switchId", 0);
        return event.getInt("trigger", 0) == trigger and switch_id > 0 and
            self.mgr.game.switches.value(@intCast(switch_id));
    }

    fn addParallelEvent(self: *GameLoop, key: i32, page: ?*const map_mod.Page) void {
        const interpreter = self.alloc.create(interpreter_mod.Interpreter) catch return;
        interpreter.* = interpreter_mod.Interpreter.init(self.alloc, &self.mgr.game, self.db, self.itp.texts);
        interpreter.scene_battles = true;
        interpreter.field_routes = true;
        interpreter.setCurrentRawMap(if (self.mgr.dm.data_map) |*raw| raw else null);
        self.parallel_events.append(self.alloc, .{ .key = key, .page = page, .interpreter = interpreter }) catch {
            interpreter.deinit();
            self.alloc.destroy(interpreter);
        };
    }

    /// Game_Event.refresh and Game_CommonEvent.refresh: a page/switch
    /// change destroys the old parallel chain, including its waits.
    fn refreshParallelEvents(self: *GameLoop) void {
        const raw = if (self.mgr.dm.data_map) |*map| map else return;
        const game = &self.mgr.game;
        var index: usize = 0;
        while (index < self.parallel_events.items.len) {
            const entry = self.parallel_events.items[index];
            const page = if (entry.key > 0) game.map.currentPage(raw, entry.key, game) else null;
            const active = if (entry.key > 0)
                page != null and page.?.trigger == 4 and page == entry.page
            else
                self.commonEventActive(-entry.key, 2);
            if (active) {
                index += 1;
            } else {
                entry.interpreter.deinit();
                self.alloc.destroy(entry.interpreter);
                _ = self.parallel_events.orderedRemove(index);
            }
        }
        for (raw.events.items) |maybe_event| {
            const event = maybe_event orelse continue;
            const page = game.map.currentPage(raw, event.id, game) orelse continue;
            if (page.trigger == 4 and self.parallelIndex(event.id) == null) self.addParallelEvent(event.id, page);
        }
        if (self.db.get("data/CommonEvents.json")) |file| {
            for (file.value.arrayItems(), 0..) |_, id| {
                const event_id: i32 = @intCast(id);
                if (self.commonEventActive(event_id, 2) and self.parallelIndex(-event_id) == null)
                    self.addParallelEvent(-event_id, null);
            }
        }
    }

    fn setupStartingEvent(self: *GameLoop) void {
        const game = &self.mgr.game;
        if (self.itp.chainRunning() or game.message.isBusy()) return;
        if (game.temp.common_event_id > 0) {
            const id = game.temp.common_event_id;
            game.temp.common_event_id = 0;
            self.itp.setup(self.itp.commonEventList(id), 0);
        } else if (self.mgr.dm.data_map) |*raw| {
            if (game.map.findAutorunEvent(raw, game)) |found| {
                self.itp.setup(found.page.list, found.event_id);
            } else if (self.db.get("data/CommonEvents.json")) |file| {
                for (file.value.arrayItems(), 0..) |_, id| {
                    const event_id: i32 = @intCast(id);
                    if (self.commonEventActive(event_id, 1)) {
                        self.itp.setup(self.itp.commonEventList(event_id), 0);
                        break;
                    }
                }
            }
        }
        self.itp.setCurrentRawMap(if (self.mgr.dm.data_map) |*raw| raw else null);
    }

    fn updateEventInterpreters(self: *GameLoop, input: interpreter_mod.FrameInput) void {
        var message_owner = self.itp.findMessageOwner();
        if (message_owner == null) {
            for (self.parallel_events.items) |entry| {
                if (entry.interpreter.findMessageOwner()) |owner| {
                    message_owner = owner;
                    break;
                }
            }
        }
        self.mgr.game.message.update(input.ok, input.cancel, &self.mgr.game.variables);
        if (message_owner) |owner| owner.acceptChoiceResult();
        self.setupStartingEvent();
        self.itp.setFrameInput(input);
        self.itp.updateCommands();
        if (self.mgr.game.player.isTransferring()) return;
        self.refreshParallelEvents();
        for (self.parallel_events.items) |entry| {
            if (!entry.interpreter.chainRunning()) {
                const list = if (entry.page) |page| page.list else entry.interpreter.commonEventList(-entry.key);
                entry.interpreter.setup(list, if (entry.key > 0) entry.key else 0);
            }
            entry.interpreter.setFrameInput(input);
            entry.interpreter.updateCommands();
            if (self.mgr.game.player.isTransferring()) break;
        }
    }

    /// D-pad → one tile step with collision + direction.
    fn tryPlayerStep(self: *GameLoop) void {
        const game = &self.mgr.game;
        var dir: i32 = 0;
        if (self.input.isTriggered(.up) or self.input.isPressed(.up)) dir = 8;
        if (self.input.isTriggered(.down) or self.input.isPressed(.down)) dir = 2;
        if (self.input.isTriggered(.left) or self.input.isPressed(.left)) dir = 4;
        if (self.input.isTriggered(.right) or self.input.isPressed(.right)) dir = 6;
        if (dir == 0) {
            // face only on action
            return;
        }

        const dx: i32 = if (dir == 4) -1 else if (dir == 6) 1 else 0;
        const dy: i32 = if (dir == 8) -1 else if (dir == 2) 1 else 0;
        const nx = game.player.x + dx;
        const ny = game.player.y + dy;

        // face the direction even when blocked (MV behavior)
        game.player.direction = dir;

        // MV checks the source's outgoing and destination's incoming
        // edges. This prevents entering a solid Tiled cell and getting
        // trapped when the next move checks that cell as its source.
        if (game.map.isTiled() and !game.map.tiledCanStep(game.player.x, game.player.y, dir)) {
            log.detail(.mv, "player blocked (tiled passage) at ({d},{d}) dir {d}", .{ game.player.x, game.player.y, dir });
            return;
        }

        if (self.canWalk(nx, ny)) {
            // followers trail: push the player's old position
            game.chaseFollowers();
            // v36: MV moveStraight — the tile jumps to the destination
            // and _realX/_realY start at the OLD tile (glide source).
            const old_x: f64 = @floatFromInt(game.player.x);
            const old_y: f64 = @floatFromInt(game.player.y);
            game.player.x = nx;
            game.player.y = ny;
            self.player_real_x = old_x;
            self.player_real_y = old_y;
            self.walk_dir = dir;
            self.walk_speed = self.requestedMoveSpeed();
            // v36: MV distancePerFrame = 2^realMoveSpeed / 256 ×
            // (48 / min(tileWidth, tileHeight)); a 1-tile walk takes
            // ceil(1 / distance) frames.
            self.walk_remaining = @intFromFloat(@ceil(1.0 / self.distancePerFrame()));
            self.checkTouchEvents(nx, ny);
        } else {
            log.detail(.mv, "player blocked at ({d},{d}) dir {d}", .{ nx, ny, dir });
        }
    }

    /// v36: MV Game_CharacterBase.distancePerFrame —
    /// 2^realMoveSpeed / 256 × (48 / min(tileWidth, tileHeight))
    /// (YED's multiplier; walk 4 → 0.09375 @32px, dash 5 → 0.1875).
    fn distancePerFrame(self: *GameLoop) f64 {
        const game = &self.mgr.game;
        const speed: f64 = @floatFromInt(self.realMoveSpeed());
        const base = std.math.pow(f64, 2.0, speed) / 256.0;
        const tw = game.map.tileWidth();
        const th = game.map.tileHeight();
        const scale = 48.0 / @as(f64, @floatFromInt(@min(tw, th)));
        return base * scale;
    }

    fn requestedMoveSpeed(self: *const GameLoop) i32 {
        // ConfigManager.alwaysDash defaults false. Enabling it inverts
        // the dash button, so holding X can still request a normal walk.
        const dashing = !self.mgr.game.map.disable_dashing and (self.always_dash != self.input.isPressed(.dash));
        return if (dashing) 5 else 4;
    }

    fn realMoveSpeed(self: *const GameLoop) i32 {
        return if (self.walk_remaining > 0) self.walk_speed else self.requestedMoveSpeed();
    }

    /// v36: MV Game_CharacterBase.updateMove — the glide position
    /// approaches the destination tile at distancePerFrame per frame,
    /// clamped so it lands exactly on the destination.
    fn updateMoveReal(self: *GameLoop) void {
        const game = &self.mgr.game;
        const d = self.distancePerFrame();
        const tx: f64 = @floatFromInt(game.player.x);
        const ty: f64 = @floatFromInt(game.player.y);
        if (tx < self.player_real_x) {
            self.player_real_x = @max(self.player_real_x - d, tx);
        }
        if (tx > self.player_real_x) {
            self.player_real_x = @min(self.player_real_x + d, tx);
        }
        if (ty < self.player_real_y) {
            self.player_real_y = @max(self.player_real_y - d, ty);
        }
        if (ty > self.player_real_y) {
            self.player_real_y = @min(self.player_real_y + d, ty);
        }
    }

    /// v36: MV Game_Player.updateScroll — scroll the map display pos by
    /// this frame's glide delta when the player passed the center zone.
    fn updateScrollCamera(self: *GameLoop) void {
        const map = &self.mgr.game.map;
        const x1 = self.last_scrolled_x;
        const y1 = self.last_scrolled_y;
        const x2 = map.scrolledX(self.player_real_x);
        const y2 = map.scrolledY(self.player_real_y);
        const cx = map.playerCenterX();
        const cy = map.playerCenterY();
        if (y2 > y1 and y2 > cy) map.scrollDown(y2 - y1);
        if (x2 < x1 and x2 < cx) map.scrollLeft(x1 - x2);
        if (x2 > x1 and x2 > cx) map.scrollRight(x2 - x1);
        if (y2 < y1 and y2 < cy) map.scrollUp(y1 - y2);
    }

    /// v36: MV Game_Player.locate → center(x, y) —
    /// setDisplayPos(x − centerX, y − centerY), and the glide snaps to
    /// the located tile (no walk in progress across a transfer).
    fn centerCameraOnPlayer(self: *GameLoop) void {
        const game = &self.mgr.game;
        self.player_real_x = @floatFromInt(game.player.x);
        self.player_real_y = @floatFromInt(game.player.y);
        game.map.setDisplayPos(
            @as(f64, @floatFromInt(game.player.x)) - game.map.playerCenterX(),
            @as(f64, @floatFromInt(game.player.y)) - game.map.playerCenterY(),
        );
    }

    /// v28 collision: map bounds + solid same-level events. Tile passage
    /// bits are approximated (see map_render notes).
    /// Tiled map edges are checked in tryPlayerStep; this checks the
    /// DESTINATION's event collision
    /// and the map bounds (game.map dims — Tiled dims when attached).
    fn canWalk(self: *GameLoop, x: i32, y: i32) bool {
        const game = &self.mgr.game;
        const raw: *const map_mod.RawMap = &(self.mgr.dm.data_map orelse return false);
        const mw = game.map.width;
        const mh = game.map.height;
        if (x < 0 or y < 0 or x >= mw or y >= mh) return false;
        if (raw.events.items.len > 0) {
            for (raw.events.items) |ev_opt| {
                const ev = ev_opt orelse continue;
                if (ev.x != x or ev.y != y) continue;
                if (game.map.isEventErased(ev.id)) continue;
                const page = game.map.currentPage(raw, ev.id, game) orelse continue;
                if (page.priority_type == 1 and !page.through) return false;
            }
        }
        return true;
    }

    fn onPlayerArrived(self: *GameLoop) void {
        // touch-trigger events at the destination
        self.checkTouchEvents(self.mgr.game.player.x, self.mgr.game.player.y);
        // Authored touch events get the whole arrival. In particular,
        // an encounter cannot interrupt a transfer or contact battle.
        self.tickEncounter();
    }

    /// trigger==1 (player touch) / ==2 (event touch) pages at (x,y).
    fn checkTouchEvents(self: *GameLoop, x: i32, y: i32) void {
        const game = &self.mgr.game;
        const raw: *const map_mod.RawMap = &(self.mgr.dm.data_map orelse return);
        if (raw.events.items.len == 0) return;
        if (self.itp.isRunning()) return;
        for (raw.events.items) |ev_opt| {
            const ev = ev_opt orelse continue;
            if (ev.x != x or ev.y != y) continue;
            if (game.map.isEventErased(ev.id)) continue;
            const page = game.map.currentPage(raw, ev.id, game) orelse continue;
            if (page.trigger == 1 or page.trigger == 2) {
                log.event(.mv, .note, "touch event {d} triggered at ({d},{d})", .{ ev.id, x, y });
                self.itp.setup(page.list, ev.id);
                self.itp.setCurrentRawMap(&self.mgr.dm.data_map.?);
                return;
            }
        }
    }

    /// Action button: trigger==0 events at the facing tile (or own tile).
    fn tryActionEvents(self: *GameLoop) void {
        const game = &self.mgr.game;
        const raw: *const map_mod.RawMap = &(self.mgr.dm.data_map orelse return);
        const dir = game.player.direction;
        const dx: i32 = if (dir == 4) -1 else if (dir == 6) 1 else 0;
        const dy: i32 = if (dir == 8) -1 else if (dir == 2) 1 else 0;
        const targets = [_][2]i32{
            .{ game.player.x + dx, game.player.y + dy },
            .{ game.player.x, game.player.y },
        };
        for (targets) |t| {
            for (raw.events.items) |ev_opt| {
                const ev = ev_opt orelse continue;
                if (ev.x != t[0] or ev.y != t[1]) continue;
                if (game.map.isEventErased(ev.id)) continue;
                const page = game.map.currentPage(raw, ev.id, game) orelse continue;
                if (page.trigger == 0) {
                    log.event(.mv, .note, "action event {d} triggered (facing {d})", .{ ev.id, dir });
                    self.itp.setup(page.list, ev.id);
                    self.itp.setCurrentRawMap(&self.mgr.dm.data_map.?);
                    return;
                }
            }
        }
        // ReZig inspection for the three decorative flowers in Neighbor's
        // Room. Their data contains artwork and solid collision but no
        // event. Let every authored interaction above claim the press first.
        if (game.map.map_id == 88) {
            const tiled = game.map.tiled orelse return;
            if (!tiled.hasVisibleTile(targets[0][0], targets[0][1], game.map.currentMapLevel(), "DW_NeighborsRoom", 34)) return;
            const flower = self.itp.texts.getMessageData("dw_flavor_text.message_92") catch null;
            game.message.clear();
            if (flower) |description| {
                game.message.setBackground(description.background);
                game.message.setPositionType(description.position);
                game.message.add(description.text);
            } else game.message.add("A small flower grows here.");
            log.event(.mv, .note, "inspected room flower at ({d},{d})", .{ targets[0][0], targets[0][1] });
        }
    }

    /// v34 (M8): the debug battle — pick a real troop (the map's first
    /// encounter, else the first non-null Troops.json entry) and enter
    /// the battle through the same startBattle() path as a random
    /// encounter. L1+R1 held ~1/3 s in the field triggers it.
    /// v36: the payload's early troops are EMPTY (troop 1 has no
    /// members — an empty battle is useless on the device); advance to
    /// the first troop that has members.
    fn forceDebugBattle(self: *GameLoop) void {
        var troop: i32 = battle_mod.debugTroopOverride(self.db) orelse 0;
        if (troop == 0) if (self.mgr.dm.data_map) |raw| {
            if (raw.encounter_list.len > 0) troop = raw.encounter_list[0].troop_id;
        };
        if (troop <= 0) {
            if (self.db.get("data/Troops.json")) |f| {
                for (f.value.arrayItems()) |t| {
                    if (t == .null) continue;
                    troop = @intCast(t.getInt("id", 0));
                    if (troop > 0) break;
                }
            }
        }
        if (troop <= 0) {
            log.event(.mv, .note, "debug battle: no troop found in the database — skipped", .{});
            return;
        }
        // v36: advance to the first troop with members.
        const items: usize = if (self.db.get("data/Troops.json")) |f| f.value.arrayItems().len else 0;
        const picked = troop;
        var t = picked;
        var found = false;
        while (t >= 0 and t < @as(i32, @intCast(items))) : (t += 1) {
            if (self.troopMemberCount(t) > 0) {
                troop = t;
                found = true;
                break;
            }
        }
        if (!found) {
            log.event(.mv, .note, "debug battle: every troop is empty — skipped", .{});
            return;
        }
        if (troop != picked) log.event(.mv, .note, "debug battle: empty troop {d} skipped → troop {d}", .{ picked, troop });
        log.milestone("game loop: DEBUG BATTLE hotkey (L1+R1) — forcing troop {d}", .{troop});
        self.startBattle(troop);
    }

    /// $dataTroops[troopId].members length (0 when absent/empty).
    fn troopMemberCount(self: *GameLoop, troop_id: i32) usize {
        if (troop_id <= 0) return 0;
        const f = self.db.get("data/Troops.json") orelse return 0;
        const items = f.value.arrayItems();
        if (troop_id >= @as(i32, @intCast(items.len))) return 0;
        const t = items[@intCast(troop_id)];
        if (t != .object) return 0;
        const members = t.get("members") orelse return 0;
        return members.arrayItems().len;
    }

    /// Count completed free steps, then roll in the destination's region.
    /// Expiring where no troop is eligible still schedules a new interval.
    fn tickEncounter(self: *GameLoop) void {
        const game = &self.mgr.game;
        const raw = if (self.mgr.dm.data_map) |*map| map else return;
        if (raw.encounter_step <= 0 or raw.encounter_list.len == 0 or !game.system.encounter_enabled) return;
        if (self.state != .field or self.itp.chainRunning() or game.message.isBusy() or game.player.isTransferring() or
            game.temp.player_movement_stopped or game.screen.isFading() or game.followers.gathering) return;

        const traits = game.party.encounterTraits();
        if (traits.none) return;

        const player = &game.player;
        const random = self.encounter_rng.random();
        const countdown = player.encounter_count orelse encounter_mod.rollCountdown(raw.encounter_step, random).?;
        const brush = !game.map.isTiled() and encounter_mod.isBush(self.db, raw, player.x, player.y);
        const points: f64 = if (brush) 2 else 1;
        player.encounter_count = countdown - points * (if (traits.half) @as(f64, 0.5) else 1);
        if (player.encounter_count.? > 0) return;

        player.encounter_count = encounter_mod.rollCountdown(raw.encounter_step, random);
        const region = game.map.encounterRegion(raw, player.x, player.y, true);
        const troop = encounter_mod.selectTroop(raw.encounter_list, region, random) orelse return;
        if (self.troopMemberCount(troop) == 0) return;
        log.milestone("game loop: encounter troop {d} in region {d}", .{ troop, region });
        self.startBattle(troop);
    }

    /// The interpreter (or the action button) requested a map transfer.
    fn performTransfer(self: *GameLoop) void {
        self.menu_calling = false;
        const game = &self.mgr.game;
        const target_map = game.player.new_map_id;
        self.clearParallelEvents();
        self.itp.setCurrentRawMap(null);
        // v36: arena reset gate (see loadMapForPlayer) — the transfer
        // interpreter may still be finishing; skip the reset when it is.
        if (!self.itp.chainRunning()) {
            self.mgr.dm.resetMapArena();
        } else {
            log.event(.mv, .note, "map arena kept: interpreter chain running (deferred reset)", .{});
        }
        if (self.mgr.dm.data_map_id != target_map or self.mgr.dm.data_map == null) {
            self.mgr.dm.loadMapData(self.vfs, target_map) catch |e| {
                log.err("FATAL_MAP: transfer target map {d} failed ({any})", .{ target_map, e });
                self.quit = true;
                return;
            };
        }
        game.map.setup(&self.mgr.dm.data_map.?, target_map) catch |e| {
            log.err("FATAL_MAP: map setup {d} failed ({any})", .{ target_map, e });
            self.quit = true;
            return;
        };
        // v36: YED_Tiled — attach the Tiled data when present.
        if (self.mgr.dm.tiled_map) |*t| {
            game.map.setupTiled(&self.mgr.dm.data_map.?, t);
        } else {
            game.map.tiled = null;
        }
        if (self.db.get("data/CommonEvents.json")) |ce| {
            game.map.setupParallelCommonEvents(ce.value.arrayItems());
        }
        _ = game.player.performTransfer();
        // v36: MV Game_Player.locate → center.
        self.centerCameraOnPlayer();
        self.itp.setCurrentRawMap(&self.mgr.dm.data_map.?);
        self.itp.clearSceneChangeDeep();
        self.map_render.setTileset(game.map.tileset_id, &self.mgr.dm);
        self.walk_remaining = 0;
        game.synchronizeFollowers();
        // v36: MV Scene_Map.start (transfer branch) — BGM/BGS autoplay.
        self.autoplayMapAudio();
        // Keep the transfer caller alive: common-event commands after
        // the transfer still run. The scheduler starts the new map's
        // autoruns once that chain finishes.
        log.milestone("game loop: transfer → map {d} '{s}', player at ({d},{d})", .{ target_map, self.mgr.dm.mapName(target_map), game.player.x, game.player.y });
    }

    /// MV `Game_Map.autoplay` — the map's BGM/BGS request. Called from
    /// Scene_Map.start's transfer branch only: new game + transfers,
    /// never continue-load.
    fn autoplayMapAudio(self: *GameLoop) void {
        const raw = &(self.mgr.dm.data_map orelse return);
        if (raw.autoplay_bgm) {
            audio_mixer.playBgmPanGlobal(
                raw.bgm.name,
                @intCast(std.math.clamp(raw.bgm.volume, 0, 100)),
                @intCast(std.math.clamp(raw.bgm.pitch, 25, 400)),
                @intCast(std.math.clamp(raw.bgm.pan, 0, 100)),
            );
            log.event(.audio, .note, "map autoplay BGM: '{s}' vol={d} pitch={d}", .{ raw.bgm.name, raw.bgm.volume, raw.bgm.pitch });
        }
        if (raw.autoplay_bgs) {
            audio_mixer.playBgsPanGlobal(
                raw.bgs.name,
                @intCast(std.math.clamp(raw.bgs.volume, 0, 100)),
                @intCast(std.math.clamp(raw.bgs.pitch, 25, 400)),
                @intCast(std.math.clamp(raw.bgs.pan, 0, 100)),
            );
            log.event(.audio, .note, "map autoplay BGS: '{s}' vol={d} pitch={d}", .{ raw.bgs.name, raw.bgs.volume, raw.bgs.pitch });
        }
    }

    // ------------------------------------------------------------------
    // v36: battle audio (MV BattleManager + Scene_Map.launchBattle)
    // ------------------------------------------------------------------

    /// MV BattleManager.saveBgmAndBgs — snapshot the map audio for the
    /// battle gap. The snapshot borrows the mixer's owned copies (valid
    /// until the next battle's save replaces them).
    fn saveBgmAndBgs(self: *GameLoop) void {
        self.battle_map_bgm = audio_mixer.saveBgmGlobal();
        self.battle_map_bgs = audio_mixer.saveBgsGlobal();
        log.event(.audio, .note, "saveBgmAndBgs: bgm '{s}' bgs '{s}'", .{ self.battle_map_bgm.name, self.battle_map_bgs.name });
    }

    /// MV Scene_Map.stopAudioOnBattleStart — stop the BGM unless it is
    /// already the battle BGM, then BGS/ME/SE.
    fn stopAudioOnBattleStart(self: *GameLoop) void {
        const bgm = self.effectiveBattleBgm();
        const cur = audio_mixer.currentBgmNameGlobal();
        const is_current = bgm.name.len > 0 and cur != null and std.mem.eql(u8, cur.?, bgm.name);
        if (!is_current) audio_mixer.stopBgmGlobal(0);
        audio_mixer.stopBgsGlobal(0);
        if (audio_mixer.instance) |mixer| mixer.stopMe();
        audio_mixer.stopSeGlobal();
        log.event(.audio, .note, "stopAudioOnBattleStart (battle bgm '{s}')", .{bgm.name});
    }

    /// MV Game_System.battleBgm() — `_battleBgm` (command 132) or
    /// $dataSystem.battleBgm. The payload's name is empty → silent.
    fn effectiveBattleBgm(self: *GameLoop) audio_mixer.SavedAudio {
        if (self.mgr.game.system.battle_bgm) |b| {
            return .{
                .name = b.name,
                .volume = @intCast(@max(b.volume, 0)),
                .pitch = @intCast(@max(b.pitch, 0)),
                .pan = @intCast(@max(b.pan, 0)),
            };
        }
        if (self.db.get("data/System.json")) |f| {
            if (f.value.get("battleBgm")) |b| {
                return .{
                    .name = b.getString("name") orelse "",
                    .volume = @intCast(@max(b.getInt("volume", 90), 0)),
                    .pitch = @intCast(@max(b.getInt("pitch", 100), 0)),
                    .pan = @intCast(@max(b.getInt("pan", 0), 0)),
                };
            }
        }
        return .{};
    }

    /// MV Game_System.victoryMe() — `_victoryMe` (command 133) or
    /// $dataSystem.victoryMe ("xx_victory" in the payload).
    fn effectiveVictoryMe(self: *GameLoop) audio_mixer.SavedAudio {
        if (self.mgr.game.system.victory_me) |b| {
            return .{
                .name = b.name,
                .volume = @intCast(@max(b.volume, 0)),
                .pitch = @intCast(@max(b.pitch, 0)),
                .pan = @intCast(@max(b.pan, 0)),
            };
        }
        if (self.db.get("data/System.json")) |f| {
            if (f.value.get("victoryMe")) |b| {
                return .{
                    .name = b.getString("name") orelse "",
                    .volume = @intCast(@max(b.getInt("volume", 100), 0)),
                    .pitch = @intCast(@max(b.getInt("pitch", 100), 0)),
                    .pan = @intCast(@max(b.getInt("pan", 0), 0)),
                };
            }
        }
        return .{};
    }

    /// MV Game_System.defeatMe() — empty in the payload → silent.
    fn effectiveDefeatMe(self: *GameLoop) audio_mixer.SavedAudio {
        if (self.db.get("data/System.json")) |f| {
            if (f.value.get("defeatMe")) |b| {
                return .{
                    .name = b.getString("name") orelse "",
                    .volume = @intCast(@max(b.getInt("volume", 100), 0)),
                    .pitch = @intCast(@max(b.getInt("pitch", 100), 0)),
                    .pan = @intCast(@max(b.getInt("pan", 0), 0)),
                };
            }
        }
        return .{};
    }

    /// MV SoundManager.playBattleStart — playSystemSound(7): the
    /// $dataSystem.sounds[7] entry, RAW (no logical-name mapping). The
    /// payload's entry name is empty → skip.
    fn playBattleStartSe(self: *GameLoop) void {
        const f = self.db.get("data/System.json") orelse return;
        const sounds = f.value.get("sounds") orelse return;
        const items = sounds.arrayItems();
        if (items.len <= 7) return;
        const s = items[7];
        if (s != .object) return;
        const name = s.getString("name") orelse "";
        if (name.len == 0) return;
        const vol: u32 = @intCast(std.math.clamp(s.getInt("volume", 100), 0, 100));
        if (audio_mixer.instance) |m| m.playSeRaw(name, vol);
        log.event(.audio, .note, "playBattleStart: '{s}' vol={d}", .{ name, vol });
    }

    /// MV BattleManager.playBattleBgm (Scene_Battle.start) —
    /// playBgm(battleBgm) + stopBgs. Empty name → stopBgm (silent).
    fn playBattleBgm(self: *GameLoop) void {
        const bgm = self.effectiveBattleBgm();
        audio_mixer.playBgmPanGlobal(bgm.name, bgm.volume, bgm.pitch, bgm.pan);
        audio_mixer.stopBgsGlobal(0);
    }

    /// MV BattleManager.playVictoryMe — one-shot music effect; the
    /// mixer pauses/replays BGM without replacing the saved map track.
    fn playVictoryMe(self: *GameLoop) void {
        const me = self.effectiveVictoryMe();
        if (me.name.len == 0) return;
        audio_mixer.playMeGlobal(me.name, me.volume, me.pitch);
        log.event(.audio, .note, "playVictoryMe: '{s}' vol={d}", .{ me.name, me.volume });
    }

    fn playDefeatMe(self: *GameLoop) void {
        const me = self.effectiveDefeatMe();
        if (me.name.len == 0) return;
        audio_mixer.playMeGlobal(me.name, me.volume, me.pitch);
        log.event(.audio, .note, "playDefeatMe: '{s}' vol={d}", .{ me.name, me.volume });
    }

    /// MV BattleManager.replayBgmAndBgs — same-name tracks update their
    /// parameters only; others restart + 0.5 s fade-in.
    fn replayBgmAndBgs(self: *GameLoop) void {
        audio_mixer.replayBgmGlobal(self.battle_map_bgm);
        audio_mixer.replayBgsGlobal(self.battle_map_bgs);
        log.event(.audio, .note, "replayBgmAndBgs: bgm '{s}' bgs '{s}'", .{ self.battle_map_bgm.name, self.battle_map_bgs.name });
    }

    // ------------------------------------------------------------------
    // menu
    // ------------------------------------------------------------------

    const MENU_COMMANDS = [_][]const u8{ "ITEM", "SKILL", "SAVE", "OPTIONS", "QUIT" };

    fn updateMenu(self: *GameLoop) void {
        const cancel = self.input.isTriggered(.cancel);
        const ok = self.input.isTriggered(.confirm);
        const up = self.input.isRepeated(.up);
        const down = self.input.isRepeated(.down);

        switch (self.menu_sub) {
            .root => {
                if (down) {
                    self.menu_index = (self.menu_index + 1) % MENU_COMMANDS.len;
                    audio_mixer.playSeGlobal("cursor", 100);
                }
                if (up) {
                    self.menu_index = (self.menu_index + MENU_COMMANDS.len - 1) % MENU_COMMANDS.len;
                    audio_mixer.playSeGlobal("cursor", 100);
                }
                if (cancel) {
                    audio_mixer.playSeGlobal("cancel", 100);
                    self.state = .field;
                    return;
                }
                if (ok) {
                    audio_mixer.playSeGlobal("decision", 100);
                    switch (self.menu_index) {
                        0 => self.openItemList(),
                        1 => self.openSkillList(),
                        2 => {
                            self.menu_sub = .save;
                            self.menu_list_index = 0;
                            self.probeSaveSlots();
                        },
                        3 => self.openOptions(),
                        4 => {
                            // QUIT → title (MV "end game")
                            log.milestone("game loop: menu QUIT → title", .{});
                            self.state = .title;
                            self.title.activated = null;
                            self.title.frame = 0;
                        },
                        else => {},
                    }
                }
            },
            .item, .skill => {
                const list_len = self.menu_ids.items.len;
                if (list_len > 0) {
                    if (down) self.menu_list_index = (self.menu_list_index + 1) % list_len;
                    if (up) self.menu_list_index = (self.menu_list_index + list_len - 1) % list_len;
                    if (ok and self.menu_sub == .item) {
                        self.useItem(self.menu_ids.items[self.menu_list_index]);
                    }
                }
                if (cancel) {
                    self.menu_sub = .root;
                    self.menu_list_index = 0;
                }
            },
            .save => {
                if (down) self.menu_list_index = (self.menu_list_index + 1) % self.file_slot_count;
                if (up) self.menu_list_index = (self.menu_list_index + self.file_slot_count - 1) % self.file_slot_count;
                if (cancel) {
                    self.menu_sub = .root;
                    self.menu_list_index = 0;
                }
                if (ok) {
                    const slot: i32 = @intCast(self.menu_list_index + 1);
                    self.saveGameAt(slot);
                    self.state = .toast;
                    self.toast_frames_left = TOAST_FRAMES;
                }
            },
        }
    }

    fn openItemList(self: *GameLoop) void {
        self.menu_ids.clearRetainingCapacity();
        const game = &self.mgr.game;
        // Usable items in the party inventory (Items.json entries with
        // an HP recovery effect; everything else lists too, use = noop).
        if (self.db.get("data/Items.json")) |f| {
            const items = f.value.arrayItems();
            for (items) |it| {
                if (it == .null) continue;
                const id: i32 = @intCast(it.getInt("id", 0));
                if (id == 0) continue;
                if (game.party.numItems(id) > 0) {
                    self.menu_ids.append(self.alloc, id) catch {};
                }
            }
        }
        self.menu_sub = .item;
        self.menu_list_index = 0;
        log.event(.mv, .note, "menu: {d} item(s) in inventory", .{self.menu_ids.items.len});
    }

    fn openSkillList(self: *GameLoop) void {
        self.menu_ids.clearRetainingCapacity();
        if (self.mgr.game.party.leader()) |leader| {
            for (leader.skills.items) |sid| {
                self.menu_ids.append(self.alloc, sid) catch {};
            }
        }
        self.menu_sub = .skill;
        self.menu_list_index = 0;
    }

    fn useItem(self: *GameLoop, item_id: i32) void {
        const game = &self.mgr.game;
        if (battle_mod.useFieldItem(self.db, game, item_id)) {
            const item = battle_mod.itemData(self.db, item_id).?;
            var message_buf: [160]u8 = undefined;
            const message = std.fmt.bufPrint(&message_buf, "USED {s}", .{item.getString("name") orelse "ITEM"}) catch "USED ITEM";
            self.toastText(message);
        } else {
            self.toastText("CANNOT USE HERE");
        }
        if (game.party.numItems(item_id) <= 0) self.openItemList();
    }

    fn probeSaveSlots(self: *GameLoop) void {
        var sm = self.saveManager();
        self.slot_info = sm.readSlotInfo() catch @splat(.{});
        self.file_slot_count = 6;
        for (&self.save_slots, 0..) |*s, i| {
            s.* = self.slot_info[i].exists;
            if (s.*) self.file_slot_count = @max(self.file_slot_count, i + 1);
        }
    }

    fn saveGameAt(self: *GameLoop, slot: i32) void {
        var sm = self.saveManager();
        if (audio_mixer.instance != null) {
            const bgm = audio_mixer.saveBgmGlobal();
            const bgs = audio_mixer.saveBgsGlobal();
            sm.captureAudioOnSave(
                .{ .name = bgm.name, .volume = @intCast(bgm.volume), .pitch = @intCast(bgm.pitch), .pan = @intCast(bgm.pan) },
                .{ .name = bgs.name, .volume = @intCast(bgs.volume), .pitch = @intCast(bgs.pitch), .pan = @intCast(bgs.pan) },
            ) catch {
                self.toastText("SAVE FAILED");
                return;
            };
        }
        const ok = sm.saveGame(slot) catch false;
        if (ok) {
            self.save_happened = true;
            log.milestone("game loop: saved to slot {d} (map {d}, playtime {d}s)", .{ slot, self.mgr.game.map.map_id, self.mgr.game.frame_count_global / 60 });
            var label: [64]u8 = undefined;
            self.toastText(std.fmt.bufPrint(&label, "SAVED - SLOT {d}", .{slot}) catch "SAVED");
        } else {
            log.err("game loop: save to slot {d} FAILED", .{slot});
            self.toastText("SAVE FAILED");
        }
    }

    fn toastText(self: *GameLoop, text: []const u8) void {
        if (self.toast_text.len > 0) self.alloc.free(self.toast_text);
        self.toast_text = self.alloc.dupe(u8, text) catch "";
        self.toast_frames_left = TOAST_FRAMES;
        self.state = .toast;
    }

    /// A transient SaveManager (vfs + game + db are loop-stable).
    fn saveManager(self: *GameLoop) save_mod.SaveManager {
        return save_mod.SaveManager.init(self.alloc, self.db, self.vfs, &self.mgr.game);
    }

    // ------------------------------------------------------------------
    // battle
    // ------------------------------------------------------------------

    fn startBattle(self: *GameLoop, troop_id: i32) void {
        self.startBattleWithRules(troop_id, true, false);
    }

    fn startRequestedBattle(self: *GameLoop) bool {
        var owner = self.itp.pendingSceneBattle();
        if (owner == null) {
            for (self.parallel_events.items) |entry| {
                if (entry.interpreter.pendingSceneBattle()) |pending| {
                    owner = pending;
                    break;
                }
            }
        }
        const interpreter = owner orelse return false;
        const request = &interpreter.scene_battle.?;
        request.claimed = true;
        self.battle_interpreter = interpreter;
        self.startBattleWithRules(request.troop_id, request.can_escape, request.can_lose);
        return true;
    }

    fn startBattleWithRules(self: *GameLoop, troop_id: i32, can_escape: bool, can_lose: bool) void {
        self.menu_calling = false;
        // v36: MV Scene_Map.launchBattle — snapshot the map audio,
        // stop BGM/BGS/ME/SE (unless the BGM already IS the battle
        // BGM), then the battle-start SE (payload: silent).
        self.saveBgmAndBgs();
        self.stopAudioOnBattleStart();
        self.playBattleStartSe();
        if (self.battle) |*old| {
            old.deinit();
            self.battle = null;
        }
        if (self.battle_troop_is_init) {
            self.battle_troop.deinit();
        }
        self.battle_troop = battle_mod.Troop.init(self.alloc, self.db);
        self.battle_troop_is_init = true;
        self.battle = battle_mod.Manager.init(self.alloc, self.db, &self.mgr.game, &self.battle_troop, self.frames * 7919 + 1);
        self.battle.?.setup(troop_id, can_escape, can_lose);
        self.battle.?.startBattle();
        self.battle_phase = .command;
        self.battle_command_index = 0;
        self.battle_target_index = 0;
        self.battle_skills.clearRetainingCapacity();
        self.state = .battle;
        // MV Scene_Battle.start → BattleManager.playBattleBgm (the
        // payload's battleBgm name is empty → silent, faithful).
        self.playBattleBgm();
        var living: usize = 0;
        for (self.battle_troop.enemies.items) |enemy| {
            if (enemy.isAlive()) living += 1;
        }
        log.milestone("battle UI: troop {d} — {d} enemy(ies)", .{ troop_id, living });
    }

    const BATTLE_COMMANDS = [_][]const u8{ "ATTACK", "SKILL", "ITEM", "ESCAPE", "GUARD" };

    fn updateBattle(self: *GameLoop) void {
        const b = if (self.battle) |*manager| manager else return;
        switch (self.battle_phase) {
            .command => {
                if (self.input.isTriggered(.cancel)) {
                    if (b.party_commands.pop()) |previous| {
                        self.battle_command_index = restoredBattleCommand(previous, self.battleCommandActor());
                    }
                    return;
                }
                if (self.input.isTriggered(.down)) self.battle_command_index = (self.battle_command_index + 1) % BATTLE_COMMANDS.len;
                if (self.input.isTriggered(.up)) self.battle_command_index = (self.battle_command_index + BATTLE_COMMANDS.len - 1) % BATTLE_COMMANDS.len;
                if (self.input.isTriggered(.confirm)) {
                    switch (self.battle_command_index) {
                        0, 4 => {
                            const actor = self.battleCommandActor() orelse return;
                            const guard = self.battle_command_index == 4;
                            const id = if (guard) @as(i32, 2) else actor.battleAttackSkillId();
                            const data = battle_mod.skillData(self.db, id) orelse return;
                            if (guard and data.getInt("scope", 0) != 11) {
                                audio_mixer.playSeGlobal("buzzer", 100);
                                return;
                            }
                            self.battle_action = .{ .kind = .skill, .skill_id = id, .subject_index = @intCast(actor.actor_id) };
                            self.battle_target_return = .command;
                            self.beginBattleTarget();
                        },
                        1 => self.openBattleList(false),
                        2 => self.openBattleList(true),
                        3 => {
                            if (!b.can_escape) {
                                audio_mixer.playSeGlobal("buzzer", 100);
                                return;
                            }
                            const escaped = b.processEscape();
                            if (escaped) {
                                self.finishBattle(.escape);
                            } else {
                                self.setBattleResultText("COULDN'T ESCAPE!");
                                self.battle_phase = .resolving;
                            }
                        },
                        else => {},
                    }
                }
            },
            .skill_list, .item_list => {
                if (self.input.isTriggered(.cancel)) {
                    self.battle_phase = .command;
                    return;
                }
                const count = self.battle_skills.items.len;
                if (count == 0) return;
                if (self.input.isRepeated(.down)) self.battle_list_index = (self.battle_list_index + 1) % count;
                if (self.input.isRepeated(.up)) self.battle_list_index = (self.battle_list_index + count - 1) % count;
                if (self.input.isTriggered(.confirm)) {
                    const actor = self.battleCommandActor() orelse return;
                    const is_item = self.battle_phase == .item_list;
                    const id = self.battle_skills.items[self.battle_list_index];
                    self.battle_action = .{ .kind = if (is_item) .item else .skill, .skill_id = if (is_item) 0 else id, .item_id = if (is_item) id else 0, .subject_index = @intCast(actor.actor_id) };
                    self.battle_target_return = if (is_item) .item_list else .skill_list;
                    self.beginBattleTarget();
                }
            },
            .target => {
                if (self.input.isTriggered(.cancel)) {
                    self.battle_phase = switch (self.battle_target_return) {
                        .command => .command,
                        .skill_list => .skill_list,
                        .item_list => .item_list,
                    };
                    return;
                }
                const count = self.battleTargetCount();
                if (count == 0) return;
                const scope = self.battleScope();
                if (scope == 1 or scope == 7 or scope == 9) {
                    if (self.input.isTriggered(.right) or self.input.isTriggered(.down)) self.battle_target_index = (self.battle_target_index + 1) % count;
                    if (self.input.isTriggered(.left) or self.input.isTriggered(.up)) self.battle_target_index = (self.battle_target_index + count - 1) % count;
                }
                if (self.input.isTriggered(.confirm)) {
                    const actor = self.mgr.game.actors.actor(@intCast(self.battle_action.subject_index)) orelse return;
                    if (!b.canUseAction(.{ .actor = actor }, self.battle_action) or
                        (self.battle_action.kind == .item and b.freeItemCount(self.battle_action.item_id) == 0))
                    {
                        audio_mixer.playSeGlobal("buzzer", 100);
                        self.battle_phase = .command;
                        return;
                    }
                    self.battle_action.target_index = self.battleTargetUnitIndex(self.battle_target_index);
                    self.battle_action.target_friends = if (self.battleDualTarget()) self.battleTargetChoice(self.battle_target_index).?.friends else null;
                    b.party_commands.append(self.alloc, self.battle_action) catch {
                        audio_mixer.playSeGlobal("buzzer", 100);
                        return;
                    };
                    self.battle_command_index = 0;
                    self.battle_phase = if (self.battleCommandActor() == null) .resolving else .command;
                }
            },
            .result => {},
            .resolving => {
                // resolve ONE turn through the validated engine, then
                // back to the command phase (interactive turn loop)
                b.startSelectedInput();
                b.startTurn();
                var guard: i32 = 0;
                while (guard < 200) : (guard += 1) {
                    if (b.checkBattleEnd()) {
                        self.finishBattle(b.result orelse .win);
                        return;
                    }
                    b.updateTurn();
                    if (b.phase == .turn_end) break;
                }
                if (b.checkBattleEnd()) {
                    self.finishBattle(b.result orelse .win);
                    return;
                }
                self.battle_phase = .command;
                self.battle_command_index = 0;
            },
        }
    }

    fn battleCommandActor(self: *GameLoop) ?*game_mod.GameActor {
        const manager = if (self.battle) |*b| b else return null;
        return manager.nextCommandActor();
    }

    fn restoredBattleCommand(action: battle_mod.Action, actor: ?*game_mod.GameActor) usize {
        if (action.kind == .item) return 2;
        if (actor) |member| {
            if (action.skill_id == member.battleAttackSkillId()) return 0;
            const skill = battle_mod.skillData(member.db, action.skill_id) orelse return 1;
            if (action.skill_id == 2 and skill.getInt("scope", 0) == 11) return 4;
        }
        return 1;
    }

    fn openBattleList(self: *GameLoop, is_item: bool) void {
        self.battle_skills.clearRetainingCapacity();
        self.battle_list_index = 0;
        self.battle_phase = if (is_item) .item_list else .skill_list;
        const actor = self.battleCommandActor() orelse return;
        const b = if (self.battle) |*manager| manager else return;
        if (is_item) {
            const file = self.db.get("data/Items.json") orelse return;
            for (file.value.arrayItems()) |item| {
                if (item == .null or item.getInt("itypeId", 1) != 1) continue;
                const id: i32 = @intCast(item.getInt("id", 0));
                const scope = item.getInt("scope", 0);
                if (scope < 1 or scope > 11) continue;
                const action = battle_mod.Action{ .kind = .item, .item_id = id };
                if (b.freeItemCount(id) > 0 and b.canUseAction(.{ .actor = actor }, action)) self.battle_skills.append(self.alloc, id) catch {};
            }
        } else {
            for (actor.skills.items) |id| {
                const skill = battle_mod.skillData(self.db, id) orelse continue;
                // OMORI's skill setup excludes hidden chain checks;
                // stype0 is the MV basic command, not a menu skill.
                if (skill.getInt("stypeId", 1) == 0) continue;
                if (std.ascii.indexOfIgnoreCase(skill.getString("note") orelse "", "<HideInMenu>") != null) continue;
                const scope = skill.getInt("scope", 0);
                if (scope < 1 or scope > 11) continue;
                const action = battle_mod.Action{ .kind = .skill, .skill_id = id };
                if (b.canUseAction(.{ .actor = actor }, action)) self.battle_skills.append(self.alloc, id) catch {};
            }
        }
    }

    fn battleScope(self: *GameLoop) i64 {
        const data = self.battle_action.item(self.db) orelse return 0;
        return data.getInt("scope", 1);
    }

    fn battleDualTarget(self: *GameLoop) bool {
        const data = self.battle_action.item(self.db) orelse return false;
        const note = data.getString("note") orelse return false;
        return std.ascii.indexOfIgnoreCase(note, "<Enemy or Actor Select>") != null;
    }

    fn beginBattleTarget(self: *GameLoop) void {
        self.battle_target_index = 0;
        if (self.battleTargetCount() == 0) {
            audio_mixer.playSeGlobal("buzzer", 100);
            return;
        }
        self.battle_phase = .target;
    }

    fn battleTargetCount(self: *GameLoop) usize {
        const scope = self.battleScope();
        if (scope == 11) return if (self.battleCommandActor() != null) 1 else 0;
        var count: usize = 0;
        const dual = self.battleDualTarget();
        if (dual or (scope >= 1 and scope <= 6)) {
            const b = if (self.battle) |*manager| manager else return 0;
            for (b.troop.enemies.items) |enemy| {
                if (enemy.isAlive()) count += 1;
            }
        }
        if (dual or (scope >= 7 and scope <= 10)) {
            for (self.mgr.game.party.members.items) |id| {
                const actor = self.mgr.game.actors.actor(id) orelse continue;
                if ((actor.hp <= 0) == (scope == 9 or scope == 10)) count += 1;
            }
        }
        return count;
    }

    /// Convert the cursor's filtered ordinal back to MV's unit index.
    /// All/random/self scopes let Game_Action choose their targets.
    fn battleTargetUnitIndex(self: *GameLoop, selected: usize) i32 {
        return if (self.battleTargetChoice(selected)) |choice| choice.index else -1;
    }

    const BattleTargetChoice = struct { index: i32, friends: bool, name: []const u8 };

    fn battleTargetChoice(self: *GameLoop, selected: usize) ?BattleTargetChoice {
        const scope = self.battleScope();
        var ordinal: usize = 0;
        const dual = self.battleDualTarget();
        if (dual or scope == 1) {
            const b = if (self.battle) |*manager| manager else return null;
            for (b.troop.enemies.items) |enemy| {
                if (!enemy.isAlive()) continue;
                if (ordinal == selected) return .{ .index = @intCast(enemy.index), .friends = false, .name = enemy.name() };
                ordinal += 1;
            }
        }
        if (dual or scope == 7 or scope == 9) {
            for (self.mgr.game.party.members.items, 0..) |id, index| {
                const actor = self.mgr.game.actors.actor(id) orelse continue;
                if ((actor.hp <= 0) != (scope == 9)) continue;
                if (ordinal == selected) return .{ .index = @intCast(index), .friends = true, .name = actor.name };
                ordinal += 1;
            }
        }
        return null;
    }

    fn battleTargetName(self: *GameLoop) []const u8 {
        if (self.battleDualTarget()) return if (self.battleTargetChoice(self.battle_target_index)) |choice| choice.name else "NO TARGET";
        const index = self.battleTargetUnitIndex(self.battle_target_index);
        return switch (self.battleScope()) {
            1 => if (index >= 0) self.battle.?.troop.enemies.items[@intCast(index)].name() else "NO TARGET",
            7, 9 => if (index >= 0) self.mgr.game.actors.actor(self.mgr.game.party.members.items[@intCast(index)]).?.name else "NO TARGET",
            2 => "ALL ENEMIES",
            3...6 => "RANDOM ENEMIES",
            8 => "ALL FRIENDS",
            10 => "ALL TOAST FRIENDS",
            11 => if (self.battleCommandActor()) |actor| actor.name else "SELF",
            else => "NO TARGET",
        };
    }

    fn updateBattleResult(self: *GameLoop) void {
        if (self.input.isTriggered(.confirm) or self.input.isTriggered(.cancel)) {
            // BattleManager queues encounter text in Game_Message. The
            // battle UI replaces that window, so dismiss it at the same
            // boundary as the result; otherwise field input stays busy.
            self.mgr.game.message.clear();
            // back to field (or game over → title)
            const can_lose = if (self.battle) |*b| b.can_lose else false;
            if (self.battle_interpreter) |owner| {
                owner.completeSceneBattle(self.battle_result);
                self.battle_interpreter = null;
            }
            if (self.battle_result == .lose and !can_lose) {
                self.state = .title;
                self.title.activated = null;
            } else {
                if (self.battle_result == .lose) {
                    for (self.mgr.game.party.members.items) |actor_id| {
                        if (self.mgr.game.actors.actor(actor_id)) |actor| {
                            if (actor.hp <= 0) actor.gainHp(1);
                        }
                    }
                }
                self.state = .field;
            }
            if (self.battle) |*b| {
                b.deinit();
                self.battle = null;
            }
        }
    }

    fn setBattleResultText(self: *GameLoop, text: []const u8) void {
        if (self.battle_result_text.len > 0) self.alloc.free(self.battle_result_text);
        self.battle_result_text = self.alloc.dupe(u8, text) catch "";
    }

    fn finishBattle(self: *GameLoop, result: battle_mod.BattleResult) void {
        // v36: MV battle-end audio — win: playVictoryMe +
        // replayBgmAndBgs; escape (processAbort): replayBgmAndBgs;
        // defeat (processDefeat): playDefeatMe + (canLose ? replay :
        // stopBgm). Event battles preserve their authored canLose flag.
        switch (result) {
            .win => {
                self.playVictoryMe();
                self.replayBgmAndBgs();
            },
            .escape => self.replayBgmAndBgs(),
            .lose => {
                self.playDefeatMe();
                if (self.battle.?.can_lose) self.replayBgmAndBgs() else audio_mixer.stopBgmGlobal(0);
            },
        }
        self.battle_result = result;
        const b = if (self.battle) |*manager| manager else return;
        b.endBattle();
        var label: [128]u8 = undefined;
        const text = switch (result) {
            .win => std.fmt.bufPrint(&label, "VICTORY!  +{d} EXP  +{d} CLAMS", .{ b.rewards_exp, b.rewards_gold }) catch "VICTORY!",
            .escape => "ESCAPED...",
            .lose => "OMORI AND FRIENDS WERE DEFEATED...",
        };
        self.setBattleResultText(text);
        self.battle_phase = .result;
        self.state = .battle_result;
        log.milestone("battle UI: result = {s} (exp +{d}, gold +{d})", .{ @tagName(result), b.rewards_exp, b.rewards_gold });
    }

    // ------------------------------------------------------------------
    // drawing
    // ------------------------------------------------------------------

    fn draw(self: *GameLoop, dl: *draw_mod.DrawList) void {
        switch (self.state) {
            .title => self.drawTitle(dl),
            .load => self.drawLoad(dl),
            .options => self.drawOptions(dl),
            .credits => self.drawCredits(dl),
            .field, .toast => self.drawField(dl),
            .menu => self.drawMenu(dl),
            .battle, .battle_result => self.drawBattle(dl),
        }
    }

    fn drawTitle(self: *GameLoop, dl: *draw_mod.DrawList) void {
        self.title.draw(dl) catch |e| {
            log.err("title draw failed: {any}", .{e});
        };
    }

    fn drawLoad(self: *GameLoop, dl: *draw_mod.DrawList) void {
        dl.pushClear(0, 0, 0);
        self.win.drawWindow(dl, 24, 24, GAME_W - 48, GAME_H - 48);
        self.win.drawText(dl, 48, 44, "CONTINUE - CHOOSE A FILE", 255, 255, 255);
        const visible = @min(self.file_slot_count, 6);
        const first = if (self.load_index >= visible) self.load_index - visible + 1 else 0;
        for (first..first + visible) |i| {
            const y = 96 + @as(i32, @intCast(i - first)) * 44;
            const selected = i == self.load_index;
            const color: u8 = if (selected) 255 else if (self.slot_info[i].exists) 180 else 110;
            var buffer: [96]u8 = undefined;
            const label = std.fmt.bufPrint(&buffer, "FILE {d}    {s}", .{ i + 1, if (self.slot_info[i].exists) self.slot_info[i].playtimeText() else "EMPTY" }) catch "FILE";
            self.win.drawText(dl, 76, y, label, color, color, color);
            if (self.slot_info[i].location_len > 0) self.win.drawTextSized(dl, 76, y + 22, self.slot_info[i].locationText(), 16, color, color, color);
            if (selected) self.win.drawText(dl, 48, y, ">", 255, 255, 255);
        }
        if (self.load_message.len > 0) self.win.drawTextSized(dl, 48, 376, self.load_message, 19, 255, 255, 255);
        self.win.drawTextSized(dl, 48, 414, "A: LOAD    B: BACK", 19, 180, 180, 180);
    }

    fn drawOptions(self: *GameLoop, dl: *draw_mod.DrawList) void {
        dl.pushClear(0, 0, 0);
        self.win.drawWindow(dl, 24, 24, GAME_W - 48, GAME_H - 48);
        self.win.drawText(dl, 48, 44, "OPTIONS", 255, 255, 255);
        for (0..config_mod.row_count) |i| {
            const row: config_mod.Row = @enumFromInt(i);
            const selected = i == self.opt_index;
            const color: u8 = if (selected) 255 else 160;
            const y = 86 + @as(i32, @intCast(i)) * 29;
            if (selected) self.win.drawTextSized(dl, 48, y, ">", 22, 255, 255, 255);
            self.win.drawTextSized(dl, 76, y, config_mod.label(row), 22, color, color, color);
            if (row != .reset) {
                var buffer: [16]u8 = undefined;
                const text = if (config_mod.isVolume(row)) std.fmt.bufPrint(&buffer, "{d}%", .{self.port_options.value(row)}) catch "" else if (self.port_options.value(row) != 0) "ON" else "OFF";
                self.win.drawTextSized(dl, 492, y, text, 22, color, color, color);
            }
        }
        self.win.drawTextSized(dl, 48, 382, if (self.options_message.len > 0) self.options_message else config_mod.description(@enumFromInt(self.opt_index)), 17, 200, 200, 200);
        self.win.drawTextSized(dl, 48, 414, "LEFT/RIGHT: CHANGE   A: CHANGE   B: SAVE/BACK", 17, 180, 180, 180);
    }

    fn drawCredits(self: *GameLoop, dl: *draw_mod.DrawList) void {
        dl.pushClear(0, 0, 0);
        self.win.drawWindow(dl, 40, 40, GAME_W - 80, GAME_H - 80);
        self.win.drawText(dl, 64, 64, "OMORI - R36S PORT", 255, 255, 255);
        self.win.drawTextSized(dl, 64, 112, "R36S PORT BY José Pilas", 32, 255, 255, 255);
        self.win.drawText(dl, 64, 240, "GAME BY OMOCAT & TEAM", 180, 180, 180);
        self.win.drawText(dl, 64, 388, "B: BACK", 160, 160, 160);
    }

    fn drawField(self: *GameLoop, dl: *draw_mod.DrawList) void {
        const game = &self.mgr.game;
        const world_start = dl.ops.items.len;
        if (self.mgr.dm.data_map != null) {
            const raw: *const map_mod.RawMap = &self.mgr.dm.data_map.?;
            self.map_render.draw(
                dl,
                raw,
                game,
                game.player.direction,
                self.walk_remaining > 0,
                self.player_real_x,
                self.player_real_y,
            );
        } else {
            dl.pushClear(0, 0, 0);
        }

        const effects = @import("field_effects.zig");
        effects.drawWeather(dl, &game.screen, game.frame_count_global, game.map.display_x * @as(f64, @floatFromInt(game.map.tileWidth())), game.map.display_y * @as(f64, @floatFromInt(game.map.tileHeight())));
        // Picture slots are ordered back to front. A hash iteration shuffled
        // overlapping overlays after a picture was replaced or erased.
        if (game.screen.pictures.count() != 0) for (1..game_mod.GameScreen.max_pictures + 1) |slot| {
            const p = game.screen.picture(@intCast(slot)) orelse continue;
            if (p.name.len == 0) continue;
            const key = std.fmt.allocPrint(self.alloc, "img/pictures/{s}.png", .{p.name}) catch continue;
            defer self.alloc.free(key);
            const pic = self.loader.get(dl, key) orelse continue;
            effects.drawPicture(dl, p, pic);
        };

        // screen tint + brightness (fade)
        const tone = game.screen.tone;
        const ta = std.math.clamp(@max(@max(tone[0], tone[1]), tone[2]), -255, 255);
        if (ta != 0) {
            const a: u8 = @intCast(@abs(ta));
            dl.pushFill(if (ta > 0) @as(u8, @intCast(std.math.clamp(tone[0], 0, 255))) else 0, if (ta > 0) @as(u8, @intCast(std.math.clamp(tone[1], 0, 255))) else 0, if (ta > 0) @as(u8, @intCast(std.math.clamp(tone[2], 0, 255))) else 0, @divTrunc(a, 2));
        }
        // Flash sits above the tinted world, while scene fades cover both.
        self.applyScreenOptions(dl, world_start);
        if (game.screen.brightness < 255) {
            const ba: u8 = @intCast(255 - std.math.clamp(game.screen.brightness, 0, 255));
            if (ba > 0) dl.pushFill(0, 0, 0, ba);
        }

        // message + choice windows
        const msg = &game.message;
        if (msg.isBusy()) {
            self.win.drawMessage(dl, msg);
            if (msg.choicesVisible()) self.win.drawChoices(dl, msg);
        }

        // toast
        if (self.state == .toast and self.toast_text.len > 0) {
            const w = @min(GAME_W - 32, @max(180, self.font.measureText(self.toast_text, window_mod.FONT_SIZE).width + 48));
            const x = @divTrunc(GAME_W - w, 2);
            self.win.drawWindow(dl, x, 40, w, 48);
            self.win.drawText(dl, x + 24, 48, self.toast_text, 255, 255, 255);
        }
        if (self.tag_active) {
            dl.pushFill(0, 0, 0, 150);
            const height: i32 = 64 + @as(i32, @intCast(game.party.members.items.len)) * LINE_HEIGHT;
            self.win.drawWindow(dl, 96, 120, GAME_W - 192, height);
            self.win.drawTextSized(dl, 116, 130, "HOLD Y: CHOOSE WHO TO TAG", 20, 255, 255, 255);
            for (game.party.members.items, 0..) |id, index| {
                const actor = game.actors.actor(id) orelse continue;
                const y = 158 + @as(i32, @intCast(index)) * LINE_HEIGHT;
                self.win.drawText(dl, 144, y, actor.name, 255, 255, 255);
                if (index == self.tag_index) self.win.drawText(dl, 120, y, ">", 255, 255, 255);
            }
            self.win.drawTextSized(dl, 116, 160 + @as(i32, @intCast(game.party.members.items.len)) * LINE_HEIGHT, "LEFT/RIGHT  RELEASE Y TO TAG  B: BACK", 16, 200, 200, 200);
        }
    }

    fn applyScreenOptions(self: *GameLoop, dl: *draw_mod.DrawList, world_start: usize) void {
        const screen = &self.mgr.game.screen;
        if (self.port_options.shake) {
            const offset: i32 = @intFromFloat(@round(screen.shake));
            if (offset != 0) for (dl.ops.items[world_start..]) |*op| {
                switch (op.*) {
                    .sprite => |*sprite| sprite.dst.x += offset,
                    .text => |*text| text.x += offset,
                    else => {},
                }
            };
        }
        if (self.port_options.flashes and screen.flash_color[3] > 0) {
            const color = screen.flash_color;
            dl.pushFill(@intCast(std.math.clamp(color[0], 0, 255)), @intCast(std.math.clamp(color[1], 0, 255)), @intCast(std.math.clamp(color[2], 0, 255)), @intCast(std.math.clamp(color[3], 0, 255)));
        }
    }

    fn drawMenu(self: *GameLoop, dl: *draw_mod.DrawList) void {
        // field behind (dimmed)
        self.drawField(dl);
        dl.pushFill(0, 0, 0, 140);

        const game = &self.mgr.game;

        // party status window (top)
        self.win.drawWindow(dl, 224, 8, GAME_W - 232, 48 + @as(i32, @intCast(game.party.members.items.len)) * LINE_HEIGHT);
        for (game.party.members.items, 0..) |id, i| {
            const actor = game.actors.actor(id) orelse continue;
            const nm = if (actor.dbActor()) |a| a.name else "?";
            const line = std.fmt.allocPrint(self.alloc, "{s}  LV{d}  HP {d}/{d}  MP {d}", .{ nm, actor.level, actor.hp, actor.param(0), actor.mp }) catch continue;
            defer self.alloc.free(line);
            self.win.drawTextSized(dl, 240, 24 + @as(i32, @intCast(i)) * LINE_HEIGHT, line, 20, 255, 255, 255);
        }

        switch (self.menu_sub) {
            .root => {
                self.win.drawWindow(dl, 8, 8, 200, MENU_COMMANDS.len * LINE_HEIGHT + 24);
                for (MENU_COMMANDS, 0..) |c, i| {
                    const selected = i == self.menu_index;
                    const color: u8 = if (selected) 255 else 150;
                    self.win.drawText(dl, 40, 20 + @as(i32, @intCast(i)) * LINE_HEIGHT, c, color, color, color);
                    if (selected) self.win.drawText(dl, 20, 20 + @as(i32, @intCast(i)) * LINE_HEIGHT, ">", 255, 255, 255);
                }
            },
            .item, .skill => {
                const names = self.collectListNames();
                defer {
                    for (names) |n| self.alloc.free(n);
                    self.alloc.free(names);
                }
                const visible: usize = @min(names.len, 8);
                const first = if (self.menu_list_index >= visible and visible > 0) self.menu_list_index - visible + 1 else 0;
                const h = @as(i32, @intCast(@max(visible, 1))) * LINE_HEIGHT + 24;
                self.win.drawWindow(dl, 224, 208, GAME_W - 232, h);
                for (names[first..][0..visible], first..) |n, i| {
                    const selected = i == self.menu_list_index;
                    const color: u8 = if (selected) 255 else 150;
                    const line = if (self.menu_sub == .item)
                        std.fmt.allocPrint(self.alloc, "{s} x{d}", .{ n, self.mgr.game.party.numItems(self.menu_ids.items[i]) }) catch n
                    else
                        n;
                    defer if (line.ptr != n.ptr) self.alloc.free(line);
                    self.win.drawText(dl, 256, 220 + @as(i32, @intCast(i - first)) * LINE_HEIGHT, line, color, color, color);
                    if (selected) self.win.drawText(dl, 236, 220 + @as(i32, @intCast(i - first)) * LINE_HEIGHT, ">", 255, 255, 255);
                }
                if (names.len == 0) {
                    self.win.drawText(dl, 248, 220, "(EMPTY)", 150, 150, 150);
                }
            },
            .save => {
                const visible = @min(self.file_slot_count, 6);
                const first = if (self.menu_list_index >= visible) self.menu_list_index - visible + 1 else 0;
                self.win.drawWindow(dl, 224, 208, GAME_W - 232, @as(i32, @intCast(visible)) * LINE_HEIGHT + 24);
                for (first..first + visible) |i| {
                    const selected = i == self.menu_list_index;
                    const color: u8 = if (selected) 255 else 150;
                    const label = std.fmt.allocPrint(self.alloc, "FILE {d}  {s}", .{ i + 1, if (self.save_slots[i]) self.slot_info[i].playtimeText() else "EMPTY" }) catch continue;
                    defer self.alloc.free(label);
                    self.win.drawTextSized(dl, 256, 220 + @as(i32, @intCast(i - first)) * LINE_HEIGHT, label, 18, color, color, color);
                    if (selected) self.win.drawText(dl, 236, 220 + @as(i32, @intCast(i - first)) * LINE_HEIGHT, ">", 255, 255, 255);
                }
                if (self.slot_info[self.menu_list_index].location_len > 0) self.win.drawTextSized(dl, 240, 432, self.slot_info[self.menu_list_index].locationText(), 17, 180, 180, 180);
            },
        }
    }

    fn collectListNames(self: *GameLoop) [][]const u8 {
        var list = self.alloc.alloc([]const u8, self.menu_ids.items.len) catch return &.{};
        for (self.menu_ids.items, 0..) |id, i| {
            var name: []const u8 = "?";
            if (self.menu_sub == .item) {
                if (battle_mod.itemData(self.db, id)) |it| {
                    name = it.getString("name") orelse "?";
                }
            } else {
                if (battle_mod.skillData(self.db, id)) |sd| {
                    name = sd.getString("name") orelse "?";
                }
            }
            list[i] = self.alloc.dupe(u8, name) catch "?";
        }
        return list;
    }

    fn drawBattle(self: *GameLoop, dl: *draw_mod.DrawList) void {
        const b = if (self.battle) |*manager| manager else return;
        const game = &self.mgr.game;
        const status_h = 24 + @as(i32, @intCast(game.party.members.items.len)) * LINE_HEIGHT;
        const status_y = GAME_H - status_h;
        const command_y = status_y - (@as(i32, BATTLE_COMMANDS.len) * LINE_HEIGHT + 24);

        dl.pushClear(0, 0, 0);

        // enemies: battler sprites at troop positions
        const members = b.troop.enemies.items;
        for (members, 0..) |e, i| {
            if (e.isHidden() or !e.isAppeared()) continue;
            const key = std.fmt.allocPrint(self.alloc, "img/enemies/{s}.png", .{e.battlerName()}) catch continue;
            defer self.alloc.free(key);
            if (self.loader.get(dl, key)) |spr| {
                // dead enemies blink out; targeted enemy gets a marker
                const alive = e.isAlive();
                const fit = @min(1.0, @min(280.0 / @as(f64, @floatFromInt(spr.width)), 280.0 / @as(f64, @floatFromInt(spr.height))));
                const w: i32 = @intFromFloat(@as(f64, @floatFromInt(spr.width)) * fit);
                const h: i32 = @intFromFloat(@as(f64, @floatFromInt(spr.height)) * fit);
                // YEP_CoreEngine repositions MV troop coordinates from
                // its editor's 816x624 base to the configured UI box.
                const x = e.screen_x + @divTrunc(GAME_W - 816, 2) - @divTrunc(w, 2);
                const y = e.screen_y + @divFloor(GAME_H - 624, 2) - h;
                if (alive) {
                    dl.pushSpriteStable(spr.handle, spr.src, .{ .x = x, .y = y, .w = w, .h = h }, 255);
                    const target_choice = self.battleTargetChoice(self.battle_target_index);
                    if (self.battle_phase == .target and target_choice != null and !target_choice.?.friends and @as(i32, @intCast(i)) == target_choice.?.index) {
                        // target cursor
                        self.win.drawText(dl, x + @divTrunc(w, 2) - 6, y - 26, "v", 255, 80, 80);
                    }
                }
            } else {
                // name-only fallback
                const label = std.fmt.allocPrint(self.alloc, "[{s}] HP {d}/{d}", .{ e.name(), e.hp, e.mhp() }) catch continue;
                defer self.alloc.free(label);
                self.win.drawTextSized(dl, 240, 64 + @as(i32, @intCast(i)) * 32, label, 20, 220, 60, 60);
            }
        }

        // enemy HP bars
        for (members, 0..) |e, i| {
            if (!e.isAlive() or e.isHidden() or !e.isAppeared()) continue;
            const x = GAME_W - 200;
            const y = 24 + @as(i32, @intCast(i)) * 26;
            const frac = std.math.clamp(e.hpRate(), 0.0, 1.0);
            self.fillRectDL(dl, x, y, 180, 12, 255);
            self.fillRectDL(dl, x, y, @intFromFloat(180.0 * frac), 12, 180);
            const nm = std.fmt.allocPrint(self.alloc, "{s}", .{e.name()}) catch continue;
            defer self.alloc.free(nm);
            self.win.drawTextSized(dl, x - 200, y - 4, nm, 16, 200, 200, 200);
        }

        // party status window (bottom)
        self.win.drawWindow(dl, 0, status_y, GAME_W, status_h);
        const choosing = switch (self.battle_phase) {
            .command, .skill_list, .item_list, .target => self.battleCommandActor(),
            else => null,
        };
        for (game.party.members.items, 0..) |id, i| {
            const actor = game.actors.actor(id) orelse continue;
            const nm = if (actor.dbActor()) |a| a.name else "?";
            const line = std.fmt.allocPrint(self.alloc, "{s}   LV {d}   HP {d}/{d}   MP {d}/{d}", .{ nm, actor.level, actor.hp, actor.param(0), actor.mp, actor.param(1) }) catch continue;
            defer self.alloc.free(line);
            const y = status_y + 8 + @as(i32, @intCast(i)) * LINE_HEIGHT;
            const active = actor == choosing;
            const color: u8 = if (active or choosing == null) 255 else 175;
            if (active) self.win.drawText(dl, 14, y, ">", 255, 255, 255);
            self.win.drawText(dl, 40, y, line, color, color, color);
        }

        // command / message window
        switch (self.battle_phase) {
            .command => {
                self.win.drawWindow(dl, 0, command_y, 200, BATTLE_COMMANDS.len * LINE_HEIGHT + 24);
                for (BATTLE_COMMANDS, 0..) |c, i| {
                    const selected = i == self.battle_command_index;
                    const color: u8 = if (selected) 255 else 150;
                    self.win.drawText(dl, 40, command_y + 12 + @as(i32, @intCast(i)) * LINE_HEIGHT, c, color, color, color);
                    if (selected) self.win.drawText(dl, 20, command_y + 12 + @as(i32, @intCast(i)) * LINE_HEIGHT, ">", 255, 255, 255);
                }
                if (b.party_commands.items.len > 0) self.win.drawTextSized(dl, 220, status_y - 38, "B: PREVIOUS MEMBER", 20, 240, 240, 240);
            },
            .skill_list, .item_list => {
                const is_item = self.battle_phase == .item_list;
                const visible = @min(self.battle_skills.items.len, 4);
                const first = if (visible > 0 and self.battle_list_index >= visible) self.battle_list_index - visible + 1 else 0;
                const list_h = @as(i32, @intCast(@max(visible, 1))) * LINE_HEIGHT + 56;
                self.win.drawWindow(dl, 0, status_y - list_h, GAME_W, list_h);
                self.win.drawTextSized(dl, 24, status_y - list_h + 8, if (is_item) "ITEMS - B: BACK" else "SKILLS - B: BACK", 20, 255, 255, 255);
                if (visible == 0) self.win.drawText(dl, 24, status_y - list_h + 36, if (is_item) "NO USABLE ITEMS" else "NO AFFORDABLE SKILLS", 160, 160, 160);
                for (self.battle_skills.items[first..][0..visible], first..) |id, index| {
                    const data = (if (is_item) battle_mod.itemData(self.db, id) else battle_mod.skillData(self.db, id)) orelse continue;
                    const name = data.getString("name") orelse "?";
                    const line = if (is_item)
                        std.fmt.allocPrint(self.alloc, "{s} x{d}", .{ name, b.freeItemCount(id) }) catch continue
                    else
                        std.fmt.allocPrint(self.alloc, "{s}  MP {d}", .{ name, data.getInt("mpCost", 0) }) catch continue;
                    defer self.alloc.free(line);
                    const y = status_y - list_h + 36 + @as(i32, @intCast(index - first)) * LINE_HEIGHT;
                    self.win.drawText(dl, 40, y, line, 255, 255, 255);
                    if (index == self.battle_list_index) self.win.drawText(dl, 20, y, ">", 255, 255, 255);
                }
            },
            .target => {
                self.win.drawWindow(dl, 0, command_y, GAME_W, 84);
                const label = std.fmt.allocPrint(self.alloc, "TARGET: < {s} >", .{self.battleTargetName()}) catch return;
                defer self.alloc.free(label);
                self.win.drawText(dl, 24, command_y + 12, label, 255, 255, 255);
                self.win.drawTextSized(dl, 24, command_y + 48, "A: CONFIRM   B: BACK", 20, 200, 200, 200);
            },
            .resolving, .result => {
                self.win.drawWindow(dl, 0, command_y, GAME_W, 60);
                const text = if (self.battle_phase == .result) self.battle_result_text else "...";
                self.win.drawText(dl, 24, command_y + 12, text, 255, 255, 255);
            },
        }
    }

    fn fillRectDL(self: *GameLoop, dl: *draw_mod.DrawList, x: i32, y: i32, w: i32, h: i32, opacity: u8) void {
        const handle = dl.addSurface(&self.win.solid);
        dl.pushSpriteStable(handle, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .x = x, .y = y, .w = w, .h = h }, opacity);
    }
};

test "battle result: dismissal releases message state before returning to field" {
    const a = std.testing.allocator;
    var mgr: scenes.SceneManager = undefined;
    mgr.game.message = game_mod.GameMessage.init(a);
    defer mgr.game.message.texts.deinit(a);
    defer mgr.game.message.choices.deinit(a);
    defer mgr.game.message.choice_labels.deinit(a);
    var input = input_mod.Input{};
    var loop = GameLoop.init(a, &mgr, undefined, undefined, undefined, undefined, undefined, undefined, &input);
    for ([_]battle_mod.BattleResult{ .win, .escape, .lose }) |result| {
        mgr.game.message.add("Enemy appeared!");
        mgr.game.message.busy = true;
        mgr.game.message.visible = true;
        loop.state = .battle_result;
        loop.battle_result = result;
        input.current.confirm = false;
        loop.updateBattleResult();
        try std.testing.expect(mgr.game.message.isBusy());
        try std.testing.expectEqual(State.battle_result, loop.state);
        input.current.confirm = true;
        loop.updateBattleResult();
        try std.testing.expect(!mgr.game.message.isBusy());
        try std.testing.expect(!mgr.game.message.busy);
        try std.testing.expect(!mgr.game.message.visible);
        try std.testing.expectEqual(if (result == .lose) State.title else State.field, loop.state);
    }
}

test "menu access: Start tap during a glide opens once after landing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try schedulerFixture(arena.allocator(), "{\"width\":5,\"height\":5,\"events\":[null]}", "[null]");
    loop.state = .field;
    loop.mgr.game.player.x = 1;
    loop.mgr.game.player.y = 1;
    loop.player_real_x = 0.8125;
    loop.player_real_y = 1;
    loop.walk_remaining = 3;
    loop.input.applyControllerButton(sdl.CB_START, true);
    loop.updateFieldCore(true);
    loop.input.endFrame();
    try std.testing.expectEqual(State.field, loop.state);
    try std.testing.expect(loop.menu_calling);
    loop.input.applyControllerButton(sdl.CB_START, false);
    for (0..2) |_| {
        loop.updateFieldCore(true);
        loop.input.endFrame();
    }
    try std.testing.expectEqual(@as(i32, 0), loop.walk_remaining);
    loop.updateFieldCore(true);
    loop.input.endFrame();
    try std.testing.expectEqual(State.menu, loop.state);
    try std.testing.expect(!loop.menu_calling);
    try std.testing.expectEqual(@as(f64, 1), loop.player_real_x);
}

test "menu access: authored lock and message discard Start instead of delaying it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try schedulerFixture(arena.allocator(), "{\"width\":5,\"height\":5,\"events\":[null]}", "[null]");
    loop.state = .field;
    loop.mgr.game.system.menu_enabled = false;
    loop.input.applyJoyButtonFor(0, 13, true, true); // Actual GO-Super Start.
    loop.updateFieldCore(true);
    loop.input.endFrame();
    try std.testing.expectEqual(State.field, loop.state);
    try std.testing.expect(!loop.menu_calling);
    loop.mgr.game.system.menu_enabled = true;
    loop.updateFieldCore(true); // Still held: no stale trigger from the lock.
    loop.input.endFrame();
    try std.testing.expectEqual(State.field, loop.state);
    loop.input.clearAll();
    loop.menu_calling = true;
    loop.mgr.game.message.add("A real message is open");
    loop.mgr.game.message.busy = true;
    loop.updateFieldCore(true);
    loop.input.endFrame();
    try std.testing.expect(!loop.menu_calling);
    loop.mgr.game.message.clear();
    loop.updateFieldCore(true);
    loop.input.endFrame();
    try std.testing.expectEqual(State.field, loop.state);
    loop.input.applyJoyButtonFor(0, 13, true, true);
    loop.updateFieldCore(true);
    loop.input.endFrame();
    try std.testing.expectEqual(State.menu, loop.state);
    loop.updateMenu(); // Holding the opening Start does not close the menu.
    try std.testing.expectEqual(State.menu, loop.state);
}

test "menu navigation: held directions use the same repeat cadence as Load and Options" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try schedulerFixture(arena.allocator(), "{\"events\":[null]}", "[null]");
    loop.state = .menu;
    loop.input.current.down = true;
    for (0..31) |_| {
        loop.updateMenu();
        loop.input.endFrame();
    }
    try std.testing.expectEqual(@as(usize, 3), loop.menu_index);
}

test "player motion integration: parallel idle counter sees glide rather than held direction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loop = try schedulerFixture(a,
        \\{"width":5,"height":5,"events":[null,{"id":1,"pages":[{"trigger":4,"list":[{"code":111,"parameters":[12,"$gamePlayer.isMoving();"]},{"code":122,"indent":1,"parameters":[1,1,0,0,0]},{"code":411},{"code":122,"indent":1,"parameters":[1,1,1,0,1]},{"code":412},{"code":0}]}]}]}
    , "[null]");
    loop.mgr.game.variables.deinit();
    loop.mgr.game.variables = try @import("state.zig").Variables.init(a, 4);
    loop.mgr.game.variables.setValue(1, 99);
    loop.walk_remaining = 2;
    loop.updateFieldCore(false);
    try std.testing.expectEqual(@as(i64, 0), loop.mgr.game.variables.value(1));
    loop.walk_remaining = 0;
    loop.input.current.right = true; // Pushing a wall is still not moving.
    loop.updateFieldCore(false);
    try std.testing.expectEqual(@as(i64, 1), loop.mgr.game.variables.value(1));
}

// The fixture uses real parsed map/database commands, without SDL or I/O.
test "event page: nested actor and item prerequisites select their authored page" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loop = try schedulerFixture(a,
        \\{"width":4,"height":4,"events":[null,
        \\{"id":1,"pages":[{}, {"actorId":7,"itemId":9,"conditions":{"actorId":4,"actorValid":true,"itemId":3,"itemValid":true}}]},
        \\{"id":2,"pages":[{}, {"actorId":2,"actorValid":true,"itemId":5,"itemValid":true}]}]}
    , "[null]");
    const raw = &loop.mgr.dm.data_map.?;
    const game = &loop.mgr.game;
    const nested = raw.events.items[1].?.pages.items;
    const flat = raw.events.items[2].?.pages.items;
    try game.party.members.appendSlice(a, &.{ 7, 2 });
    game.party.gainItem(9, 1);
    try std.testing.expectEqual(&nested[0], game.map.currentPage(raw, 1, game).?);
    try std.testing.expectEqual(&flat[0], game.map.currentPage(raw, 2, game).?);
    try game.party.members.append(a, 4);
    try std.testing.expectEqual(&nested[0], game.map.currentPage(raw, 1, game).?);
    game.party.gainItem(3, 1);
    game.party.gainItem(5, 1);
    try std.testing.expectEqual(&nested[1], game.map.currentPage(raw, 1, game).?);
    try std.testing.expectEqual(&flat[1], game.map.currentPage(raw, 2, game).?);
}

test "event page: recruited room friends activate their blank NPC pages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = std.process.getEnvVarOwned(a, "OMORI_BATTLE_SMOKE_ROOT") catch return error.SkipZigTest;
    const loop = try schedulerFixture(a, "{\"width\":4,\"height\":4}", "[null]");
    var vfs = vfs_mod.Vfs.init(a, root, "/unused");
    defer vfs.deinit();
    try loop.mgr.dm.loadMapData(&vfs, 88);
    const raw = &loop.mgr.dm.data_map.?;
    const game = &loop.mgr.game;
    try game.map.setup(raw, 88);
    for ([_][2]i32{ .{ 2, 4 }, .{ 4, 2 }, .{ 5, 3 } }) |pair| {
        const before = game.map.currentPage(raw, pair[0], game).?;
        try std.testing.expect(before.image.?.getString("characterName").?.len > 0);
        try game.party.members.append(a, pair[1]);
        const after = game.map.currentPage(raw, pair[0], game).?;
        try std.testing.expectEqual(pair[1], after.condition.actor_id);
        try std.testing.expectEqualStrings("", after.image.?.getString("characterName").?);
    }
}

test "room flower: authored events take precedence and external decorations use localized text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = std.process.getEnvVarOwned(a, "OMORI_BATTLE_SMOKE_ROOT") catch return error.SkipZigTest;
    const loop = try schedulerFixture(a,
        \\{"width":29,"height":28,"events":[null,{"id":1,"x":11,"y":20,"pages":[{"trigger":0,"priorityType":1,"list":[{"code":230,"parameters":[2]},{"code":0}]}]}]}
    , "[null]");
    var vfs = vfs_mod.Vfs.init(a, root, "/unused");
    loop.itp.texts.vfs = &vfs;
    const tiled = try a.create(@import("tiled.zig").TiledMap);
    tiled.* = @import("tiled.zig").TiledMap.load(a, &vfs, 88) orelse return error.MissingRoom;
    const game = &loop.mgr.game;
    game.map.map_id = 88;
    game.map.tiled = tiled;
    game.player.x = 11;
    game.player.y = 19;
    game.player.direction = 2;
    loop.tryActionEvents();
    try std.testing.expect(loop.itp.isRunning());
    try std.testing.expectEqual(@as(i32, 1), loop.itp.event_id);
    try std.testing.expect(!game.message.isBusy());
    // Clearing the synthetic authored event restores the actual map situation.
    game.map.eraseEvent(1);
    for ([_][2]i32{ .{ 11, 20 }, .{ 20, 18 }, .{ 21, 16 } }) |position| {
        try std.testing.expect(tiled.isSolid(0, position[0], position[1]));
        game.player.x = position[0];
        game.player.y = position[1] - 1;
        loop.tryActionEvents();
        const description = (try loop.itp.texts.getMessageData("dw_flavor_text.message_92")).?;
        try std.testing.expectEqual(@as(usize, 1), game.message.texts.items.len);
        try std.testing.expectEqualStrings(description.text, game.message.texts.items[0]);
        game.message.clear();
    }
    game.player.x = 11;
    game.player.y = 19;
    game.player.direction = 6; // adjacent bare floor
    loop.tryActionEvents();
    try std.testing.expect(!game.message.isBusy());
}

fn schedulerFixture(a: std.mem.Allocator, map_json: []const u8, common_json: []const u8) !*GameLoop {
    const db = try a.create(database.Database);
    db.* = database.Database.init(a, undefined);
    const files = [_]struct { path: []const u8, data: []const u8 }{
        .{ .path = "data/System.json", .data = "{\"switches\":[null,\"1\",\"2\",\"3\",\"4\",\"5\",\"6\",\"7\",\"8\",\"9\"],\"variables\":[null,\"1\",\"2\",\"3\",\"4\"]}" },
        .{ .path = "data/CommonEvents.json", .data = common_json },
    };
    for (files) |file| {
        var parser = try json.Parser.init(a, file.data);
        const value = try parser.parse();
        try db.storage.append(a, .{ .path = file.path, .kind = .database, .value = value });
        try db.files.put(file.path, db.storage.items.len - 1);
    }
    const mgr = try a.create(scenes.SceneManager);
    mgr.* = scenes.SceneManager.init(a, db, undefined);
    try mgr.game.create();
    var parser = try json.Parser.init(a, map_json);
    mgr.dm.data_map = try map_mod.RawMap.fromJson(a, try parser.parse());
    mgr.dm.data_map_id = 87;
    try mgr.game.map.setup(&mgr.dm.data_map.?, 87);
    const texts = try a.create(text_mod.TextStore);
    texts.* = text_mod.TextStore.init(a, undefined, "en");
    const input = try a.create(input_mod.Input);
    input.* = .{};
    const loop = try a.create(GameLoop);
    loop.* = GameLoop.init(a, mgr, undefined, db, undefined, undefined, undefined, undefined, input);
    loop.itp = interpreter_mod.Interpreter.init(a, &mgr.game, db, texts);
    loop.map_render = map_render_mod.MapRenderer.init(a, undefined, db);
    loop.itp.setCurrentRawMap(&mgr.dm.data_map.?);
    return loop;
}

test "balloon cues: player and event cues overlap and waiting resumes at completion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try schedulerFixture(arena.allocator(),
        \\{"width":20,"height":20,"events":[null,{"id":1,"pages":[{"trigger":0,"list":[
        \\{"code":213,"parameters":[-1,2,false]},
        \\{"code":213,"parameters":[0,1,true]},
        \\{"code":121,"parameters":[1,1,0]},{"code":0}
        \\]}]}]}
    , "[null]");
    const game = &loop.mgr.game;
    const effects = @import("balloons.zig");
    loop.itp.field_routes = true;
    loop.itp.setup(loop.mgr.dm.data_map.?.events.items[1].?.pages.items[0].list, 1);
    loop.updateFieldCore(false);
    try std.testing.expectEqual(@as(usize, 2), game.map.balloons.count());
    try std.testing.expectEqual(@as(u8, 1), game.map.balloons.get(-1).?.row);
    for (0..effects.duration - 1) |_| loop.updateFieldCore(false);
    try std.testing.expectEqual(@as(i32, 7), game.map.balloons.get(1).?.column());
    try std.testing.expect(!game.switches.value(1));
    loop.updateFieldCore(false);
    try std.testing.expect(game.switches.value(1));
    try std.testing.expectEqual(@as(usize, 0), game.map.balloons.count());
    try game.map.balloons.put(game.map.alloc, 1, .{ .row = 0, .sheet = .standard });
    game.map.eraseEvent(1);
    try std.testing.expect(!game.map.balloons.contains(1));
    try game.map.balloons.put(game.map.alloc, -1, .{ .row = 0, .sheet = .standard });
    try game.map.setup(&loop.mgr.dm.data_map.?, 88);
    try std.testing.expectEqual(@as(usize, 0), game.map.balloons.count());
}

test "scripted camera: a second command waits for the first to finish and starts once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try schedulerFixture(arena.allocator(),
        \\{"width":40,"height":30,"events":[null,{"id":1,"pages":[{"trigger":0,"list":[
        \\{"code":204,"parameters":[6,1,4]},{"code":204,"parameters":[2,0.5,4]},
        \\{"code":121,"parameters":[1,1,0]},{"code":0}
        \\]}]}]}
    , "[null]");
    const game = &loop.mgr.game;
    loop.itp.setup(loop.mgr.dm.data_map.?.events.items[1].?.pages.items[0].list, 1);
    for (0..8) |_| loop.updateFieldCore(false);
    try std.testing.expectEqual(@as(f64, 0.5), game.map.display_x);
    try std.testing.expectEqual(@as(f64, 0), game.map.display_y);
    try std.testing.expect(!game.switches.value(1));
    for (0..16) |_| loop.updateFieldCore(false);
    try std.testing.expectEqual(@as(f64, 1), game.map.display_x);
    try std.testing.expectEqual(@as(f64, 0.5), game.map.display_y);
    try std.testing.expect(game.switches.value(1));
    try std.testing.expect(!game.map.isScrolling());
}

test "encounter: disabled steps and authored events do not advance the field countdown" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try schedulerFixture(arena.allocator(),
        \\{"width":20,"height":20,"encounterStep":1,"encounterList":[{"troopId":3,"weight":1,"regionSet":[9]}],
        \\"events":[null,{"id":1,"x":2,"y":2,"pages":[{"priorityType":0,"trigger":1,
        \\"list":[{"code":230,"parameters":[10]},{"code":0}]}]}]}
    , "[null]");
    const game = &loop.mgr.game;
    loop.state = .field;
    game.player.x = 1;
    game.player.y = 1;
    game.player.encounter_count = 1;
    game.system.encounter_enabled = false;
    loop.onPlayerArrived();
    try std.testing.expectEqual(@as(?f64, 1), game.player.encounter_count);
    game.system.encounter_enabled = true;
    game.player.encounter_count = 2;
    loop.onPlayerArrived();
    try std.testing.expectEqual(@as(?f64, 1), game.player.encounter_count);
    loop.onPlayerArrived();
    // Region 0 has no matching troop. The countdown still rerolls.
    try std.testing.expectEqual(@as(?f64, 1), game.player.encounter_count);
    try std.testing.expectEqual(State.field, loop.state);
    game.player.x = 2;
    game.player.y = 2;
    game.player.encounter_count = 2;
    loop.onPlayerArrived();
    try std.testing.expect(loop.itp.chainRunning());
    try std.testing.expectEqual(@as(?f64, 2), game.player.encounter_count);
}

test "animation integration: stationary step events tick once per update and repeated draws do not advance them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try schedulerFixture(arena.allocator(),
        \\{"width":10,"height":10,"events":[null,{"id":1,"pages":[{"stepAnime":true,"moveSpeed":3,"image":{"characterName":"","pattern":1},"trigger":0,"list":[{"code":0}]}]}]}
    , "[null]");
    loop.mgr.game.player.transparent = true;
    for (0..17) |_| loop.updateFieldCore(false);
    try std.testing.expectEqual(@as(i32, 1), loop.map_render.event_animations.get(1).?.clock.pattern());
    loop.updateFieldCore(false);
    try std.testing.expectEqual(@as(i32, 2), loop.map_render.event_animations.get(1).?.clock.pattern());
    const before = loop.map_render.event_animations.get(1).?.clock.half_count;
    var list = draw_mod.DrawList.init(std.testing.allocator);
    defer list.deinit();
    for (0..2) |_| {
        loop.map_render.draw(&list, &loop.mgr.dm.data_map.?, &loop.mgr.game, 2, false, 0, 0);
        list.clear();
    }
    try std.testing.expectEqual(before, loop.map_render.event_animations.get(1).?.clock.half_count);
    loop.mgr.game.map.map_id = 88;
    loop.updateFieldCore(false);
    try std.testing.expectEqual(@as(i32, 1), loop.map_render.event_animations.get(1).?.clock.pattern());
}

test "field scheduler: consecutive autoruns, independent parallels and common trigger semantics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try schedulerFixture(arena.allocator(),
        \\{"width":10,"height":10,"events":[null,
        \\{"id":1,"pages":[{"trigger":3,"list":[{"code":122,"parameters":[1,1,0,0,11]},{"code":123,"parameters":["A",0]},{"code":0}]},{"trigger":0,"conditions":{"selfSwitchValid":true,"selfSwitchCh":"A"},"list":[{"code":0}]}]},
        \\{"id":2,"pages":[{"trigger":3,"list":[{"code":121,"parameters":[5,5,0]},{"code":123,"parameters":["A",0]},{"code":0}]},{"trigger":0,"conditions":{"selfSwitchValid":true,"selfSwitchCh":"A"},"list":[{"code":0}]}]},
        \\{"id":3,"pages":[{"trigger":4,"list":[{"code":122,"parameters":[2,2,1,0,1]},{"code":230,"parameters":[2]},{"code":0}]},{"trigger":0,"conditions":{"switch1Valid":true,"switch1Id":8},"list":[{"code":0}]}]}]}
    ,
        \\[null,{"id":1,"trigger":2,"switchId":6,"list":[{"code":122,"parameters":[3,3,1,0,1]},{"code":230,"parameters":[3]},{"code":0}]},{"id":2,"trigger":1,"switchId":7,"list":[{"code":122,"parameters":[4,4,0,0,44]},{"code":121,"parameters":[7,7,1]},{"code":0}]}]
    );
    const game = &loop.mgr.game;
    loop.updateEventInterpreters(.{});
    try std.testing.expectEqual(@as(i64, 11), game.variables.value(1));
    try std.testing.expect(!game.switches.value(5));
    try std.testing.expectEqual(@as(i64, 1), game.variables.value(2));
    loop.updateEventInterpreters(.{});
    try std.testing.expect(game.switches.value(5));
    try std.testing.expectEqual(@as(i64, 1), game.variables.value(2)); // wait belongs to the parallel only
    game.switches.setValue(6, true);
    game.switches.setValue(7, true);
    loop.updateEventInterpreters(.{});
    try std.testing.expectEqual(@as(i64, 44), game.variables.value(4));
    try std.testing.expect(!game.switches.value(7));
    try std.testing.expectEqual(@as(i64, 1), game.variables.value(3));
    try std.testing.expectEqual(@as(usize, 2), loop.parallel_events.items.len);
    game.switches.setValue(8, true); // map event's active page changes
    game.switches.setValue(6, false); // common-event switch disables its waiting chain
    loop.updateEventInterpreters(.{});
    try std.testing.expectEqual(@as(usize, 0), loop.parallel_events.items.len);
    loop.clearParallelEvents();
}

test "field scheduler: held buttons reach autorun children and independent parallel children" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try schedulerFixture(arena.allocator(),
        \\{"events":[null,{"id":1,"pages":[{"trigger":3,"list":[{"code":117,"parameters":[1]},{"code":122,"parameters":[1,1,0,0,11]},{"code":123,"parameters":["A",0]},{"code":0}]},{"trigger":0,"conditions":{"selfSwitchValid":true,"selfSwitchCh":"A"},"list":[{"code":0}]}]},{"id":2,"pages":[{"trigger":4,"list":[{"code":117,"parameters":[1]},{"code":122,"parameters":[2,2,0,0,22]},{"code":230,"parameters":[10]},{"code":0}]}]}]}
    ,
        \\[null,{"id":1,"trigger":0,"list":[{"code":112,"indent":0},{"code":111,"indent":1,"parameters":[11,"right"]},{"code":113,"indent":2},{"code":412,"indent":1},{"code":230,"indent":1,"parameters":[5]},{"code":413,"indent":0},{"code":0}]}]
    );
    for (0..15) |_| loop.updateEventInterpreters(.{});
    try std.testing.expectEqual(@as(i64, 0), loop.mgr.game.variables.value(1));
    try std.testing.expectEqual(@as(i64, 0), loop.mgr.game.variables.value(2));
    for (0..8) |_| loop.updateEventInterpreters(.{ .held = .{ .right = true } });
    try std.testing.expectEqual(@as(i64, 11), loop.mgr.game.variables.value(1));
    try std.testing.expectEqual(@as(i64, 22), loop.mgr.game.variables.value(2));
    try std.testing.expect(loop.mgr.game.self_switches.value(87, 1, "A"));
    loop.clearParallelEvents();
}

test "field scheduler: one shared message tick despite multiple parallel interpreters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try schedulerFixture(arena.allocator(),
        \\{"events":[null,{"id":1,"pages":[{"trigger":4,"list":[{"code":230,"parameters":[10]},{"code":0}]}]},{"id":2,"pages":[{"trigger":4,"list":[{"code":230,"parameters":[10]},{"code":0}]}]}]}
    , "[null]");
    loop.updateEventInterpreters(.{});
    for (0..9) |_| loop.mgr.game.message.add("line");
    loop.updateEventInterpreters(.{ .ok = true });
    try std.testing.expectEqual(@as(usize, 1), loop.mgr.game.message.page_index);
    try std.testing.expectEqual(@as(u64, 1), loop.mgr.game.message.pause_frames);
    try std.testing.expect(loop.mgr.game.message.isBusy());
    loop.clearParallelEvents();
}

test "field scheduler: dismissing the final message does not reopen an action event" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try schedulerFixture(arena.allocator(),
        \\{"width":10,"height":10,"events":[null,{"id":1,"x":0,"y":0,"pages":[{"trigger":0,"list":[{"code":122,"parameters":[1,1,1,0,1]},{"code":0}]}]}]}
    , "[null]");
    const game = &loop.mgr.game;
    loop.state = .field;
    loop.itp.setup(loop.mgr.dm.data_map.?.events.items[1].?.pages.items[0].list, 1);
    game.message.add("Last line");
    loop.input.applyControllerButton(0, true); // SDL A / confirm
    loop.updateFieldCore(true);
    try std.testing.expectEqual(@as(i64, 1), game.variables.value(1));
    try std.testing.expect(!game.message.isBusy());
    try std.testing.expect(!loop.itp.chainRunning());
}

test "field scheduler: a common-event child's choice result reaches its own branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try schedulerFixture(arena.allocator(),
        \\{"events":[null,{"id":1,"pages":[{"trigger":3,"list":[{"code":117,"parameters":[1]},{"code":123,"parameters":["A",0]},{"code":0}]},{"trigger":0,"conditions":{"selfSwitchValid":true,"selfSwitchCh":"A"},"list":[{"code":0}]}]}]}
    ,
        \\[null,{"id":1,"trigger":0,"list":[{"code":102,"indent":0,"parameters":[["one","two"],-1,0,2,0]},{"code":402,"indent":0,"parameters":[0,"one"]},{"code":122,"indent":1,"parameters":[1,1,0,0,11]},{"code":402,"indent":0,"parameters":[1,"two"]},{"code":122,"indent":1,"parameters":[1,1,0,0,22]},{"code":404,"indent":0},{"code":0}]}]
    );
    loop.updateEventInterpreters(.{});
    loop.updateEventInterpreters(.{}); // child starts the choice window
    try std.testing.expect(loop.mgr.game.message.choices.items.len == 2);
    loop.mgr.game.message.choice_index = 1;
    loop.updateEventInterpreters(.{ .ok = true });
    try std.testing.expectEqual(@as(i64, 22), loop.mgr.game.variables.value(1));
    try std.testing.expect(loop.mgr.game.self_switches.value(87, 1, "A"));
}

test "event battle: a common-event child waits for interactive UI and receives each result branch" {
    for ([_]battle_mod.BattleResult{ .win, .escape, .lose }) |result| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const loop = try schedulerFixture(a,
            \\{"events":[null,{"id":1,"pages":[{"trigger":3,"list":[{"code":117,"parameters":[1]},{"code":123,"parameters":["A",0]},{"code":0}]},{"trigger":0,"conditions":{"selfSwitchValid":true,"selfSwitchCh":"A"},"list":[{"code":0}]}]}]}
        ,
            \\[null,{"id":1,"trigger":0,"list":[{"code":301,"indent":0,"parameters":[0,1,false,true]},{"code":601,"indent":0},{"code":122,"indent":1,"parameters":[1,1,0,0,11]},{"code":602,"indent":0},{"code":122,"indent":1,"parameters":[1,1,0,0,22]},{"code":603,"indent":0},{"code":122,"indent":1,"parameters":[1,1,0,0,33]},{"code":604,"indent":0},{"code":0}]}]
        );
        loop.itp.scene_battles = true;
        var parser = try json.Parser.init(a, "[null,{\"id\":1,\"name\":\"event battle\",\"members\":[],\"pages\":[]}]");
        try loop.db.storage.append(a, .{ .path = "data/Troops.json", .kind = .database, .value = try parser.parse() });
        try loop.db.files.put("data/Troops.json", loop.db.storage.items.len - 1);
        loop.updateEventInterpreters(.{});
        loop.updateEventInterpreters(.{});
        const owner = loop.itp.pendingSceneBattle().?;
        try std.testing.expect(owner != &loop.itp);
        try std.testing.expectEqual(@as(i64, 0), loop.mgr.game.variables.value(1));
        try std.testing.expect(loop.startRequestedBattle());
        try std.testing.expectEqual(State.battle, loop.state);
        try std.testing.expect(!loop.battle.?.can_escape);
        try std.testing.expect(loop.battle.?.can_lose);
        try std.testing.expect(loop.itp.pendingSceneBattle() == null);
        loop.updateEventInterpreters(.{});
        try std.testing.expectEqual(@as(i64, 0), loop.mgr.game.variables.value(1));
        // A non-escapable authored battle cannot use the UI escape command.
        loop.battle_command_index = 3;
        loop.input.current.confirm = true;
        loop.updateBattle();
        try std.testing.expectEqual(State.battle, loop.state);
        try std.testing.expect(loop.battle.?.result == null);
        loop.battle.?.result = result;
        loop.finishBattle(result);
        try std.testing.expect(owner.scene_battle != null);
        loop.updateBattleResult();
        try std.testing.expectEqual(State.field, loop.state);
        try std.testing.expect(owner.scene_battle == null);
        loop.updateEventInterpreters(.{});
        const expected: i64 = switch (result) {
            .win => 11,
            .escape => 22,
            .lose => 33,
        };
        try std.testing.expectEqual(expected, loop.mgr.game.variables.value(1));
        try std.testing.expect(loop.mgr.game.self_switches.value(87, 1, "A"));
    }
}

// In-memory battle UI fixture: no shared temp directories or game assets.
fn battleUiFixture(a: std.mem.Allocator) !*GameLoop {
    const loop = try schedulerFixture(a, "{\"events\":[null]}", "[null]");
    const files = [_]struct { path: []const u8, data: []const u8 }{
        .{ .path = "data/Actors.json", .data = 
        \\[null,{"id":1,"name":"LEADER","classId":1,"initialLevel":1,"maxLevel":99,"equips":[]},{"id":2,"name":"FRIEND","classId":1,"initialLevel":1,"maxLevel":99,"equips":[]}]
        },
        .{ .path = "data/Classes.json", .data = 
        \\[null,{"id":1,"params":[[100,100],[30,30],[10,10],[0,0],[10,10],[0,0],[20,20],[10,10]],"learnings":[{"level":1,"skillId":2},{"level":1,"skillId":3},{"level":1,"skillId":4},{"level":1,"skillId":5}]}]
        },
        .{ .path = "data/Skills.json", .data = 
        \\[null,
        \\{"id":1,"name":"ATTACK","scope":1,"successRate":100,"damage":{"type":1,"formula":"4","variance":0}},
        \\{"id":2,"name":"HEAL","scope":7,"mpCost":5,"successRate":100,"damage":{"type":3,"formula":"15","variance":0}},
        \\{"id":3,"name":"FIRE","scope":1,"mpCost":7,"successRate":100,"damage":{"type":1,"formula":"13","variance":0}},
        \\{"id":4,"name":"TOO EXPENSIVE","scope":1,"mpCost":99},
        \\{"id":5,"name":"FIELD ONLY","scope":7,"occasion":2},
        \\{"id":6,"name":"UNLEARNED","scope":1,"mpCost":0},
        \\{"id":7,"name":"ATTACK AGAIN CHECK","stypeId":1,"scope":1,"mpCost":0,"note":"<HideInMenu>"},
        \\{"id":8,"name":"GUARD","stypeId":0,"scope":11,"mpCost":0}]
        },
        .{ .path = "data/Items.json", .data = 
        \\[null,
        \\{"id":1,"name":"SNACK","itypeId":1,"scope":7,"occasion":0,"consumable":true,"repeats":2,"successRate":100,"effects":[{"code":11,"value1":0,"value2":25}]},
        \\{"id":2,"name":"BOMB","itypeId":1,"scope":2,"occasion":1,"consumable":true,"repeats":2,"successRate":100,"damage":{"type":1,"formula":"4","variance":0}},
        \\{"id":3,"name":"KEY","itypeId":2,"scope":7,"occasion":0},
        \\{"id":4,"name":"FLUTE","itypeId":1,"scope":11,"occasion":1,"consumable":false,"successRate":100,"effects":[{"code":11,"value1":0,"value2":3}]},
        \\{"id":5,"name":"LIFE JAM","itypeId":1,"scope":9,"occasion":1,"consumable":true,"successRate":100,"effects":[{"code":11,"value1":0.5,"value2":0}]}]
        },
        .{ .path = "data/Enemies.json", .data = 
        \\[null,{"id":1,"name":"FOE","params":[1000,0,0,0,0,0,0,0],"actions":[],"traits":[]}]
        },
        .{ .path = "data/Troops.json", .data = 
        \\[null,{"id":1,"members":[{"enemyId":1,"hidden":false},{"enemyId":1,"hidden":false}],"pages":[]}]
        },
    };
    for (files) |file| {
        var parser = try json.Parser.init(a, file.data);
        const value = try parser.parse();
        try loop.db.storage.append(a, .{ .path = file.path, .kind = .database, .value = value });
        try loop.db.files.put(file.path, loop.db.storage.items.len - 1);
    }
    const game = &loop.mgr.game;
    try game.party.members.appendSlice(a, &.{ 1, 2 });
    game.actors.actor(1).?.hp = 10;
    game.actors.actor(2).?.hp = 20;
    loop.battle = battle_mod.Manager.init(a, loop.db, game, &game.troop, 7);
    loop.battle.?.setup(1, true, false);
    loop.state = .battle;
    return loop;
}

fn battleUiPress(loop: *GameLoop, comptime button: input_mod.LogicalButton) void {
    loop.input.current = .{};
    loop.input.previous = .{};
    @field(loop.input.current, @tagName(button)) = true;
    loop.updateBattle();
    loop.input.endFrame();
}

fn battleUiConfirmAttack(loop: *GameLoop) !void {
    try std.testing.expect(loop.battle_phase == .command);
    try std.testing.expectEqual(@as(usize, 0), loop.battle_command_index);
    battleUiPress(loop, .confirm);
    try std.testing.expect(loop.battle_phase == .target);
    battleUiPress(loop, .confirm);
}

test "battle UI: empty items and target cancellation do not heal or consume a turn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try battleUiFixture(arena.allocator());
    const leader = loop.mgr.game.actors.actor(1).?;
    loop.battle_command_index = 2;
    battleUiPress(loop, .confirm);
    try std.testing.expect(loop.battle_phase == .item_list);
    try std.testing.expectEqual(@as(usize, 0), loop.battle_skills.items.len);
    battleUiPress(loop, .confirm);
    try std.testing.expectEqual(@as(i32, 10), leader.hp);
    try std.testing.expectEqual(@as(i32, 0), loop.battle.?.troop.turn_count);
    battleUiPress(loop, .cancel);
    try std.testing.expect(loop.battle_phase == .command);

    loop.mgr.game.party.gainItem(1, 2);
    loop.mgr.game.party.gainItem(3, 1); // key items are not battle commands
    battleUiPress(loop, .confirm);
    try std.testing.expectEqualSlices(i32, &.{1}, loop.battle_skills.items);
    battleUiPress(loop, .confirm);
    try std.testing.expect(loop.battle_phase == .target);
    battleUiPress(loop, .right);
    try std.testing.expectEqualStrings("FRIEND", loop.battleTargetName());
    battleUiPress(loop, .cancel);
    try std.testing.expect(loop.battle_phase == .item_list);
    try std.testing.expectEqual(@as(i32, 2), loop.mgr.game.party.numItems(1));
    try std.testing.expectEqual(@as(i32, 10), leader.hp);
    try std.testing.expectEqual(@as(usize, 0), loop.battle.?.party_commands.items.len);
    try std.testing.expectEqual(@as(i32, 0), loop.battle.?.troop.turn_count);
}

test "battle UI: hidden chain checks and basic command skills stay out of SKILL" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try battleUiFixture(arena.allocator());
    const actor = loop.mgr.game.actors.actor(1).?;
    actor.learnSkill(7);
    actor.learnSkill(8);
    loop.openBattleList(false);
    try std.testing.expectEqualSlices(i32, &.{ 2, 3 }, loop.battle_skills.items);
}

test "battle UI: chosen item applies to chosen ally and consumes once across repeats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try battleUiFixture(arena.allocator());
    const game = &loop.mgr.game;
    game.party.gainItem(1, 2);
    loop.battle_command_index = 2;
    battleUiPress(loop, .confirm); // inventory
    battleUiPress(loop, .confirm); // SNACK
    battleUiPress(loop, .right); // FRIEND
    battleUiPress(loop, .confirm); // commit; no effect before execution
    try std.testing.expectEqual(@as(i32, 2), game.party.numItems(1));
    try std.testing.expectEqual(@as(i32, 20), game.actors.actor(2).?.hp);
    try battleUiConfirmAttack(loop);
    loop.battle.?.preemptive = true;
    loop.input.current = .{};
    loop.updateBattle();
    try std.testing.expect(loop.battle_phase == .command);
    try std.testing.expectEqual(@as(i32, 1), game.party.numItems(1));
    try std.testing.expectEqual(@as(i32, 70), game.actors.actor(2).?.hp);
    try std.testing.expectEqual(@as(i32, 10), game.actors.actor(1).?.hp);
    try std.testing.expectEqual(@as(i32, 30), game.actors.actor(1).?.mp);
    try std.testing.expectEqual(@as(usize, 0), loop.battle.?.party_commands.items.len);
}

test "battle UI: learned affordable skill selection spends cost once and preserves other attacks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try battleUiFixture(arena.allocator());
    const game = &loop.mgr.game;
    loop.battle_command_index = 1;
    battleUiPress(loop, .confirm);
    try std.testing.expectEqualSlices(i32, &.{ 2, 3 }, loop.battle_skills.items);
    battleUiPress(loop, .down); // FIRE instead of first HEAL
    battleUiPress(loop, .confirm);
    battleUiPress(loop, .right); // second enemy
    battleUiPress(loop, .confirm);
    try std.testing.expectEqual(@as(i32, 3), loop.battle.?.party_commands.items[0].skill_id);
    try battleUiConfirmAttack(loop);
    loop.battle.?.preemptive = true;
    loop.input.current = .{};
    loop.updateBattle();
    try std.testing.expectEqual(@as(i32, 23), game.actors.actor(1).?.mp);
    try std.testing.expectEqual(@as(i32, 30), game.actors.actor(2).?.mp);
    const first_hp = game.troop.enemies.items[0].hp;
    const second_hp = game.troop.enemies.items[1].hp;
    try std.testing.expectEqual(@as(i32, 1983), first_hp + second_hp); // FIRE 13 + friend's ATTACK 4
    try std.testing.expect(second_hp <= 987);
    game.actors.actor(1).?.mp = 4;
    loop.battle_command_index = 1;
    battleUiPress(loop, .confirm);
    try std.testing.expectEqual(@as(usize, 0), loop.battle_skills.items.len);
}

test "battle UI: all-target items consume once and dead allies are valid revival targets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try battleUiFixture(arena.allocator());
    const game = &loop.mgr.game;
    game.party.gainItem(2, 1);
    loop.battle_command_index = 2;
    battleUiPress(loop, .confirm);
    battleUiPress(loop, .confirm);
    try std.testing.expectEqual(@as(i32, -1), loop.battleTargetUnitIndex(0));
    battleUiPress(loop, .confirm);
    try battleUiConfirmAttack(loop);
    loop.battle.?.preemptive = true;
    loop.input.current = .{};
    loop.updateBattle();
    try std.testing.expectEqual(@as(i32, 0), game.party.numItems(2));
    try std.testing.expectEqual(@as(i32, 1980), game.troop.enemies.items[0].hp + game.troop.enemies.items[1].hp); // 2 targets x 2 repeats x 4 + friend's attack 4

    game.actors.actor(1).?.hp = 0;
    game.party.gainItem(5, 1);
    loop.battle_command_index = 2;
    battleUiPress(loop, .confirm);
    try std.testing.expectEqualSlices(i32, &.{5}, loop.battle_skills.items);
    battleUiPress(loop, .confirm);
    try std.testing.expectEqualStrings("LEADER", loop.battleTargetName());
    try std.testing.expectEqual(@as(i32, 0), loop.battleTargetUnitIndex(0));
    try std.testing.expectEqual(@as(usize, 2), loop.battle_action.subject_index); // surviving friend acts
    battleUiPress(loop, .confirm);
    loop.battle.?.preemptive = true;
    loop.input.current = .{};
    loop.updateBattle();
    try std.testing.expectEqual(@as(i32, 50), game.actors.actor(1).?.hp);
    try std.testing.expectEqual(@as(i32, 0), game.party.numItems(5));
}

test "battle UI: nonconsumable recovery caps HP at the actor maximum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try battleUiFixture(arena.allocator());
    const game = &loop.mgr.game;
    game.actors.actor(1).?.hp = 99;
    game.party.gainItem(4, 1);
    loop.battle_command_index = 2;
    battleUiPress(loop, .confirm);
    battleUiPress(loop, .confirm);
    battleUiPress(loop, .confirm);
    try battleUiConfirmAttack(loop);
    loop.battle.?.preemptive = true;
    loop.input.current = .{};
    loop.updateBattle();
    try std.testing.expectEqual(@as(i32, 100), game.actors.actor(1).?.hp);
    try std.testing.expectEqual(@as(i32, 1), game.party.numItems(4));
}

test "battle UI: execution rechecks lost inventory and drained skill cost" {
    for ([_]bool{ true, false }) |is_item| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const loop = try battleUiFixture(arena.allocator());
        const game = &loop.mgr.game;
        if (is_item) game.party.gainItem(1, 1);
        loop.battle_command_index = if (is_item) 2 else 1;
        battleUiPress(loop, .confirm);
        if (!is_item) battleUiPress(loop, .down); // FIRE
        battleUiPress(loop, .confirm);
        battleUiPress(loop, .confirm);
        if (is_item) game.party.gainItem(1, -1) else game.actors.actor(1).?.mp = 0;
        try battleUiConfirmAttack(loop);
        loop.battle.?.preemptive = true;
        loop.input.current = .{};
        loop.updateBattle();
        try std.testing.expectEqual(@as(i32, 10), game.actors.actor(1).?.hp);
        try std.testing.expectEqual(@as(i32, 20), game.actors.actor(2).?.hp);
        try std.testing.expectEqual(@as(i32, 0), game.party.numItems(1));
        try std.testing.expectEqual(@as(i32, 1996), game.troop.enemies.items[0].hp + game.troop.enemies.items[1].hp); // only friend's normal attack
        if (!is_item) try std.testing.expectEqual(@as(i32, 0), game.actors.actor(1).?.mp);
    }
}

test "battle UI: OMORI Enemy or Actor Select can choose either side" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try battleUiFixture(arena.allocator());
    var parser = try json.Parser.init(arena.allocator(),
        \\{"id":2,"name":"DUAL HEAL","note":"<Enemy or Actor Select>","scope":7,"mpCost":5,"successRate":100,"damage":{"type":3,"formula":"15","variance":0}}
    );
    loop.db.get("data/Skills.json").?.value.array.items[2] = try parser.parse();
    loop.battle.?.troop.enemies.items[0].hp = 100;
    loop.battle_command_index = 1;
    battleUiPress(loop, .confirm);
    battleUiPress(loop, .confirm);
    try std.testing.expectEqual(@as(usize, 4), loop.battleTargetCount());
    try std.testing.expect(!loop.battleTargetChoice(0).?.friends);
    try std.testing.expect(loop.battleTargetChoice(2).?.friends);
    try std.testing.expectEqualStrings("LEADER", loop.battleTargetChoice(2).?.name);
    battleUiPress(loop, .confirm); // enemy target for a friend-scope skill
    try std.testing.expectEqual(@as(?bool, false), loop.battle.?.party_commands.items[0].target_friends);
    try battleUiConfirmAttack(loop);
    loop.battle.?.preemptive = true;
    loop.input.current = .{};
    loop.updateBattle();
    try std.testing.expectEqual(@as(i32, 1111), loop.battle.?.troop.enemies.items[0].hp + loop.battle.?.troop.enemies.items[1].hp); // heal 15, friend attacks 4
    try std.testing.expectEqual(@as(i32, 25), loop.mgr.game.actors.actor(1).?.mp);
}

test "battle UI: revising party commands releases reserved snacks and keeps each actor's target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try battleUiFixture(arena.allocator());
    const game = &loop.mgr.game;
    game.party.gainItem(1, 1);
    game.party.gainItem(4, 1);
    const b = &loop.battle.?;
    loop.battle_command_index = 2;
    battleUiPress(loop, .confirm); // ITEM
    battleUiPress(loop, .confirm); // last SNACK
    battleUiPress(loop, .confirm); // leader picked self
    try std.testing.expectEqualStrings("FRIEND", loop.battleCommandActor().?.name);
    try std.testing.expectEqual(@as(i32, 1), game.party.numItems(1));
    loop.battle_command_index = 2;
    battleUiPress(loop, .confirm);
    try std.testing.expectEqualSlices(i32, &.{4}, loop.battle_skills.items);
    battleUiPress(loop, .cancel); // leave friend's inventory
    battleUiPress(loop, .cancel); // edit leader's prior choice
    try std.testing.expectEqualStrings("LEADER", loop.battleCommandActor().?.name);
    try std.testing.expectEqual(@as(i32, 1), b.freeItemCount(1));
    try std.testing.expectEqual(@as(i32, 0), b.troop.turn_count);
    loop.battle_command_index = 1;
    battleUiPress(loop, .confirm);
    battleUiPress(loop, .down);
    battleUiPress(loop, .confirm); // FIRE
    battleUiPress(loop, .right);
    battleUiPress(loop, .confirm); // enemy 2
    loop.battle_command_index = 2;
    battleUiPress(loop, .confirm);
    battleUiPress(loop, .confirm);
    battleUiPress(loop, .right);
    battleUiPress(loop, .confirm); // SNACK for friend
    try std.testing.expect(loop.battle_phase == .resolving);
    b.preemptive = true;
    loop.updateBattle();
    try std.testing.expectEqual(@as(i32, 1000), b.troop.enemies.items[0].hp);
    try std.testing.expectEqual(@as(i32, 987), b.troop.enemies.items[1].hp);
    try std.testing.expectEqual(@as(i32, 23), game.actors.actor(1).?.mp);
    try std.testing.expectEqual(@as(i32, 10), game.actors.actor(1).?.hp);
    try std.testing.expectEqual(@as(i32, 70), game.actors.actor(2).?.hp);
    try std.testing.expectEqual(@as(i32, 0), game.party.numItems(1));
    try std.testing.expectEqualStrings("LEADER", loop.battleCommandActor().?.name);
}

test "battle UI: failed escape clears committed commands and costs one enemy turn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try battleUiFixture(arena.allocator());
    const b = &loop.battle.?;
    try battleUiConfirmAttack(loop);
    b.escape_ratio = 0;
    loop.battle_command_index = 3;
    battleUiPress(loop, .confirm);
    try std.testing.expect(loop.battle_phase == .resolving);
    loop.updateBattle();
    try std.testing.expectEqual(@as(i32, 1), b.troop.turn_count);
    try std.testing.expectEqual(@as(i64, 0), b.commands_executed); // fixture enemies have no actions
    try std.testing.expectEqual(@as(i32, 1000), b.troop.enemies.items[0].hp);
    try std.testing.expectEqualStrings("LEADER", loop.battleCommandActor().?.name);
}

fn titleInput(input: *input_mod.Input) title_scene_mod.Input {
    return .{
        .up = input.isTriggered(.up),
        .down = input.isTriggered(.down),
        .up_rep = input.isRepeated(.up),
        .down_rep = input.isRepeated(.down),
        .ok = input.isTriggered(.confirm),
        .cancel = input.isTriggered(.cancel),
    };
}

fn saveUiFixture(a: std.mem.Allocator, root: []const u8) !*GameLoop {
    const loop = try schedulerFixture(a, "{\"width\":40,\"height\":30,\"events\":[null]}", "[null]");
    const vfs = try a.create(vfs_mod.Vfs);
    vfs.* = vfs_mod.Vfs.init(a, root, try std.fs.path.join(a, &.{ root, "saves" }));
    loop.vfs = vfs;
    loop.db.vfs = vfs;
    var parser = try json.Parser.init(a, "{\"startMapId\":999,\"gameTitle\":\"TEST\"}");
    loop.db.storage.items[loop.db.files.get("data/System.json").?].value = try parser.parse();
    loop.mgr.game.variables.deinit();
    loop.mgr.game.variables = try @import("state.zig").Variables.init(a, 64);
    return loop;
}

fn saveUiPress(loop: *GameLoop, button: input_mod.LogicalButton) void {
    loop.input.clearAll();
    switch (button) {
        .confirm => loop.input.current.confirm = true,
        .cancel => loop.input.current.cancel = true,
        .up => loop.input.current.up = true,
        .down => loop.input.current.down = true,
        else => unreachable,
    }
    loop.updateLoad();
    loop.input.endFrame();
    loop.input.current = .{};
    loop.input.endFrame();
}

test "save UI: cold Continue selects a real file and restores its map, level, erased events and time" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("data");
    try tmp.dir.makePath("maps");
    try tmp.dir.writeFile(.{ .sub_path = "data/Map087.json", .data = "{\"width\":40,\"height\":30,\"events\":[null]}" });
    try tmp.dir.writeFile(.{ .sub_path = "data/Map088.json", .data = "{\"width\":45,\"height\":40,\"events\":[null,{\"id\":1,\"pages\":[]}]}" });
    try tmp.dir.writeFile(.{ .sub_path = "data/Map999.json", .data = "{\"width\":17,\"height\":13,\"events\":[null]}" });
    try tmp.dir.writeFile(.{ .sub_path = "maps/Map88.json", .data = 
        \\{"width":45,"height":40,"tilewidth":32,"tileheight":32,"tilesets":[],"layers":[{"type":"tilelayer","name":"upper","width":45,"height":40,"data":[],"properties":{"level":"2"}}]}
    });
    const root = try tmp.dir.realpathAlloc(a, ".");
    const writer = try saveUiFixture(a, root);
    const game = &writer.mgr.game;
    game.map.map_id = 87;
    game.player.map_id = 87;
    game.player.x = 28;
    game.player.y = 22;
    game.frame_count_global = 5160;
    var saves = writer.saveManager();
    try std.testing.expect(try saves.saveGame(1));
    game.map.map_id = 88;
    game.player.map_id = 88;
    game.player.x = 20;
    game.player.y = 22;
    game.map.setCurrentMapLevel(2);
    try game.map.erased_events.put(1, true);
    game.map.display_x = 3;
    game.map.display_y = 4;
    game.map.startScriptedScroll(6, 0.75, 3);
    game.player.encounter_count = 6.5;
    game.frame_count_global = 7321;
    try std.testing.expect(try saves.saveGame(2));

    // A separate game/manager/loop begins with the actual fresh-process
    // boot transfer. No prior live transfer can accidentally supply map88.
    const reader = try saveUiFixture(a, root);
    reader.mgr.game.player.reserveTransfer(999, 1, 0, 2, 0);
    reader.openLoad();
    try std.testing.expectEqual(State.load, reader.state);
    try std.testing.expectEqual(@as(usize, 6), reader.file_slot_count);
    reader.load_index = 1;
    saveUiPress(reader, .confirm);
    try std.testing.expectEqual(State.field, reader.state);
    try std.testing.expect(reader.continued_once);
    try std.testing.expectEqual(@as(u32, 88), reader.mgr.game.player.map_id);
    try std.testing.expectEqual(@as(u32, 88), reader.mgr.game.map.map_id);
    try std.testing.expectEqual(@as(u32, 88), reader.mgr.dm.data_map_id);
    try std.testing.expectEqual(@as(i32, 45), reader.mgr.game.map.width);
    try std.testing.expectEqual(@as(i32, 20), reader.mgr.game.player.x);
    try std.testing.expectEqual(@as(i32, 22), reader.mgr.game.player.y);
    try std.testing.expectEqual(@as(i32, 2), reader.mgr.game.map.currentMapLevel());
    try std.testing.expectEqual(@as(f64, 3), reader.mgr.game.map.display_x);
    try std.testing.expectEqual(@as(f64, 4), reader.mgr.game.map.display_y);
    try std.testing.expectEqual(@as(f64, 0.75), reader.mgr.game.map.scripted_scroll.remaining);
    try std.testing.expectEqual(@as(?f64, 6.5), reader.mgr.game.player.encounter_count);
    try std.testing.expect(reader.mgr.game.map.isEventErased(1));
    try std.testing.expectEqual(@as(u64, 7321), reader.mgr.game.frame_count_global);
    try std.testing.expect(!reader.mgr.game.player.isTransferring());
    try std.testing.expect(!reader.itp.chainRunning());
}

test "save UI: empty and corrupt files keep the list usable, cancel returns to title, legacy slot20 remains reachable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    const loop = try saveUiFixture(a, root);
    loop.openLoad();
    saveUiPress(loop, .confirm);
    try std.testing.expectEqual(State.load, loop.state);
    try std.testing.expectEqualStrings("THIS FILE IS EMPTY", loop.load_message);
    saveUiPress(loop, .cancel);
    try std.testing.expectEqual(State.title, loop.state);
    try loop.vfs.writeFileSync("save/file20.rpgsave", "corrupt");
    loop.openLoad();
    try std.testing.expectEqual(@as(usize, 20), loop.file_slot_count);
    try std.testing.expectEqual(@as(usize, 19), loop.load_index);
    saveUiPress(loop, .confirm);
    try std.testing.expectEqual(State.load, loop.state);
    try std.testing.expectEqualStrings("COULD NOT LOAD THIS FILE", loop.load_message);
    saveUiPress(loop, .down);
    try std.testing.expectEqual(@as(usize, 0), loop.load_index);
    saveUiPress(loop, .up);
    try std.testing.expectEqual(@as(usize, 19), loop.load_index);
}

fn tagFixture(a: std.mem.Allocator) !*GameLoop {
    const loop = try schedulerFixture(a, "{\"events\":[null]}", "[null]");
    const game = &loop.mgr.game;
    game.switches.deinit();
    game.variables.deinit();
    game.switches = try @import("state.zig").Switches.init(a, 64);
    game.variables = try @import("state.zig").Variables.init(a, 64);
    try game.party.members.appendSlice(a, &.{ 1, 2, 3, 4 });
    loop.state = .field;
    return loop;
}

test "tag controls: disabled, moving, solo and busy states cannot open selector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try tagFixture(arena.allocator());
    try std.testing.expect(loop.canOpenTag());
    loop.mgr.game.switches.setValue(16, true);
    try std.testing.expect(!loop.canOpenTag());
    loop.mgr.game.switches.setValue(16, false);
    loop.walk_remaining = 1;
    try std.testing.expect(!loop.canOpenTag());
    loop.walk_remaining = 0;
    loop.input.applyControllerButton(sdl.CB_DPLEFT, true);
    try std.testing.expect(!loop.canOpenTag());
    loop.input.clearAll();
    loop.mgr.game.message.add("Busy");
    try std.testing.expect(!loop.canOpenTag());
    loop.mgr.game.message.clear();
    loop.mgr.game.party.members.shrinkRetainingCapacity(1);
    try std.testing.expect(!loop.canOpenTag());
}

test "tag controls: hold/right/release commits authored leader order; cancel leaves it unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const loop = try tagFixture(a);
    loop.tag_active = true;
    loop.input.applyControllerButton(sdl.CB_Y, true);
    loop.input.endFrame();
    loop.input.applyControllerButton(sdl.CB_DPRIGHT, true);
    loop.updateTagSelection();
    try std.testing.expectEqual(@as(usize, 1), loop.tag_index);
    try std.testing.expectEqualSlices(i32, &.{ 1, 2, 3, 4 }, loop.mgr.game.party.members.items);
    loop.input.endFrame();
    loop.input.applyControllerButton(sdl.CB_DPRIGHT, false);
    loop.input.applyControllerButton(sdl.CB_Y, false);
    loop.updateTagSelection();
    try std.testing.expect(!loop.tag_active);
    try std.testing.expectEqualSlices(i32, &.{ 2, 1, 3, 4 }, loop.mgr.game.party.members.items);
    try std.testing.expectEqual(@as(i64, 2), loop.mgr.game.variables.value(20));
    loop.input.endFrame();
    loop.tag_active = true;
    loop.tag_index = 3;
    loop.input.applyControllerButton(sdl.CB_Y, true);
    loop.input.applyControllerButton(sdl.CB_B, true);
    loop.updateTagSelection();
    try std.testing.expect(!loop.tag_active);
    try std.testing.expectEqualSlices(i32, &.{ 2, 1, 3, 4 }, loop.mgr.game.party.members.items);
    var saves = save_mod.SaveManager.init(a, loop.db, undefined, &loop.mgr.game);
    const contents = try saves.makeSaveContents();
    const members = contents.get("party").?.get("_actors").?.arrayItems();
    try std.testing.expectEqual(@as(i64, 2), members[0].asInt());
}

test "tag controls: confirm and real-world order match sortMembersForTag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const loop = try tagFixture(arena.allocator());
    loop.mgr.game.variables.setValue(22, 2);
    loop.mgr.game.party.members.clearRetainingCapacity();
    try loop.mgr.game.party.members.appendSlice(loop.alloc, &.{ 8, 10, 9, 11 });
    loop.tag_active = true;
    loop.tag_index = 2;
    loop.input.applyControllerButton(sdl.CB_Y, true);
    loop.input.applyControllerButton(sdl.CB_A, true);
    loop.updateTagSelection();
    try std.testing.expect(!loop.tag_active);
    try std.testing.expectEqualSlices(i32, &.{ 9, 8, 10, 11 }, loop.mgr.game.party.members.items);
    try std.testing.expectEqual(@as(i64, 9), loop.mgr.game.variables.value(20));
}
