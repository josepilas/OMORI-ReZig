//! Native Game_Interpreter (Milestone 5) — the event-command engine.
//!
//! **Behavioral oracle:** `js/rpg_objects.js` `Game_Interpreter` plus the
//! payload plugin extensions actually on the execution path
//! (`Text_Language_Processor.js` ShowMessage/AddChoice/ShowChoices,
//! `YEP_CallEvent.js` CallEvent).
//!
//! **Command coverage is census-driven, not speculative.** A full census
//! of the real payload (521 maps, 2000 common events, 1000 troops) found
//! exactly 80 distinct field command codes; every one has a handler here.
//! Where the effect belongs to a later milestone (audio mixing, movement
//! interpolation, scene push), the handler updates the engine state,
//! logs the deferral, and continues — nothing runs silently. Unknown
//! codes are skipped EXACTLY like MV's `executeCommand` (no `commandX`
//! method → fall through, advance) with a one-per-code diagnostic.

const std = @import("std");
const balloons = @import("balloons.zig");
const log = @import("../core/log.zig");
const json = @import("../data/json.zig");
const database = @import("../data/database.zig");
const game_mod = @import("game.zig");
const map_mod = @import("map.zig");
const encounter_mod = @import("encounters.zig");
const text_mod = @import("../omori/text.zig");
const battle_mod = @import("battle.zig");
const audio_mixer = @import("../audio/mixer.zig");
const input_mod = @import("../input/input.zig");

/// Input flags consumed per frame (headless scripts or real input).
pub const FrameInput = struct {
    ok: bool = false,
    cancel: bool = false,
    up: bool = false,
    down: bool = false,
    /// Actual interpolation state, not held directions: walking continues
    /// after release, while pushing against a wall is not movement.
    player_moving: bool = false,
    player_jumping: bool = false,
    /// MV command111's Button condition uses held input, independently
    /// of the one-shot presses that advance messages and choices.
    held: ?input_mod.ButtonState = null,
};

fn valStr(v: json.Value) []const u8 {
    return switch (v) {
        .string => |s| s,
        else => "",
    };
}

