//! VP8L (WebP lossless) decoder — the payload's actual image codec.
//!
//! **Payload fact (verified):** all 872 image files under `img/` are
//! RIFF/WEBP `VP8L` streams with `.png` extensions. The browser stack
//! never noticed because Chromium's image decoder sniffs content, not
//! extensions; a native runtime must decode VP8L itself.
//!
//! This is a spec-faithful decoder (RFC 9649 / libwebp `vp8l_dec.c`):
//!   * RIFF container → VP8L chunk; signature 0x2F, 14-bit w/h, alpha
//!     bit, 3-bit version (must be 0)
//!   * transforms (level-0 only, each once): PREDICTOR (subsampled tile
//!     image of predictor modes, 14 modes incl. Select/ClampedAddSubtract),
//!     CROSS_COLOR (per-tile channel multipliers), SUBTRACT_GREEN,
//!     COLOR_INDEXING (palette + pixel bundling with xsize subsampling)
//!     — transform tile/palette data is itself an image stream decoded
//!     through the same machinery (recursion depth 1)
//!   * color cache (4-bit size, per stream level)
//!   * prefix codes: simple (1-2 symbols) and normal (code-length codes
//!     with the 19-symbol shuffled order, repeat codes 16/17/18, optional
//!     max-symbol truncation); meta prefix codes via the entropy image
//!   * LZ77: green alphabet 256 + 24 lengths + color-cache; distance
//!     codes through the 40-symbol plane-code mapping (kCodeToPlane)
//!   * inverse transforms applied in reverse stream order; ARGB→RGBA out
//!
//! Validated byte-for-byte against Pillow/libwebp on the payload's title
//! sheet and a corpus sample (see tests + scripts/vp8l_check.py).

const std = @import("std");
const log = @import("../core/log.zig");

/// Debug tracing (set via the check harness --debug or compile flag).
pub var debug_trace: bool = false;
/// Trace every LZ77 symbol (very verbose).
pub var trace_all: bool = false;
/// Dump palette entries after decode.
pub var dump_palette: bool = false;
/// When set, the pre-inverse ARGB pixels are dumped here (u32 LE per pixel).
pub var dump_raw_path: ?[]const u8 = null;

fn dbg(comptime fmt: []const u8, args: anytype) void {
    if (debug_trace or trace_all) std.debug.print("[vp8l] " ++ fmt ++ "\n", args);
}

pub const DecodeError = error{
    OutOfMemory,
    BadRiff,
    BadVp8lHeader,
    BadTransform,
    BadPrefixCode,
    BadStream,
    TooLarge,
};

/// Decoded image (RGBA, row-major, caller owns `pixels`).
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []u8, // width*height*4
};

// ---------------------------------------------------------------------------
// Bit reader (LSB-first)
// ---------------------------------------------------------------------------

const BitReader = struct {
    src: []const u8,
    byte_pos: usize = 0,
    bit_pos: u5 = 0, // bits consumed in current byte

    fn init(src: []const u8) BitReader {
        return .{ .src = src };
    }

    fn readBit(self: *BitReader) DecodeError!u1 {
        if (self.byte_pos >= self.src.len) return DecodeError.BadStream;
        const b: u1 = @intCast((self.src[self.byte_pos] >> @intCast(self.bit_pos)) & 1);
        if (self.bit_pos == 7) {
            self.bit_pos = 0;
            self.byte_pos += 1;
        } else {
            self.bit_pos += 1;
        }
        return b;
    }

    fn readBits(self: *BitReader, n: u6) DecodeError!u32 {
        var v: u32 = 0;
        var i: u6 = 0;
        while (i < n) : (i += 1) {
            v |= @as(u32, try self.readBit()) << @intCast(i);
        }
        return v;
    }

    fn eof(self: *const BitReader) bool {
        return self.byte_pos >= self.src.len;
    }
};

// ---------------------------------------------------------------------------
// Canonical prefix-code table
//
// Build: histogram → canonical next-code → REVERSED codes (stream is
// LSB-first, Huffman codes are MSB-first) → flat root table.
// root_bits == 0 marks a single-symbol 0-bit code.
// ---------------------------------------------------------------------------

