//! Draw list — the backend-agnostic presentation contract (M6).
//!
//! Scenes emit an ordered list of draw operations each frame:
//!   * `clear`  — full-canvas fill (the white title background)
//!   * `sprite` — blit of a decoded RGBA surface's sub-rectangle into a
//!     destination rect, with 0..255 opacity (the atlas sprite pipeline)
//!   * `text`   — a rasterized text run (color + pixel position)
//!
//! Backends:
//!   * **Headless validation** — walks the list, verifies every rect is
//!     in-bounds and every sprite references a loaded surface, and
//!     records counts for the milestone trail (the M6 acceptance proof
//!     runs entirely headless).
//!   * **SDL2 windowed** — uploads surfaces as streaming textures
//!     (SDL_PIXELFORMAT_ABGR8888) and blits with SDL_RenderCopy through
//!     the letterboxed logical 640x480 presentation.
//!
//! MV pixel semantics: opacity multiplies the surface alpha (same as
//! PIXI's Sprite.alpha × texture alpha).

const std = @import("std");
const log = @import("../core/log.zig");
const sdl = @import("../platform/sdl2.zig");
const renderer_mod = @import("renderer.zig");
const TexCache = renderer_mod.TexCache;
const TextTexCache = renderer_mod.TextTexCache;

pub const GAME_W: i32 = @import("../core/canvas.zig").WIDTH;
pub const GAME_H: i32 = @import("../core/canvas.zig").HEIGHT;

pub const Rect = struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const Surface = struct {
    width: u32,
    height: u32,
    pixels: []const u8, // RGBA, row-major (borrowed — caller owns)

};

pub const SpriteTransform = struct {
    angle: f64 = 0,
    flip: c_int = 0,
    pivot: sdl.Point = .{ .x = 0, .y = 0 },
    additive: bool = false,
};

pub const DrawOp = union(enum) {
    clear: struct { r: u8, g: u8, b: u8 },
    /// v28: full-canvas alpha fill (screen tint / fade to black).
    fill: struct { r: u8, g: u8, b: u8, a: u8 },
    sprite: struct {
        /// index into the surface table (set by the renderer).
        surface: u32,
        src: Rect,
        dst: Rect,
        opacity: u8,
        /// v29: the surface's pixel store is stable for the whole scene
        /// (scene-owned) — the texture cache may keep its upload alive
        /// across frames. Per-frame reallocating callers leave false.
        stable: bool = false,
        transform: SpriteTransform = .{},
    },
    text: struct {
        /// index into the text-run table (rasterized beforehand).
        run: u32,
        x: i32,
        y: i32,
        r: u8,
        g: u8,
        b: u8,
    },
};

/// A rasterized text run (already composited glyphs on transparent RGBA).
pub const TextRun = struct {
    width: u32,
    height: u32,
    pixels: []u8, // owned RGBA
};

