//! Minimal TrueType glyph rasterizer for the runtime's text rendering.
//!
//! Scope: exactly what OMORI's title/menu text needs — the payload's
//! GameFont (`fonts/OMORI_GAME2.ttf`, verified: glyf outlines, 105
//! mapped glyphs covering A-Z/0-9, unitsPerEm 1024). Implements:
//!   * table directory + head/cmap(format 4)/maxp/loca/hmtx/hhea parsing
//!   * simple glyf contours (flags, deltas, quadratic beziers) and
//!     composite glyphs (component transforms, bounded recursion)
//!   * bezier flattening → scanline fill with nonzero winding
//!   * 8-bit alpha coverage bitmap per glyph + advance metrics,
//!     cached per (glyph, size)
//!   * bounded missing-é/É composition from the font's own letter/grave ink
//!
//! Not implemented (documented honestly): hinting instructions (the
//! payload font ships none), OpenType shaping, bitmap strikes.

const std = @import("std");
const log = @import("../core/log.zig");

pub const FontError = error{
    OutOfMemory,
    NotTrueType,
    MissingTable,
    BadTable,
};

/// A rasterized glyph: 8-bit coverage; row 0 is the TOP row.
pub const Glyph = struct {
    width: u32,
    height: u32,
    /// distance from pen to glyph left edge (pixels).
    bearing_x: i32,
    /// rows from the TOP row down to the baseline.
    top: i32,
    /// horizontal advance (pixels).
    advance: i32,
    coverage: []u8, // width * height, row-major

    pub fn deinit(self: *Glyph, alloc: std.mem.Allocator) void {
        if (self.coverage.len > 0) alloc.free(self.coverage);
    }
};

const Point = struct { x: f64, y: f64, on_curve: bool };
const Edge = struct { x0: f64, y0: f64, x1: f64, y1: f64 };
// Reserved only for small fonts lacking these codepoints. The original
// GameFont supplies the e/E and grave ink used to compose the acute.
const e_acute_glyph: u16 = 0xfffe;
const E_acute_glyph: u16 = 0xfffd;