pub const Interpreter = struct {
    // --- infrastructure -------------------------------------------------
    alloc: std.mem.Allocator,
    game: *game_mod.GameObjects,
    db: *database.Database,
    texts: *text_mod.TextStore,

    // --- MV interpreter state (field-for-field) --------------------------
    depth: usize = 0,
    map_id: u32 = 0,
    event_id: i32 = 0,
    list: []const map_mod.Command = &.{},
    index: usize = 0,
    wait_count: i32 = 0,
    wait_mode: []const u8 = "",
    frame_input: FrameInput = .{},
    comments: std.ArrayList([]const u8) = .empty,
    /// _branch: indent → condition result (null = unset).
    branch: std.AutoHashMap(i32, ?bool),
    child: ?*Interpreter = null,
    freeze_checker: u64 = 0,
    frame_count: u64 = 0,

    // --- movement-route wait (M7 owns real movement) ---------------------
    route_wait_frames: i32 = 0,
    field_routes: bool = false,
    route_event_id: i32 = 0,
    balloon_target: i32 = 0,

    // --- OMORI language choice flow --------------------------------------
    /// Pending language choices from AddChoice: {text, label}.
    choices: std.ArrayList([2][]const u8) = .empty,
    /// True when the installed choice callback is the MV 402/403 branch
    /// kind; false = OMORI label-jump kind.
    choice_is_mv: bool = true,
    /// 402 compares the numeric result; stored when the callback fires.
    choice_branch_value: i32 = -99,
    /// Scene-change request flag (201/353/354) — caller performs it.
    scene_changing: bool = false,

    // --- diagnostics -------------------------------------------------------
    last_message: ?text_mod.MessageData = null,
    executed_commands: u64 = 0,
    skipped_codes: std.AutoHashMap(i32, u64),
    skipped_plugins: std.StringHashMap(u64),

    // --- command-list cache (common events + CallEvent pages) -------------
    command_cache: std.AutoHashMap(i64, []const map_mod.Command) = undefined,
    cache_arena: ?*std.heap.ArenaAllocator = null,

    /// The current map's RawMap (set by the runner after loadMapData).
    currentRawMap: ?*const map_mod.RawMap = null,

    /// Local variables of the currently-running script block.
    script_vars: std.StringHashMap(i64),

    /// M8: battle branch results (0 win / 1 escape / 2 lose) keyed by
    /// indent — the 601/602/603 contract.
    battle_branch: std.AutoHashMap(i32, u8),
    /// Interactive scenes suspend command 301 until their battle UI
    /// returns a result. Standalone diagnostic interpreters keep the
    /// deterministic atomic runner.
    scene_battles: bool = false,
    scene_battle: ?SceneBattle = null,

    /// Deterministic RNG for 122 random (seeded per-boot).
    rng: std.Random.DefaultPrng = std.Random.DefaultPrng.init(0x4F4D4F52),

    pub const SceneBattle = struct {
        troop_id: i32,
        can_escape: bool,
        can_lose: bool,
        indent: i32,
        claimed: bool = false,
    };

    // -----------------------------------------------------------------
    // Lifecycle
    // -----------------------------------------------------------------

    pub fn init(alloc: std.mem.Allocator, game: *game_mod.GameObjects, db: *database.Database, texts: *text_mod.TextStore) Interpreter {
        return Interpreter{
            .alloc = alloc,
            .game = game,
            .db = db,
            .texts = texts,
            .branch = std.AutoHashMap(i32, ?bool).init(alloc),
            .choices = .empty,
            .skipped_codes = std.AutoHashMap(i32, u64).init(alloc),
            .skipped_plugins = std.StringHashMap(u64).init(alloc),
            .comments = .empty,
            .command_cache = std.AutoHashMap(i64, []const map_mod.Command).init(alloc),
            .script_vars = std.StringHashMap(i64).init(alloc),
            .battle_branch = std.AutoHashMap(i32, u8).init(alloc),
        };
    }

    pub fn deinit(self: *Interpreter) void {
        self.comments.deinit(self.alloc);
        self.branch.deinit();
        self.choices.deinit(self.alloc);
        if (self.child) |c| {
            c.deinit();
            self.alloc.destroy(c);
            self.child = null;
        }
        self.skipped_codes.deinit();
        if (self.cache_arena) |a| {
            a.deinit();
            self.alloc.destroy(a);
        }
        self.command_cache.deinit();
        var it = self.skipped_plugins.iterator();
        while (it.next()) |e| self.alloc.free(e.key_ptr.*);
        self.skipped_plugins.deinit();
        var sit = self.script_vars.iterator();
        while (sit.next()) |e| self.alloc.free(e.key_ptr.*);
        self.script_vars.deinit();
        self.battle_branch.deinit();
    }

    /// setup(list, eventId) — mapId from $gameMap (MV semantics).
    pub fn setup(self: *Interpreter, list: []const map_mod.Command, event_id: i32) void {
        self.clearState();
        self.map_id = self.game.map.map_id;
        self.event_id = event_id;
        self.list = list;
        log.event(.mv, .info, "interpreter setup: event {d}, map {d}, {d} command(s)", .{ event_id, self.map_id, list.len });
    }

    fn clearState(self: *Interpreter) void {
        self.map_id = 0;
        self.event_id = 0;
        self.list = &.{};
        self.index = 0;
        self.wait_count = 0;
        self.wait_mode = "";
        self.scene_battle = null;
        self.route_wait_frames = 0;
        self.route_event_id = 0;
        self.comments.clearRetainingCapacity();
        self.choices.clearRetainingCapacity();
        self.branch.clearRetainingCapacity();
        var sit = self.script_vars.iterator();
        while (sit.next()) |e| self.alloc.free(e.key_ptr.*);
        self.script_vars.clearRetainingCapacity();
        if (self.child) |c| {
            c.deinit();
            self.alloc.destroy(c);
            self.child = null;
        }
    }

    pub fn isRunning(self: *const Interpreter) bool {
        return self.list.len > 0;
    }

    /// v36: is this interpreter or any child in the chain still running?
    /// Interpreter `list`/`currentRawMap` point into the map arena, so
    /// the arena must not reset while a chain runs
    /// (data_manager.resetMapArena gates on this).
    pub fn chainRunning(self: *const Interpreter) bool {
        if (self.list.len > 0) return true;
        if (self.child) |c| return c.chainRunning();
        return false;
    }

    pub fn pendingSceneBattle(self: *Interpreter) ?*Interpreter {
        if (self.child) |child| {
            if (child.pendingSceneBattle()) |owner| return owner;
        }
        if (self.scene_battle) |request| {
            if (!request.claimed) return self;
        }
        return null;
    }

    pub fn completeSceneBattle(self: *Interpreter, result: battle_mod.BattleResult) void {
        const request = self.scene_battle orelse return;
        self.battle_branch.put(request.indent, @intCast(@intFromEnum(result))) catch {};
        self.scene_battle = null;
    }

    /// MV checkOverflow (depth >= 100 → error).
    pub fn checkOverflow(self: *const Interpreter) InterpreterError!void {
        if (self.depth >= 100) {
            log.event(.mv, .err, "FATAL: common event calls exceeded the limit (depth {d})", .{self.depth});
            return InterpreterError.CommonEventDepth;
        }
    }

    // -----------------------------------------------------------------
    // update loop (Game_Interpreter.update)
    // -----------------------------------------------------------------

    /// One frame. Drives the message window, then commands until a wait.
    pub fn update(self: *Interpreter, input: FrameInput) void {
        self.setFrameInput(input);
        const owner = self.findMessageOwner() orelse self;
        owner.applyChoiceResultIfReady();
        self.advanceMessageFlow(input);
        owner.applyChoiceResultIfReady();
        self.updateCommands();
    }

    /// All active event chains see the same logical input snapshot.
    /// A common-event child can own a picture's wait-for-input loop.
    pub fn setFrameInput(self: *Interpreter, input: FrameInput) void {
        self.frame_input = input;
        if (self.child) |child| child.setFrameInput(input);
    }

    /// Scene_Map owns the one shared message-window tick. Independent
    /// parallel interpreters run commands without advancing that window.
    pub fn updateCommands(self: *Interpreter) void {
        var guard: u64 = 0;
        while (self.isRunning()) {
            guard += 1;
            if (guard > 200000) {
                log.event(.mv, .warn, "interpreter freeze guard tripped (event {d})", .{self.event_id});
                break;
            }
            if (self.updateChild() or self.updateWait()) break;
            if (self.sceneRequested()) break;
            if (!self.executeCommand()) break;
            if (self.checkFreeze()) break;
        }
    }

    /// The deepest waiting interpreter owns the message/choice callback.
    /// Parents must not consume a child's choice result.
    pub fn findMessageOwner(self: *Interpreter) ?*Interpreter {
        if (self.child) |child| {
            if (child.findMessageOwner()) |owner| return owner;
        }
        return if (std.mem.eql(u8, self.wait_mode, "message")) self else null;
    }

    pub fn acceptChoiceResult(self: *Interpreter) void {
        self.applyChoiceResultIfReady();
    }

    pub fn commonEventList(self: *Interpreter, id: i32) []const map_mod.Command {
        const file = self.db.get("data/CommonEvents.json") orelse return &.{};
        const events = file.value.arrayItems();
        if (id <= 0 or id >= events.len) return &.{};
        const value = events[@intCast(id)].get("list") orelse return &.{};
        return self.getOrParseCommandCache(id, value);
    }

    /// The interpreter pauses for scene changes (SceneManager.isSceneChanging).
    fn sceneRequested(self: *Interpreter) bool {
        if (self.scene_changing) {
            log.event(.mv, .note, "interpreter paused: scene change requested (map {d})", .{self.game.player.new_map_id});
            return true;
        }
        return false;
    }

    /// 201/353/354 set this; the caller (Scene_Map/SceneManager) performs
    /// the transfer and then calls resumeAfterScene().
    pub fn requestSceneChange(self: *Interpreter) void {
        self.scene_changing = true;
    }

    fn updateChild(self: *Interpreter) bool {
        if (self.child) |c| {
            c.updateCommands();
            if (c.isRunning()) return true;
            c.deinit();
            self.alloc.destroy(c);
            self.child = null;
        }
        return false;
    }

    fn updateWait(self: *Interpreter) bool {
        return self.updateWaitCount() or self.updateWaitMode();
    }

    fn updateWaitCount(self: *Interpreter) bool {
        if (self.wait_count > 0) {
            self.wait_count -= 1;
            return true;
        }
        return false;
    }

    fn updateWaitMode(self: *Interpreter) bool {
        const waiting = blk: {
            if (std.mem.eql(u8, self.wait_mode, "message")) {
                break :blk self.game.message.isBusy();
            } else if (std.mem.eql(u8, self.wait_mode, "transfer")) {
                break :blk self.game.player.isTransferring();
            } else if (std.mem.eql(u8, self.wait_mode, "scroll")) {
                break :blk self.game.map.isScrolling();
            } else if (std.mem.eql(u8, self.wait_mode, "route")) {
                if (self.route_event_id > 0) break :blk self.isOnCurrentMap() and self.game.map.visual_routes.forcing(self.route_event_id);
                break :blk self.route_wait_frames > 0;
            } else if (std.mem.eql(u8, self.wait_mode, "gather")) {
                break :blk self.game.followers.gathering;
            } else if (std.mem.eql(u8, self.wait_mode, "balloon")) {
                break :blk self.isOnCurrentMap() and self.game.map.balloons.contains(self.balloon_target);
            } else if (std.mem.eql(u8, self.wait_mode, "fade")) {
                break :blk self.game.screen.isFading();
            } else if (std.mem.eql(u8, self.wait_mode, "battle")) {
                break :blk self.scene_battle != null;
            }
            break :blk false;
        };
        if (std.mem.eql(u8, self.wait_mode, "route") and self.route_wait_frames > 0) {
            self.route_wait_frames -= 1;
        }
        if (!waiting) self.wait_mode = "";
        return waiting;
    }

    fn setWaitMode(self: *Interpreter, mode: []const u8) void {
        self.wait_mode = mode;
    }

    fn wait(self: *Interpreter, duration: i32) void {
        self.wait_count = duration;
    }

    fn checkFreeze(self: *Interpreter) bool {
        if (self.frame_count != self.game.frame_count_global) {
            self.frame_count = self.game.frame_count_global;
            self.freeze_checker = 0;
        }
        self.freeze_checker += 1;
        return self.freeze_checker >= 100000;
    }

    // -----------------------------------------------------------------
    // Message-window advance + choice callback application
    // -----------------------------------------------------------------

    fn advanceMessageFlow(self: *Interpreter, input: FrameInput) void {
        const msg = &self.game.message;
        if (msg.choices.items.len > 0) {
            if (input.down) msg.choice_index = @min(msg.choice_index + 1, @as(i32, @intCast(msg.choices.items.len)) - 1);
            if (input.up) msg.choice_index = @max(msg.choice_index - 1, 0);
            if (input.ok and msg.num_input_value == null and msg.num_input_max_digits == 0) {
                msg.num_input_value = null;
            }
        }
        msg.update(input.ok, input.cancel, &self.game.variables);
    }

    /// Apply the choice callback the moment the message window finished
    /// with a choice result (Window_ChoiceList.callOkHandler timing).
    fn applyChoiceResultIfReady(self: *Interpreter) void {
        const msg = &self.game.message;
        const result = msg.choice_result orelse return;
        msg.choice_result = null;
        if (self.choice_is_mv) {
            // MV setupChoices callback: _branch[indent] = n
            const indent: i32 = if (self.index < self.list.len) self.list[self.index].indent else 0;
            self.setBranchIndentValue(indent, result);
            log.detail(.mv, "choice result {d} → branch[{d}]", .{ result, indent });
        } else {
            // OMORI language flow: jump to the chosen label
            if (result >= 0 and result < self.choices.items.len) {
                const label = self.choices.items[@intCast(result)][1];
                log.event(.mv, .note, "language choice '{s}' → jump to label '{s}'", .{ self.choices.items[@intCast(result)][0], label });
                self.jumpToLabelName(label);
            }
            self.choices.clearRetainingCapacity();
        }
    }

    fn setBranchIndentValue(self: *Interpreter, indent: i32, value: i32) void {
        // Store as ?bool: >= 0 maps to true-ish sentinel; we keep the
        // number in a side channel (choice_branch_value) for 402 checks.
        self.setBranch(indent, value >= 0);
        self.choice_branch_value = value;
    }

    fn jumpToLabelName(self: *Interpreter, label: []const u8) void {
        for (self.list, 0..) |c, i| {
            if (c.code == 118 and c.parameters.len > 0 and std.mem.eql(u8, valStr(c.parameters[0]), label)) {
                self.jumpTo(i);
                return;
            }
        }
        log.event(.mv, .warn, "jump to label '{s}': label not found", .{label});
    }

    // -----------------------------------------------------------------
    // executeCommand
    // -----------------------------------------------------------------

    fn currentCommand(self: *const Interpreter) ?map_mod.Command {
        if (self.index < self.list.len) return self.list[self.index];
        return null;
    }

    fn nextEventCode(self: *const Interpreter) i32 {
        if (self.index + 1 < self.list.len) return self.list[self.index + 1].code;
        return 0;
    }

    fn executeCommand(self: *Interpreter) bool {
        const cmd = self.currentCommand() orelse {
            self.terminate();
            return true;
        };
        // MV: unknown code → no commandX method → fall through, ADVANCE.
        // (code 0 is exactly this: no method, index advances.)
        self.executed_commands += 1;
        const cont = self.dispatch(cmd);
        if (cont) self.index += 1;
        return cont;
    }

    fn terminate(self: *Interpreter) void {
        self.list = &.{};
        self.comments.clearRetainingCapacity();
    }

    // --- parameter accessors -------------------------------------------

    fn pInt(self: *Interpreter, cmd: map_mod.Command, i: usize, default: i64) i64 {
        _ = self;
        const ps = cmd.parameters;
        if (i >= ps.len) return default;
        return ps[i].asInt();
    }

    fn pStr(self: *Interpreter, cmd: map_mod.Command, i: usize, default: []const u8) []const u8 {
        _ = self;
        const ps = cmd.parameters;
        if (i >= ps.len) return default;
        return valStr(ps[i]);
    }

    fn pArr(self: *Interpreter, cmd: map_mod.Command, i: usize) []const json.Value {
        _ = self;
        const ps = cmd.parameters;
        if (i >= ps.len) return &.{};
        return ps[i].arrayItems();
    }

    fn pBgm(self: *Interpreter, cmd: map_mod.Command, i: usize) game_mod.GameSystem.BgmSave {
        _ = self;
        const ps = cmd.parameters;
        if (i < ps.len) {
            if (ps[i].get("name")) |n| {
                var out: game_mod.GameSystem.BgmSave = .{ .name = valStr(n), .volume = 90, .pitch = 100, .pan = 0 };
                if (ps[i].get("volume")) |v| out.volume = @intCast(v.asInt());
                if (ps[i].get("pitch")) |v| out.pitch = @intCast(v.asInt());
                if (ps[i].get("pan")) |v| out.pan = @intCast(v.asInt());
                return out;
            }
        }
        return .{ .name = "", .volume = 90, .pitch = 100, .pan = 0 };
    }

    // --- branch machinery ------------------------------------------------

    fn setBranch(self: *Interpreter, indent: i32, value: ?bool) void {
        self.branch.put(indent, value) catch {};
    }

    fn getBranch(self: *const Interpreter, indent: i32) ?bool {
        return self.branch.get(indent) orelse null;
    }

    fn skipBranch(self: *Interpreter) void {
        const indent = self.currentCommand().?.indent;
        while (self.index + 1 < self.list.len and self.list[self.index + 1].indent > indent) {
            self.index += 1;
        }
    }

    fn jumpTo(self: *Interpreter, target: usize) void {
        const last = self.index;
        const start = @min(target, last);
        const end = @max(target, last);
        var indent = self.currentCommand().?.indent;
        var i = start;
        while (i <= end and i < self.list.len) : (i += 1) {
            const new_indent = self.list[i].indent;
            if (new_indent != indent) {
                self.setBranch(indent, null);
                indent = new_indent;
            }
        }
        self.index = target;
    }

    fn setupChild(self: *Interpreter, list: []const map_mod.Command, event_id: i32) InterpreterError!void {
        if (self.child != null) {
            log.event(.mv, .warn, "interpreter: common event while child running — deferred", .{});
            return;
        }
        const child = self.alloc.create(Interpreter) catch return InterpreterError.OutOfMemory;
        child.* = Interpreter.init(self.alloc, self.game, self.db, self.texts);
        child.scene_battles = self.scene_battles;
        child.field_routes = self.field_routes;
        child.depth = self.depth + 1;
        try child.checkOverflow();
        child.setup(list, event_id);
        child.setFrameInput(self.frame_input);
        child.setCurrentRawMap(self.currentRawMap);
        self.child = child;
    }

    fn isOnCurrentMap(self: *const Interpreter) bool {
        return self.map_id == self.game.map.map_id;
    }

    // --- command-list cache ----------------------------------------------

    fn cacheArena(self: *Interpreter) *std.heap.ArenaAllocator {
        if (self.cache_arena == null) {
            const a = self.alloc.create(std.heap.ArenaAllocator) catch unreachable;
            a.* = std.heap.ArenaAllocator.init(self.alloc);
            self.cache_arena = a;
        }
        return self.cache_arena.?;
    }

    fn getOrParseCommandCache(self: *Interpreter, key: i64, list_value: json.Value) []const map_mod.Command {
        if (self.command_cache.get(key)) |cached| return cached;
        const parsed = map_mod.parseCommands(self.cacheArena().allocator(), list_value) catch return &.{};
        self.command_cache.put(key, parsed) catch {};
        return parsed;
    }

    fn noteSkippedCode(self: *Interpreter, code: i32) bool {
        const entry = self.skipped_codes.getOrPut(code) catch return true;
        if (!entry.found_existing) {
            log.event(.mv, .note, "command {d}: no native handler — skipped (MV: no command{d} method)", .{ code, code });
        }
        entry.value_ptr.* += 1;
        return true;
    }

    fn noteSkippedPluginOnce(self: *Interpreter, name: []const u8) void {
        const key = self.alloc.dupe(u8, name) catch return;
        const entry = self.skipped_plugins.getOrPut(key) catch {
            self.alloc.free(key);
            return;
        };
        if (entry.found_existing) {
            self.alloc.free(key);
            entry.value_ptr.* += 1;
            return;
        }
        entry.value_ptr.* = 1;
        log.event(.mv, .note, "plugin command '{s}': no native implementation — logged and skipped", .{name});
    }

    pub fn resumeAfterScene(self: *Interpreter) void {
        self.scene_changing = false;
    }

    /// Clear the scene-change request along the whole interpreter chain
    /// (a transfer requested inside a child common event flags the CHILD;
    /// the performer must clear it everywhere or the child stalls).
    pub fn clearSceneChangeDeep(self: *Interpreter) void {
        self.scene_changing = false;
        if (self.child) |c| c.clearSceneChangeDeep();
    }

    // =================================================================
    // dispatch (executeCommand) — all 80 census field codes
    // =================================================================

    fn dispatch(self: *Interpreter, cmd: map_mod.Command) bool {
        return switch (cmd.code) {
            0 => true,
            101 => self.cmdShowText(),
            102 => self.cmdShowChoices(),
            103 => self.cmdInputNumber(),
            104 => self.cmdSelectItem(),
            105 => self.cmdShowScrollingText(),
            108 => self.cmdComment(),
            111 => self.cmdIf(),
            112 => true, // loop
            113 => self.cmdBreakLoop(),
            115 => self.cmdExitProcessing(),
            117 => self.cmdCommonEvent(),
            118 => true, // label
            119 => self.cmdJumpToLabel(),
            121 => self.cmdControlSwitches(),
            122 => self.cmdControlVariables(),
            123 => self.cmdControlSelfSwitch(),
            124 => self.cmdControlTimer(),
            125 => self.cmdChangeGold(),
            126 => self.cmdChangeItems(),
            127 => self.cmdChangeWeaponsOrArmors(.item),
            128 => self.cmdChangeWeaponsOrArmors(.armor),
            129 => self.cmdChangePartyMember(),
            132 => self.cmdSetBgmFlag(.battle_bgm),
            133 => self.cmdSetBgmFlag(.victory_me),
            134 => self.cmdAccessFlag(.save),
            135 => self.cmdAccessFlag(.menu),
            136 => self.cmdAccessFlag(.encounter),
            137 => self.cmdAccessFlag(.formation),
            201 => self.cmdTransferPlayer(),
            203 => self.cmdSetEventLocation(),
            204 => self.cmdScrollMap(),
            205 => self.cmdSetMovementRoute(),
            211 => self.cmdChangeTransparency(),
            212 => self.cmdCharacterFx("animation"),
            213 => self.cmdBalloon(),
            214 => self.cmdEraseEvent(),
            216 => self.cmdChangeFollowers(),
            217 => self.cmdGatherFollowers(),
            221 => self.cmdFade(.out),
            222 => self.cmdFade(.in),
            223 => self.cmdTintScreen(),
            224 => self.cmdFlashScreen(),
            225 => self.cmdShakeScreen(),
            230 => self.cmdWait(),
            231 => self.cmdShowPicture(),
            232 => self.cmdMovePicture(),
            233 => self.cmdRotatePicture(),
            234 => self.cmdTintPicture(),
            235 => self.cmdErasePicture(),
            236 => self.cmdWeather(),
            241 => self.cmdPlayAudio(.bgm),
            242 => self.cmdFadeoutAudio("bgm"),
            243 => self.cmdSaveBgm(),
            244 => self.cmdResumeBgm(),
            245 => self.cmdPlayAudio(.bgs),
            246 => self.cmdFadeoutAudio("bgs"),
            249 => self.cmdPlayAudio(.me),
            250 => self.cmdPlayAudio(.se),
            251 => self.cmdStopSe(),
            283 => self.cmdChangeBattleback(),
            284 => self.cmdChangeParallax(),
            302 => self.cmdShopProcessing(),
            311 => self.cmdChangeHpMp(.hp),
            312 => self.cmdChangeHpMp(.mp),
            313 => self.cmdChangeState(),
            314 => self.cmdRecoverAll(),
            315 => self.cmdChangeExp(),
            316 => self.cmdChangeLevel(),
            317 => self.cmdChangeParam(),
            318 => self.cmdChangeSkill(),
            319 => self.cmdChangeEquip(),
            322 => self.cmdChangeActorImages(),
            301 => self.cmdBattleProcessing(),
            331 => self.cmdEnemyHp(),
            332 => self.cmdEnemyMp(),
            333 => self.cmdEnemyState(),
            334 => self.cmdEnemyRecoverAll(),
            335 => self.cmdEnemyAppear(),
            336 => self.cmdEnemyTransform(),
            337 => self.cmdBattleAnimation(),
            339 => true, // Force Action — the battle driver's scripted
            // input path; logged by the battle manager
            340 => self.cmdAbortBattle(),
            342 => self.cmdEnemyTp(),
            353 => self.cmdGameOver(),
            355 => self.cmdScript(),
            356 => self.cmdPluginCommand(),
            357 => self.cmdControlSelfVariables(),
            402 => self.cmdWhenChoice(),
            403 => self.cmdWhenCancel(),
            411 => self.cmdElse(),
            412 => true, // end-if (branch cleanup is implicit via indent map)
            413 => self.cmdRepeatAbove(),
            601 => self.cmdBattleBranch(0), // If Win
            602 => self.cmdBattleBranch(1), // If Escape
            603 => self.cmdBattleBranch(2), // If Lose
            655 => true, // script continuation — consumed by 355
            604, 605 => true, // battle-branch / shop data-only brackets
            else => self.noteSkippedCode(cmd.code), // MV: no handler → skip
        };
    }

    // =================================================================
    // Message commands (101-105, 402/403)
    // =================================================================

    fn cmdShowText(self: *Interpreter) bool {
        if (self.game.message.isBusy()) return false;
        const cmd = self.currentCommand().?;
        const msg = &self.game.message;
        msg.clear();
        msg.setFaceImage(self.pStr(cmd, 0, ""), @intCast(self.pInt(cmd, 1, 0)));
        msg.setBackground(@intCast(self.pInt(cmd, 2, 0)));
        msg.setPositionType(@intCast(self.pInt(cmd, 3, 2)));
        while (self.nextEventCode() == 401) {
            self.index += 1;
            const line = self.currentCommand().?;
            if (line.parameters.len > 0) msg.add(valStr(line.parameters[0]));
        }
        const nxt = self.nextEventCode();
        if (nxt == 102) {
            self.index += 1;
            self.setupChoices(self.currentCommand().?);
        } else if (nxt == 103) {
            self.index += 1;
            self.game.message.setNumberInput(@intCast(self.pInt(self.currentCommand().?, 0, 0)), @intCast(self.pInt(self.currentCommand().?, 1, 0)));
        } else if (nxt == 104) {
            self.index += 1;
            self.game.message.setItemChoice(@intCast(self.pInt(self.currentCommand().?, 0, 0)), @intCast(self.pInt(self.currentCommand().?, 1, 2)));
        } else if (nxt == 356) {
            // OMORI: ShowMessage then "356: ShowChoices <cancel>".
            const txt = self.pStr(self.list[self.index + 1], 0, "");
            var it = std.mem.splitScalar(u8, txt, ' ');
            const name = it.next() orelse "";
            if (std.mem.eql(u8, name, "ShowChoices")) {
                const cancel = it.next();
                self.index += 1;
                self.setupLanguageChoices(cancel);
            }
        }
        self.index += 1;
        self.setWaitMode("message");
        return false;
    }

    fn cmdShowChoices(self: *Interpreter) bool {
        if (self.game.message.isBusy()) return false;
        self.setupChoices(self.currentCommand().?);
        self.index += 1;
        self.setWaitMode("message");
        return false;
    }

    fn setupChoices(self: *Interpreter, cmd: map_mod.Command) void {
        var choice_texts: std.ArrayList([]const u8) = .empty;
        defer choice_texts.deinit(self.alloc);
        for (self.pArr(cmd, 0)) |c| {
            choice_texts.append(self.alloc, valStr(c)) catch {};
        }
        var cancel: i32 = @intCast(self.pInt(cmd, 1, 0));
        const default: i32 = @intCast(self.pInt(cmd, 2, 0));
        const pos: i32 = @intCast(self.pInt(cmd, 3, 2));
        if (cancel >= choice_texts.items.len) cancel = -2;
        const msg = &self.game.message;
        // MV setupChoices does NOT clear the message — text + choices
        // coexist (the window renders both).
        msg.setChoices(choice_texts.items, default, cancel);
        msg.setPositionType(pos);
        self.choice_is_mv = true;
        self.choice_branch_value = -99;
    }

    /// OMORI language flow setupChoices: accumulated AddChoice entries.
    fn setupLanguageChoices(self: *Interpreter, cancel_param: ?[]const u8) void {
        var cancel: i32 = -2;
        if (cancel_param) |c| {
            cancel = std.fmt.parseInt(i32, std.mem.trim(u8, c, " "), 10) catch -2;
        }
        var texts: std.ArrayList([]const u8) = .empty;
        defer texts.deinit(self.alloc);
        for (self.choices.items) |pair| {
            texts.append(self.alloc, pair[0]) catch {};
        }
        if (cancel >= texts.items.len) cancel = -2;
        const msg = &self.game.message;
        msg.setChoices(texts.items, 0, cancel);
        // choice labels — consumed on result.
        self.choice_is_mv = false;
    }

    fn cmdInputNumber(self: *Interpreter) bool {
        if (self.game.message.isBusy()) return false;
        const cmd = self.currentCommand().?;
        self.game.message.clear();
        self.game.message.setNumberInput(@intCast(self.pInt(cmd, 0, 0)), @intCast(self.pInt(cmd, 1, 0)));
        self.index += 1;
        self.setWaitMode("message");
        return false;
    }

    fn cmdSelectItem(self: *Interpreter) bool {
        if (self.game.message.isBusy()) return false;
        const cmd = self.currentCommand().?;
        self.game.message.clear();
        self.game.message.setItemChoice(@intCast(self.pInt(cmd, 0, 0)), @intCast(self.pInt(cmd, 1, 2)));
        self.index += 1;
        self.setWaitMode("message");
        return false;
    }

    fn cmdShowScrollingText(self: *Interpreter) bool {
        if (self.game.message.isBusy()) return false;
        const cmd = self.currentCommand().?;
        const msg = &self.game.message;
        msg.clear();
        msg.setScroll(@intCast(self.pInt(cmd, 0, 2)), self.pInt(cmd, 1, 0) != 0);
        while (self.nextEventCode() == 405) {
            self.index += 1;
            const line = self.currentCommand().?;
            if (line.parameters.len > 0) msg.add(valStr(line.parameters[0]));
        }
        self.index += 1;
        self.setWaitMode("message");
        return false;
    }

    /// 402 When [n].
    fn cmdWhenChoice(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        if (self.choice_branch_value != self.pInt(cmd, 0, -1)) {
            self.skipBranch();
        }
        return true;
    }

    /// 403 When Cancel.
    fn cmdWhenCancel(self: *Interpreter) bool {
        if (self.choice_branch_value >= 0) {
            self.skipBranch();
        }
        return true;
    }

    /// 108 Comment + 408s.
    fn cmdComment(self: *Interpreter) bool {
        self.comments.clearRetainingCapacity();
        self.comments.append(self.alloc, self.pStr(self.currentCommand().?, 0, "")) catch {};
        while (self.nextEventCode() == 408) {
            self.index += 1;
            self.comments.append(self.alloc, self.pStr(self.currentCommand().?, 0, "")) catch {};
        }
        return true;
    }

    // =================================================================
    // Flow control (111-119, 411/413)
    // =================================================================

    fn cmdIf(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const result = self.evalCondition(cmd);
        self.setBranch(cmd.indent, result);
        if (result != true) self.skipBranch();
        return true;
    }

    fn evalCondition(self: *Interpreter, cmd: map_mod.Command) bool {
        switch (self.pInt(cmd, 0, -1)) {
            0 => { // Switch
                const id: usize = @intCast(@max(self.pInt(cmd, 1, 0), 1));
                return self.game.switches.value(id) == (self.pInt(cmd, 2, 0) == 0);
            },
            1 => { // Variable
                const id: usize = @intCast(@max(self.pInt(cmd, 1, 0), 1));
                const v1 = self.game.variables.value(id);
                const v2 = if (self.pInt(cmd, 2, 0) == 0)
                    self.pInt(cmd, 3, 0)
                else
                    self.game.variables.value(@intCast(@max(self.pInt(cmd, 3, 1), 1)));
                return switch (self.pInt(cmd, 4, 0)) {
                    0 => v1 == v2,
                    1 => v1 >= v2,
                    2 => v1 <= v2,
                    3 => v1 > v2,
                    4 => v1 < v2,
                    5 => v1 != v2,
                    else => false,
                };
            },
            2 => { // Self Switch
                if (self.event_id > 0) {
                    return self.game.self_switches.value(self.map_id, self.event_id, self.pStr(cmd, 1, "A")) == (self.pInt(cmd, 2, 0) == 0);
                }
                return false;
            },
            3 => { // Timer
                if (self.game.timer.working) {
                    const secs = @divTrunc(@as(i64, @intCast(self.game.timer.frames)), 60);
                    return if (self.pInt(cmd, 2, 0) == 0) secs >= self.pInt(cmd, 1, 0) else secs <= self.pInt(cmd, 1, 0);
                }
                return false;
            },
            4 => { // Actor
                const a = self.game.actors.actor(@intCast(self.pInt(cmd, 1, 0)));
                if (a) |actor| {
                    const n: i64 = self.pInt(cmd, 3, 0);
                    return switch (self.pInt(cmd, 2, 0)) {
                        0 => blk: {
                            for (self.game.party.members.items) |m| {
                                if (m == actor.actor_id) break :blk true;
                            }
                            break :blk false;
                        },
                        1 => std.mem.eql(u8, actor.name, self.pStr(cmd, 3, "")),
                        2 => actor.class_id == n,
                        3 => actor.hasSkill(@intCast(n)),
                        6 => actor.isStateAffected(@intCast(n)), // M8: state
                        else => false,
                    };
                }
                return false;
            },
            5 => { // M8: Enemy — appear / HP% / state (battle only)
                if (!self.game.troop.in_battle) return false;
                const idx = self.pInt(cmd, 1, 0);
                if (idx < 0 or idx >= self.game.troop.enemies.items.len) return false;
                const e = self.game.troop.enemies.items[@intCast(idx)];
                const n: i64 = self.pInt(cmd, 3, 0);
                return switch (self.pInt(cmd, 2, 0)) {
                    0 => e.isAppeared(),
                    1 => e.hpRate() * 100 <= @as(f64, @floatFromInt(n)),
                    2 => e.isStateAffected(@intCast(n)),
                    else => false,
                };
            },
            6 => { // Character direction (movement is M7; player only)
                return self.game.player.direction == self.pInt(cmd, 2, 2);
            },
            7 => { // Gold
                return switch (self.pInt(cmd, 2, 0)) {
                    0 => self.game.party.gold >= self.pInt(cmd, 1, 0),
                    1 => self.game.party.gold <= self.pInt(cmd, 1, 0),
                    2 => self.game.party.gold < self.pInt(cmd, 1, 0),
                    else => false,
                };
            },
            8 => return self.game.party.numItems(@intCast(self.pInt(cmd, 1, 0))) > 0,
            9, 10 => {
                const weapon = self.pInt(cmd, 0, 0) == 9;
                const id = std.math.cast(i32, self.pInt(cmd, 1, 0)) orelse return false;
                if ((if (weapon) self.game.party.numWeapons(id) else self.game.party.numArmors(id)) > 0) return true;
                if (self.pInt(cmd, 2, 0) == 0) return false;
                for (self.game.party.members.items) |actor_id| {
                    const actor = self.game.actors.actor(actor_id) orelse continue;
                    for (actor.equips.items) |equip| {
                        if (equip.is_weapon == weapon and equip.item_id == id and id > 0) return true;
                    }
                }
                return false;
            },
            11 => return self.isButtonPressed(self.pStr(cmd, 1, "")),
            12 => { // Bounded authored conditions; unknown JS still logs.
                if (partyCountCondition(self.pStr(cmd, 1, ""), self.game.party.members.items.len)) |result| return result;
                if (playerMotionCondition(self.pStr(cmd, 1, ""), self.frame_input)) |result| return result;
                self.noteSkippedPluginOnce("script-condition");
                return false;
            },
            14 => { // Self Variable (OMORI)
                const v1 = self.game.self_variables.value(self.map_id, self.event_id, self.pStr(cmd, 1, ""));
                const v2 = if (self.pInt(cmd, 2, 0) == 0)
                    self.pInt(cmd, 3, 0)
                else if (self.pInt(cmd, 2, 0) == 1)
                    self.game.self_variables.value(self.map_id, self.event_id, self.pStr(cmd, 3, ""))
                else
                    self.game.variables.value(@intCast(@max(self.pInt(cmd, 3, 1), 1)));
                return switch (self.pInt(cmd, 4, 0)) {
                    0 => v1 == v2,
                    1 => v1 >= v2,
                    2 => v1 <= v2,
                    3 => v1 > v2,
                    4 => v1 < v2,
                    5 => v1 != v2,
                    else => false,
                };
            },
            else => return false, // 5 enemy / 13 vehicle: battle milestone
        }
    }

    fn isButtonPressed(self: *const Interpreter, name: []const u8) bool {
        var held = self.frame_input.held orelse input_mod.ButtonState{
            .confirm = self.frame_input.ok,
            .cancel = self.frame_input.cancel,
            .up = self.frame_input.up,
            .down = self.frame_input.down,
        };
        // An SDL down/up pair can arrive in one pump. Preserve that
        // frame's queued logical edge even though the key is now up.
        held.confirm = held.confirm or self.frame_input.ok;
        held.cancel = held.cancel or self.frame_input.cancel;
        held.up = held.up or self.frame_input.up;
        held.down = held.down or self.frame_input.down;
        // The payload's Input.isPressed aliases escape into cancel/menu.
        if (std.mem.eql(u8, name, "ok")) return held.confirm;
        if (std.mem.eql(u8, name, "cancel")) return held.cancel or held.menu;
        if (std.mem.eql(u8, name, "escape") or std.mem.eql(u8, name, "menu")) return held.menu;
        if (std.mem.eql(u8, name, "shift")) return held.dash;
        if (std.mem.eql(u8, name, "up")) return held.up;
        if (std.mem.eql(u8, name, "down")) return held.down;
        if (std.mem.eql(u8, name, "left")) return held.left;
        if (std.mem.eql(u8, name, "right")) return held.right;
        if (std.mem.eql(u8, name, "pageup")) return held.page_up;
        if (std.mem.eql(u8, name, "pagedown")) return held.page_down;
        return false;
    }

    /// 411 Else.
    fn cmdElse(self: *Interpreter) bool {
        if (self.getBranch(self.currentCommand().?.indent) != false) {
            self.skipBranch();
        }
        return true;
    }

    /// 113 Break Loop.
    fn cmdBreakLoop(self: *Interpreter) bool {
        var depth: i32 = 0;
        while (self.index < self.list.len - 1) {
            self.index += 1;
            const c = self.list[self.index];
            if (c.code == 112) depth += 1;
            if (c.code == 413) {
                if (depth > 0) depth -= 1 else break;
            }
        }
        return true;
    }

    /// 115 Exit Event Processing.
    fn cmdExitProcessing(self: *Interpreter) bool {
        self.index = self.list.len;
        return true;
    }

    /// 117 Common Event (child interpreter).
    fn cmdCommonEvent(self: *Interpreter) bool {
        const ce_id: i32 = @intCast(self.pInt(self.currentCommand().?, 0, 0));
        const f = self.db.get("data/CommonEvents.json") orelse return true;
        const ces = f.value.arrayItems();
        if (ce_id <= 0 or ce_id >= ces.len) {
            log.event(.mv, .warn, "common event {d} not found — skipped", .{ce_id});
            return true;
        }
        const ce = ces[@intCast(ce_id)];
        if (ce == .null) return true;
        const list_v = ce.get("list") orelse return true;
        const list = self.getOrParseCommandCache(ce_id, list_v);
        if (list.len == 0) return true;
        const event_id: i32 = if (self.isOnCurrentMap()) self.event_id else 0;
        log.detail(.mv, "common event {d} ('{s}') → child interpreter", .{ ce_id, ce.getString("name") orelse "?" });
        self.setupChild(list, event_id) catch {};
        return true;
    }

    /// 119 Jump to Label.
    fn cmdJumpToLabel(self: *Interpreter) bool {
        self.jumpToLabelName(self.pStr(self.currentCommand().?, 0, ""));
        return true;
    }

    /// 413 Repeat Above.
    fn cmdRepeatAbove(self: *Interpreter) bool {
        const indent = self.currentCommand().?.indent;
        while (self.index > 0) {
            self.index -= 1;
            if (self.list[self.index].indent == indent) break;
        }
        return true;
    }

    // =================================================================
    // Data commands (121-124, 357)
    // =================================================================

    fn cmdControlSwitches(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const first = self.pInt(cmd, 0, 1);
        const last = self.pInt(cmd, 1, first);
        const on = self.pInt(cmd, 2, 0) == 0;
        var i = @max(first, 1);
        while (i <= last) : (i += 1) {
            self.game.switches.setValue(@intCast(i), on);
        }
        log.detail(.mv, "control switches: {d}..{d} = {s}", .{ first, last, if (on) "ON" else "OFF" });
        return true;
    }

    fn cmdControlVariables(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const first = @max(self.pInt(cmd, 0, 1), 1);
        const last = self.pInt(cmd, 1, first);
        const op: state_op = @enumFromInt(@as(i64, self.pInt(cmd, 2, 0)));
        const operand_kind = self.pInt(cmd, 3, 0);

        switch (operand_kind) {
            0 => { // constant
                const v = self.pInt(cmd, 4, 0);
                var i = first;
                while (i <= last) : (i += 1) self.operateVariable(@intCast(i), op, v);
            },
            1 => { // variable
                const v = self.game.variables.value(@intCast(@max(self.pInt(cmd, 4, 1), 1)));
                var i = first;
                while (i <= last) : (i += 1) self.operateVariable(@intCast(i), op, v);
            },
            2 => { // random [min, max]
                const lo = self.pInt(cmd, 4, 0);
                const hi = self.pInt(cmd, 5, 0);
                const span = @max(hi - lo + 1, 1);
                var i = first;
                while (i <= last) : (i += 1) {
                    const r = @mod(self.rng.next(), @as(u64, @intCast(@max(span, 1)))) + @as(u64, @intCast(@max(lo, 0)));
                    self.operateVariable(@intCast(i), op, @intCast(r));
                }
            },
            3 => { // game data
                const v = self.gameDataOperand(@intCast(self.pInt(cmd, 4, 0)), self.pInt(cmd, 5, 0), self.pInt(cmd, 6, 0));
                var i = first;
                while (i <= last) : (i += 1) self.operateVariable(@intCast(i), op, v);
            },
            4 => {
                // The balloon sheet is one of two authored string literals,
                // not an arbitrary expression or a filesystem path.
                const expr = std.mem.trim(u8, self.pStr(cmd, 4, ""), " \t\r\n");
                if (first == balloons.sheet_variable and first == last and self.pInt(cmd, 2, 0) == 0 and expr.len >= 2) {
                    const quote = expr[0];
                    if ((quote == '\'' or quote == '"') and expr[expr.len - 1] == quote) {
                        if (balloons.Sheet.fromName(expr[1 .. expr.len - 1])) |sheet| {
                            self.game.variables.setBalloonSheet(sheet);
                            return true;
                        }
                    }
                }
                self.noteSkippedPluginOnce("script-operand");
            },
            else => {},
        }
        return true;
    }

    /// gameDataOperand (the census's subset).
    fn gameDataOperand(self: *Interpreter, kind: i64, p1: i64, p2: i64) i64 {
        switch (kind) {
            0 => return self.game.party.numItems(@intCast(p1)),
            1 => return self.game.party.numWeapons(@intCast(p1)),
            2 => return self.game.party.numArmors(@intCast(p1)),
            3 => { // Actor: level/exp/hp/mp/param
                const a = self.game.actors.actor(@intCast(p1)) orelse return 0;
                return switch (p2) {
                    0 => a.level,
                    1 => a.exp,
                    2 => a.hp,
                    3 => a.mp,
                    4...11 => a.param(@intCast(p2 - 4)),
                    else => 0,
                };
            },
            5 => { // M8: Enemy HP / MP (battle context)
                if (!self.game.troop.in_battle) return 0;
                const idx = p1;
                if (idx < 0 or idx >= self.game.troop.enemies.items.len) return 0;
                const e = self.game.troop.enemies.items[@intCast(idx)];
                return switch (p2) {
                    0 => e.hp,
                    1 => e.mp,
                    2 => @intFromFloat(@floor(e.hpRate() * 100)),
                    3 => @intFromFloat(@floor(e.mpRate() * 100)),
                    4 => e.tp,
                    else => 0,
                };
            },
            6 => { // Party member actor id
                const members = self.game.party.members.items;
                if (p1 >= 0 and p1 < members.len) return members[@intCast(p1)];
                return 0;
            },
            7 => { // Other
                return switch (p1) {
                    0 => @intCast(self.game.map.map_id),
                    1 => @intCast(self.game.party.members.items.len),
                    2 => self.game.party.gold,
                    3 => @intCast(self.game.party.steps),
                    4 => @intCast(self.game.frame_count_global / 60), // playtime
                    5 => @intCast(self.game.timer.frames / 60),
                    6 => self.game.system.save_count,
                    7 => self.game.system.battle_count,
                    8 => self.game.system.win_count,
                    9 => self.game.system.escape_count,
                    else => 0,
                };
            },
            else => return 0,
        }
    }

    fn operateVariable(self: *Interpreter, id: usize, op: state_op, value: i64) void {
        const old = self.game.variables.value(id);
        const next: i64 = switch (op) {
            .set => value,
            .add => old + value,
            .sub => old - value,
            .mul => old * value,
            .div => if (value == 0) 0 else @divTrunc(old, value),
            .mod => if (value == 0) 0 else @rem(old, value),
        };
        self.game.variables.setValue(id, next);
    }

    fn cmdControlSelfSwitch(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        if (self.event_id > 0) {
            const ch = self.pStr(cmd, 0, "A");
            const on = self.pInt(cmd, 1, 0) == 0;
            self.game.self_switches.setValue(self.map_id, self.event_id, ch, on);
            log.detail(.mv, "self switch [{d},{d},{s}] = {s}", .{ self.map_id, self.event_id, ch, if (on) "ON" else "OFF" });
        }
        return true;
    }

    /// 357 Control Self Variables (OMORI).
    fn cmdControlSelfVariables(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        if (self.event_id <= 0) return true;
        const first = @max(self.pInt(cmd, 0, 1), 1);
        const last = self.pInt(cmd, 1, first);
        const op: state_op = @enumFromInt(@as(i64, self.pInt(cmd, 2, 0)));
        const operand_kind = self.pInt(cmd, 3, 0);
        const ch_buf = [_]u8{};
        _ = ch_buf;
        var name_buf: [24]u8 = undefined;
        const ch = std.fmt.bufPrint(&name_buf, "{d}", .{self.pInt(cmd, 4, 0)}) catch "0";
        const value: i64 = switch (operand_kind) {
            0 => self.pInt(cmd, 4, 0),
            1 => self.game.variables.value(@intCast(@max(self.pInt(cmd, 4, 1), 1))),
            5 => self.game.self_variables.value(self.map_id, self.event_id, ch),
            else => blk: {
                self.noteSkippedPluginOnce("self-var-operand");
                break :blk 0;
            },
        };
        var i = first;
        while (i <= last) : (i += 1) {
            var key_buf: [24]u8 = undefined;
            const key = std.fmt.bufPrint(&key_buf, "{d}", .{i}) catch continue;
            const old = self.game.self_variables.value(self.map_id, self.event_id, key);
            const next: i64 = switch (op) {
                .set => value,
                .add => old + value,
                .sub => old - value,
                .mul => old * value,
                .div => if (value == 0) 0 else @divTrunc(old, value),
                .mod => if (value == 0) 0 else @rem(old, value),
            };
            self.game.self_variables.setValue(self.map_id, self.event_id, key, next);
        }
        return true;
    }

    fn cmdControlTimer(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        if (self.pInt(cmd, 0, 0) == 0) {
            self.game.timer.start(@intCast(self.pInt(cmd, 1, 0)));
        } else {
            self.game.timer.stop();
        }
        return true;
    }

    // =================================================================
    // Party / gold / items (125-129)
    // =================================================================

    fn operateValue(self: *Interpreter, cmd: map_mod.Command, op_idx: usize, ot_idx: usize, val_idx: usize) i64 {
        const operation = self.pInt(cmd, op_idx, 0);
        const operand_type = self.pInt(cmd, ot_idx, 0);
        const operand = self.pInt(cmd, val_idx, 0);
        const v = if (operand_type == 0) operand else self.game.variables.value(@intCast(@max(operand, 1)));
        return if (operation == 0) v else -v;
    }

    fn cmdChangeGold(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        self.game.party.gainGold(self.operateValue(cmd, 0, 1, 2));
        return true;
    }

    fn cmdChangeItems(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const id: i32 = @intCast(self.pInt(cmd, 0, 0));
        const count: i32 = @intCast(self.operateValue(cmd, 1, 2, 3));
        self.game.party.gainItem(id, count);
        return true;
    }

    const ItemKind = enum { item, armor };

    fn cmdChangeWeaponsOrArmors(self: *Interpreter, kind: ItemKind) bool {
        const cmd = self.currentCommand().?;
        const id: i32 = @intCast(self.pInt(cmd, 0, 0));
        const count: i32 = @intCast(self.operateValue(cmd, 1, 2, 3));
        if (kind == .item) self.game.party.gainWeapon(id, count) else self.game.party.gainArmor(id, count);
        return true;
    }

    fn cmdChangePartyMember(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const actor_id: i32 = @intCast(self.pInt(cmd, 0, 0));
        if (self.game.actors.actor(actor_id) == null) return true;
        if (self.pInt(cmd, 1, 0) == 0) { // add
            if (self.pInt(cmd, 2, 0) != 0) { // initialize
                if (self.game.actors.actor(actor_id)) |a| a.setup();
            }
            self.game.party.addActor(actor_id);
        } else {
            self.game.party.removeActor(actor_id);
        }
        return true;
    }

    // =================================================================
    // System flags / audio settings (132-137, 241-251, 243/244)
    // =================================================================

    const BgmFlagKind = enum { battle_bgm, victory_me };

    fn cmdSetBgmFlag(self: *Interpreter, kind: BgmFlagKind) bool {
        const cmd = self.currentCommand().?;
        const bgm = self.pBgm(cmd, 0);
        switch (kind) {
            .battle_bgm => self.game.system.battle_bgm = .{ .name = bgm.name, .volume = bgm.volume, .pitch = bgm.pitch, .pan = bgm.pan },
            .victory_me => self.game.system.victory_me = .{ .name = bgm.name, .volume = bgm.volume, .pitch = bgm.pitch, .pan = bgm.pan },
        }
        log.detail(.mv, "{s} = '{s}'", .{ if (kind == .battle_bgm) "battleBgm" else "victoryMe", bgm.name });
        return true;
    }

    const AccessFlagKind = enum { save, menu, encounter, formation };

    fn cmdAccessFlag(self: *Interpreter, kind: AccessFlagKind) bool {
        const cmd = self.currentCommand().?;
        const enable = self.pInt(cmd, 0, 0) != 0;
        switch (kind) {
            .save => self.game.system.save_enabled = enable,
            .menu => self.game.system.menu_enabled = enable,
            .encounter => self.game.system.encounter_enabled = enable,
            .formation => self.game.system.formation_enabled = enable,
        }
        log.detail(.mv, "system flag {s} = {s}", .{ @tagName(kind), if (enable) "enabled" else "disabled" });
        return true;
    }

    const AudioKind = enum { bgm, bgs, me, se };

    /// MV 241 — playBgm; OMORI's interpreter carries an optional second
    /// parameter (fade-in seconds; > 0 → AudioManager.fadeIn).
    fn cmdPlayAudio(self: *Interpreter, kind: AudioKind) bool {
        const cmd = self.currentCommand().?;
        const bgm = self.pBgm(cmd, 0);
        if (audio_mixer.instance) |m| {
            const vol: u32 = @intCast(std.math.clamp(bgm.volume, 0, 100));
            const pit: u32 = @intCast(std.math.clamp(bgm.pitch, 25, 400));
            switch (kind) {
                .bgm => m.playBgm(bgm.name, vol, pit),
                .bgs => m.playBgs(bgm.name, vol, pit),
                .me => m.playMe(bgm.name, vol, pit),
                .se => m.playSe(bgm.name, vol),
            }
            log.event(.audio, .note, "play{s}: '{s}' vol={d} pitch={d} pan={d} — mixed", .{
                @tagName(kind), bgm.name, bgm.volume, bgm.pitch, bgm.pan,
            });
            if (kind == .bgm) {
                const fade_s = self.pInt(cmd, 1, 0);
                if (fade_s > 0) {
                    const ms: u32 = @intCast(std.math.clamp(fade_s * 1000, 0, std.math.maxInt(u32)));
                    m.fadeInLoop(.bgm, ms);
                    log.event(.audio, .note, "fadeInBgm: {d} s", .{fade_s});
                }
            }
        } else {
            log.event(.audio, .note, "play{s}: '{s}' vol={d} pitch={d} pan={d} (no audio device)", .{
                @tagName(kind), bgm.name, bgm.volume, bgm.pitch, bgm.pan,
            });
        }
        return true;
    }

    fn cmdFadeoutAudio(self: *Interpreter, channel: []const u8) bool {
        const cmd = self.currentCommand().?;
        // MV commands 242/246 pass a duration in seconds to WebAudio.
        const seconds = self.pInt(cmd, 0, 0);
        const ms: u32 = @intCast(std.math.clamp(@as(i128, seconds) * 1000, 0, std.math.maxInt(u32)));
        if (audio_mixer.instance) |m| {
            if (std.mem.eql(u8, channel, "bgs")) m.stopBgs(ms) else m.stopBgm(ms);
        }
        log.event(.audio, .note, "fadeOut{s}: {d} seconds ({d} ms) — mixed", .{ channel, seconds, ms });
        return true;
    }

    /// MV 243 — `$gameSystem.saveBgm()`: snapshot the BGM channel into
    /// _savedBgm (the mixer keeps an owned copy; GameSystem borrows it).
    fn cmdSaveBgm(self: *Interpreter) bool {
        const saved = audio_mixer.saveBgmGlobal();
        self.game.system.saved_bgm = .{
            .name = saved.name,
            .volume = @intCast(saved.volume),
            .pitch = @intCast(saved.pitch),
            .pan = @intCast(saved.pan),
        };
        log.event(.audio, .note, "saveBgm: '{s}' vol={d} pitch={d} → $gameSystem._savedBgm", .{ saved.name, saved.volume, saved.pitch });
        return true;
    }

    /// MV 244 — `$gameSystem.replayBgm()`: replayBgm(_savedBgm).
    fn cmdResumeBgm(self: *Interpreter) bool {
        if (self.game.system.saved_bgm) |bgm| {
            audio_mixer.replayBgmGlobal(.{
                .name = bgm.name,
                .volume = @intCast(@max(bgm.volume, 0)),
                .pitch = @intCast(@max(bgm.pitch, 0)),
                .pan = @intCast(@max(bgm.pan, 0)),
            });
            log.event(.audio, .note, "replayBgm: '{s}' vol={d} pitch={d}", .{ bgm.name, bgm.volume, bgm.pitch });
        } else {
            log.event(.audio, .note, "replayBgm: no saved BGM — skip", .{});
        }
        return true;
    }

    fn cmdStopSe(self: *Interpreter) bool {
        _ = self;
        if (audio_mixer.instance) |m| m.stopSe();
        log.event(.audio, .note, "stopSe — mixed", .{});
        return true;
    }

    // =================================================================
    // Map / player (201-217, 283/284)
    // =================================================================

    fn cmdTransferPlayer(self: *Interpreter) bool {
        if (self.game.party.in_battle or self.game.message.isBusy()) return false;
        const cmd = self.currentCommand().?;
        var map_id: i64 = undefined;
        var x: i64 = undefined;
        var y: i64 = undefined;
        if (self.pInt(cmd, 0, 0) == 0) {
            map_id = self.pInt(cmd, 1, 0);
            x = self.pInt(cmd, 2, 0);
            y = self.pInt(cmd, 3, 0);
        } else {
            map_id = self.game.variables.value(@intCast(@max(self.pInt(cmd, 1, 1), 1)));
            x = self.game.variables.value(@intCast(@max(self.pInt(cmd, 2, 1), 1)));
            y = self.game.variables.value(@intCast(@max(self.pInt(cmd, 3, 1), 1)));
        }
        const direction: ?i32 = if (self.pInt(cmd, 4, 0) > 0) @intCast(self.pInt(cmd, 4, 0)) else null;
        self.game.player.reserveTransfer(@intCast(@max(map_id, 0)), @intCast(x), @intCast(y), direction, @intCast(self.pInt(cmd, 5, 0)));
        self.setWaitMode("transfer");
        self.index += 1;
        self.scene_changing = true; // Scene_Map performs the actual transfer
        return false;
    }

    fn cmdSetEventLocation(self: *Interpreter) bool {
        // Character positions are the movement milestone's state; the
        // command is state-logged.
        const cmd = self.currentCommand().?;
        log.detail(.mv, "setEventLocation: target={d} mode={d} (movement milestone)", .{ self.pInt(cmd, 0, 0), self.pInt(cmd, 1, 0) });
        return true;
    }

    fn cmdScrollMap(self: *Interpreter) bool {
        if (self.game.party.in_battle) return true;
        const cmd = self.currentCommand().?;
        if (self.game.map.isScrolling()) {
            self.setWaitMode("scroll");
            return false; // Retry this command after the earlier pan ends.
        }
        if (cmd.parameters.len < 3) return true;
        const direction = cmd.parameters[0].asFloat();
        if (direction != 2 and direction != 4 and direction != 6 and direction != 8) return true;
        self.game.map.startScriptedScroll(@intFromFloat(direction), cmd.parameters[1].asFloat(), cmd.parameters[2].asFloat());
        return true;
    }

    fn cmdSetMovementRoute(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const target: i64 = self.pInt(cmd, 0, 0);
        self.route_event_id = 0;
        self.route_wait_frames = 0;
        if (self.field_routes and self.isOnCurrentMap() and cmd.parameters.len > 1) {
            const id = if (target == 0) self.event_id else target;
            if (self.currentRawMap) |raw| {
                if (id > 0 and id < raw.events.items.len) {
                    if (self.game.map.currentPage(raw, @intCast(id), self.game)) |page| {
                        const event = &raw.events.items[@intCast(id)].?;
                        if (self.game.map.visual_routes.force(self.game.map.alloc, event, page, cmd.parameters[1])) {
                            if (cmd.parameters[1].getBool("wait", false)) {
                                self.setWaitMode("route");
                                self.route_event_id = @intCast(id);
                            }
                            return true;
                        }
                    }
                }
            }
        }
        // Unimplemented movement routes retain the existing bounded wait.
        var route_len: usize = 0;
        var route_wait = false;
        const ps = cmd.parameters;
        if (ps.len > 1) {
            route_wait = ps[1].getBool("wait", false);
            if (ps[1].get("list")) |l| route_len = l.arrayItems().len;
        }
        log.detail(.mv, "setMovementRoute: target={d} {d} move command(s) (movement milestone)", .{ target, route_len });
        if (route_wait) {
            self.setWaitMode("route");
            self.route_wait_frames = @intCast(@min(route_len, 60)); // bounded stand-in
        }
        return true;
    }

    fn cmdChangeTransparency(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        self.game.player.transparent = self.pInt(cmd, 0, 0) == 0;
        log.detail(.mv, "player transparent = {s}", .{if (self.game.player.transparent) "true" else "false"});
        return true;
    }

    fn cmdCharacterFx(self: *Interpreter, kind: []const u8) bool {
        const cmd = self.currentCommand().?;
        log.detail(.mv, "{s}: target={d} id={d} (sprite milestone)", .{ kind, self.pInt(cmd, 0, 0), self.pInt(cmd, 1, 0) });
        return true;
    }

    fn cmdBalloon(self: *Interpreter) bool {
        // The boot validator runs the interpreter without a live field clock.
        if (!self.field_routes or self.game.party.in_battle or !self.isOnCurrentMap()) return true;
        const cmd = self.currentCommand().?;
        const requested = self.pInt(cmd, 0, 0);
        const id = std.math.cast(i32, if (requested == 0) self.event_id else requested) orelse return true;
        if (id != -1) {
            const raw = self.currentRawMap orelse return true;
            if (id <= 0 or id >= raw.events.items.len or raw.events.items[@intCast(id)] == null or self.game.map.isEventErased(id)) return true;
        }
        const row = self.pInt(cmd, 1, 0);
        if (row < 1 or row > 15) return true;
        const sheet = self.game.variables.balloon_sheet orelse .standard;
        self.game.map.balloons.put(self.game.map.alloc, id, .{ .row = @intCast(row - 1), .sheet = sheet }) catch return true;
        if (self.pInt(cmd, 2, 0) != 0) {
            self.balloon_target = id;
            self.setWaitMode("balloon");
        }
        return true;
    }

    fn cmdEraseEvent(self: *Interpreter) bool {
        if (self.isOnCurrentMap() and self.event_id > 0) {
            self.game.map.eraseEvent(self.event_id);
        }
        return true;
    }

    fn cmdChangeFollowers(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        self.game.followers.visible = self.pInt(cmd, 0, 0) == 0;
        log.detail(.mv, "followers visible = {s}", .{if (self.game.followers.visible) "true" else "false"});
        return true;
    }

    fn cmdGatherFollowers(self: *Interpreter) bool {
        if (!self.game.party.in_battle) {
            self.game.followers.gathering = true;
            self.setWaitMode("gather");
        }
        return true;
    }

    fn cmdChangeBattleback(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        self.game.map.battleback1_name = self.pStr(cmd, 0, "");
        self.game.map.battleback2_name = self.pStr(cmd, 1, "");
        return true;
    }

    fn cmdChangeParallax(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        self.game.map.parallax_name = self.pStr(cmd, 0, "");
        self.game.map.parallax_loop_x = self.pInt(cmd, 1, 0) != 0;
        self.game.map.parallax_loop_y = self.pInt(cmd, 2, 0) != 0;
        self.game.map.parallax_sx = @intCast(self.pInt(cmd, 3, 0));
        self.game.map.parallax_sy = @intCast(self.pInt(cmd, 4, 0));
        return true;
    }

    // =================================================================
    // Screen (221-225, 230-236)
    // =================================================================

    const FadeKind = enum { out, in };

    fn cmdFade(self: *Interpreter, kind: FadeKind) bool {
        if (self.game.message.isBusy()) return false;
        const speed: i32 = 24; // Game_Interpreter.fadeSpeed()
        if (kind == .out) {
            self.game.screen.startFadeOut(speed);
        } else {
            self.game.screen.startFadeIn(speed);
        }
        self.wait(speed);
        self.index += 1;
        return false;
    }

    fn cmdTintScreen(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const arr = self.pArr(cmd, 0);
        var tone: [4]i32 = .{ 0, 0, 0, 0 };
        for (arr, 0..) |v, i| {
            if (i < 4) tone[i] = @intCast(v.asInt());
        }
        const duration: i32 = @intCast(self.pInt(cmd, 1, 0));
        self.game.screen.startTint(tone, duration);
        if (self.pInt(cmd, 2, 0) != 0) self.wait(duration);
        return true;
    }

    fn cmdFlashScreen(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const arr = self.pArr(cmd, 0);
        var color: [4]i32 = .{ 0, 0, 0, 0 };
        for (arr, 0..) |v, i| {
            if (i < 4) color[i] = @intCast(v.asInt());
        }
        const duration: i32 = @intCast(self.pInt(cmd, 1, 0));
        self.game.screen.startFlash(color, duration);
        if (self.pInt(cmd, 2, 0) != 0) self.wait(duration);
        return true;
    }

    fn cmdShakeScreen(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        self.game.screen.startShake(@intCast(self.pInt(cmd, 0, 3)), @intCast(self.pInt(cmd, 1, 5)), @intCast(self.pInt(cmd, 2, 0)));
        if (self.pInt(cmd, 3, 0) != 0) self.wait(@intCast(self.pInt(cmd, 2, 0)));
        return true;
    }

    fn cmdWait(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const frames: i32 = @intCast(self.pInt(cmd, 0, 0));
        self.wait(frames);
        log.detail(.mv, "wait {d} frame(s)", .{frames});
        return true;
    }

    fn cmdShowPicture(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const id: i32 = @intCast(self.pInt(cmd, 0, 0));
        var name = self.pStr(cmd, 1, "");
        // OMORI language picture suffix replacement (Text_Language_Processor command231 override)
        const original_name = name;
        name = self.replaceDefaultLanguageSuffix(name);
        defer if (name.ptr != original_name.ptr) self.alloc.free(name);
        const origin: i32 = @intCast(self.pInt(cmd, 2, 0));
        const x: i32 = @intCast(if (self.pInt(cmd, 3, 0) == 0) self.pInt(cmd, 4, 0) else self.game.variables.value(@intCast(@max(self.pInt(cmd, 4, 1), 1))));
        const y: i32 = @intCast(if (self.pInt(cmd, 3, 0) == 0) self.pInt(cmd, 5, 0) else self.game.variables.value(@intCast(@max(self.pInt(cmd, 5, 1), 1))));
        self.game.screen.showPicture(id, name, origin, x, y, @intCast(self.pInt(cmd, 6, 100)), @intCast(self.pInt(cmd, 7, 100)), @intCast(self.pInt(cmd, 8, 255)), @intCast(self.pInt(cmd, 9, 0)));
        return true;
    }

    /// `_en` → `_<current language>` on picture names (the OMORI override).
    fn replaceDefaultLanguageSuffix(self: *Interpreter, name: []const u8) []const u8 {
        const default_suffix = "_en";
        if (std.mem.endsWith(u8, name, default_suffix)) {
            const base_len = name.len - default_suffix.len;
            const replacement = std.fmt.allocPrint(self.alloc, "{s}_{s}", .{ name[0..base_len], self.texts.language }) catch return name;
            return replacement;
        }
        return name;
    }

    fn cmdMovePicture(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const id: i32 = @intCast(self.pInt(cmd, 0, 0));
        const x: i32 = @intCast(if (self.pInt(cmd, 3, 0) == 0) self.pInt(cmd, 4, 0) else self.game.variables.value(@intCast(@max(self.pInt(cmd, 4, 1), 1))));
        const y: i32 = @intCast(if (self.pInt(cmd, 3, 0) == 0) self.pInt(cmd, 5, 0) else self.game.variables.value(@intCast(@max(self.pInt(cmd, 5, 1), 1))));
        self.game.screen.movePicture(id, @intCast(self.pInt(cmd, 2, 0)), x, y, @intCast(self.pInt(cmd, 6, 100)), @intCast(self.pInt(cmd, 7, 100)), @intCast(self.pInt(cmd, 8, 255)), @intCast(self.pInt(cmd, 9, 0)), @intCast(self.pInt(cmd, 10, 0)));
        if (self.pInt(cmd, 11, 0) != 0) self.wait(@intCast(self.pInt(cmd, 10, 0)));
        return true;
    }

    fn cmdRotatePicture(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        self.game.screen.rotatePicture(@intCast(self.pInt(cmd, 0, 0)), @intCast(self.pInt(cmd, 1, 0)));
        return true;
    }

    fn cmdTintPicture(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const duration: i32 = @intCast(self.pInt(cmd, 2, 0));
        log.detail(.mv, "tintPicture id={d} dur={d} (sprite milestone applies)", .{ self.pInt(cmd, 0, 0), duration });
        if (self.pInt(cmd, 3, 0) != 0) self.wait(duration);
        return true;
    }

    fn cmdErasePicture(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        self.game.screen.erasePicture(@intCast(self.pInt(cmd, 0, 0)));
        return true;
    }

    fn cmdWeather(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const kind_names = [_][]const u8{ "none", "rain", "storm", "snow", "petals", "leaves" };
        const value: json.Value = if (cmd.parameters.len > 0) cmd.parameters[0] else .null;
        var kind: []const u8 = "none";
        if (value == .string) {
            for (kind_names) |candidate| {
                if (std.mem.eql(u8, candidate, value.string)) {
                    kind = candidate;
                    break;
                }
            }
        } else {
            const index = self.pInt(cmd, 0, 0);
            if (index >= 0 and index < kind_names.len) kind = kind_names[@intCast(index)];
        }
        self.game.screen.changeWeather(kind, @intCast(self.pInt(cmd, 1, 0)), @intCast(self.pInt(cmd, 2, 0)));
        if (self.pInt(cmd, 3, 0) != 0) self.wait(@intCast(self.pInt(cmd, 2, 0)));
        return true;
    }

    // =================================================================
    // Actors (311-322)
    // =================================================================

    /// iterateActorEx: fixed id (0 → party all, n → actor n) or variable.
    fn forEachActorEx(self: *Interpreter, cmd: map_mod.Command, body: fn (self: *Interpreter, actor: *game_mod.GameActor, ctx: ActorCtx) void, ctx: ActorCtx) void {
        const mode = self.pInt(cmd, 0, 0);
        const value = self.pInt(cmd, 1, 0);
        if (mode == 0) {
            if (value == 0) {
                for (self.game.party.members.items) |m| {
                    if (self.game.actors.actor(m)) |a| body(self, a, ctx);
                }
            } else if (self.game.actors.actor(@intCast(value))) |a| {
                body(self, a, ctx);
            }
        } else {
            const vid: usize = @intCast(@max(value, 1));
            const actor_id = self.game.variables.value(vid);
            if (self.game.actors.actor(@intCast(actor_id))) |a| body(self, a, ctx);
        }
    }

    const ActorCtx = struct {
        i0: i64 = 0,
        i1: i64 = 0,
        i2: i64 = 0,
        i3: i64 = 0,
    };

    const HpMpKind = enum { hp, mp };

    fn cmdChangeHpMp(self: *Interpreter, kind: HpMpKind) bool {
        const cmd = self.currentCommand().?;
        const value = self.operateValue(cmd, 2, 3, 4);
        const ctx = ActorCtx{ .i0 = value, .i1 = self.pInt(cmd, 5, 0) };
        if (kind == .hp) {
            self.forEachActorEx(cmd, actorChangeHp, ctx);
        } else {
            self.forEachActorEx(cmd, actorChangeMp, ctx);
        }
        return true;
    }

    fn actorChangeHp(self: *Interpreter, actor: *game_mod.GameActor, ctx: ActorCtx) void {
        _ = self;
        // MV changeHp: clamp so allowDeath=false keeps 1 hp.
        var v = ctx.i0;
        if (ctx.i1 == 0 and @as(i64, actor.hp) <= -v) {
            v = @as(i64, 1) - actor.hp;
        }
        actor.gainHp(v);
    }

    fn actorChangeMp(self: *Interpreter, actor: *game_mod.GameActor, ctx: ActorCtx) void {
        _ = self;
        actor.gainMp(ctx.i0);
    }

    fn cmdChangeState(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        log.detail(.mv, "changeState: actor-spec={d}/{d} op={d} state={d} (states: battle milestone)", .{
            self.pInt(cmd, 0, 0), self.pInt(cmd, 1, 0), self.pInt(cmd, 2, 0), self.pInt(cmd, 3, 0),
        });
        return true;
    }

    fn cmdRecoverAll(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const ctx = ActorCtx{};
        _ = ctx;
        const mode = self.pInt(cmd, 0, 0);
        const value = self.pInt(cmd, 1, 0);
        if (mode == 0) {
            if (value == 0) {
                for (self.game.party.members.items) |m| {
                    if (self.game.actors.actor(m)) |a| a.recoverAll();
                }
            } else if (self.game.actors.actor(@intCast(value))) |a| {
                a.recoverAll();
            }
        } else if (self.game.actors.actor(@intCast(self.game.variables.value(@intCast(@max(value, 1)))))) |a| {
            a.recoverAll();
        }
        return true;
    }

    fn cmdChangeExp(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const value = self.operateValue(cmd, 2, 3, 4);
        const ctx = ActorCtx{ .i0 = value };
        self.forEachActorEx(cmd, actorChangeExp, ctx);
        return true;
    }

    fn actorChangeExp(self: *Interpreter, actor: *game_mod.GameActor, ctx: ActorCtx) void {
        _ = self;
        actor.changeExp(actor.exp + ctx.i0);
    }

    fn cmdChangeLevel(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const value = self.operateValue(cmd, 2, 3, 4);
        const ctx = ActorCtx{ .i0 = value };
        self.forEachActorEx(cmd, actorChangeLevel, ctx);
        return true;
    }

    fn actorChangeLevel(self: *Interpreter, actor: *game_mod.GameActor, ctx: ActorCtx) void {
        _ = self;
        actor.changeLevel(actor.level + @as(i32, @intCast(ctx.i0)));
    }

    fn cmdChangeParam(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const value = self.operateValue(cmd, 3, 4, 5);
        const ctx = ActorCtx{ .i0 = self.pInt(cmd, 2, 0), .i1 = value };
        self.forEachActorEx(cmd, actorAddParam, ctx);
        return true;
    }

    fn actorAddParam(self: *Interpreter, actor: *game_mod.GameActor, ctx: ActorCtx) void {
        _ = self;
        actor.addParam(@intCast(ctx.i0), ctx.i1);
    }

    fn cmdChangeSkill(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const ctx = ActorCtx{ .i0 = self.pInt(cmd, 3, 0), .i1 = self.pInt(cmd, 2, 0) };
        self.forEachActorEx(cmd, actorChangeSkill, ctx);
        return true;
    }

    fn actorChangeSkill(self: *Interpreter, actor: *game_mod.GameActor, ctx: ActorCtx) void {
        _ = self;
        if (ctx.i1 == 0) {
            actor.learnSkill(@intCast(ctx.i0));
        } else {
            actor.forgetSkill(@intCast(ctx.i0));
        }
    }

    fn cmdChangeEquip(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const actor_id = std.math.cast(i32, self.pInt(cmd, 0, 0)) orelse return true;
        const etype = std.math.cast(i32, self.pInt(cmd, 1, 0)) orelse return true;
        const item_id = std.math.cast(i32, self.pInt(cmd, 2, 0)) orelse return true;
        const actor = self.game.actors.actor(actor_id) orelse return true;
        const changed = self.changeActorEquipById(actor, etype, item_id);
        log.detail(.mv, "changeEquipById: actor={d} type={d} item={d} accepted={}", .{ actor_id, etype, item_id, changed });
        return true;
    }

    fn databaseEntry(self: *Interpreter, path: []const u8, id: i32) ?json.Value {
        const file = self.db.get(path) orelse return null;
        const items = file.value.arrayItems();
        if (id <= 0 or id >= items.len or items[@intCast(id)] == .null) return null;
        return items[@intCast(id)];
    }

    fn hasEquipTrait(data: json.Value, code: i64, id: i64) bool {
        const traits = if (data.get("traits")) |value| value.arrayItems() else return false;
        for (traits) |trait| {
            if (trait.getInt("code", 0) == code and trait.getInt("dataId", -1) == id) return true;
        }
        return false;
    }

    fn actorEquipTrait(self: *Interpreter, actor: *game_mod.GameActor, slot: usize, replacement: json.Value, code: i64, id: i64) bool {
        const sources = [_]struct { path: []const u8, id: i32 }{
            .{ .path = "data/Actors.json", .id = actor.actor_id },
            .{ .path = "data/Classes.json", .id = actor.class_id },
        };
        for (sources) |source| {
            if (self.databaseEntry(source.path, source.id)) |data| if (hasEquipTrait(data, code, id)) return true;
        }
        for (actor.equips.items, 0..) |equip, index| {
            const data = if (index == slot) replacement else self.databaseEntry(if (equip.is_weapon) "data/Weapons.json" else "data/Armors.json", equip.item_id) orelse continue;
            if (hasEquipTrait(data, code, id)) return true;
        }
        var states = actor.states.keyIterator();
        while (states.next()) |state_id| {
            if (self.databaseEntry("data/States.json", state_id.*)) |data| if (hasEquipTrait(data, code, id)) return true;
        }
        return false;
    }

    /// MV changeEquipById: etype is one-based; trade with inventory,
    /// then refresh parameters. The native actor's declared slots bound
    /// this path; unsupported slot layouts are never synthesized.
    fn changeActorEquipById(self: *Interpreter, actor: *game_mod.GameActor, etype: i32, item_id: i32) bool {
        if (etype <= 0 or item_id < 0) return false;
        const slot: usize = @intCast(etype - 1);
        if (slot >= actor.equips.items.len) return false;
        const weapon = actor.equips.items[slot].is_weapon;
        const path = if (weapon) "data/Weapons.json" else "data/Armors.json";
        if (item_id > 0) {
            const item = self.databaseEntry(path, item_id) orelse return false;
            if (item.getInt("etypeId", 0) != etype) return false;
            const allowed = self.actorEquipTrait(actor, slot, item, if (weapon) 51 else 52, item.getInt(if (weapon) "wtypeId" else "atypeId", 0));
            if (!allowed or self.actorEquipTrait(actor, slot, item, 54, etype)) return false;
        }
        const old = actor.equips.items[slot].item_id;
        if (old == item_id) return true;
        const party = &self.game.party;
        if (item_id > 0 and (if (weapon) party.numWeapons(item_id) else party.numArmors(item_id)) <= 0) return false;
        if (old > 0) {
            if (weapon) party.gainWeapon(old, 1) else party.gainArmor(old, 1);
        }
        if (item_id > 0) {
            if (weapon) party.gainWeapon(item_id, -1) else party.gainArmor(item_id, -1);
        }
        actor.equips.items[slot].item_id = item_id;
        actor.gainHp(0);
        actor.gainMp(0);
        return true;
    }

    fn cmdChangeActorImages(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        if (self.game.actors.actor(@intCast(self.pInt(cmd, 0, 0)))) |actor| {
            actor.setCharacterImage(self.pStr(cmd, 1, ""), @intCast(std.math.clamp(self.pInt(cmd, 2, 0), 0, 7))) catch {};
        }
        return true;
    }

    // =================================================================
    // M8 — battle commands (301, 331-337, 339, 340, 342, 601-603)
    // =================================================================

    /// 301 Battle Processing — the field scene opens the interactive
    /// battle, then returns its result to this exact interpreter (which
    /// may be a common-event child) for branches 601/602/603.
    fn cmdBattleProcessing(self: *Interpreter) bool {
        if (self.game.party.in_battle) return true; // no nested battles
        const cmd = self.currentCommand().?;

        // Resolve the troop id (0 direct / 1 variable / 2 random
        // encounter from the map's encounter list).
        var troop_id: i32 = 0;
        switch (self.pInt(cmd, 0, 0)) {
            0 => troop_id = @intCast(self.pInt(cmd, 1, 0)),
            1 => troop_id = @intCast(self.game.variables.value(@intCast(@max(self.pInt(cmd, 1, 1), 1)))),
            else => troop_id = self.makeEncounterTroopId(),
        }

        const f = self.db.get("data/Troops.json");
        const troops = if (f) |ff| ff.value.arrayItems() else &[_]json.Value{};
        if (troop_id <= 0 or troop_id >= troops.len or troops[@intCast(troop_id)] == .null) {
            log.event(.mv, .warn, "battle processing: troop {d} not found — skipped", .{troop_id});
            return true;
        }

        log.event(.mv, .note, "battle processing: troop {d} ('{s}') — native battle begins", .{
            troop_id, troops[@intCast(troop_id)].getString("name") orelse "?",
        });
        if (self.currentRawMap) |raw| {
            if (raw.encounter_list.len > 0) {
                self.game.player.encounter_count = encounter_mod.rollCountdown(raw.encounter_step, self.rng.random());
            }
        }

        if (self.scene_battles) {
            self.scene_battle = .{
                .troop_id = troop_id,
                .can_escape = self.pInt(cmd, 2, 0) != 0,
                .can_lose = self.pInt(cmd, 3, 0) != 0,
                .indent = cmd.indent,
            };
            self.setWaitMode("battle");
            return true;
        }

        // BattleManager.setup + run (deterministic, seeded).
        var mgr = battle_mod.Manager.init(
            self.alloc,
            self.db,
            self.game,
            &self.game.troop,
            self.rng.random().int(u64),
        );
        defer mgr.deinit();
        mgr.setup(troop_id, self.pInt(cmd, 2, 0) != 0, self.pInt(cmd, 3, 0) != 0);
        const result = mgr.run();
        self.battle_branch.put(cmd.indent, @as(u8, @intCast(@intFromEnum(result)))) catch {};

        log.event(.mv, .note, "battle processing complete: result={s} (branch 601/602/603 at indent {d})", .{
            @tagName(result), cmd.indent,
        });
        return true;
    }

    /// makeEncounterTroopId — weighted pick from the current map's
    /// encounter list (the player's next random encounter).
    fn makeEncounterTroopId(self: *Interpreter) i32 {
        const raw = self.currentRawMap orelse return 0;
        const player = &self.game.player;
        const region = self.game.map.encounterRegion(raw, player.x, player.y, false);
        return encounter_mod.selectTroop(raw.encounter_list, region, self.rng.random()) orelse 0;
    }

    /// 601/602/603 — battle branch (If Win / If Escape / If Lose).
    fn cmdBattleBranch(self: *Interpreter, want: u8) bool {
        const indent = self.currentCommand().?.indent;
        const got = self.battle_branch.get(indent);
        if (got == null or got.? != want) {
            self.skipBranch();
        }
        return true;
    }

    /// iterateEnemyIndex — param 0 = enemy index; -1 = all.
    fn eachEnemy(self: *Interpreter, index_param: i64, ctx: anytype, comptime f: fn (@TypeOf(ctx), *battle_mod.GameEnemy) void) void {
        if (index_param < 0) {
            for (self.game.troop.enemies.items) |e| f(ctx, e);
        } else if (index_param < self.game.troop.enemies.items.len) {
            f(ctx, self.game.troop.enemies.items[@intCast(index_param)]);
        }
    }

    /// 331 Change Enemy HP.
    fn cmdEnemyHp(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const value = self.operateValue(cmd, 1, 2, 3);
        const allow_death = self.pInt(cmd, 4, 0) != 0;
        const Ctx = struct {
            itp: *Interpreter,
            value: i64,
            allow_death: bool,
        };
        self.eachEnemy(self.pInt(cmd, 0, -1), Ctx{ .itp = self, .value = value, .allow_death = allow_death }, struct {
            fn apply(c: Ctx, e: *battle_mod.GameEnemy) void {
                const before = e.hp;
                e.hp = std.math.clamp(e.hp + @as(i32, @intCast(c.value)), 0, e.mhp());
                if (e.hp == 0 and before > 0 and !c.allow_death) e.hp = 1;
                if (e.hp == 0 and before > 0) {
                    log.detail(.mv, "enemy {d} '{s}' killed by command 331", .{ e.index, e.name() });
                }
            }
        }.apply);
        return true;
    }

    /// 332 Change Enemy MP.
    fn cmdEnemyMp(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const value = self.operateValue(cmd, 1, 2, 3);
        const Ctx = struct { v: i64 };
        self.eachEnemy(self.pInt(cmd, 0, -1), Ctx{ .v = value }, struct {
            fn apply(c: Ctx, e: *battle_mod.GameEnemy) void {
                e.gainMp(@intCast(c.v));
            }
        }.apply);
        return true;
    }

    /// 342 Change Enemy TP (OMORI: unused, still honored).
    fn cmdEnemyTp(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const value = self.operateValue(cmd, 1, 2, 3);
        const Ctx = struct { v: i64 };
        self.eachEnemy(self.pInt(cmd, 0, -1), Ctx{ .v = value }, struct {
            fn apply(c: Ctx, e: *battle_mod.GameEnemy) void {
                e.gainTp(@intCast(c.v));
            }
        }.apply);
        return true;
    }

    /// 333 Change Enemy State (0 add / 1 remove).
    fn cmdEnemyState(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const add = self.pInt(cmd, 1, 0) == 0;
        const state_id = self.pInt(cmd, 2, 0);
        const Ctx = struct {
            itp: *Interpreter,
            add: bool,
            sid: i32,
        };
        self.eachEnemy(self.pInt(cmd, 0, -1), Ctx{ .itp = self, .add = add, .sid = @intCast(state_id) }, struct {
            fn apply(c: Ctx, e: *battle_mod.GameEnemy) void {
                if (c.add) {
                    e.addState(c.sid);
                } else {
                    e.removeState(c.sid);
                }
                log.detail(.mv, "enemy {d} '{s}' {s}state {d}", .{ e.index, e.name(), if (c.add) "+" else "-", c.sid });
            }
        }.apply);
        return true;
    }

    /// 334 Enemy Recover All.
    fn cmdEnemyRecoverAll(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const Ctx = struct {};
        self.eachEnemy(self.pInt(cmd, 0, -1), Ctx{}, struct {
            fn apply(_: Ctx, e: *battle_mod.GameEnemy) void {
                e.recoverAll();
            }
        }.apply);
        return true;
    }

    /// 335 Enemy Appear.
    fn cmdEnemyAppear(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const Ctx = struct {};
        self.eachEnemy(self.pInt(cmd, 0, -1), Ctx{}, struct {
            fn apply(_: Ctx, e: *battle_mod.GameEnemy) void {
                e.appear();
                log.detail(.mv, "enemy {d} '{s}' appeared", .{ e.index, e.name() });
            }
        }.apply);
        self.game.troop.makeUniqueNames();
        return true;
    }

    /// 336 Enemy Transform.
    fn cmdEnemyTransform(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        const new_id = self.pInt(cmd, 1, 0);
        const Ctx = struct { id: i32 };
        self.eachEnemy(self.pInt(cmd, 0, -1), Ctx{ .id = @intCast(new_id) }, struct {
            fn apply(c: Ctx, e: *battle_mod.GameEnemy) void {
                e.transform(c.id);
            }
        }.apply);
        self.game.troop.makeUniqueNames();
        return true;
    }

    /// 337 Show Battle Animation — presentation layer (logged).
    fn cmdBattleAnimation(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        log.detail(.mv, "battle animation {d} (target {d}, mirror={d}) — presentation layer", .{
            self.pInt(cmd, 1, 0), self.pInt(cmd, 0, 0), self.pInt(cmd, 2, 0),
        });
        return true;
    }

    /// 340 Abort Battle.
    fn cmdAbortBattle(self: *Interpreter) bool {
        if (self.game.party.in_battle) {
            log.event(.mv, .note, "battle aborted by command 340", .{});
            self.game.party.in_battle = false;
            self.game.troop.in_battle = false;
        }
        return true;
    }

    // =================================================================
    // Scenes / script / plugin commands (302, 353, 355, 356)
    // =================================================================

    fn cmdShopProcessing(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        log.detail(.mv, "shop processing (purchaseOnly={d}) — scene push: scene milestone", .{self.pInt(cmd, 1, 0)});
        return true;
    }

    fn cmdGameOver(self: *Interpreter) bool {
        log.event(.mv, .note, "SceneManager.goto(Scene_Gameover)", .{});
        self.scene_changing = true;
        return true;
    }

    /// 355 Script (+ 655 continuation). NO JavaScript engine — instead a
    /// bounded mini-evaluator for the census's top statement forms:
    ///   var/let/const NAME = <expr>;
    ///   $gameVariables.setValue(ID, <expr>);
    ///   $gameSelfSwitches.setValue([MAP, EVENT, 'CH'], <expr>);
    ///   $gamePlayer.reserveTransfer(<expr>, <expr>, <expr>, <expr>, <expr>);
    ///   $gameScreen.startFadeIn/startFadeOut/startTint(<expr>);
    /// where <expr> ::= number | NAME | $gameVariables.value(ID) |
    ///                   [expr, expr, 'str'].
    /// Anything else logs-and-skips with per-pattern accounting (the same
    /// honesty contract as unknown command codes).
    fn cmdScript(self: *Interpreter) bool {
        const cmd = self.currentCommand().?;
        self.runScriptLine(self.pStr(cmd, 0, ""));
        while (self.nextEventCode() == 655) {
            self.index += 1;
            self.runScriptLine(self.pStr(self.currentCommand().?, 0, ""));
        }
        return true;
    }

    /// One script statement (see cmdScript).
    fn runScriptLine(self: *Interpreter, raw_line: []const u8) void {
        var line = std.mem.trim(u8, raw_line, " \t\r");
        // strip trailing // comment
        if (std.mem.indexOf(u8, line, "//")) |cpos| {
            line = std.mem.trim(u8, line[0..cpos], " \t");
        }
        if (line.len == 0) return;
        // strip trailing ;
        if (line[line.len - 1] == ';') line = line[0 .. line.len - 1];
        if (line.len == 0) return;

        // OMORI BASE's authored equipped skill must be available to the
        // native command picker (which currently lists learned skills).
        // Only this chained call and the four authored slots are handled.
        const actor_prefix = "$gameActors.actor(";
        if (std.mem.startsWith(u8, line, actor_prefix)) {
            if (std.mem.indexOf(u8, line, ").equipSkill(")) |method| {
                const actor_id = std.math.cast(i32, self.evalScriptExpr(line[actor_prefix.len..method]) orelse return) orelse return;
                var source = line[method + ").equipSkill(".len ..];
                if (!std.mem.endsWith(u8, source, ")")) return;
                source = source[0 .. source.len - 1];
                const args = self.splitArgs(source);
                defer self.freeArgs(args);
                if (args.len != 2) return;
                const slot = self.evalScriptExpr(args[0]) orelse return;
                const skill_id = std.math.cast(i32, self.evalScriptExpr(args[1]) orelse return) orelse return;
                if (slot < 0 or slot >= 4 or battle_mod.skillData(self.db, skill_id) == null) return;
                if (self.game.actors.actor(actor_id)) |actor| actor.learnSkill(skill_id);
                return;
            }
        }

        // Chained event calls have an inner parenthesis before the method.
        const event_prefix = "$gameMap.event(";
        if (std.mem.startsWith(u8, line, event_prefix)) {
            if (std.mem.indexOf(u8, line, ").setPosition(")) |method| {
                const event_id = self.evalScriptExpr(line[event_prefix.len..method]) orelse return;
                var args_src = line[method + ").setPosition(".len ..];
                if (std.mem.endsWith(u8, args_src, ")")) args_src = args_src[0 .. args_src.len - 1];
                const args = self.splitArgs(args_src);
                defer self.freeArgs(args);
                if (args.len == 2) {
                    const x = self.evalScriptExpr(args[0]) orelse return;
                    const y = self.evalScriptExpr(args[1]) orelse return;
                    self.setEventScriptPosition(event_id, x, y);
                    return;
                }
            }
        }

        // var NAME = EXPR;
        if (std.mem.startsWith(u8, line, "var ") or std.mem.startsWith(u8, line, "let ") or std.mem.startsWith(u8, line, "const ")) {
            var it = std.mem.tokenizeAny(u8, line[4..], " ");
            const name = it.next() orelse return;
            const rest = std.mem.trim(u8, it.rest(), " ");
            if (std.mem.startsWith(u8, rest, "=")) {
                const val = self.evalScriptExpr(std.mem.trim(u8, rest[1..], " ")) orelse {
                    self.noteSkippedPluginOnce("script:var-complex");
                    return;
                };
                const key = self.alloc.dupe(u8, name) catch return;
                const entry = self.script_vars.getOrPut(key) catch {
                    self.alloc.free(key);
                    return;
                };
                if (entry.found_existing) self.alloc.free(key);
                entry.value_ptr.* = val;
                return;
            }
            self.noteSkippedPluginOnce("script:var-decl");
            return;
        }

        // $gameXxx.call(...)
        if (std.mem.indexOfScalar(u8, line, '(')) |paren| {
            const func = std.mem.trim(u8, line[0..paren], " ");
            var args_src = line[paren + 1 ..];
            if (args_src.len > 0 and args_src[args_src.len - 1] == ')') args_src = args_src[0 .. args_src.len - 1];
            const args = self.splitArgs(args_src);
            defer self.freeArgs(args);

            if (std.mem.eql(u8, func, "$gameMap.randomPos")) {
                if (args.len == 2) {
                    const event_id = self.evalScriptExpr(args[0]) orelse return;
                    const region_id = self.evalScriptExpr(args[1]) orelse return;
                    self.randomizeEventPosition(event_id, region_id);
                    return;
                }
            } else if (std.mem.eql(u8, func, "$gameVariables.setValue")) {
                if (args.len == 2) {
                    const id = self.evalScriptExpr(args[0]) orelse 0;
                    const val = self.evalScriptExpr(args[1]) orelse 0;
                    if (id > 0) {
                        self.game.variables.setValue(@intCast(id), val);
                        log.detail(.mv, "script: variables[{d}] = {d}", .{ id, val });
                        return;
                    }
                }
            } else if (std.mem.eql(u8, func, "$gameSelfSwitches.setValue")) {
                if (args.len == 2) {
                    // args[0] like [map, event, 'A']
                    const key = parseSelfSwitchKey(args[0]) orelse {
                        self.noteSkippedPluginOnce("script:selfswitch-complex");
                        return;
                    };
                    const val = self.evalScriptExpr(args[1]) orelse 0;
                    self.game.self_switches.setValue(key.map, key.event, key.ch, val != 0);
                    log.detail(.mv, "script: selfSwitches[{d},{d},{s}] = {s}", .{ key.map, key.event, key.ch, if (val != 0) "ON" else "OFF" });
                    return;
                }
            } else if (std.mem.eql(u8, func, "$gamePlayer.reserveTransfer")) {
                if (args.len == 5) {
                    const map_id = self.evalScriptExpr(args[0]) orelse return;
                    const x = self.evalScriptExpr(args[1]) orelse 0;
                    const y = self.evalScriptExpr(args[2]) orelse 0;
                    const dir = self.evalScriptExpr(args[3]);
                    const fade = self.evalScriptExpr(args[4]) orelse 0;
                    self.game.player.reserveTransfer(@intCast(@max(map_id, 0)), @intCast(x), @intCast(y), if (dir) |d| @intCast(d) else null, @intCast(fade));
                    self.setWaitMode("transfer");
                    self.scene_changing = true;
                    log.detail(.mv, "script: reserveTransfer map {d} ({d},{d})", .{ map_id, x, y });
                    return;
                }
            } else if (std.mem.eql(u8, func, "$gameScreen.startFadeIn") or
                std.mem.eql(u8, func, "$gameScreen.startFadeOut"))
            {
                if (args.len == 1) {
                    const dur = self.evalScriptExpr(args[0]) orelse 24;
                    if (std.mem.endsWith(u8, func, "startFadeIn")) {
                        self.game.screen.startFadeIn(@intCast(dur));
                    } else {
                        self.game.screen.startFadeOut(@intCast(dur));
                    }
                    return;
                }
            } else if (std.mem.eql(u8, func, "$gameScreen.startTint")) {
                if (args.len == 2) {
                    var tone: [4]i32 = .{ 0, 0, 0, 0 };
                    // args[0]: [r, g, b, gray]
                    var arr = args[0];
                    if (arr.len > 1 and arr[0] == '[' and arr[arr.len - 1] == ']') {
                        arr = arr[1 .. arr.len - 1];
                        const parts = self.splitArgs(arr);
                        defer self.freeArgs(parts);
                        for (parts, 0..) |pv, i| {
                            if (i < 4) tone[i] = @intCast(self.evalScriptExpr(pv) orelse 0);
                        }
                    }
                    const dur = self.evalScriptExpr(args[1]) orelse 0;
                    self.game.screen.startTint(tone, @intCast(dur));
                    return;
                }
            }
        }
        self.noteSkippedPluginOnce("script:other");
    }

    fn setEventScriptPosition(self: *Interpreter, event_id: i64, x: i64, y: i64) void {
        const raw = self.currentRawMap orelse return;
        if (event_id <= 0 or event_id >= raw.events.items.len) return;
        if (x < std.math.minInt(i32) or x > std.math.maxInt(i32) or y < std.math.minInt(i32) or y > std.math.maxInt(i32)) return;
        if (raw.events.items[@intCast(event_id)]) |*event| {
            event.x = @intCast(x);
            event.y = @intCast(y);
            log.detail(.mv, "script: event {d} setPosition({d},{d})", .{ event_id, x, y });
        }
    }

    /// Archeia_CoreChanges/RegionRandomize: choose uniformly among tiles
    /// with the requested region, honoring the active Tiled map level.
    fn randomizeEventPosition(self: *Interpreter, event_id: i64, region_id: i64) void {
        const raw = self.currentRawMap orelse return;
        const width = if (self.game.map.tiled != null) self.game.map.width else raw.width;
        const height = if (self.game.map.tiled != null) self.game.map.height else raw.height;
        var candidates: usize = 0;
        var chosen_x: i32 = 0;
        var chosen_y: i32 = 0;
        var x: i32 = 0;
        while (x < width) : (x += 1) {
            var y: i32 = 0;
            while (y < height) : (y += 1) {
                const region: i32 = if (self.game.map.tiled != null)
                    self.game.map.tiledRegionId(x, y)
                else blk: {
                    const index: usize = @intCast((5 * height + y) * width + x);
                    break :blk if (index < raw.data.len) raw.data[index] else 0;
                };
                if (region != region_id) continue;
                candidates += 1;
                if (self.rng.random().uintLessThan(usize, candidates) == 0) {
                    chosen_x = x;
                    chosen_y = y;
                }
            }
        }
        if (candidates > 0) self.setEventScriptPosition(event_id, chosen_x, chosen_y);
    }

    /// Split top-level comma args (respecting [] and () nesting).
    fn splitArgs(self: *Interpreter, src: []const u8) [][]const u8 {
        var out: std.ArrayList([]const u8) = .empty;
        var depth: usize = 0;
        var start: usize = 0;
        var in_str: u8 = 0;
        for (src, 0..) |c, i| {
            if (in_str != 0) {
                if (c == in_str) in_str = 0;
                continue;
            }
            switch (c) {
                '\'', '"' => in_str = c,
                '[', '(' => depth += 1,
                ']', ')' => {
                    if (depth > 0) depth -= 1;
                },
                ',' => {
                    if (depth == 0) {
                        const piece = std.mem.trim(u8, src[start..i], " \t");
                        out.append(self.alloc, piece) catch {};
                        start = i + 1;
                    }
                },
                else => {},
            }
        }
        if (start <= src.len) {
            const piece = std.mem.trim(u8, src[start..], " \t");
            out.append(self.alloc, piece) catch {};
        }
        return out.toOwnedSlice(self.alloc) catch &.{};
    }

    fn freeArgs(self: *Interpreter, args: [][]const u8) void {
        self.alloc.free(args);
    }

    /// expr ::= number | NAME | $gameVariables.value(ID) | NAME.value(ID)
    fn evalScriptExpr(self: *Interpreter, expr: []const u8) ?i64 {
        const e = std.mem.trim(u8, expr, " \t");
        if (e.len == 0) return null;
        // number
        if (std.fmt.parseInt(i64, e, 10)) |n| {
            return n;
        } else |_| {}
        // negative number
        if (e[0] == '-') {
            if (std.fmt.parseInt(i64, e[1..], 10)) |n| {
                return -n;
            } else |_| {}
        }
        // $gameVariables.value(N)
        if (std.mem.endsWith(u8, e, ")")) {
            if (std.mem.indexOf(u8, e, ".value(")) |vp| {
                const head = std.mem.trim(u8, e[0..vp], " ");
                if (std.mem.eql(u8, head, "$gameVariables")) {
                    var inner = e[vp + 7 .. e.len - 1];
                    inner = std.mem.trim(u8, inner, " ");
                    const id = std.fmt.parseInt(i64, inner, 10) catch return null;
                    if (id > 0) return self.game.variables.value(@intCast(id));
                }
                return null;
            }
        }
        // bare local variable name
        if (std.mem.eql(u8, e, "this._eventId")) return self.event_id;
        if (self.script_vars.get(e)) |v| return v;
        // true/false
        if (std.mem.eql(u8, e, "true")) return 1;
        if (std.mem.eql(u8, e, "false")) return 0;
        return null;
    }

    /// 356 Plugin Command — dispatches the OMORI language pipeline
    /// (ShowMessage/AddChoice/ShowChoices), Wait, CallEvent; everything
    /// else logs-and-skips with per-name accounting.
    fn cmdPluginCommand(self: *Interpreter) bool {
        const raw = self.pStr(self.currentCommand().?, 0, "");
        var it = std.mem.splitScalar(u8, raw, ' ');
        const name = it.next() orelse "";
        if (name.len == 0) return true;

        if (std.mem.eql(u8, name, "StopPlayerMovement") or std.mem.eql(u8, name, "AllowPlayerMovement")) {
            self.game.temp.player_movement_stopped = std.mem.eql(u8, name, "StopPlayerMovement");
            log.detail(.mv, "player movement {s}", .{if (self.game.temp.player_movement_stopped) "stopped" else "allowed"});
            return true;
        } else if (std.mem.eql(u8, name, "ShowMessage")) {
            const code = it.next() orelse "";
            return self.cmdShowLanguageMessage(code);
        } else if (std.mem.eql(u8, name, "AddChoice")) {
            const code = it.next() orelse "";
            const label = it.next() orelse "";
            return self.cmdAddLanguageChoice(code, label);
        } else if (std.mem.eql(u8, name, "ShowChoices")) {
            const cancel = it.next();
            if (self.game.message.isBusy()) return false;
            self.setupLanguageChoices(cancel);
            self.index += 1;
            self.setWaitMode("message");
            return false;
        } else if (std.mem.eql(u8, name, "Wait") or std.mem.eql(u8, name, "WAIT") or std.mem.eql(u8, name, "wait")) {
            const frames = it.next() orelse "0";
            self.wait(std.fmt.parseInt(i32, frames, 10) catch 0);
            return true;
        } else if (std.mem.eql(u8, name, "CallEvent")) {
            // YEP_CallEvent: "<id>, PAGE n, MAP m"
            const rest = std.mem.trim(u8, it.rest(), " ");
            return self.cmdCallEvent(rest);
        } else if (std.mem.eql(u8, name, "ChangeLanguage")) {
            // handled at the language layer (a fresh boot-time concern)
            return true;
        }
        self.noteSkippedPluginOnce(name);
        return true;
    }

    /// ShowMessage <file.message_key> — the OMORI message pipeline.
    fn cmdShowLanguageMessage(self: *Interpreter, code: []const u8) bool {
        if (self.game.message.isBusy()) return false;
        const msg = &self.game.message;
        msg.clear();
        const data = self.texts.getMessageData(code) catch null;
        if (data) |d| {
            msg.setFaceImage(d.faceset, d.faceindex);
            msg.setBackground(d.background);
            msg.setPositionType(d.position);
            msg.add(d.text);
            self.last_message = d;
            log.event(.mv, .note, "ShowMessage '{s}': faceset='{s}' text=\"{s}\"", .{
                code, d.faceset, d.text[0..@min(d.text.len, 60)],
            });
        } else {
            log.event(.mv, .warn, "ShowMessage '{s}': message data missing", .{code});
        }
        // commandShowLanguageMessage: trailing 102/103/104/356-ShowChoices
        const nxt = self.nextEventCode();
        if (nxt == 102) {
            self.index += 1;
            self.setupChoices(self.currentCommand().?);
        } else if (nxt == 356) {
            const txt = self.pStr(self.list[self.index + 1], 0, "");
            var it2 = std.mem.splitScalar(u8, txt, ' ');
            const n2 = it2.next() orelse "";
            if (std.mem.eql(u8, n2, "ShowChoices")) {
                self.index += 1;
                self.setupLanguageChoices(it2.next());
            }
        }
        self.index += 1;
        self.setWaitMode("message");
        return false;
    }

    fn cmdAddLanguageChoice(self: *Interpreter, code: []const u8, label: []const u8) bool {
        const data = self.texts.getMessageData(code) catch null;
        if (data) |d| {
            self.choices.append(self.alloc, .{ d.text, label }) catch {};
            log.detail(.mv, "AddChoice '{s}' label='{s}'", .{ code, label });
        }
        return true;
    }

    /// YEP_CallEvent "<eventId>, PAGE n, MAP m" — runs that page's list
    /// as a child interpreter (same-map pages only until map cache grows).
    fn cmdCallEvent(self: *Interpreter, spec: []const u8) bool {
        var event_id: i64 = 0;
        var page_no: i64 = 1;
        var map_id: ?i64 = null;

        var it = std.mem.splitScalar(u8, spec, ',');
        if (it.next()) |id_part| {
            event_id = std.fmt.parseInt(i64, std.mem.trim(u8, id_part, " "), 10) catch 0;
        }
        while (it.next()) |part| {
            const p = std.mem.trim(u8, part, " ");
            if (std.ascii.startsWithIgnoreCase(p, "PAGE")) {
                const n = std.mem.trim(u8, p[4..], " ");
                page_no = std.fmt.parseInt(i64, n, 10) catch 1;
            } else if (std.ascii.startsWithIgnoreCase(p, "MAP")) {
                const n = std.mem.trim(u8, p[3..], " ");
                map_id = std.fmt.parseInt(i64, n, 10) catch null;
            }
        }
        if (event_id <= 0) return true;

        const target_map: u32 = if (map_id) |m| @intCast(m) else self.game.map.map_id;
        const list = self.callEventList(target_map, @intCast(event_id), @intCast(page_no)) orelse {
            log.event(.mv, .warn, "CallEvent: map {d} event {d} page {d} not resolvable", .{ target_map, event_id, page_no });
            return true;
        };
        if (list.len == 0) return true;
        log.detail(.mv, "CallEvent: map {d} event {d} page {d} ({d} commands)", .{ target_map, event_id, page_no, list.len });
        self.setupChild(list, if (target_map == self.game.map.map_id) @intCast(event_id) else 0) catch {};
        return true;
    }

    fn callEventList(self: *Interpreter, map_id: u32, event_id: i32, page_no: i32) ?[]const map_mod.Command {
        // Same-map: use the loaded $dataMap. Other maps: load MapNNN.json
        // through the database (cached).
        const dm_list = self.mapPageList(map_id, event_id, page_no) orelse return null;
        return dm_list;
    }

    fn mapPageList(self: *Interpreter, map_id: u32, event_id: i32, page_no: i32) ?[]const map_mod.Command {
        // The loaded current map: dm.data_map — accessed through the
        // game module (setup happened at transfer time). For other maps,
        // parse Map###.json on demand into the cache arena.
        var raw: ?*const map_mod.RawMap = null;
        var parsed: ?map_mod.RawMap = null;
        if (map_id == self.game.map.map_id and self.currentRawMap != null) {
            raw = self.currentRawMap;
        } else {
            var path_buf: [32]u8 = undefined;
            const path = std.fmt.bufPrint(&path_buf, "data/Map{d:0>3}.json", .{map_id}) catch return null;
            if (self.db.get(path) == null) {
                _ = self.db.loadFile(.map, path) catch return null;
            }
            const f = self.db.get(path) orelse return null;
            parsed = map_mod.RawMap.fromJson(self.cacheArena().allocator(), f.value) catch return null;
            raw = &parsed.?;
        }
        const r = raw.?;
        if (event_id <= 0 or event_id >= r.events.items.len) return null;
        const ev = r.events.items[@intCast(event_id)] orelse return null;
        const pi: usize = @intCast(@max(page_no - 1, 0));
        if (pi >= ev.pages.items.len) return null;
        return ev.pages.items[pi].list;
    }

    pub fn setCurrentRawMap(self: *Interpreter, raw: ?*const map_mod.RawMap) void {
        self.currentRawMap = raw;
        if (self.child) |child| child.setCurrentRawMap(raw);
    }
};

