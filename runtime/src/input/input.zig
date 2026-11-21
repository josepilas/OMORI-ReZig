//! Logical input model — the R36S physical mapping stays OUTSIDE game
//! logic (architectural pivot §19).
//!
//! **Evidence preserved from the existing project:** the V21 gptokeyb
//! mapping (`omori/gptokeyb/omori.gptk`) documented exactly how OMORI's
//! keyboard model was driven on the R36S:
//!   dpad/analog → arrows, A → z, B → x, X → shift, Y → l,
//!   L1 → l, R1 → r, L2 → f4, R2 → f2, Start → esc, Select → f12.
//!
//! The native runtime replaces gptokeyb's keyboard synthesis with direct
//! SDL game-controller events mapped to the SAME logical actions. The
//! table below is the R36S layer; everything above it (scenes, events,
//! battle) consumes only `LogicalButton`.
//!
//! **v31 — the direction-provenance split (the v30 D-pad wipe bug):**
//! The v30 device run proved the analog-stick polling path
//! (`pollSticks` → axis→direction) AUTHORITATIVELY overwrote the four
//! direction bits every frame: a D-pad press (button/hat event) was set
//! by `pumpEvents` and then WIPED by `pollSticks` reading the resting
//! stick before `update()` ever saw it — "the D-pad is completely dead".
//! The fix: DIRECTIONS HAVE PROVENANCE. `pad_*` bits are owned by the
//! button/hat path (authoritative per event), `stick_*` bits by the axis
//! path (events + per-frame polling), and the effective direction is
//! the OR of both. A resting stick clears only the stick contribution.
//!
//! **v31 — the raw joystick button numbering (dual SELECT/START):** the
//! v30 log budget (first 100 events) was eaten by stick jitter in 4 s,
//! so the R36S's actual joy-button numbers for SELECT/START were never
//! captured. The Linux joystick driver numbers buttons by BTN code
//! order; a 10-button handheld gives SELECT=8, START=9, but a pad that
//! also exposes BTN_C/BTN_Z shifts them to 10/11. v31 maps BOTH pairs
//! (10/11 would be L3/R3 on a standard-layout pad — pressing both
//! stick-clicks together is not a game action, so the alias is safe)
//! and logs every button event for the whole session so the next run
//! pins the exact numbering.
//! **v34 — THE GO-SUPER A/B SWAP:** the v33 device logs proved the GO-Super
//! Gamepad's SDL controller mapping labels the shell's physical A (east
//! face button) as SDL 'B' and the shell's physical B (south face button)
//! as SDL 'A' (Xbox-convention mapping on a Nintendo-layout shell). The
//! user pressed physical A → logical cancel (sys_cancel.ogg, "A does
//! nothing"), and physical B → logical confirm → NEW GAME → the
//! transition crash. v34 swaps CB_A/CB_B for that device (name check,
//! OMORI_SWAP_AB env override), so physical A = confirm, physical B =
//! cancel — the gptokeyb-verified R36S contract (A → z, B → x).
//!
//! **v37 — current controls:** the payload's Omori BASE defaults map Y
//! (keyboard A) to tag, X/Shift to dash, and L/R (Q/W) to paging. Every
//! keyboard binding and up to four pads retain separate held sources;
//! queued press/release taps keep one frame of triggered state. The
//! standard raw profile uses Select8/Start9; the observed GO-Super raw
//! profile uses dpad8..11/Select12/Start13. This replaces v31's guessed
//! aliases. SDL mappings own mapped pads except GO-Super raw Select/Start.
//! Unknown raw layouts require an SDL mapping or a matching explicit
//! profile; this module does not promise arbitrary-controller parity.

const std = @import("std");
const sdl = @import("../platform/sdl2.zig");

/// v34: swap SDL controller button codes A↔B (the GO-Super mapping fix).
/// Only the two face codes are exchanged; everything else passes through.
pub fn swapAbButton(b: u8) u8 {
    return switch (b) {
        sdl.CB_A => sdl.CB_B,
        sdl.CB_B => sdl.CB_A,
        else => b,
    };
}

/// v34: does this controller name indicate a GO-Super Gamepad (the R36S
/// pad whose SDL mapping swaps physical A/B)? Case-insensitive substring.
pub fn nameRequestsAbSwap(name: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(name, "go-super") != null;
}

