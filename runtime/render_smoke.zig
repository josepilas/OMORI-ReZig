//! Real SDL2 software-renderer pixel checks, with no proprietary assets.
//! Linux: zig build render-smoke -- [font.ttf] [title-screenshot.ppm] [title-sheet.webp] [character-sheet.webp]
//! Defaults to the system NotoMono font; SDL2 must be installed.
const std = @import("std");
const sdl = @import("src/platform/sdl2.zig");
const dyn = @import("src/platform/dyn.zig");
const renderer_mod = @import("src/renderer/renderer.zig");
const draw = @import("src/renderer/draw.zig");
const font_mod = @import("src/text/font.zig");
const title_mod = @import("src/mv/title_scene.zig");
const image_codec = @import("src/codec/image.zig");
const map_render = @import("src/mv/map_render.zig");

extern "c" fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
const W = draw.GAME_W;
const H = draw.GAME_H;
const ReadPixels = *const fn (?*anyopaque, ?*const sdl.Rect, u32, ?*anyopaque, c_int) callconv(.c) c_int;

pub fn main() !void {
    const a = std.heap.page_allocator;
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    const font_path = if (args.len > 1) args[1] else "/usr/share/fonts/truetype/noto/NotoMono-Regular.ttf";
    const font_data = try std.fs.cwd().readFileAlloc(a, font_path, 8 * 1024 * 1024);
    defer a.free(font_data);
    var font = try font_mod.Font.init(a, font_data);
    defer font.deinit();
    try checkGlyphRuns(a, &font);
    _ = setenv("SDL_VIDEODRIVER", "dummy", 1);
    _ = setenv("OMORI_FLUSH_DESTROY", "1", 1);
    var lib = sdl.Sdl2.load(a) orelse return error.SdlUnavailable;
    if (lib.Init(sdl.INIT_VIDEO) != 0) return error.SdlInitFailed;
    const window = lib.CreateWindow("OMORI renderer smoke", 0, 0, W, H, 0) orelse return error.WindowFailed;
    const backend = lib.CreateRenderer(window, -1, 0) orelse return error.RendererFailed;
    var version: sdl.Version = undefined;
    lib.GetVersion(&version);
    var info: sdl.RendererInfo = undefined;
    if (lib.GetRendererInfo(backend, &info) != 0) return error.RendererInfoFailed;
    std.debug.print("SDL2 {d}.{d}.{d}, renderer={s}\n", .{ version.major, version.minor, version.patch, if (info.name) |name| std.mem.span(name) else "unknown" });
    if (lib.RenderSetLogicalSize(backend, W, H) != 0) return error.LogicalSizeFailed;
    const read_pixels: ReadPixels = @ptrCast(@alignCast(dyn.sym(lib.handle, "SDL_RenderReadPixels") orelse return error.ReadPixelsUnavailable));
    var renderer = renderer_mod.Renderer{
        .allocator = a,
        .mode = .windowed,
        .sdl = lib,
        .window = window,
        .renderer = backend,
    };

    // The default transparent sheet isolates glyphs from art/codecs. An
    // optional local game sheet also exercises the actual image decoder.
    // Game data remains external to the project and is never bundled.
    const sheet = if (args.len > 3) blk: {
        const encoded = try std.fs.cwd().readFileAlloc(a, args[3], 32 * 1024 * 1024);
        defer a.free(encoded);
        const decoded = try image_codec.decode(a, encoded);
        if (decoded.width != 1464 or decoded.height != 1053) {
            a.free(decoded.pixels);
            return error.UnexpectedTitleSheetSize;
        }
        std.debug.print("external title sheet: {d}x{d} image RGBA OK\n", .{ decoded.width, decoded.height });
        break :blk decoded.pixels;
    } else blk: {
        const transparent = try a.alloc(u8, 1464 * 1053 * 4);
        @memset(transparent, 0);
        break :blk transparent;
    };
    defer a.free(sheet);
    var title = title_mod.TitleScene{
        .alloc = a,
        .atlas = undefined,
        .assets = undefined,
        .font = &font,
        .texts = undefined,
        .command_labels = .{ "NEW GAME", "CONTINUE", "OPTIONS", "PORTED BY" },
        .sheet_surface = .{ .width = 1464, .height = 1053, .pixels = sheet },
    };
    const pixels = try a.alloc(u8, W * H * 4);
    defer a.free(pixels);
    for (0..3) |frame| {
        var dl = draw.DrawList.init(a);
        defer dl.deinit();
        try title.draw(&dl);
        try require(dl.validate().errors == 0, "title draw list invalid");
        dl.render(&lib, backend, &renderer.cache, &renderer.text_cache);
        try read(read_pixels, backend, pixels);
        try require(rgbIs(pixels, title_mod.COMMAND_START_X + 2, title_mod.COMMAND_Y + 2, 20, 20, 20), "selected black box missing");
        var white_glyphs: usize = 0;
        var gray_glyphs: usize = 0;
        const first_right: usize = @intCast(title_mod.COMMAND_START_X + font.measureText(title.command_labels[0], title.commandFontSize()).width + 24);
        for (title_mod.COMMAND_Y + 2..title_mod.COMMAND_Y + title_mod.COMMAND_HEIGHT - 2) |y| {
            for (title_mod.COMMAND_START_X + 2..first_right - 2) |x| {
                const p = rgba(pixels, x, y);
                if (p[0] > 220 and p[1] > 220 and p[2] > 220) white_glyphs += 1;
            }
            for (first_right + 30..W - 10) |x| {
                const p = rgba(pixels, x, y);
                if (p[0] > 30 and p[0] < 200 and p[0] == p[1] and p[1] == p[2]) gray_glyphs += 1;
            }
        }
        try require(white_glyphs > 8, "selected white glyphs missing");
        try require(gray_glyphs > 20, "unselected gray labels missing");
        if (frame == 2 and args.len > 2) try writePpm(a, args[2], pixels);
        lib.RenderPresent(backend);
        dl.finishFrame(&lib);
        std.debug.print("title frame {d}: black selection, {d} white glyph pixels, {d} gray glyph pixels OK\n", .{ frame + 1, white_glyphs, gray_glyphs });
    }

    // Preserve the live SDL table across an actual Renderer value move,
    // while invalidating the source table before destroying cached art.
    var moved = renderer;
    renderer.sdl = null;
    renderer.renderer = null;
    renderer.window = null;
    defer moved.deinit();
    try require(moved.flushTextureCache("real SDL move smoke") == 1, "moved Renderer did not release title upload");
    try require(moved.cacheEntryCount() == 0, "moved Renderer cache not empty");
    std.debug.print("moved Renderer: cached SDL texture destroyed through live table OK\n", .{});

    // A fade queued after a red sprite must darken it, rather than being
    // moved under the sprite by an unordered clear/fill prepass.
    var dl = draw.DrawList.init(a);
    defer dl.deinit();
    const red = [_]u8{ 255, 0, 0, 255 };
    const surface = draw.Surface{ .width = 1, .height = 1, .pixels = &red };
    const handle = dl.addSurface(&surface);
    dl.pushClear(255, 255, 255);
    dl.pushSprite(handle, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .x = 0, .y = 0, .w = W, .h = H }, 255);
    dl.pushFill(0, 0, 0, 128);
    dl.render(&lib, backend, &moved.cache, &moved.text_cache);
    try read(read_pixels, backend, pixels);
    const faded = rgba(pixels, 400, 300);
    try require(faded[0] >= 126 and faded[0] <= 128 and faded[1] == 0 and faded[2] == 0, "fade did not cover red sprite");
    lib.RenderPresent(backend);
    dl.finishFrame(&lib);
    std.debug.print("ordered fade: red sprite -> ({d},{d},{d}) after 50% black overlay OK\n", .{ faded[0], faded[1], faded[2] });

    dl.clear();
    const two_pixels = [_]u8{ 180, 0, 0, 255, 0, 120, 0, 255 };
    const pair = dl.addSurface(&.{ .width = 2, .height = 1, .pixels = &two_pixels });
    const src = draw.Rect{ .x=0, .y=0, .w=2, .h=1 };
    dl.pushClear(0,0,30);
    dl.pushTransformed(pair,src,.{ .x=10,.y=10,.w=20,.h=10 },255,.{.flip=1,.additive=true});
    dl.pushSpriteStable(pair,src,.{ .x=40,.y=10,.w=20,.h=10 },255);
    dl.pushTransformed(pair,src,.{ .x=90,.y=20,.w=20,.h=10 },255,.{.angle=90,.pivot=.{.x=0,.y=0}});
    dl.render(&lib,backend,&moved.cache,&moved.text_cache);
    try read(read_pixels,backend,pixels);
    try require(rgbIs(pixels,14,14,0,120,30) and rgbIs(pixels,25,14,180,0,30),"mirrored additive picture pixels");
    try require(rgbIs(pixels,44,14,180,0,0),"picture blend leaked to the following sprite");
    try require(rgbIs(pixels,85,24,180,0,0) and rgbIs(pixels,85,35,0,120,0),"rotation around the top-left origin");
    lib.RenderPresent(backend);
    dl.finishFrame(&lib);
    std.debug.print("picture transforms: mirror, pivot rotation and additive isolation OK\n", .{});

    if (args.len > 4) {
        const encoded = try std.fs.cwd().readFileAlloc(a, args[4], 32 * 1024 * 1024);
        defer a.free(encoded);
        const img = try image_codec.decode(a, encoded);
        defer a.free(img.pixels);
        const rect = map_render.MapRenderer.characterFrameRect(@intCast(img.width), @intCast(img.height), "DW_OMORI", 0, 2, 1) orelse return error.CharacterFrameUnavailable;
        try require(rect.w == 32 and rect.h == 32, "DW_OMORI frame is not 32x32");
        const character = draw.Surface{ .width = img.width, .height = img.height, .pixels = img.pixels };
        var character_dl = draw.DrawList.init(a);
        defer character_dl.deinit();
        character_dl.pushClear(255, 255, 255);
        const character_handle = character_dl.addSurface(&character);
        character_dl.pushSprite(character_handle, rect, .{ .x = W / 2 - 64, .y = H / 2 - 64, .w = 128, .h = 128 }, 255);
        character_dl.render(&lib, backend, &moved.cache, &moved.text_cache);
        try read(read_pixels, backend, pixels);
        var ink: usize = 0;
        for (H / 2 - 64..H / 2 + 64) |y| {
            for (W / 2 - 64..W / 2 + 64) |x| {
                if (!rgbIs(pixels, x, y, 255, 255, 255)) ink += 1;
            }
        }
        try require(ink > 64, "character frame has no visible ink");
        if (args.len > 2) {
            const path = try std.fmt.allocPrint(a, "{s}.character.ppm", .{args[2]});
            defer a.free(path);
            try writePpm(a, path, pixels);
        }
        lib.RenderPresent(backend);
        character_dl.finishFrame(&lib);
        std.debug.print("character sheet: {d}x{d}, standing frame ({d},{d}) {d}x{d}, {d} enlarged ink pixels OK\n", .{ img.width, img.height, rect.x, rect.y, rect.w, rect.h, ink });
    }
}

