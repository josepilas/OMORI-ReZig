//! v30 input self-test: prove the WHOLE dispatch chain (SDL event →
//! Input logical state → quit combo) against a REAL SDL2 library,
//! without needing the game payload or a physical pad.
//!
//! Why this exists: the v29 device run showed 328 input events arriving
//! with ZERO game reaction — the event-type constants were wrong
//! (0x64B vs the real 0x651), and nothing below the dispatcher could
//! ever catch it because unit tests only tested the logical layer with
//! hand-fed constants. This self-test pushes SYNTHETIC SDL events
//! through SDL_PushEvent (real library, real union layouts, real type
//! values) and asserts what the Input model receives.
//!
//! Runs on the dev box (SDL 2.32.4) and under qemu-aarch64 (bundled SDL
//! 2.0.10) — two different real SDL2 builds agreeing on the ABI.

const std = @import("std");
const log = @import("../core/log.zig");
const sdl = @import("../platform/sdl2.zig");
const dyn = @import("../platform/dyn.zig");
const input_mod = @import("input.zig");
const renderer_mod = @import("../renderer/renderer.zig");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

var failures: u32 = 0;

fn check(ok: bool, what: []const u8) void {
    if (ok) {
        log.event(.sys, .note, "selftest input: PASS — {s}", .{what});
    } else {
        failures += 1;
        log.err("selftest input: FAIL — {s}", .{what});
    }
}

/// Push one SDL event (SDL_PushEvent) — the queue is drained by the
/// renderer's PollEvent loop on the next pump.
fn push(lib: *sdl.Sdl2, ev: *sdl.Event) void {
    _ = lib.PushEvent(ev);
}

fn controllerButton(lib: *sdl.Sdl2, button: u8, down: bool) void {
    controllerButtonFor(lib, 0, button, down);
}

fn controllerButtonFor(lib: *sdl.Sdl2, instance: i32, button: u8, down: bool) void {
    var ev = std.mem.zeroes(sdl.Event);
    ev.cbutton = .{
        .type = if (down) sdl.EVENT_CONTROLLERBUTTONDOWN else sdl.EVENT_CONTROLLERBUTTONUP,
        .timestamp = 0,
        .which = instance,
        .button = button,
        .state = if (down) 1 else 0,
        .padding1 = 0,
        .padding2 = 0,
    };
    push(lib, &ev);
}

fn joyButton(lib: *sdl.Sdl2, button: u8, down: bool) void {
    joyButtonFor(lib, 0, button, down);
}

fn joyButtonFor(lib: *sdl.Sdl2, instance: i32, button: u8, down: bool) void {
    var ev = std.mem.zeroes(sdl.Event);
    ev.jbutton = .{
        .type = if (down) sdl.EVENT_JOYBUTTONDOWN else sdl.EVENT_JOYBUTTONUP,
        .timestamp = 0,
        .which = instance,
        .button = button,
        .state = if (down) 1 else 0,
        .padding1 = 0,
        .padding2 = 0,
    };
    push(lib, &ev);
}

fn joyHat(lib: *sdl.Sdl2, value: u8) void {
    var ev = std.mem.zeroes(sdl.Event);
    ev.jhat = .{
        .type = sdl.EVENT_JOYHATMOTION,
        .timestamp = 0,
        .which = 0,
        .hat = 0,
        .value = value,
        .padding1 = 0,
        .padding2 = 0,
    };
    push(lib, &ev);
}

fn controllerAxis(lib: *sdl.Sdl2, axis: u8, value: i16) void {
    var ev = std.mem.zeroes(sdl.Event);
    ev.caxis = .{
        .type = sdl.EVENT_CONTROLLERAXISMOTION,
        .timestamp = 0,
        .which = 0,
        .axis = axis,
        .padding1 = 0,
        .padding2 = 0,
        .padding3 = 0,
        .value = value,
        .padding4 = 0,
    };
    push(lib, &ev);
}