const HuffTable = struct {
    root_bits: u5,
    /// (symbol, len) flat table of 2^root_bits entries (len 0 = invalid
    /// except for the single-symbol case where len is 0 = consume 0).
    fast: []FastEntry,

    const FastEntry = struct {
        symbol: u16,
        len: u8,
    };

    const SINGLE = HuffTable{ .root_bits = 0, .fast = &.{} };

    fn deinit(self: *const HuffTable, alloc: std.mem.Allocator) void {
        if (self.fast.len > 0) alloc.free(self.fast);
    }

    fn build(alloc: std.mem.Allocator, code_lengths: []const u32, alphabet: usize) DecodeError!HuffTable {
        var counts: [16]u32 = .{0} ** 16;
        var max_len: u32 = 0;
        var total_codes: u32 = 0;
        for (code_lengths[0..alphabet]) |l| {
            if (l > 15) return DecodeError.BadPrefixCode;
            if (l > 0) {
                counts[l] += 1;
                total_codes += 1;
                if (l > max_len) max_len = l;
            }
        }
        if (total_codes == 0) return DecodeError.BadPrefixCode;

        // Single-symbol tree: 0-bit code (readSymbol consumes nothing).
        if (total_codes == 1) {
            for (code_lengths[0..alphabet], 0..) |l, sym| {
                if (l > 0) {
                    const fast = alloc.alloc(FastEntry, 1) catch return DecodeError.OutOfMemory;
                    fast[0] = .{ .symbol = @intCast(sym), .len = 0 };
                    return .{ .root_bits = 0, .fast = fast };
                }
            }
            unreachable;
        }

        // Canonical next-code (bl_count[0] excluded).
        var next: [16]u32 = .{0} ** 16;
        var code: u32 = 0;
        var l: u5 = 1;
        while (l <= 15) : (l += 1) {
            code = (code + counts[l - 1]) << 1;
            next[l] = code;
        }

        const root_bits: u5 = @intCast(@min(max_len, 15));
        const table_size: usize = @as(usize, 1) << root_bits;
        var fast = alloc.alloc(FastEntry, table_size) catch return DecodeError.OutOfMemory;
        errdefer alloc.free(fast);
        @memset(fast, .{ .symbol = 0, .len = 0 });

        for (code_lengths[0..alphabet], 0..) |clen, sym| {
            if (clen == 0) continue;
            const c = next[clen];
            next[clen] += 1;
            // reverse `clen` bits
            var rev: u32 = 0;
            var b: u5 = 0;
            while (b < clen) : (b += 1) {
                rev |= ((c >> @intCast(b)) & 1) << @intCast(clen - 1 - b);
            }
            const step: usize = @as(usize, 1) << @intCast(clen);
            var idx: usize = rev;
            while (idx < table_size) : (idx += step) {
                fast[idx] = .{ .symbol = @intCast(sym), .len = @intCast(clen) };
            }
        }
        return .{ .root_bits = root_bits, .fast = fast };
    }

    inline fn readSymbol(self: *const HuffTable, br: *BitReader) DecodeError!u32 {
        if (self.root_bits == 0) {
            // 0-bit code: consume nothing.
            if (self.fast.len == 0) return DecodeError.BadPrefixCode;
            return self.fast[0].symbol;
        }
        const rb = self.root_bits;
        // Forward-scan with zero padding past the end (the reference bit
        // reader returns zero bits on overrun and flags eos; codes whose
        // CONSUMED length exceeds the stream are rejected after).
        var peek: u32 = 0;
        var consumed: u6 = 0;
        while (consumed < rb) : (consumed += 1) {
            var bit: u32 = 0;
            if (br.byte_pos < br.src.len) {
                bit = (br.src[br.byte_pos] >> @intCast(br.bit_pos)) & 1;
            }
            peek |= bit << @intCast(consumed);
            if (br.bit_pos == 7) {
                br.bit_pos = 0;
                br.byte_pos += 1;
            } else br.bit_pos += 1;
        }
        const entry = self.fast[peek];
        if (entry.len == 0) return DecodeError.BadPrefixCode;
        // unconsume (rb - len) bits
        var back: u5 = rb - @as(u5, @intCast(entry.len));
        while (back > 0) : (back -= 1) {
            if (br.bit_pos == 0) {
                br.bit_pos = 7;
                if (br.byte_pos > 0) br.byte_pos -= 1;
            } else br.bit_pos -= 1;
        }
        // Real overrun check: consumed bits must lie within the stream.
        const consumed_total: u64 = @as(u64, br.byte_pos) * 8 + br.bit_pos;
        if (consumed_total > @as(u64, br.src.len) * 8) {
            return DecodeError.BadStream;
        }
        return entry.symbol;
    }
};

// ---------------------------------------------------------------------------
// Constants (libwebp parity)
// ---------------------------------------------------------------------------

const NUM_LITERAL_CODES = 256;
const NUM_LENGTH_CODES = 24;
const NUM_DISTANCE_CODES = 40;
const NUM_CODE_LENGTH_CODES = 19;

const code_length_code_order = [NUM_CODE_LENGTH_CODES]u32{
    17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
};

const CODE_TO_PLANE_CODES = 120;
const code_to_plane = [CODE_TO_PLANE_CODES]u8{
    0x18, 0x07, 0x17, 0x19, 0x28, 0x06, 0x27, 0x29, 0x16, 0x1a, 0x26, 0x2a,
    0x38, 0x05, 0x37, 0x39, 0x15, 0x1b, 0x36, 0x3a, 0x25, 0x2b, 0x48, 0x04,
    0x47, 0x49, 0x14, 0x1c, 0x35, 0x3b, 0x46, 0x4a, 0x24, 0x2c, 0x58, 0x45,
    0x4b, 0x34, 0x3c, 0x03, 0x57, 0x59, 0x13, 0x1d, 0x56, 0x5a, 0x23, 0x2d,
    0x44, 0x4c, 0x55, 0x5b, 0x33, 0x3d, 0x68, 0x02, 0x67, 0x69, 0x12, 0x1e,
    0x66, 0x6a, 0x22, 0x2e, 0x54, 0x5c, 0x43, 0x4d, 0x65, 0x6b, 0x32, 0x3e,
    0x78, 0x01, 0x77, 0x79, 0x53, 0x5d, 0x11, 0x1f, 0x64, 0x6c, 0x42, 0x4e,
    0x76, 0x7a, 0x21, 0x2f, 0x75, 0x7b, 0x31, 0x3f, 0x63, 0x6d, 0x52, 0x5e,
    0x00, 0x74, 0x7c, 0x41, 0x4f, 0x10, 0x20, 0x62, 0x6e, 0x30, 0x73, 0x7d,
    0x51, 0x5f, 0x40, 0x72, 0x7e, 0x61, 0x6f, 0x50, 0x71, 0x7f, 0x60, 0x70,
};

/// ARGB_BLACK.
const argb_black: u32 = 0xFF000000;

const TransformType = enum(u2) {
    predictor = 0,
    cross_color = 1,
    subtract_green = 2,
    color_indexing = 3,
};

const Transform = struct {
    type: TransformType,
    /// transform-space xsize (color indexing shrinks it).
    xsize: u32,
    ysize: u32,
    /// tile bits (predictor / cross_color / color-indexing bundling).
    bits: u5 = 0,
    /// tile/palette pixel data (decoded nested image).
    data: []u32 = &.{},

    fn deinit(self: *Transform, alloc: std.mem.Allocator) void {
        if (self.data.len > 0) alloc.free(self.data);
    }
};

/// The 5 prefix codes of one htree group.
const HTreeGroup = struct {
    green: HuffTable,
    red: HuffTable,
    blue: HuffTable,
    alpha: HuffTable,
    dist: HuffTable,

    fn deinit(self: *HTreeGroup, alloc: std.mem.Allocator) void {
        self.green.deinit(alloc);
        self.red.deinit(alloc);
        self.blue.deinit(alloc);
        self.alpha.deinit(alloc);
        self.dist.deinit(alloc);
    }
};