/// The logical buttons OMORI/MV actually consume.
pub const LogicalButton = enum {
    up,
    down,
    left,
    right,
    /// Confirm (MV "ok") — game key z.
    confirm,
    /// Cancel / menu-back (MV "cancel") — game key x.
    cancel,
    /// Dash / context (MV "shift") — game key shift.
    dash,
    /// Escape — menu (game key esc).
    menu,
    /// Page navigation (MV pageup / pagedown).
    page_up,
    page_down,
    /// OMORI party tagging (Y on the pad / A on the keyboard).
    tag,
    /// Debug/aux keys OMORI's control config exposes (f2/f4/f12).
    debug_1,
    debug_2,
    debug_3,
};

pub const ButtonState = packed struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
    confirm: bool = false,
    cancel: bool = false,
    dash: bool = false,
    menu: bool = false,
    page_up: bool = false,
    page_down: bool = false,
    tag: bool = false,
    debug_1: bool = false,
    debug_2: bool = false,
    debug_3: bool = false,
};

/// The four directions, tracked with provenance (v31).
const DpadState = packed struct {
    up: bool = false,
    down: bool = false,
    left: bool = false,
    right: bool = false,
};

/// MV key-repeat constants (rpg_core.js Input): the first repeat fires
/// after 24 frames of holding, then every 6 frames.
const REPEAT_DELAY_FRAMES: u32 = 24;
const REPEAT_INTERVAL_FRAMES: u32 = 6;