pub const Font = struct {
    alloc: std.mem.Allocator,
    data: []const u8, // the whole TTF (borrowed)
    upem: u16,
    num_glyphs: u16,
    index_to_loc_long: bool,
    num_hmetrics: u16,
    cmap_offset: u32 = 0,
    cmap_len: u32 = 0,
    glyf_offset: u32 = 0,
    loca_offset: u32 = 0,
    hmtx_offset: u32 = 0,
    kern_offset: u32 = 0,
    kern_len: u32 = 0,
    /// glyph cache: (glyph_id << 24 | size) → Glyph (owned).
    cache: std.AutoHashMap(u64, Glyph),

    pub fn init(alloc: std.mem.Allocator, data: []const u8) FontError!Font {
        if (data.len < 12) return FontError.NotTrueType;
        const version = std.mem.readInt(u32, data[0..4], .big);
        if (version != 0x00010000) return FontError.NotTrueType;
        const num_tables = std.mem.readInt(u16, data[4..6], .big);

        var font = Font{
            .alloc = alloc,
            .data = data,
            .upem = 1000,
            .num_glyphs = 0,
            .index_to_loc_long = false,
            .num_hmetrics = 0,
            .cache = std.AutoHashMap(u64, Glyph).init(alloc),
        };

        var ti: usize = 0;
        while (ti < num_tables) : (ti += 1) {
            const base = 12 + ti * 16;
            if (base + 16 > data.len) return FontError.BadTable;
            const tag = data[base .. base + 4];
            const off = std.mem.readInt(u32, data[base + 8 ..][0..4], .big);
            const len = std.mem.readInt(u32, data[base + 12 ..][0..4], .big);
            if (off + len > data.len) return FontError.BadTable;
            if (std.mem.eql(u8, tag, "head")) {
                if (len < 54) return FontError.BadTable;
                font.upem = std.mem.readInt(u16, data[off + 18 ..][0..2], .big);
                // OpenType head.indexToLocFormat is a BE int16: long
                // offsets are encoded 00 01, not a nonzero first byte.
                // https://learn.microsoft.com/en-us/typography/opentype/spec/head
                font.index_to_loc_long = switch (std.mem.readInt(i16, data[off + 50 ..][0..2], .big)) {
                    0 => false,
                    1 => true,
                    else => return FontError.BadTable,
                };
            } else if (std.mem.eql(u8, tag, "cmap")) {
                font.cmap_offset = off;
                font.cmap_len = len;
            } else if (std.mem.eql(u8, tag, "glyf")) {
                font.glyf_offset = off;
            } else if (std.mem.eql(u8, tag, "loca")) {
                font.loca_offset = off;
            } else if (std.mem.eql(u8, tag, "hmtx")) {
                font.hmtx_offset = off;
            } else if (std.mem.eql(u8, tag, "maxp")) {
                if (len < 6) return FontError.BadTable;
                font.num_glyphs = std.mem.readInt(u16, data[off + 4 ..][0..2], .big);
            } else if (std.mem.eql(u8, tag, "hhea")) {
                if (len < 36) return FontError.BadTable;
                font.num_hmetrics = std.mem.readInt(u16, data[off + 34 ..][0..2], .big);
            } else if (std.mem.eql(u8, tag, "kern")) {
                font.kern_offset = off;
                font.kern_len = len;
            }
        }
        if (font.glyf_offset == 0 or font.loca_offset == 0 or font.cmap_offset == 0 or font.num_glyphs == 0) {
            return FontError.MissingTable;
        }
        return font;
    }

    pub fn deinit(self: *Font) void {
        var it = self.cache.iterator();
        while (it.next()) |e| {
            var g = e.value_ptr.*;
            g.deinit(self.alloc);
        }
        self.cache.deinit();
    }

    /// Unicode → glyph id. Missing é/É can use an in-font composite;
    /// existing cmap glyphs always take precedence.
    pub fn glyphId(self: *const Font, code: u21) u16 {
        const mapped = self.cmapGlyphId(code);
        if (mapped != 0 or self.num_glyphs >= E_acute_glyph) return mapped;
        const base: u21 = switch (code) {
            0x00e9 => 'e',
            0x00c9 => 'E',
            else => return 0,
        };
        if (self.cmapGlyphId(base) == 0 or self.cmapGlyphId('`') == 0) return 0;
        return if (code == 0x00e9) e_acute_glyph else E_acute_glyph;
    }

    /// Direct cmap lookup, without virtual glyphs.
    fn cmapGlyphId(self: *const Font, code: u21) u16 {
        const cmap = self.data[self.cmap_offset..][0..@intCast(self.cmap_len)];
        if (cmap.len < 4) return 0;
        const num_sub = std.mem.readInt(u16, cmap[2..4], .big);
        var i: usize = 0;
        while (i < num_sub) : (i += 1) {
            const rec = cmap[4 + i * 8 ..][0..8];
            const platform = std.mem.readInt(u16, rec[0..2], .big);
            const encoding = std.mem.readInt(u16, rec[2..4], .big);
            const off = std.mem.readInt(u32, rec[4..8], .big);
            if (off >= cmap.len) continue;
            const sub = cmap[off..];
            if (sub.len < 2) continue;
            const fmt = std.mem.readInt(u16, sub[0..2], .big);
            const is_unicode = (platform == 3 and (encoding == 1 or encoding == 10)) or platform == 0;
            if (!is_unicode) continue;
            switch (fmt) {
                4 => return cmapFmt4(sub, code),
                12 => return cmapFmt12(sub, code),
                0 => if (code < 256 and sub.len > 6 + code) return sub[6 + code],
                else => {},
            }
        }
        return 0;
    }

    fn cmapFmt4(sub: []const u8, code: u21) u16 {
        if (sub.len < 14) return 0;
        const seg_count_x2 = std.mem.readInt(u16, sub[6..8], .big);
        if (seg_count_x2 == 0 or (seg_count_x2 & 1) != 0) return 0;
        const seg_count: usize = seg_count_x2 / 2;
        if (14 + seg_count_x2 * 4 > sub.len) return 0;
        const end_base = 14;
        const start_base = 14 + seg_count_x2 + 2;
        const delta_base = start_base + seg_count_x2;
        const range_base = delta_base + seg_count_x2;
        var seg: usize = 0;
        while (seg < seg_count) : (seg += 1) {
            const end_code = std.mem.readInt(u16, sub[end_base + seg * 2 ..][0..2], .big);
            if (code > end_code) continue;
            const start_code = std.mem.readInt(u16, sub[start_base + seg * 2 ..][0..2], .big);
            if (code < start_code) return 0;
            const id_delta = std.mem.readInt(i16, sub[delta_base + seg * 2 ..][0..2], .big);
            const range_pos = range_base + seg * 2;
            const id_range_off = std.mem.readInt(u16, sub[range_pos..][0..2], .big);
            if (id_range_off == 0) {
                return @truncate(@as(u32, code) +% @as(u32, @bitCast(@as(i32, id_delta))));
            }
            const glyph_pos = range_pos + id_range_off + (code - start_code) * 2;
            if (glyph_pos + 2 > sub.len) return 0;
            const g = std.mem.readInt(u16, sub[glyph_pos..][0..2], .big);
            if (g == 0) return 0;
            return @truncate(@as(u32, g) +% @as(u32, @bitCast(@as(i32, id_delta))));
        }
        return 0;
    }

    fn cmapFmt12(sub: []const u8, code: u21) u16 {
        if (sub.len < 16) return 0;
        const num_groups = std.mem.readInt(u32, sub[12..16], .big);
        var g: usize = 0;
        while (g < num_groups) : (g += 1) {
            const base = 16 + g * 12;
            if (base + 12 > sub.len) return 0;
            const start = std.mem.readInt(u32, sub[base..][0..4], .big);
            const end = std.mem.readInt(u32, sub[base + 4 ..][0..4], .big);
            const start_gid = std.mem.readInt(u32, sub[base + 8 ..][0..4], .big);
            if (code >= start and code <= end) {
                return @truncate(start_gid + (code - start));
            }
        }
        return 0;
    }

    fn advanceUnits(self: *const Font, glyph_id: u16) u16 {
        const physical = self.physicalGlyphId(glyph_id);
        const d = self.data;
        if (physical < self.num_hmetrics) {
            const off = self.hmtx_offset + @as(u32, physical) * 4;
            if (off + 2 <= d.len) return std.mem.readInt(u16, d[off..][0..2], .big);
        }
        if (self.num_hmetrics > 0) {
            const off = self.hmtx_offset + (@as(u32, self.num_hmetrics) - 1) * 4;
            if (off + 2 <= d.len) return std.mem.readInt(u16, d[off..][0..2], .big);
        }
        return 0;
    }

    /// kerning between glyphs (font units), format-0 subtable.
    pub fn kernUnits(self: *const Font, left: u16, right: u16) i16 {
        if (self.kern_offset == 0) return 0;
        const kern = self.data[self.kern_offset..][0..@intCast(self.kern_len)];
        if (kern.len < 4) return 0;
        const num_sub = std.mem.readInt(u16, kern[2..4], .big);
        var i: usize = 0;
        while (i < num_sub) : (i += 1) {
            const sub_base = 4 + i * 6;
            if (sub_base + 6 > kern.len) return 0;
            const coverage = std.mem.readInt(u16, kern[sub_base + 4 ..][0..2], .big);
            if ((coverage >> 8) != 0) continue; // format 0 only
            const sub = kern[sub_base + 6 ..];
            if (sub.len < 8) continue;
            const n_pairs = std.mem.readInt(u16, sub[0..2], .big);
            var lo: usize = 0;
            var hi: usize = n_pairs;
            while (lo < hi) {
                const mid = (lo + hi) / 2;
                const pair_off = 8 + mid * 6;
                if (pair_off + 6 > sub.len) return 0;
                const key = std.mem.readInt(u32, sub[pair_off..][0..4], .big);
                const want = (@as(u32, self.physicalGlyphId(left)) << 16) | self.physicalGlyphId(right);
                if (key == want) return std.mem.readInt(i16, sub[pair_off + 4 ..][0..2], .big);
                if (key < want) lo = mid + 1 else hi = mid;
            }
        }
        return 0;
    }

    pub fn scale(self: *const Font, size_px: u32) f64 {
        return @as(f64, @floatFromInt(size_px)) / @as(f64, @floatFromInt(self.upem));
    }

    fn physicalGlyphId(self: *const Font, glyph_id: u16) u16 {
        if (self.num_glyphs < E_acute_glyph) switch (glyph_id) {
            e_acute_glyph => return self.cmapGlyphId('e'),
            E_acute_glyph => return self.cmapGlyphId('E'),
            else => {},
        };
        return glyph_id;
    }

    /// Rasterize a glyph at `size_px` (em height in pixels). Cached.
    pub fn rasterize(self: *Font, glyph_id: u16, size_px: u32) FontError!*const Glyph {
        const key = (@as(u64, glyph_id) << 24) | size_px;
        if (self.cache.getPtr(key)) |g| return g;
        const g = try self.rasterizeUncached(glyph_id, size_px);
        self.cache.put(key, g) catch {
            var g2 = g;
            g2.deinit(self.alloc);
            return FontError.OutOfMemory;
        };
        return self.cache.getPtr(key).?;
    }

    fn rasterizeUncached(self: *Font, glyph_id: u16, size_px: u32) FontError!Glyph {
        const physical = self.physicalGlyphId(glyph_id);
        if (physical != glyph_id) {
            // Copy cache entries by value before another insertion can
            // rehash the map. Their coverage allocations stay stable.
            const base = (try self.rasterize(physical, size_px)).*;
            const grave = (try self.rasterize(self.cmapGlyphId('`'), size_px)).*;
            return composeAcute(self.alloc, base, grave, size_px);
        }
        var points: std.ArrayList(Point) = .empty;
        defer points.deinit(self.alloc);
        var contours: std.ArrayList(usize) = .empty; // end-point index per contour
        defer contours.deinit(self.alloc);

        try self.collectOutline(glyph_id, &points, &contours, 0);

        const sc = self.scale(size_px);
        const adv: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(self.advanceUnits(glyph_id))) * sc));

        if (points.items.len == 0 or contours.items.len == 0) {
            return .{ .width = 0, .height = 0, .bearing_x = 0, .top = 0, .advance = adv, .coverage = &.{} };
        }

        // Pixel space: y flipped (baseline = 0, up = negative pixel rows).
        var min_x: f64 = std.math.floatMax(f64);
        var max_x: f64 = -std.math.floatMax(f64);
        var min_y: f64 = std.math.floatMax(f64);
        var max_y: f64 = -std.math.floatMax(f64);
        for (points.items) |p| {
            const x = p.x * sc;
            const y = -p.y * sc;
            min_x = @min(min_x, x);
            max_x = @max(max_x, x);
            min_y = @min(min_y, y);
            max_y = @max(max_y, y);
        }

        const pad = 1.0;
        const x0 = @floor(min_x - pad);
        const y0 = @floor(min_y - pad); // top edge
        const w_f = max_x - min_x + 2 * pad;
        const h_f = max_y - min_y + 2 * pad;
        const width: u32 = @intFromFloat(@ceil(w_f));
        const height: u32 = @intFromFloat(@ceil(h_f));
        if (width == 0 or height == 0 or width > 4096 or height > 4096) {
            return .{ .width = 0, .height = 0, .bearing_x = 0, .top = 0, .advance = adv, .coverage = &.{} };
        }

        var edges: std.ArrayList(Edge) = .empty;
        defer edges.deinit(self.alloc);
        var contour_start: usize = 0;
        for (contours.items) |contour_end| {
            if (contour_end >= contour_start) {
                try flattenContour(self.alloc, &edges, points.items[contour_start .. contour_end + 1], sc, x0, y0);
            }
            contour_start = contour_end + 1;
        }

        const coverage = try self.alloc.alloc(u8, @as(usize, width) * height);
        errdefer self.alloc.free(coverage);
        @memset(coverage, 0);

        // scanline fill (nonzero winding)
        var row: u32 = 0;
        while (row < height) : (row += 1) {
            const sy = @as(f64, @floatFromInt(row)) + 0.5;
            var crossings: [64]f64 = undefined;
            var winds: [64]i16 = undefined;
            var nc: usize = 0;
            for (edges.items) |e| {
                const y_lo = @min(e.y0, e.y1);
                const y_hi = @max(e.y0, e.y1);
                if (sy >= y_lo and sy < y_hi and nc < crossings.len) {
                    const t = (sy - e.y0) / (e.y1 - e.y0);
                    crossings[nc] = e.x0 + t * (e.x1 - e.x0);
                    winds[nc] = if (e.y1 > e.y0) 1 else -1;
                    nc += 1;
                }
            }
            if (nc == 0) continue;
            // sort by x (insertion sort; nc is small)
            var a: usize = 1;
            while (a < nc) : (a += 1) {
                const xv = crossings[a];
                const wv = winds[a];
                var b = a;
                while (b > 0 and crossings[b - 1] > xv) : (b -= 1) {
                    crossings[b] = crossings[b - 1];
                    winds[b] = winds[b - 1];
                }
                crossings[b] = xv;
                winds[b] = wv;
            }
            // fill spans where winding != 0, with horizontal AA at edges
            var acc: i32 = 0;
            var span_left: f64 = 0;
            var k: usize = 0;
            while (k < nc) : (k += 1) {
                const prev_acc = acc;
                acc += winds[k];
                if (prev_acc == 0 and acc != 0) {
                    span_left = crossings[k];
                } else if (prev_acc != 0 and acc == 0) {
                    const span_right = crossings[k];
                    const l = @max(span_left, 0.0);
                    const r = @min(span_right, @as(f64, @floatFromInt(width)));
                    if (r > l) {
                        var xi: u32 = @intFromFloat(@floor(l));
                        while (@as(f64, @floatFromInt(xi)) < r and xi < width) : (xi += 1) {
                            const cov = @min(@as(f64, @floatFromInt(xi + 1)), r) - @max(@as(f64, @floatFromInt(xi)), l);
                            const idx = row * width + xi;
                            const v: u32 = @as(u32, coverage[idx]) + @as(u32, @intFromFloat(cov * 255.0));
                            coverage[idx] = @intCast(@min(v, 255));
                        }
                    }
                }
            }
        }

        const bearing_x: i32 = @intFromFloat(x0);
        const top: i32 = @intFromFloat(-y0); // baseline-to-top distance

        return .{
            .width = width,
            .height = height,
            .bearing_x = bearing_x,
            .top = top,
            .advance = adv,
            .coverage = coverage,
        };
    }

    /// Extract a glyph outline (font units), composites expanded.
    fn collectOutline(self: *Font, glyph_id: u16, points: *std.ArrayList(Point), contours: *std.ArrayList(usize), depth: u5) FontError!void {
        if (depth > 4) return;
        const d = self.data;
        const glyph_start: u32 = blk: {
            if (self.index_to_loc_long) {
                const off = self.loca_offset + @as(u32, glyph_id) * 4;
                if (off + 4 > d.len) return FontError.BadTable;
                break :blk std.mem.readInt(u32, d[off..][0..4], .big);
            } else {
                const off = self.loca_offset + @as(u32, glyph_id) * 2;
                if (off + 2 > d.len) return FontError.BadTable;
                break :blk @as(u32, std.mem.readInt(u16, d[off..][0..2], .big)) * 2;
            }
        };
        const glyph_end: u32 = blk: {
            if (self.index_to_loc_long) {
                const off = self.loca_offset + @as(u32, glyph_id + 1) * 4;
                if (off + 4 > d.len) return FontError.BadTable;
                break :blk std.mem.readInt(u32, d[off..][0..4], .big);
            } else {
                const off = self.loca_offset + @as(u32, glyph_id + 1) * 2;
                if (off + 2 > d.len) return FontError.BadTable;
                break :blk @as(u32, std.mem.readInt(u16, d[off..][0..2], .big)) * 2;
            }
        };
        if (glyph_start >= glyph_end or self.glyf_offset + glyph_end > d.len) return;
        const g = d[self.glyf_offset + glyph_start .. self.glyf_offset + glyph_end];
        if (g.len < 10) return;

        const num_contours = std.mem.readInt(i16, g[0..2], .big);
        if (num_contours > 0) {
            const n: usize = @intCast(num_contours);
            if (10 + n * 2 + 2 > g.len) return FontError.BadTable;
            var num_points: usize = 0;
            var ci: usize = 0;
            while (ci < n) : (ci += 1) {
                const ep = std.mem.readInt(u16, g[10 + ci * 2 ..][0..2], .big);
                if (ep + 1 > num_points) num_points = ep + 1;
            }
            const instr_len = std.mem.readInt(u16, g[10 + n * 2 ..][0..2], .big);
            var pos: usize = 10 + n * 2 + 2 + instr_len;

            // flags (with repeat)
            var flags: std.ArrayList(u8) = .empty;
            defer flags.deinit(self.alloc);
            while (flags.items.len < num_points) {
                if (pos >= g.len) return FontError.BadTable;
                const fl = g[pos];
                pos += 1;
                flags.append(self.alloc, fl) catch return FontError.OutOfMemory;
                if (fl & 0x08 != 0) {
                    if (pos >= g.len) return FontError.BadTable;
                    const rep = g[pos];
                    pos += 1;
                    var r: usize = 0;
                    while (r < rep and flags.items.len < num_points) : (r += 1) {
                        flags.append(self.alloc, fl) catch return FontError.OutOfMemory;
                    }
                }
            }
            // x deltas
            const xs = self.alloc.alloc(i32, num_points) catch return FontError.OutOfMemory;
            defer self.alloc.free(xs);
            var x: i32 = 0;
            var pi: usize = 0;
            while (pi < num_points) : (pi += 1) {
                const fl = flags.items[pi];
                if (fl & 0x02 != 0) {
                    if (pos >= g.len) return FontError.BadTable;
                    // Short coordinates store an UNSIGNED magnitude;
                    // the flag carries its sign (OpenType glyf spec).
                    const v: i32 = g[pos];
                    pos += 1;
                    x += if (fl & 0x10 != 0) v else -v;
                } else if (fl & 0x10 == 0) {
                    if (pos + 2 > g.len) return FontError.BadTable;
                    x += std.mem.readInt(i16, g[pos..][0..2], .big);
                    pos += 2;
                }
                xs[pi] = x;
            }
            // y deltas
            const ys = self.alloc.alloc(i32, num_points) catch return FontError.OutOfMemory;
            defer self.alloc.free(ys);
            var y: i32 = 0;
            pi = 0;
            while (pi < num_points) : (pi += 1) {
                const fl = flags.items[pi];
                if (fl & 0x04 != 0) {
                    if (pos >= g.len) return FontError.BadTable;
                    const v: i32 = g[pos];
                    pos += 1;
                    y += if (fl & 0x20 != 0) v else -v;
                } else if (fl & 0x20 == 0) {
                    if (pos + 2 > g.len) return FontError.BadTable;
                    y += std.mem.readInt(i16, g[pos..][0..2], .big);
                    pos += 2;
                }
                ys[pi] = y;
            }
            // append points + contour end indices
            const base = points.items.len;
            pi = 0;
            while (pi < num_points) : (pi += 1) {
                points.append(self.alloc, .{
                    .x = @floatFromInt(xs[pi]),
                    .y = @floatFromInt(ys[pi]),
                    .on_curve = flags.items[pi] & 0x01 != 0,
                }) catch return FontError.OutOfMemory;
            }
            ci = 0;
            while (ci < n) : (ci += 1) {
                const ep = std.mem.readInt(u16, g[10 + ci * 2 ..][0..2], .big);
                contours.append(self.alloc, base + ep) catch return FontError.OutOfMemory;
            }
        } else if (num_contours < 0) {
            // composite glyph
            var pos: usize = 10;
            while (pos + 4 <= g.len) {
                const flags16 = std.mem.readInt(u16, g[pos..][0..2], .big);
                const gid = std.mem.readInt(u16, g[pos + 2 ..][0..2], .big);
                pos += 4;
                var a: f64 = 1.0;
                var b: f64 = 0.0;
                var c: f64 = 0.0;
                var dd: f64 = 1.0;
                var e: f64 = 0.0;
                var f: f64 = 0.0;
                var arg1: i32 = 0;
                var arg2: i32 = 0;
                if (flags16 & 0x0001 != 0) {
                    if (pos + 4 > g.len) return FontError.BadTable;
                    arg1 = std.mem.readInt(i16, g[pos..][0..2], .big);
                    arg2 = std.mem.readInt(i16, g[pos + 2 ..][0..2], .big);
                    pos += 4;
                } else {
                    if (pos + 2 > g.len) return FontError.BadTable;
                    arg1 = @as(i8, @bitCast(g[pos]));
                    arg2 = @as(i8, @bitCast(g[pos + 1]));
                    pos += 2;
                }
                if (flags16 & 0x0002 != 0) {
                    // ARGS_ARE_XY_VALUES: offsets
                    e = @floatFromInt(arg1);
                    f = @floatFromInt(arg2);
                    if (flags16 & 0x0008 != 0) { // WE_HAVE_A_SCALE
                        a = @as(f64, @floatFromInt(arg1)) / 16384.0;
                        dd = a;
                    } else if (flags16 & 0x0040 != 0) { // XY scale
                        a = @as(f64, @floatFromInt(arg1)) / 16384.0;
                        dd = @as(f64, @floatFromInt(arg2)) / 16384.0;
                    } else if (flags16 & 0x0080 != 0) { // 2x2: 4 more words
                        if (pos + 8 > g.len) return FontError.BadTable;
                        a = @as(f64, @floatFromInt(std.mem.readInt(i16, g[pos..][0..2], .big))) / 16384.0;
                        b = @as(f64, @floatFromInt(std.mem.readInt(i16, g[pos + 2 ..][0..2], .big))) / 16384.0;
                        c = @as(f64, @floatFromInt(std.mem.readInt(i16, g[pos + 4 ..][0..2], .big))) / 16384.0;
                        dd = @as(f64, @floatFromInt(std.mem.readInt(i16, g[pos + 6 ..][0..2], .big))) / 16384.0;
                        pos += 8;
                    }
                }
                const base = points.items.len;
                try self.collectOutline(gid, points, contours, depth + 1);
                var idx = base;
                while (idx < points.items.len) : (idx += 1) {
                    const px = points.items[idx].x;
                    const py = points.items[idx].y;
                    points.items[idx].x = a * px + c * py + e;
                    points.items[idx].y = b * px + dd * py + f;
                }
                if (flags16 & 0x0020 == 0) break; // no MORE_COMPONENTS
            }
        }
    }

    /// Flatten one closed contour (font units) into pixel-space edges,
    /// resolving implied on-curve points and quadratic beziers.
    fn flattenContour(alloc: std.mem.Allocator, edges: *std.ArrayList(Edge), pts: []const Point, sc: f64, x0: f64, y0: f64) FontError!void {
        if (pts.len < 3) return;
        // If the contour starts off-curve, rotate so it starts on-curve
        // (or synthesize the implied start midpoint).
        var list = pts;
        var synthetic_first: Point = undefined;
        var need_free = false;
        defer if (need_free) alloc.free(list);
        if (!pts[0].on_curve) {
            if (pts[pts.len - 1].on_curve) {
                // rotate: start at last point
                const buf = alloc.alloc(Point, pts.len) catch return FontError.OutOfMemory;
                buf[0] = pts[pts.len - 1];
                @memcpy(buf[1..], pts[0 .. pts.len - 1]);
                list = buf;
                need_free = true;
            } else {
                // both ends off-curve: prepend the implied midpoint
                const buf = alloc.alloc(Point, pts.len + 1) catch return FontError.OutOfMemory;
                synthetic_first = .{
                    .x = (pts[0].x + pts[pts.len - 1].x) / 2.0,
                    .y = (pts[0].y + pts[pts.len - 1].y) / 2.0,
                    .on_curve = true,
                };
                buf[0] = synthetic_first;
                @memcpy(buf[1..], pts);
                list = buf;
                need_free = true;
            }
        }

        var prev = list[0];
        var i: usize = 1;
        while (i <= list.len) : (i += 1) {
            const cur = if (i < list.len) list[i] else list[0];
            if (cur.on_curve) {
                try pushEdge(alloc, edges, prev, cur, sc, x0, y0);
                prev = cur;
            } else {
                // quad from prev through cur(off) to next
                const next_idx = i + 1;
                var next: Point = undefined;
                if (next_idx < list.len) {
                    if (list[next_idx].on_curve) {
                        next = list[next_idx];
                        i += 1;
                    } else {
                        next = .{
                            .x = (cur.x + list[next_idx].x) / 2.0,
                            .y = (cur.y + list[next_idx].y) / 2.0,
                            .on_curve = true,
                        };
                    }
                } else {
                    next = list[0];
                }
                try pushQuad(alloc, edges, prev, cur, next, sc, x0, y0);
                prev = next;
            }
        }
    }

    fn pushEdge(alloc: std.mem.Allocator, edges: *std.ArrayList(Edge), from: Point, to: Point, sc: f64, x0: f64, y0: f64) FontError!void {
        const ax = from.x * sc - x0;
        const ay = -from.y * sc - y0;
        const bx = to.x * sc - x0;
        const by = -to.y * sc - y0;
        if (ay == by) return;
        edges.append(alloc, .{ .x0 = ax, .y0 = ay, .x1 = bx, .y1 = by }) catch return FontError.OutOfMemory;
    }

    fn pushQuad(alloc: std.mem.Allocator, edges: *std.ArrayList(Edge), p0: Point, p1: Point, p2: Point, sc: f64, x0: f64, y0: f64) FontError!void {
        const steps: usize = 8;
        var prev_x = p0.x;
        var prev_y = p0.y;
        var s: usize = 1;
        while (s <= steps) : (s += 1) {
            const t = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(steps));
            const u = 1.0 - t;
            const x = u * u * p0.x + 2.0 * u * t * p1.x + t * t * p2.x;
            const y = u * u * p0.y + 2.0 * u * t * p1.y + t * t * p2.y;
            try pushEdge(alloc, edges, .{ .x = prev_x, .y = prev_y, .on_curve = true }, .{ .x = x, .y = y, .on_curve = true }, sc, x0, y0);
            prev_x = x;
            prev_y = y;
        }
    }

    /// Measure a UTF-8 string (pixel advance incl. kerning).
    pub fn measureText(self: *Font, text: []const u8, size_px: u32) struct { width: i32, height: i32 } {
        var w: i32 = 0;
        var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
        var prev_gid: u16 = 0;
        const sc = self.scale(size_px);
        while (iter.nextCodepoint()) |cp| {
            const gid = self.glyphId(cp);
            const adv_f = @as(f64, @floatFromInt(self.advanceUnits(gid))) * sc;
            const kern_f = @as(f64, @floatFromInt(self.kernUnits(prev_gid, gid))) * sc;
            w += @intFromFloat(@round(adv_f + kern_f));
            prev_gid = gid;
        }
        return .{ .width = w, .height = @intCast(size_px) };
    }
};