const ColorCache = struct {
    bits: u5,
    data: []u32,

    /// libwebp: index = (argb * 0x1e35a7bd) >> (32 - bits) — a right
    /// shift, NOT a low-bits mask.
    fn index(argb: u32, bits: u5) u32 {
        return (argb *% 0x1e35_a7bd) >> @intCast(32 - @as(u6, bits));
    }

    fn lookup(self: *const ColorCache, key: u32) u32 {
        return self.data[key];
    }

    fn insert(self: *ColorCache, argb: u32) void {
        self.data[index(argb, self.bits)] = argb;
    }
};

// ---------------------------------------------------------------------------
// One image-stream level: [transforms if level0] + color cache + codes +
// LZ77 data. `decodeStream` returns the ARGB pixel array (caller owns).
// ---------------------------------------------------------------------------

const Stream = struct {
    alloc: std.mem.Allocator,
    br: BitReader,
    color_cache: ?ColorCache = null,
    groups: []HTreeGroup = &.{},
    /// entropy image (meta map), subsampled; entry = group index.
    huffman_image: []u32 = &.{},
    huffman_bits: u5 = 0,
    huffman_xsize: u32 = 1,
    h_xsize: u32 = 1,

    fn deinit(self: *Stream) void {
        for (self.groups) |*g| g.deinit(self.alloc);
        if (self.groups.len > 0) self.alloc.free(self.groups);
        if (self.huffman_image.len > 0) self.alloc.free(self.huffman_image);
        if (self.color_cache) |*cc| self.alloc.free(cc.data);
    }

    fn groupForPos(self: *const Stream, x: u32, y: u32) *HTreeGroup {
        if (self.huffman_image.len == 0 or self.groups.len <= 1) {
            return &self.groups[0];
        }
        const sub_x = x >> self.huffman_bits;
        const sub_y = y >> self.huffman_bits;
        const cell = sub_y * self.h_xsize + sub_x;
        const gi = if (cell < self.huffman_image.len) self.huffman_image[cell] else 0;
        return &self.groups[@intCast(@min(gi, self.groups.len - 1))];
    }

};

fn subSampleSize(size: u32, sampling_bits: u5) u32 {
    return (size + (@as(u32, 1) << sampling_bits) - 1) >> sampling_bits;
}

fn decodeStreamPixels(alloc: std.mem.Allocator, br: *BitReader, xsize: u32, ysize: u32, is_level0: bool) DecodeError![]u32 {
    _ = is_level0;
    // No transforms at nested levels; read color cache + codes + pixels.
    var cache_bits: u5 = 0;
    if (try br.readBit() == 1) {
        const cb = try br.readBits(4);
        if (cb < 1 or cb > 11) return DecodeError.BadStream;
        cache_bits = @intCast(cb);
    }
    var stream = Stream{ .alloc = alloc, .br = br.* };
    defer stream.deinit();
    try readHuffmanCodes(alloc, &stream, br, xsize, ysize, cache_bits, false);
    if (cache_bits > 0) {
        const size: usize = @as(usize, 1) << cache_bits;
        const cdata = alloc.alloc(u32, size) catch return DecodeError.OutOfMemory;
        @memset(cdata, 0);
        stream.color_cache = .{ .bits = cache_bits, .data = cdata };
    }
    return decodeLZ77Pixels(alloc, br, &stream, xsize, ysize);
}

/// Read the huffman code groups (+ optional meta entropy image).
fn readHuffmanCodes(alloc: std.mem.Allocator, stream: *Stream, br: *BitReader, xsize: u32, ysize: u32, cache_bits: u5, allow_meta: bool) DecodeError!void {
    var num_groups: usize = 1;
    var meta_map: []u32 = &.{};

    if (allow_meta and try br.readBit() == 1) {
        const huff_bits: u5 = @intCast(2 + try br.readBits(3));
        const hx = subSampleSize(xsize, huff_bits);
        const hy = subSampleSize(ysize, huff_bits);
        dbg("meta huffman: bits={d} {d}x{d}", .{ huff_bits, hx, hy });
        // The entropy image is itself an image stream (no meta recursion).
        const ent = try decodeStreamPixels(alloc, br, hx, hy, false);
        defer alloc.free(ent);
        const map = alloc.alloc(u32, ent.len) catch return DecodeError.OutOfMemory;
        var max_group: u32 = 0;
        for (ent, 0..) |p, i| {
            const g = (p >> 8) & 0xFFFF;
            map[i] = g;
            if (g > max_group) max_group = g;
        }
        stream.huffman_image = map;
        stream.huffman_bits = huff_bits;
        stream.huffman_xsize = hx;
        stream.h_xsize = hx;
        meta_map = map;
        num_groups = max_group + 1;
    }

    const gs = alloc.alloc(HTreeGroup, num_groups) catch return DecodeError.OutOfMemory;
    var initialized: usize = 0;
    errdefer {
        for (gs[0..initialized]) |*g| g.deinit(alloc);
        alloc.free(gs);
    }
    for (gs) |*g| {
        g.* = try readHTreeGroup(alloc, br, cache_bits);
        initialized += 1;
        dbg("group {d}/{d} read (bit pos {d}:{d})", .{ initialized, num_groups, br.byte_pos, br.bit_pos });
    }
    stream.groups = gs;
}

/// One group = green(280+cache) / red / blue / alpha / dist(40).
fn readHTreeGroup(alloc: std.mem.Allocator, br: *BitReader, cache_bits: u5) DecodeError!HTreeGroup {
    const green_alphabet: usize = NUM_LITERAL_CODES + NUM_LENGTH_CODES + (if (cache_bits > 0) @as(usize, 1) << cache_bits else 0);
    const green = try readHuffTable(alloc, br, green_alphabet);
    errdefer green.deinit(alloc);
    const red = try readHuffTable(alloc, br, NUM_LITERAL_CODES);
    errdefer red.deinit(alloc);
    const blue = try readHuffTable(alloc, br, NUM_LITERAL_CODES);
    errdefer blue.deinit(alloc);
    const alpha = try readHuffTable(alloc, br, NUM_LITERAL_CODES);
    errdefer alpha.deinit(alloc);
    const dist = try readHuffTable(alloc, br, NUM_DISTANCE_CODES);
    return .{ .green = green, .red = red, .blue = blue, .alpha = alpha, .dist = dist };
}