pub const Input = struct {
    current: ButtonState = .{},
    previous: ButtonState = .{},
    triggered: ButtonState = .{},

    /// Direction provenance (v31): buttons/hats vs axes.
    pad: DpadState = .{},
    stick: DpadState = .{},

    /// Frames each logical button has been held (repeat semantics).
    held: [countButtons]u32 = @splat(0),
    controller_bits: [MAX_DEVICES]u32 = @splat(0),
    joystick_bits: [MAX_DEVICES]u32 = @splat(0),
    joystick_go_super: [MAX_DEVICES]bool = @splat(false),
    hats: [MAX_DEVICES]u8 = @splat(0),
    axes: [MAX_DEVICES][2]i16 = @splat(.{ 0, 0 }),
    keys_down: [key_bindings.len]bool = @splat(false),

    pub const MAX_DEVICES = 4;

    /// Commands polled during this frame also see a down/up tap that
    /// arrived in one event batch; held state itself remains accurate.
    pub fn frameState(self: *const Input) ButtonState {
        var state = self.current;
        for (0..countButtons) |i| {
            const button: LogicalButton = @enumFromInt(i);
            if (fieldOf(self.triggered, button)) setField(&state, button, true);
        }
        return state;
    }

    pub fn isPressed(self: *const Input, b: LogicalButton) bool {
        return fieldOf(self.current, b);
    }

    pub fn isTriggered(self: *const Input, b: LogicalButton) bool {
        return fieldOf(self.triggered, b) or (fieldOf(self.current, b) and !fieldOf(self.previous, b));
    }

    /// MV `isRepeated`: true on the press frame (held == 0 — MV's
    /// `_pressedTime === 0`), then the repeat cadence after the 24-frame
    /// delay (every 6 frames). Menus use this so a held D-pad walks the
    /// list instead of moving one entry per press; single taps behave
    /// exactly like plain triggers.
    pub fn isRepeated(self: *const Input, b: LogicalButton) bool {
        if (self.isTriggered(b)) return true;
        if (!fieldOf(self.current, b)) return false;
        const held = self.held[@intFromEnum(b)];
        return held == 0 or (held >= REPEAT_DELAY_FRAMES and held % REPEAT_INTERVAL_FRAMES == 0);
    }

    pub fn isLongPressed(self: *const Input, b: LogicalButton) bool {
        return fieldOf(self.current, b) and self.held[@intFromEnum(b)] >= REPEAT_DELAY_FRAMES;
    }

    /// Frame boundary: current becomes previous; held-frame counters
    /// advance for still-pressed buttons and reset on release.
    pub fn endFrame(self: *Input) void {
        self.previous = self.current;
        self.triggered = .{};
        for (0..countButtons) |i| {
            const b: LogicalButton = @enumFromInt(i);
            if (fieldOf(self.current, b)) {
                self.held[i] +%= 1;
            } else {
                self.held[i] = 0;
            }
        }
    }

    /// Recompute the effective four directions from the two sources.
    fn refreshDirections(self: *Input) void {
        self.current.up = self.pad.up or self.stick.up;
        self.current.down = self.pad.down or self.stick.down;
        self.current.left = self.pad.left or self.stick.left;
        self.current.right = self.pad.right or self.stick.right;
    }

    fn fieldOf(state: ButtonState, b: LogicalButton) bool {
        return switch (b) {
            .up => state.up,
            .down => state.down,
            .left => state.left,
            .right => state.right,
            .confirm => state.confirm,
            .cancel => state.cancel or state.menu,
            .dash => state.dash,
            .menu => state.menu,
            .page_up => state.page_up,
            .page_down => state.page_down,
            .tag => state.tag,
            .debug_1 => state.debug_1,
            .debug_2 => state.debug_2,
            .debug_3 => state.debug_3,
        };
    }

    fn setField(state: *ButtonState, b: LogicalButton, value: bool) void {
        switch (b) {
            .up => state.up = value,
            .down => state.down = value,
            .left => state.left = value,
            .right => state.right = value,
            .confirm => state.confirm = value,
            .cancel => state.cancel = value,
            .dash => state.dash = value,
            .menu => state.menu = value,
            .page_up => state.page_up = value,
            .page_down => state.page_down = value,
            .tag => state.tag = value,
            .debug_1 => state.debug_1 = value,
            .debug_2 => state.debug_2 = value,
            .debug_3 => state.debug_3 = value,
        }
    }

    const countButtons = @typeInfo(LogicalButton).@"enum".fields.len;

    const key_bindings = [_]struct { sym: i32, logical: LogicalButton }{
        .{ .sym = sdl.K_UP, .logical = .up },         .{ .sym = sdl.K_DOWN, .logical = .down },
        .{ .sym = sdl.K_LEFT, .logical = .left },     .{ .sym = sdl.K_RIGHT, .logical = .right },
        .{ .sym = sdl.K_Z, .logical = .confirm },     .{ .sym = sdl.K_RETURN, .logical = .confirm },
        .{ .sym = sdl.K_SPACE, .logical = .confirm }, .{ .sym = sdl.K_X, .logical = .cancel },
        .{ .sym = sdl.K_ESCAPE, .logical = .menu },   .{ .sym = sdl.K_F12, .logical = .debug_3 },
        .{ .sym = sdl.K_LSHIFT, .logical = .dash },   .{ .sym = sdl.K_RSHIFT, .logical = .dash },
        .{ .sym = sdl.K_Q, .logical = .page_up },     .{ .sym = sdl.K_W, .logical = .page_down },
        .{ .sym = sdl.K_L, .logical = .page_up },     .{ .sym = sdl.K_R, .logical = .page_down },
        .{ .sym = sdl.K_A, .logical = .tag },
    };

    fn controllerMapping(button: u8) ?LogicalButton {
        return switch (button) {
            sdl.CB_DPUP => .up,
            sdl.CB_DPDOWN => .down,
            sdl.CB_DPLEFT => .left,
            sdl.CB_DPRIGHT => .right,
            sdl.CB_A => .confirm,
            sdl.CB_B => .cancel,
            sdl.CB_X => .dash,
            sdl.CB_Y => .tag,
            sdl.CB_LEFTSHOULDER => .page_up,
            sdl.CB_RIGHTSHOULDER => .page_down,
            sdl.CB_START => .menu,
            sdl.CB_BACK => .debug_3,
            else => null,
        };
    }

    fn joystickMapping(button: u8, go_super: bool) ?LogicalButton {
        if (go_super) switch (button) {
            8 => return .up,
            9 => return .down,
            10 => return .left,
            11 => return .right,
            12 => return .debug_3,
            13 => return .menu,
            else => {},
        };
        return switch (button) {
            0 => .confirm,
            1 => .cancel,
            2 => .dash,
            3 => .tag,
            4 => .page_up,
            5 => .page_down,
            6 => .debug_1,
            7 => .debug_2,
            8 => if (go_super) null else .debug_3,
            9 => if (go_super) null else .menu,
            else => null,
        };
    }

    fn bitDown(bits: u32, button: u8) bool {
        return button < 32 and bits & (@as(u32, 1) << @as(u5, @intCast(button))) != 0;
    }
    fn setBit(bits: *u32, button: u8, down: bool) void {
        if (button >= 32) return;
        const mask = @as(u32, 1) << @as(u5, @intCast(button));
        if (down) bits.* |= mask else bits.* &= ~mask;
    }

    // Each physical source owns its held bits. A duplicate release from
    // SDL's controller/raw paths cannot clear another source's press.
    fn rebuild(self: *Input) void {
        var combined = ButtonState{};
        for (key_bindings, self.keys_down) |binding, down| {
            if (down) setField(&combined, binding.logical, true);
        }
        self.stick = .{};
        for (0..MAX_DEVICES) |slot| {
            for (0..32) |button| {
                const b: u8 = @intCast(button);
                if (bitDown(self.controller_bits[slot], b)) {
                    if (controllerMapping(b)) |logical| setField(&combined, logical, true);
                }
                if (bitDown(self.joystick_bits[slot], b)) {
                    if (joystickMapping(b, self.joystick_go_super[slot])) |logical| setField(&combined, logical, true);
                }
            }
            combined.up = combined.up or self.hats[slot] & sdl.HAT_UP != 0;
            combined.down = combined.down or self.hats[slot] & sdl.HAT_DOWN != 0;
            combined.left = combined.left or self.hats[slot] & sdl.HAT_LEFT != 0;
            combined.right = combined.right or self.hats[slot] & sdl.HAT_RIGHT != 0;
            self.stick.left = self.stick.left or self.axes[slot][0] < -16000;
            self.stick.right = self.stick.right or self.axes[slot][0] > 16000;
            self.stick.up = self.stick.up or self.axes[slot][1] < -16000;
            self.stick.down = self.stick.down or self.axes[slot][1] > 16000;
        }
        self.pad = .{ .up = combined.up, .down = combined.down, .left = combined.left, .right = combined.right };
        combined.cancel = combined.cancel or combined.menu;
        const before = self.current;
        self.current = combined;
        self.refreshDirections();
        for (0..countButtons) |i| {
            const button: LogicalButton = @enumFromInt(i);
            if (fieldOf(self.current, button) and !fieldOf(before, button)) setField(&self.triggered, button, true);
        }
    }

    pub fn clearDevice(self: *Input, slot: usize) void {
        if (slot >= MAX_DEVICES) return;
        self.controller_bits[slot] = 0;
        self.joystick_bits[slot] = 0;
        self.hats[slot] = 0;
        self.axes[slot] = .{ 0, 0 };
        self.rebuild();
    }
    pub fn clearAll(self: *Input) void {
        self.controller_bits = @splat(0);
        self.joystick_bits = @splat(0);
        self.hats = @splat(0);
        self.axes = @splat(.{ 0, 0 });
        self.keys_down = @splat(false);
        self.rebuild();
    }
    pub fn applyControllerButton(self: *Input, button: u8, down: bool) void {
        self.applyControllerButtonFor(0, button, down);
    }
    pub fn applyControllerButtonFor(self: *Input, slot: usize, button: u8, down: bool) void {
        if (slot >= MAX_DEVICES) return;
        setBit(&self.controller_bits[slot], button, down);
        self.rebuild();
    }
    pub fn applyJoyButton(self: *Input, button: u8, down: bool) void {
        self.applyJoyButtonFor(0, button, down, false);
    }
    pub fn applyJoyButtonFor(self: *Input, slot: usize, button: u8, down: bool, go_super: bool) void {
        if (slot >= MAX_DEVICES) return;
        self.joystick_go_super[slot] = go_super;
        setBit(&self.joystick_bits[slot], button, down);
        self.rebuild();
    }
    pub fn applyJoyHat(self: *Input, value: u8) void {
        self.applyJoyHatFor(0, value);
    }
    pub fn applyJoyHatFor(self: *Input, slot: usize, value: u8) void {
        if (slot >= MAX_DEVICES) return;
        self.hats[slot] = value;
        self.rebuild();
    }
    pub fn applyStickAxis(self: *Input, axis: u8, value: i16) void {
        self.applyStickAxisFor(0, axis, value);
    }
    pub fn applyStickAxisFor(self: *Input, slot: usize, axis: u8, value: i16) void {
        if (slot >= MAX_DEVICES or axis >= 2) return;
        self.axes[slot][axis] = value;
        self.rebuild();
    }
    pub fn applyKey(self: *Input, sym: i32, down: bool) void {
        for (key_bindings, 0..) |binding, i| {
            if (binding.sym == sym) self.keys_down[i] = down;
        }
        self.rebuild();
    }
};