/// Compose only from this font's rasterized ink. Reflection turns its
/// diagonal grave into an acute; the base letter retains its metrics.
fn composeAcute(alloc: std.mem.Allocator, base: Glyph, grave: Glyph, size: u32) FontError!Glyph {
    if (base.coverage.len == 0 or grave.coverage.len == 0) {
        var copy = base;
        copy.coverage = try alloc.dupe(u8, base.coverage);
        return copy;
    }
    const base_left = base.bearing_x;
    const base_top = -base.top;
    const accent_left = base_left + @divFloor(@as(i32, @intCast(base.width)) - @as(i32, @intCast(grave.width)), 2);
    const accent_top = base_top - @as(i32, @intCast(@max(1, size / 24))) - @as(i32, @intCast(grave.height));
    const left = @min(base_left, accent_left);
    const top = @min(base_top, accent_top);
    const right = @max(base_left + @as(i32, @intCast(base.width)), accent_left + @as(i32, @intCast(grave.width)));
    const bottom = base_top + @as(i32, @intCast(base.height));
    const width: u32 = @intCast(right - left);
    const height: u32 = @intCast(bottom - top);
    if (width > 4096 or height > 4096) return FontError.BadTable;
    const coverage = try alloc.alloc(u8, @as(usize, width) * height);
    @memset(coverage, 0);
    for (0..base.height) |y| for (0..base.width) |x| {
        const dx = @as(usize, @intCast(base_left - left)) + x;
        const dy = @as(usize, @intCast(base_top - top)) + y;
        coverage[dy * width + dx] = base.coverage[y * base.width + x];
    };
    for (0..grave.height) |y| for (0..grave.width) |x| {
        const dx = @as(usize, @intCast(accent_left - left)) + x;
        const dy = @as(usize, @intCast(accent_top - top)) + y;
        coverage[dy * width + dx] = grave.coverage[y * grave.width + (grave.width - 1 - x)];
    };
    return .{ .width = width, .height = height, .bearing_x = left, .top = -top, .advance = base.advance, .coverage = coverage };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "font: acute composition keeps base ink and advance and mirrors the font mark" {
    var body = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 };
    var mark = [_]u8{ 100, 0, 0, 0, 200, 0, 0, 0, 255 };
    const base = Glyph{ .width = 5, .height = 4, .bearing_x = 0, .top = 4, .advance = 6, .coverage = &body };
    const grave = Glyph{ .width = 3, .height = 3, .bearing_x = 0, .top = 7, .advance = 4, .coverage = &mark };
    var accented = try composeAcute(testing.allocator, base, grave, 24);
    defer accented.deinit(testing.allocator);
    try testing.expectEqual(base.advance, accented.advance);
    try testing.expectEqual(base.bearing_x, accented.bearing_x);
    try testing.expectEqual(@as(u32, 5), accented.width);
    try testing.expectEqual(@as(i32, 8), accented.top);
    for (0..base.height) |row| try testing.expectEqualSlices(u8, body[row * 5 ..][0..5], accented.coverage[(row + 4) * 5 ..][0..5]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 100, 0 }, accented.coverage[0..5]);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 200, 0, 0 }, accented.coverage[5..10]);
    try testing.expectEqualSlices(u8, &.{ 0, 255, 0, 0, 0 }, accented.coverage[10..15]);
}

