//! Optional controller-driven Options/credits regression with external assets.
//! Run edit, reload, then defaults in separate processes, using one private save root.
const std = @import("std");
const log = @import("src/core/log.zig");
const sdl = @import("src/platform/sdl2.zig");
const dyn = @import("src/platform/dyn.zig");
const renderer_mod = @import("src/renderer/renderer.zig");
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
const config = @import("src/mv/config.zig");
const Mode = enum { edit, reload, defaults };
var mode: Mode = .edit;
var phase: enum { enter_options, edit_options, return_title, credits, done } = .enter_options;
var row: usize = 0;
var pending = false;
var defaults_reset = false;
var reset_left_checked = false;
var visited: u16 = 0;
const reset_row = @intFromEnum(config.Row.reset);
var passed = false;
var failure: ?[]const u8 = null;
fn noDelay(_: u32) callconv(.c) void {}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    if (args.len != 5) return error.Usage;
    evidence = args[3];
    mode = std.meta.stringToEnum(Mode, args[4]) orelse return error.Usage;
    try std.fs.cwd().makePath(evidence);
    log.init(a, evidence);
    defer log.deinit();
    _ = setenv("SDL_VIDEODRIVER", "dummy", 1);
    _ = setenv("SDL_AUDIODRIVER", "dummy", 1);
    var lib = sdl.Sdl2.load(a) orelse return error.SdlUnavailable;
    if (lib.Init(sdl.INIT_VIDEO | sdl.INIT_TIMER) != 0) return error.SdlInit;
    const window = lib.CreateWindow("OMORI Options and credits regression", 0, 0, 640, 480, 0) orelse return error.Window;
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
    const expected: config.Settings = if (mode == .reload) changedSettings() else .{};
    if (!std.meta.eql(expected, loop.port_options) or loop.always_dash != expected.always_run) return error.FreshPreferencesMismatch;
    loop.scripted = tick;
    loop.max_frames = 600;
    _ = loop.run();
    if (failure) |message| {
        log.err("OPTIONS REPRO FAIL: {s}", .{message});
        return error.OptionsRegression;
    }
    if (!passed) return error.OptionsIncomplete;
    if (mode == .edit and visited != (@as(u16, 1) << config.row_count) - 1) return error.OptionsRowMissing;
    const description: []const u8 = switch (mode) {
        .edit => "all ten rows, nine controller edits, save/back, game-font credits and cancel",
        .reload => "separate-process preferences restored, controller reset applied and persisted",
        .defaults => "restored defaults survived another process restart",
    };
    log.milestone("OPTIONS REPRO PASS ({s}): {s}; {d} frames", .{ @tagName(mode), description, loop.frames });
}

fn changedSettings() config.Settings {
    return .{ .always_run = true, .master_volume = 90, .bgm_volume = 90, .bgs_volume = 90, .me_volume = 90, .se_volume = 90, .flashes = false, .shake = false, .instant_text = true };
}
fn fail(loop: *loop_mod.GameLoop, message: []const u8) void {
    failure = message;
    loop.quit = true;
}
fn tick(loop: *loop_mod.GameLoop, frame: u64) void {
    for ([_]u8{ sdl.CB_A, sdl.CB_B, sdl.CB_START, sdl.CB_DPUP, sdl.CB_DPDOWN, sdl.CB_DPLEFT, sdl.CB_DPRIGHT }) |button| loop.input.applyControllerButton(button, false);
    if (frame % 6 != 0) return;
    if (mode == .defaults) {
        if (loop.state != .title or !std.meta.eql(config.Settings{}, loop.port_options)) return fail(loop, "restored defaults did not survive restart");
        passed = true;
        loop.quit = true;
        return;
    }
    switch (phase) {
        .enter_options => {
            if (loop.state == .options) {
                capture(loop, if (mode == .edit) "options-defaults.ppm" else "options-reloaded.ppm") catch return fail(loop, "options readback failed");
                phase = .edit_options;
            } else if (loop.state == .title) {
                loop.input.applyControllerButton(if (loop.title.command_index == 2) sdl.CB_A else sdl.CB_DPDOWN, true);
            } else return fail(loop, "unexpected scene entering Options");
        },
        .edit_options => {
            if (loop.state != .options) return fail(loop, "left Options while editing");
            if (mode == .reload) {
                if (defaults_reset) {
                    if (!std.meta.eql(config.Settings{}, loop.port_options) or loop.always_dash) return fail(loop, "restore defaults did not apply");
                    capture(loop, "options-restored.ppm") catch return fail(loop, "restored readback failed");
                    loop.input.applyControllerButton(sdl.CB_B, true);
                    phase = .return_title;
                } else if (loop.opt_index != reset_row) {
                    loop.input.applyControllerButton(sdl.CB_DPDOWN, true);
                } else {
                    loop.input.applyControllerButton(sdl.CB_A, true);
                    defaults_reset = true;
                }
                return;
            }
            if (pending) {
                const edited_row: config.Row = @enumFromInt(row);
                if (loop.port_options.value(edited_row) != changedSettings().value(edited_row)) return fail(loop, "controller edit did not take effect");
                visited |= @as(u16, 1) << @as(u4, @intCast(row));
                row += 1;
                pending = false;
            }
            if (row < reset_row) {
                if (loop.opt_index != row) {
                    loop.input.applyControllerButton(sdl.CB_DPDOWN, true);
                } else {
                    const edited_row: config.Row = @enumFromInt(row);
                    loop.input.applyControllerButton(if (config.isVolume(edited_row)) sdl.CB_DPLEFT else sdl.CB_A, true);
                    pending = true;
                }
            } else if (loop.opt_index != reset_row) {
                loop.input.applyControllerButton(sdl.CB_DPDOWN, true);
            } else if (!reset_left_checked) {
                visited |= @as(u16, 1) << reset_row;
                loop.input.applyControllerButton(sdl.CB_DPLEFT, true);
                reset_left_checked = true;
            } else {
                if (!std.meta.eql(changedSettings(), loop.port_options) or !loop.always_dash) return fail(loop, "reset activated on left or settings were lost");
                capture(loop, "options-edited.ppm") catch return fail(loop, "edited options readback failed");
                loop.input.applyControllerButton(sdl.CB_B, true);
                phase = .return_title;
            }
        },
        .return_title => {
            if (loop.state != .title or loop.options_dirty) return fail(loop, "Options did not save and return to title");
            const expected: config.Settings = if (mode == .edit) changedSettings() else .{};
            const disk = config.Settings.load(loop.vfs);
            if (!std.meta.eql(expected, disk)) return fail(loop, "on-disk preferences differ from UI");
            if (mode == .reload) {
                passed = true;
                loop.quit = true;
                return;
            }
            if (loop.title.command_index != 3) loop.input.applyControllerButton(sdl.CB_DPDOWN, true) else {
                loop.input.applyControllerButton(sdl.CB_A, true);
                phase = .credits;
            }
        },
        .credits => {
            if (loop.state != .credits) return fail(loop, "credit command did not open credit scene");
            capture(loop, "credits-game-font.ppm") catch return fail(loop, "credit readback failed");
            loop.input.applyControllerButton(sdl.CB_B, true);
            phase = .done;
        },
        .done => {
            if (loop.state != .title) return fail(loop, "credit cancel did not return to title");
            passed = true;
            loop.quit = true;
        },
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
