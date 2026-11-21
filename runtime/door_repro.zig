//! Developer-only real-payload regression for the v34 Map087 door crash.
//! Copy beside runtime/build.zig and compile with:
//! zig build-exe door_repro.zig src/audio/stb_vorbis.c -lc -O Debug -femit-bin=omori-door-repro
//! Usage: omori-door-repro <www-root> <evidence-dir> [--neighbors-to-stump]
//! Uses the real GameLoop, maps, events, fonts, picture decoder, draw lists,
//! and SDL software renderer. Only wall-clock SDL_Delay is disabled.
const std = @import("std");
const log = @import("src/core/log.zig");
const sdl = @import("src/platform/sdl2.zig");
const dyn = @import("src/platform/dyn.zig");
const renderer_mod = @import("src/renderer/renderer.zig");
const draw = @import("src/renderer/draw.zig");
const font_mod = @import("src/text/font.zig");
const vfs_mod = @import("src/filesystem/vfs.zig");
const database = @import("src/data/database.zig");
const atlas_mod = @import("src/assets/atlas.zig");
const manager_mod = @import("src/assets/manager.zig");
const scenes = @import("src/mv/scenes.zig");
const text_mod = @import("src/omori/text.zig");
const input_mod = @import("src/input/input.zig");
const game_loop = @import("src/mv/game_loop.zig");
const memory_mod = @import("src/memory/budget.zig");
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
const ReadPixels = *const fn (?*anyopaque, ?*const sdl.Rect, u32, ?*anyopaque, c_int) callconv(.c) c_int;
const W = draw.GAME_W;
const H = draw.GAME_H;
var read_pixels: ReadPixels = undefined;
var evidence: []const u8 = undefined;
var intro999_seen = false;
var whitespace_seen = false;
var door_started = false;
var door_seen = false;
var door_frame: u64 = 0;
var full_door_seen = false;
var choice_seen = false;
var complete = false;
var fail_message: []const u8 = "";
var last_map: u32 = std.math.maxInt(u32);
var pixel_comparisons: usize = 0;
const Phase = enum { intro, objects, knife, door, neighbors, save, quit_to_title, continue_game, restored, flowers, recruit, stairs, stump, battle_start, battle_ui, battle_return };
const flowers = [_][2]i32{ .{ 11, 20 }, .{ 20, 18 }, .{ 21, 16 } };
var flower_index: usize = 0;
var flower_read = false;
var phase: Phase = .intro;
const object_events = [_]i32{ 3, 23, 28, 4 };
var object_index: usize = 0;
var interaction_started = false;
var knife_acquired = false;
var neighbor_dialogue = false;
var saw_partial_dialogue = false;
var saw_dialogue_pause = false;
var neighbor_interaction = false;
var walked_steps: usize = 0;
var previous_position: ?[2]i32 = null;
var saved_position: [2]i32 = .{ 0, 0 };
var saved_door_switch = false;
var restored_frame: u64 = 0;
var memory_budget: memory_mod.Budget = undefined;
var extend_neighbors = false;
var stump_seen = false;
var follower_glide_seen = false;
var independent_followers_seen = false;
var stump_frame: u64 = 0;
var recruit_target: i32 = -1;
var attack_without_knife: i64 = -1;
var battle_smoke = false;
var journal_smoke = false;
var journal_open_count: usize = 0;
var journal_close_count: usize = 0;
var journal_open_frame: u64 = 0;
var journal_open = false;
var journal_return_capture_pending = false;
var credits_captured = false;
var credits_returned = false;
var credits_frame: u64 = 0;
var battle_passed = false;
var battle_started_frame: u64 = 0;
var battle_skill_checked = false;
var battle_item_checked = false;
var battle_command_captured = false;
var battle_target_checked = false;
var battle_rewound = false;
var battle_rewind_checked = false;
var party_round_checked = false;
var battle_result_frame: u64 = 0;
var original_present: *const fn (?*anyopaque) callconv(.c) void = undefined;
var capture_loop: ?*game_loop.GameLoop = null;
const CaptureRequest = struct { name: []const u8, state: game_loop.State, battle_phase: u8, busy: bool, choices: bool };
var capture_requests: [16]CaptureRequest = undefined;
var capture_request_count: usize = 0;
fn noDelay(_: u32) callconv(.c) void {}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    memory_budget = memory_mod.Budget.init(a);
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    if (args.len < 3) return error.UsageDataRootAndEvidenceDir;
    evidence = args[2];
    if (args.len > 3) for (args[3..]) |arg| {
        if (std.mem.eql(u8, arg, "--neighbors-to-stump")) extend_neighbors = true;
        if (std.mem.eql(u8, arg, "--journal-smoke")) journal_smoke = true;
        if (std.mem.eql(u8, arg, "--battle-smoke")) {
            battle_smoke = true;
            extend_neighbors = true;
        }
    };
    if (battle_smoke) _ = setenv("OMORI_DEBUG_TROOP", "34", 1);
    try std.fs.cwd().makePath(evidence);
    log.init(a, evidence);
    defer log.deinit();
    _ = setenv("SDL_VIDEODRIVER", "dummy", 1);
    _ = setenv("SDL_AUDIODRIVER", "dummy", 1);
    _ = setenv("OMORI_LIVENESS", "0", 1);
    _ = setenv("OMORI_FLUSH_DESTROY", "1", 1);
    var lib = sdl.Sdl2.load(a) orelse return error.SdlUnavailable;
    if (lib.Init(sdl.INIT_VIDEO | sdl.INIT_TIMER) != 0) return error.SdlInitFailed;
    const window = lib.CreateWindow("OMORI door regression", 0, 0, W, H, 0) orelse return error.WindowFailed;
    const backend = lib.CreateRenderer(window, -1, 0) orelse return error.RendererFailed;
    if (lib.RenderSetLogicalSize(backend, W, H) != 0) return error.LogicalSizeFailed;
    read_pixels = @ptrCast(@alignCast(dyn.sym(lib.handle, "SDL_RenderReadPixels") orelse return error.ReadPixelsUnavailable));
    lib.Delay = noDelay;
    original_present = lib.RenderPresent;
    lib.RenderPresent = presentAndCapture;
    var renderer = renderer_mod.Renderer{ .allocator = a, .mode = .windowed, .sdl = lib, .window = window, .renderer = backend };
    defer renderer.deinit();
    var info: sdl.RendererInfo = undefined;
    if (lib.GetRendererInfo(backend, &info) != 0) return error.RendererInfoFailed;
    log.milestone("DOOR REPRO: SDL renderer={s}, real payload={s}", .{ if (info.name) |n| std.mem.span(n) else "unknown", args[1] });
    const save_root = try std.fmt.allocPrint(a, "{s}/saves", .{evidence});
    defer a.free(save_root);
    var vfs = vfs_mod.Vfs.init(a, args[1], save_root);
    defer vfs.deinit();
    var db = database.Database.init(a, &vfs);
    defer db.deinit();
    for (database.boot_database_files) |f| _ = try db.loadFile(.database, f);
    const yaml = try vfs.readFileSync("data/Atlas.yaml");
    defer a.free(yaml);
    var atlas = try atlas_mod.parseAtlasYaml(a, yaml);
    defer atlas.deinit(a);
    var assets = manager_mod.Manager.init(a, &vfs, 48 * 1024 * 1024);
    defer assets.deinit();
    var mgr = scenes.SceneManager.init(a, &db, &atlas);
    defer mgr.deinit();
    _ = try mgr.boot(&vfs, &assets);
    const font_data = try vfs.readFileSync("fonts/OMORI_GAME2.ttf");
    defer a.free(font_data);
    var font = try font_mod.Font.init(a, font_data);
    defer font.deinit();
    var texts = text_mod.TextStore.init(a, &vfs, "en");
    defer texts.deinit();
    var input = input_mod.Input{};
    var loop = game_loop.GameLoop.init(gpa.allocator(), &mgr, &vfs, &db, &atlas, &assets, &font, &renderer, &input);
    defer loop.deinit();
    capture_loop = &loop;
    defer capture_loop = null;
    loop.bindTexts(&texts);
    loop.scripted = tick;
    loop.max_frames = if (extend_neighbors) 20000 else 14000;
    _ = loop.run();
    if (fail_message.len > 0) {
        log.err("DOOR REPRO FAIL: {s}", .{fail_message});
        return error.DoorRegressionFailed;
    }
    if (journal_smoke and (journal_open_count != 3 or journal_close_count != 3 or !credits_captured or !credits_returned)) return error.JournalSequenceIncomplete;
    if (!complete or !intro999_seen or !whitespace_seen or !door_seen or !full_door_seen or !choice_seen or !knife_acquired or !neighbor_dialogue or !loop.save_happened or !loop.continued_once or walked_steps < 10 or pixel_comparisons == 0) {
        log.err("DOOR REPRO incomplete: complete={} intro={} whitespace={} door={} opaque={} choice={} knife={} dialogue={} save={} continue={} walking={d} pixels={d}", .{ complete, intro999_seen, whitespace_seen, door_seen, full_door_seen, choice_seen, knife_acquired, neighbor_dialogue, loop.save_happened, loop.continued_once, walked_steps, pixel_comparisons });
        return error.DoorSequenceIncomplete;
    }
    const memory = memory_budget.sample(assets.report().current_bytes);
    log.milestone("DOOR REPRO PASS: title -> Map999 intro -> Map087 -> four object interactions -> spawned knife acquired -> event2 (117 commands) -> ws_door -> language choices -> Map088 -> walking and TV dialogue -> SAVE -> title -> CONTINUE restored knife/door/page state, {d} exact source/readback pixels; {d} frames presented; RSS {d} MiB, sampled peak {d} MiB", .{ pixel_comparisons, renderer.frames_presented, memory.rss_bytes / (1024 * 1024), memory.rss_peak_bytes / (1024 * 1024) });
    if ((!loop.port_options.instant_text and !saw_partial_dialogue) or !saw_dialogue_pause) return error.DialogueFlowMissing;
    log.milestone("DIALOGUE SMOKE PASS: progressive text observed={}, authored pause observed={}", .{ saw_partial_dialogue, saw_dialogue_pause });
    if (journal_smoke) log.milestone("JOURNAL SMOKE PASS: laptop JOURNAL viewed three times, A/B/Escape each closes the authored picture wait, laptop LOG OFF returns to field; complete opening/save/continue still passes", .{});
    if (extend_neighbors) {
        if (!stump_seen) return error.NeighborsProgressionIncomplete;
        if (!independent_followers_seen or !follower_glide_seen) return error.FollowerMovementIncomplete;
        log.milestone("FOLLOWER SMOKE PASS: three recruited friends occupy successive tiles, glide between them and synchronize on entry to Map089", .{});
        log.milestone("NEIGHBORS PROGRESSION PASS: watermelon -> returned STUFFED TOY -> Aubrey switch102 -> Hero YES -> four party members -> stairs -> Map089; {d} actual tile steps", .{walked_steps});
    }
    if (battle_smoke) {
        if (!battle_passed) return error.BattleUiSmokeIncomplete;
        log.milestone("BATTLE SMOKE PASS: diagnostic troop34 via L1+R1, SKILL SAD POEM26, target/cancel, empty ITEM list, revise prior member, all four recruited actors choose targets before resolution, WIN and field return", .{});
    }
}

