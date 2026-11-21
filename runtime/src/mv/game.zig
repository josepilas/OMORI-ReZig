//! MV Game_* state objects (milestone 4) — the $gameXxx set.
//!
//! Faithful ports of the `rpg_objects.js` initial state, field-for-field
//! where OMORI's boot touches them:
//!
//!   Game_Temp, Game_System, Game_Screen, Game_Timer, Game_Message,
//!   Game_Switches, Game_Variables, Game_SelfSwitches,
//!   Game_SelfVariables, Game_Actors/Game_Actor, Game_Party, Game_Troop,
//!   Game_Followers, Game_Player (transfer semantics).
//!
//! Honest scope (this milestone):
//!   * full construction semantics: initialize/setup from the database,
//!     including Game_Actor::setup (class/level/skills-from-learnings/
//!     equips), Game_Party::setupStartingMembers, Game_Player::
//!     reserveTransfer, Game_Map::setup (events, parallax, scroll,
//!     battleback, encounter step).
//!   * Game_Actor::expForLevel / currentLevelExp / paramBase /
//!     paramPlus (equip params) / paramMax — the level/exp/param curve,
//!     needed by level-up and the menu/battle milestones.
//!   * mutation surfaces the interpreter drives: switches, variables
//!     (command 122), self switches (command 123), self variables
//!     (OMORI plugin), timer (command 124 partially: start/stop),
//!     gold/items (commands 125/126), actor state.
//!   * Not in this milestone: movement, battle actions, message window
//!     flow — they arrive with M5+ (interpreter/scenes/battle).
//!
//! The event *interpreter* itself is M5; here we provide the state and
//! verify semantics with unit tests against synthetic databases.

const std = @import("std");
const log = @import("../core/log.zig");
const json = @import("../data/json.zig");
const database = @import("../data/database.zig");
const state = @import("state.zig");
const map_mod = @import("map.zig");
const tiled_mod = @import("tiled.zig");
const data_manager_mod = @import("data_manager.zig");
const vfs_mod = @import("../filesystem/vfs.zig");
const battle_mod = @import("battle.zig");
const encounter_mod = @import("encounters.zig");

/// Narrowing cast for database ints (values are small; truncation is a
/// data-integrity issue the tolerant layer would have flagged anyway).
fn int32(v: i64) i32 {
    return @intCast(v);
}

pub const Switches = state.Switches;
pub const Variables = state.Variables;

// ---------------------------------------------------------------------------
// Game_Temp
// ---------------------------------------------------------------------------

pub const GameTemp = struct {
    is_playtest: bool = false,
    common_event_id: i32 = 0,
    destination_x: ?i32 = null,
    destination_y: ?i32 = null,
    /// YEP_StopMapMovement: blocks manual player movement until allowed.
    player_movement_stopped: bool = false,
    /// Set only by importing an older native save, consumed once after its
    /// saved map is loaded. New saves and original MV saves do not opt in.
    legacy_collision_recovery: bool = false,

    pub fn init() GameTemp {
        return .{};
    }
};

// ---------------------------------------------------------------------------
// Game_System
// ---------------------------------------------------------------------------

pub const GameSystem = struct {
    save_enabled: bool = true,
    menu_enabled: bool = true,
    encounter_enabled: bool = true,
    formation_enabled: bool = true,
    battle_count: u32 = 0,
    win_count: u32 = 0,
    escape_count: u32 = 0,
    save_count: u32 = 0,
    version_id: u32 = 0,
    frames_on_save: u64 = 0,
    bgm_on_save: ?BgmSave = null,
    bgs_on_save: ?BgmSave = null,
    window_tone: ?[4]i32 = null,
    battle_bgm: ?BgmSave = null,
    victory_me: ?MeSave = null,
    defeat_me: ?MeSave = null,
    saved_bgm: ?BgmSave = null,
    walking_bgm: ?BgmSave = null,

    pub const BgmSave = struct { name: []const u8, volume: i32, pitch: i32, pan: i32 };
    pub const MeSave = BgmSave;

    pub fn init() GameSystem {
        // Game_System.initialize() — every field at its MV default.
        return .{};
    }
};

// ---------------------------------------------------------------------------
// Game_Screen (initial clear state)
// ---------------------------------------------------------------------------

pub const GameScreen = struct {
    pub const max_pictures = 100;
    brightness: i32 = 255,
    fade_out_duration: i32 = 0,
    fade_in_duration: i32 = 0,
    tone: [4]i32 = .{ 0, 0, 0, 0 }, // r,g,b,gray
    tone_target: [4]i32 = .{ 0, 0, 0, 0 },
    tone_duration: i32 = 0,
    flash_color: [4]i32 = .{ 0, 0, 0, 0 },
    flash_duration: i32 = 0,
    shake_power: i32 = 0,
    shake_speed: i32 = 0,
    shake_duration: i32 = 0,
    shake_direction: i32 = 1,
    shake: f64 = 0,
    zoom_x: f64 = 0,
    zoom_y: f64 = 0,
    zoom_scale: f64 = 1,
    zoom_scale_target: f64 = 1,
    zoom_duration: i32 = 0,
    weather_type: []const u8 = "none",
    weather_power: f64 = 0,
    weather_power_target: i32 = 0,
    weather_duration: i32 = 0,

    alloc: std.mem.Allocator,
    /// id → Picture (MV stores in a 101-slot array; sparse map is the
    /// same observable contract).
    pictures: std.AutoHashMap(i32, Picture),

    /// Game_Picture state (the interpreter's commands 231/232/233/234/235
    /// mutate these; M6 draws them).
    pub const Picture = struct {
        id: i32,
        name: []const u8 = "",
        origin: i32 = 0,
        x: i32 = 0,
        y: i32 = 0,
        scale_x: i32 = 100,
        scale_y: i32 = 100,
        opacity: i32 = 255,
        blend_mode: i32 = 0,
        angle: f64 = 0,
        spin: i32 = 0,
        // move-target interpolation state (movePicture)
        target_x: i32 = 0,
        target_y: i32 = 0,
        target_scale_x: i32 = 100,
        target_scale_y: i32 = 100,
        target_opacity: i32 = 255,
        move_duration: i32 = 0,
    };

    pub fn init(alloc: std.mem.Allocator) GameScreen {
        return .{ .alloc = alloc, .pictures = std.AutoHashMap(i32, Picture).init(alloc) };
    }

    pub fn deinit(self: *GameScreen) void {
        var it = self.pictures.valueIterator();
        while (it.next()) |picture_value| self.alloc.free(picture_value.name);
        self.pictures.deinit();
    }

    pub fn picture(self: *GameScreen, id: i32) ?*Picture {
        return self.pictures.getPtr(id);
    }

    /// showPicture (command 231). origin/x/y/scale/opacity/blend.
    pub fn showPicture(self: *GameScreen, id: i32, name: []const u8, origin: i32, x: i32, y: i32, scale_x: i32, scale_y: i32, opacity: i32, blend: i32) void {
        const owned_name = self.alloc.dupe(u8, name) catch return;
        const p = Picture{
            .id = id,
            .name = owned_name,
            .origin = origin,
            .x = x,
            .y = y,
            .scale_x = scale_x,
            .scale_y = scale_y,
            .opacity = opacity,
            .blend_mode = blend,
            .target_x = x,
            .target_y = y,
            .target_scale_x = scale_x,
            .target_scale_y = scale_y,
            .target_opacity = opacity,
        };
        const old = self.pictures.fetchPut(id, p) catch {
            self.alloc.free(owned_name);
            return;
        };
        if (old) |entry| self.alloc.free(entry.value.name);
        log.detail(.mv, "showPicture: id={d} name='{s}' pos=({d},{d}) scale=({d}%,{d}%) opacity={d}", .{ id, name, x, y, scale_x, scale_y, opacity });
    }

    /// movePicture (command 232): sets the move target; update()
    /// interpolates like Game_Picture.updateMove.
    pub fn movePicture(self: *GameScreen, id: i32, origin: i32, x: i32, y: i32, scale_x: i32, scale_y: i32, opacity: i32, blend: i32, duration: i32) void {
        const p = self.pictures.getPtr(id) orelse return;
        p.origin = origin;
        p.target_x = x;
        p.target_y = y;
        p.target_scale_x = scale_x;
        p.target_scale_y = scale_y;
        p.target_opacity = opacity;
        p.blend_mode = blend;
        p.move_duration = duration;
        if (duration <= 0) {
            // MV Game_Picture with duration 0: target applies at once.
            p.x = x;
            p.y = y;
            p.scale_x = scale_x;
            p.scale_y = scale_y;
            p.opacity = opacity;
            p.move_duration = 0;
        }
        log.detail(.mv, "movePicture: id={d} to ({d},{d}) scale=({d}%,{d}%) opacity={d} dur={d}", .{ id, x, y, scale_x, scale_y, opacity, duration });
    }

    /// rotatePicture (command 233).
    pub fn rotatePicture(self: *GameScreen, id: i32, speed: i32) void {
        const p = self.pictures.getPtr(id) orelse return;
        p.spin = speed;
    }

    /// erasePicture (command 235).
    pub fn erasePicture(self: *GameScreen, id: i32) void {
        if (self.pictures.fetchRemove(id)) |entry| self.alloc.free(entry.value.name);
        log.detail(.mv, "erasePicture: id={d}", .{id});
    }

    /// startFadeOut / startFadeIn (commands 221/222).
    pub fn startFadeOut(self: *GameScreen, duration: i32) void {
        self.fade_out_duration = @max(duration, 0);
        self.fade_in_duration = 0;
        log.detail(.mv, "startFadeOut: duration={d}", .{duration});
    }

    pub fn startFadeIn(self: *GameScreen, duration: i32) void {
        self.fade_in_duration = @max(duration, 0);
        self.fade_out_duration = 0;
        log.detail(.mv, "startFadeIn: duration={d}", .{duration});
    }

    pub fn isFading(self: *const GameScreen) bool {
        return self.fade_out_duration > 0 or self.fade_in_duration > 0;
    }

    /// startTint (223), startFlash (224), startShake (225).
    pub fn startTint(self: *GameScreen, tone: [4]i32, duration: i32) void {
        self.tone_target = tone;
        self.tone_duration = @max(duration, 0);
        if (self.tone_duration == 0) self.tone = tone;
    }

    pub fn startFlash(self: *GameScreen, color: [4]i32, duration: i32) void {
        self.flash_color = color;
        self.flash_duration = @max(duration, 0);
        if (self.flash_duration == 0) self.flash_color[3] = 0;
    }

    pub fn startShake(self: *GameScreen, power: i32, speed: i32, duration: i32) void {
        self.shake_power = std.math.clamp(power, 0, 1000);
        self.shake_speed = std.math.clamp(speed, 0, 1000);
        self.shake_duration = @max(duration, 0);
        if (self.shake_power == 0 or self.shake_speed == 0) {
            self.shake = 0;
            self.shake_duration = 0;
        }
    }

    /// changeWeather (236).
    pub fn changeWeather(self: *GameScreen, kind: []const u8, power: i32, duration: i32) void {
        // Keep the previous particles visible throughout a fade to clear.
        const clearing = std.mem.eql(u8, kind, "none");
        if (!clearing or duration <= 0) self.weather_type = kind;
        self.weather_power_target = if (clearing) 0 else std.math.clamp(power, 0, 9);
        self.weather_duration = @max(0, duration);
        if (self.weather_duration == 0) self.weather_power = @floatFromInt(self.weather_power_target);
        log.detail(.mv, "weather: {s} power={d} dur={d}", .{ kind, power, duration });
    }

    /// Game_Screen.update (picture moves, fades, tone, shake, weather).
    pub fn update(self: *GameScreen) void {
        if (self.weather_duration > 0) {
            const target: f64 = @floatFromInt(self.weather_power_target);
            self.weather_power += (target - self.weather_power) / @as(f64, @floatFromInt(self.weather_duration));
            self.weather_duration -= 1;
        }
        if (self.fade_out_duration > 0) {
            self.brightness = remainingStep(self.brightness, 0, self.fade_out_duration);
            self.fade_out_duration -= 1;
        }
        if (self.fade_in_duration > 0) {
            self.brightness = remainingStep(self.brightness, 255, self.fade_in_duration);
            self.fade_in_duration -= 1;
        }
        if (self.tone_duration > 0) {
            for (&self.tone, self.tone_target) |*value, target| value.* = remainingStep(value.*, target, self.tone_duration);
            self.tone_duration -= 1;
        }
        if (self.flash_duration > 0) {
            self.flash_color[3] = remainingStep(self.flash_color[3], 0, self.flash_duration);
            self.flash_duration -= 1;
        }
        if (self.shake_duration > 0 or self.shake != 0) {
            const power: f64 = @floatFromInt(self.shake_power);
            const delta = power * @as(f64, @floatFromInt(self.shake_speed * self.shake_direction)) / 10.0;
            if (self.shake_duration <= 1 and self.shake * (self.shake + delta) < 0) {
                self.shake = 0;
            } else {
                self.shake += delta;
            }
            if (self.shake > power * 2) self.shake_direction = -1;
            if (self.shake < -power * 2) self.shake_direction = 1;
            self.shake_duration = @max(self.shake_duration - 1, 0);
        }
        var pit = self.pictures.iterator();
        while (pit.next()) |e| {
            const p = e.value_ptr; // mutable pointer — interpolate in place
            if (p.spin != 0) p.angle = @mod(p.angle + @as(f64, @floatFromInt(p.spin)) / 2.0, 360.0);
            if (p.move_duration > 0) {
                const d = p.move_duration;
                p.x = remainingStep(p.x, p.target_x, d);
                p.y = remainingStep(p.y, p.target_y, d);
                p.scale_x = remainingStep(p.scale_x, p.target_scale_x, d);
                p.scale_y = remainingStep(p.scale_y, p.target_scale_y, d);
                p.opacity = remainingStep(p.opacity, p.target_opacity, d);
                p.move_duration -= 1;
            }
        }
    }

    // MV uses the remaining duration, not the total elapsed fraction.
    // Integer screen coordinates preserve exact final values on d=1.
    fn remainingStep(from: i32, to: i32, duration: i32) i32 {
        return @intCast(@divTrunc(@as(i64, from) * (duration - 1) + to, duration));
    }
};

// ---------------------------------------------------------------------------
// Game_Timer
// ---------------------------------------------------------------------------

pub const GameTimer = struct {
    frames: u64 = 0,
    working: bool = false,

    pub fn init() GameTimer {
        return .{};
    }

    /// command 124 start: (sec*60 frames); MV semantics.
    pub fn start(self: *GameTimer, seconds: i32) void {
        self.frames = @as(u64, @intCast(@max(seconds, 0))) * 60;
        self.working = true;
        log.detail(.mv, "timer start: {d}s ({d} frames)", .{ seconds, self.frames });
    }

    pub fn stop(self: *GameTimer) void {
        self.working = false;
    }

    pub fn update(self: *GameTimer) void {
        if (self.working and self.frames > 0) self.frames -= 1;
    }
};