/// One prefix code: simple or code-length-coded.
fn readHuffTable(alloc: std.mem.Allocator, br: *BitReader, alphabet: usize) DecodeError!HuffTable {
    const is_simple = (try br.readBit()) == 1;
    var code_lengths = alloc.alloc(u32, alphabet + 1) catch return DecodeError.OutOfMemory;
    defer alloc.free(code_lengths);
    @memset(code_lengths, 0);

    if (is_simple) {
        const num_symbols: u32 = @as(u32, try br.readBit()) + 1;
        const first_symbol_len_code = try br.readBit();
        const sym: u32 = try br.readBits(if (first_symbol_len_code == 0) 1 else 8);
        if (sym >= code_lengths.len) return DecodeError.BadPrefixCode;
        code_lengths[sym] = 1;
        if (num_symbols == 2) {
            const sym2: u32 = try br.readBits(8);
            if (sym2 >= code_lengths.len) return DecodeError.BadPrefixCode;
            code_lengths[sym2] = 1;
        }
        return HuffTable.build(alloc, code_lengths, alphabet);
    }

    // Normal code: code-length code first (3-bit lengths, shuffled order).
    const num_codes: usize = @intCast((try br.readBits(4)) + 4);
    var cl_lengths: [NUM_CODE_LENGTH_CODES]u32 = .{0} ** NUM_CODE_LENGTH_CODES;
    var i: usize = 0;
    while (i < num_codes) : (i += 1) {
        cl_lengths[code_length_code_order[i]] = try br.readBits(3);
    }
    const cl_tree = try HuffTable.build(alloc, &cl_lengths, NUM_CODE_LENGTH_CODES);
    defer cl_tree.deinit(alloc);

    // Optional max-symbol truncation.
    var max_symbol: usize = alphabet;
    if (try br.readBit() == 1) {
        const length_nbits: u32 = 2 + 2 * (try br.readBits(3));
        max_symbol = 2 + @as(usize, try br.readBits(@intCast(length_nbits)));
        if (max_symbol > alphabet) return DecodeError.BadPrefixCode;
    }

    // Read the symbol code lengths with repeat codes.
    var prev_code_len: u32 = 8; // DEFAULT_CODE_LENGTH
    var sym: usize = 0;
    var remaining: usize = max_symbol;
    while (sym < alphabet) {
        if (remaining == 0) break;
        remaining -= 1;
        const code_len_sym = try cl_tree.readSymbol(br);
        if (code_len_sym < 16) {
            code_lengths[sym] = code_len_sym;
            if (code_len_sym != 0) prev_code_len = code_len_sym;
            sym += 1;
        } else {
            const use_prev = code_len_sym == 16;
            const slot: usize = @intCast(code_len_sym - 16);
            const extra_bits_table = [3]u6{ 2, 3, 7 };
            const repeat_offset_table = [3]u32{ 3, 3, 11 };
            const repeat: u32 = repeat_offset_table[slot] + (try br.readBits(extra_bits_table[slot]));
            if (sym + repeat > alphabet) return DecodeError.BadPrefixCode;
            const value: u32 = if (use_prev) prev_code_len else 0;
            var r: u32 = 0;
            while (r < repeat) : (r += 1) {
                code_lengths[sym] = value;
                sym += 1;
            }
        }
    }
    return HuffTable.build(alloc, code_lengths, alphabet);
}

// ---------------------------------------------------------------------------
// LZ77 pixel decoding
// ---------------------------------------------------------------------------

/// GetCopyDistance / GetCopyLength (same formula).
fn copyCodeToLength(br: *BitReader, symbol: u32) DecodeError!u32 {
    if (symbol < 4) {
        return symbol + 1;
    }
    const extra_bits: u6 = @intCast((symbol - 2) >> 1);
    const offset: u32 = (@as(u32, 2) + (symbol & 1)) << @intCast(extra_bits);
    return offset + (try br.readBits(extra_bits)) + 1;
}

fn planeCodeToDistance(xsize: u32, plane_code: u32) u32 {
    if (plane_code > CODE_TO_PLANE_CODES) {
        return plane_code - CODE_TO_PLANE_CODES;
    }
    const dist_code: u32 = code_to_plane[plane_code - 1];
    const yoffset: i64 = @intCast(dist_code >> 4);
    // NB: 8 - (nibble) is SIGNED in the C reference — can be negative.
    const xoffset: i64 = 8 - @as(i64, @intCast(dist_code & 0xF));
    var dist: i64 = yoffset * @as(i64, xsize) + xoffset;
    if (dist < 1) dist = 1;
    return @intCast(dist);
}

