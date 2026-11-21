//! v28 — sprite loader: the one place where an image KEY becomes RGBA
//! pixels + a source rect, handling OMORI's Atlas system.
//!
//! Two paths (both used by the payload):
//!   * key in Atlas.yaml → load the atlas SHEET once (manager LRU caches
//!     the encoded bytes; this module caches the DECODED sheet pixels),
//!     return the entry's source rect inside the sheet,
//!   * key not in the atlas → load + decode the image directly.
//!
//! The decoded-pixel cache is bounded (budget, default 24 MiB) with
//! simple LRU eviction — sheets are shared by many sprites (940 atlas
//! entries over ~40 sheets), so caching decoded sheets is what makes
//! per-frame event rendering cheap.

const std = @import("std");
const log = @import("../core/log.zig");
const atlas_mod = @import("../assets/atlas.zig");
const manager_mod = @import("../assets/manager.zig");
const image_codec = @import("../codec/image.zig");
const draw_mod = @import("../renderer/draw.zig");

pub const Sprite = struct {
    /// Draw-list surface handle (assigned by the first user of the frame).
    handle: u32 = 0,
    width: i32 = 0,
    height: i32 = 0,
    /// Source rect (inside the shared sheet, or the whole image).
    src: draw_mod.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
};

test "sprite loader: atlas lookup keeps its resolved key alive" {
    const a = std.testing.allocator;
    const entries = [_]atlas_mod.AtlasEntry{.{
        .key = "img/pictures/test.png",
        .atlas_name = "Shared",
        .rect = .{ .width = 1, .height = 1 },
        .source_rect = .{ .x = 1, .width = 1, .height = 1 },
    }};
    var atlas = atlas_mod.AtlasData{ .entries = &entries, .index = std.StringHashMap(usize).init(a) };
    defer atlas.index.deinit();
    try atlas.index.put(entries[0].key, 0);
    var loader = Loader.init(a, undefined, &atlas);
    defer loader.deinit();
    const pixels = try a.dupe(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 255 });
    const key = try a.dupe(u8, "img/atlases/Shared.png");
    try loader.cache.put(key, .{
        .pixels = pixels,
        .width = 2,
        .height = 1,
        .surface = .{ .width = 2, .height = 1, .pixels = pixels },
        .last_use = 0,
        .bytes = pixels.len,
    });
    loader.used_bytes = pixels.len;
    var dl = draw_mod.DrawList.init(a);
    defer dl.deinit();
    const sprite = loader.get(&dl, entries[0].key) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(i32, 1), sprite.src.x);
    try std.testing.expectEqual(@as(i32, 1), sprite.width);
    try std.testing.expectEqualSlices(u8, pixels, dl.surfaces.items[sprite.handle].pixels);
    try std.testing.expectEqual(@as(usize, 0), loader.decode_count);
}

test "sprite loader: queued pixels survive budget pressure until next frame" {
    const a = std.testing.allocator;
    var atlas = atlas_mod.AtlasData{ .entries = &.{}, .index = std.StringHashMap(usize).init(a) };
    defer atlas.index.deinit();
    var loader = Loader.init(a, undefined, &atlas);
    defer loader.deinit();
    loader.budget_bytes = 4;
    for ([_][]const u8{ "first", "second" }, 0..) |key_name, i| {
        const pixels = try a.dupe(u8, &.{ @intCast(i + 1), 0, 0, 255 });
        const key = try a.dupe(u8, key_name);
        try loader.cache.put(key, .{
            .pixels = pixels,
            .width = 1,
            .height = 1,
            .surface = .{ .width = 1, .height = 1, .pixels = pixels },
            .last_use = 0,
            .frame_used = loader.frame,
            .bytes = pixels.len,
        });
        loader.used_bytes += pixels.len;
    }
    var dl = draw_mod.DrawList.init(a);
    defer dl.deinit();
    const first = loader.get(&dl, "first") orelse return error.TestUnexpectedResult;
    const second = loader.get(&dl, "second") orelse return error.TestUnexpectedResult;
    loader.evictIfNeeded();
    try std.testing.expectEqual(@as(usize, 8), loader.used_bytes);
    try std.testing.expectEqual(@as(u8, 1), dl.surfaces.items[first.handle].pixels[0]);
    try std.testing.expectEqual(@as(u8, 2), dl.surfaces.items[second.handle].pixels[0]);
    dl.clear(); // frame is complete; no borrowed pixels remain queued
    loader.beginFrame();
    try std.testing.expectEqual(@as(usize, 4), loader.used_bytes);
    try std.testing.expectEqual(@as(u32, 1), loader.cache.count());
}

const CacheEntry = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    surface: draw_mod.Surface,
    /// LRU stamp (bumped on use).
    last_use: u64,
    /// Pixels referenced by this frame's draw list cannot be evicted.
    frame_used: u64 = 0,
    bytes: usize,
};