// ---------------------------------------------------------------------------
// Game_Message (initial clear state)
// ---------------------------------------------------------------------------

pub const GameMessage = struct {
    layout: ?@import("dialogue.zig").Layout = null,
    instant_text: bool = false,
    owned_texts: std.ArrayList([]u8) = .empty,
    texts: std.ArrayList([]const u8) = .empty,
    face_name: []const u8 = "",
    face_index: i32 = 0,
    background: i32 = 0,
    position_type: i32 = 2,
    choice_type: i32 = 0,
    choice_default: i32 = 0,
    choices: std.ArrayList([]const u8) = .empty,
    /// OMORI language-choice labels (Text_Language_Processor
    /// setLanguageLabels — the label each choice jumps to).
    choice_labels: std.ArrayList([]const u8) = .empty,
    choice_cancel: i32 = 0,
    num_input_variable_id: i32 = 0,
    num_input_max_digits: i32 = 0,
    visible: bool = false,
    /// Waiting for player input (window pause / choice / input).
    busy: bool = false,
    /// Current visible page index (texts are 4-line pages; M6 draws).
    page_index: usize = 0,
    /// Wrapped line count from Window_Message's latest layout. The
    /// interpreter may run without a renderer and uses raw lines then.
    display_line_count: usize = 0,
    /// Frame counter while the window is paused on input.
    pause_frames: u64 = 0,
    /// Result of a choice selection (set by input handling; consumed by
    /// the interpreter's choice callback semantics).
    choice_result: ?i32 = null,
    /// Scrolling-text mode (command 105) — auto-advances without input
    /// when the scroll completes; kept false → input-driven otherwise.
    is_scroll_text: bool = false,
    scroll_speed: i32 = 2,
    scroll_no_fast: bool = false,
    /// Number-input current value (headless driver writes it).
    num_input_value: ?i64 = null,
    /// Choice selection index driven by external input (M6 menu).
    choice_index: i32 = 0,
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) GameMessage {
        return .{ .alloc = alloc };
    }

    /// MV Game_Message.clear — full reset (called on window terminate).
    pub fn clear(self: *GameMessage) void {
        self.discardLayout();
        for (self.owned_texts.items) |text| self.alloc.free(text);
        self.owned_texts.clearRetainingCapacity();
        self.texts.clearRetainingCapacity();
        self.choices.clearRetainingCapacity();
        self.choice_labels.clearRetainingCapacity();
        self.face_name = "";
        self.face_index = 0;
        self.background = 0;
        self.position_type = 2;
        self.choice_type = 0;
        self.choice_default = 0;
        self.choice_cancel = 0;
        self.num_input_variable_id = 0;
        self.num_input_max_digits = 0;
        self.visible = false;
        self.busy = false;
        self.page_index = 0;
        self.display_line_count = 0;
        self.pause_frames = 0;
        self.choice_result = null;
        self.is_scroll_text = false;
        self.scroll_speed = 2;
        self.scroll_no_fast = false;
    }

    /// MV isBusy: texts OR choices OR number input active.
    pub fn isBusy(self: *const GameMessage) bool {
        return self.texts.items.len > 0 or
            self.choices.items.len > 0 or
            self.num_input_variable_id > 0;
    }

    /// add(text) — appends one text line (dedup like MV add does NOT —
    /// MV pushes every line; the window concatenates 4 per page).
    pub fn add(self: *GameMessage, text: []const u8) void {
        self.discardLayout();
        self.texts.append(self.alloc, text) catch {};
    }

    /// Runtime-generated text outlives its formatting buffer and is
    /// released when the message closes, unlike borrowed language data.
    pub fn addOwned(self: *GameMessage, text: []u8) void {
        self.discardLayout();
        self.owned_texts.append(self.alloc, text) catch {
            self.alloc.free(text);
            return;
        };
        self.texts.append(self.alloc, text) catch {
            _ = self.owned_texts.pop();
            self.alloc.free(text);
        };
    }

    pub fn deinit(self: *GameMessage) void {
        self.clear();
        self.texts.deinit(self.alloc);
        self.choices.deinit(self.alloc);
        self.choice_labels.deinit(self.alloc);
        self.owned_texts.deinit(self.alloc);
    }

    pub fn textPageCount(self: *const GameMessage) usize {
        return (@max(self.texts.items.len, self.display_line_count) + 3) / 4;
    }

    pub fn isLastTextPage(self: *const GameMessage) bool {
        return self.page_index + 1 >= self.textPageCount();
    }

    fn discardLayout(self: *GameMessage) void {
        if (self.layout) |layout| layout.deinit(self.alloc);
        self.layout = null;
        self.display_line_count = 0;
    }

    pub fn choicesVisible(self: *const GameMessage) bool {
        return self.choices.items.len > 0 and self.isLastTextPage() and
            (self.layout == null or self.layout.?.ready);
    }

    /// setFaceImage / setBackground / setPositionType.
    pub fn setFaceImage(self: *GameMessage, name: []const u8, index: i32) void {
        self.face_name = name;
        self.face_index = index;
    }

    pub fn setBackground(self: *GameMessage, bg: i32) void {
        self.background = bg;
    }

    pub fn setPositionType(self: *GameMessage, pos: i32) void {
        self.position_type = pos;
    }

    /// setChoices(choices, defaultType, cancelType) — MV.
    pub fn setChoices(self: *GameMessage, choice_texts: []const []const u8, default_type: i32, cancel_type: i32) void {
        self.choices.clearRetainingCapacity();
        for (choice_texts) |c| self.choices.append(self.alloc, c) catch {};
        self.choice_type = 1;
        self.choice_default = default_type;
        self.choice_cancel = cancel_type;
        self.choice_index = if (default_type >= 0 and default_type < choice_texts.len) default_type else 0;
    }

    /// setNumberInput(variableId, maxDigits) — command 103.
    pub fn setNumberInput(self: *GameMessage, variable_id: i32, max_digits: i32) void {
        self.num_input_variable_id = variable_id;
        self.num_input_max_digits = max_digits;
        self.choice_type = 4;
    }

    /// setItemChoice(variableId, itemType) — command 104.
    pub fn setItemChoice(self: *GameMessage, variable_id: i32, item_type: i32) void {
        self.num_input_variable_id = variable_id;
        self.choice_type = 5;
        _ = item_type;
    }

    /// setScroll(speed, noFast) — command 105.
    pub fn setScroll(self: *GameMessage, speed: i32, no_fast: bool) void {
        self.is_scroll_text = true;
        self.scroll_speed = speed;
        self.scroll_no_fast = no_fast;
    }

    /// One frame of window logic (Window_Message.update reduced to the
    /// state machine the interpreter observes):
    ///  * paused on last page + ok → terminate (clear)
    ///  * choice visible + ok/cancel → choice_result + terminate
    ///  * number input + ok → value written to the variable + terminate
    /// `input` = pressed-this-frame flags (ok / cancel).
    pub fn update(self: *GameMessage, input_ok: bool, input_cancel: bool, variables: ?*Variables) void {
        if (!self.isBusy()) return;
        self.busy = true;
        self.pause_frames += 1;

        var auto_advance = false;
        if (self.layout) |*layout| {
            if (!self.is_scroll_text and !layout.tick(self.page_index, input_ok, self.instant_text)) return;
            auto_advance = layout.auto_end and self.isLastTextPage();
        }
        if (self.choicesVisible()) {
            // Choice window: caller sets choice_index externally (up/down
            // input); ok picks the current selection, cancel maps through
            // choice_cancel.
            if (input_ok) {
                self.choice_result = self.choice_index;
                self.terminateChoice(variables);
            } else if (input_cancel and self.choice_cancel != -1) {
                self.choice_result = self.choice_cancel;
                self.terminateChoice(variables);
            }
            return;
        }
        if (self.num_input_variable_id > 0 and self.isLastTextPage()) {
            if (input_ok) {
                // Number input: the headless driver stores the value into
                // choice_result_num; variables write-back happens here.
                if (variables) |vs| {
                    if (self.num_input_value) |v| {
                        vs.setValue(@intCast(self.num_input_variable_id), v);
                    }
                }
                self.num_input_variable_id = 0;
                self.choice_type = 0;
                self.clear();
            }
            return;
        }
        // Plain text pages: 4 lines per page (MV window chunking).
        const page_count = self.textPageCount();
        if (self.is_scroll_text) {
            // Scrolling text auto-terminates after the scroll duration;
            // approximated as one page per 16 lines * (6 - speed) frames.
            const scroll_frames: u64 = @intCast(@max(1, 6 - @min(self.scroll_speed, 6)) * 20);
            if (self.pause_frames >= scroll_frames * page_count) {
                self.clear();
            }
            return;
        }
        if (input_ok or auto_advance) {
            if (self.page_index + 1 < page_count) {
                self.page_index += 1;
                if (self.layout) |*layout| layout.nextPage();
            } else {
                self.clear();
            }
        }
    }

    fn terminateChoice(self: *GameMessage, variables: ?*Variables) void {
        _ = variables;
        self.choices.clearRetainingCapacity();
        self.choice_labels.clearRetainingCapacity();
        self.choice_type = 0;
        // texts already empty in the pure-choice case; if the message had
        // text + choices, the text pages finish first in MV. Keep simple
        // fidelity: full clear while retaining the callback result.
        // Window_ChoiceList delivers this after closing the window.
        const result = self.choice_result;
        self.clear();
        self.choice_result = result;
    }
};

// ---------------------------------------------------------------------------
// Game_SelfSwitches / Game_SelfVariables
// ---------------------------------------------------------------------------

pub const GameSelfSwitches = struct {
    alloc: std.mem.Allocator,
    /// key: "mapId,eventId,char"
    map: std.StringHashMap(bool),

    pub fn init(alloc: std.mem.Allocator) GameSelfSwitches {
        return .{ .alloc = alloc, .map = std.StringHashMap(bool).init(alloc) };
    }

    pub fn deinit(self: *GameSelfSwitches) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.map.deinit();
    }

    fn makeKey(alloc: std.mem.Allocator, map_id: u32, event_id: i32, ch: []const u8) ![]u8 {
        return std.fmt.allocPrint(alloc, "{d},{d},{s}", .{ map_id, event_id, ch });
    }

    pub fn value(self: *const GameSelfSwitches, map_id: u32, event_id: i32, ch: []const u8) bool {
        var kbuf: [48]u8 = undefined;
        const key = std.fmt.bufPrint(&kbuf, "{d},{d},{s}", .{ map_id, event_id, ch }) catch return false;
        return self.map.get(key) orelse false;
    }

    pub fn setValue(self: *GameSelfSwitches, map_id: u32, event_id: i32, ch: []const u8, v: bool) void {
        var kbuf: [48]u8 = undefined;
        const stack_key: []const u8 = std.fmt.bufPrint(&kbuf, "{d},{d},{s}", .{ map_id, event_id, ch }) catch return;
        const existing = self.map.getKey(stack_key) orelse blk: {
            const owned = makeKey(self.alloc, map_id, event_id, ch) catch return;
            break :blk owned;
        };
        if (v) {
            self.map.put(existing, true) catch {};
        } else {
            _ = self.map.remove(existing);
            if (existing.ptr != stack_key.ptr) self.alloc.free(existing);
        }
        log.detail(.mv, "selfSwitch {d},{d},{s} = {s}", .{ map_id, event_id, ch, if (v) "true" else "false" });
    }
};

pub const GameSelfVariables = struct {
    alloc: std.mem.Allocator,
    map: std.StringHashMap(i64),

    pub fn init(alloc: std.mem.Allocator) GameSelfVariables {
        return .{ .alloc = alloc, .map = std.StringHashMap(i64).init(alloc) };
    }

    pub fn deinit(self: *GameSelfVariables) void {
        var it = self.map.keyIterator();
        while (it.next()) |k| self.alloc.free(k.*);
        self.map.deinit();
    }

    pub fn value(self: *GameSelfVariables, map_id: u32, event_id: i32, ch: []const u8) i64 {
        var kbuf: [48]u8 = undefined;
        const key = std.fmt.bufPrint(&kbuf, "{d},{d},{s}", .{ map_id, event_id, ch }) catch return 0;
        return self.map.get(key) orelse 0;
    }

    pub fn setValue(self: *GameSelfVariables, map_id: u32, event_id: i32, ch: []const u8, v: i64) void {
        var kbuf: [48]u8 = undefined;
        const stack_key: []const u8 = std.fmt.bufPrint(&kbuf, "{d},{d},{s}", .{ map_id, event_id, ch }) catch return;
        const existing = self.map.getKey(stack_key) orelse blk: {
            const owned = std.fmt.allocPrint(self.alloc, "{d},{d},{s}", .{ map_id, event_id, ch }) catch return;
            break :blk owned;
        };
        if (v != 0) {
            self.map.put(existing, v) catch {};
        } else {
            _ = self.map.remove(existing);
            if (existing.ptr != stack_key.ptr) self.alloc.free(existing);
        }
    }
};

// ---------------------------------------------------------------------------
// Game_Actors / Game_Actor
// ---------------------------------------------------------------------------

fn attackCommandFromNote(note: []const u8) i32 {
    var in_commands = false;
    var lines = std.mem.tokenizeAny(u8, note, "\r\n");
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t");
        if (std.ascii.eqlIgnoreCase(line, "<BattleCommandsList>")) {
            in_commands = true;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(line, "</BattleCommandsList>")) break;
        if (!in_commands or line.len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return 1;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), "skill")) return 1;
        const id = std.fmt.parseInt(i32, std.mem.trim(u8, line[colon + 1 ..], " \t"), 10) catch return 1;
        return if (id > 0) id else 1;
    }
    return 1;
}

test "actor attack command: OMORI skill metadata replaces generic MV skill one" {
    try std.testing.expectEqual(@as(i32, 21), attackCommandFromNote("<BattleCommandsList>\r\nskill: 21\r\nskillList\r\ndefend\r\nitems\r\n</BattleCommandsList>"));
    try std.testing.expectEqual(@as(i32, 64), attackCommandFromNote("<battlecommandslist>\n skill: 64 \n</battlecommandslist>"));
    try std.testing.expectEqual(@as(i32, 1), attackCommandFromNote(""));
    try std.testing.expectEqual(@as(i32, 1), attackCommandFromNote("<BattleCommandsList>\nattack\nskill: 99\n</BattleCommandsList>"));
    try std.testing.expectEqual(@as(i32, 1), attackCommandFromNote("<BattleCommandsList>\nskill: -2\n</BattleCommandsList>"));
}