// ---------------------------------------------------------------------------
// Tests: physical mapping stays outside game logic.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "controller mapping: R36S A=confirm, B=cancel, X=dash" {
    var input = Input{};
    input.applyControllerButton(sdl.CB_A, true);
    try testing.expect(input.isPressed(.confirm));
    input.applyControllerButton(sdl.CB_B, true);
    try testing.expect(input.isPressed(.cancel));
    input.applyControllerButton(sdl.CB_X, true);
    try testing.expect(input.isPressed(.dash));

    // Trigger semantics: pressed THIS frame only.
    try testing.expect(input.isTriggered(.confirm));
    input.endFrame(); // previous := current (still held)
    try testing.expect(!input.isTriggered(.confirm));
    try testing.expect(input.isPressed(.confirm));

    // Release.
    input.applyControllerButton(sdl.CB_A, false);
    try testing.expect(!input.isPressed(.confirm));
    // B is STILL held (pressed in frame 1): pressed yes, triggered no.
    try testing.expect(input.isPressed(.cancel));
    try testing.expect(!input.isTriggered(.cancel));
}

test "keyboard mapping parity with the gptokeyb evidence" {
    var input = Input{};
    input.applyKey(sdl.K_Z, true); // game key z == A == confirm
    try testing.expect(input.isPressed(.confirm));
    input.applyKey(sdl.K_X, true); // game key x == B == cancel
    try testing.expect(input.isPressed(.cancel));
    input.applyKey(sdl.K_LSHIFT, true); // dash
    try testing.expect(input.isPressed(.dash));
    input.applyKey(sdl.K_UP, true);
    try testing.expect(input.isPressed(.up));
}

