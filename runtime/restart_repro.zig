//! Fresh-process Continue regression. Uses only caller-supplied private saves.
//! Usage: restart-repro <www> <save-copy> <evidence-dir> <slot> <map> <x> <y>
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
const loop_mod = @import("src/mv/game_loop.zig");
extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
const ReadPixels = *const fn (?*anyopaque, ?*const sdl.Rect, u32, ?*anyopaque, c_int) callconv(.c) c_int;
var read_pixels: ReadPixels = undefined;
var evidence: []const u8 = undefined;
var target_slot: usize = 1;
var expected_map: u32 = 0;
var expected_x: i32 = 0;
var expected_y: i32 = 0;
var load_seen = false;
var cancelled = false;
var loaded = false;
var loaded_frame: u64 = 0;
var moved = false;
var menu_seen = false;
var passed = false;
var failure: ?[]const u8 = null;
var expect_backup = false;
var backup_notice = false;
fn noDelay(_: u32) callconv(.c) void {}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    if (args.len != 8 and args.len != 9) return error.Usage;
    if (args.len == 9) {
        if (!std.mem.eql(u8, args[8], "--expect-backup")) return error.Usage;
        expect_backup = true;
    }
    evidence = args[3];
    target_slot = try std.fmt.parseInt(usize, args[4], 10);
    expected_map = try std.fmt.parseInt(u32, args[5], 10);
    expected_x = try std.fmt.parseInt(i32, args[6], 10);
    expected_y = try std.fmt.parseInt(i32, args[7], 10);
    try std.fs.cwd().makePath(evidence);
    log.init(a, evidence);
    defer log.deinit();
    _ = setenv("SDL_VIDEODRIVER", "dummy", 1);
    _ = setenv("SDL_AUDIODRIVER", "dummy", 1);
    var lib = sdl.Sdl2.load(a) orelse return error.SdlUnavailable;
    if (lib.Init(sdl.INIT_VIDEO | sdl.INIT_TIMER) != 0) return error.SdlInit;
    const window = lib.CreateWindow("OMORI fresh-process load regression", 0, 0, 640, 480, 0) orelse return error.Window;
    const backend = lib.CreateRenderer(window, -1, 0) orelse return error.Renderer;
    _ = lib.RenderSetLogicalSize(backend, 640, 480);
    read_pixels = @ptrCast(@alignCast(dyn.sym(lib.handle, "SDL_RenderReadPixels") orelse return error.Readback));
    lib.Delay = noDelay;
    var renderer = renderer_mod.Renderer{ .allocator = a, .mode = .windowed, .sdl = lib, .window = window, .renderer = backend };
    defer renderer.deinit();
    var vfs = vfs_mod.Vfs.init(a, args[1], args[2]);
    defer vfs.deinit();
    var db = database.Database.init(a, &vfs);
    defer db.deinit();
    for (database.boot_database_files) |file| _ = try db.loadFile(.database, file);
    const yaml = try vfs.readFileSync("data/Atlas.yaml");
    defer a.free(yaml);
    var atlas = try atlas_mod.parseAtlasYaml(a, yaml);
    defer atlas.deinit(a);
    var assets = manager_mod.Manager.init(a, &vfs, 48 * 1024 * 1024);
    defer assets.deinit();
    var mgr = scenes.SceneManager.init(a, &db, &atlas);
    defer mgr.deinit();
    _ = try mgr.boot(&vfs, &assets);
    const data = try vfs.readFileSync("fonts/OMORI_GAME2.ttf");
    defer a.free(data);
    var font = try font_mod.Font.init(a, data);
    defer font.deinit();
    var texts = text_mod.TextStore.init(a, &vfs, "en");
    defer texts.deinit();
    var input = input_mod.Input{};
    var loop = loop_mod.GameLoop.init(a, &mgr, &vfs, &db, &atlas, &assets, &font, &renderer, &input);
    defer loop.deinit();
    loop.bindTexts(&texts);
    loop.scripted = tick;
    loop.max_frames = 600;
    _ = loop.run();
    if (failure) |message| {
        log.err("RESTART REPRO FAIL: {s}", .{message});
        return error.RestartRegression;
    }
    if (!passed or !cancelled or !load_seen or !loaded or !moved or !menu_seen) return error.RestartIncomplete;
    if (expect_backup and !backup_notice) return error.BackupNoticeMissing;
    log.milestone("RESTART REPRO PASS: fresh boot Map999 -> Continue -> cancel -> Continue -> select slot {d} -> map {d} ({d},{d}); map/player/data identities agree, movement and menu work; no save writes", .{ target_slot, expected_map, expected_x, expected_y });
}