fn fail(loop: *game_loop.GameLoop, message: []const u8) void {
    fail_message = message;
    loop.quit = true;
}
fn pulse(loop: *game_loop.GameLoop, frame: u64, choice: i32) void {
    const msg = &loop.mgr.game.message;
    if (msg.layout) |layout| {
        if (!layout.ready and !layout.paused and layout.cursor > 0 and layout.cursor < layout.text.len) saw_partial_dialogue = true;
        if (layout.paused) saw_dialogue_pause = true;
    }
    if (frame % 12 != 0) return;
    if (msg.choicesVisible() and msg.choice_index != choice) {
        loop.input.applyControllerButton(if (msg.choice_index < choice) sdl.CB_DPDOWN else sdl.CB_DPUP, true);
    } else loop.input.applyControllerButton(sdl.CB_A, true);
}
fn knifeEquipped(loop: *game_loop.GameLoop) bool {
    const actor = loop.mgr.game.actors.actor(1) orelse return false;
    return actor.equips.items.len > 0 and actor.equips.items[0].is_weapon and actor.equips.items[0].item_id == 2;
}
fn knifeHeld(loop: *game_loop.GameLoop) bool {
    return knifeEquipped(loop) or loop.mgr.game.party.numWeapons(2) > 0;
}
fn starterSkillRetained(loop: *game_loop.GameLoop) bool {
    const actor = loop.mgr.game.actors.actor(1) orelse return false;
    return std.mem.indexOfScalar(i32, actor.skills.items, 26) != null;
}
var room_balloon_seen = false;
var room_pan_seen = false;