test "v30: joystick-button fallback maps standard SELECT8/START9" {
    // The v29 device run: SELECT arrived as joy 0x603 WITHOUT a
    // controller counterpart — the quit combo died right there.
    var input = Input{};
    input.applyJoyButton(8, true); // BTN_SELECT
    try testing.expect(input.isPressed(.debug_3));
    input.applyJoyButton(9, true); // BTN_START
    try testing.expect(input.isPressed(.menu));
    // The combo the renderer watches: menu AND debug_3.
    try testing.expect(input.isPressed(.menu) and input.isPressed(.debug_3));
    // Face buttons map too (a controller-mapping-less pad still plays).
    input.applyJoyButton(0, true);
    try testing.expect(input.isPressed(.confirm));
    input.applyJoyButton(1, true);
    try testing.expect(input.isPressed(.cancel));
}

test "v33: confirmed GO-Super SELECT12/START13 arm quit; dpad10/11 must not" {
    // Device logs confirm raw 10/11 are dpad-left/right, and 12/13
    // are SELECT/START. Only the named GO-Super profile uses that pair.
    var input = Input{};
    input.applyJoyButton(10, true);
    input.applyJoyButton(11, true);
    try testing.expect(!input.isPressed(.debug_3));
    try testing.expect(!input.isPressed(.menu));
    input.applyJoyButtonFor(0, 12, true, true);
    input.applyJoyButtonFor(0, 13, true, true);
    try testing.expect(input.isPressed(.debug_3) and input.isPressed(.menu));
}