pub const DbActorView = struct {
    id: i32 = 0,
    name: []const u8 = "",
    nickname: []const u8 = "",
    profile: []const u8 = "",
    class_id: i32 = 1,
    initial_level: i32 = 1,
    max_level: i32 = 99,
    character_name: []const u8 = "",
    character_index: i32 = 0,
    face_name: []const u8 = "",
    face_index: i32 = 0,
    battler_name: []const u8 = "",
    battler_hue: i32 = 0,
    equips: []const json.Value = &.{},
    traits: []const json.Value = &.{},
    note: []const u8 = "",

    pub fn from(v: json.Value) DbActorView {
        return .{
            .id = int32(v.getInt("id", 0)),
            .name = v.getString("name") orelse "",
            .nickname = v.getString("nickname") orelse "",
            .profile = v.getString("profile") orelse "",
            .class_id = int32(v.getInt("classId", 1)),
            .initial_level = int32(v.getInt("initialLevel", 1)),
            .max_level = int32(v.getInt("maxLevel", 99)),
            .character_name = v.getString("characterName") orelse "",
            .character_index = int32(v.getInt("characterIndex", 0)),
            .face_name = v.getString("faceName") orelse "",
            .face_index = int32(v.getInt("faceIndex", 0)),
            .battler_name = v.getString("battlerName") orelse "",
            .battler_hue = int32(v.getInt("battlerHue", 0)),
            .equips = if (v.get("equips")) |e| e.arrayItems() else &.{},
            .traits = if (v.get("traits")) |t| t.arrayItems() else &.{},
            .note = v.getString("note") orelse "",
        };
    }
};

pub const DbClassView = struct {
    id: i32 = 0,
    name: []const u8 = "",
    exp_params: [4]i64 = .{ 30, 20, 30, 30 },
    /// params[8][100] — flattened view over the JSON array of arrays.
    params: []const json.Value = &.{},
    learnings: []const json.Value = &.{},

    pub fn from(v: json.Value) DbClassView {
        var exp: [4]i64 = .{ 30, 20, 30, 30 };
        if (v.get("expParams")) |ep| {
            const items = ep.arrayItems();
            for (items, 0..) |item, i| {
                if (i < 4) exp[i] = item.asInt();
            }
        }
        return .{
            .id = int32(v.getInt("id", 0)),
            .name = v.getString("name") orelse "",
            .exp_params = exp,
            .params = if (v.get("params")) |p| p.arrayItems() else &.{},
            .learnings = if (v.get("learnings")) |l| l.arrayItems() else &.{},
        };
    }
};

pub const GameActor = struct {
    alloc: std.mem.Allocator,
    db: *database.Database,
    actor_id: i32 = 0,
    name: []const u8 = "",
    nickname: []const u8 = "",
    profile: []const u8 = "",
    character_name: []const u8 = "",
    character_index: i32 = 0,
    owned_character_name: ?[]u8 = null,
    class_id: i32 = 1,
    level: i32 = 1,
    /// exp per class (we track the current class only; the map shape
    /// mirrors `_exp[classId]`).
    exp: i64 = 0,
    skills: std.ArrayList(i32) = .empty,
    /// Game_Item slots: (is_weapon, item_id).
    equips: std.ArrayList(EquipSlot) = .empty,
    param_plus: [8]i64 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    /// M8 battle state: states (id → remaining turns, 0 = infinite),
    /// buffs (+2/-2 per param), and the queued battle action.
    states: std.AutoHashMap(i32, i32) = undefined,
    buffs: [8]i32 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    battle_action: ?battle_mod.Action = null,
    hp: i32 = 1,
    mp: i32 = 0,
    tp: i32 = 0,

    pub const EquipSlot = struct { is_weapon: bool, item_id: i32 };

    pub fn init(alloc: std.mem.Allocator, db: *database.Database, actor_id: i32) GameActor {
        return .{ .alloc = alloc, .db = db, .actor_id = actor_id, .states = std.AutoHashMap(i32, i32).init(alloc) };
    }

    pub fn deinit(self: *GameActor) void {
        if (self.owned_character_name) |owned| self.alloc.free(owned);
        self.skills.deinit(self.alloc);
        self.equips.deinit(self.alloc);
        self.states.deinit();
    }

    pub fn setCharacterImage(self: *GameActor, name: []const u8, index: i32) !void {
        if (!std.mem.eql(u8, name, self.character_name)) {
            const copy = try self.alloc.dupe(u8, name);
            if (self.owned_character_name) |old| self.alloc.free(old);
            self.character_name = copy;
            self.owned_character_name = copy;
        }
        self.character_index = std.math.clamp(index, 0, 7);
    }

    pub fn dbActor(self: *const GameActor) ?DbActorView {
        const f = self.db.get("data/Actors.json") orelse return null;
        const items = f.value.arrayItems();
        const id = self.actor_id;
        if (id <= 0 or id >= items.len) return null;
        if (items[@intCast(id)] == .null) return null;
        return DbActorView.from(items[@intCast(id)]);
    }

    pub fn dbClass(self: *const GameActor) ?DbClassView {
        const f = self.db.get("data/Classes.json") orelse return null;
        const items = f.value.arrayItems();
        const id = self.class_id;
        if (id <= 0 or id >= items.len) return null;
        if (items[@intCast(id)] == .null) return null;
        return DbClassView.from(items[@intCast(id)]);
    }

    /// OMORI's first battle command is an actor-specific skill from
    /// Battle Commands List.js, not MV's generic skill #1 (PLAY here).
    pub fn battleAttackSkillId(self: *const GameActor) i32 {
        const actor = self.dbActor() orelse return 1;
        return attackCommandFromNote(actor.note);
    }

    /// Game_Actor.setup.
    pub fn setup(self: *GameActor) void {
        const a = self.dbActor() orelse {
            log.event(.mv, .err, "Game_Actor: no database actor {d}", .{self.actor_id});
            return;
        };
        if (self.owned_character_name) |old| self.alloc.free(old);
        self.owned_character_name = null;
        self.character_name = a.character_name;
        self.character_index = a.character_index;
        self.name = a.name;
        self.nickname = a.nickname;
        self.profile = a.profile;
        self.class_id = a.class_id;
        self.level = a.initial_level;
        self.initSkills();
        self.initEquips(a.equips);
        self.recoverAll();
        log.detail(.mv, "Game_Actor {d} ('{s}') setup: class={d} level={d} skills={d} equips={d}", .{
            self.actor_id, self.name, self.class_id, self.level, self.skills.items.len, self.equips.items.len,
        });
    }

    /// initSkills: learnings with level <= current level.
    fn initSkills(self: *GameActor) void {
        self.skills.clearRetainingCapacity();
        const cls = self.dbClass() orelse return;
        for (cls.learnings) |l| {
            const learn_level = l.getInt("level", 0);
            const skill_id: i32 = @intCast(l.getInt("skillId", 0));
            if (learn_level <= self.level and skill_id > 0) {
                self.learnSkill(skill_id);
            }
        }
    }

    pub fn learnSkill(self: *GameActor, skill_id: i32) void {
        for (self.skills.items) |s| {
            if (s == skill_id) return;
        }
        self.skills.append(self.alloc, skill_id) catch {};
    }

    /// forgetSkill — 318 remove.
    pub fn forgetSkill(self: *GameActor, skill_id: i32) void {
        var i: usize = 0;
        while (i < self.skills.items.len) {
            if (self.skills.items[i] == skill_id) {
                _ = self.skills.orderedRemove(i);
            } else i += 1;
        }
    }

    pub fn hasSkill(self: *const GameActor, skill_id: i32) bool {
        for (self.skills.items) |s| {
            if (s == skill_id) return true;
        }
        return false;
    }

    /// gainHp (clamped to 0..mhp; death handling is M8).
    pub fn gainHp(self: *GameActor, value: i64) void {
        const mhp: i64 = self.param(0);
        const next = std.math.clamp(@as(i64, self.hp) + value, 0, mhp);
        if (next != self.hp) {
            log.detail(.mv, "actor {d} hp: {d} -> {d} ({d})", .{ self.actor_id, self.hp, next, value });
            self.hp = @intCast(next);
        }
    }

    /// gainMp (clamped 0..mmp).
    pub fn gainMp(self: *GameActor, value: i64) void {
        const mmp: i64 = self.param(1);
        const next = std.math.clamp(@as(i64, self.mp) + value, 0, mmp);
        if (next != self.mp) self.mp = @intCast(next);
    }

    /// addParam — 317.
    pub fn addParam(self: *GameActor, param_id: usize, value: i64) void {
        if (param_id < 8) self.param_plus[param_id] += value;
    }

    /// changeLevel (+ level-up learnings like MV levelUp).
    pub fn changeLevel(self: *GameActor, level: i32) void {
        const lvl = std.math.clamp(level, 1, @as(i32, @intCast(self.maxLevel())));
        if (lvl == self.level) return;
        const up = lvl > self.level;
        self.level = lvl;
        log.detail(.mv, "actor {d} level: -> {d}", .{ self.actor_id, self.level });
        if (up) self.learnLevelSkills();
    }

    /// changeExp — 315 (level follows, MV currentLevelExp semantics).
    pub fn changeExp(self: *GameActor, exp: i64) void {
        self.exp = @max(exp, 0);
        while (self.level < self.maxLevel() and self.exp >= self.expForLevel(self.level + 1)) {
            self.level += 1;
            log.detail(.mv, "actor {d} level up: {d} (exp {d})", .{ self.actor_id, self.level, self.exp });
            self.learnLevelSkills();
        }
        while (self.level > 1 and self.exp < self.expForLevel(self.level)) {
            self.level -= 1;
        }
    }

    /// Skills learned at the current level (MV learnings filter).
    fn learnLevelSkills(self: *GameActor) void {
        const cls = self.dbClass() orelse return;
        for (cls.learnings) |l| {
            const lvl: i32 = @intCast(l.getInt("level", 0));
            const skill: i32 = @intCast(l.getInt("skillId", 0));
            if (lvl <= self.level and lvl > 0 and skill > 0) self.learnSkill(skill);
        }
    }

    fn initEquips(self: *GameActor, equips: []const json.Value) void {
        self.equips.clearRetainingCapacity();
        // MV equipSlots(): slot 0 is the weapon slot; OMORI actors carry
        // their equip arrays in Actors.json — we mirror their length.
        var i: usize = 0;
        while (i < equips.len) : (i += 1) {
            const item_id = int32(equips[i].asInt());
            const is_weapon = i == 0;
            self.equips.append(self.alloc, .{ .is_weapon = is_weapon, .item_id = item_id }) catch {};
        }
    }

    /// recoverAll (MV): _hp = mhp; _mp = mmp — the *current* param
    /// values (base + plus + equips), not the param caps.
    pub fn recoverAll(self: *GameActor) void {
        self.hp = @intCast(self.param(0));
        self.mp = @intCast(self.param(1));
    }

    /// Game_Actor.expForLevel (MV formula, f64 like JavaScript).
    pub fn expForLevel(self: *const GameActor, level: i32) i64 {
        const cls = self.dbClass() orelse return 0;
        const basis: f64 = @floatFromInt(cls.exp_params[0]);
        const extra: f64 = @floatFromInt(cls.exp_params[1]);
        const acc_a: f64 = @floatFromInt(cls.exp_params[2]);
        const acc_b: f64 = @floatFromInt(cls.exp_params[3]);
        const lvl: f64 = @floatFromInt(level);
        const p1 = std.math.pow(f64, lvl - 1, 0.9 + acc_a / 250.0);
        const p2 = std.math.pow(f64, lvl, 2.0) / 50.0 / acc_b;
        const raw = basis * p1 * lvl * (lvl + 1) / (6.0 + p2) + (lvl - 1) * extra;
        return @intFromFloat(@round(raw));
    }

    pub fn currentLevelExp(self: *const GameActor) i64 {
        return self.expForLevel(self.level);
    }

    pub fn nextLevelExp(self: *const GameActor) i64 {
        return if (self.level >= self.maxLevel()) std.math.maxInt(i64) else self.expForLevel(self.level + 1);
    }

    fn maxLevel(self: *const GameActor) i32 {
        const a = self.dbActor() orelse return 99;
        return a.max_level;
    }

    /// Battle: queue the next action (scripted input / force action).
    pub fn queueAction(self: *GameActor, action: battle_mod.Action) void {
        self.battle_action = action;
    }

    pub fn dequeueAction(self: *GameActor) ?battle_mod.Action {
        const a = self.battle_action;
        self.battle_action = null;
        return a;
    }

    /// States (313 / item effects). State 1 = KO (death).
    pub fn isStateAffected(self: *const GameActor, state_id: i32) bool {
        if (state_id == 1) return self.hp <= 0;
        return self.states.contains(state_id);
    }

    pub fn addState(self: *GameActor, db: *database.Database, state_id: i32) void {
        if (state_id == 1) {
            self.hp = 0;
            return;
        }
        const turns = battle_mod.stateTurns(db, state_id);
        self.states.put(state_id, turns) catch {};
    }

    pub fn removeState(self: *GameActor, state_id: i32) void {
        if (state_id == 1) return; // KO removal is revive-only
        _ = self.states.remove(state_id);
    }

    /// Turn tick: state turns decrement; expired states removed.
    pub fn tickStateTurns(self: *GameActor) void {
        var expired = std.ArrayList(i32).empty;
        defer expired.deinit(self.alloc);
        var it = self.states.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.* > 0) {
                kv.value_ptr.* -= 1;
                if (kv.value_ptr.* <= 0) expired.append(self.alloc, kv.key_ptr.*) catch {};
            }
        }
        for (expired.items) |sid| {
            log.detail(.mv, "actor '{s}' state {d} expired", .{ self.name, sid });
            _ = self.states.remove(sid);
        }
    }

    /// paramBase: class.params[paramId][level].
    fn paramBase(self: *const GameActor, param_id: usize) i64 {
        const cls = self.dbClass() orelse return 0;
        if (param_id >= cls.params.len) return 0;
        const row = cls.params[param_id].arrayItems();
        const lvl: usize = @intCast(@max(self.level, 0));
        if (lvl >= row.len) return 0;
        return row[lvl].asInt();
    }

    /// paramPlus: trait-plus + equip params.
    fn paramPlus(self: *const GameActor, param_id: usize) i64 {
        var value: i64 = self.param_plus[param_id];
        for (self.equips.items) |eq| {
            if (eq.item_id <= 0) continue;
            const path = if (eq.is_weapon) "data/Weapons.json" else "data/Armors.json";
            const f = self.db.get(path) orelse continue;
            const items = f.value.arrayItems();
            const id: usize = @intCast(eq.item_id);
            if (id >= items.len) continue;
            if (items[id] == .null) continue;
            if (items[id].get("params")) |ps| {
                const arr = ps.arrayItems();
                if (param_id < arr.len) value += arr[param_id].asInt();
            }
        }
        return value;
    }

    pub fn param(self: *const GameActor, param_id: usize) i64 {
        const base = self.paramBase(param_id);
        const plus = self.paramPlus(param_id);
        const scaled: i64 = @intFromFloat(@floor(@as(f64, @floatFromInt(base + plus)) * self.paramRate(param_id)));
        return @min(scaled, self.paramMax(param_id));
    }

    pub fn paramMax(self: *const GameActor, param_id: usize) i64 {
        _ = self;
        return if (param_id == 0) 999999 else 9999;
    }

    pub fn paramRate(self: *const GameActor, param_id: usize) f64 {
        // MV parameter-rate traits multiply, including timed states such
        // as ATTACK DOWN (0.9/0.8/0.7) authored by BE CUTE.
        var rate: f64 = 1;
        var states = self.states.keyIterator();
        while (states.next()) |state_id| {
            const state_data = battle_mod.stateData(self.db, state_id.*) orelse continue;
            const traits = if (state_data.get("traits")) |t| t.arrayItems() else &[_]json.Value{};
            for (traits) |trait| {
                if (trait.getInt("code", 0) == 21 and trait.getInt("dataId", -1) == param_id) {
                    rate *= if (trait.get("value")) |value| value.asFloat() else 1;
                }
            }
        }
        return rate;
    }
};