test "font: missing acute glyph caches in-font composition with matching text metrics" {
    // Generated cmap/hmtx/loca and three simple triangles; no game data.
    var data: [376]u8 = @splat(0);
    std.mem.writeInt(u16, data[2..4], 1, .big);
    std.mem.writeInt(u16, data[4..6], 3, .big);
    std.mem.writeInt(u16, data[6..8], 1, .big);
    std.mem.writeInt(u32, data[8..12], 12, .big);
    std.mem.writeInt(u16, data[14..16], 262, .big);
    data[18 + 'e'] = 1;
    data[18 + 'E'] = 2;
    data[18 + '`'] = 3;
    for (0..4) |i| std.mem.writeInt(u16, data[274 + i * 4 ..][0..2], 600, .big);
    for ([_]u32{ 0, 0, 22, 44, 66 }, 0..) |offset, i| std.mem.writeInt(u32, data[290 + i * 4 ..][0..4], offset, .big);
    const triangle = [_]u8{ 0, 1, 0, 0, 0, 0, 0, 200, 0, 200, 0, 2, 0, 0, 0x37, 0x23, 0x15, 200, 200, 200, 200, 0 };
    for (0..3) |i| @memcpy(data[310 + i * 22 ..][0..22], &triangle);
    var font = Font{ .alloc = testing.allocator, .data = &data, .upem = 1000, .num_glyphs = 4, .index_to_loc_long = true, .num_hmetrics = 4, .cmap_offset = 0, .cmap_len = 274, .hmtx_offset = 274, .loca_offset = 290, .glyf_offset = 310, .cache = std.AutoHashMap(u64, Glyph).init(testing.allocator) };
    defer font.deinit();
    try testing.expectEqual(@as(u16, 0), font.cmapGlyphId(0x00e9));
    try testing.expectEqual(e_acute_glyph, font.glyphId(0x00e9));
    try testing.expectEqual(E_acute_glyph, font.glyphId(0x00c9));
    try testing.expectEqual(@as(u16, 0), font.glyphId(0x00f6));
    const accented = (try font.rasterize(font.glyphId(0x00e9), 24)).*;
    const body = (try font.rasterize(font.glyphId('e'), 24)).*;
    try testing.expect(accented.top > body.top and accented.height > body.height);
    try testing.expectEqual(body.advance, accented.advance);
    try testing.expectEqual(font.measureText("Jose", 24).width, font.measureText("José", 24).width);
    const cached = try font.rasterize(e_acute_glyph, 24);
    try testing.expectEqual(cached, try font.rasterize(e_acute_glyph, 24));
    data[18 + 0x00e9] = 2;
    try testing.expectEqual(@as(u16, 2), font.glyphId(0x00e9));
}