test "v30: hat + axis events drive the dpad model" {
    var input = Input{};
    input.applyJoyHat(sdl.HAT_DOWN | sdl.HAT_LEFT);
    try testing.expect(input.isPressed(.down));
    try testing.expect(input.isPressed(.left));
    try testing.expect(!input.isPressed(.up));
    input.applyJoyHat(0); // centered
    try testing.expect(!input.isPressed(.down));

    input.applyStickAxis(1, -20000); // LEFTY pushed up
    try testing.expect(input.isPressed(.up));
    try testing.expect(!input.isPressed(.down));
    input.applyStickAxis(0, 20000); // LEFTX pushed right
    try testing.expect(input.isPressed(.right));
    input.applyStickAxis(0, 5000); // inside the dead zone
    try testing.expect(!input.isPressed(.right));
    input.applyStickAxis(1, 0);
    try testing.expect(!input.isPressed(.up));
}

test "v31: THE WIPE REGRESSION — a resting stick must not erase a D-pad press" {
    // The v30 device failure: pumpEvents set 'up' from the D-pad, then
    // pollSticks read the resting stick and cleared it before update().
    var input = Input{};

    // D-pad press (hat path) ...
    input.applyJoyHat(sdl.HAT_UP);
    try testing.expect(input.isPressed(.up));
    // ... then the per-frame stick poll sees a centered stick.
    input.applyStickAxis(0, 0);
    input.applyStickAxis(1, 0);
    // v30 behavior: up was wiped here. v31: the press survives.
    try testing.expect(input.isPressed(.up));

    // D-pad button path (controller mapping, no-joy fallback) survives too.
    input.applyJoyHat(0);
    try testing.expect(!input.isPressed(.up));
    input.applyControllerButton(sdl.CB_DPDOWN, true);
    try testing.expect(input.isPressed(.down));
    input.applyStickAxis(1, 0);
    try testing.expect(input.isPressed(.down));

    // Keyboard arrows are pad-provenance too (a tilted stick must not
    // erase them either — the OR makes both coexist).
    input.applyKey(sdl.K_LEFT, true);
    try testing.expect(input.isPressed(.left));
    input.applyStickAxis(0, 0);
    try testing.expect(input.isPressed(.left));

    // Stick direction while the D-pad is idle still works (the OR).
    input.applyControllerButton(sdl.CB_DPDOWN, false);
    input.applyStickAxis(1, 25000);
    try testing.expect(input.isPressed(.down));
    input.applyStickAxis(1, 0);
    try testing.expect(!input.isPressed(.down));
}

test "v34: GO-Super A/B swap — physical A (SDL 'B') becomes confirm" {
    // The v33 device evidence: physical A → SDL controller button 'B'
    // (logical cancel), physical B → SDL button 'A' (logical confirm).
    // After the swap: SDL 'B' (physical A) → confirm, SDL 'A' (physical
    // B) → cancel. X/Y/dpad/shoulders pass through untouched.
    var input = Input{};
    // physical A arrives as SDL 'B' → swap → 'A' → confirm
    input.applyControllerButton(swapAbButton(sdl.CB_B), true);
    try testing.expect(input.isPressed(.confirm));
    try testing.expect(!input.isPressed(.cancel));
    // physical B arrives as SDL 'A' → swap → 'B' → cancel
    input.applyControllerButton(swapAbButton(sdl.CB_A), true);
    try testing.expect(input.isPressed(.cancel));
    // X and D-pad are unaffected by the swap helper
    try testing.expectEqual(sdl.CB_X, swapAbButton(sdl.CB_X));
    try testing.expectEqual(sdl.CB_DPUP, swapAbButton(sdl.CB_DPUP));
    try testing.expectEqual(sdl.CB_START, swapAbButton(sdl.CB_START));
}

test "v34: GO-Super name detection (case-insensitive)" {
    try testing.expect(nameRequestsAbSwap("GO-Super Gamepad"));
    try testing.expect(nameRequestsAbSwap("go-super gamepad"));
    try testing.expect(nameRequestsAbSwap("HID: GO-SUPER"));
    try testing.expect(!nameRequestsAbSwap("Xbox 360 Controller"));
    try testing.expect(!nameRequestsAbSwap(""));
}