pub const GameActors = struct {
    alloc: std.mem.Allocator,
    db: *database.Database,
    /// Sparse map actorId → GameActor (lazy creation, MV semantics).
    map: std.AutoHashMap(i32, *GameActor),

    pub fn init(alloc: std.mem.Allocator, db: *database.Database) GameActors {
        return .{ .alloc = alloc, .db = db, .map = std.AutoHashMap(i32, *GameActor).init(alloc) };
    }

    pub fn deinit(self: *GameActors) void {
        var it = self.map.valueIterator();
        while (it.next()) |a| {
            a.*.deinit();
            self.alloc.destroy(a.*);
        }
        self.map.deinit();
    }

    /// Game_Actors.actor(id) — null for out-of-range ids (MV semantics).
    pub fn actor(self: *GameActors, actor_id: i32) ?*GameActor {
        if (actor_id <= 0) return null;
        if (self.map.get(actor_id)) |a| return a;
        // Validate against $dataActors.
        const f = self.db.get("data/Actors.json") orelse return null;
        const items = f.value.arrayItems();
        if (actor_id >= items.len) return null;
        if (items[@intCast(actor_id)] == .null) return null;

        const a = self.alloc.create(GameActor) catch return null;
        a.* = GameActor.init(self.alloc, self.db, actor_id);
        a.setup();
        self.map.put(actor_id, a) catch {};
        return a;
    }
};

// ---------------------------------------------------------------------------
// Game_Party
// ---------------------------------------------------------------------------

pub const GameParty = struct {
    alloc: std.mem.Allocator,
    db: *database.Database,
    actors: *GameActors,
    gold: i64 = 0,
    steps: u64 = 0,
    menu_actor_id: i32 = 0,
    target_actor_id: i32 = 0,
    /// Battle member ids in order.
    members: std.ArrayList(i32) = .empty,
    /// item_id → count.
    items: std.AutoHashMap(i32, i32),
    weapons: std.AutoHashMap(i32, i32),
    armors: std.AutoHashMap(i32, i32),
    last_item: struct { is_weapon: bool, item_id: i32 } = .{ .is_weapon = false, .item_id = 0 },
    /// OMORI's _lastItemData for \itemget; separate from MV's last-used
    /// battle item, which is serialized in last_item.
    last_gained: struct { kind: enum { item, weapon, armor } = .item, item_id: i32 = 0, amount: i32 = 0 } = .{},
    in_battle: bool = false,

    pub fn init(alloc: std.mem.Allocator, db: *database.Database, actors: *GameActors) GameParty {
        return .{ .alloc = alloc, .db = db, .actors = actors, .items = std.AutoHashMap(i32, i32).init(alloc), .weapons = std.AutoHashMap(i32, i32).init(alloc), .armors = std.AutoHashMap(i32, i32).init(alloc) };
    }

    pub fn deinit(self: *GameParty) void {
        self.members.deinit(self.alloc);
        self.items.deinit();
        self.weapons.deinit();
        self.armors.deinit();
    }

    pub fn maxBattleMembers(self: *const GameParty) usize {
        _ = self;
        return 4; // MV Game_Party.maxBattleMembers()
    }

    pub fn encounterTraits(self: *const GameParty) encounter_mod.Traits {
        var traits: encounter_mod.Traits = .{};
        const party_members = self.members.items[0..@min(self.members.items.len, self.maxBattleMembers())];
        for (party_members) |id| {
            const actor = self.actors.map.get(id) orelse continue;
            traits.addRecord(encounter_mod.record(self.db, "data/Actors.json", id));
            traits.addRecord(encounter_mod.record(self.db, "data/Classes.json", actor.class_id));
            for (actor.equips.items) |equip| {
                const path = if (equip.is_weapon) "data/Weapons.json" else "data/Armors.json";
                traits.addRecord(encounter_mod.record(self.db, path, equip.item_id));
            }
            var states = actor.states.keyIterator();
            while (states.next()) |state_id| {
                traits.addRecord(encounter_mod.record(self.db, "data/States.json", state_id.*));
            }
            if (traits.none) break;
        }
        return traits;
    }

    /// setupStartingMembers from $dataSystem.partyMembers.
    pub fn setupStartingMembers(self: *GameParty, dm: *const data_manager_mod.DataManager) !void {
        self.members.clearRetainingCapacity();
        const sys = dm.system() orelse return error.NoSystem;
        const pm = sys.get("partyMembers") orelse return error.NoSystem;
        for (pm.arrayItems()) |v| {
            const actor_id: i32 = int32(v.asInt());
            if (actor_id <= 0) continue;
            if (self.actors.actor(actor_id) != null) {
                try self.members.append(self.alloc, actor_id);
                log.detail(.mv, "party member: actor {d} ('{s}')", .{ actor_id, self.actors.actor(actor_id).?.name });
            }
        }
        log.event(.mv, .info, "setupStartingMembers: {d}/{d} member(s)", .{ self.members.items.len, pm.arrayItems().len });
    }

    pub fn gainGold(self: *GameParty, amount: i64) void {
        const next = std.math.clamp(self.gold + amount, 0, std.math.maxInt(i32));
        if (next != self.gold) {
            log.detail(.mv, "gold: {d} -> {d} ({d})", .{ self.gold, next, amount });
            self.gold = next;
        }
    }

    pub fn gainItem(self: *GameParty, item_id: i32, count: i32) void {
        if (count != 0) self.last_gained = .{ .kind = .item, .item_id = item_id, .amount = count };
        const cur = self.items.get(item_id) orelse 0;
        const next = cur + count;
        if (next <= 0) {
            _ = self.items.remove(item_id);
        } else {
            self.items.put(item_id, next) catch {};
        }
        log.detail(.mv, "item {d}: {d} -> {d}", .{ item_id, cur, @max(next, 0) });
    }

    /// M8: battle rewards (weapon/armor drops).
    pub fn gainWeapon(self: *GameParty, weapon_id: i32, count: i32) void {
        if (count != 0) self.last_gained = .{ .kind = .weapon, .item_id = weapon_id, .amount = count };
        const cur = self.weapons.get(weapon_id) orelse 0;
        const next = cur + count;
        if (next <= 0) {
            _ = self.weapons.remove(weapon_id);
        } else {
            self.weapons.put(weapon_id, next) catch {};
        }
        log.detail(.mv, "weapon {d}: {d} -> {d}", .{ weapon_id, cur, @max(next, 0) });
    }

    pub fn gainArmor(self: *GameParty, armor_id: i32, count: i32) void {
        if (count != 0) self.last_gained = .{ .kind = .armor, .item_id = armor_id, .amount = count };
        const cur = self.armors.get(armor_id) orelse 0;
        const next = cur + count;
        if (next <= 0) {
            _ = self.armors.remove(armor_id);
        } else {
            self.armors.put(armor_id, next) catch {};
        }
        log.detail(.mv, "armor {d}: {d} -> {d}", .{ armor_id, cur, @max(next, 0) });
    }

    pub fn lastGainedItemName(self: *const GameParty) []const u8 {
        const path: []const u8 = switch (self.last_gained.kind) {
            .item => "data/Items.json",
            .weapon => "data/Weapons.json",
            .armor => "data/Armors.json",
        };
        const file = self.db.get(path) orelse return "";
        const entries = file.value.arrayItems();
        const id = self.last_gained.item_id;
        if (id <= 0 or id >= entries.len) return "";
        return entries[@intCast(id)].getString("name") orelse "";
    }

    /// M8: gainExp — level follows exp (MV changeExp semantics per
    /// actor; level-ups log learnings via changeLevel).
    pub fn gainExp(self: *GameParty, exp: i64, db: *database.Database) void {
        _ = db;
        if (exp <= 0) return;
        for (self.members.items) |id| {
            if (self.actors.actor(id)) |a| {
                a.changeExp(a.exp + exp);
            }
        }
        log.event(.mv, .note, "party gained {d} exp", .{exp});
    }

    pub fn itemName(self: *const GameParty, item_id: i32) []const u8 {
        const f = self.db.get("data/Items.json") orelse return "";
        const items = f.value.arrayItems();
        if (item_id <= 0 or item_id >= items.len) return "";
        return items[@intCast(item_id)].getString("name") orelse "";
    }

    pub fn leader(self: *const GameParty) ?*GameActor {
        if (self.members.items.len == 0) return null;
        return self.actors.actor(self.members.items[0]);
    }

    /// addActor (command 129) — MV: setup if unseen, insert at the end,
    // capped at maxBattleMembers for the battle line (field order keeps
    // all members).
    pub fn addActor(self: *GameParty, actor_id: i32) void {
        for (self.members.items) |m| {
            if (m == actor_id) return; // already in
        }
        self.members.append(self.alloc, actor_id) catch {};
        log.event(.mv, .note, "party addActor: {d} ('{s}') → {d} member(s)", .{ actor_id, if (self.actors.actor(actor_id)) |a| a.name else "?", self.members.items.len });
    }

    /// removeActor (command 129).
    pub fn removeActor(self: *GameParty, actor_id: i32) void {
        var i: usize = 0;
        while (i < self.members.items.len) {
            if (self.members.items[i] == actor_id) {
                _ = self.members.orderedRemove(i);
            } else i += 1;
        }
        log.event(.mv, .note, "party removeActor: {d} → {d} member(s)", .{ actor_id, self.members.items.len });
    }

    /// numItems for gameDataOperand / hasItem.
    pub fn numItems(self: *const GameParty, item_id: i32) i64 {
        return @intCast(self.items.get(item_id) orelse 0);
    }

    /// numWeapons / numArmors.
    pub fn numWeapons(self: *const GameParty, id: i32) i64 {
        return @intCast(self.weapons.get(id) orelse 0);
    }

    pub fn numArmors(self: *const GameParty, id: i32) i64 {
        return @intCast(self.armors.get(id) orelse 0);
    }
};

// ---------------------------------------------------------------------------
// Game_Troop (initial state — battle milestone fills the rest)
// ---------------------------------------------------------------------------

pub const GameTroop = struct {
    in_battle: bool = false,
    troop_id: i32 = 0,
    turn_count: i32 = 0,

    pub fn init() GameTroop {
        return .{};
    }
};

// ---------------------------------------------------------------------------
// Game_Followers
// ---------------------------------------------------------------------------

pub const GameFollowers = struct {
    visible: bool = true,
    gathering: bool = false,
    /// follower slot index → actor id (resolved at setup from party).
    member_slots: std.ArrayList(i32) = .empty,

    pub fn init(opt_followers: bool) GameFollowers {
        return .{ .visible = opt_followers };
    }

    pub fn setup(self: *GameFollowers, alloc: std.mem.Allocator, party: *const GameParty) void {
        self.member_slots.clearRetainingCapacity();
        // MV Game_Followers.initialize: one follower SLOT per battle
        // member 1..maxBattleMembers-1 — regardless of current party
        // size (Game_Follower.actor() resolves to null for empty slots;
        // the follower just does not draw).
        const n = party.maxBattleMembers();
        const members = party.members.items;
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const actor_id: i32 = if (i < members.len) members[i] else 0; // 0 = empty slot
            self.member_slots.append(alloc, actor_id) catch {};
        }
    }

    pub fn deinit(self: *GameFollowers, alloc: std.mem.Allocator) void {
        self.member_slots.deinit(alloc);
    }
};

// ---------------------------------------------------------------------------
// Game_Player (transfer semantics only — movement is M7)
// ---------------------------------------------------------------------------

/// Each slot follows the *previous* destination of the character ahead.
pub const FollowerTrailEntry = struct {
    x: i32 = 0,
    y: i32 = 0,
    real_x: f64 = 0,
    real_y: f64 = 0,
    direction: i32 = 2,
    animation: @import("character_animation.zig").CharacterAnimation = .{},

    pub fn relocate(self: *FollowerTrailEntry, x: i32, y: i32, dir: i32) void {
        self.* = .{ .x = x, .y = y, .real_x = @floatFromInt(x), .real_y = @floatFromInt(y), .direction = dir };
    }

    fn chase(self: *FollowerTrailEntry, x: i32, y: i32) void {
        const dx: i32 = if (x > self.x) 1 else if (x < self.x) -1 else 0;
        const dy: i32 = if (y > self.y) 1 else if (y < self.y) -1 else 0;
        if (dx != 0 and (dy == 0 or self.direction == (if (dx > 0) @as(i32, 4) else 6)))
            self.direction = if (dx > 0) 6 else 4
        else if (dy != 0)
            self.direction = if (dy > 0) 2 else 8;
        self.x += dx;
        self.y += dy;
    }

    pub fn moving(self: FollowerTrailEntry) bool {
        return self.real_x != @as(f64, @floatFromInt(self.x)) or self.real_y != @as(f64, @floatFromInt(self.y));
    }

    fn approach(from: f64, target: i32, distance: f64) f64 {
        const to: f64 = @floatFromInt(target);
        return from + std.math.clamp(to - from, -distance, distance);
    }

    fn advance(self: *FollowerTrailEntry, distance: f64, speed: i32) void {
        self.animation.update(self.moving(), false, speed);
        self.real_x = approach(self.real_x, self.x, distance);
        self.real_y = approach(self.real_y, self.y, distance);
    }
};

pub const GamePlayer = struct {
    /// Remaining MV movement points before the next map encounter roll.
    /// null means a transfer or legacy save needs a fresh roll.
    encounter_count: ?f64 = null,
    transferring: bool = false,
    new_map_id: u32 = 0,
    new_x: i32 = 0,
    new_y: i32 = 0,
    new_direction: ?i32 = null,
    fade_type: i32 = 0,
    needs_map_reload: bool = false,
    map_id: u32 = 0,
    x: i32 = 0,
    y: i32 = 0,
    direction: i32 = 2,
    transparent: bool = false,

    /// reserveTransfer(mapId, x, y, d, fadeType).
    pub fn reserveTransfer(self: *GamePlayer, map_id: u32, x: i32, y: i32, direction: ?i32, fade_type: i32) void {
        self.transferring = true;
        self.new_map_id = map_id;
        self.new_x = x;
        self.new_y = y;
        self.new_direction = direction;
        self.fade_type = fade_type;
        log.event(.mv, .note, "reserveTransfer: map {d} ({d},{d}) fade={d}", .{ map_id, x, y, fade_type });
    }

    pub fn isTransferring(self: *const GamePlayer) bool {
        return self.transferring;
    }

    /// performTransfer — requires the new map to be loaded ($dataMap);
    /// Game_Map.setup happens in GameObjects.setupMap.
    pub fn performTransfer(self: *GamePlayer) bool {
        if (!self.transferring) return false;
        if (self.new_direction) |d| self.direction = d;
        self.transferring = false;
        self.map_id = self.new_map_id;
        self.x = self.new_x;
        self.y = self.new_y;
        self.encounter_count = null;
        log.event(.mv, .note, "performTransfer: player at map {d} ({d},{d}) direction={d}", .{ self.map_id, self.x, self.y, self.direction });
        return true;
    }
};