fn key(lib: *sdl.Sdl2, sym: i32, down: bool) void {
    var ev = std.mem.zeroes(sdl.Event);
    ev.key = .{
        .type = if (down) sdl.EVENT_KEYDOWN else sdl.EVENT_KEYUP,
        .timestamp = 0,
        .windowID = 0,
        .state = if (down) 1 else 0,
        .repeat = 0,
        .padding2 = .{ 0, 0 },
        .keysym = .{ .scancode = 0, .sym = sym, .mod = 0, .unused = 0 },
    };
    push(lib, &ev);
}

/// The full chain test. Returns the number of failures (0 = pass).
pub fn run(alloc: std.mem.Allocator) u32 {
    failures = 0;
    log.section("input self-test (synthetic SDL events through a real SDL2)");

    // The self-test needs no real display: force the SDL dummy video
    // driver BEFORE the renderer's SDL_Init (the device never runs this
    // mode; production keeps kmsdrm from the env).
    _ = setenv("SDL_VIDEODRIVER", "dummy", 1);

    var renderer = renderer_mod.Renderer.init(alloc, false); // windowed: dummy driver is fine
    defer renderer.deinit();
    if (renderer.mode != .windowed) {
        log.err("selftest input: FAIL — no windowed renderer (SDL unavailable)", .{});
        return 1;
    }
    if (renderer.sdl == null) {
        log.err("selftest input: FAIL — SDL2 handle missing", .{});
        return 1;
    }
    const lib: *sdl.Sdl2 = &renderer.sdl.?;

    // Isolate the synthetic tests from any physical controllers or
    // OMORI_SWAP_AB override. Restore real handles before deinit closes
    // them; no sentinel is ever passed into an SDL controller function.
    const opened_controllers = renderer.controllers;
    const opened_joysticks = renderer.joysticks;
    const opened_instances = renderer.input_instances;
    const opened_mapped = renderer.controller_mapped;
    const opened_profiles = renderer.raw_go_super;
    const opened_swaps = renderer.controller_swaps;
    const opened_swap_ab = renderer.swap_ab;
    const opened_have_joy = renderer.have_joy;
    renderer.joysticks = @splat(null);
    renderer.input_instances = @splat(-1);
    renderer.controller_mapped = @splat(false);
    renderer.raw_go_super = @splat(false);
    renderer.controller_swaps = @splat(false);
    renderer.have_joy = false;
    defer renderer.joysticks = opened_joysticks;
    defer renderer.input_instances = opened_instances;
    defer renderer.controller_mapped = opened_mapped;
    defer renderer.raw_go_super = opened_profiles;
    defer renderer.controller_swaps = opened_swaps;
    defer renderer.swap_ab = opened_swap_ab;
    defer renderer.have_joy = opened_have_joy;
    renderer.controllers = @splat(null);
    defer renderer.controllers = opened_controllers;
    renderer.swap_ab = false;

    var input = input_mod.Input{};

    // --- 1. controller button dispatch (dpad + confirm) -------------------
    controllerButton(lib, sdl.CB_DPDOWN, true);
    _ = renderer.pumpEvents(&input);
    check(input.isPressed(.down) and input.isTriggered(.down), "controller DPAD-DOWN pressed+triggered");
    input.endFrame();
    _ = renderer.pumpEvents(&input); // still held
    check(input.isPressed(.down) and !input.isTriggered(.down), "held DPAD-DOWN is pressed but not re-triggered");
    controllerButton(lib, sdl.CB_DPDOWN, false);
    _ = renderer.pumpEvents(&input);
    check(!input.isPressed(.down), "DPAD-DOWN release clears the state");

    controllerButton(lib, sdl.CB_A, true);
    _ = renderer.pumpEvents(&input);
    check(input.isTriggered(.confirm), "controller A (confirm) triggers");
    controllerButton(lib, sdl.CB_A, false);
    _ = renderer.pumpEvents(&input);
    check(!input.isPressed(.confirm), "controller A release clears");

    // --- 2. standard raw joystick SELECT/START ---------------------------
    joyButton(lib, 8, true); // BTN_SELECT
    joyButton(lib, 9, true); // BTN_START
    check(!renderer.pumpEvents(&input), "standard raw START+SELECT exits on its first pump");
    check(input.isPressed(.menu) and input.isPressed(.debug_3), "joy SELECT+START set the quit-combo inputs");
    joyButton(lib, 8, false);
    joyButton(lib, 9, false);
    check(renderer.pumpEvents(&input), "standard raw START+SELECT releases clear exit state");

    // --- 3. overlap, not two unrelated taps, is the quit gesture ---------
    controllerButton(lib, sdl.CB_START, true);
    controllerButton(lib, sdl.CB_START, false);
    controllerButton(lib, sdl.CB_BACK, true);
    controllerButton(lib, sdl.CB_BACK, false);
    check(renderer.pumpEvents(&input), "queued START down/up then SELECT down/up does not exit");
    check(!input.isPressed(.menu) and !input.isPressed(.debug_3), "separate queued taps do not fabricate held quit buttons");

    // A short chord can arrive entirely between two slow render frames.
    // Catch overlap inside the SDL queue, even with both releases queued.
    controllerButton(lib, sdl.CB_BACK, true);
    controllerButton(lib, sdl.CB_START, true);
    controllerButton(lib, sdl.CB_BACK, false);
    controllerButton(lib, sdl.CB_START, false);
    check(!renderer.pumpEvents(&input), "queued START+SELECT down/down/up/up exits immediately");
    check(renderer.pumpEvents(&input), "queued chord releases reset exit detection");
    check(!input.isPressed(.menu) and !input.isPressed(.debug_3), "quit chord does not remain stuck after release");

    key(lib, sdl.K_ESCAPE, true);
    key(lib, sdl.K_ESCAPE, false);
    key(lib, sdl.K_F12, true);
    key(lib, sdl.K_F12, false);
    check(renderer.pumpEvents(&input), "separate Escape and F12 taps do not exit");

    key(lib, sdl.K_ESCAPE, true);
    key(lib, sdl.K_F12, true);
    check(!renderer.pumpEvents(&input), "PortMaster Escape+F12 keyboard equivalents exit");
    key(lib, sdl.K_ESCAPE, false);
    key(lib, sdl.K_F12, false);
    _ = renderer.pumpEvents(&input);

    // --- 4. hat + axis ------------------------------------------------------
    joyHat(lib, sdl.HAT_UP | sdl.HAT_LEFT);
    _ = renderer.pumpEvents(&input);
    check(input.isPressed(.up) and input.isPressed(.left), "joy hat UP+LEFT dispatches");
    joyHat(lib, 0);
    _ = renderer.pumpEvents(&input);
    check(!input.isPressed(.up), "hat centered clears");

    controllerAxis(lib, 1, -20000); // LEFTY up
    _ = renderer.pumpEvents(&input);
    check(input.isPressed(.up), "stick LEFTY=-20000 maps to up");
    controllerAxis(lib, 1, 0);
    _ = renderer.pumpEvents(&input);
    check(!input.isPressed(.up), "stick centered clears up");
    controllerAxis(lib, 0, 20000); // LEFTX right
    _ = renderer.pumpEvents(&input);
    check(input.isPressed(.right), "stick LEFTX=+20000 maps to right");
    controllerAxis(lib, 0, 0);
    _ = renderer.pumpEvents(&input);

    // --- 5. keyboard (SDL2 keysym values) ----------------------------------
    key(lib, sdl.K_UP, true);
    _ = renderer.pumpEvents(&input);
    check(input.isPressed(.up), "SDL2 K_UP (0x40000052) dispatches");
    key(lib, sdl.K_UP, false);
    key(lib, sdl.K_Z, true);
    _ = renderer.pumpEvents(&input);
    check(input.isTriggered(.confirm), "keyboard z triggers confirm");
    key(lib, sdl.K_Z, false);
    _ = renderer.pumpEvents(&input);

    // --- 6. pollSticks with no physical pad must be a no-op ----------------
    renderer.pollSticks(&input);
    check(!input.isPressed(.up) and !input.isPressed(.down), "pollSticks no-pad is a no-op");

    // --- 6b. Per-device controller-authoritative arbitration -------------
    // Metadata selects a mapped GO-Super profile, without fake SDL handles.
    {
        renderer.controller_mapped[0] = true;
        renderer.raw_go_super[0] = true;
        defer renderer.controller_mapped[0] = false;
        defer renderer.raw_go_super[0] = false;
        controllerButton(lib, sdl.CB_A, true);
        joyButton(lib, 1, true); // duplicate raw face button would cancel
        _ = renderer.pumpEvents(&input);
        check(input.isPressed(.confirm) and !input.isPressed(.cancel), "controller A confirms and duplicate raw face button is ignored");
        controllerButton(lib, sdl.CB_A, false);
        joyButton(lib, 1, false);
        _ = renderer.pumpEvents(&input);
        check(!input.isPressed(.cancel) and !input.isPressed(.confirm), "controller-authoritative release clears face buttons");

        controllerButton(lib, sdl.CB_START, true);
        joyButton(lib, 13, true);
        key(lib, sdl.K_ESCAPE, true);
        controllerButton(lib, sdl.CB_START, false);
        joyButton(lib, 13, false);
        _ = renderer.pumpEvents(&input);
        check(input.isPressed(.menu), "duplicate controller/raw START releases preserve keyboard Escape");
        key(lib, sdl.K_ESCAPE, false);
        _ = renderer.pumpEvents(&input);
        check(!input.isPressed(.menu), "last independent menu-source release clears menu");

        controllerButton(lib, sdl.CB_START, true);
        joyButton(lib, 13, true);
        controllerButton(lib, sdl.CB_START, false);
        _ = renderer.pumpEvents(&input);
        check(input.isPressed(.menu), "controller START release preserves raw GO-Super START");
        joyButton(lib, 13, false);
        _ = renderer.pumpEvents(&input);

        for (8..12) |button| joyButton(lib, @intCast(button), true);
        _ = renderer.pumpEvents(&input);
        check(!input.isPressed(.menu) and !input.isPressed(.debug_3) and renderer.quit_combo_frames == 0, "raw dpad buttons 8..11 cannot arm quit while a controller is open");
        for (8..12) |button| joyButton(lib, @intCast(button), false);
        _ = renderer.pumpEvents(&input);

        joyButton(lib, 12, true);
        joyButton(lib, 13, true);
        check(!renderer.pumpEvents(&input), "GO-Super raw SELECT12+START13 exit on their first pump");
        check(input.isPressed(.menu) and input.isPressed(.debug_3), "raw SELECT12+START13 arm quit alongside a controller");
        joyButton(lib, 12, false);
        joyButton(lib, 13, false);
        _ = renderer.pumpEvents(&input);
        check(!input.isPressed(.menu) and !input.isPressed(.debug_3) and renderer.quit_combo_frames == 0, "raw quit-button release clears the combo");

        renderer.swap_ab = true;
        defer renderer.swap_ab = false;
        controllerButton(lib, sdl.CB_B, true); // physical A on GO-Super
        joyButton(lib, 0, true); // paired raw event must stay ignored
        _ = renderer.pumpEvents(&input);
        check(input.isPressed(.confirm) and !input.isPressed(.cancel), "GO-Super A/B swap maps SDL B to confirm without double firing");
        controllerButton(lib, sdl.CB_B, false);
        joyButton(lib, 0, false);
        _ = renderer.pumpEvents(&input);
        check(!input.isPressed(.confirm) and !input.isPressed(.cancel), "swapped controller-button release clears confirm");
    }

    // --- 6d. v31 THE WIPE REGRESSION: stick poll must not erase a D-pad ---
    // (model-level twin of the device bug; here through the real pump:
    // a hat press followed by a centered-stick axis event survives.)
    joyHat(lib, sdl.HAT_UP);
    controllerAxis(lib, 0, 0); // stick at rest
    controllerAxis(lib, 1, 0);
    _ = renderer.pumpEvents(&input);
    check(input.isPressed(.up), "v31 wipe regression: hat UP survives centered-stick axis events");
    joyHat(lib, 0);
    _ = renderer.pumpEvents(&input);
    check(!input.isPressed(.up), "hat release clears after the regression check");

    // Real SDL event routing by instance ID: releasing a second pad or
    // receiving an unknown device's event cannot erase another pad.
    renderer.input_instances[0] = 41;
    renderer.input_instances[1] = 42;
    renderer.controller_swaps[0] = false;
    renderer.controller_swaps[1] = true;
    controllerButtonFor(lib, 41, sdl.CB_A, true);
    controllerButtonFor(lib, 42, sdl.CB_B, true);
    controllerButtonFor(lib, 999, sdl.CB_A, false);
    controllerButtonFor(lib, 41, sdl.CB_A, false);
    _ = renderer.pumpEvents(&input);
    check(input.isPressed(.confirm) and !input.isPressed(.cancel), "per-pad A/B profiles and instance IDs isolate overlapping confirm sources");
    controllerButtonFor(lib, 42, sdl.CB_B, false);
    _ = renderer.pumpEvents(&input);
    check(!input.isPressed(.confirm), "second pad release clears only its own confirm source");
    renderer.input_instances[0] = -1;
    renderer.input_instances[1] = -1;
    renderer.controller_swaps[1] = false;

    // A physical disconnect must release held directions and buttons.
    renderer.input_instances[0] = 17;
    renderer.controller_mapped[0] = true;
    input.applyControllerButtonFor(0, sdl.CB_DPUP, true);
    input.applyControllerButtonFor(0, sdl.CB_START, true);
    var removed = std.mem.zeroes(sdl.Event);
    removed.jbutton.type = sdl.EVENT_JOYDEVICEREMOVED;
    removed.jbutton.which = 17;
    push(lib, &removed);
    _ = renderer.pumpEvents(&input);
    check(!input.isPressed(.up) and !input.isPressed(.menu), "device removal releases held directions and START");
    check(renderer.input_instances[0] == -1 and !renderer.controller_mapped[0], "device removal clears its instance slot for reconnect");

    // Available on SDL 2.0.14+: real virtual-device hotplug plus polling.
    // Older bundled SDL still executes every synthetic dispatch test.
    virtualDeviceCheck(&renderer, &input);

    // --- 7. AUDIO chain: device + decode + mix + queue --------------------
    // Fixture: a real ogg (scripts generate one with ffmpeg); if absent
    // the check is skipped (CI without the fixture).
    audioCheck(lib, alloc);

    if (failures == 0) {
        log.milestone("INPUT SELFTEST PASSED — controller + joystick + hat + axis + keyboard + quit combo all dispatch through a real SDL2", .{});
    } else {
        log.err("INPUT SELFTEST FAILED — {d} check(s)", .{failures});
    }
    return failures;
}

