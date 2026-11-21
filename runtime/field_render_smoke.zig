//! Developer-only real-map renderer/cache benchmark. This prepares Map087
//! directly; opening-smoke separately proves input-driven progression.
//! zig build-exe field_render_smoke.zig src/audio/stb_vorbis.c -lc -O ReleaseSafe
//! Usage: field_render_smoke <www-root> [field.ppm]
const std = @import("std");
const sdl = @import("src/platform/sdl2.zig");
const dyn = @import("src/platform/dyn.zig");
const renderer_mod = @import("src/renderer/renderer.zig");
const draw = @import("src/renderer/draw.zig");
const vfs_mod = @import("src/filesystem/vfs.zig");
const database = @import("src/data/database.zig");
const atlas_mod = @import("src/assets/atlas.zig");
const manager_mod = @import("src/assets/manager.zig");
const game_mod = @import("src/mv/game.zig");
const dm_mod = @import("src/mv/data_manager.zig");
const sprites = @import("src/mv/sprites.zig");
const map_render = @import("src/mv/map_render.zig");

extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
const ReadPixels = *const fn (?*anyopaque, ?*const sdl.Rect, u32, ?*anyopaque, c_int) callconv(.c) c_int;
const W = draw.GAME_W;
const H = draw.GAME_H;
var evictions: usize = 0;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    const result = run(gpa.allocator());
    const status = gpa.deinit();
    try result;
    if (status == .leak) return error.OwnedMemoryLeaked;
}

fn run(a: std.mem.Allocator) !void {
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    if (args.len < 2) return error.ExpectedExternalGameRoot;
    _ = setenv("SDL_VIDEODRIVER", "dummy", 1);
    _ = setenv("OMORI_FLUSH_DESTROY", "1", 1);
    var lib = sdl.Sdl2.load(a) orelse return error.SdlUnavailable;
    if (lib.Init(sdl.INIT_VIDEO) != 0) return error.SdlInitFailed;
    const window = lib.CreateWindow("OMORI field cache smoke", 0, 0, W, H, 0) orelse return error.WindowFailed;
    const backend = lib.CreateRenderer(window, -1, 0) orelse return error.RendererFailed;
    if (lib.RenderSetLogicalSize(backend, W, H) != 0) return error.LogicalSizeFailed;
    const read_pixels: ReadPixels = @ptrCast(@alignCast(dyn.sym(lib.handle, "SDL_RenderReadPixels") orelse return error.ReadPixelsUnavailable));
    var renderer = renderer_mod.Renderer{ .allocator = a, .mode = .windowed, .sdl = lib, .window = window, .renderer = backend };
    defer renderer.deinit();

    var vfs = vfs_mod.Vfs.init(a, args[1], "/var/tmp/omori-field-render-smoke-saves");
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
    var dm = dm_mod.DataManager.init(a, &db);
    defer dm.deinit();
    var game = game_mod.GameObjects.init(a, &db);
    defer game.deinit();
    try game.create();
    try game.party.setupStartingMembers(&dm);
    try dm.loadMapData(&vfs, 87);
    try game.map.setup(&dm.data_map.?, 87);
    if (dm.tiled_map) |*tiled| game.map.setupTiled(&dm.data_map.?, tiled);
    game.player.reserveTransfer(87, 28, 27, null, 0);
    _ = game.player.performTransfer();
    game.map.setDisplayPos(28.0 - game.map.playerCenterX(), 27.0 - game.map.playerCenterY());
    var loader = sprites.Loader.init(a, &assets, &atlas);
    defer loader.deinit();
    loader.on_evict = evicted;
    loader.evict_ctx = &renderer;
    var painter = map_render.MapRenderer.init(a, &loader, &db);
    defer painter.deinit();
    painter.setTileset(game.map.tileset_id, &dm);
    const before = try a.alloc(u8, W * H * 4);
    defer a.free(before);
    const after = try a.alloc(u8, W * H * 4);
    defer a.free(after);
    var warm_uploads: u64 = 0;
    var warm_rss: u64 = 0;
    var op_count: usize = 0;
    var warm_op_count: usize = 0;
    for (0..720) |frame| {
        op_count = try frameDraw(a, &loader, &painter, &dm, &game, &renderer, read_pixels, if (frame == 59) before else null);
        if (frame == 59) {
            warm_uploads = renderer.cache.uploads;
            warm_rss = rssBytes();
            warm_op_count = op_count;
        }
        if (frame >= 60) try require(op_count == warm_op_count, "idle field retains draw items from earlier frames");
    }
    const end_rss = rssBytes();
    try require(renderer.cache.uploads == warm_uploads, "idle field keeps uploading cached sheets");
    try require(end_rss <= warm_rss + 8 * 1024 * 1024, "idle renderer memory grows after warmup");
    const cached = renderer.cacheEntryCount();
    try require(cached > 0, "field did not use the sprite cache");
    // Force decoded-loader eviction at a frame boundary, exercising the
    // actual invalidation callback before any freed address can alias.
    loader.budget_bytes = 0;
    loader.beginFrame();
    try require(evictions > 0, "decoded cache eviction callback did not fire");
    try require(renderer.cacheEntryCount() == 0, "freed decoded pixels retained stale GPU keys");
    loader.budget_bytes = 24 * 1024 * 1024;
    _ = try frameDraw(a, &loader, &painter, &dm, &game, &renderer, read_pixels, after);
    try require(std.mem.eql(u8, before, after), "eviction/reload changed field pixels");
    try require(renderer.cache.uploads > warm_uploads, "evicted field did not upload fresh textures");
    if (args.len > 2) try writePpm(a, args[2], after);
    std.debug.print("FIELD RENDER PASS: 720 frames, {d} draw ops/frame, {d} warm uploads, {d} cached sheets; RSS {d}->{d} KiB; {d} decoded evictions/reload exact pixels\n", .{ op_count, warm_uploads, cached, warm_rss / 1024, end_rss / 1024, evictions });
}