pub const DrawList = struct {
    alloc: std.mem.Allocator,
    ops: std.ArrayList(DrawOp) = .empty,
    // Copy surface metadata: callers may pass stack wrappers or values
    // inside a growing asset hash map. Only the pixel slice is borrowed.
    surfaces: std.ArrayList(Surface) = .empty,
    runs: std.ArrayList(TextRun) = .empty,
    /// Per-frame sprite textures live until finishFrame, called by the
    /// renderer after RenderPresent. Stable uploads live in the cache.
    frame_textures: std.ArrayList(?*anyopaque) = .empty,

    pub fn init(alloc: std.mem.Allocator) DrawList {
        return .{ .alloc = alloc };
    }

    pub fn deinit(self: *DrawList) void {
        // Safety net: if a windowed frame died mid-render (panic between
        // render and finishFrame), the textures leak — destroying them
        // here without a live renderer would be worse on some backends.
        // finishFrame is the ONLY destroy site.
        self.frame_textures.deinit(self.alloc);
        for (self.runs.items) |*r| self.alloc.free(r.pixels);
        self.runs.deinit(self.alloc);
        self.surfaces.deinit(self.alloc);
        self.ops.deinit(self.alloc);
    }

    pub fn clear(self: *DrawList) void {
        self.ops.clearRetainingCapacity();
        for (self.runs.items) |*r| self.alloc.free(r.pixels);
        self.runs.clearRetainingCapacity();
        self.surfaces.clearRetainingCapacity();
        self.frame_textures.clearRetainingCapacity();
    }

    /// Register a decoded surface once per frame, including repeated
    /// atlas lookups whose stack wrappers differ but pixels are shared.
    pub fn addSurface(self: *DrawList, s: *const Surface) u32 {
        for (self.surfaces.items, 0..) |existing, i| {
            if (existing.pixels.ptr == s.pixels.ptr and existing.pixels.len == s.pixels.len and existing.width == s.width and existing.height == s.height) return @intCast(i);
        }
        const idx: u32 = @intCast(self.surfaces.items.len);
        self.surfaces.append(self.alloc, s.*) catch return 0;
        return idx;
    }

    pub fn pushClear(self: *DrawList, r: u8, g: u8, b: u8) void {
        self.ops.append(self.alloc, .{ .clear = .{ .r = r, .g = g, .b = b } }) catch {};
    }

    /// v28: full-canvas alpha fill — tint screens and fades.
    pub fn pushFill(self: *DrawList, r: u8, g: u8, b: u8, a: u8) void {
        self.ops.append(self.alloc, .{ .fill = .{ .r = r, .g = g, .b = b, .a = a } }) catch {};
    }

    pub fn pushSprite(self: *DrawList, surface: u32, src: Rect, dst: Rect, opacity: u8) void {
        self.ops.append(self.alloc, .{ .sprite = .{ .surface = surface, .src = src, .dst = dst, .opacity = opacity, .stable = false } }) catch {};
    }

    /// v29: stable-surface variant — the caller guarantees the surface's
    /// pixels outlive the frame (scene-owned sheet); the renderer keeps
    /// the uploaded texture in its cache until the scene changes.
    pub fn pushSpriteStable(self: *DrawList, surface: u32, src: Rect, dst: Rect, opacity: u8) void {
        self.ops.append(self.alloc, .{ .sprite = .{ .surface = surface, .src = src, .dst = dst, .opacity = opacity, .stable = true } }) catch {};
    }

    pub fn pushTransformed(self: *DrawList, surface: u32, src: Rect, dst: Rect, opacity: u8, transform: SpriteTransform) void {
        self.ops.append(self.alloc, .{ .sprite = .{ .surface = surface, .src = src, .dst = dst, .opacity = opacity, .stable = true, .transform = transform } }) catch {};
    }

    pub fn pushText(self: *DrawList, run: u32, x: i32, y: i32, r: u8, g: u8, b: u8) void {
        self.ops.append(self.alloc, .{ .text = .{ .run = run, .x = x, .y = y, .r = r, .g = g, .b = b } }) catch {};
    }

    /// Rasterize + register a text run; returns the run index.
    /// `glyphs` = (glyph, pen_x) pairs already laid out by the caller.
    /// `height` is the minimum line height; reserve space below the
    /// baseline for every glyph, extending unusually tall runs to fit.
    pub fn addTextRun(self: *DrawList, glyphs: []const LaidGlyph, width: u32, height: u32) u32 {
        // OMORI_GAME2 has ink below the baseline even in uppercase E/G.
        // Placing the baseline at `height` cut off E's bottom bar and all
        // lowercase descenders. Keep a shared baseline above that space.
        var ascent: i32 = 0;
        var descent: i32 = 0;
        for (glyphs) |lg| {
            const g = lg.glyph;
            if (g.width == 0 or g.height == 0) continue;
            ascent = @max(ascent, g.top);
            descent = @max(descent, @as(i32, @intCast(g.height)) - g.top);
        }
        const run_height = @max(height, @as(u32, @intCast(ascent + descent)));
        const baseline = @as(i32, @intCast(run_height)) - descent;
        const pixels = self.alloc.alloc(u8, @as(usize, width) * run_height * 4) catch return 0;
        @memset(pixels, 0);
        for (glyphs) |lg| {
            const g = lg.glyph;
            const gx = lg.x + g.bearing_x;
            const gy = baseline - g.top;
            var row: i32 = 0;
            while (row < @as(i32, @intCast(g.height))) : (row += 1) {
                var col: i32 = 0;
                while (col < @as(i32, @intCast(g.width))) : (col += 1) {
                    const px = gx + col;
                    const py = gy + row;
                    if (px < 0 or py < 0 or px >= @as(i32, @intCast(width)) or py >= @as(i32, @intCast(run_height))) continue;
                    const cov = g.coverage[@intCast(row * @as(i32, @intCast(g.width)) + col)];
                    if (cov == 0) continue;
                    const idx = (@as(usize, @intCast(py)) * width + @as(usize, @intCast(px))) * 4;
                    pixels[idx] = 255;
                    pixels[idx + 1] = 255;
                    pixels[idx + 2] = 255;
                    pixels[idx + 3] = @max(pixels[idx + 3], cov);
                }
            }
        }
        const idx: u32 = @intCast(self.runs.items.len);
        self.runs.append(self.alloc, .{ .width = width, .height = run_height, .pixels = pixels }) catch {
            self.alloc.free(pixels);
            return 0;
        };
        return idx;
    }

    pub const LaidGlyph = struct {
        /// Glyph BY VALUE: the font cache is a hash map — pointers into
        /// it invalidate on rehash; the coverage slice is separately
        /// allocated and stays stable.
        glyph: @import("../text/font.zig").Glyph,
        x: i32,
    };

    // -----------------------------------------------------------------
    // Headless validation
    // -----------------------------------------------------------------

    pub const Validation = struct {
        op_count: usize = 0,
        sprites: usize = 0,
        texts: usize = 0,
        clear_count: usize = 0,
        /// pixels covered by sprite dst rects (for the coverage proof).
        sprite_area: i64 = 0,
        errors: usize = 0,
    };

    /// Walk the list and validate invariants: in-bounds rects, valid
    /// surface refs, non-empty sub-rects. Headless M6 acceptance.
    pub fn validate(self: *const DrawList) Validation {
        var v = Validation{};
        for (self.ops.items) |op| {
            v.op_count += 1;
            switch (op) {
                .clear => |c| {
                    v.clear_count += 1;
                    _ = c;
                },
                .fill => |f| {
                    v.clear_count += 1;
                    _ = f;
                },
                .sprite => |s| {
                    v.sprites += 1;
                    if (s.surface >= self.surfaces.items.len) {
                        v.errors += 1;
                        log.event(.res, .err, "draw validation: bad surface index {d}", .{s.surface});
                        continue;
                    }
                    const surf = self.surfaces.items[s.surface];
                    if (s.src.x < 0 or s.src.y < 0 or
                        s.src.x + s.src.w > @as(i32, @intCast(surf.width)) or
                        s.src.y + s.src.h > @as(i32, @intCast(surf.height)) or
                        s.src.w <= 0 or s.src.h <= 0)
                    {
                        v.errors += 1;
                        log.event(.res, .err, "draw validation: sprite src {d} out of surface {d}x{d}", .{ s.src.w, surf.width, surf.height });
                        continue;
                    }
                    if (s.dst.w <= 0 or s.dst.h <= 0) {
                        v.errors += 1;
                        continue;
                    }
                    v.sprite_area += @as(i64, s.dst.w) * s.dst.h;
                },
                .text => |t| {
                    v.texts += 1;
                    if (t.run >= self.runs.items.len) {
                        v.errors += 1;
                        continue;
                    }
                },
            }
        }
        return v;
    }

    /// Render through SDL2 (windowed mode). v29: stable surfaces go
    /// through the Renderer's texture cache (the 6 MiB title sheet
    /// uploads ONCE instead of per frame); every SDL failure is logged
    /// (v28 continued silently — a white screen told us nothing).
    ///
    /// v34 — THE TEXT PATH REWRITE:
    ///   * text runs go through the CONTENT-ADDRESSED TextTexCache
    ///     (hash of the tinted pixels + tint + dims): static labels reuse
    ///     uploads until cache eviction;
    ///   * per-frame SPRITE textures are collected in frame_textures and
    ///     destroyed by finishFrame() AFTER RenderPresent — never inside
    ///     render();
    ///   * TEXT-DIAG-2: the first few text draws log the full SDL-side
    ///     state (query/blend/mod/dst) so any remaining invisibility is
    ///     localizable to the exact call.
    pub fn render(self: *const DrawList, lib: *sdl.Sdl2, renderer: *anyopaque, cache: *TexCache, text_cache: *TextTexCache) void {
        // per-frame (uncached) sprite textures: collected, destroyed AFTER
        // present (see finishFrame). MUTABLE state on a *const method is
        // unacceptable — render() is invoked on the loop-owned list, so
        // cast to the mutable view it really owns (same object).
        const mut: *DrawList = @constCast(self);
        var textures = self.alloc.alloc(?*anyopaque, self.surfaces.items.len) catch return;
        defer self.alloc.free(textures);
        @memset(textures, null);

        for (self.ops.items) |op| {
            switch (op) {
                // Draw in emission order: fades/tints are queued after
                // the world and must cover it instead of sitting below.
                .clear => |c| {
                    _ = lib.SetRenderDrawColor(renderer, c.r, c.g, c.b, 255);
                    _ = lib.RenderClear(renderer);
                },
                .fill => |f| {
                    _ = lib.SetRenderDrawBlendMode(renderer, sdl.BLENDMODE_BLEND);
                    _ = lib.SetRenderDrawColor(renderer, f.r, f.g, f.b, f.a);
                    _ = lib.RenderFillRect(renderer, null);
                    _ = lib.SetRenderDrawBlendMode(renderer, 0);
                },
                .sprite => |s| {
                    if (s.surface >= self.surfaces.items.len) continue;
                    const surf = self.surfaces.items[s.surface];
                    if (surf.width == 0 or surf.height == 0) continue; // v29: 0x0 textures are rejected by SDL
                    var use: ?*anyopaque = null;
                    if (s.stable) {
                        // v29: cached path — upload once per scene.
                        const key: *const anyopaque = @ptrCast(surf.pixels.ptr);
                        use = cache.get(lib, renderer, key, surf.width, surf.height);
                        if (use == null) {
                            use = cache.put(lib, renderer, key, surf.width, surf.height, surf.pixels);
                        }
                    }
                    if (use == null) {
                        if (textures[s.surface]) |t| {
                            use = t;
                        } else {
                            const tex = lib.CreateTexture(renderer, sdl.PIXELFORMAT_ABGR8888, sdl.TEXTUREACCESS_STREAMING, @intCast(surf.width), @intCast(surf.height));
                            if (tex == null) {
                                log.warn("draw: SDL_CreateTexture failed for {d}x{d}: {s}", .{ surf.width, surf.height, std.mem.span(lib.GetError()) });
                                continue;
                            }
                            _ = lib.SetTextureBlendMode(tex, sdl.BLENDMODE_BLEND);
                            if (lib.UpdateTexture(tex, null, surf.pixels.ptr, @intCast(surf.width * 4)) != 0) {
                                log.warn("draw: SDL_UpdateTexture failed ({d}x{d}): {s}", .{ surf.width, surf.height, std.mem.span(lib.GetError()) });
                                lib.DestroyTexture(tex);
                                continue;
                            }
                            textures[s.surface] = tex;
                            // v34: tracked via the per-surface table below —
                            // destroyed after present (see finishFrame).
                            use = tex;
                        }
                    }
                    const tex = use.?;
                    _ = lib.SetTextureAlphaMod(tex, s.opacity);
                    var src = sdlRect(s.src);
                    var dst = scaleRect(s.dst);
                    if (s.transform.additive) _ = lib.SetTextureBlendMode(tex, 2); // SDL_BLENDMODE_ADD
                    defer if (s.transform.additive) {
                        _ = lib.SetTextureBlendMode(tex, sdl.BLENDMODE_BLEND);
                    };
                    const rc = if (s.transform.flip != 0 or s.transform.angle != 0)
                        lib.RenderCopyEx(renderer, tex, &src, &dst, s.transform.angle, &s.transform.pivot, s.transform.flip)
                    else
                        lib.RenderCopy(renderer, tex, &src, &dst);
                    if (rc != 0) {
                        log.warn("draw: SDL_RenderCopy failed (sprite {d}x{d}): {s}", .{ s.src.w, s.src.h, std.mem.span(lib.GetError()) });
                    }
                },
                .text => |t| {
                    if (t.run >= self.runs.items.len) continue;
                    const run = self.runs.items[t.run];
                    if (run.width == 0 or run.height == 0) {
                        // v29: 0x0 textures are rejected by SDL — v33: say
                        // so (throttled) instead of vanishing silently.
                        if (text_runs_skipped_logged < 10) {
                            text_runs_skipped_logged += 1;
                            log.event(.res, .note, "TEXT-SKIP: run {d} is {d}x{d} (empty run — glyph pipeline produced nothing; see TEXT-DIAG lines)", .{ t.run, run.width, run.height });
                        }
                        continue;
                    }
                    // v34: tint FIRST (the cache key covers the tint), then
                    // the content-addressed cache — a hit reuses a texture
                    // that was created once and kept alive.
                    const tinted = tintRun(self.alloc, &run, t.r, t.g, t.b) catch continue;
                    defer self.alloc.free(tinted);
                    const key = TextTexCache.keyOf(tinted, run.width, run.height, t.r, t.g, t.b);
                    var tex = text_cache.get(key);
                    const from_cache = tex != null;
                    if (tex == null) {
                        tex = text_cache.put(lib, renderer, key, run.width, run.height, tinted);
                    }
                    const draw_tex = tex orelse continue; // upload failed — already logged
                    // v34 TEXT-DIAG-2: first N text draws dump the SDL-side
                    // truth (query/blend/mods/dst + return codes) — one
                    // device run then localizes any invisibility exactly.
                    if (text_cache.diag_logged < 6) {
                        text_cache.diag_logged += 1;
                        var fmt: u32 = 0;
                        var access: c_int = 0;
                        var qw: c_int = 0;
                        var qh: c_int = 0;
                        const qrc = lib.QueryTexture(draw_tex, &fmt, &access, &qw, &qh);
                        const dst = scaleRect(.{ .x = t.x, .y = t.y, .w = @intCast(run.width), .h = @intCast(run.height) });
                        log.event(.res, .note, "TEXT-DIAG-2 run {d}: {d}x{d} tint=({d},{d},{d}) dst=({d},{d},{d},{d}) tex=0x{x} {s} query=({s} fmt=0x{x} acc={d} {d}x{d}) blend_rc={d} colormod_rc={d} alphamod_rc={d}", .{
                            t.run,                                           run.width,                             run.height, t.r,   t.g,                   t.b,
                            dst.x,                                           dst.y,                                 dst.w,      dst.h, @intFromPtr(draw_tex), if (from_cache) "CACHED" else "UPLOADED",
                            if (qrc == 0) "ok" else "FAIL",                  fmt,                                   access,     qw,    qh,                    lib.SetTextureBlendMode(draw_tex, sdl.BLENDMODE_BLEND),
                            lib.SetTextureColorMod(draw_tex, 255, 255, 255), lib.SetTextureAlphaMod(draw_tex, 255),
                        });
                    }
                    var dst = scaleRect(.{ .x = t.x, .y = t.y, .w = @intCast(run.width), .h = @intCast(run.height) });
                    if (lib.RenderCopy(renderer, draw_tex, null, &dst) != 0) {
                        log.warn("draw: SDL_RenderCopy (text) failed: {s}", .{std.mem.span(lib.GetError())});
                    }
                },
            }
        }

        // hand the per-surface texture table to frame_textures (post-present
        // destroy). Duplicates (same surface drawn twice) can't occur: the
        // per-surface table is the dedup; frame_textures holds the same
        // pointers only once per surface.
        for (textures) |t| {
            if (t) |tex| {
                mut.frame_textures.append(self.alloc, tex) catch {
                    lib.DestroyTexture(tex); // cannot track — destroy now
                };
            }
        }
    }

    /// v34: destroy the per-frame textures AFTER RenderPresent. Called by
    /// Renderer.presentList once the frame is on screen.
    pub fn finishFrame(self: *DrawList, lib: *sdl.Sdl2) void {
        for (self.frame_textures.items) |t| {
            if (t) |tex| lib.DestroyTexture(tex);
        }
        self.frame_textures.clearRetainingCapacity();
    }

    fn sdlRect(r: Rect) sdl.Rect {
        return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    }

    /// The 640x480 logical canvas maps 1:1 (SDL_RenderSetLogicalSize
    /// handles device scaling + letterboxing).
    fn scaleRect(r: Rect) sdl.Rect {
        return .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    }

    fn tintRun(alloc: std.mem.Allocator, run: *const TextRun, r: u8, g: u8, b: u8) ![]u8 {
        const out = try alloc.dupe(u8, run.pixels);
        var i: usize = 0;
        while (i < out.len) : (i += 4) {
            out[i] = @intCast(@divTrunc(@as(u32, out[i]) * r + 127, 255));
            out[i + 1] = @intCast(@divTrunc(@as(u32, out[i + 1]) * g + 127, 255));
            out[i + 2] = @intCast(@divTrunc(@as(u32, out[i + 2]) * b + 127, 255));
        }
        return out;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

/// v33: throttled counter for skipped empty text runs — a run with
/// width/height 0 is silently invisible (the v32 title text bug class);
/// the first 10 skips get logged so the next device run can tell
/// "runs are empty at build time" from "runs are empty at draw time".
var text_runs_skipped_logged: u32 = 0;

test "draw list: construction + validation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dl = DrawList.init(a);
    defer dl.deinit();

    const px = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255 };
    const surf = Surface{ .width = 2, .height = 2, .pixels = &px };
    const s0 = dl.addSurface(&surf);

    dl.pushClear(255, 255, 255);
    dl.pushSprite(s0, .{ .x = 0, .y = 0, .w = 2, .h = 2 }, .{ .x = 10, .y = 10, .w = 100, .h = 50 }, 200);
    dl.pushSprite(s0, .{ .x = 1, .y = 0, .w = 1, .h = 2 }, .{ .x = 120, .y = 10, .w = 50, .h = 100 }, 255);

    const v = dl.validate();
    try testing.expectEqual(@as(usize, 3), v.op_count);
    try testing.expectEqual(@as(usize, 2), v.sprites);
    try testing.expectEqual(@as(usize, 1), v.clear_count);
    try testing.expectEqual(@as(usize, 0), v.errors);
    try testing.expectEqual(@as(i64, 5000 + 5000), v.sprite_area);
}