// Map088's stairs require friends. Evaluate this known MV numeric
// expression without turning arbitrary script text into executable code.
fn partyCountCondition(script: []const u8, count: usize) ?bool {
    const expression = std.mem.trim(u8, script, " \t\r\n;");
    var suffix: ?[]const u8 = null;
    for ([_][]const u8{ "$gameParty.members().length", "$gameParty.size()" }) |prefix| {
        if (std.mem.startsWith(u8, expression, prefix)) {
            suffix = std.mem.trim(u8, expression[prefix.len..], " \t");
            break;
        }
    }
    const comparison = suffix orelse return null;
    for ([_][]const u8{ "===", "!==", "<=", ">=", "==", "!=", "<", ">" }) |operator| {
        if (!std.mem.startsWith(u8, comparison, operator)) continue;
        const literal = std.mem.trim(u8, comparison[operator.len..], " \t");
        const right = std.fmt.parseInt(i64, literal, 10) catch return null;
        const left: i64 = @intCast(count);
        return if (std.mem.eql(u8, operator, "<=")) left <= right else if (std.mem.eql(u8, operator, ">=")) left >= right else if (std.mem.eql(u8, operator, "<")) left < right else if (std.mem.eql(u8, operator, ">")) left > right else if (operator[0] == '!') left != right else left == right;
    }
    return null;
}