fn tick(loop: *game_loop.GameLoop, frame: u64) void {
    const game = &loop.mgr.game;
    const input = loop.input;
    if (loop.state == .field and game.map.map_id == 88) {
        if (!room_balloon_seen and game.map.balloons.count() != 0) {
            var cues = game.map.balloons.valueIterator();
            while (cues.next()) |cue| {
                if (cue.age < 24) continue;
                capture(loop, "room-reaction.ppm") catch return fail(loop, "could not capture room balloon");
                room_balloon_seen = true;
                log.milestone("BALLOON SMOKE PASS: authored Map088 event cue reached visible frame {d}", .{cue.column()});
                break;
            }
        }
        if (!room_pan_seen and game.map.isScrolling()) {
            room_pan_seen = true;
            log.milestone("CAMERA SMOKE: authored Map088 pan is progressing", .{});
        }
    }
    for ([_]u8{ sdl.CB_A, sdl.CB_B, sdl.CB_START, sdl.CB_DPUP, sdl.CB_DPDOWN, sdl.CB_DPLEFT, sdl.CB_DPRIGHT, sdl.CB_LEFTSHOULDER, sdl.CB_RIGHTSHOULDER }) |button|
        input.applyControllerButton(button, false);
    if (game.player.map_id != last_map) {
        last_map = game.player.map_id;
        previous_position = null;
        log.milestone("DOOR REPRO: observed map {d} @ frame {d}, position({d},{d})", .{ last_map, frame, game.player.x, game.player.y });
        if (last_map == 88) {
            phase = .neighbors;
            interaction_started = false;
            capture(loop, "neighbors-first-frame.ppm") catch {};
        } else if (last_map == 89 and extend_neighbors) {
            for (game.followers_trail) |slot| {
                if (slot.x != game.player.x or slot.y != game.player.y or slot.moving()) return fail(loop, "followers did not synchronize on the map transfer");
            }
            phase = .stump;
            stump_frame = frame;
        }
    }
    if (previous_position) |position| {
        if (position[0] != game.player.x or position[1] != game.player.y) walked_steps += 1;
    }
    previous_position = .{ game.player.x, game.player.y };
    if (journal_smoke and loop.state == .credits and !credits_returned) {
        if (!credits_captured) {
            capture(loop, "credits-jose-pilas.ppm") catch {};
            credits_captured = true;
            credits_frame = frame;
        }
        if (frame >= credits_frame + 30) input.applyControllerButton(sdl.CB_B, true);
        return;
    }
    if (loop.state == .title) {
        if (journal_smoke and !intro999_seen) {
            if (credits_captured) credits_returned = true;
            if (frame % 12 == 0) {
                const index: usize = if (credits_returned) 0 else 3;
                if (loop.title.command_index != index) input.applyControllerButton(sdl.CB_DPDOWN, true) else input.applyControllerButton(sdl.CB_A, true);
            }
            return;
        }
        if (phase == .quit_to_title) phase = .continue_game;
        if (phase == .continue_game and frame % 12 == 0) {
            if (loop.title.command_index != 1) input.applyControllerButton(sdl.CB_DPDOWN, true) else input.applyControllerButton(sdl.CB_A, true);
        } else if (frame == 10) input.applyControllerButton(sdl.CB_A, true);
        return;
    }
    // Continue now follows the original game's separate Load scene.
    // Confirm the selected slot through the same controller path.
    if (loop.state == .load) {
        if (phase != .continue_game) return fail(loop, "unexpected Load scene during opening");
        if (frame % 12 == 0) loop.input.applyControllerButton(sdl.CB_A, true);
        return;
    }
    if (game.player.map_id == 999) intro999_seen = true;
    if (game.player.map_id == 87) whitespace_seen = true;
    const idle = loop.state == .field and !loop.itp.chainRunning() and !game.message.isBusy() and loop.walk_remaining == 0;

    switch (phase) {
        .intro => {
            pulse(loop, frame, 0);
            // The actual map initializer must have run, rather than only
            // its first music autorun. It unlocks the knife parallel page.
            if (game.player.map_id == 87 and idle and game.self_switches.value(87, 8, "A")) {
                phase = .objects;
                capture(loop, "whitespace-before-objects.ppm") catch {};
                log.milestone("DOOR REPRO: WhiteSpace initializer completed; starting four object interactions", .{});
            }
        },
        .objects => {
            const id = object_events[object_index];
            if (loop.itp.chainRunning() and loop.itp.event_id == id) interaction_started = true;
            if (interaction_started) {
                if (journal_smoke and id == 3) {
                    if (journalInteraction(loop, frame)) return;
                }
                // Laptop's last choice is LOG OFF; sketchbook's first is
                // YES. Both choices flow through actual window input.
                const choice: i32 = if (id == 3 and game.message.choices.items.len > 0)
                    (if (journal_smoke and journal_close_count < 3) 1 else @as(i32, @intCast(game.message.choices.items.len - 1)))
                else
                    0;
                pulse(loop, frame, choice);
                if (idle and game.self_switches.value(87, id, "A")) {
                    object_index += 1;
                    interaction_started = false;
                    log.milestone("DOOR REPRO: object event{d} completed; count variable101={d}", .{ id, game.variables.value(101) });
                    if (object_index == object_events.len) {
                        attack_without_knife = if (game.actors.actor(1)) |actor| actor.param(2) else -1;
                        phase = .knife;
                    }
                }
            } else if (idle) {
                navigateToEvent(loop, id) catch return fail(loop, "could not navigate to WhiteSpace object");
            } else pulse(loop, frame, 0);
        },
        .knife => {
            pulse(loop, frame, 0);
            if (knifeHeld(loop)) {
                knife_acquired = true;
                if (idle) {
                    const actor = game.actors.actor(1) orelse return fail(loop, "OMORI actor missing after knife pickup");
                    if (!knifeEquipped(loop) or actor.param(2) != attack_without_knife + 5 or !starterSkillRetained(loop)) return fail(loop, "knife equip did not grant +5 attack or starting skill26 missing");
                    phase = .door;
                    interaction_started = false;
                    log.milestone("DOOR REPRO: real knife pickup equipped weapon2; ATK{d}->{d}, starting skill26 present; walked{d} tile steps", .{ attack_without_knife, actor.param(2), walked_steps });
                }
            } else if (idle and game.self_switches.value(87, 8, "B")) {
                navigateToEvent(loop, 8) catch return fail(loop, "could not navigate to spawned knife");
            }
        },
        .door => {
            if (!door_started and idle) {
                const page = game.map.currentPage(&loop.mgr.dm.data_map.?, 2, game) orelse return fail(loop, "door page missing");
                if (page.list.len != 117) return fail(loop, "door page differs from device117 commands");
                navigateToEvent(loop, 2) catch return fail(loop, "could not navigate to door");
            }
            if (loop.itp.chainRunning() and loop.itp.event_id == 2) door_started = true;
            if (game.screen.picture(2)) |pic| {
                if (std.mem.eql(u8, pic.name, "ws_door")) {
                    if (!door_seen) {
                        door_seen = true;
                        door_frame = frame;
                        if (pic.opacity != 0) return fail(loop, "first ws_door observation did not have opacity0");
                        checkPicture(loop) catch |err| {
                            log.err("DOOR PIXEL CHECK: {s}", .{@errorName(err)});
                            return fail(loop, "ws_door source/readback pixels differed or validation failed");
                        };
                        log.milestone("DOOR REPRO: ws_door opacity0 rendered; {d} source/readback pixels matched @ frame{d}", .{ pixel_comparisons, frame });
                    }
                    if (!full_door_seen and pic.opacity == 255 and game.screen.tone_duration == 0 and game.screen.tone[0] == 0) {
                        full_door_seen = true;
                        capture(loop, "door-opaque.ppm") catch return fail(loop, "could not capture opaque door frame");
                    }
                }
            }
            if (door_seen and game.message.choicesVisible()) {
                if (!choice_seen) log.milestone("DOOR REPRO: actual door choices available: {d}, selecting OPEN", .{game.message.choices.items.len});
                // tick runs before drawing; refresh this capture while
                // the choices are visible so it includes the window.
                capture(loop, "door-choices.ppm") catch return fail(loop, "could not capture door choice frame");
                choice_seen = true;
            }
            if (door_started) pulse(loop, frame, 0);
            if (door_seen and frame > door_frame + 3000) fail(loop, "door did not transfer within3000 frames");
        },
        .neighbors => {
            if (game.message.isBusy()) {
                neighbor_dialogue = true;
                capture(loop, "neighbors-dialogue.ppm") catch {};
            }
            if (loop.itp.chainRunning() and loop.itp.event_id == 3) neighbor_interaction = true;
            pulse(loop, frame, 0);
            if (idle) {
                if (neighbor_interaction and neighbor_dialogue) {
                    capture(loop, "neighbors-after-dialogue.ppm") catch {};
                    log.milestone("DOOR REPRO: NeighborsRoom TV interaction completed with{d} real walking steps", .{walked_steps});
                    phase = .save;
                } else navigateToEvent(loop, 3) catch return fail(loop, "could not navigate to NeighborsRoom TV");
            }
        },
        .save => {
            if (loop.state == .menu) {
                capture(loop, if (loop.menu_sub == .save) "save-menu.ppm" else "field-menu.ppm") catch {};
                if (frame % 12 == 0) {
                    if (loop.menu_sub == .root and loop.menu_index != 2) input.applyControllerButton(sdl.CB_DPDOWN, true) else input.applyControllerButton(sdl.CB_A, true);
                }
            } else if (loop.save_happened and idle) {
                saved_position = .{ game.player.x, game.player.y };
                saved_door_switch = game.self_switches.value(87, 2, "A");
                phase = .quit_to_title;
            } else if (idle and frame % 12 == 0) input.applyControllerButton(sdl.CB_B, true);
        },
        .quit_to_title => {
            if (loop.state == .menu and frame % 12 == 0) {
                if (loop.menu_index != 4) input.applyControllerButton(sdl.CB_DPDOWN, true) else input.applyControllerButton(sdl.CB_A, true);
            } else if (idle and frame % 12 == 0) input.applyControllerButton(sdl.CB_B, true);
        },
        .continue_game => {
            if (loop.continued_once and idle) {
                if (game.player.map_id != 88 or game.player.x != saved_position[0] or game.player.y != saved_position[1] or
                    !knifeHeld(loop) or !knifeEquipped(loop) or !starterSkillRetained(loop) or game.variables.value(101) < 4 or
                    game.self_switches.value(87, 2, "A") != saved_door_switch or !game.self_switches.value(87, 8, "C"))
                    return fail(loop, "CONTINUE did not restore map/position/knife/objectcount/door/knife-page switches");
                phase = .restored;
                restored_frame = frame;
                capture(loop, "continue-restored.ppm") catch {};
                const actor = game.actors.actor(1) orelse return fail(loop, "OMORI actor missing after continue");
                if (actor.param(2) != attack_without_knife + 5) return fail(loop, "CONTINUE did not retain knife attack bonus");
                log.milestone("DOOR REPRO: CONTINUE restored map88 at({d},{d}), equipped knife, +5ATK, skill26, objectcount4 and door/knife-page switches", .{ game.player.x, game.player.y });
            } else pulse(loop, frame, 0);
        },
        .restored => {
            if (frame > restored_frame + 30 and idle) {
                capture(loop, "continue-restored.ppm") catch return fail(loop, "could not capture restored map");
                phase = .flowers;
            }
        },
        .flowers => {
            if (flower_index == flowers.len) {
                if (!idle) return;
                const back = (routeDirection(loop, saved_position[0], saved_position[1]) catch return fail(loop, "cannot leave flower area")) orelse return fail(loop, "no return path from flowers");
                if (back != 0) {
                    input.applyControllerButton(directionButton(back), true);
                    return;
                }
                log.milestone("FLOWER SMOKE PASS: walked to all three solid plants, read and closed each localized inspection, returned to the checkpoint", .{});
                complete = true;
                if (extend_neighbors) phase = .recruit else loop.quit = true;
                return;
            }
            const flower = flowers[flower_index];
            if (game.player.x == flower[0] and game.player.y == flower[1]) return fail(loop, "entered solid flower tile");
            if (game.message.isBusy()) {
                const description = (loop.itp.texts.getMessageData("dw_flavor_text.message_92") catch null) orelse return fail(loop, "localized flower description missing");
                const layout = game.message.layout orelse return;
                if (!layout.ready) return;
                if (game.message.texts.items.len == 1 and std.mem.eql(u8, game.message.texts.items[0], description.text)) {
                    if (!flower_read and flower_index == 0) capture(loop, "flower-inspection.ppm") catch {};
                    flower_read = true;
                }
                // An inspection uses ordinary dialogue confirmation, unlike
                // the journal, which has its own picture-dismiss input.
                if (frame % 12 == 0) input.applyControllerButton(sdl.CB_A, true);
            } else if (idle and flower_read) {
                flower_read = false;
                flower_index += 1;
            } else if (idle) {
                navigateAdjacent(loop, flower[0], flower[1]) catch return fail(loop, "no legal approach to flower");
            }
        },
        .recruit => {
            if (game.message.isBusy() and loop.itp.event_id == 4) capture(loop, "aubrey-dialogue.ppm") catch {};
            if (game.message.isBusy() and loop.itp.event_id == 9) {
                if (game.party.last_gained.kind != .weapon or game.party.last_gained.item_id != 14) return fail(loop, "actual toy pickup retained wrong itemget metadata");
                capture(loop, "stuffed-toy-get.ppm") catch {};
            }
            if (idle) {
                if (game.party.members.items.len >= 4) {
                    // The recruitment pages retire the stationary NPCs as
                    // their actors begin following OMORI.
                    const raw = &loop.mgr.dm.data_map.?;
                    for ([_]i32{ 2, 4, 5 }) |event_id| {
                        const page = game.map.currentPage(raw, event_id, game) orelse return fail(loop, "recruited friend has no current event page");
                        const name = if (page.image) |graphic| graphic.getString("characterName") orelse "" else "";
                        if (name.len != 0) return fail(loop, "stationary duplicate of recruited friend is still visible");
                    }
                    capture(loop, "friends-recruited.ppm") catch {};
                    log.milestone("NEIGHBORS: actual Hero event recruited {d} party members; switch102={}", .{ game.party.members.items.len, game.switches.value(102) });
                    phase = .stairs;
                } else {
                    const target: i32 = if (game.party.numWeapons(14) == 0 and !game.switches.value(101)) 9 else if (!game.switches.value(102)) 4 else 2;
                    if (target != recruit_target) log.milestone("NEIGHBORS: walking to actual event{d}, stuffedtoy={d} switch101={} switch102={}", .{ target, game.party.numWeapons(14), game.switches.value(101), game.switches.value(102) });
                    recruit_target = target;
                    navigateToEvent(loop, target) catch return fail(loop, "could not navigate NeighborsRoom story object");
                }
            } else pulse(loop, frame, 0);
        },
        .stairs => {
            var x = game.player.x;
            var y = game.player.y;
            var distinct: usize = 0;
            for (game.followers_trail, 0..) |slot, i| {
                const actor = game.followerActor(i) orelse return fail(loop, "recruited party member invisible");
                if (actor.character_name.len == 0) return fail(loop, "missing recruited follower graphic");
                if (@abs(slot.x - x) > 1 or @abs(slot.y - y) > 1) return fail(loop, "follower left the preceding member's path");
                if (slot.x != x or slot.y != y) distinct += 1;
                if (slot.moving() and (@floor(slot.real_x) != slot.real_x or @floor(slot.real_y) != slot.real_y)) follower_glide_seen = true;
                x = slot.x;
                y = slot.y;
            }
            if (distinct == 3 and !independent_followers_seen) {
                independent_followers_seen = true;
                capture(loop, "party-trail.ppm") catch return fail(loop, "cannot capture follower trail");
            }
            if (idle) {
                const event = loop.mgr.dm.data_map.?.events.items[7] orelse return fail(loop, "stairs missing");
                const direction = (routeDirection(loop, event.x, event.y) catch return fail(loop, "stairs route failed")) orelse return fail(loop, "stairs route unavailable");
                if (direction != 0) input.applyControllerButton(directionButton(direction), true);
            } else pulse(loop, frame, 0);
        },
        .stump => {
            pulse(loop, frame, 0);
            if (frame > stump_frame + 30 and idle) {
                if (game.party.members.items.len < 4 or !game.switches.value(102)) return fail(loop, "Map089 reached without actual party recruitment");
                capture(loop, "stump-map089.ppm") catch return fail(loop, "could not capture stump");
                stump_seen = true;
                if (battle_smoke) phase = .battle_start else loop.quit = true;
            }
        },
        .battle_start => {
            if (loop.state == .battle) {
                phase = .battle_ui;
                battle_started_frame = frame;
                log.milestone("BATTLE SMOKE: diagnostic battle entered through actual L1+R1 input", .{});
            } else if (idle) {
                input.applyControllerButton(sdl.CB_LEFTSHOULDER, true);
                input.applyControllerButton(sdl.CB_RIGHTSHOULDER, true);
            } else pulse(loop, frame, 0);
        },
        .battle_ui => {
            if (loop.state == .battle_result) {
                if (battle_result_frame == 0) battle_result_frame = frame;
                if (frame > battle_result_frame + 2) {
                    if (loop.battle_result != .win) return fail(loop, "diagnostic battle did not win");
                    capture(loop, "battle-win.ppm") catch {};
                    if (frame % 12 == 0) input.applyControllerButton(sdl.CB_A, true);
                }
            } else if (loop.state == .field) {
                restored_frame = frame;
                phase = .battle_return;
            } else if (loop.state == .battle) switch (loop.battle_phase) {
                .command => {
                    const b = &loop.battle.?;
                    if (battle_rewound and !battle_rewind_checked and frame % 12 == 0) {
                        if (b.party_commands.items.len != 0 or b.nextCommandActor().?.actor_id != game.party.members.items[0]) return fail(loop, "back did not return to the first actor");
                        battle_rewind_checked = true;
                    }
                    if (!battle_command_captured and frame > battle_started_frame + 2) {
                        capture(loop, "battle-command.ppm") catch {};
                        battle_command_captured = true;
                    }
                    if (frame % 12 == 0) {
                        if (b.party_commands.items.len == 1 and !battle_rewound) {
                            input.applyControllerButton(sdl.CB_B, true);
                            battle_rewound = true;
                            return;
                        }
                        const target: usize = if (!battle_skill_checked) 1 else if (!battle_item_checked) 2 else 0;
                        input.applyControllerButton(if (loop.battle_command_index != target) sdl.CB_DPDOWN else sdl.CB_A, true);
                    }
                },
                .skill_list => {
                    const skill_index = std.mem.indexOfScalar(i32, loop.battle_skills.items, 26) orelse return fail(loop, "SAD POEM26 missing from actual SKILL list");
                    for ([_]i32{ 2, 46, 49 }) |internal_skill| {
                        if (std.mem.indexOfScalar(i32, loop.battle_skills.items, internal_skill) != null) return fail(loop, "internal basic/chain skill leaked into SKILL list");
                    }
                    capture(loop, "battle-skill-list.ppm") catch {};
                    if (frame % 12 == 0) {
                        input.applyControllerButton(if (battle_skill_checked) sdl.CB_B else if (loop.battle_list_index != skill_index) sdl.CB_DPDOWN else sdl.CB_A, true);
                    }
                },
                .item_list => {
                    if (loop.battle_skills.items.len != 0) return fail(loop, "unexpected regular item acquired on route; update item smoke expectation");
                    capture(loop, "battle-item-empty.ppm") catch {};
                    if (frame % 12 == 0) {
                        battle_item_checked = true;
                        input.applyControllerButton(sdl.CB_B, true);
                    }
                },
                .target => {
                    if (loop.battle_target_return == .skill_list) {
                        capture(loop, "battle-skill-target.ppm") catch {};
                        if (frame % 12 == 0) {
                            battle_skill_checked = true;
                            input.applyControllerButton(sdl.CB_B, true);
                        }
                    } else {
                        capture(loop, "battle-attack-target.ppm") catch {};
                        battle_target_checked = true;
                        if (frame % 12 == 0) input.applyControllerButton(sdl.CB_A, true);
                    }
                },
                .resolving => {
                    if (!party_round_checked) {
                        const commands = loop.battle.?.party_commands.items;
                        if (commands.len != 4 or commands.len != game.party.members.items.len) return fail(loop, "incomplete four-actor round");
                        for (commands, game.party.members.items) |chosen, id| {
                            if (chosen.subject_index != id or chosen.target_index != 0) return fail(loop, "actor or selected target lost before resolution");
                        }
                        party_round_checked = true;
                    }
                },
                else => {},
            };
        },
        .battle_return => {
            if (frame > restored_frame + 30 and idle) {
                if (!battle_command_captured or !battle_skill_checked or !battle_item_checked or !battle_target_checked or !battle_rewind_checked or !party_round_checked) return fail(loop, "battle UI smoke phases incomplete");
                capture(loop, "battle-returned-field.ppm") catch {};
                battle_passed = true;
                loop.quit = true;
            }
        },
    }
    if (frame % 600 == 0) {
        const memory = memory_budget.sample(loop.assets.report().current_bytes);
        log.milestone("DOOR REPRO: progress phase={s} map{d} player({d},{d}) event{d} commands{d} var101={d} RSS={d}MiB", .{ @tagName(phase), game.player.map_id, game.player.x, game.player.y, loop.itp.event_id, loop.itp.index, game.variables.value(101), memory.rss_bytes / (1024 * 1024) });
        if (phase == .recruit) capture(loop, "neighbors-recruit-progress.ppm") catch {};
    }
}