// ---------------------------------------------------------------------------
// Game_Map (setup semantics over the raw map)
// ---------------------------------------------------------------------------

pub const GameMap = struct {
    alloc: std.mem.Allocator,
    db: *database.Database,
    /// v36: back-pointer for the Tiled level variable — set in
    /// GameObjects.create() (currentMapLevel reads/writes var 26).
    owner: ?*GameObjects = null,
    /// v36: YED_Tiled data for this map (null = plain MV map). Points
    /// into DataManager.tiled_map, stable while the map is loaded.
    tiled: ?*const tiled_mod.TiledMap = null,
    interpreter_depth: usize = 0,
    map_id: u32 = 0,
    tileset_id: i32 = 0,
    /// Event presence by index (sparse, index 0 unused).
    events: std.ArrayList(bool) = .empty,
    /// Erased events (command 214): id → true until map re-setup.
    erased_events: std.AutoHashMap(i32, bool),
    visual_routes: @import("event_routes.zig").Routes = .{},
    balloons: @import("balloons.zig").Active = .{},
    /// Parallel common-event ids active on this map.
    common_events: std.ArrayList(i32) = .empty,
    display_x: f64 = 0,
    display_y: f64 = 0,
    name_display: bool = true,
    scripted_scroll: ScriptedScroll = .{},
    parallax_name: []const u8 = "",
    parallax_zero: bool = false,
    parallax_loop_x: bool = false,
    parallax_loop_y: bool = false,
    parallax_sx: i32 = 0,
    parallax_sy: i32 = 0,
    parallax_x: f64 = 0,
    parallax_y: f64 = 0,
    battleback1_name: ?[]const u8 = null,
    battleback2_name: ?[]const u8 = null,
    /// v36: $dataMap.scrollType (1 = vertical loop, 2 = horizontal, 3 =
    /// both) — set in setup(). OMORI maps are all 0 (no looping).
    loop_h: bool = false,
    loop_v: bool = false,
    needs_refresh: bool = true,
    encounter_step: i32 = 30,
    disable_dashing: bool = false,
    width: i32 = 0,
    height: i32 = 0,
    /// v36: how many events the last setupTiledEvents relocated (log only).
    relocated_events: usize = 0,

    pub const ScriptedScroll = struct {
        direction: i32 = 2,
        remaining: f64 = 0,
        speed: f64 = 4,
    };

    pub fn init(alloc: std.mem.Allocator, db: *database.Database) GameMap {
        return .{ .alloc = alloc, .db = db, .erased_events = std.AutoHashMap(i32, bool).init(alloc) };
    }

    pub fn deinit(self: *GameMap) void {
        self.events.deinit(self.alloc);
        self.common_events.deinit(self.alloc);
        self.erased_events.deinit();
        self.visual_routes.clear(self.alloc);
        self.balloons.deinit(self.alloc);
    }

    /// Game_Map.setup(mapId) — from the already-loaded $dataMap (raw).
    pub fn setup(self: *GameMap, raw: *const map_mod.RawMap, map_id: u32) !void {
        self.map_id = map_id;
        self.tileset_id = raw.tileset_id;
        self.display_x = 0;
        self.display_y = 0;
        self.erased_events.clearRetainingCapacity();
        self.visual_routes.clear(self.alloc);
        self.balloons.clearRetainingCapacity();
        self.setupEvents(raw);
        self.setupScroll(raw);
        self.setupParallax(raw);
        self.setupBattleback(raw);
        self.needs_refresh = false;
        self.encounter_step = raw.encounter_step;
        self.disable_dashing = raw.disable_dashing;
        self.width = raw.width;
        self.height = raw.height;
        log.event(.mv, .info, "Game_Map.setup: id={d} ({s}) {d}x{d} tileset={d} events={d}", .{
            map_id, raw.display_name, raw.width, raw.height, raw.tileset_id, raw.eventCount(),
        });
    }

    fn setupEvents(self: *GameMap, raw: *const map_mod.RawMap) void {
        self.events.clearRetainingCapacity();
        for (raw.events.items) |e| {
            self.events.append(self.alloc, e != null) catch {};
        }
    }

    fn setupScroll(self: *GameMap, raw: *const map_mod.RawMap) void {
        self.scripted_scroll = .{};
        // v36: isLoopHorizontal/Vertical from $dataMap.scrollType
        self.loop_h = raw.scroll_type == 2 or raw.scroll_type == 3;
        self.loop_v = raw.scroll_type == 1 or raw.scroll_type == 3;
    }

    fn setupParallax(self: *GameMap, raw: *const map_mod.RawMap) void {
        self.parallax_name = raw.parallax_name;
        self.parallax_zero = false; // ImageManager.isZeroParallax — asset-level check, M6
        self.parallax_loop_x = raw.parallax_loop_x;
        self.parallax_loop_y = raw.parallax_loop_y;
        self.parallax_sx = raw.parallax_sx;
        self.parallax_sy = raw.parallax_sy;
        self.parallax_x = 0;
        self.parallax_y = 0;
    }

    fn setupBattleback(self: *GameMap, raw: *const map_mod.RawMap) void {
        if (raw.specify_battleback) {
            self.battleback1_name = raw.battleback1_name;
            self.battleback2_name = raw.battleback2_name;
        } else {
            self.battleback1_name = null;
            self.battleback2_name = null;
        }
    }

    // -----------------------------------------------------------------
    // v36: YED_Tiled Game_Map overrides
    // -----------------------------------------------------------------

    /// YED's Game_Map.setup override, second half — attach the Tiled
    /// data, replace $dataMap.width/height with the Tiled dims, reset
    /// the level variable (setup → `currentMapLevel = 0` → var 26),
    /// relocate events onto their objectgroup markers and report the
    /// level build. Call right after setup(); `raw` must be the map
    /// this `tiled` belongs to (the arena copy is mutated in place).
    pub fn setupTiled(self: *GameMap, raw: *map_mod.RawMap, tiled: *const tiled_mod.TiledMap) void {
        self.tiled = tiled;
        self.width = tiled.width;
        self.height = tiled.height;
        self.setCurrentMapLevel(0);
        self.setupTiledEvents(raw, tiled);
        log.event(.mv, .info, "Game_Map tiled setup: {d}x{d} tiles, {d}x{d} px, {d} level(s), {d} event(s) relocated", .{
            tiled.width, tiled.height, tiled.tile_w, tiled.tile_h, tiled.levels.len, self.relocated_events,
        });
    }

    /// YED `Game_Map._setupTiledEvents` — objectgroup objects with
    /// `properties.eventId` relocate the matching MV event to
    /// `floor(obj.x/tw), floor(obj.y/th)` (half-tile offset skipped:
    /// the payload's param is false). `_events[id]` is 1-indexed and
    /// the raw list matches (index 0 unused).
    fn setupTiledEvents(self: *GameMap, raw: *map_mod.RawMap, tiled: *const tiled_mod.TiledMap) void {
        self.relocated_events = 0;
        const tw: f64 = @floatFromInt(tiled.tile_w);
        const th: f64 = @floatFromInt(tiled.tile_h);
        for (tiled.layers) |layer| {
            if (layer.kind != .objectgroup) continue;
            for (layer.objects) |obj| {
                if (obj.event_id <= 0) continue;
                const idx: usize = @intCast(obj.event_id);
                if (idx >= raw.events.items.len) continue;
                const slot = &(raw.events.items[idx]);
                if (slot.*) |*ev| {
                    ev.x = @intFromFloat(@floor(obj.x / tw));
                    ev.y = @intFromFloat(@floor(obj.y / th));
                    self.relocated_events += 1;
                }
            }
        }
    }

    pub fn isTiled(self: *const GameMap) bool {
        return self.tiled != null;
    }

    /// YED `Game_Map.currentMapLevel` getter — the Map Level Variable
    /// (param 26; `parseInt(param)` truthy → $gameVariables.value).
    pub fn currentMapLevel(self: *const GameMap) i32 {
        const o = self.owner orelse return 0;
        return @intCast(std.math.clamp(o.variables.value(tiled_mod.MAP_LEVEL_VAR), -1_000_000, 1_000_000));
    }

    /// YED `Game_Map.currentMapLevel` setter — $gameVariables.setValue.
    pub fn setCurrentMapLevel(self: *GameMap, lv: i32) void {
        const o = self.owner orelse return;
        o.variables.setValue(tiled_mod.MAP_LEVEL_VAR, lv);
    }

    /// YED `Game_Map.isPassable` override (Tiled): the source tile's
    /// arrow bits gate the direction, then collision. Plain maps keep
    /// the MV passage semantics — callers branch on isTiled().
    pub fn tiledIsPassable(self: *const GameMap, x: i32, y: i32, d: i32) bool {
        const t = self.tiled orelse return true;
        return t.isPassable(self.currentMapLevel(), x, y, d);
    }

    /// A player step requires the source's outgoing edge and the
    /// destination's incoming edge to be passable, matching MV/YED.
    pub fn tiledCanStep(self: *const GameMap, x: i32, y: i32, d: i32) bool {
        const t = self.tiled orelse return true;
        return t.canStep(self.currentMapLevel(), x, y, d);
    }

    /// Find a one-cell recovery for a pre-v39 native save made after the
    /// source-only collision bug admitted a solid tile. This never moves
    /// the player itself: the load caller consumes the opt-in once, then
    /// applies the result in memory without overwriting the save file.
    pub fn findLegacyCollisionRecovery(self: *const GameMap, raw: *const map_mod.RawMap, game: *const GameObjects) !?[2]i32 {
        if (!game.temp.legacy_collision_recovery or game.temp.player_movement_stopped or
            game.player.transparent or game.player.isTransferring() or
            !game.system.menu_enabled or !game.system.save_enabled) return null;
        if (self.findAutorunEvent(raw, game) != null) return null;
        const t = self.tiled orelse return null;
        const level = self.currentMapLevel();
        const x = game.player.x;
        const y = game.player.y;
        if (!t.isSolid(level, x, y)) return null;

        // Prefer backtracking, but never infer which side of a wall is
        // correct: all candidate cells must be connected without crossing
        // the trapped cell, an active event, or a map-level transition.
        const reverse: i32 = switch (game.player.direction) {
            2, 4, 6, 8 => 10 - game.player.direction,
            else => 8,
        };
        const directions = [_]i32{ reverse, 2, 4, 6, 8 };
        var candidates: [4][2]i32 = undefined;
        var n: usize = 0;
        for (directions) |d| {
            const nx = x + (if (d == 4) @as(i32, -1) else if (d == 6) @as(i32, 1) else 0);
            const ny = y + (if (d == 8) @as(i32, -1) else if (d == 2) @as(i32, 1) else 0);
            if (!self.legacyRecoveryFloor(raw, game, nx, ny)) continue;
            var duplicate = false;
            for (candidates[0..n]) |p| if (p[0] == nx and p[1] == ny) {
                duplicate = true;
                break;
            };
            if (!duplicate) {
                candidates[n] = .{ nx, ny };
                n += 1;
            }
        }
        if (n == 0) return null;
        const width: usize = @intCast(t.width);
        const count = width * @as(usize, @intCast(t.height));
        const visited = try self.alloc.alloc(bool, count);
        defer self.alloc.free(visited);
        @memset(visited, false);
        const queue = try self.alloc.alloc([2]i32, count);
        defer self.alloc.free(queue);
        queue[0] = candidates[0];
        visited[@as(usize, @intCast(queue[0][1])) * width + @as(usize, @intCast(queue[0][0]))] = true;
        var head: usize = 0;
        var tail: usize = 1;
        const moves = [_][3]i32{ .{ 0, -1, 8 }, .{ -1, 0, 4 }, .{ 1, 0, 6 }, .{ 0, 1, 2 } };
        while (head < tail) : (head += 1) {
            const p = queue[head];
            for (moves) |move| {
                const nx = p[0] + move[0];
                const ny = p[1] + move[1];
                if (!t.canStep(level, p[0], p[1], move[2]) or !self.legacyRecoveryFloor(raw, game, nx, ny)) continue;
                const index = @as(usize, @intCast(ny)) * width + @as(usize, @intCast(nx));
                if (visited[index]) continue;
                visited[index] = true;
                queue[tail] = .{ nx, ny };
                tail += 1;
            }
        }
        if (tail < 2) return null; // A cell with no legal exit is no recovery.
        for (candidates[0..n]) |p| {
            if (!visited[@as(usize, @intCast(p[1])) * width + @as(usize, @intCast(p[0]))]) return null;
        }
        return candidates[0];
    }

    fn legacyRecoveryFloor(self: *const GameMap, raw: *const map_mod.RawMap, game: *const GameObjects, x: i32, y: i32) bool {
        const t = self.tiled orelse return false;
        const level = self.currentMapLevel();
        if (!t.isPassable(level, x, y, 0) or t.levelChangeAt(level, x, y) != null) return false;
        for (raw.events.items) |maybe_event| {
            const event = maybe_event orelse continue;
            if (event.x == x and event.y == y and self.currentPage(raw, event.id, game) != null) return false;
        }
        return true;
    }

    /// YED `Game_Map.regionId` override (Tiled): regions[level][x + w*y].
    pub fn tiledRegionId(self: *const GameMap, x: i32, y: i32) i32 {
        const t = self.tiled orelse return 0;
        return t.regionId(self.currentMapLevel(), x, y);
    }

    pub fn encounterRegion(self: *const GameMap, raw: *const map_mod.RawMap, x: i32, y: i32, arriving: bool) i32 {
        const tiled = self.tiled orelse return encounter_mod.plainRegion(raw, x, y);
        const level = self.currentMapLevel();
        const destination_level = if (arriving) tiled.levelChangeAt(level, x, y) orelse level else level;
        return tiled.regionId(destination_level, x, y);
    }

    /// YED `Game_Map.checkMapLevelChanging` — when the tile switches
    /// levels, write the new level (var 26) and report it. Called every
    /// frame for the player's tile (YED: Game_Player update hook).
    pub fn checkMapLevelChanging(self: *GameMap, x: i32, y: i32) bool {
        const t = self.tiled orelse return false;
        if (t.levelChangeAt(self.currentMapLevel(), x, y)) |lv| {
            self.setCurrentMapLevel(lv);
            log.event(.mv, .note, "map level changed → {d} at ({d},{d})", .{ lv, x, y });
            return true;
        }
        return false;
    }

    // -----------------------------------------------------------------
    // v36: MV camera — Game_Map screen/scrolled/scroll + Game_Player
    // center. Graphics.width/height = 640×480; tileWidth 48 (MV) or the
    // Tiled map's tilewidth (32; the payload's "Half-tile movement"
    // plugin param is false → no halving).
    // -----------------------------------------------------------------

    pub const SCREEN_W: f64 = @floatFromInt(@import("../core/canvas.zig").WIDTH);
    pub const SCREEN_H: f64 = @floatFromInt(@import("../core/canvas.zig").HEIGHT);

    /// Game_Map.tileWidth (YED override when Tiled).
    pub fn tileWidth(self: *const GameMap) i32 {
        if (self.tiled) |t| return t.tile_w;
        return 48;
    }

    /// Game_Map.tileHeight (YED override when Tiled).
    pub fn tileHeight(self: *const GameMap) i32 {
        if (self.tiled) |t| return t.tile_h;
        return 48;
    }

    pub fn isLoopHorizontal(self: *const GameMap) bool {
        return self.loop_h;
    }

    pub fn isLoopVertical(self: *const GameMap) bool {
        return self.loop_v;
    }

    /// Game_Map.screenTileX — Graphics.width / tileWidth, NOT floored
    /// (13⅓ @48px, 20 @32px).
    pub fn screenTileX(self: *const GameMap) f64 {
        return SCREEN_W / @as(f64, @floatFromInt(self.tileWidth()));
    }

    /// Game_Map.screenTileY — Graphics.height / tileHeight.
    pub fn screenTileY(self: *const GameMap) f64 {
        return SCREEN_H / @as(f64, @floatFromInt(self.tileHeight()));
    }

    /// Game_Player.centerX — (screenTileX − 1) / 2 (9.5 @32px).
    pub fn playerCenterX(self: *const GameMap) f64 {
        return (self.screenTileX() - 1.0) / 2.0;
    }

    /// Game_Player.centerY — (screenTileY − 1) / 2 (7 @32px).
    pub fn playerCenterY(self: *const GameMap) f64 {
        return (self.screenTileY() - 1.0) / 2.0;
    }

    /// Game_Map.setDisplayPos — loop: x.mod(width); non-loop: endX < 0
    /// → endX / 2 (small maps center), else clamp(x, 0, endX). The
    /// parallax origin follows the display pos (non-loop branch).
    pub fn setDisplayPos(self: *GameMap, x: f64, y: f64) void {
        const w = @as(f64, @floatFromInt(self.width));
        const h = @as(f64, @floatFromInt(self.height));
        if (self.isLoopHorizontal()) {
            self.display_x = jsMod(x, w);
            self.parallax_x = x;
        } else {
            const end_x = w - self.screenTileX();
            self.display_x = if (end_x < 0) end_x / 2.0 else std.math.clamp(x, 0.0, end_x);
            self.parallax_x = self.display_x;
        }
        if (self.isLoopVertical()) {
            self.display_y = jsMod(y, h);
            self.parallax_y = y;
        } else {
            const end_y = h - self.screenTileY();
            self.display_y = if (end_y < 0) end_y / 2.0 else std.math.clamp(y, 0.0, end_y);
            self.parallax_y = self.display_y;
        }
    }

    /// JS `((v % m) + m) % m` — the sign follows the divisor (Zig @mod).
    fn jsMod(v: f64, m: f64) f64 {
        return @mod(v, m);
    }

    /// Game_CharacterBase.scrolledX → Game_Map.adjustX(_realX).
    pub fn scrolledX(self: *const GameMap, real: f64) f64 {
        if (self.isLoopHorizontal()) {
            const w = @as(f64, @floatFromInt(self.width));
            if (real < self.display_x - (w - self.screenTileX()) / 2.0) {
                return real - self.display_x + w;
            }
        }
        return real - self.display_x;
    }

    /// Game_CharacterBase.scrolledY → Game_Map.adjustY(_realY).
    pub fn scrolledY(self: *const GameMap, real: f64) f64 {
        if (self.isLoopVertical()) {
            const h = @as(f64, @floatFromInt(self.height));
            if (real < self.display_y - (h - self.screenTileY()) / 2.0) {
                return real - self.display_y + h;
            }
        }
        return real - self.display_y;
    }

    pub fn isScrolling(self: *const GameMap) bool {
        return self.scripted_scroll.remaining > 0;
    }

    pub fn startScriptedScroll(self: *GameMap, direction: i32, distance: f64, speed: f64) void {
        if (!std.math.isFinite(distance) or distance <= 0 or !std.math.isFinite(speed)) return;
        switch (direction) {
            2, 4, 6, 8 => self.scripted_scroll = .{
                .direction = direction,
                .remaining = @min(distance, std.math.maxInt(i32)),
                .speed = std.math.clamp(speed, 0, 8),
            },
            else => {},
        }
    }

    /// Advance an authored pan in tile units, using the same clamping and
    /// parallax displacement as the map's ordinary camera movement.
    pub fn updateScriptedScroll(self: *GameMap) void {
        if (!self.isScrolling()) return;
        const previous_x = self.display_x;
        const previous_y = self.display_y;
        const scroll = &self.scripted_scroll;
        const step = @min(scroll.remaining, @exp2(scroll.speed) / 256.0);
        switch (scroll.direction) {
            2 => self.scrollDown(step),
            4 => self.scrollLeft(step),
            6 => self.scrollRight(step),
            8 => self.scrollUp(step),
            else => {},
        }
        // A pan may reach an edge, including small maps that cannot scroll.
        scroll.remaining = if (self.display_x == previous_x and self.display_y == previous_y) 0 else scroll.remaining - step;
    }

    /// Game_Map.scrollDown — non-loop runs only when height ≥
    /// screenTileY: min(displayY + d, height − screenTileY). Parallax
    /// accumulates the APPLIED delta (clamped-zone walks accumulate).
    pub fn scrollDown(self: *GameMap, distance: f64) void {
        const h = @as(f64, @floatFromInt(self.height));
        if (self.isLoopVertical()) {
            self.display_y = jsMod(self.display_y + distance, h);
            if (self.parallax_loop_y) self.parallax_y += distance;
        } else if (h >= self.screenTileY()) {
            const last = self.display_y;
            self.display_y = @min(self.display_y + distance, h - self.screenTileY());
            self.parallax_y += self.display_y - last;
        }
    }

    /// Game_Map.scrollLeft — non-loop: max(displayX − d, 0).
    pub fn scrollLeft(self: *GameMap, distance: f64) void {
        const w = @as(f64, @floatFromInt(self.width));
        if (self.isLoopHorizontal()) {
            self.display_x = jsMod(self.display_x + (w - distance), w);
            if (self.parallax_loop_x) self.parallax_x -= distance;
        } else if (w >= self.screenTileX()) {
            const last = self.display_x;
            self.display_x = @max(self.display_x - distance, 0.0);
            self.parallax_x += self.display_x - last;
        }
    }

    /// Game_Map.scrollRight — non-loop: min(displayX + d, width − screenTileX).
    pub fn scrollRight(self: *GameMap, distance: f64) void {
        const w = @as(f64, @floatFromInt(self.width));
        if (self.isLoopHorizontal()) {
            self.display_x = jsMod(self.display_x + distance, w);
            if (self.parallax_loop_x) self.parallax_x += distance;
        } else if (w >= self.screenTileX()) {
            const last = self.display_x;
            self.display_x = @min(self.display_x + distance, w - self.screenTileX());
            self.parallax_x += self.display_x - last;
        }
    }

    /// Game_Map.scrollUp — non-loop: max(displayY − d, 0).
    pub fn scrollUp(self: *GameMap, distance: f64) void {
        const h = @as(f64, @floatFromInt(self.height));
        if (self.isLoopVertical()) {
            self.display_y = jsMod(self.display_y + (h - distance), h);
            if (self.parallax_loop_y) self.parallax_y -= distance;
        } else if (h >= self.screenTileY()) {
            const last = self.display_y;
            self.display_y = @max(self.display_y - distance, 0.0);
            self.parallax_y += self.display_y - last;
        }
    }

    /// parallelCommonEvents(): $dataCommonEvents with trigger === 2.
    pub fn setupParallelCommonEvents(self: *GameMap, common_events: []const json.Value) void {
        self.common_events.clearRetainingCapacity();
        for (common_events, 0..) |ce, i| {
            if (ce == .null) continue;
            const trigger = ce.getInt("trigger", 0);
            if (trigger == 2) {
                const id: i32 = @intCast(ce.getInt("id", @intCast(i)));
                self.common_events.append(self.alloc, id) catch {};
            }
        }
        if (self.common_events.items.len > 0) {
            log.detail(.mv, "parallel common events: {d}", .{self.common_events.items.len});
        }
    }

    pub fn requestRefresh(self: *GameMap) void {
        self.needs_refresh = true;
    }

    /// eraseEvent (command 214) — MV marks the event erased until map
    /// re-setup.
    pub fn eraseEvent(self: *GameMap, event_id: i32) void {
        _ = self.balloons.remove(event_id);
        self.erased_events.put(event_id, true) catch {};
        self.visual_routes.remove(self.alloc, event_id);
        log.event(.mv, .note, "eraseEvent: {d} on map {d}", .{ event_id, self.map_id });
    }

    pub fn isEventErased(self: *const GameMap, event_id: i32) bool {
        return self.erased_events.contains(event_id);
    }

    /// The event's CURRENT page (MV: highest-numbered page whose
    /// conditions all pass; the event's trigger comes from THIS page).
    /// Page conditions the interpreter owns: switches / self switch /
    /// variables (actor/item conditions are rare and evaluate ON
    /// only if the actor/item is present — treated as valid here).
    pub fn currentPage(self: *const GameMap, raw: *const map_mod.RawMap, event_id: i32, game: anytype) ?*const map_mod.Page {
        if (event_id <= 0 or event_id >= raw.events.items.len) return null;
        const ev = raw.events.items[@intCast(event_id)] orelse return null;
        if (self.isEventErased(event_id)) return null;
        var pi = ev.pages.items.len;
        while (pi > 0) {
            pi -= 1;
            const page = &ev.pages.items[pi];
            const c = page.condition;
            if (c.switch1_valid and !game.switches.value(@intCast(@max(c.switch1_id, 1)))) continue;
            if (c.switch2_valid and !game.switches.value(@intCast(@max(c.switch2_id, 1)))) continue;
            if (c.self_switch_valid) {
                if (!game.self_switches.value(self.map_id, event_id, c.self_switch_ch)) continue;
            }
            if (c.variable_valid) {
                if (game.variables.value(@intCast(@max(c.variable_id, 1))) < c.variable_value) continue;
            }
            if (c.item_valid and game.party.numItems(c.item_id) <= 0) continue;
            if (c.actor_valid and std.mem.indexOfScalar(i32, game.party.members.items, c.actor_id) == null) continue;
            return page;
        }
        return null;
    }

    /// Find the first (lowest id) event whose CURRENT page is an autorun
    /// (trigger 3) — MV Game_Map.setupStartingEvent order.
    pub fn findAutorunEvent(self: *const GameMap, raw: *const map_mod.RawMap, game: anytype) ?struct { event_id: i32, page: *const map_mod.Page } {
        for (raw.events.items, 0..) |ev_opt, idx| {
            if (ev_opt == null) continue;
            const event_id: i32 = @intCast(idx);
            if (self.isEventErased(event_id)) continue;
            if (self.currentPage(raw, event_id, game)) |page| {
                if (page.trigger == 3) {
                    return .{ .event_id = event_id, .page = page };
                }
            }
        }
        return null;
    }
};