test "font: not-a-font rejection" {
    const junk = "hello world, definitely not a font";
    try testing.expectError(FontError.NotTrueType, Font.init(testing.allocator, junk));
}

test "font: head indexToLocFormat is a big-endian int16" {
    // Minimal five-table sfnt fixture. No proprietary font is required.
    var data: [166]u8 = @splat(0);
    std.mem.writeInt(u32, data[0..4], 0x00010000, .big);
    std.mem.writeInt(u16, data[4..6], 5, .big);
    const Table = struct { tag: *const [4]u8, offset: u32, len: u32 };
    const tables = [_]Table{
        .{ .tag = "head", .offset = 92, .len = 54 },
        .{ .tag = "maxp", .offset = 146, .len = 6 },
        .{ .tag = "cmap", .offset = 152, .len = 4 },
        .{ .tag = "glyf", .offset = 156, .len = 2 },
        .{ .tag = "loca", .offset = 158, .len = 8 },
    };
    for (tables, 0..) |table, i| {
        const base = 12 + i * 16;
        @memcpy(data[base..][0..4], table.tag);
        std.mem.writeInt(u32, data[base + 8 ..][0..4], table.offset, .big);
        std.mem.writeInt(u32, data[base + 12 ..][0..4], table.len, .big);
    }
    std.mem.writeInt(u16, data[110..112], 1000, .big); // unitsPerEm
    std.mem.writeInt(u16, data[150..152], 1, .big); // numGlyphs
    std.mem.writeInt(i16, data[142..144], 1, .big); // indexToLocFormat
    var long = try Font.init(testing.allocator, &data);
    defer long.deinit();
    try testing.expect(long.index_to_loc_long);
    std.mem.writeInt(i16, data[142..144], 0, .big);
    var short = try Font.init(testing.allocator, &data);
    defer short.deinit();
    try testing.expect(!short.index_to_loc_long);
    std.mem.writeInt(i16, data[142..144], 2, .big);
    try testing.expectError(FontError.BadTable, Font.init(testing.allocator, &data));
}