/// The White Space idle counter asks isMoving() from a parallel event.
/// Support those exact predicates without evaluating arbitrary script text.
fn playerMotionCondition(script: []const u8, frame: FrameInput) ?bool {
    const expression = std.mem.trim(u8, script, " \t\r\n;");
    if (std.mem.eql(u8, expression, "$gamePlayer.isMoving()")) return frame.player_moving;
    if (std.mem.eql(u8, expression, "$gamePlayer.isStopping()")) return !frame.player_moving and !frame.player_jumping;
    return null;
}

const SelfSwitchKey = struct { map: u32, event: i32, ch: []const u8 };

/// Parse `[123, 4, 'A']` self-switch key literals.
fn parseSelfSwitchKey(src: []const u8) ?SelfSwitchKey {
    var s2 = std.mem.trim(u8, src, " \t");
    if (s2.len < 2 or s2[0] != '[' or s2[s2.len - 1] != ']') return null;
    s2 = s2[1 .. s2.len - 1];
    var parts: [3][]const u8 = undefined;
    var n: usize = 0;
    var depth: usize = 0;
    var start: usize = 0;
    for (s2, 0..) |c, i| {
        switch (c) {
            '[' => depth += 1,
            ']' => depth -= 1,
            ',' => if (depth == 0) {
                if (n < 3) {
                    parts[n] = std.mem.trim(u8, s2[start..i], " \t");
                    n += 1;
                }
                start = i + 1;
            },
            else => {},
        }
    }
    if (n < 3) {
        parts[n] = std.mem.trim(u8, s2[start..], " \t");
        n += 1;
    }
    if (n != 3) return null;
    const map = std.fmt.parseInt(u32, parts[0], 10) catch return null;
    const event = std.fmt.parseInt(i32, parts[1], 10) catch return null;
    var ch = parts[2];
    if (ch.len >= 2 and (ch[0] == '\'' or ch[0] == '"')) ch = ch[1 .. ch.len - 1];
    if (ch.len != 1) return null;
    return .{ .map = map, .event = event, .ch = ch };
}