test "draw list: out-of-bounds src is reported" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var dl = DrawList.init(a);
    defer dl.deinit();
    const px = [_]u8{ 0, 0, 0, 0 };
    const surf = Surface{ .width = 1, .height = 1, .pixels = &px };
    const s0 = dl.addSurface(&surf);
    dl.pushSprite(s0, .{ .x = 0, .y = 0, .w = 5, .h = 1 }, .{ .x = 0, .y = 0, .w = 5, .h = 5 }, 255);
    const v = dl.validate();
    try testing.expectEqual(@as(usize, 1), v.errors);
}

test "draw list: surface metadata survives changes to the caller wrapper" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    const original_pixels = [_]u8{ 1, 2, 3, 255 };
    const replacement_pixels = [_]u8{ 4, 5, 6, 255 };
    var wrapper = Surface{ .width = 1, .height = 1, .pixels = &original_pixels };
    const handle = dl.addSurface(&wrapper);
    wrapper = .{ .width = 99, .height = 80, .pixels = &replacement_pixels };
    const registered = dl.surfaces.items[handle];
    try testing.expectEqual(@as(u32, 1), registered.width);
    try testing.expectEqual(@as(u32, 1), registered.height);
    try testing.expectEqual(original_pixels[0..].ptr, registered.pixels.ptr);
}