/// Optional SDL test helpers never become required production symbols.
/// SDL's virtual joystick drives its real add/remove/open/poll pathways.
fn virtualDeviceCheck(renderer: *renderer_mod.Renderer, input: *input_mod.Input) void {
    const lib = &renderer.sdl.?;
    const Attach = *const fn (c_int, c_int, c_int, c_int) callconv(.c) c_int;
    const Detach = *const fn (c_int) callconv(.c) c_int;
    const Button = *const fn (?*anyopaque, c_int, u8) callconv(.c) c_int;
    const Axis = *const fn (?*anyopaque, c_int, i16) callconv(.c) c_int;
    const Hat = *const fn (?*anyopaque, c_int, u8) callconv(.c) c_int;
    const attach: Attach = @ptrCast(@alignCast(dyn.sym(lib.handle, "SDL_JoystickAttachVirtual") orelse {
        log.event(.sys, .note, "selftest input: virtual-device lifecycle SKIPPED (SDL older than 2.0.14)", .{});
        return;
    }));
    const detach: Detach = @ptrCast(@alignCast(dyn.sym(lib.handle, "SDL_JoystickDetachVirtual") orelse return));
    const button: Button = @ptrCast(@alignCast(dyn.sym(lib.handle, "SDL_JoystickSetVirtualButton") orelse return));
    const axis: Axis = @ptrCast(@alignCast(dyn.sym(lib.handle, "SDL_JoystickSetVirtualAxis") orelse return));
    const hat: Hat = @ptrCast(@alignCast(dyn.sym(lib.handle, "SDL_JoystickSetVirtualHat") orelse return));

    // Two complete attachments prove removal clears sources and a new
    // instance reuses the slot without retaining the old held state.
    for (0..2) |pass| {
        const index = attach(0, 2, 14, 1); // unmapped generic raw joystick
        check(index >= 0, "real SDL virtual raw joystick attaches");
        if (index < 0) return;
        const joy = lib.JoystickOpen(index) orelse {
            _ = detach(index);
            check(false, "virtual raw joystick opens for driving state");
            return;
        };
        const instance = lib.JoystickInstanceID(joy);
        _ = renderer.pumpEvents(input);
        var found: ?usize = null;
        for (renderer.input_instances, 0..) |id, slot| {
            if (id == instance) found = slot;
        }
        check(found != null, if (pass == 0) "real JOYDEVICEADDED opens and registers a raw joystick" else "real raw reconnect registers its new instance");
        if (found) |slot| {
            check(renderer.joysticks[slot] != null and !renderer.controller_mapped[slot], "unmapped joystick retains an open raw SDL handle");
            check(!input.isPressed(.up) and !input.isPressed(.right) and !input.isPressed(.menu), "attached/reconnected joystick starts with clean held state");
            _ = button(joy, 0, 1);
            _ = button(joy, 9, 1);
            _ = axis(joy, 0, 25000);
            _ = hat(joy, 0, sdl.HAT_UP);
            _ = renderer.pumpEvents(input);
            renderer.pollSticks(input);
            check(input.isPressed(.confirm) and input.isPressed(.menu) and input.isPressed(.up) and input.isPressed(.right), "real raw button/hat/axis state dispatches and polls");
            key(lib, sdl.K_Z, true);
            _ = renderer.pumpEvents(input);
        }
        check(detach(index) == 0, "real SDL virtual raw joystick detaches");
        lib.JoystickClose(joy);
        _ = renderer.pumpEvents(input);
        check(!input.isPressed(.up) and !input.isPressed(.right) and !input.isPressed(.menu), "real raw disconnect clears held direction and START");
        if (found) |slot| {
            check(renderer.input_instances[slot] == -1 and renderer.joysticks[slot] == null, "real raw disconnect frees its device slot");
            check(input.isPressed(.confirm), "device disconnect preserves another source's held confirm");
        }
        key(lib, sdl.K_Z, false);
        _ = renderer.pumpEvents(input);
        input.endFrame();
    }

    // SDL_JOYSTICK_TYPE_GAMECONTROLLER makes a mapped virtual controller
    // on supported SDL builds. The native path must own both handles.
    const index = attach(1, 6, 15, 1);
    check(index >= 0, "real SDL virtual game controller attaches");
    if (index < 0) return;
    const joy = lib.JoystickOpen(index) orelse {
        _ = detach(index);
        check(false, "virtual mapped controller opens for driving state");
        return;
    };
    const instance = lib.JoystickInstanceID(joy);
    _ = renderer.pumpEvents(input);
    var found: ?usize = null;
    for (renderer.input_instances, 0..) |id, slot| {
        if (id == instance) found = slot;
    }
    if (found) |slot| {
        check(renderer.controller_mapped[slot] and renderer.controllers[slot] != null and renderer.joysticks[slot] != null, "real mapped hotplug opens controller and raw handles once");
        _ = button(joy, sdl.CB_Y, 1);
        _ = button(joy, sdl.CB_DPDOWN, 1);
        _ = axis(joy, 0, -25000);
        _ = renderer.pumpEvents(input);
        renderer.pollSticks(input);
        check(input.isPressed(.tag) and input.isPressed(.down) and input.isPressed(.left), "real mapped Y/dpad/stick state dispatches without raw duplicates");
        _ = button(joy, sdl.CB_Y, 0);
        _ = button(joy, sdl.CB_DPDOWN, 0);
        _ = axis(joy, 0, 0);
        _ = renderer.pumpEvents(input);
        renderer.pollSticks(input);
        check(!input.isPressed(.tag) and !input.isPressed(.down) and !input.isPressed(.left), "real mapped button/stick releases clear held state");
        _ = button(joy, sdl.CB_START, 1);
        _ = renderer.pumpEvents(input);
        check(input.isPressed(.menu), "real mapped START is held before disconnect");
    } else check(false, "real mapped hotplug registers its instance");
    check(detach(index) == 0, "real SDL virtual game controller detaches");
    lib.JoystickClose(joy);
    _ = renderer.pumpEvents(input);
    check(!input.isPressed(.menu) and !input.isPressed(.tag), "real mapped disconnect clears its held buttons");
    if (found) |slot| check(renderer.input_instances[slot] == -1 and renderer.controllers[slot] == null and renderer.joysticks[slot] == null, "duplicate raw/controller removal events leave one clean slot");
    input.endFrame();
}