/// Command 122 operation kinds (MV operateVariable).
const state_op = enum(i64) {
    set = 0,
    add = 1,
    sub = 2,
    mul = 3,
    div = 4,
    mod = 5,
};

pub const InterpreterError = error{
    OutOfMemory,
    CommonEventDepth,
};

// ---------------------------------------------------------------------------
// Tests — synthetic command lists exercising the exact MV mechanics
// ---------------------------------------------------------------------------

const testing = std.testing;
const vfs_mod = @import("../filesystem/vfs.zig");
const state = @import("state.zig");

fn buildTestDb(alloc: std.mem.Allocator) !*database.Database {
    const root = "/tmp/omori-itp-test";
    std.fs.cwd().deleteTree(root) catch {};
    const dir = try std.fs.path.join(alloc, &.{ root, "data" });
    defer alloc.free(dir);
    try std.fs.cwd().makePath(dir);
    {
        const p = try std.fs.path.join(alloc, &.{ root, "data", "System.json" });
        defer alloc.free(p);
        var f = try std.fs.cwd().createFile(p, .{});
        defer f.close();
        try f.writeAll("{\"gameTitle\":\"T\",\"switches\":[null,\"s1\",\"s2\"],\"variables\":[null,\"v1\",\"v2\",\"v3\"],\"partyMembers\":[1]}");
    }
    {
        const p = try std.fs.path.join(alloc, &.{ root, "data", "Actors.json" });
        defer alloc.free(p);
        var f = try std.fs.cwd().createFile(p, .{});
        defer f.close();
        try f.writeAll("[null,{\"id\":1,\"name\":\"HERO\",\"nickname\":\"\",\"profile\":\"\",\"classId\":1,\"level\":1,\"equips\":[1],\"maxLevel\":99}]");
    }
    {
        const p = try std.fs.path.join(alloc, &.{ root, "data", "Classes.json" });
        defer alloc.free(p);
        var f = try std.fs.cwd().createFile(p, .{});
        defer f.close();
        try f.writeAll("[null,{\"id\":1,\"name\":\"CLASS\",\"expParams\":[30,20,30,30],\"params\":[[500,500,500,500,500,500,500,500]],\"learnings\":[{\"level\":1,\"skillId\":1}]}]");
    }
    {
        const p = try std.fs.path.join(alloc, &.{ root, "data", "CommonEvents.json" });
        defer alloc.free(p);
        var f = try std.fs.cwd().createFile(p, .{});
        defer f.close();
        try f.writeAll("[null,{\"id\":1,\"name\":\"CE1\",\"trigger\":0,\"list\":[{\"code\":121,\"indent\":0,\"parameters\":[2,2,0]},{\"code\":0,\"indent\":0,\"parameters\":[]}]}]");
    }
    const vfs = try alloc.create(vfs_mod.Vfs);
    vfs.* = vfs_mod.Vfs.init(alloc, root, "/tmp/omori-itp-save");
    const db = try alloc.create(database.Database);
    db.* = database.Database.init(alloc, vfs);
    // Load the files the game objects read (switches/variables counts,
    // actors, classes, common events).
    _ = try db.loadFile(.database, "data/System.json");
    _ = try db.loadFile(.database, "data/Actors.json");
    _ = try db.loadFile(.database, "data/Classes.json");
    _ = try db.loadFile(.database, "data/CommonEvents.json");
    return db;
}