// ---------------------------------------------------------------------------
// GameObjects — the $gameXxx set as one owned structure
// ---------------------------------------------------------------------------

pub const GameObjects = struct {
    alloc: std.mem.Allocator,
    db: *database.Database,
    /// Guard: fields below are undefined until create() succeeds.
    created: bool = false,
    /// Strings imported from a save outlive the load transaction. A new
    /// successful load replaces this storage after copying live values.
    retained_save_strings: ?std.heap.ArenaAllocator = null,

    temp: GameTemp,
    system: GameSystem,
    screen: GameScreen,
    timer: GameTimer,
    message: GameMessage,
    switches: Switches,
    variables: Variables,
    self_switches: GameSelfSwitches,
    self_variables: GameSelfVariables,
    actors: GameActors,
    party: GameParty,
    troop: battle_mod.Troop,
    followers: GameFollowers,
    /// v28: follower trail slots (up to 3 behind the player).
    followers_trail: [3]FollowerTrailEntry = .{ .{}, .{}, .{} },
    map: GameMap,
    player: GamePlayer,

    savefile_id: i32 = 0,
    /// Graphics.frameCount — the interpreter's freeze checker clock.
    frame_count_global: u64 = 0,

    fn switchCount(self: *const GameObjects) usize {
        const f = self.db.get("data/System.json") orelse return 0;
        if (f.value.get("switches")) |s| return s.arrayItems().len;
        return 0;
    }

    fn variableCount(self: *const GameObjects) usize {
        const f = self.db.get("data/System.json") orelse return 0;
        if (f.value.get("variables")) |v| return v.arrayItems().len;
        return 0;
    }

    pub fn followerActor(self: *GameObjects, slot: usize) ?*GameActor {
        if (self.player.transparent or !self.followers.visible or slot + 1 >= self.party.members.items.len) return null;
        return self.actors.actor(self.party.members.items[slot + 1]);
    }

    pub fn synchronizeFollowers(self: *GameObjects) void {
        for (&self.followers_trail) |*slot| slot.relocate(self.player.x, self.player.y, self.player.direction);
        self.followers.gathering = false;
    }

    pub fn chaseFollowers(self: *GameObjects) void {
        var i = self.followers_trail.len;
        while (i > 0) {
            i -= 1;
            if (i == 0) self.followers_trail[i].chase(self.player.x, self.player.y) else {
                const previous = self.followers_trail[i - 1];
                self.followers_trail[i].chase(previous.x, previous.y);
            }
        }
    }

    pub fn updateFollowers(self: *GameObjects, distance: f64, speed: i32) void {
        if (self.followers.gathering) {
            const count = if (self.followers.visible) @min(self.followers_trail.len, self.party.members.items.len -| 1) else 0;
            var moving = false;
            var gathered = true;
            for (self.followers_trail[0..count]) |slot| {
                moving = moving or slot.moving();
                gathered = gathered and slot.x == self.player.x and slot.y == self.player.y;
            }
            if (!moving) {
                if (gathered) self.followers.gathering = false else self.chaseFollowers();
            }
        }
        for (&self.followers_trail) |*slot| slot.advance(distance, speed);
    }

    pub fn optFollowers(self: *const GameObjects) bool {
        const f = self.db.get("data/System.json") orelse return true;
        return f.value.getBool("optFollowers", true);
    }

    /// createGameObjects — MV construction order. After success,
    /// deinit() owns and frees everything.
    pub fn create(self: *GameObjects) !void {
        if (self.created) self.deinit();
        self.created = false;
        self.temp = GameTemp.init();
        self.system = GameSystem.init();
        self.screen = GameScreen.init(self.alloc);
        self.timer = GameTimer.init();
        self.message = GameMessage.init(self.alloc);
        self.switches = try Switches.init(self.alloc, self.switchCount());
        self.variables = try Variables.init(self.alloc, self.variableCount());
        self.self_switches = GameSelfSwitches.init(self.alloc);
        self.self_variables = GameSelfVariables.init(self.alloc);
        self.actors = GameActors.init(self.alloc, self.db);
        self.party = GameParty.init(self.alloc, self.db, &self.actors);
        self.troop = battle_mod.Troop.init(self.alloc, self.db);
        self.followers = GameFollowers.init(self.optFollowers());
        self.map = GameMap.init(self.alloc, self.db);
        self.map.owner = self; // v36: the Tiled level variable path
        self.player = GamePlayer{};
        self.created = true;
        log.detail(.mv, "GameObjects created: switches={d} variables={d} optFollowers={s}", .{
            self.switches.values.len - 1, self.variables.values.len - 1, if (self.followers.visible) "true" else "false",
        });
    }

    pub fn init(alloc: std.mem.Allocator, db: *database.Database) GameObjects {
        return .{
            .alloc = alloc,
            .db = db,
            .temp = GameTemp.init(),
            .system = GameSystem.init(),
            .screen = GameScreen.init(alloc),
            .timer = GameTimer.init(),
            .message = GameMessage.init(alloc),
            .switches = undefined,
            .variables = undefined,
            .self_switches = undefined,
            .self_variables = undefined,
            .actors = undefined,
            .party = undefined,
            .troop = undefined,
            .followers = undefined,
            .map = undefined,
            .player = .{},
        };
    }

    /// Full teardown (all owned state). Safe before create().
    pub fn deinit(self: *GameObjects) void {
        if (!self.created) return;
        self.switches.deinit();
        self.variables.deinit();
        self.self_switches.deinit();
        self.self_variables.deinit();
        self.party.deinit();
        self.actors.deinit();
        self.troop.deinit();
        self.followers.deinit(self.alloc);
        self.map.deinit();
        self.message.deinit();
        self.screen.deinit();
        if (self.retained_save_strings) |*retained| retained.deinit();
        self.retained_save_strings = null;
        self.created = false;
    }

    /// selectSavefileForNewGame: first editable slot → 1 (no saves yet).
    pub fn selectSavefileForNewGame(self: *GameObjects) void {
        self.savefile_id = 1;
        log.detail(.mv, "selectSavefileForNewGame: slot {d}", .{self.savefile_id});
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "message ownership: generated battle text is released on close and teardown" {
    var message = GameMessage.init(testing.allocator);
    defer message.deinit();
    for (0..32) |_| {
        message.add("Borrowed language text");
        message.addOwned(try testing.allocator.dupe(u8, "Generated battle text"));
        try testing.expectEqualStrings("Generated battle text", message.texts.items[1]);
        message.clear();
        try testing.expectEqual(@as(usize, 0), message.owned_texts.items.len);
    }
    message.addOwned(try testing.allocator.dupe(u8, "Closed by teardown"));
}

fn makeTestDb(alloc: std.mem.Allocator, comptime files: []const [2][]const u8) !database.Database {
    const root = "/tmp/omori-game-test";
    std.fs.cwd().deleteTree(root) catch {};
    const vfs = try alloc.create(vfs_mod.Vfs);
    vfs.* = vfs_mod.Vfs.init(alloc, root, "/tmp/omori-game-save");
    {
        const data_dir = try std.fs.path.join(alloc, &.{ root, "data" });
        defer alloc.free(data_dir);
        try std.fs.cwd().makePath(data_dir);
    }
    for (files) |f| {
        const p = try std.fs.path.join(alloc, &.{ root, "data", f[0] });
        defer alloc.free(p);
        var file = try std.fs.cwd().createFile(p, .{});
        defer file.close();
        try file.writeAll(f[1]);
    }
    var db = database.Database.init(alloc, vfs);
    for (files) |f| {
        const p = try std.fmt.allocPrint(alloc, "data/{s}", .{f[0]});
        defer alloc.free(p);
        _ = try db.loadFile(.database, p);
    }
    return db;
}

fn destroyTestDb(alloc: std.mem.Allocator, db: *database.Database) void {
    db.vfs.deinit();
    alloc.destroy(db.vfs);
    db.deinit();
}

test "screen effects: flash decay and shake settle without changing fades" {
    var screen = GameScreen.init(testing.allocator);
    defer screen.deinit();
    screen.startFlash(.{ 255, 120, 30, 200 }, 4);
    screen.startFadeOut(8);
    screen.update();
    try testing.expectEqual(@as(i32, 150), screen.flash_color[3]);
    for (0..3) |_| screen.update();
    try testing.expectEqual(@as(i32, 0), screen.flash_color[3]);
    try testing.expectEqual(@as(i32, 0), screen.flash_duration);
    try testing.expectEqual(@as(i32, 4), screen.fade_out_duration);
    screen.startShake(5, 5, 20);
    var positive = false;
    var negative = false;
    for (0..100) |_| {
        screen.update();
        positive = positive or screen.shake > 0;
        negative = negative or screen.shake < 0;
    }
    try testing.expect(positive and negative);
    try testing.expectEqual(@as(f64, 0), screen.shake);
    try testing.expectEqual(@as(i32, 0), screen.shake_duration);
    try testing.expectEqual(@as(i32, 0), screen.brightness);
    screen.startShake(0, 5, 20);
    screen.update();
    try testing.expectEqual(@as(f64, 0), screen.shake);
}

test "screen transitions: tint duration zero, one and neutral completion" {
    var screen = GameScreen.init(testing.allocator);
    defer screen.deinit();
    screen.startTint(.{ 240, -120, 60, 180 }, 0);
    try testing.expectEqual([4]i32{ 240, -120, 60, 180 }, screen.tone);
    screen.startTint(.{ 0, 0, 0, 0 }, 4);
    screen.update();
    try testing.expectEqual([4]i32{ 180, -90, 45, 135 }, screen.tone);
    for (0..3) |_| screen.update();
    try testing.expectEqual([4]i32{ 0, 0, 0, 0 }, screen.tone);
    try testing.expectEqual(@as(i32, 0), screen.tone_duration);
    screen.startTint(.{ 255, 255, 255, 255 }, 1);
    screen.update();
    try testing.expectEqual([4]i32{ 255, 255, 255, 255 }, screen.tone);
    screen.startTint(.{ 0, 0, 0, 0 }, 1);
    screen.update();
    try testing.expectEqual([4]i32{ 0, 0, 0, 0 }, screen.tone);
}

test "message pages: wrapped overflow advances before a trailing choice" {
    var message = GameMessage.init(testing.allocator);
    defer message.texts.deinit(testing.allocator);
    defer message.choices.deinit(testing.allocator);
    message.add("one long raw entry with six wrapped display lines");
    message.display_line_count = 6;
    message.setChoices(&.{ "YES", "NO" }, 0, -2);
    message.update(true, false, null);
    try testing.expectEqual(@as(usize, 1), message.page_index);
    try testing.expect(message.isBusy());
    try testing.expectEqual(@as(?i32, null), message.choice_result);
    message.choice_index = 1;
    message.update(true, false, null);
    try testing.expect(!message.isBusy());
    try testing.expectEqual(@as(?i32, 1), message.choice_result);
}

test "screen transitions: fades reverse from current brightness and picture moves stay linear" {
    var screen = GameScreen.init(testing.allocator);
    defer screen.deinit();
    screen.brightness = 240;
    screen.startFadeOut(4);
    screen.update();
    try testing.expectEqual(@as(i32, 180), screen.brightness);
    screen.startFadeIn(3);
    try testing.expectEqual(@as(i32, 0), screen.fade_out_duration);
    try testing.expectEqual(@as(i32, 180), screen.brightness);
    screen.update();
    try testing.expectEqual(@as(i32, 205), screen.brightness);
    screen.update();
    screen.update();
    try testing.expectEqual(@as(i32, 255), screen.brightness);
    screen.startFadeOut(1);
    screen.update();
    try testing.expectEqual(@as(i32, 0), screen.brightness);
    screen.startFadeIn(1);
    screen.update();
    try testing.expectEqual(@as(i32, 255), screen.brightness);
    screen.startFadeOut(0);
    screen.update();
    try testing.expectEqual(@as(i32, 255), screen.brightness);
    screen.showPicture(2, "door", 0, 0, 0, 100, 100, 0, 0);
    screen.movePicture(2, 0, 240, -120, 140, 60, 240, 0, 4);
    for (1..5) |step| {
        screen.update();
        const picture_value = screen.picture(2).?;
        try testing.expectEqual(@as(i32, @intCast(step)) * 60, picture_value.x);
        try testing.expectEqual(-@as(i32, @intCast(step)) * 30, picture_value.y);
        try testing.expectEqual(@as(i32, @intCast(step)) * 60, picture_value.opacity);
    }
    screen.movePicture(2, 0, 10, 20, 100, 100, 255, 0, 0);
    try testing.expectEqual(@as(i32, 10), screen.picture(2).?.x);
    try testing.expectEqual(@as(i32, 255), screen.picture(2).?.opacity);
}

test "screen pictures: retain names after caller storage changes and release replacements" {
    var screen = GameScreen.init(testing.allocator);
    defer screen.deinit();
    var name = [_]u8{ 'd', 'o', 'o', 'r' };
    screen.showPicture(1, &name, 0, 0, 0, 100, 100, 255, 0);
    @memset(&name, 'x');
    try testing.expectEqualStrings("door", screen.picture(1).?.name);
    screen.showPicture(1, "next", 0, 0, 0, 100, 100, 255, 0);
    try testing.expectEqualStrings("next", screen.picture(1).?.name);
    screen.erasePicture(1);
    try testing.expect(screen.picture(1) == null);
}

test "GameObjects: repeated new game releases previous owned state" {
    const a = testing.allocator;
    var db = try makeTestDb(a, &.{.{ "System.json", "{\"switches\":[null,\"A\"],\"variables\":[null,\"V\"]}" }});
    defer destroyTestDb(a, &db);
    var game = GameObjects.init(a, &db);
    defer game.deinit();
    for (0..3) |_| {
        try game.create();
        game.self_switches.setValue(87, 2, "A", true);
        game.screen.showPicture(2, "ws_door", 0, 0, 0, 100, 100, 255, 0);
    }
}

test "GameObjects: create + starting members + new game flow" {
    const alloc = testing.allocator;
    var db = try makeTestDb(alloc, &.{
        .{ "System.json", "{\"gameTitle\":\"OMORI\",\"partyMembers\":[1,2],\"startMapId\":3,\"startX\":5,\"startY\":6,\"switches\":[null,\"A\",\"B\"],\"variables\":[null,\"V\"],\"optFollowers\":true}" },
        .{ "Actors.json", "[null,{\"id\":1,\"name\":\"OMORI\",\"nickname\":\"...\",\"profile\":\"a\",\"classId\":1,\"initialLevel\":1,\"maxLevel\":50,\"equips\":[1],\"characterName\":\"OMORI\",\"faceName\":\"OMORI\"},{\"id\":2,\"name\":\"AUBREY\",\"nickname\":\"\",\"profile\":\"b\",\"classId\":2,\"initialLevel\":1,\"maxLevel\":50,\"equips\":[]}]" },
        .{ "Classes.json", "[null,{\"id\":1,\"name\":\"OMORI class\",\"expParams\":[30,20,30,30],\"params\":[[500,600],[20,30],[15,25],[15,25],[10,15],[10,15],[999,999],[999,999]],\"learnings\":[{\"level\":1,\"skillId\":1},{\"level\":10,\"skillId\":2}]},{\"id\":2,\"name\":\"AUBREY class\",\"expParams\":[25,15,30,30],\"params\":[[400,500],[15,25],[12,20],[12,20],[8,12],[8,12],[99,99],[99,99]],\"learnings\":[{\"level\":1,\"skillId\":3}]}]" },
        .{ "Weapons.json", "[null,{\"id\":1,\"name\":\"KNIFE\",\"params\":[10,0,0,0,0,0,0,0]}]" },
        .{ "Skills.json", "[null,{\"id\":1,\"name\":\"ATTACK\"},{\"id\":2,\"name\":\"OBSERVE\"},{\"id\":3,\"name\":\"HIT\"}]" },
        .{ "Items.json", "[null,{\"id\":1,\"name\":\"TOY BOX\"}]" },
        .{ "MapInfos.json", "[null,{\"id\":1,\"name\":\"MAP1\"},{\"id\":2,\"name\":\"MAP2\"},{\"id\":3,\"name\":\"START\"}]" },
    });
    defer destroyTestDb(alloc, &db);

    var game = GameObjects.init(alloc, &db);
    defer game.deinit();
    try game.create();

    // Switches/variables sized from System.json (1-indexed).
    // values.len = db count + 1 (index 0 is the null slot).
    try testing.expectEqual(@as(usize, 4), game.switches.values.len);
    try testing.expectEqual(@as(usize, 3), game.variables.values.len);

    // Starting members.
    var dm = data_manager_mod.DataManager.init(alloc, &db);
    defer dm.deinit();
    try game.party.setupStartingMembers(&dm);
    try testing.expectEqual(@as(usize, 2), game.party.members.items.len);

    // Actor lazy construction with setup semantics.
    const omori = game.actors.actor(1).?;
    try testing.expectEqualStrings("OMORI", omori.name);
    try testing.expectEqual(@as(i32, 1), omori.level);
    try testing.expectEqual(@as(i32, 1), omori.class_id);
    // Learnings at level <= 1: skill 1 only.
    try testing.expectEqual(@as(usize, 1), omori.skills.items.len);
    // param(0) = class base (params[0][1] = 600) + weapon (10).
    try testing.expectEqual(@as(i64, 610), omori.param(0));
    // recoverAll → hp = param(0).
    try testing.expectEqual(@as(i32, 610), omori.hp);

    // expForLevel formula check (basis=30 extra=20 acc_a=30 acc_b=30):
    // level 2 → round(30*1*2*3/(6+4/50/30)+1*20) = 50.
    const e2 = omori.expForLevel(2);
    try testing.expectEqual(@as(i64, 50), e2);

    // Player transfer.
    game.player.reserveTransfer(3, 5, 6, null, 0);
    try testing.expect(game.player.isTransferring());
    try testing.expect(game.player.performTransfer());
    try testing.expectEqual(@as(u32, 3), game.player.map_id);
    try testing.expectEqual(@as(i32, 5), game.player.x);

    // Self switches.
    game.self_switches.setValue(3, 7, "A", true);
    try testing.expect(game.self_switches.value(3, 7, "A"));
    game.self_switches.setValue(3, 7, "A", false);
    try testing.expect(!game.self_switches.value(3, 7, "A"));

    // Gold & items (command 125/126 surfaces).
    game.party.gainGold(150);
    try testing.expectEqual(@as(i64, 150), game.party.gold);
    game.party.gainItem(1, 3);
    try testing.expectEqual(@as(i32, 3), game.party.items.get(1).?);
    try testing.expectEqualStrings("TOY BOX", game.party.itemName(1));

    // Timer.
    game.timer.start(90);
    try testing.expectEqual(@as(u64, 5400), game.timer.frames);
}

test "GameMap setup from a raw map" {
    const alloc = testing.allocator;
    var db = try makeTestDb(alloc, &.{
        .{ "System.json", "{\"switches\":[null],\"variables\":[null]}" },
        .{ "CommonEvents.json", "[null,{\"id\":1,\"name\":\"PAR\",\"trigger\":1,\"switchId\":5},{\"id\":2,\"name\":\"AUTO\",\"trigger\":2}]" },
    });
    defer destroyTestDb(alloc, &db);

    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const src = "{\"tilesetId\":9,\"width\":17,\"height\":13,\"displayName\":\"FOREST\",\"events\":[null,{\"id\":1}],\"parallaxName\":\"BG1\",\"parallaxLoopX\":true,\"specifyBattleback\":true,\"battleback1Name\":\"BB1\",\"encounterStep\":25,\"disableDashing\":true}";
    var parser = try json.Parser.init(arena.allocator(), src);
    const v = try parser.parse();
    var raw = try map_mod.RawMap.fromJson(arena.allocator(), v);
    defer raw.deinit();

    var gmap = GameMap.init(alloc, &db);
    defer gmap.deinit();
    try gmap.setup(&raw, 42);
    try testing.expectEqual(@as(u32, 42), gmap.map_id);
    try testing.expectEqual(@as(i32, 9), gmap.tileset_id);
    try testing.expectEqual(@as(i32, 25), gmap.encounter_step);
    try testing.expect(gmap.disable_dashing);
    try testing.expect(gmap.parallax_loop_x);
    try testing.expectEqualStrings("BG1", gmap.parallax_name);
    try testing.expectEqualStrings("BB1", gmap.battleback1_name.?);
    try testing.expectEqual(@as(usize, 2), gmap.events.items.len);

    // Parallel common events (trigger == 2).
    const f = db.get("data/CommonEvents.json").?;
    gmap.setupParallelCommonEvents(f.value.arrayItems());
    try testing.expectEqual(@as(usize, 1), gmap.common_events.items.len);
    try testing.expectEqual(@as(i32, 2), gmap.common_events.items[0]);
}

test "GameMap camera: screen tiles + player center (MV + YED 32px)" {
    const alloc = testing.allocator;
    var db = try makeTestDb(alloc, &.{.{ "System.json", "{\"switches\":[null],\"variables\":[null]}" }});
    defer destroyTestDb(alloc, &db);
    var gmap = GameMap.init(alloc, &db);
    defer gmap.deinit();

    // Plain MV map: 640x480 canvas / 48px tiles (fractional X).
    gmap.width = 40;
    gmap.height = 30;
    try testing.expectEqual(@as(i32, 48), gmap.tileWidth());
    try testing.expectEqual(@as(i32, 48), gmap.tileHeight());
    try testing.expectApproxEqAbs(@as(f64, 640.0 / 48.0), gmap.screenTileX(), 0.000001);
    try testing.expectApproxEqAbs(@as(f64, 10.0), gmap.screenTileY(), 0.000001);
    try testing.expectApproxEqAbs(@as(f64, (640.0 / 48.0 - 1.0) / 2.0), gmap.playerCenterX(), 0.000001);
    try testing.expectApproxEqAbs(@as(f64, 4.5), gmap.playerCenterY(), 0.000001);

    // Tiled map: 32px tiles → screenTile 20×15, center 9.5/7.
    var tiled = tiled_mod.TiledMap{ .arena = alloc, .width = 30, .height = 20, .tile_w = 32, .tile_h = 32 };
    gmap.tiled = &tiled;
    try testing.expectEqual(@as(i32, 32), gmap.tileWidth());
    try testing.expectApproxEqAbs(@as(f64, 20.0), gmap.screenTileX(), 0.000001);
    try testing.expectApproxEqAbs(@as(f64, 15.0), gmap.screenTileY(), 0.000001);
    try testing.expectApproxEqAbs(@as(f64, 9.5), gmap.playerCenterX(), 0.000001);
    try testing.expectApproxEqAbs(@as(f64, 7.0), gmap.playerCenterY(), 0.000001);
}

test "GameMap camera: setDisplayPos clamps and centers small maps (YED dims)" {
    const alloc = testing.allocator;
    var db = try makeTestDb(alloc, &.{.{ "System.json", "{\"switches\":[null],\"variables\":[null]}" }});
    defer destroyTestDb(alloc, &db);
    var gmap = GameMap.init(alloc, &db);
    defer gmap.deinit();

    // 30×20 @32px: endX = 30 − 20 = 10, endY = 20 − 15 = 5.
    gmap.width = 30;
    gmap.height = 20;
    var tiled = tiled_mod.TiledMap{ .arena = alloc, .width = 30, .height = 20, .tile_w = 32, .tile_h = 32 };
    gmap.tiled = &tiled;

    gmap.setDisplayPos(100, 100);
    try testing.expectApproxEqAbs(@as(f64, 10.0), gmap.display_x, 0.000001);
    try testing.expectApproxEqAbs(@as(f64, 5.0), gmap.display_y, 0.000001);
    // the parallax origin follows the display pos (non-loop)
    try testing.expectApproxEqAbs(gmap.display_x, gmap.parallax_x, 0.000001);

    // small map (2×2): endX < 0 → endX / 2 (centered, negative display)
    gmap.width = 2;
    gmap.height = 2;
    gmap.setDisplayPos(10, 10);
    try testing.expectApproxEqAbs(@as(f64, -9.0), gmap.display_x, 0.000001);
    try testing.expectApproxEqAbs(@as(f64, -6.5), gmap.display_y, 0.000001);
}

test "GameMap camera: scroll clamps + clamped-zone accumulation" {
    const alloc = testing.allocator;
    var db = try makeTestDb(alloc, &.{.{ "System.json", "{\"switches\":[null],\"variables\":[null]}" }});
    defer destroyTestDb(alloc, &db);
    var gmap = GameMap.init(alloc, &db);
    defer gmap.deinit();
    var tiled = tiled_mod.TiledMap{ .arena = alloc, .width = 30, .height = 20, .tile_w = 32, .tile_h = 32 };
    gmap.tiled = &tiled;
    gmap.width = 30;
    gmap.height = 20;

    // scrollRight accumulates up to the clamp (width − screenTileX = 10).
    gmap.display_x = 0;
    gmap.scrollRight(2);
    try testing.expectApproxEqAbs(@as(f64, 2.0), gmap.display_x, 0.000001);
    gmap.scrollRight(10);
    try testing.expectApproxEqAbs(@as(f64, 10.0), gmap.display_x, 0.000001);
    // Parallax accumulates the APPLIED delta only (2 + 8).
    try testing.expectApproxEqAbs(@as(f64, 10.0), gmap.parallax_x, 0.000001);

    // scrollLeft bottoms out at 0
    gmap.scrollLeft(100);
    try testing.expectApproxEqAbs(@as(f64, 0.0), gmap.display_x, 0.000001);
    try testing.expectApproxEqAbs(@as(f64, 0.0), gmap.parallax_x, 0.000001);

    // scrollUp/Down clamp at height − screenTileY = 5.
    gmap.display_y = 0;
    gmap.scrollDown(20);
    try testing.expectApproxEqAbs(@as(f64, 5.0), gmap.display_y, 0.000001);
    gmap.scrollUp(5);
    try testing.expectApproxEqAbs(@as(f64, 0.0), gmap.display_y, 0.000001);

    // scrolledX/Y — real minus display
    gmap.display_x = 3;
    gmap.display_y = 2;
    try testing.expectApproxEqAbs(@as(f64, 12.0), gmap.scrolledX(15.0), 0.000001);
    try testing.expectApproxEqAbs(@as(f64, 8.0), gmap.scrolledY(10.0), 0.000001);
}

test "GameMap camera: per-frame walk scroll (MV updateScroll deltas)" {
    const alloc = testing.allocator;
    var db = try makeTestDb(alloc, &.{.{ "System.json", "{\"switches\":[null],\"variables\":[null]}" }});
    defer destroyTestDb(alloc, &db);
    var gmap = GameMap.init(alloc, &db);
    defer gmap.deinit();
    var tiled = tiled_mod.TiledMap{ .arena = alloc, .width = 40, .height = 30, .tile_w = 32, .tile_h = 32 };
    gmap.tiled = &tiled;
    gmap.width = 40;
    gmap.height = 30;

    // player starts left of center; walking right past the center zone
    // scrolls one distancePerFrame per frame (32px walk = 0.09375)
    const real_start: f64 = 8.0;
    gmap.setDisplayPos(real_start - gmap.playerCenterX(), 0);
    try testing.expectApproxEqAbs(@as(f64, 0.0), gmap.display_x, 0.000001);

    const dpf: f64 = std.math.pow(f64, 2.0, 4.0) / 256.0 * (48.0 / 32.0); // 0.09375
    var real = real_start;
    var last = gmap.scrolledX(real);
    var scrolls: usize = 0;
    while (real < real_start + 6.0) : (real += dpf) {
        const now = gmap.scrolledX(real);
        if (now > last and now > gmap.playerCenterX()) {
            gmap.scrollRight(now - last);
            scrolls += 1;
        }
        last = now;
    }
    // The zone: scrolled > 9.5 only from real ≈ 9.5 + display…
    try testing.expect(scrolls > 0);
    // the display pos ends where the player passed the center zone
    try testing.expect(gmap.display_x > 0);
    try testing.expect(gmap.display_x <= 40.0 - 20.0 + 0.001);
}

const LegacyPositionFixture = struct { game: *GameObjects, raw: *map_mod.RawMap, tiled: *tiled_mod.TiledMap };

fn legacyPositionFixture(a: std.mem.Allocator, raw_json: []const u8) !LegacyPositionFixture {
    const db = try a.create(database.Database);
    db.* = try makeTestDb(a, &.{.{ "System.json", "{\"switches\":[null],\"variables\":[null]}" }});
    const game = try a.create(GameObjects);
    game.* = GameObjects.init(a, db);
    try game.create();
    var parser = try json.Parser.init(a, raw_json);
    const raw = try a.create(map_mod.RawMap);
    raw.* = try map_mod.RawMap.fromJson(a, try parser.parse());
    try game.map.setup(raw, 88);
    const tiled = try a.create(tiled_mod.TiledMap);
    tiled.* = try tiled_mod.TiledMap.parseText(a,
        \\{"width":5,"height":5,"tilewidth":32,"tileheight":32,"tilesets":[],"layers":[
        \\{"type":"tilelayer","properties":{"collision":"full"},"data":[0,0,0,0,0,0,0,0,0,0,0,0,1,0,0,0,0,0,0,0,0,0,0,0,0]}]}
    , "legacy-position-fixture");
    tiled.setup();
    game.map.tiled = tiled;
    game.player.map_id = 88;
    game.player.x = 2;
    game.player.y = 2;
    game.temp.legacy_collision_recovery = true;
    return .{ .game = game, .raw = raw, .tiled = tiled };
}

test "legacy collision recovery: old solid-tile save gets an adjacent connected floor candidate" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try legacyPositionFixture(arena.allocator(), "{\"width\":5,\"height\":5,\"events\":[null]}");
    const position = (try f.game.map.findLegacyCollisionRecovery(f.raw, f.game)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 1), @abs(position[0] - 2) + @abs(position[1] - 2));
    try testing.expect(!f.tiled.isSolid(0, position[0], position[1]));
    // Querying never edits the live game or its on-disk save.
    try testing.expectEqual(@as(i32, 2), f.game.player.x);
    try testing.expectEqual(@as(i32, 2), f.game.player.y);
    f.game.temp.legacy_collision_recovery = false;
    try testing.expect((try f.game.map.findLegacyCollisionRecovery(f.raw, f.game)) == null);
}