fn require(ok: bool, message: []const u8) !void {
    if (!ok) {
        std.debug.print("FAIL: {s}\n", .{message});
        return error.PixelCheckFailed;
    }
}

fn checkGlyphRuns(a: std.mem.Allocator, font: *font_mod.Font) !void {
    // A real font's uppercase glyphs may cross the baseline too. Preserve
    // all coverage, rather than merely requiring a few visible pixels.
    for ([_]u32{ 24, 32, 48 }) |size| {
        for ("EGgy") |cp| {
            const glyph = (try font.rasterize(font.glyphId(cp), size)).*;
            try require(glyph.width > 0 and glyph.height > 0, "test glyph is empty");
            var dl = draw.DrawList.init(a);
            defer dl.deinit();
            const laid = [_]draw.DrawList.LaidGlyph{.{ .glyph = glyph, .x = -glyph.bearing_x }};
            const index = dl.addTextRun(&laid, glyph.width, size);
            const run = dl.runs.items[index];
            var expected_alpha: u64 = 0;
            var expected_ink: usize = 0;
            for (glyph.coverage) |cov| {
                expected_alpha += cov;
                if (cov != 0) expected_ink += 1;
            }
            var actual_alpha: u64 = 0;
            var actual_ink: usize = 0;
            var offset: usize = 3;
            while (offset < run.pixels.len) : (offset += 4) {
                const cov = run.pixels[offset];
                actual_alpha += cov;
                if (cov != 0) actual_ink += 1;
            }
            try require(actual_alpha == expected_alpha and actual_ink == expected_ink, "text run clipped glyph coverage");
            std.debug.print("glyph {c} size={d}: {d} ink pixels, alpha={d}, below-baseline rows={d} preserved OK\n", .{
                cp, size, actual_ink, actual_alpha, @max(0, @as(i32, @intCast(glyph.height)) - glyph.top),
            });
        }
    }
}

fn read(read_pixels: ReadPixels, backend: *anyopaque, pixels: []u8) !void {
    if (read_pixels(backend, null, sdl.PIXELFORMAT_ABGR8888, pixels.ptr, W * 4) != 0) return error.ReadPixelsFailed;
}
fn rgba(pixels: []const u8, x: usize, y: usize) []const u8 {
    return pixels[(y * W + x) * 4 ..][0..4];
}
fn rgbIs(pixels: []const u8, x: usize, y: usize, r: u8, g: u8, b: u8) bool {
    const p = rgba(pixels, x, y);
    return p[0] == r and p[1] == g and p[2] == b;
}
fn writePpm(a: std.mem.Allocator, path: []const u8, pixels: []const u8) !void {
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