fn freeTestDb(alloc: std.mem.Allocator, db: *database.Database) void {
    db.vfs.deinit();
    alloc.destroy(db.vfs);
    db.deinit();
    alloc.destroy(db);
}

fn jv(n: f64) json.Value {
    return .{ .number = n };
}

fn js(s: []const u8) json.Value {
    return .{ .string = s };
}

fn ja(items: []const json.Value) json.Value {
    return .{ .array = .{ .items = @constCast(items) } };
}

fn mkCmds(alloc: std.mem.Allocator, cmds: []const map_mod.Command) ![]map_mod.Command {
    return alloc.dupe(map_mod.Command, cmds);
}

fn setupInterpreter(alloc: std.mem.Allocator) !struct { db: *database.Database, game: *game_mod.GameObjects, texts: *text_mod.TextStore, itp: *Interpreter } {
    const db = try buildTestDb(alloc);
    errdefer freeTestDb(alloc, db);
    const game = try alloc.create(game_mod.GameObjects);
    game.* = game_mod.GameObjects.init(alloc, &db.*);
    try game.create();
    game.party.members.append(alloc, 1) catch {};
    const texts = try alloc.create(text_mod.TextStore);
    texts.* = text_mod.TextStore.init(alloc, db.vfs, "en");
    const itp = try alloc.create(Interpreter);
    itp.* = Interpreter.init(alloc, game, db, texts);
    return .{ .db = db, .game = game, .texts = texts, .itp = itp };
}