test "legacy collision recovery: valid floor arrow restrictions and out-of-bounds saves stay unchanged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try legacyPositionFixture(arena.allocator(), "{\"width\":5,\"height\":5,\"events\":[null]}");
    f.tiled.levels[0].collision[12] = 0;
    f.tiled.levels[0].arrows[12] = 0;
    try testing.expect((try f.game.map.findLegacyCollisionRecovery(f.raw, f.game)) == null);
    f.game.player.x = 0;
    f.game.player.y = 0;
    try testing.expect((try f.game.map.findLegacyCollisionRecovery(f.raw, f.game)) == null);
    f.game.player.x = -1;
    try testing.expect((try f.game.map.findLegacyCollisionRecovery(f.raw, f.game)) == null);
}

test "legacy collision recovery: adjacent cells in different blocked rooms are ambiguous" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try legacyPositionFixture(arena.allocator(), "{\"width\":5,\"height\":5,\"events\":[null]}");
    // A complete vertical wall separates the two available neighbors.
    for (0..5) |y| f.tiled.levels[0].collision[y * 5 + 2] = 1;
    try testing.expect((try f.game.map.findLegacyCollisionRecovery(f.raw, f.game)) == null);
}

test "legacy collision recovery: active event cells are never recovery destinations" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try legacyPositionFixture(arena.allocator(),
        \\{"width":5,"height":5,"events":[null,
        \\{"id":1,"x":2,"y":1,"pages":[{"trigger":0}]},
        \\{"id":2,"x":1,"y":2,"pages":[{"trigger":1,"through":true}]},
        \\{"id":3,"x":3,"y":2,"pages":[{"trigger":0,"priorityType":0}]},
        \\{"id":4,"x":2,"y":3,"pages":[{"trigger":0}]}]}
    );
    try testing.expect((try f.game.map.findLegacyCollisionRecovery(f.raw, f.game)) == null);
}