test "font: short glyph deltas above 127 use unsigned magnitudes" {
    // A three-point contour: (200,200), (0,200), (0,0). Each 200-byte
    // magnitude must keep its value; signs come from the flag bits.
    // https://learn.microsoft.com/en-us/typography/opentype/spec/glyf
    const data = [_]u8{
        0, 0, 0, 11, // short loca: offsets 0 and 22
        0, 1, // one contour
        0, 0, 0, 0, 0, 200, 0, 200, // bbox
        0, 2, 0, 0, // contour endpoint and no instructions
        0x37, 0x23, 0x15, // flags for the three on-curve points
        200, 200, // x: positive 200, negative 200, unchanged
        200, 200, // y: positive 200, unchanged, negative 200
        0, // alignment padding
    };
    var font = Font{
        .alloc = testing.allocator,
        .data = &data,
        .upem = 1000,
        .num_glyphs = 1,
        .index_to_loc_long = false,
        .num_hmetrics = 0,
        .loca_offset = 0,
        .glyf_offset = 4,
        .cache = std.AutoHashMap(u64, Glyph).init(testing.allocator),
    };
    defer font.deinit();
    var points: std.ArrayList(Point) = .empty;
    defer points.deinit(testing.allocator);
    var contours: std.ArrayList(usize) = .empty;
    defer contours.deinit(testing.allocator);
    try font.collectOutline(0, &points, &contours, 0);
    try testing.expectEqual(@as(usize, 3), points.items.len);
    try testing.expectEqual(@as(f64, 200), points.items[0].x);
    try testing.expectEqual(@as(f64, 200), points.items[0].y);
    try testing.expectEqual(@as(f64, 0), points.items[1].x);
    try testing.expectEqual(@as(f64, 200), points.items[1].y);
    try testing.expectEqual(@as(f64, 0), points.items[2].x);
    try testing.expectEqual(@as(f64, 0), points.items[2].y);
}