pub const Loader = struct {
    alloc: std.mem.Allocator,
    assets: *manager_mod.Manager,
    atlas: *atlas_mod.AtlasData,
    cache: std.StringHashMap(CacheEntry),
    /// Decoded-byte budget for the pixel cache.
    budget_bytes: usize = 24 * 1024 * 1024,
    used_bytes: usize = 0,
    clock: u64 = 0,
    decode_count: usize = 0,
    frame: u64 = 1,
    /// v36 (B3): fired whenever an eviction frees decoded pixels. The
    /// GPU texture cache keys on the pixel base pointer — a recycled
    /// address must never alias a stale texture, so the game loop
    /// flushes the renderer texture cache here.
    on_evict: ?*const fn (ctx: ?*anyopaque, bytes: usize) void = null,
    evict_ctx: ?*anyopaque = null,

    pub fn init(alloc: std.mem.Allocator, assets: *manager_mod.Manager, atlas: *atlas_mod.AtlasData) Loader {
        return .{
            .alloc = alloc,
            .assets = assets,
            .atlas = atlas,
            .cache = std.StringHashMap(CacheEntry).init(alloc),
        };
    }

    pub fn deinit(self: *Loader) void {
        var it = self.cache.iterator();
        while (it.next()) |kv| {
            self.alloc.free(kv.value_ptr.pixels);
            self.alloc.free(kv.key_ptr.*);
        }
        self.cache.deinit();
    }

    /// Called after the previous frame has finished rendering. A working
    /// set larger than the budget is retained until this boundary so a
    /// queued sprite never reads freed pixels.
    pub fn beginFrame(self: *Loader) void {
        self.frame += 1;
        self.evictIfNeeded();
    }

    /// Resolve a key into a sprite (surface registered into the frame's
    /// draw list + source rect). Returns null when the image cannot be
    /// loaded/decoded (logged; the caller skips the sprite).
    pub fn get(self: *Loader, dl: *draw_mod.DrawList, key: []const u8) ?Sprite {
        self.clock += 1;

        // Atlas redirect: sheet key + source rect.
        var real_key = key;
        var owned_key: ?[]u8 = null;
        defer if (owned_key) |k| self.alloc.free(k);
        var src = draw_mod.Rect{ .x = 0, .y = 0, .w = 0, .h = 0 };
        if (self.atlas.atlasNameOf(key)) |sheet| {
            const e = self.atlas.entry(key) orelse return null;
            // build the sheet path exactly like Atlas.yaml says
            const sheet_path = std.fmt.allocPrint(self.alloc, "img/atlases/{s}.png", .{sheet}) catch return null;
            owned_key = sheet_path;
            real_key = sheet_path;
            src = .{
                .x = e.source_rect.x,
                .y = e.source_rect.y,
                .w = e.source_rect.width,
                .h = e.source_rect.height,
            };
        }

        // decoded-sheet cache
        var entry: *CacheEntry = blk: {
            if (self.cache.getPtr(real_key)) |c| {
                c.last_use = self.clock;
                c.frame_used = self.frame;
                break :blk c;
            }
            const loaded = self.loadAndDecode(real_key) orelse return null;
            self.cache.put(loaded.key, loaded.entry) catch {
                self.alloc.free(loaded.entry.pixels);
                self.alloc.free(loaded.key);
                return null;
            };
            self.used_bytes += loaded.entry.bytes;
            break :blk self.cache.getPtr(real_key).?;
        };

        // DrawList copies the surface metadata. The loader pins its
        // borrowed pixels through the rest of this frame.
        entry.surface.pixels = entry.pixels;
        const handle = dl.addSurface(&entry.surface);
        if (src.w == 0) {
            src = .{ .x = 0, .y = 0, .w = @intCast(entry.width), .h = @intCast(entry.height) };
        }
        self.evictIfNeeded();
        return .{ .handle = handle, .width = src.w, .height = src.h, .src = src };
    }

    const Loaded = struct { key: []u8, entry: CacheEntry };

    fn loadAndDecode(self: *Loader, key: []const u8) ?Loaded {
        const snap = self.assets.load(key) catch |e| {
            log.event(.res, .warn, "sprite '{s}' not loadable ({any}) — skipped", .{ key, e });
            return null;
        };
        const img = image_codec.decode(self.alloc, snap.encoded) catch |e| {
            // Some non-atlas images may be real PNG (e.g. system
            // windows). Report malformed or unsupported image data.
            log.event(.res, .warn, "sprite '{s}' decode failed ({any})", .{ key, e });
            return null;
        };
        self.decode_count += 1;

        const key_copy = self.alloc.dupe(u8, key) catch {
            self.alloc.free(img.pixels);
            return null;
        };
        const entry = CacheEntry{
            .pixels = img.pixels,
            .width = img.width,
            .height = img.height,
            .surface = .{ .width = img.width, .height = img.height, .pixels = img.pixels },
            .last_use = self.clock,
            .frame_used = self.frame,
            .bytes = img.pixels.len,
        };
        return .{ .key = key_copy, .entry = entry };
    }

    fn evictIfNeeded(self: *Loader) void {
        if (self.used_bytes <= self.budget_bytes) return;
        // evict least-recently-used entries until under budget
        while (self.used_bytes > self.budget_bytes and self.cache.count() > 0) {
            var oldest_key: ?[]const u8 = null;
            var oldest_use: u64 = std.math.maxInt(u64);
            var oldest_bytes: usize = 0;
            var it = self.cache.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.frame_used == self.frame) continue;
                if (kv.value_ptr.last_use < oldest_use) {
                    oldest_use = kv.value_ptr.last_use;
                    oldest_key = kv.key_ptr.*;
                    oldest_bytes = kv.value_ptr.bytes;
                }
            }
            if (oldest_key) |k| {
                if (self.cache.fetchRemove(k)) |kv| {
                    self.alloc.free(kv.value.pixels);
                    self.alloc.free(kv.key);
                    self.used_bytes -= oldest_bytes;
                    // v36 (B3): stale GPU textures keyed on the freed
                    // pointer must go (see on_evict).
                    if (self.on_evict) |cb| cb(self.evict_ctx, oldest_bytes);
                }
            } else break;
        }
    }

    pub fn stats(self: *const Loader) struct { entries: usize, decoded: usize, used_mib: f32 } {
        return .{
            .entries = self.cache.count(),
            .decoded = self.decode_count,
            .used_mib = @as(f32, @floatFromInt(self.used_bytes)) / (1024.0 * 1024.0),
        };
    }
};