fn decodeLZ77Pixels(alloc: std.mem.Allocator, br: *BitReader, stream: *Stream, width: u32, height: u32) DecodeError![]u32 {
    const total: usize = @as(usize, width) * @as(usize, height);
    const data = alloc.alloc(u32, total) catch return DecodeError.OutOfMemory;
    errdefer alloc.free(data);

    const color_cache: ?*ColorCache = if (stream.color_cache != null) &stream.color_cache.? else null;
    // Lazily built cache (inserts on row wrap / before cache reads).
    var last_cached: usize = 0;

    const len_code_limit: u32 = NUM_LITERAL_CODES + NUM_LENGTH_CODES;
    const color_cache_limit: u32 = len_code_limit +
        (if (stream.color_cache) |*cc| @as(u32, @intCast(cc.data.len)) else 0);

    var pos: usize = 0;
    var col: u32 = 0;
    var row: u32 = 0;

    while (pos < total) {
        if (debug_trace and (pos & 0x3FFFF == 0)) {
            dbg("lz77 at {d}/{d} (col {d} row {d}, bit {d}:{d})", .{ pos, total, col, row, br.byte_pos, br.bit_pos });
        }
        const group = stream.groupForPos(col, row);
        const code = group.green.readSymbol(br) catch |e| {
            dbg("green symbol FAILED at pos {d}: {s}", .{ pos, @errorName(e) });
            return e;
        };
        if (trace_all) {
            if (code < 256) {
                dbg("L{d} pos={d} bit={d}:{d}", .{ code, pos, br.byte_pos, br.bit_pos });
            } else if (code < 280) {
                // backref — details printed below
            } else {
                dbg("C{d} pos={d} bit={d}:{d}", .{ code, pos, br.byte_pos, br.bit_pos });
            }
        }

        if (code < NUM_LITERAL_CODES) {
            // literal
            const red = try group.red.readSymbol(br);
            const blue = try group.blue.readSymbol(br);
            const alpha = try group.alpha.readSymbol(br);
            data[pos] = (alpha << 24) | (red << 16) | (code << 8) | blue;
            pos += 1;
            col += 1;
            if (col >= width) {
                col = 0;
                row += 1;
                if (color_cache) |cc| {
                    while (last_cached < pos) : (last_cached += 1) {
                        cc.insert(data[last_cached]);
                    }
                }
            }
        } else if (code < len_code_limit) {
            // backward reference
            const length_sym = code - NUM_LITERAL_CODES;
            const length = try copyCodeToLength(br, length_sym);
            const dist_symbol = try group.dist.readSymbol(br);
            const dist_code = try copyCodeToLength(br, dist_symbol);
            const dist = planeCodeToDistance(width, dist_code);
            if (trace_all or (debug_trace and pos + 12 > total)) {
                dbg("B len={d} dist={d} pos={d} bit={d}:{d}", .{ length, dist, pos, br.byte_pos, br.bit_pos });
            }

            if (dist > pos or pos + length > total + 1) {
                dbg("BAD backref at pos {d}: len {d} dist {d} (dist_code {d})", .{ pos, length, dist, dist_code });
                return DecodeError.BadStream;
            }
            const src = pos - dist;
            if (length > total - pos) {
                // length may exceed the row (cropped) — allowed by spec
                var k: usize = 0;
                while (pos + k < total and k < length) : (k += 1) {
                    data[pos + k] = data[src + k];
                }
                const moved = k;
                pos += moved;
                col += @intCast(moved);
                while (col >= width) {
                    col -= width;
                    row += 1;
                }
                if (color_cache) |cc| {
                    while (last_cached < pos) : (last_cached += 1) {
                        cc.insert(data[last_cached]);
                    }
                }
            } else {
                var k: usize = 0;
                while (k < length) : (k += 1) {
                    data[pos + k] = data[src + k];
                }
                pos += length;
                col += @intCast(length);
                while (col >= width) {
                    col -= width;
                    row += 1;
                }
                if (color_cache) |cc| {
                    while (last_cached < pos) : (last_cached += 1) {
                        cc.insert(data[last_cached]);
                    }
                }
            }
        } else if (code < color_cache_limit) {
            const key = code - len_code_limit;
            if (color_cache == null) {
                dbg("BAD cache ref at pos {d} but no cache", .{pos});
                return DecodeError.BadStream;
            }
            if (color_cache) |cc| {
                while (last_cached < pos) : (last_cached += 1) {
                    cc.insert(data[last_cached]);
                }
            }
            if (key >= stream.color_cache.?.data.len) return DecodeError.BadStream;
            data[pos] = stream.color_cache.?.lookup(key);
            pos += 1;
            col += 1;
            if (col >= width) {
                col = 0;
                row += 1;
            }
        } else {
            dbg("BAD code {d} at pos {d} (limit {d}, cache {d})", .{ code, pos, color_cache_limit, @intFromBool(stream.color_cache != null) });
            return DecodeError.BadStream;
        }
    }
    return data;
}

// ---------------------------------------------------------------------------
// Top-level decode
// ---------------------------------------------------------------------------

pub fn decode(alloc: std.mem.Allocator, data: []const u8) DecodeError!Image {
    if (data.len < 20) return DecodeError.BadRiff;
    if (!std.mem.eql(u8, data[0..4], "RIFF") or !std.mem.eql(u8, data[8..12], "WEBP")) {
        return DecodeError.BadRiff;
    }
    var pos: usize = 12;
    while (pos + 8 <= data.len) {
        const fourcc = data[pos .. pos + 4];
        const chunk_len = std.mem.readInt(u32, data[pos + 4 ..][0..4], .little);
        if (pos + 8 + chunk_len > data.len) return DecodeError.BadRiff;
        if (std.mem.eql(u8, fourcc, "VP8L")) {
            return decodeVp8l(alloc, data[pos + 8 .. pos + 8 + chunk_len]);
        }
        pos += 8 + chunk_len + (chunk_len & 1);
    }
    return DecodeError.BadRiff;
}