test "draw list: shared atlas wrappers reuse one frame handle without conflating shapes" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    const pixels = [_]u8{ 1, 2, 3, 255, 4, 5, 6, 255 };
    const first = Surface{ .width = 2, .height = 1, .pixels = &pixels };
    const second = Surface{ .width = 2, .height = 1, .pixels = &pixels };
    const reshaped = Surface{ .width = 1, .height = 2, .pixels = &pixels };
    const shared = dl.addSurface(&first);
    for (0..400) |_| try testing.expectEqual(shared, dl.addSurface(&second));
    try testing.expectEqual(@as(usize, 1), dl.surfaces.items.len);
    try testing.expect(dl.addSurface(&reshaped) != shared);
    dl.clear();
    try testing.expectEqual(@as(u32, 0), dl.addSurface(&second));
    try testing.expectEqual(@as(usize, 1), dl.surfaces.items.len);
}

test "draw list: text preserves bottom bars and descenders in the requested line height" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    var e = [_]u8{ 255, 255, 255, 255, 0, 0, 255, 255, 0, 255, 255, 255 };
    var g = [_]u8{ 100, 200, 255, 255, 0, 255, 100, 200, 255, 0, 0, 255, 255, 255, 100 };
    const glyphs = [_]DrawList.LaidGlyph{
        .{ .x = 0, .glyph = .{ .width = 3, .height = 4, .top = 3, .bearing_x = 0, .advance = 4, .coverage = &e } },
        .{ .x = 4, .glyph = .{ .width = 3, .height = 5, .top = 3, .bearing_x = 0, .advance = 4, .coverage = &g } },
    };
    const index = dl.addTextRun(&glyphs, 7, 6);
    const run = dl.runs.items[index];
    try testing.expectEqual(@as(u32, 6), run.height);
    // Both glyphs start at row 1. E's final bar survives on row 4;
    // g's two rows below the baseline survive through row 5.
    for (glyphs) |lg| {
        for (lg.glyph.coverage, 0..) |cov, i| {
            const x = @as(usize, @intCast(lg.x)) + i % 3;
            const y = 1 + i / 3;
            try testing.expectEqual(cov, run.pixels[(y * run.width + x) * 4 + 3]);
        }
    }
}