fn fail(loop: *loop_mod.GameLoop, message: []const u8) void {
    failure = message;
    loop.quit = true;
}
fn tick(loop: *loop_mod.GameLoop, frame: u64) void {
    for ([_]u8{ sdl.CB_A, sdl.CB_B, sdl.CB_START, sdl.CB_DPUP, sdl.CB_DPDOWN, sdl.CB_DPLEFT, sdl.CB_DPRIGHT }) |button| loop.input.applyControllerButton(button, false);
    if (frame % 6 != 0) return;
    switch (loop.state) {
        .title => {
            if (loop.title.command_index != 1) loop.input.applyControllerButton(sdl.CB_DPDOWN, true) else loop.input.applyControllerButton(sdl.CB_A, true);
        },
        .load => {
            load_seen = true;
            if (!cancelled) {
                capture(loop, "load-list.ppm") catch return fail(loop, "cannot capture load list");
                cancelled = true;
                loop.input.applyControllerButton(sdl.CB_B, true);
            } else if (loop.load_index != target_slot - 1) {
                loop.input.applyControllerButton(if (loop.load_index < target_slot - 1) sdl.CB_DPDOWN else sdl.CB_DPUP, true);
            } else {
                capture(loop, "selected-slot.ppm") catch return fail(loop, "cannot capture selected slot");
                loop.input.applyControllerButton(sdl.CB_A, true);
            }
        },
        .field => {
            const game = &loop.mgr.game;
            if (!loaded) {
                if (!loop.continued_once or game.player.map_id != expected_map or game.map.map_id != expected_map or loop.mgr.dm.data_map_id != expected_map)
                    return fail(loop, "cold load restored inconsistent map identities");
                if (game.player.x != expected_x or game.player.y != expected_y or game.player.isTransferring() or game.temp.legacy_collision_recovery) return fail(loop, "cold load lost coordinates or retained transfer/recovery state");
                loaded = true;
                loaded_frame = frame;
                capture(loop, "loaded-field.ppm") catch return fail(loop, "cannot capture restored field");
                log.milestone("RESTART restored: map={d} player={d} data={d} position({d},{d}) playtime={d}s", .{ game.map.map_id, game.player.map_id, loop.mgr.dm.data_map_id, game.player.x, game.player.y, game.frame_count_global / 60 });
            }
            if (menu_seen) {
                passed = true;
                loop.quit = true;
                return;
            }
            if (game.player.x != expected_x or game.player.y != expected_y) moved = true;
            const elapsed = frame - loaded_frame;
            if (moved and loop.walk_remaining == 0) {
                loop.input.applyControllerButton(sdl.CB_START, true);
            } else if (elapsed < 192) {
                const button: u8 = switch ((elapsed / 48) % 4) {
                    0 => sdl.CB_DPDOWN,
                    1 => sdl.CB_DPUP,
                    2 => sdl.CB_DPLEFT,
                    else => sdl.CB_DPRIGHT,
                };
                loop.input.applyControllerButton(button, true);
            } else return fail(loop, "restored player cannot move in any direction");
        },
        .menu => {
            menu_seen = true;
            capture(loop, "restored-menu.ppm") catch return fail(loop, "cannot capture restored menu");
            loop.input.applyControllerButton(sdl.CB_B, true);
        },
        .toast => {
            if (!expect_backup or !std.mem.eql(u8, loop.toast_text, "LOADED PREVIOUS SAVE BACKUP")) return fail(loop, "unexpected load notification");
            if (!backup_notice) capture(loop, "backup-notice.ppm") catch return fail(loop, "cannot capture backup notice");
            backup_notice = true;
        },
        else => return fail(loop, "unexpected scene while loading checkpoint"),
    }
}

fn capture(loop: *loop_mod.GameLoop, name: []const u8) !void {
    const pixels = try loop.alloc.alloc(u8, 640 * 480 * 4);
    defer loop.alloc.free(pixels);
    if (read_pixels(loop.renderer.renderer.?, null, sdl.PIXELFORMAT_ABGR8888, pixels.ptr, 640 * 4) != 0) return error.Readback;
    const rgb = try loop.alloc.alloc(u8, 640 * 480 * 3);
    defer loop.alloc.free(rgb);
    for (0..640 * 480) |i| @memcpy(rgb[i * 3 ..][0..3], pixels[i * 4 ..][0..3]);
    const path = try std.fmt.allocPrint(loop.alloc, "{s}/{s}", .{ evidence, name });
    defer loop.alloc.free(path);
    var file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll("P6\n640 480\n255\n");
    try file.writeAll(rgb);
}