fn teardownInterpreter(alloc: std.mem.Allocator, ctx: anytype) void {
    ctx.itp.deinit();
    alloc.destroy(ctx.itp);
    ctx.texts.deinit();
    alloc.destroy(ctx.texts);
    ctx.game.deinit();
    alloc.destroy(ctx.game);
    freeTestDb(alloc, ctx.db);
}

fn addEquipmentTestData(a: std.mem.Allocator, db: *database.Database) !void {
    const files = [_]struct { path: []const u8, data: []const u8 }{
        .{ .path = "data/Actors.json", .data = 
        \\[null,{"id":1,"name":"OMORI","classId":1,"initialLevel":1,"equips":[1,0],"maxLevel":99}]
        },
        .{ .path = "data/Classes.json", .data = 
        \\[null,{"id":1,"params":[[100,100],[20,20],[10,10],[4,4]],"learnings":[],"traits":[{"code":51,"dataId":1},{"code":52,"dataId":1}]}]
        },
        .{ .path = "data/Weapons.json", .data = 
        \\[null,{"id":1,"etypeId":1,"wtypeId":1,"params":[0,0,2,0]},
        \\{"id":2,"name":"SHINY KNIFE","etypeId":1,"wtypeId":1,"params":[0,0,5,0]},
        \\{"id":3,"etypeId":2,"wtypeId":1,"params":[0,0,99,0]},
        \\{"id":4,"etypeId":1,"wtypeId":2,"params":[0,0,99,0]}]
        },
        .{ .path = "data/Armors.json", .data = 
        \\[null,{"id":1,"etypeId":2,"atypeId":1,"params":[0,0,0,3]},{"id":2,"etypeId":1,"atypeId":1,"params":[0,0,0,99]}]
        },
    };
    for (files) |file| {
        var parser = try json.Parser.init(a, file.data);
        const value = try parser.parse();
        if (db.files.get(file.path)) |index| {
            db.storage.items[index].value = value;
        } else {
            try db.storage.append(a, .{ .path = file.path, .kind = .database, .value = value });
            try db.files.put(try a.dupe(u8, file.path), db.storage.items.len - 1);
        }
    }
    const skills = try a.alloc(json.Value, 27);
    @memset(skills, .null);
    var parser = try json.Parser.init(a, "{\"id\":26,\"name\":\"SAD POEM\",\"scope\":7,\"mpCost\":5}");
    skills[26] = try parser.parse();
    try db.storage.append(a, .{ .path = "data/Skills.json", .kind = .database, .value = .{ .array = .{ .items = skills } } });
    try db.files.put(try a.dupe(u8, "data/Skills.json"), db.storage.items.len - 1);
}

fn runEquipTestCommand(itp: *Interpreter, etype: i32, item_id: i32) void {
    const params = [_]json.Value{ jv(1), jv(@floatFromInt(etype)), jv(@floatFromInt(item_id)) };
    const commands = [_]map_mod.Command{.{ .code = 319, .indent = 0, .parameters = &params }};
    itp.setup(&commands, 0);
    itp.updateCommands();
    itp.setup(&.{}, 0);
}

test "button conditions: held logical actions and escape alias match the payload" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ctx = try setupInterpreter(arena.allocator());
    defer teardownInterpreter(arena.allocator(), ctx);
    const names = [_][]const u8{ "ok", "cancel", "up", "down", "left", "right", "shift", "pageup", "pagedown", "menu", "escape" };
    for (names) |name| {
        const command = map_mod.Command{ .code = 111, .indent = 0, .parameters = &.{ jv(11), js(name) } };
        ctx.itp.setFrameInput(.{});
        try testing.expect(!ctx.itp.evalCondition(command));
        ctx.itp.setFrameInput(.{ .held = .{
            .confirm = true,
            .cancel = true,
            .up = true,
            .down = true,
            .left = true,
            .right = true,
            .dash = true,
            .page_up = true,
            .page_down = true,
            .menu = true,
        } });
        try testing.expect(ctx.itp.evalCondition(command));
    }
    ctx.itp.setFrameInput(.{ .held = .{ .menu = true } });
    try testing.expect(ctx.itp.evalCondition(.{ .code = 111, .indent = 0, .parameters = &.{ jv(11), js("cancel") } }));
    try testing.expect(!ctx.itp.evalCondition(.{ .code = 111, .indent = 0, .parameters = &.{ jv(11), js("ok") } }));
    ctx.itp.setFrameInput(.{ .ok = true, .held = .{} });
    try testing.expect(ctx.itp.evalCondition(.{ .code = 111, .indent = 0, .parameters = &.{ jv(11), js("ok") } }));
}

test "button conditions: actual journal common event exits through child input and returns to caller" {
    const root = std.posix.getenv("OMORI_BATTLE_SMOKE_ROOT") orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vfs = vfs_mod.Vfs.init(a, root, root);
    defer vfs.deinit();
    var db = database.Database.init(a, &vfs);
    defer db.deinit();
    for (database.boot_database_files) |path| _ = try db.loadFile(.database, path);
    var game = game_mod.GameObjects.init(a, &db);
    defer game.deinit();
    try game.create();
    var texts = text_mod.TextStore.init(a, &vfs, "en");
    defer texts.deinit();
    var itp = Interpreter.init(a, &game, &db, &texts);
    defer itp.deinit();
    const commands = [_]map_mod.Command{
        .{ .code = 117, .indent = 0, .parameters = &.{jv(1)} },
        .{ .code = 235, .indent = 0, .parameters = &.{jv(3)} },
        .{ .code = 122, .indent = 0, .parameters = &.{ jv(2), jv(2), jv(0), jv(0), jv(77) } },
        .{ .code = 0, .indent = 0, .parameters = &.{} },
    };
    for ([_]input_mod.ButtonState{ .{ .confirm = true }, .{ .cancel = true }, .{ .menu = true } }) |held| {
        game.variables.setValue(2, 0);
        game.screen.showPicture(3, "ws_laptop_journal", 0, 0, 0, 100, 100, 255, 0);
        itp.setup(&commands, 3);
        for (0..20) |_| itp.update(.{});
        try testing.expect(itp.chainRunning());
        try testing.expect(itp.child != null);
        try testing.expect(game.screen.picture(3) != null);
        try testing.expectEqual(@as(i64, 0), game.variables.value(2));
        // Keep held input after its one-shot message edge has expired.
        // The authored loop waits five frames between button checks.
        for (0..8) |_| itp.update(.{ .held = held });
        try testing.expect(!itp.chainRunning());
        try testing.expect(game.screen.picture(3) == null);
        try testing.expectEqual(@as(i64, 77), game.variables.value(2));
    }
}

test "authored equipment: command319 trades inventory and validates slots and item types" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try setupInterpreter(a);
    defer teardownInterpreter(a, ctx);
    try addEquipmentTestData(a, ctx.db);
    const actor = ctx.game.actors.actor(1).?;
    try testing.expectEqual(@as(i64, 12), actor.param(2));
    ctx.game.party.gainWeapon(2, 1);
    runEquipTestCommand(ctx.itp, 1, 2);
    try testing.expectEqual(@as(i32, 2), actor.equips.items[0].item_id);
    try testing.expectEqual(@as(i64, 15), actor.param(2));
    try testing.expectEqual(@as(i64, 0), ctx.game.party.numWeapons(2));
    try testing.expectEqual(@as(i64, 1), ctx.game.party.numWeapons(1));
    const owned = map_mod.Command{ .code = 111, .indent = 0, .parameters = &.{ jv(9), jv(2), .{ .boolean = false } } };
    const equipped = map_mod.Command{ .code = 111, .indent = 0, .parameters = &.{ jv(9), jv(2), .{ .boolean = true } } };
    try testing.expect(!ctx.itp.evalCondition(owned));
    try testing.expect(ctx.itp.evalCondition(equipped)); // actual door contract
    runEquipTestCommand(ctx.itp, 1, 2); // no duplicate return on no-op
    try testing.expectEqual(@as(i64, 1), ctx.game.party.numWeapons(1));
    ctx.game.party.gainWeapon(3, 1);
    ctx.game.party.gainWeapon(4, 1);
    for ([_][2]i32{ .{ 0, 2 }, .{ 3, 2 }, .{ 1, 999 }, .{ 1, 3 }, .{ 1, 4 } }) |args| runEquipTestCommand(ctx.itp, args[0], args[1]);
    try testing.expectEqual(@as(i32, 2), actor.equips.items[0].item_id);
    try testing.expectEqual(@as(i64, 1), ctx.game.party.numWeapons(3));
    try testing.expectEqual(@as(i64, 1), ctx.game.party.numWeapons(4));
    runEquipTestCommand(ctx.itp, 1, 0);
    try testing.expectEqual(@as(i64, 10), actor.param(2));
    try testing.expectEqual(@as(i64, 1), ctx.game.party.numWeapons(2));
    runEquipTestCommand(ctx.itp, 1, 2);
    try testing.expectEqual(@as(i64, 15), actor.param(2)); // knife's +5 ATK
    runEquipTestCommand(ctx.itp, 2, 1); // not owned
    try testing.expectEqual(@as(i32, 0), actor.equips.items[1].item_id);
    ctx.game.party.gainArmor(1, 1);
    runEquipTestCommand(ctx.itp, 2, 1);
    try testing.expectEqual(@as(i64, 7), actor.param(3));
    try testing.expectEqual(@as(i64, 0), ctx.game.party.numArmors(1));
    try testing.expect(ctx.itp.evalCondition(.{ .code = 111, .indent = 0, .parameters = &.{ jv(10), jv(1), .{ .boolean = true } } }));
    runEquipTestCommand(ctx.itp, 2, 0);
    try testing.expectEqual(@as(i64, 1), ctx.game.party.numArmors(1));
}

test "authored equipment: bounded equipSkill script enables SAD POEM without duplicates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try setupInterpreter(a);
    defer teardownInterpreter(a, ctx);
    try addEquipmentTestData(a, ctx.db);
    const actor = ctx.game.actors.actor(1).?;
    try testing.expect(!actor.hasSkill(26));
    ctx.itp.runScriptLine("$gameActors.actor(1).equipSkill(0, 26);");
    try testing.expect(actor.hasSkill(26));
    ctx.itp.runScriptLine("$gameActors.actor(1).equipSkill(0, 26);");
    try testing.expectEqual(@as(usize, 1), actor.skills.items.len);
    actor.forgetSkill(26);
    for ([_][]const u8{
        "$gameActors.actor(1).equipSkill(-1, 26)",
        "$gameActors.actor(1).equipSkill(4, 26)",
        "$gameActors.actor(1).equipSkill(0, 999)",
        "$gameActors.actor(999).equipSkill(0, 26)",
    }) |line| ctx.itp.runScriptLine(line);
    try testing.expect(!actor.hasSkill(26));
}

test "authored equipment: actual Map087 knife adds five ATK and script enables skill26" {
    const root = std.posix.getenv("OMORI_BATTLE_SMOKE_ROOT") orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vfs = vfs_mod.Vfs.init(a, root, root);
    defer vfs.deinit();
    var db = database.Database.init(a, &vfs);
    defer db.deinit();
    for (database.boot_database_files) |path| _ = try db.loadFile(.database, path);
    const file = try db.loadFile(.map, "data/Map087.json");
    var raw = try map_mod.RawMap.fromJson(a, file.value);
    defer raw.deinit();
    var game = game_mod.GameObjects.init(a, &db);
    defer game.deinit();
    try game.create();
    game.party.addActor(1);
    var texts = text_mod.TextStore.init(a, &vfs, "en");
    defer texts.deinit();
    var itp = Interpreter.init(a, &game, &db, &texts);
    defer itp.deinit();
    const actor = game.actors.actor(1).?;
    const before = actor.param(2);
    game.party.gainWeapon(2, 1);
    const event = raw.events.items[8].?;
    var equipped = false;
    for (event.pages.items[3].list) |command| {
        if (command.code == 319) {
            itp.setup(&.{command}, 8);
            itp.updateCommands();
            equipped = true;
        }
    }
    try testing.expect(equipped);
    try testing.expectEqual(@as(i32, 2), actor.equips.items[0].item_id);
    try testing.expectEqual(before + 5, actor.param(2));
    try testing.expectEqual(@as(i64, 0), game.party.numWeapons(2));
    actor.forgetSkill(26);
    var skill_script = false;
    for (event.pages.items[1].list) |command| {
        if (command.code == 355) {
            const source = switch (command.parameters[0]) {
                .string => |source| source,
                else => continue,
            };
            if (std.mem.indexOf(u8, source, ".equipSkill(")) |_| {
                itp.runScriptLine(source);
                skill_script = true;
            }
        }
    }
    try testing.expect(skill_script);
    try testing.expect(actor.hasSkill(26));
    try testing.expect(itp.evalCondition(.{ .code = 111, .indent = 0, .parameters = &.{ jv(9), jv(2), .{ .boolean = true } } }));
    std.debug.print("actual Map087 command319: SHINY KNIFE equipped, ATK {d}->{d}, SAD POEM26 enabled, equipped-knife door condition true\n", .{ before, actor.param(2) });
}

test "interpreter: knife event relocates to its region and accepts chained position calls" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try setupInterpreter(a);
    defer teardownInterpreter(a, ctx);
    var raw = map_mod.RawMap{ .alloc = a, .meta = map_mod.Metadata.init(a), .width = 3, .height = 2 };
    defer raw.deinit();
    try raw.events.append(a, null);
    try raw.events.append(a, .{ .id = 1, .name = "knife", .x = 0, .y = 0, .meta = map_mod.Metadata.init(a) });
    const data = try a.alloc(i32, 3 * 2 * 6);
    @memset(data, 0);
    data[(5 * 2 + 1) * 3 + 2] = 15; // sole region15 cell: (2,1)
    raw.data = data;
    ctx.itp.currentRawMap = &raw;
    ctx.itp.event_id = 1;
    ctx.itp.runScriptLine("$gameMap.randomPos(1, 15);");
    try testing.expectEqual(@as(i32, 2), raw.events.items[1].?.x);
    try testing.expectEqual(@as(i32, 1), raw.events.items[1].?.y);
    ctx.itp.runScriptLine("$gameMap.event(this._eventId).setPosition(25, 40);");
    try testing.expectEqual(@as(i32, 25), raw.events.items[1].?.x);
    try testing.expectEqual(@as(i32, 40), raw.events.items[1].?.y);
    // No matching region leaves the location unchanged.
    ctx.itp.runScriptLine("$gameMap.randomPos(1, 99);");
    try testing.expectEqual(@as(i32, 25), raw.events.items[1].?.x);
    try testing.expectEqual(@as(usize, 0), ctx.itp.skipped_plugins.count());
}