pub fn decodeVp8l(alloc: std.mem.Allocator, body: []const u8) DecodeError!Image {
    var br = BitReader.init(body);

    // header
    const sig = try br.readBits(8);
    if (sig != 0x2F) return DecodeError.BadVp8lHeader;
    const width: u32 = (try br.readBits(14)) + 1;
    const height: u32 = (try br.readBits(14)) + 1;
    _ = try br.readBits(1); // alpha_is_used
    const version = try br.readBits(3);
    if (version != 0) return DecodeError.BadVp8lHeader;
    dbg("header: {d}x{d} (bit pos {d}:{d})", .{ width, height, br.byte_pos, br.bit_pos });

    const n_pix: u64 = @as(u64, width) * @as(u64, height);
    if (n_pix == 0 or n_pix > 64 * 1024 * 1024) return DecodeError.TooLarge;

    // transforms (level 0)
    var transforms: [4]Transform = undefined;
    var n_transforms: usize = 0;
    var transforms_seen: u4 = 0;
    var data_xsize: u32 = width; // xsize in the coded (transform) space
    defer for (transforms[0..n_transforms]) |*t| t.deinit(alloc);

    while (try br.readBit() == 1) {
        if (n_transforms >= 4) return DecodeError.BadTransform;
        const ttype: TransformType = @enumFromInt(try br.readBits(2));
        const mask: u4 = @as(u4, 1) << @intCast(@intFromEnum(ttype));
        if (transforms_seen & mask != 0) return DecodeError.BadTransform;
        transforms_seen |= mask;
        var t = Transform{ .type = ttype, .xsize = data_xsize, .ysize = height };
        switch (ttype) {
            .predictor, .cross_color => {
                t.bits = @intCast(2 + (try br.readBits(3)));
                const tile_x = subSampleSize(data_xsize, t.bits);
                const tile_y = subSampleSize(height, t.bits);
                t.data = try decodeStreamPixels(alloc, &br, tile_x, tile_y, false);
                if (dump_raw_path) |rp| {
                    var buf: [128]u8 = undefined;
                    const tp = std.fmt.bufPrint(&buf, "{s}.{s}.tiles", .{ rp, @tagName(ttype) }) catch rp;
                    if (std.fs.createFileAbsolute(tp, .{})) |f| {
                        var file = f;
                        defer file.close();
                        file.writeAll(std.mem.sliceAsBytes(t.data)) catch {};
                    } else |_| {}
                }
            },
            .subtract_green => {},
            .color_indexing => {
                const num_colors: u32 = (try br.readBits(8)) + 1;
                const bits: u5 = if (num_colors > 16) 0 else if (num_colors > 4) 1 else if (num_colors > 2) 2 else 3;
                t.bits = bits;
                t.xsize = data_xsize;
                data_xsize = subSampleSize(data_xsize, bits);
                const raw = try decodeStreamPixels(alloc, &br, num_colors, 1, false);
                // ExpandColorMap: entries are DELTA-coded — entry k is the
                // per-channel mod-256 sum of stored k and entry k-1; the
                // table extends to 1<<(8>>bits) entries with a black tail.
                const shift: u5 = @intCast(@as(u32, 8) >> @as(u5, bits));
                const final_num_colors: usize = @as(usize, 1) << shift;
                var expanded = alloc.alloc(u32, final_num_colors) catch return DecodeError.OutOfMemory;
                @memset(expanded, 0);
                if (raw.len > 0) {
                    expanded[0] = raw[0];
                    var k: usize = 1;
                    while (k < raw.len and k < final_num_colors) : (k += 1) {
                        expanded[k] = addPixels(raw[k], expanded[k - 1]);
                    }
                }
                alloc.free(raw);
                t.data = expanded;
            },
        }
        transforms[n_transforms] = t;
        n_transforms += 1;
        dbg("transform {d}: type={s} bits={d} data={d} (bit pos {d}:{d})", .{ n_transforms, @tagName(t.type), t.bits, t.data.len, br.byte_pos, br.bit_pos });
    }

    // color cache
    var cache_bits: u5 = 0;
    if (try br.readBit() == 1) {
        const cb = try br.readBits(4);
        if (cb < 1 or cb > 11) return DecodeError.BadStream;
        cache_bits = @intCast(cb);
    }
    dbg("color cache bits: {d} (bit pos {d}:{d})", .{ cache_bits, br.byte_pos, br.bit_pos });

    // huffman codes
    var stream = Stream{ .alloc = alloc, .br = br };
    defer stream.deinit();
    try readHuffmanCodes(alloc, &stream, &br, data_xsize, height, cache_bits, true);
    if (cache_bits > 0) {
        const size: usize = @as(usize, 1) << cache_bits;
        const cdata = alloc.alloc(u32, size) catch return DecodeError.OutOfMemory;
        @memset(cdata, 0);
        stream.color_cache = .{ .bits = cache_bits, .data = cdata };
    }

    // pixel data
    var argb = try decodeLZ77Pixels(alloc, &br, &stream, data_xsize, height);
    defer alloc.free(argb);

    if (dump_raw_path) |rp| {
        if (std.fs.createFileAbsolute(rp, .{})) |f| {
            var file = f;
            defer file.close();
            const bytes = std.mem.sliceAsBytes(argb);
            file.writeAll(bytes) catch {};
        } else |_| {}
    }

    if (dump_palette) {
        for (transforms[0..n_transforms]) |*t| {
            if (t.type == .color_indexing) {
                for (t.data, 0..) |c, k| {
                    std.debug.print("palette[{d}] = A{d} R{d} G{d} B{d}\n", .{ k, (c >> 24) & 0xFF, (c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF });
                }
            }
        }
    }

    // inverse transforms — reverse stream order
    var i = n_transforms;
    while (i > 0) {
        i -= 1;
        argb = try applyInverse(alloc, &transforms[i], argb, data_xsize, height);
    }

    // ARGB → RGBA
    const pixels = alloc.alloc(u8, @intCast(n_pix * 4)) catch return DecodeError.OutOfMemory;
    errdefer alloc.free(pixels);
    var p: usize = 0;
    while (p < argb.len) : (p += 1) {
        const c = argb[p];
        pixels[p * 4 + 0] = @intCast((c >> 16) & 0xFF);
        pixels[p * 4 + 1] = @intCast((c >> 8) & 0xFF);
        pixels[p * 4 + 2] = @intCast(c & 0xFF);
        pixels[p * 4 + 3] = @intCast((c >> 24) & 0xFF);
    }
    return .{ .width = width, .height = height, .pixels = pixels };
}

// ---------------------------------------------------------------------------
// Inverse transforms (libwebp parity)
// ---------------------------------------------------------------------------

/// Returns the (possibly re-allocated) pixel array. Color-indexing expands
/// in place to a new array.
fn applyInverse(alloc: std.mem.Allocator, t: *Transform, argb: []u32, data_xsize: u32, height: u32) DecodeError![]u32 {
    switch (t.type) {
        .subtract_green => {
            for (argb) |*p| {
                const green = (p.* >> 8) & 0xFF;
                var red_blue = p.* & 0x00FF00FF;
                red_blue +%= (green << 16) | green;
                red_blue &= 0x00FF00FF;
                p.* = (p.* & 0xFF00FF00) | red_blue;
            }
            return argb;
        },
        .predictor => {
            const width = t.xsize;
            const bits = t.bits;
            const tiles_per_row = subSampleSize(width, bits);

            var y: u32 = 0;
            while (y < height) : (y += 1) {
                var x: u32 = 0;
                while (x < width) : (x += 1) {
                    const idx = y * width + x;
                    if (idx >= argb.len) break;
                    var pred: u32 = undefined;
                    if (y == 0) {
                        pred = if (x == 0) argb_black else argb[idx - 1];
                    } else if (x == 0) {
                        pred = argb[idx - width];
                    } else {
                        const tile_idx = (y >> bits) * tiles_per_row + (x >> bits);
                        const mode: u32 = if (tile_idx < t.data.len) (t.data[tile_idx] >> 8) & 0xF else 1;
                        pred = predict(mode, argb, idx - 1, idx - width, idx - width + 1, idx - width - 1, x, width);
                    }
                    argb[idx] = addPixels(argb[idx], pred);
                }
            }
            return argb;
        },
        .cross_color => {
            const width = t.xsize;
            const bits = t.bits;
            const tiles_per_row = subSampleSize(width, bits);
            var y: u32 = 0;
            while (y < height) : (y += 1) {
                var x: u32 = 0;
                while (x < width) : (x += 1) {
                    const idx = y * width + x;
                    if (idx >= argb.len) break;
                    const tile_idx = (y >> bits) * tiles_per_row + (x >> bits);
                    const code: u32 = if (tile_idx < t.data.len) t.data[tile_idx] else 0;
                    const g2r: i8 = @bitCast(@as(u8, @intCast(code & 0xFF)));
                    const g2b: i8 = @bitCast(@as(u8, @intCast((code >> 8) & 0xFF)));
                    const r2b: i8 = @bitCast(@as(u8, @intCast((code >> 16) & 0xFF)));
                    const p = argb[idx];
                    const green: i8 = @bitCast(@as(u8, @intCast((p >> 8) & 0xFF)));
                    const red: u32 = (p >> 16) & 0xFF;
                    const blue: u32 = p & 0xFF;
                    var new_red: u32 = red;
                    new_red +%= @as(u32, @bitCast(@as(i32, colorTransformDelta(g2r, green)))) & 0xFF;
                    new_red &= 0xFF;
                    var new_blue: u32 = blue;
                    new_blue +%= @as(u32, @bitCast(@as(i32, colorTransformDelta(g2b, green)))) & 0xFF;
                    // NB: the reference uses the TRANSFORMED new_red here.
                    new_blue +%= @as(u32, @bitCast(@as(i32, colorTransformDelta(r2b, @bitCast(@as(u8, @intCast(new_red))))))) & 0xFF;
                    new_blue &= 0xFF;
                    argb[idx] = (p & 0xFF00FF00) | (new_red << 16) | new_blue;
                }
            }
            return argb;
        },
        .color_indexing => {
            // Expand the bundled indices to palette colors. Coded width
            // is subSampleSize(orig_width, bits).
            const bits = t.bits;
            const orig_width = t.xsize;
            const total_out: usize = @as(usize, orig_width) * height;
            var out = alloc.alloc(u32, total_out) catch return DecodeError.OutOfMemory;
            errdefer alloc.free(out);
            const bits_per_pixel: u5 = @intCast(@as(u32, 1) << (if (bits == 0) 3 else 3 - @as(u5, bits)));
            // bits=0 → 8 bits/px; bits=1 → 4; bits=2 → 2; bits=3 → 1
            const bpp: u32 = if (bits == 0) 8 else (@as(u32, 1) << (3 - bits));
            _ = bits_per_pixel;
            const bit_mask: u32 = (@as(u32, 1) << @intCast(bpp)) - 1;
            const per_byte: u32 = 8 / bpp;

            var y: u32 = 0;
            while (y < height) : (y += 1) {
                var x: u32 = 0;
                while (x < orig_width) {
                    const coded_idx = y * data_xsize + (x / per_byte);
                    if (coded_idx >= argb.len) break;
                    const packed_byte: u32 = (argb[coded_idx] >> 8) & 0xFF;
                    var k: u32 = 0;
                    while (k < per_byte and x + k < orig_width) : (k += 1) {
                        const shift: u5 = @intCast(k * bpp);
                        const pal_idx: u32 = (packed_byte >> shift) & bit_mask;
                        const out_idx = y * orig_width + x + k;
                        if (out_idx < out.len) {
                            out[out_idx] = if (pal_idx < t.data.len) t.data[pal_idx] else argb_black;
                        }
                    }
                    x += per_byte;
                }
            }
            alloc.free(argb);
            return out;
        },
    }
}

fn colorTransformDelta(pred: i8, color: i8) i16 {
    const t: i32 = @as(i32, pred) * @as(i32, color);
    return @intCast(t >> 5);
}

// per-channel mod-256 addition (libwebp VP8LAddPixels)
fn addPixels(a: u32, b: u32) u32 {
    const alpha = (((a >> 24) & 0xFF) + ((b >> 24) & 0xFF)) & 0xFF;
    const r = (((a >> 16) & 0xFF) + ((b >> 16) & 0xFF)) & 0xFF;
    const g = (((a >> 8) & 0xFF) + ((b >> 8) & 0xFF)) & 0xFF;
    const bl = ((a & 0xFF) + (b & 0xFF)) & 0xFF;
    return (alpha << 24) | (r << 16) | (g << 8) | bl;
}

fn average2(a0: u32, a1: u32) u32 {
    return (((a0 ^ a1) & 0xFEFEFEFE) >> 1) + (a0 & a1);
}

fn average3(a0: u32, a1: u32, a2: u32) u32 {
    return average2(average2(a0, a2), a1);
}

fn average4(a0: u32, a1: u32, a2: u32, a3: u32) u32 {
    return average2(average2(a0, a1), average2(a2, a3));
}

fn clip255(a: i32) u32 {
    if (a < 0) return 0;
    if (a > 255) return 255;
    return @intCast(a);
}

fn clampedAddSubtractFull(c0: u32, c1: u32, c2: u32) u32 {
    const a = clip255(@as(i32, @intCast((c0 >> 24) & 0xFF)) + @as(i32, @intCast((c1 >> 24) & 0xFF)) - @as(i32, @intCast((c2 >> 24) & 0xFF)));
    const r = clip255(@as(i32, @intCast((c0 >> 16) & 0xFF)) + @as(i32, @intCast((c1 >> 16) & 0xFF)) - @as(i32, @intCast((c2 >> 16) & 0xFF)));
    const g = clip255(@as(i32, @intCast((c0 >> 8) & 0xFF)) + @as(i32, @intCast((c1 >> 8) & 0xFF)) - @as(i32, @intCast((c2 >> 8) & 0xFF)));
    const b = clip255(@as(i32, @intCast(c0 & 0xFF)) + @as(i32, @intCast(c1 & 0xFF)) - @as(i32, @intCast(c2 & 0xFF)));
    return (a << 24) | (r << 16) | (g << 8) | b;
}

fn addSubtractComponentHalf(a: i32, b: i32) u32 {
    // C: Clip255(a + (a - b) / 2) — integer division truncates toward 0.
    return clip255(a + @divTrunc(a - b, 2));
}

fn clampedAddSubtractHalf(c0: u32, c1: u32, c2: u32) u32 {
    const ave = average2(c0, c1);
    const a = addSubtractComponentHalf(@intCast((ave >> 24) & 0xFF), @intCast((c2 >> 24) & 0xFF));
    const r = addSubtractComponentHalf(@intCast((ave >> 16) & 0xFF), @intCast((c2 >> 16) & 0xFF));
    const g = addSubtractComponentHalf(@intCast((ave >> 8) & 0xFF), @intCast((c2 >> 8) & 0xFF));
    const b = addSubtractComponentHalf(@intCast(ave & 0xFF), @intCast(c2 & 0xFF));
    return (a << 24) | (r << 16) | (g << 8) | b;
}

fn sub3(a: i32, b: i32, c: i32) i32 {
    const pb: i32 = b - c;
    const pa: i32 = a - c;
    const apb: i32 = if (pb < 0) -pb else pb;
    const apa: i32 = if (pa < 0) -pa else pa;
    return apb - apa;
}

fn selectPredictor(a: u32, b: u32, c: u32) u32 {
    const pa_minus_pb =
        sub3(@intCast((a >> 24) & 0xFF), @intCast((b >> 24) & 0xFF), @intCast((c >> 24) & 0xFF)) +
        sub3(@intCast((a >> 16) & 0xFF), @intCast((b >> 16) & 0xFF), @intCast((c >> 16) & 0xFF)) +
        sub3(@intCast((a >> 8) & 0xFF), @intCast((b >> 8) & 0xFF), @intCast((c >> 8) & 0xFF)) +
        sub3(@intCast(a & 0xFF), @intCast(b & 0xFF), @intCast(c & 0xFF));
    return if (pa_minus_pb <= 0) a else b;
}

/// The 14 spatial predictors. Neighbor pixels:
///   left = argb[li], top = argb[ti], top_right = argb[tri], top_left = argb[tli]
fn predict(mode: u32, argb: []const u32, li: usize, ti: usize, tri: usize, tli: usize, x: u32, width: u32) u32 {
    _ = x;
    _ = width;
    const left = argb[li];
    const top = argb[ti];
    return switch (mode) {
        0 => argb_black,
        1 => left,
        2 => top,
        3 => argb[tri],
        4 => argb[tli],
        5 => average3(left, top, argb[tri]),
        6 => average2(left, argb[tli]),
        7 => average2(left, top),
        8 => average2(argb[tli], top),
        9 => average2(top, argb[tri]),
        10 => average4(left, argb[tli], top, argb[tri]),
        11 => selectPredictor(top, left, argb[tli]),
        12 => clampedAddSubtractFull(left, top, argb[tli]),
        13 => clampedAddSubtractHalf(left, top, argb[tli]),
        else => argb_black,
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "vp8l: RIFF rejection" {
    var buf: [24]u8 = .{0} ** 24;
    try testing.expectError(DecodeError.BadRiff, decode(testing.allocator, &buf));
    const not_webp = "RIFF1234WAVEjunkjunkjunkjunk";
    try testing.expectError(DecodeError.BadRiff, decode(testing.allocator, not_webp));
}

test "vp8l: bit reader LSB-first order" {
    // 0b00000110 = 0x06: first bit = 0, second = 1, third = 1, then 0s
    var br = BitReader.init(&[_]u8{0x06});
    try testing.expectEqual(@as(u1, 0), try br.readBit());
    try testing.expectEqual(@as(u1, 1), try br.readBit());
    try testing.expectEqual(@as(u1, 1), try br.readBit());
    try testing.expectEqual(@as(u1, 0), try br.readBit());
    // 5 bits of 0x06 = 0b00110 read LSB-first as value 6
    var br2 = BitReader.init(&[_]u8{0x06});
    try testing.expectEqual(@as(u32, 6), try br2.readBits(5));
}

test "vp8l: huffman canonical build and read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // codes: A len 1, B len 2, C len 2 → canonical: A=0, B=10, C=11
    // stream bits: 0 (A), 1 0 (B), 1 1 (C) → LSB-first bytes: 0b0, then 01, then 11...
    var lengths: [4]u32 = .{ 1, 2, 2, 0 };
    const table = try HuffTable.build(a, &lengths, 4);
    // A: code 0 (len 1) reversed 0 → fast[0] and fast[1]
    // B: code 2 (10) reversed (01) len 2 → fast[1] (already A) hmm —
    // canonical assignment order: symbol order within length: A(1),B(2),C(3)
    // A=code 0 len 1; B=code 2 (0b10) len 2; C=code 3 (0b11) len 2.
    // reversed: B=0b01, C=0b11.
    // table size 2 (root_bits = max_len 2? root_bits = min(max_len,15)=2 → 4 entries)
    var br = BitReader.init(&[_]u8{ 0b0000_0110, 0b1000_0000 });
    // bits: 0,1,1,0,0,0,0,0, 0,0,0,0,0,0,0,1
    // stream bits (LSB first): 0,1,1,0,0,0,0,0 | 0,0,0,0,0,0,0,1
    // A: bit0=0 → fast[0] → A (len 1)
    try testing.expectEqual(@as(u32, 0), try table.readSymbol(&br));
    // bits 1,1 → peek value 0b11 = 3 → C (code 11)
    try testing.expectEqual(@as(u32, 2), try table.readSymbol(&br));
    // bits 0,0 → peek value 0 → A again (code 0, 1 bit)
    try testing.expectEqual(@as(u32, 0), try table.readSymbol(&br));
    // B: canonical code 0b10 (MSB-first) → stream bits 1,0 → peek value
    // = 1<<0 | 0<<1 = 1 → fast[1] = B (len 2).
    var br_b = BitReader.init(&[_]u8{0b0000_0001}); // bits: 1,0,...
    try testing.expectEqual(@as(u32, 1), try table.readSymbol(&br_b));
    }

// The real-image validation tests live in scripts/vp8l_check.py +
// the boot smoke (decode the title sheet); unit battery stays hermetic.