test "legacy collision recovery: authored cutscenes and disabled movement are not relocated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const f = try legacyPositionFixture(arena.allocator(), "{\"width\":5,\"height\":5,\"events\":[null]}");
    f.game.player.transparent = true;
    try testing.expect((try f.game.map.findLegacyCollisionRecovery(f.raw, f.game)) == null);
    f.game.player.transparent = false;
    f.game.system.menu_enabled = false;
    try testing.expect((try f.game.map.findLegacyCollisionRecovery(f.raw, f.game)) == null);
    f.game.system.menu_enabled = true;
    f.game.temp.player_movement_stopped = true;
    try testing.expect((try f.game.map.findLegacyCollisionRecovery(f.raw, f.game)) == null);
    f.game.temp.player_movement_stopped = false;
    f.game.player.reserveTransfer(88, 0, 0, null, 0);
    try testing.expect((try f.game.map.findLegacyCollisionRecovery(f.raw, f.game)) == null);
    f.game.player.transferring = false;
    const auto = try legacyPositionFixture(arena.allocator(), "{\"width\":5,\"height\":5,\"events\":[null,{\"id\":1,\"x\":0,\"y\":0,\"pages\":[{\"trigger\":3}]}]}");
    try testing.expect((try auto.game.map.findLegacyCollisionRecovery(auto.raw, auto.game)) == null);
}