test "draw list: text extends a short line to fit a shared baseline" {
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    var upper = [_]u8{ 255, 100, 50, 25, 10 };
    var lower = [_]u8{ 200, 150, 100, 50 };
    const glyphs = [_]DrawList.LaidGlyph{
        .{ .x = 0, .glyph = .{ .width = 1, .height = 5, .top = 5, .bearing_x = 0, .advance = 1, .coverage = &upper } },
        .{ .x = 1, .glyph = .{ .width = 1, .height = 4, .top = 1, .bearing_x = 0, .advance = 1, .coverage = &lower } },
    };
    const index = dl.addTextRun(&glyphs, 2, 4);
    const run = dl.runs.items[index];
    try testing.expectEqual(@as(u32, 8), run.height);
    for (upper, 0..) |cov, y| try testing.expectEqual(cov, run.pixels[(y * 2) * 4 + 3]);
    for (lower, 0..) |cov, y| try testing.expectEqual(cov, run.pixels[((y + 4) * 2 + 1) * 4 + 3]);
}

const DrawTestSdl = struct {
    var trace: [16]u8 = undefined;
    var trace_len: usize = 0;

    fn record(op: u8) void {
        trace[trace_len] = op;
        trace_len += 1;
    }
    fn create(_: ?*anyopaque, _: u32, _: c_int, _: c_int, _: c_int) callconv(.c) ?*anyopaque {
        return @ptrFromInt(0x1000);
    }
    fn destroy(_: ?*anyopaque) callconv(.c) void {
        record('D');
    }
    fn color(_: ?*anyopaque, _: u8, _: u8, _: u8, _: u8) callconv(.c) c_int {
        return 0;
    }
    fn blend(_: ?*anyopaque, _: c_int) callconv(.c) c_int {
        return 0;
    }
    fn alpha(_: ?*anyopaque, _: u8) callconv(.c) c_int {
        return 0;
    }
    fn upload(_: ?*anyopaque, _: ?*const sdl.Rect, _: ?*const anyopaque, _: c_int) callconv(.c) c_int {
        return 0;
    }
    fn clear(_: ?*anyopaque) callconv(.c) c_int {
        record('C');
        return 0;
    }
    fn fill(_: ?*anyopaque, _: ?*const sdl.Rect) callconv(.c) c_int {
        record('F');
        return 0;
    }
    fn copy(_: ?*anyopaque, _: ?*anyopaque, _: ?*const sdl.Rect, _: ?*const sdl.Rect) callconv(.c) c_int {
        record('S');
        return 0;
    }
    fn present(_: ?*anyopaque) callconv(.c) void {
        record('P');
    }
    fn table() sdl.Sdl2 {
        var lib: sdl.Sdl2 = undefined;
        lib.CreateTexture = create;
        lib.DestroyTexture = destroy;
        lib.SetRenderDrawColor = color;
        lib.SetRenderDrawBlendMode = blend;
        lib.RenderClear = clear;
        lib.RenderFillRect = fill;
        lib.SetTextureBlendMode = blend;
        lib.SetTextureAlphaMod = alpha;
        lib.UpdateTexture = upload;
        lib.RenderCopy = copy;
        lib.RenderPresent = present;
        return lib;
    }
};