fn directionButton(direction: i32) u8 {
    return switch (direction) {
        2 => sdl.CB_DPDOWN,
        4 => sdl.CB_DPLEFT,
        6 => sdl.CB_DPRIGHT,
        else => sdl.CB_DPUP,
    };
}
fn clearTile(loop: *game_loop.GameLoop, x: i32, y: i32) bool {
    const game = &loop.mgr.game;
    if (x < 0 or y < 0 or x >= game.map.width or y >= game.map.height) return false;
    const raw = &loop.mgr.dm.data_map.?;
    for (raw.events.items) |maybe_event| {
        const event = maybe_event orelse continue;
        if (event.x != x or event.y != y) continue;
        const page = game.map.currentPage(raw, event.id, game) orelse continue;
        if (page.priority_type == 1 and !page.through) return false;
    }
    return true;
}
// Breadth-first search selects dpad input only. GameLoop performs every
// movement, collision check, touch event, camera glide and action trigger.
fn routeDirection(loop: *game_loop.GameLoop, target_x: i32, target_y: i32) !?i32 {
    const game = &loop.mgr.game;
    if (game.player.x == target_x and game.player.y == target_y) return 0;
    if (!clearTile(loop, target_x, target_y)) return null;
    const width: usize = @intCast(game.map.width);
    const height: usize = @intCast(game.map.height);
    const count = width * height;
    const first = try loop.alloc.alloc(i32, count);
    defer loop.alloc.free(first);
    @memset(first, -1);
    const queue = try loop.alloc.alloc([2]i32, count);
    defer loop.alloc.free(queue);
    queue[0] = .{ game.player.x, game.player.y };
    first[@as(usize, @intCast(game.player.y)) * width + @as(usize, @intCast(game.player.x))] = 0;
    var head: usize = 0;
    var tail: usize = 1;
    const moves = [_][3]i32{ .{ 0, -1, 8 }, .{ -1, 0, 4 }, .{ 1, 0, 6 }, .{ 0, 1, 2 } };
    while (head < tail) : (head += 1) {
        const pos = queue[head];
        const previous = first[@as(usize, @intCast(pos[1])) * width + @as(usize, @intCast(pos[0]))];
        for (moves) |move| {
            const nx = pos[0] + move[0];
            const ny = pos[1] + move[1];
            if (!clearTile(loop, nx, ny)) continue;
            if (game.map.isTiled() and !game.map.tiledCanStep(pos[0], pos[1], move[2])) continue;
            const index = @as(usize, @intCast(ny)) * width + @as(usize, @intCast(nx));
            if (first[index] != -1) continue;
            first[index] = if (previous == 0) move[2] else previous;
            if (nx == target_x and ny == target_y) return first[index];
            queue[tail] = .{ nx, ny };
            tail += 1;
        }
    }
    return null;
}
fn navigateToEvent(loop: *game_loop.GameLoop, event_id: i32) !void {
    const game = &loop.mgr.game;
    const raw = &loop.mgr.dm.data_map.?;
    const event = raw.events.items[@intCast(event_id)] orelse return error.MissingEvent;
    if (event.x == game.player.x and event.y == game.player.y) {
        if (!extend_neighbors or loop.frames % 12 == 0) loop.input.applyControllerButton(sdl.CB_A, true);
        return;
    }
    return navigateAdjacent(loop, event.x, event.y);
}