/// The self-test never presents frames — feed the v29 present
/// watchdog manually so its boot-grace timer doesn't kill the test
/// during the audio sleeps.
fn feedWatchdog() void {
    renderer_mod.feedWatchdogBeat();
}

/// v30 M10: prove the mixer end-to-end — a real Vorbis file decoded,
/// mixed by the mixer thread, and queued to the (dummy) audio device.
fn audioCheck(lib: *sdl.Sdl2, alloc: std.mem.Allocator) void {
    const root = "/tmp/omori-audio-selftest";
    std.fs.cwd().deleteTree(root) catch {};
    defer std.fs.cwd().deleteTree(root) catch {};
    const dir = std.fs.path.join(alloc, &.{ root, "audio", "bgm" }) catch return;
    defer alloc.free(dir);
    std.fs.cwd().makePath(dir) catch return;
    const dst = std.fs.path.join(alloc, &.{ dir, "loop.ogg" }) catch return;
    defer alloc.free(dst);
    // the ffmpeg-generated fixture
    const src = std.fs.cwd().readFileAlloc(alloc, "/tmp/omori-mixer-test/se.ogg", 1024 * 1024) catch {
        log.event(.audio, .note, "selftest audio: SKIPPED (no /tmp/omori-mixer-test/se.ogg fixture)", .{});
        return;
    };
    defer alloc.free(src);
    std.fs.cwd().writeFile(.{ .sub_path = dst, .data = src }) catch return;

    var vfs = @import("../filesystem/vfs.zig").Vfs.init(alloc, root, root);
    defer vfs.deinit();

    var mixer = @import("../audio/mixer.zig").Mixer.init(alloc, lib, &vfs);
    defer mixer.deinit();
    if (!mixer.enabled) {
        log.event(.audio, .note, "selftest audio: SKIPPED (no audio device)", .{});
        return;
    }
    mixer.start(); // thread on this stack address
    mixer.playBgm("loop", 100, 100);
    // let the mixer thread produce + queue a few chunks
    std.Thread.sleep(300 * std.time.ns_per_ms);
    const queued = lib.GetQueuedAudioSize(mixer.dev);
    check(queued > 0, "audio mixer queues real decoded PCM (queued bytes > 0)");
    log.event(.audio, .note, "selftest audio: {d} bytes queued after 300 ms", .{queued});
    // fade + stop exercise (keep the present watchdog fed while sleeping)
    mixer.stopBgm(50);
    var slept: u32 = 0;
    while (slept < 120) : (slept += 20) {
        std.Thread.sleep(20 * std.time.ns_per_ms);
        feedWatchdog();
    }
    check(true, "audio fade-out path ran without deadlock");
}