test "draw list: fade covers sprites and temporary textures survive until present" {
    DrawTestSdl.trace_len = 0;
    var lib = DrawTestSdl.table();
    var dl = DrawList.init(testing.allocator);
    defer dl.deinit();
    var sprites = TexCache{};
    var texts = TextTexCache{};
    const pixels = [_]u8{ 255, 255, 255, 255 };
    const surface = Surface{ .width = 1, .height = 1, .pixels = &pixels };
    const handle = dl.addSurface(&surface);
    dl.pushClear(255, 255, 255);
    dl.pushSprite(handle, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, 255);
    dl.pushFill(0, 0, 0, 128);
    const backend: *anyopaque = @ptrFromInt(0x2000);
    dl.render(&lib, backend, &sprites, &texts);
    try testing.expectEqualStrings("CSF", DrawTestSdl.trace[0..DrawTestSdl.trace_len]);
    try testing.expectEqual(@as(usize, 1), dl.frame_textures.items.len);
    lib.RenderPresent(backend);
    dl.finishFrame(&lib);
    try testing.expectEqualStrings("CSFPD", DrawTestSdl.trace[0..DrawTestSdl.trace_len]);
    try testing.expectEqual(@as(usize, 0), dl.frame_textures.items.len);
    dl.finishFrame(&lib);
    try testing.expectEqualStrings("CSFPD", DrawTestSdl.trace[0..DrawTestSdl.trace_len]);
}