test "interpreter: StopPlayerMovement persists until AllowPlayerMovement" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try setupInterpreter(a);
    defer teardownInterpreter(a, ctx);
    const commands = [_]map_mod.Command{
        .{ .code = 356, .indent = 0, .parameters = &.{js("StopPlayerMovement")} },
        .{ .code = 356, .indent = 0, .parameters = &.{js("AllowPlayerMovement")} },
    };
    ctx.itp.setup(&commands, 1);
    try testing.expect(ctx.itp.cmdPluginCommand());
    try testing.expect(ctx.game.temp.player_movement_stopped);
    ctx.itp.index = 1;
    try testing.expect(ctx.itp.cmdPluginCommand());
    try testing.expect(!ctx.game.temp.player_movement_stopped);
}

test "player motion conditions: actual interpolation differs from held directions" {
    const a = testing.allocator;
    const ctx = try setupInterpreter(a);
    defer teardownInterpreter(a, ctx);
    const moving = map_mod.Command{ .code = 111, .indent = 0, .parameters = &.{ jv(12), js(" $gamePlayer.isMoving(); ") } };
    const stopping = map_mod.Command{ .code = 111, .indent = 0, .parameters = &.{ jv(12), js("$gamePlayer.isStopping()") } };
    // A held direction at a wall must not reset the idle clock.
    ctx.itp.setFrameInput(.{ .held = .{ .right = true } });
    try testing.expect(!ctx.itp.evalCondition(moving));
    try testing.expect(ctx.itp.evalCondition(stopping));
    // An interpolating step remains moving after the direction is released.
    ctx.itp.setFrameInput(.{ .player_moving = true, .held = .{} });
    try testing.expect(ctx.itp.evalCondition(moving));
    try testing.expect(!ctx.itp.evalCondition(stopping));
    ctx.itp.setFrameInput(.{ .player_jumping = true });
    try testing.expect(!ctx.itp.evalCondition(moving));
    try testing.expect(!ctx.itp.evalCondition(stopping));
    try testing.expectEqual(@as(?bool, null), playerMotionCondition("$gamePlayer.isMoving() || true", .{}));
    try testing.expectEqual(@as(usize, 0), ctx.itp.skipped_plugins.count());
}

test "player motion conditions: idle counter resets during movement and reaches common-event children" {
    const a = testing.allocator;
    const ctx = try setupInterpreter(a);
    defer teardownInterpreter(a, ctx);
    // Generated equivalent of the authored Map087 idle/reset branches.
    const counter = [_]map_mod.Command{
        .{ .code = 230, .indent = 0, .parameters = &.{jv(2)} },
        .{ .code = 111, .indent = 0, .parameters = &.{ jv(12), js("$gamePlayer.isMoving(); ") } },
        .{ .code = 122, .indent = 1, .parameters = &.{ jv(2), jv(2), jv(0), jv(0), jv(0) } },
        .{ .code = 411, .indent = 0, .parameters = &.{} },
        .{ .code = 122, .indent = 1, .parameters = &.{ jv(2), jv(2), jv(1), jv(0), jv(1) } },
        .{ .code = 412, .indent = 0, .parameters = &.{} },
        .{ .code = 0, .indent = 0, .parameters = &.{} },
    };
    const parent = [_]map_mod.Command{.{ .code = 230, .indent = 0, .parameters = &.{jv(10)} }};
    for ([_]bool{ false, true }) |moving| {
        ctx.game.variables.setValue(2, 99);
        ctx.itp.setup(&parent, 6);
        ctx.itp.setFrameInput(.{ .player_moving = !moving });
        try ctx.itp.setupChild(&counter, 6);
        ctx.itp.updateCommands(); // Child enters its authored wait.
        try testing.expect(ctx.itp.child != null);
        for (0..5) |_| {
            ctx.itp.setFrameInput(.{ .player_moving = moving, .held = if (moving) .{} else .{ .right = true } });
            ctx.itp.updateCommands();
        }
        try testing.expectEqual(@as(i64, if (moving) 0 else 100), ctx.game.variables.value(2));
        try testing.expectEqual(@as(usize, 0), ctx.itp.skipped_plugins.count());
    }
}

test "player motion conditions: actual White Space idle event does not activate while walking" {
    const root = std.posix.getenv("OMORI_BATTLE_SMOKE_ROOT") orelse return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var vfs = vfs_mod.Vfs.init(a, root, root);
    defer vfs.deinit();
    var db = database.Database.init(a, &vfs);
    defer db.deinit();
    for (database.boot_database_files) |path| _ = try db.loadFile(.database, path);
    var game = game_mod.GameObjects.init(a, &db);
    defer game.deinit();
    try game.create();
    game.map.map_id = 87;
    const text = try vfs.readFileSync("data/Map087.json");
    var parser = try json.Parser.init(a, text);
    const raw = try map_mod.RawMap.fromJson(a, try parser.parse());
    const event = raw.events.items[6] orelse return error.MissingIdleEvent;
    var counter: ?[]const map_mod.Command = null;
    for (event.pages.items) |page| {
        for (page.list) |command| {
            if (command.code == 111 and command.parameters.len >= 2 and command.parameters[0].asInt() == 12 and
                std.mem.eql(u8, std.mem.trim(u8, valStr(command.parameters[1]), " \t\r\n;"), "$gamePlayer.isMoving()"))
            {
                counter = page.list;
                break;
            }
        }
        if (counter != null) break;
    }
    const list = counter orelse return error.MissingIdleCounter;
    var texts = text_mod.TextStore.init(a, &vfs, "en");
    defer texts.deinit();
    var itp = Interpreter.init(a, &game, &db, &texts);
    defer itp.deinit();
    game.variables.setValue(1087, 599);
    for (0..180) |_| {
        game.frame_count_global += 1;
        if (!itp.chainRunning()) itp.setup(list, 6);
        itp.setFrameInput(.{ .player_moving = true });
        itp.updateCommands();
    }
    try testing.expectEqual(@as(i64, 0), game.variables.value(1087));
    try testing.expect(!game.self_switches.value(87, 6, "A"));
    itp.setup(&.{}, 6);
    game.variables.setValue(1087, 599);
    for (0..40) |_| {
        game.frame_count_global += 1;
        if (!itp.chainRunning()) itp.setup(list, 6);
        itp.setFrameInput(.{ .held = .{ .right = true } }); // blocked input is still idle
        itp.updateCommands();
        if (game.self_switches.value(87, 6, "A")) break;
    }
    try testing.expect(game.self_switches.value(87, 6, "A"));
    try testing.expectEqual(@as(usize, 0), itp.skipped_plugins.count());
}

test "interpreter: stairs party-count guard changes after three friends join" {
    const a = testing.allocator;
    const ctx = try setupInterpreter(a);
    defer teardownInterpreter(a, ctx);
    const guard = map_mod.Command{ .code = 111, .indent = 0, .parameters = &.{ jv(12), js("$gameParty.members().length <= 1") } };
    try testing.expect(ctx.itp.evalCondition(guard));
    for ([_]i32{ 2, 3, 4 }) |actor_id| ctx.game.party.addActor(actor_id);
    try testing.expect(!ctx.itp.evalCondition(guard));
    try testing.expectEqual(@as(?bool, true), partyCountCondition("$gameParty.size() === 4;", 4));
    try testing.expectEqual(@as(?bool, false), partyCountCondition("$gameParty.members().length != 4", 4));
    try testing.expectEqual(@as(?bool, null), partyCountCondition("$gameParty.members().length <= 1 || true", 1));
    try testing.expectEqual(@as(?bool, null), partyCountCondition("$gamePlayer.pos(16, 19)", 1));
    try testing.expectEqual(@as(usize, 0), ctx.itp.skipped_plugins.count());
}

test "interpreter: authored weapon and armor gains update itemget metadata" {
    const a = testing.allocator;
    const ctx = try setupInterpreter(a);
    defer teardownInterpreter(a, ctx);
    const commands = [_]map_mod.Command{
        .{ .code = 127, .indent = 0, .parameters = &.{ jv(14), jv(0), jv(0), jv(1), .{ .boolean = false } } },
        .{ .code = 128, .indent = 0, .parameters = &.{ jv(50), jv(0), jv(0), jv(2), .{ .boolean = false } } },
    };
    ctx.itp.setup(&commands, 9);
    try testing.expect(ctx.itp.cmdChangeWeaponsOrArmors(.item));
    try testing.expectEqual(@as(i32, 14), ctx.game.party.last_gained.item_id);
    try testing.expect(ctx.game.party.last_gained.kind == .weapon);
    ctx.itp.index = 1;
    try testing.expect(ctx.itp.cmdChangeWeaponsOrArmors(.armor));
    try testing.expectEqual(@as(i32, 50), ctx.game.party.last_gained.item_id);
    try testing.expectEqual(@as(i32, 2), ctx.game.party.last_gained.amount);
    try testing.expect(ctx.game.party.last_gained.kind == .armor);
}

test "interpreter: control switches/variables/self switch + waits" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try setupInterpreter(a);

    const cmds = try mkCmds(a, &.{
        .{ .code = 121, .indent = 0, .parameters = &.{ jv(1), jv(1), jv(0) } },
        .{ .code = 122, .indent = 0, .parameters = &.{ jv(1), jv(2), jv(1), jv(0), jv(7) } },
        .{ .code = 123, .indent = 0, .parameters = &.{ js("A"), jv(0) } },
        .{ .code = 230, .indent = 0, .parameters = &.{jv(5)} },
        .{ .code = 0, .indent = 0, .parameters = &.{} },
    });

    ctx.game.map.map_id = 42;
    ctx.itp.setup(cmds, 3);
    var frames: usize = 0;
    while (ctx.itp.isRunning() and frames < 20) {
        ctx.game.frame_count_global += 1;
        ctx.itp.update(.{});
        frames += 1;
    }
    try testing.expect(!ctx.itp.isRunning());
    try testing.expect(ctx.game.switches.value(1) == true);
    try testing.expectEqual(@as(i64, 7), ctx.game.variables.value(1));
    try testing.expectEqual(@as(i64, 7), ctx.game.variables.value(2));
    try testing.expect(ctx.game.self_switches.value(42, 3, "A") == true);
    try testing.expectEqual(@as(usize, 6), frames);

    teardownInterpreter(a, ctx);
}

test "interpreter: if/else + skipBranch by indent" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try setupInterpreter(a);

    const cmds = try mkCmds(a, &.{
        .{ .code = 111, .indent = 0, .parameters = &.{ jv(0), jv(1), jv(1) } },
        .{ .code = 122, .indent = 1, .parameters = &.{ jv(1), jv(1), jv(0), jv(0), jv(111) } },
        .{ .code = 411, .indent = 0, .parameters = &.{} },
        .{ .code = 122, .indent = 1, .parameters = &.{ jv(2), jv(2), jv(0), jv(0), jv(222) } },
        .{ .code = 412, .indent = 0, .parameters = &.{} },
        .{ .code = 0, .indent = 0, .parameters = &.{} },
    });
    ctx.itp.setup(cmds, 0);
    var frames: usize = 0;
    while (ctx.itp.isRunning() and frames < 10) {
        ctx.game.frame_count_global += 1;
        ctx.itp.update(.{});
        frames += 1;
    }
    // switch 1 is OFF → condition true → then-branch runs, else skipped
    try testing.expectEqual(@as(i64, 111), ctx.game.variables.value(1));
    try testing.expectEqual(@as(i64, 0), ctx.game.variables.value(2));

    teardownInterpreter(a, ctx);
}

test "interpreter: loop + break" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try setupInterpreter(a);

    const cmds = try mkCmds(a, &.{
        .{ .code = 122, .indent = 0, .parameters = &.{ jv(1), jv(1), jv(1), jv(0), jv(1) } },
        .{ .code = 112, .indent = 0, .parameters = &.{} },
        .{ .code = 111, .indent = 1, .parameters = &.{ jv(1), jv(1), jv(0), jv(3), jv(1) } },
        .{ .code = 113, .indent = 2, .parameters = &.{} },
        .{ .code = 412, .indent = 1, .parameters = &.{} },
        .{ .code = 122, .indent = 1, .parameters = &.{ jv(1), jv(1), jv(1), jv(0), jv(1) } },
        .{ .code = 413, .indent = 0, .parameters = &.{} },
        .{ .code = 115, .indent = 0, .parameters = &.{} },
        .{ .code = 0, .indent = 0, .parameters = &.{} },
    });
    ctx.itp.setup(cmds, 0);
    var frames: usize = 0;
    while (ctx.itp.isRunning() and frames < 30) {
        ctx.game.frame_count_global += 1;
        ctx.itp.update(.{});
        frames += 1;
    }
    try testing.expect(!ctx.itp.isRunning());
    try testing.expectEqual(@as(i64, 3), ctx.game.variables.value(1));

    teardownInterpreter(a, ctx);
}

test "interpreter: message flow with ok input and choice branch" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try setupInterpreter(a);

    const cmds = try mkCmds(a, &.{
        .{ .code = 101, .indent = 0, .parameters = &.{ js(""), jv(0), jv(0), jv(2) } },
        .{ .code = 401, .indent = 0, .parameters = &.{js("Hello line 1")} },
        .{ .code = 401, .indent = 0, .parameters = &.{js("Hello line 2")} },
        .{ .code = 102, .indent = 0, .parameters = &.{ ja(&.{ js("Yes"), js("No") }), jv(1), jv(0), jv(2) } },
        .{ .code = 402, .indent = 0, .parameters = &.{jv(0)} },
        .{ .code = 122, .indent = 0, .parameters = &.{ jv(1), jv(1), jv(0), jv(0), jv(100) } },
        .{ .code = 412, .indent = 0, .parameters = &.{} },
        .{ .code = 0, .indent = 0, .parameters = &.{} },
    });
    ctx.itp.setup(cmds, 0);

    var frames: usize = 0;
    var ok_pressed = false;
    while (ctx.itp.isRunning() and frames < 100) {
        ctx.game.frame_count_global += 1;
        ctx.itp.update(.{ .ok = ok_pressed });
        frames += 1;
        if (frames == 1) {
            try testing.expect(ctx.game.message.isBusy());
            try testing.expectEqualStrings("Hello line 1", ctx.game.message.texts.items[0]);
            try testing.expectEqual(@as(usize, 2), ctx.game.message.choices.items.len);
        }
        if (frames >= 2) ok_pressed = true;
    }
    try testing.expect(!ctx.itp.isRunning());
    try testing.expectEqual(@as(i64, 100), ctx.game.variables.value(1));

    teardownInterpreter(a, ctx);
}

test "interpreter: common event child (117)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try setupInterpreter(a);

    const cmds = try mkCmds(a, &.{
        .{ .code = 117, .indent = 0, .parameters = &.{jv(1)} },
        .{ .code = 0, .indent = 0, .parameters = &.{} },
    });
    ctx.game.map.map_id = 7;
    ctx.itp.setup(cmds, 0);
    var frames: usize = 0;
    while (ctx.itp.isRunning() and frames < 10) {
        ctx.game.frame_count_global += 1;
        ctx.itp.update(.{});
        frames += 1;
    }
    try testing.expect(ctx.game.switches.value(2) == true);
    try testing.expect(!ctx.itp.isRunning());

    teardownInterpreter(a, ctx);
}

test "interpreter: transfer player (201) pauses and reserves" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try setupInterpreter(a);

    const cmds = try mkCmds(a, &.{
        .{ .code = 201, .indent = 0, .parameters = &.{ jv(0), jv(87), jv(10), jv(11), jv(2), jv(1) } },
        .{ .code = 0, .indent = 0, .parameters = &.{} },
    });
    ctx.itp.setup(cmds, 0);
    ctx.game.frame_count_global += 1;
    ctx.itp.update(.{});
    try testing.expect(ctx.game.player.isTransferring());
    try testing.expectEqual(@as(u32, 87), ctx.game.player.new_map_id);
    try testing.expect(ctx.itp.scene_changing);

    teardownInterpreter(a, ctx);
}

test "interpreter: erase event (214) + jump to label (119/118)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try setupInterpreter(a);

    const cmds = try mkCmds(a, &.{
        .{ .code = 119, .indent = 0, .parameters = &.{js("skip")} },
        .{ .code = 122, .indent = 0, .parameters = &.{ jv(1), jv(1), jv(0), jv(0), jv(1) } },
        .{ .code = 118, .indent = 0, .parameters = &.{js("skip")} },
        .{ .code = 214, .indent = 0, .parameters = &.{} },
        .{ .code = 0, .indent = 0, .parameters = &.{} },
    });
    ctx.game.map.map_id = 9;
    ctx.itp.setup(cmds, 5);
    var frames: usize = 0;
    while (ctx.itp.isRunning() and frames < 10) {
        ctx.game.frame_count_global += 1;
        ctx.itp.update(.{});
        frames += 1;
    }
    try testing.expectEqual(@as(i64, 0), ctx.game.variables.value(1));
    try testing.expect(ctx.game.map.isEventErased(5));

    teardownInterpreter(a, ctx);
}

test "interpreter: pictures (231/232/235) screen state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try setupInterpreter(a);

    const cmds = try mkCmds(a, &.{
        .{ .code = 231, .indent = 0, .parameters = &.{ jv(5), js("intro_slide"), jv(0), jv(0), jv(0), jv(0), jv(0), jv(100), jv(100), jv(255), jv(0) } },
        .{ .code = 232, .indent = 0, .parameters = &.{ jv(5), jv(0), jv(0), jv(0), jv(300), jv(400), jv(200), jv(50), jv(0), jv(0), jv(0), jv(0), jv(0) } },
        .{ .code = 0, .indent = 0, .parameters = &.{} },
    });
    ctx.itp.setup(cmds, 0);
    var frames: usize = 0;
    while (ctx.itp.isRunning() and frames < 5) {
        ctx.game.frame_count_global += 1;
        ctx.itp.update(.{});
        ctx.game.screen.update();
        frames += 1;
    }
    const pic = ctx.game.screen.picture(5) orelse return error.TestExpectedNonEqual;
    try testing.expectEqualStrings("intro_slide", pic.name);
    try testing.expectEqual(@as(i32, 300), pic.x);
    try testing.expectEqual(@as(i32, 400), pic.y);

    const cmds2 = try mkCmds(a, &.{
        .{ .code = 235, .indent = 0, .parameters = &.{jv(5)} },
        .{ .code = 0, .indent = 0, .parameters = &.{} },
    });
    ctx.itp.setup(cmds2, 0);
    while (ctx.itp.isRunning()) {
        ctx.game.frame_count_global += 1;
        ctx.itp.update(.{});
    }
    try testing.expect(ctx.game.screen.picture(5) == null);

    teardownInterpreter(a, ctx);
}

test "interpreter: fade (221/222) waits fadeSpeed frames" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ctx = try setupInterpreter(a);

    const cmds = try mkCmds(a, &.{
        .{ .code = 221, .indent = 0, .parameters = &.{} },
        .{ .code = 222, .indent = 0, .parameters = &.{} },
        .{ .code = 0, .indent = 0, .parameters = &.{} },
    });
    ctx.itp.setup(cmds, 0);
    var frames: usize = 0;
    while (ctx.itp.isRunning() and frames < 100) {
        ctx.game.frame_count_global += 1;
        ctx.itp.update(.{});
        ctx.game.screen.update();
        frames += 1;
    }
    try testing.expectEqual(@as(usize, 51), frames);

    teardownInterpreter(a, ctx);
}