fn navigateAdjacent(loop: *game_loop.GameLoop, x: i32, y: i32) !void {
    const game = &loop.mgr.game;
    // Prefer standing below, so direction-gated laptop/door pages see UP.
    const targets = [_][3]i32{ .{ x, y + 1, 8 }, .{ x - 1, y, 6 }, .{ x + 1, y, 4 }, .{ x, y - 1, 2 } };
    for (targets) |target| {
        if (try routeDirection(loop, target[0], target[1])) |direction| {
            if (direction == 0) {
                if (game.player.direction != target[2]) loop.input.applyControllerButton(directionButton(target[2]), true) else if (!extend_neighbors or loop.frames % 12 == 0) loop.input.applyControllerButton(sdl.CB_A, true);
            } else loop.input.applyControllerButton(directionButton(direction), true);
            return;
        }
    }
    return error.NoRouteToEvent;
}
fn checkPicture(loop: *game_loop.GameLoop) !void {
    const a = loop.alloc;
    var dl = draw.DrawList.init(a);
    defer dl.deinit();
    const sprite = loop.loader.get(&dl, "img/pictures/ws_door.png") orelse return error.PictureMissing;
    log.milestone("DOOR SOURCE: {d}x{d} src({d},{d},{d},{d})", .{ sprite.width, sprite.height, sprite.src.x, sprite.src.y, sprite.src.w, sprite.src.h });
    if (sprite.width <= 0 or sprite.height <= 0) return error.PictureDimensions;
    const surface = dl.surfaces.items[sprite.handle];
    if (@as(u64, surface.width) * surface.height * 4 != surface.pixels.len) return error.SurfaceDimensions;
    dl.pushClear(0, 0, 0);
    dl.pushSprite(sprite.handle, sprite.src, .{ .x = 0, .y = 0, .w = sprite.width, .h = sprite.height }, 255);
    if (dl.validate().errors != 0) return error.InvalidDrawList;
    const lib = &loop.renderer.sdl.?;
    const backend = loop.renderer.renderer.?;
    dl.render(lib, backend, &loop.renderer.cache, &loop.renderer.text_cache);
    defer dl.finishFrame(lib);
    const pixels = try a.alloc(u8, W * H * 4);
    defer a.free(pixels);
    if (read_pixels(backend, null, sdl.PIXELFORMAT_ABGR8888, pixels.ptr, W * 4) != 0) return error.ReadPixels;
    var y: usize = 0;
    while (y < @min(H, sprite.height)) : (y += 7) {
        var x: usize = 0;
        while (x < @min(W, sprite.width)) : (x += 7) {
            const sx = x + @as(usize, @intCast(sprite.src.x));
            const sy = y + @as(usize, @intCast(sprite.src.y));
            const source = surface.pixels[(sy * surface.width + sx) * 4 ..][0..4];
            if (source[3] != 255) continue;
            const actual = pixels[(y * W + x) * 4 ..][0..4];
            if (!std.mem.eql(u8, source, actual)) return error.PixelMismatch;
            pixel_comparisons += 1;
        }
    }
    if (pixel_comparisons < 100) return error.InsufficientOpaquePixels;
    try writePpm(a, "door-source-readback.ppm", pixels);
}
fn journalInteraction(loop: *game_loop.GameLoop, frame: u64) bool {
    const game = &loop.mgr.game;
    const picture = game.screen.picture(3);
    const visible = if (picture) |p| std.mem.eql(u8, p.name, "ws_laptop_journal") else false;
    if (journal_return_capture_pending and !visible and game.screen.brightness == 255 and game.message.choicesVisible() and game.message.choices.items.len == 3) {
        capture(loop, "journal-menu-restored.ppm") catch {};
        journal_return_capture_pending = false;
        return true;
    }
    if (!journal_open and visible and game.screen.brightness == 255 and loop.itp.child != null) {
        journal_open = true;
        journal_open_frame = frame;
        journal_open_count += 1;
        capture(loop, switch (journal_open_count) {
            1 => "journal-confirm.ppm",
            2 => "journal-cancel.ppm",
            else => "journal-escape.ppm",
        }) catch {};
        log.milestone("JOURNAL SMOKE: picture open {d}; waiting without input", .{journal_open_count});
    }
    if (journal_open) {
        if (!visible) {
            journal_open = false;
            journal_close_count += 1;
            journal_return_capture_pending = true;
            log.milestone("JOURNAL SMOKE: picture closed {d} after actual button input", .{journal_close_count});
        } else {
            if (frame >= journal_open_frame + 30) {
                loop.input.applyControllerButton(switch (journal_open_count) {
                    1 => sdl.CB_A,
                    2 => sdl.CB_B,
                    else => sdl.CB_START,
                }, true);
            }
            return true;
        }
    }
    return false;
}