fn frameDraw(a: std.mem.Allocator, loader: *sprites.Loader, painter: *map_render.MapRenderer, dm: *dm_mod.DataManager, game: *game_mod.GameObjects, renderer: *renderer_mod.Renderer, read_pixels: ReadPixels, snapshot: ?[]u8) !usize {
    loader.beginFrame();
    var list = draw.DrawList.init(a);
    defer list.deinit();
    painter.draw(&list, &dm.data_map.?, game, game.player.direction, false, 28, 27);
    try require(list.validate().errors == 0, "field draw validation failed");
    for (list.ops.items) |op| if (op == .sprite) try require(op.sprite.stable, "map art bypassed its persistent cache");
    list.render(&renderer.sdl.?, renderer.renderer.?, &renderer.cache, &renderer.text_cache);
    if (snapshot) |pixels| try read(read_pixels, renderer.renderer.?, pixels);
    renderer.sdl.?.RenderPresent(renderer.renderer.?);
    // Stable field drawing creates no temporary textures. Keep the same
    // cleanup contract as Renderer.presentList for future optional ops.
    list.finishFrame(&renderer.sdl.?);
    return list.ops.items.len;
}

fn evicted(ctx: ?*anyopaque, _: usize) void {
    const renderer: *renderer_mod.Renderer = @ptrCast(@alignCast(ctx.?));
    evictions += 1;
    _ = renderer.flushTextureCache("field renderer eviction regression");
}

fn read(read_pixels: ReadPixels, renderer: *anyopaque, pixels: []u8) !void {
    if (read_pixels(renderer, null, sdl.PIXELFORMAT_ABGR8888, pixels.ptr, W * 4) != 0) return error.ReadPixelsFailed;
}

fn rssBytes() u64 {
    const file = std.fs.cwd().openFile("/proc/self/statm", .{}) catch return 0;
    defer file.close();
    var bytes: [128]u8 = undefined;
    const n = file.readAll(&bytes) catch return 0;
    var fields = std.mem.tokenizeAny(u8, bytes[0..n], " \n");
    _ = fields.next();
    return (std.fmt.parseInt(u64, fields.next() orelse return 0, 10) catch return 0) * 4096;
}

fn require(ok: bool, message: []const u8) !void {
    if (!ok) {
        std.debug.print("FIELD RENDER FAIL: {s}\n", .{message});
        return error.FieldRenderFailed;
    }
}

fn writePpm(a: std.mem.Allocator, path: []const u8, pixels: []const u8) !void {
    const rgb = try a.alloc(u8, W * H * 3);
    defer a.free(rgb);
    for (0..W * H) |i| @memcpy(rgb[i * 3 ..][0..3], pixels[i * 4 ..][0..3]);
    const file = try std.fs.cwd().createFile(path, .{});
    defer file.close();
    var header: [64]u8 = undefined;
    try file.writeAll(try std.fmt.bufPrint(&header, "P6\n{d} {d}\n255\n", .{ W, H }));
    try file.writeAll(rgb);
}