test "v31: MV key repeat — 24-frame delay, 6-frame cadence" {
    var input = Input{};
    input.applyJoyButton(0, true); // confirm

    // The press frame (held == 0, MV's _pressedTime === 0): repeated.
    try testing.expect(input.isRepeated(.confirm));

    // Held frames 1..23: no repeat, not long-pressed.
    var f: u32 = 0;
    while (f < 23) : (f += 1) input.endFrame();
    try testing.expect(!input.isRepeated(.confirm));
    try testing.expect(input.isPressed(.confirm));
    try testing.expect(!input.isLongPressed(.confirm));

    // Held 24: the first repeat; long-pressed from here on.
    input.endFrame();
    try testing.expect(input.isRepeated(.confirm));
    try testing.expect(input.isLongPressed(.confirm));

    // Held 25..29: silent; held 30: the next repeat (30 % 6 == 0).
    var g: u32 = 0;
    while (g < 5) : (g += 1) input.endFrame();
    try testing.expect(!input.isRepeated(.confirm));
    input.endFrame();
    try testing.expect(input.isRepeated(.confirm));

    // Release resets everything.
    input.applyJoyButton(0, false);
    input.endFrame();
    try testing.expect(!input.isPressed(.confirm));
    try testing.expect(!input.isRepeated(.confirm));
}

test "input sources: duplicate releases and multiple pads do not erase held actions" {
    var input = Input{};
    input.applyControllerButtonFor(0, sdl.CB_START, true);
    input.applyJoyButtonFor(0, 13, true, true);
    input.applyKey(sdl.K_ESCAPE, true);
    input.applyControllerButtonFor(0, sdl.CB_START, false);
    try testing.expect(input.isPressed(.menu) and input.isPressed(.cancel));
    input.applyJoyButtonFor(0, 13, false, true);
    try testing.expect(input.isPressed(.menu));
    input.applyKey(sdl.K_ESCAPE, false);
    try testing.expect(!input.isPressed(.menu));
    input.applyStickAxisFor(0, 1, -25000);
    input.applyStickAxisFor(1, 1, 0);
    try testing.expect(input.isPressed(.up));
    input.applyControllerButtonFor(1, sdl.CB_A, true);
    input.clearDevice(0);
    try testing.expect(!input.isPressed(.up) and input.isPressed(.confirm));
    input.clearDevice(1);
    try testing.expect(!input.isPressed(.confirm));
}

test "input edges: short queued taps survive without fabricating held state" {
    var input = Input{};
    input.applyControllerButton(sdl.CB_B, true);
    input.applyControllerButton(sdl.CB_B, false);
    try testing.expect(!input.isPressed(.cancel));
    try testing.expect(input.isTriggered(.cancel) and input.isRepeated(.cancel));
    try testing.expect(input.frameState().cancel);
    input.endFrame();
    try testing.expect(!input.isTriggered(.cancel));
    input.applyKey(sdl.K_Z, true);
    input.applyKey(sdl.K_RETURN, true);
    input.applyKey(sdl.K_Z, false);
    try testing.expect(input.isPressed(.confirm));
    input.applyKey(sdl.K_RETURN, false);
    try testing.expect(!input.isPressed(.confirm));
}

test "input profiles: GO-Super dpad is not quit and primary tag/page controls are mapped" {
    var input = Input{};
    for (8..12) |b| input.applyJoyButtonFor(0, @intCast(b), true, true);
    try testing.expect(!input.isPressed(.menu) and !input.isPressed(.debug_3));
    try testing.expect(input.isPressed(.up) and input.isPressed(.down) and input.isPressed(.left) and input.isPressed(.right));
    input.clearDevice(0);
    input.applyJoyButtonFor(0, 12, true, true);
    input.applyJoyButtonFor(0, 13, true, true);
    try testing.expect(input.isPressed(.menu) and input.isPressed(.debug_3));
    input.clearDevice(0);
    input.applyJoyButton(12, true);
    input.applyJoyButton(13, true);
    try testing.expect(!input.isPressed(.menu) and !input.isPressed(.debug_3));
    input.applyControllerButton(sdl.CB_Y, true);
    try testing.expect(input.isPressed(.tag) and !input.isPressed(.page_down));
    input.applyKey(sdl.K_Q, true);
    input.applyKey(sdl.K_W, true);
    try testing.expect(input.isPressed(.page_up) and input.isPressed(.page_down));
    input.clearAll();
    input.applyKey(sdl.K_A, true);
    try testing.expect(input.isPressed(.tag));
}