fn capture(loop: *game_loop.GameLoop, name: []const u8) !void {
    if (capture_request_count == capture_requests.len) return error.CaptureQueueFull;
    capture_requests[capture_request_count] = .{ .name = name, .state = loop.state, .battle_phase = @intFromEnum(loop.battle_phase), .busy = loop.mgr.game.message.isBusy(), .choices = loop.mgr.game.message.choices.items.len > 0 };
    capture_request_count += 1;
}
fn presentAndCapture(backend: ?*anyopaque) callconv(.c) void {
    if (capture_loop) |loop| {
        for (capture_requests[0..capture_request_count]) |request| {
            // Input/update can close a message or change battle phase.
            // Keep the last frame of the requested visible state.
            if (request.state != loop.state) continue;
            if ((loop.state == .battle or loop.state == .battle_result) and request.battle_phase != @intFromEnum(loop.battle_phase)) continue;
            if (request.busy and !loop.mgr.game.message.isBusy()) continue;
            if (request.choices and loop.mgr.game.message.choices.items.len == 0) continue;
            readCapture(loop, request.name) catch |err| {
                log.err("capture failed before present: {s}", .{@errorName(err)});
                fail(loop, "SDL pre-present capture failed");
            };
        }
    }
    capture_request_count = 0;
    original_present(backend);
}
fn readCapture(loop: *game_loop.GameLoop, name: []const u8) !void {
    const pixels = try loop.alloc.alloc(u8, W * H * 4);
    defer loop.alloc.free(pixels);
    if (read_pixels(loop.renderer.renderer.?, null, sdl.PIXELFORMAT_ABGR8888, pixels.ptr, W * 4) != 0) return error.ReadPixels;
    try writePpm(loop.alloc, name, pixels);
}
fn writePpm(a: std.mem.Allocator, name: []const u8, pixels: []const u8) !void {
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ evidence, name });
    defer a.free(path);
    const rgb = try a.alloc(u8, W * H * 3);
    defer a.free(rgb);
    for (0..W * H) |i| @memcpy(rgb[i * 3 ..][0..3], pixels[i * 4 ..][0..3]);
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    const header = try std.fmt.allocPrint(a, "P6\n{d} {d}\n255\n", .{ W, H });
    defer a.free(header);
    try file.writeAll(header);
    try file.writeAll(rgb);
}