test "font: parse the payload GameFont and rasterize glyphs" {
    const path = std.process.getEnvVarOwned(testing.allocator, "OMORI_FONT_SMOKE_PATH") catch |e| switch (e) {
        error.EnvironmentVariableNotFound => return error.SkipZigTest,
        else => return e,
    };
    defer testing.allocator.free(path);
    const data = try std.fs.cwd().readFileAlloc(testing.allocator, path, 16 * 1024 * 1024);
    defer testing.allocator.free(data);

    var font = try Font.init(testing.allocator, data);
    defer font.deinit();

    try testing.expectEqual(@as(u16, 1024), font.upem);
    try testing.expect(font.num_glyphs > 90);

    const gid_a = font.glyphId('A');
    try testing.expect(gid_a != 0);

    const g = try font.rasterize(gid_a, 24);
    try testing.expect(g.width > 4 and g.height > 8);
    try testing.expect(g.advance > 4);
    var ink: usize = 0;
    for (g.coverage) |c| {
        if (c > 32) ink += 1;
    }
    try testing.expect(ink > g.coverage.len / 8);

    // space → empty glyph with positive advance
    const gid_space = font.glyphId(' ');
    const gs = try font.rasterize(gid_space, 24);
    try testing.expect(gs.width == 0);
    try testing.expect(gs.advance > 0);

    // caching: same pointer
    const g2 = try font.rasterize(gid_a, 24);
    try testing.expectEqual(g, g2);

    // measureText monotone
    const m1 = font.measureText("OMORI", 24);
    const m2 = font.measureText("OMORI2", 24);
    try testing.expect(m2.width > m1.width);
    try testing.expect(m1.width > 20);
}
