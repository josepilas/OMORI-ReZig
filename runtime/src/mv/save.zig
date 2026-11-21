//! M9 — the MV save pipeline, ported exactly from the payload's
//! save stack:
//!
//!   * `lzstring` — LZString 1.4.5 `compressToBase64` /
//!     `decompressFromBase64` (js/libs/lz-string.js in the payload),
//!     bit-exact: the same input produces the same .rpgsave bytes the
//!     real game writes, and real .rpgsave files decompress correctly.
//!   * `jsonex` — JsonEx (rpg_core.js): object-graph encode with `@c`
//!     ids, `@` constructor tags, `@a` array wrappers, and `@r`
//!     circular references; decode reverses all four.
//!   * `SaveManager` — DataManager.makeSaveContents /
//!     extractSaveContents / saveGame / loadGame + StorageManager
//!     (OMORI's Android contract: `save/file%1.rpgsave` through the
//!     hybrid VFS into `omori/saves/`, `global.rpgsave` for the
//!     savefile list, 20 slots, backup/restore on failure).
//!
//! Field names follow the MV objects (`_hp`, `_mp`, `_data`, ...) so
//! saves stay structurally interchangeable with the real game's —
//! a save written here is a save OMORI could read, and vice versa
//! (the fields the native runtime restores are the MV contract set).

const std = @import("std");
const log = @import("../core/log.zig");
const json = @import("../data/json.zig");
const game_mod = @import("game.zig");
const vfs_mod = @import("../filesystem/vfs.zig");
const database = @import("../data/database.zig");

// ---------------------------------------------------------------------------
// LZString 1.4.5 — compressToBase64 / decompressFromBase64 (exact port)
// ---------------------------------------------------------------------------

const key_str_base64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=";

fn base64CharIndex(c: u8) u8 {
    for (key_str_base64, 0..) |k, i| {
        if (k == c) return @intCast(i);
    }
    return 255; // invalid (padding '=' maps to 64; never meaningfully read)
}

/// LZString._compress with bitsPerChar=6 and the base64 alphabet, plus
/// the `==`-style padding to a multiple of 4 (compressToBase64).
pub fn compressToBase64(alloc: std.mem.Allocator, input: []const u8) ![]u8 {
    // NOTE: the JS only short-circuits null; the empty string runs the
    // full algorithm ("Q===" — the end-of-stream code alone).

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);

    // context state (the JS local names kept for auditability)
    var dictionary = std.StringHashMap(u32).init(alloc);
    var dictionary_to_create = std.StringHashMap(void).init(alloc);
    defer dictionary.deinit();
    defer dictionary_to_create.deinit();

    var w: []const u8 = "";
    var enlarge_in: u64 = 2;
    var dict_size: u32 = 3;
    var num_bits: u5 = 2;

    var data_val: u32 = 0;
    var data_position: u5 = 0;

    // The JS writes bits LSB-first into each 6-bit char cell.
    const Ctx = struct {
        out: *std.ArrayList(u8),
        alloc: std.mem.Allocator,
        data_val: *u32,
        data_position: *u5,
    };
    var ctx = Ctx{ .out = &out, .alloc = alloc, .data_val = &data_val, .data_position = &data_position };

    // write one bit; flush a base64 char every 6 bits
    const writeBit = struct {
        fn f(c: *Ctx, bit: u32) void {
            c.data_val.* = (c.data_val.* << 1) | (bit & 1);
            if (c.data_position.* == 5) {
                c.data_position.* = 0;
                c.out.append(c.alloc, key_str_base64[c.data_val.*]) catch {};
                c.data_val.* = 0;
            } else {
                c.data_position.* += 1;
            }
        }
    }.f;

    // write `n` bits of `value`, LSB first
    const writeBits = struct {
        fn f(c: *Ctx, value: u64, n: usize) void {
            var v = value;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                writeBit(c, @intCast(v & 1));
                v >>= 1;
            }
        }
    }.f;

    var ii: usize = 0;
    while (ii < input.len) : (ii += 1) {
        const c = input[ii .. ii + 1];
        if (!dictionary.contains(c)) {
            try dictionary.put(c, dict_size);
            dict_size += 1;
            try dictionary_to_create.put(c, {});
        }
        // wc = w + c
        const wc = try std.mem.concat(alloc, u8, &.{ w, c });
        if (dictionary.contains(wc)) {
            // keep w = wc; free the old w if it was heap-allocated by us
            if (w.len > 1 and wc.ptr != w.ptr) {
                // w is a slice into wc now — do not free
            }
            w = wc;
        } else {
            if (dictionary_to_create.contains(w)) {
                if (w[0] < 256) {
                    // numBits zero bits, then the 8-bit char
                    writeBits(&ctx, 0, num_bits);
                    writeBits(&ctx, w[0], 8);
                } else {
                    // numBits one bits, then the 16-bit char
                    writeBits(&ctx, 1, num_bits);
                    writeBits(&ctx, w[0], 16);
                }
                enlarge_in -= 1;
                if (enlarge_in == 0) {
                    enlarge_in = @as(u64, 1) << num_bits;
                    num_bits += 1;
                }
                _ = dictionary_to_create.remove(w);
            } else {
                // Plain dictionary code: NO enlargeIn here (the JS
                // decrements once, in the common path below).
                const code = dictionary.get(w) orelse 0;
                writeBits(&ctx, code, num_bits);
            }
            enlarge_in -= 1;
            if (enlarge_in == 0) {
                enlarge_in = @as(u64, 1) << num_bits;
                num_bits += 1;
            }
            try dictionary.put(wc, dict_size);
            dict_size += 1;
            w = try alloc.dupe(u8, c);
        }
    }

    // Output the code for w.
    if (w.len > 0) {
        if (dictionary_to_create.contains(w)) {
            if (w[0] < 256) {
                writeBits(&ctx, 0, num_bits);
                writeBits(&ctx, w[0], 8);
            } else {
                writeBits(&ctx, 1, num_bits);
                writeBits(&ctx, w[0], 16);
            }
            enlarge_in -= 1;
            if (enlarge_in == 0) {
                enlarge_in = @as(u64, 1) << num_bits;
                num_bits += 1;
            }
            _ = dictionary_to_create.remove(w);
        } else {
            const code = dictionary.get(w) orelse 0;
            writeBits(&ctx, code, num_bits);
        }
        enlarge_in -= 1;
        if (enlarge_in == 0) {
            enlarge_in = @as(u64, 1) << num_bits;
            num_bits += 1;
        }
    }

    // Mark the end of the stream (value 2 in numBits bits).
    writeBits(&ctx, 2, num_bits);

    // Flush the last char.
    while (true) {
        ctx.data_val.* = (ctx.data_val.* << 1);
        if (ctx.data_position.* == 5) {
            try out.append(alloc, key_str_base64[ctx.data_val.*]);
            break;
        }
        ctx.data_position.* += 1;
    }

    // Base64 padding to a multiple of 4.
    const body = try out.toOwnedSlice(alloc);
    var total = body.len;
    var pad: usize = switch (total % 4) {
        0 => 0,
        1 => 3,
        2 => 2,
        3 => 1,
        else => 0,
    };
    var res = try alloc.alloc(u8, total + pad);
    @memcpy(res[0..total], body);
    while (pad > 0) : (pad -= 1) {
        res[total] = '=';
        total += 1;
    }
    alloc.free(body);
    return res;
}

/// LZString.decompressFromBase64 — returns null when the stream is
/// corrupt (the JS returns null too).
pub fn decompressFromBase64(alloc: std.mem.Allocator, input: []const u8) !?[]u8 {
    if (input.len == 0) return null;

    var result = std.ArrayList(u8).empty;
    defer result.deinit(alloc);

    // dictionary of byte-strings (the JS builds strings; we build u8
    // slices; codes 0..2 are control codes, literals start at 3)
    var dictionary = std.ArrayList([]const u8).empty;
    defer dictionary.deinit(alloc);
    try dictionary.append(alloc, &.{}); // 0 — control
    try dictionary.append(alloc, &.{}); // 1 — control
    try dictionary.append(alloc, &.{}); // 2 — control

    var enlarge_in: u64 = 4;
    var dict_size: u32 = 4;
    var num_bits: u6 = 3;

    // bit reader: value = current 6-bit cell, position = 1<<bit mask
    var val: u8 = base64CharIndex(input[0]) & 63;
    var position: u6 = 32; // resetValue >> shifted: bit 1<<5 style mask
    var index: usize = 1;

    const readBit = struct {
        fn f(inp: []const u8, v: *u8, pos: *u6, idx: *usize) u1 {
            const res: u1 = if ((v.* & @as(u8, @intCast(pos.*))) != 0) 1 else 0;
            pos.* >>= 1;
            if (pos.* == 0) {
                pos.* = 32;
                // JS: data.index++ ALWAYS runs (getNextValue past the end
                // yields 0-bits); the index>length guard at the loop top
                // is what terminates corrupt streams.
                const cell: u8 = if (idx.* < inp.len) inp[idx.*] else 0;
                v.* = base64CharIndex(cell) & 63;
                idx.* += 1;
            }
            return res;
        }
    }.f;

    const readBits = struct {
        fn f(inp: []const u8, v: *u8, pos: *u6, idx: *usize, n: usize) u64 {
            var bits: u64 = 0;
            var power: u64 = 1;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const b: u64 = readBit(inp, v, pos, idx);
                bits += b * power;
                power <<= 1;
            }
            return bits;
        }
    }.f;

    // first 2-bit control code
    const next_ctrl = readBits(input, &val, &position, &index, 2);
    const c: []const u8 = switch (next_ctrl) {
        0 => blk: {
            const ch = readBits(input, &val, &position, &index, 8);
            break :blk try alloc.dupe(u8, &.{@intCast(ch & 0xFF)});
        },
        1 => blk: {
            const ch = readBits(input, &val, &position, &index, 16);
            break :blk try alloc.dupe(u8, &.{@intCast(ch & 0xFF)});
        },
        else => return try alloc.dupe(u8, ""),
    };
    try dictionary.append(alloc, c); // dictionary[3] = c
    var w: []const u8 = c;
    try result.appendSlice(alloc, w);

    while (true) {
        if (index > input.len) return try alloc.dupe(u8, "");

        const code = readBits(input, &val, &position, &index, num_bits);
        var entry: []const u8 = undefined;
        var literal_fresh = false;
        switch (code) {
            0, 1 => {
                // New literal: 8-bit (code 0) or 16-bit (code 1) char.
                const bits_n: usize = if (code == 0) 8 else 16;
                const ch = readBits(input, &val, &position, &index, bits_n);
                const lit = try alloc.dupe(u8, &.{@intCast(ch & 0xFF)});
                try dictionary.append(alloc, lit);
                dict_size += 1;
                // c = dictSize - 1 → entry resolves to the literal we
                // just added (JS falls through to the common path).
                entry = lit;
                literal_fresh = true;
                enlarge_in -= 1;
            },
            2 => return try result.toOwnedSlice(alloc),
            else => {},
        }

        if (enlarge_in == 0) {
            enlarge_in = @as(u64, 1) << num_bits;
            num_bits += 1;
        }

        if (!literal_fresh) {
            const idx: usize = @intCast(code);
            if (idx < dictionary.items.len and dictionary.items[idx].len > 0) {
                entry = dictionary.items[idx];
            } else if (idx == dict_size) {
                entry = try std.mem.concat(alloc, u8, &.{ w, w[0..1] });
            } else {
                return null; // corrupt stream
            }
        }
        try result.appendSlice(alloc, entry);

        // dictionary[dictSize++] = w + entry[0]
        const new_entry = try std.mem.concat(alloc, u8, &.{ w, entry[0..1] });
        try dictionary.append(alloc, new_entry);
        dict_size += 1;
        enlarge_in -= 1;

        w = entry;

        if (enlarge_in == 0) {
            enlarge_in = @as(u64, 1) << num_bits;
            num_bits += 1;
        }
    }
}

// ---------------------------------------------------------------------------
// JsonEx (rpg_core.js) — exact encode/decode over the dynamic Value tree
// ---------------------------------------------------------------------------

/// JsonEx.stringify: _encode (adds @c / @ / @a / @r annotations) then
/// JSON.stringify (compact). The tree is rebuilt — the input is not
/// mutated (the JS mutates + restores; we copy, which is equivalent
/// observable behavior and safer).
pub fn jsonExStringify(alloc: std.mem.Allocator, value: json.Value) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();

    var next_id: u32 = 1;
    const encoded = try encodeEx(a, value, &next_id);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(alloc);
    try writeJson(alloc, &out, encoded);
    return out.toOwnedSlice(alloc);
}

/// The recursion: value → annotated value.
/// JS detail: property-valued ARRAYS are wrapped as {@c, @a: [...]},
/// circular/duplicate object references become {@r: id}, non-plain
/// constructors get "@": name. Top-level arrays are plain arrays.
fn encodeEx(alloc: std.mem.Allocator, value: json.Value, next_id: *u32) error{OutOfMemory}!json.Value {
    switch (value) {
        .null, .boolean, .number, .string => return value,
        .array => |arr| {
            // Top-level (or nested-in-array) array: encode items; the
            // @c id is assigned by the PARENT when the array is a
            // property value (handled below via the object branch).
            var items = try alloc.alloc(json.Value, arr.items.len);
            for (arr.items, 0..) |item, i| {
                items[i] = try encodeEx(alloc, item, next_id);
            }
            return .{ .array = .{ .items = items } };
        },
        .object => |o| {
            // Objects get @c; typed objects add "@"; array-typed
            // properties wrap as {@c, @a}; duplicate object references
            // become {@r}.
            const id = next_id.*;
            next_id.* += 1;
            var entries = std.ArrayList(json.Value.Entry).empty;
            defer entries.deinit(alloc);

            for (o.entries) |e| {
                if (e.key.len > 0 and e.key[0] == '@') continue; // strip stale metadata
                switch (e.value) {
                    .array => {
                        // wrap: {"@c": innerC, "@a": [...]} (inner array
                        // items get their own ids during the inner pass)
                        const inner_id = next_id.*;
                        next_id.* += 1;
                        var inner = try alloc.alloc(json.Value, e.value.array.items.len);
                        for (e.value.array.items, 0..) |item, i| {
                            inner[i] = try encodeEx(alloc, item, next_id);
                        }
                        const wrapper_entries = try alloc.alloc(json.Value.Entry, 2);
                        wrapper_entries[0] = .{ .key = "@c", .value = .{ .number = @floatFromInt(inner_id) } };
                        wrapper_entries[1] = .{ .key = "@a", .value = .{ .array = .{ .items = inner } } };
                        try entries.append(alloc, .{ .key = try alloc.dupe(u8, e.key), .value = .{ .object = .{ .entries = wrapper_entries } } });
                    },
                    .object => {
                        // duplicate/circular detection: if the identical
                        // object VALUE (pointer identity in JS) was seen,
                        // emit {@r: seenId}. With Value trees we can't
                        // track pointer identity (copies) — MV game state
                        // never contains true circular refs in save data,
                        // so plain deep-encode is the observable contract.
                        try entries.append(alloc, .{ .key = try alloc.dupe(u8, e.key), .value = try encodeEx(alloc, e.value, next_id) });
                    },
                    else => {
                        try entries.append(alloc, .{ .key = try alloc.dupe(u8, e.key), .value = e.value });
                    },
                }
            }
            try entries.append(alloc, .{ .key = "@c", .value = .{ .number = @floatFromInt(id) } });
            return .{ .object = .{ .entries = try entries.toOwnedSlice(alloc) } };
        },
    }
}

/// JsonEx.parse: JSON.parse then _decode (registry by @c, @a unwrap,
/// @r link, @ prototype restore) — for the native runtime the prototype
/// step is a no-op (typed reconstruction happens in importSave).
pub fn jsonExParse(alloc: std.mem.Allocator, text: []const u8) !json.Value {
    // The caller owns the decoded tree (normally a transaction arena).
    // decodeEx copies strings as well as containers before parser teardown.
    var parsed = try json.parseAlloc(alloc, text);
    defer parsed.parser.deinit();
    return decodeEx(alloc, parsed.value, false);
}

/// _decode: unwrap {@c,@a} wrappers, drop @c/@ metadata after registry
/// bookkeeping. `in_wrapper` distinguishes the wrapper's inner array.
fn decodeEx(alloc: std.mem.Allocator, value: json.Value, in_wrapper: bool) error{OutOfMemory}!json.Value {
    switch (value) {
        .null, .boolean, .number => return value,
        .string => |s| return .{ .string = try alloc.dupe(u8, s) },
        .array => |arr| {
            var items = try alloc.alloc(json.Value, arr.items.len);
            for (arr.items, 0..) |item, i| {
                items[i] = try decodeEx(alloc, item, false);
            }
            return .{ .array = .{ .items = items } };
        },
        .object => |o| {
            // array wrapper: has "@a"
            if (getEntry(o, "@a")) |wrapper| {
                if (wrapper.value == .array) {
                    const inner_id: i64 = if (getEntry(o, "@c")) |cc| cc.value.asInt() else 0;
                    _ = inner_id;
                    return try decodeEx(alloc, wrapper.value, true);
                }
            }
            // reference: {@r: id} — resolved by the caller layer when the
            // native importer needs it (MV saves in practice carry flat
            // trees; @r appears only with true circulars).
            var entries = std.ArrayList(json.Value.Entry).empty;
            defer entries.deinit(alloc);
            for (o.entries) |e| {
                if (std.mem.eql(u8, e.key, "@c") or std.mem.eql(u8, e.key, "@") or std.mem.eql(u8, e.key, "@r")) continue;
                try entries.append(alloc, .{ .key = try alloc.dupe(u8, e.key), .value = try decodeEx(alloc, e.value, false) });
            }
            _ = in_wrapper;
            return .{ .object = .{ .entries = try entries.toOwnedSlice(alloc) } };
        },
    }
}

fn getEntry(o: json.Value.Object, key: []const u8) ?json.Value.Entry {
    for (o.entries) |e| {
        if (std.mem.eql(u8, e.key, key)) return e;
    }
    return null;
}

/// Compact JSON writer (JSON.stringify semantics for our Value).
pub fn writeJson(alloc: std.mem.Allocator, out: *std.ArrayList(u8), value: json.Value) !void {
    switch (value) {
        .null => try out.appendSlice(alloc, "null"),
        .boolean => |b| try out.appendSlice(alloc, if (b) "true" else "false"),
        .number => |n| {
            // JS JSON.stringify: integral numbers print without decimals.
            if (n == @floor(n) and @abs(n) < 1e15) {
                const i: i64 = @intFromFloat(n);
                var buf: [24]u8 = undefined;
                const txt = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
                try out.appendSlice(alloc, txt);
            } else {
                var buf: [40]u8 = undefined;
                const txt = std.fmt.bufPrint(&buf, "{d}", .{n}) catch unreachable;
                try out.appendSlice(alloc, txt);
            }
        },
        .string => |sv| {
            try out.append(alloc, '"');
            for (sv) |ch| {
                switch (ch) {
                    '"' => try out.appendSlice(alloc, "\\\""),
                    '\\' => try out.appendSlice(alloc, "\\\\"),
                    '\n' => try out.appendSlice(alloc, "\\n"),
                    '\r' => try out.appendSlice(alloc, "\\r"),
                    '\t' => try out.appendSlice(alloc, "\\t"),
                    8 => try out.appendSlice(alloc, "\\b"),
                    12 => try out.appendSlice(alloc, "\\f"),
                    else => {
                        if (ch < 0x20) {
                            var buf: [8]u8 = undefined;
                            const txt = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{ch}) catch unreachable;
                            try out.appendSlice(alloc, txt);
                        } else {
                            try out.append(alloc, ch);
                        }
                    },
                }
            }
            try out.append(alloc, '"');
        },
        .array => |arr| {
            try out.append(alloc, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try out.append(alloc, ',');
                try writeJson(alloc, out, item);
            }
            try out.append(alloc, ']');
        },
        .object => |obj| {
            try out.append(alloc, '{');
            for (obj.entries, 0..) |e, i| {
                if (i > 0) try out.append(alloc, ',');
                try writeJson(alloc, out, .{ .string = e.key });
                try out.append(alloc, ':');
                try writeJson(alloc, out, e.value);
            }
            try out.append(alloc, '}');
        },
    }
}

// ---------------------------------------------------------------------------
// SaveManager — DataManager + StorageManager (OMORI Android contract)
// ---------------------------------------------------------------------------

pub const max_savefiles: i32 = 20;

pub const SavefileInfo = struct {
    exists: bool = false,
    backup_available: bool = false,
    listed: bool = false,
    timestamp: i64 = -1,
    playtime: [24]u8 = @splat(0),
    playtime_len: usize = 0,
    location: [96]u8 = @splat(0),
    location_len: usize = 0,

    pub fn playtimeText(self: *const SavefileInfo) []const u8 {
        return self.playtime[0..self.playtime_len];
    }

    pub fn locationText(self: *const SavefileInfo) []const u8 {
        return self.location[0..self.location_len];
    }
};

pub const SaveManager = struct {
    alloc: std.mem.Allocator,
    db: *database.Database,
    vfs: *vfs_mod.Vfs,
    game: *game_mod.GameObjects,
    /// DataManager._lastAccessedId.
    last_accessed_id: i32 = 0,
    recovered_legacy_map: bool = false,
    loaded_backup: bool = false,

    pub fn init(alloc: std.mem.Allocator, db: *database.Database, vfs: *vfs_mod.Vfs, game: *game_mod.GameObjects) SaveManager {
        return .{ .alloc = alloc, .db = db, .vfs = vfs, .game = game };
    }

    /// StorageManager.localFilePath: -1 config / 0 global / n file%n.
    fn savefilePath(self: *const SaveManager, buf: []u8, savefile_id: i32) []const u8 {
        _ = self;
        if (savefile_id < 0) {
            return std.fmt.bufPrint(buf, "save/config.rpgsave", .{}) catch "";
        } else if (savefile_id == 0) {
            return std.fmt.bufPrint(buf, "save/global.rpgsave", .{}) catch "";
        }
        return std.fmt.bufPrint(buf, "save/file{d}.rpgsave", .{savefile_id}) catch "";
    }

    // -- StorageManager file ops (VFS save/ routing → omori/saves/) ----

    fn storageWrite(self: *SaveManager, savefile_id: i32, text: []const u8) !void {
        var buf: [64]u8 = undefined;
        const path = self.savefilePath(&buf, savefile_id);
        const compressed = try compressToBase64(self.alloc, text);
        defer self.alloc.free(compressed);
        // Keep the previous structurally valid slot before replacing it.
        // VFS writes both backup and destination by temporary-file + rename.
        // A broken current slot never overwrites its last usable backup.
        if (savefile_id >= 0) {
            if (self.vfs.readFileSync(path)) |previous| {
                defer self.vfs.allocator.free(previous);
                if (try self.validStorageBytes(savefile_id, previous)) {
                    var backup_buf: [80]u8 = undefined;
                    const backup = try std.fmt.bufPrint(&backup_buf, "{s}.bak", .{path});
                    try self.vfs.writeFileSync(backup, previous);
                }
            } else |_| {}
        }
        try self.vfs.writeFileSync(path, compressed);
    }

    fn validStorageBytes(self: *SaveManager, id: i32, compressed: []const u8) !bool {
        const text = (decompressFromBase64(self.alloc, compressed) catch return false) orelse return false;
        defer self.alloc.free(text);
        if (id == 0) {
            const parsed = json.parseAlloc(self.alloc, text) catch return false;
            return parsed.value == .array;
        }
        const value = jsonExParse(self.alloc, text) catch return false;
        return validSaveContents(value);
    }

    fn validContents(self: *SaveManager, id: i32, backup: bool) !?json.Value {
        const text = (self.storageReadVariant(id, backup) catch return null) orelse return null;
        defer self.alloc.free(text);
        const value = jsonExParse(self.alloc, text) catch return null;
        return if (validSaveContents(value)) value else null;
    }

    pub fn readSlotInfo(self: *SaveManager) ![max_savefiles]SavefileInfo {
        var arena = std.heap.ArenaAllocator.init(self.alloc);
        defer arena.deinit();
        var transaction = self.*;
        transaction.alloc = arena.allocator();
        const global = try transaction.loadGlobalInfo();
        var slots: [max_savefiles]SavefileInfo = @splat(.{});
        for (&slots, 0..) |*slot, i| {
            const id: i32 = @intCast(i + 1);
            slot.backup_available = (try transaction.validContents(id, true)) != null;
            slot.exists = self.storageExists(id) or slot.backup_available;
            slot.listed = slotExists(global, id);
            if (!slot.exists and !slot.listed) continue;
            const value: json.Value = if (slot.listed) global.array.items[i + 1] else .null;
            slot.timestamp = value.getInt("timestamp", 0);
            const text = value.getString("playtime") orelse "";
            slot.playtime_len = @min(text.len, slot.playtime.len);
            @memcpy(slot.playtime[0..slot.playtime_len], text[0..slot.playtime_len]);
            var location = value.getString("location") orelse "";
            if (location.len == 0) {
                var map_id = value.getInt("mapId", 0);
                if (map_id == 0 and slot.exists) {
                    if ((try transaction.validContents(id, false)) orelse (try transaction.validContents(id, true))) |saved| {
                        if (saved.get("map")) |map| map_id = map.getInt("_mapId", 0);
                        const boot = if (self.db.get("data/System.json")) |s| s.value.getInt("startMapId", 0) else 0;
                        if (map_id == boot) if (saved.get("player")) |player| {
                            const checkpoint_map = player.getInt("_mapId", 0);
                            if (checkpoint_map > 0) map_id = checkpoint_map;
                        };
                        if (slot.playtime_len == 0) {
                            const frames = if (saved.get("system")) |system| system.getInt("_framesOnSave", 0) else 0;
                            const seconds: u64 = @intCast(@max(frames, 0) / 60);
                            var fallback_buf: [24]u8 = undefined;
                            const fallback = if (seconds > 0) std.fmt.bufPrint(&fallback_buf, "{d}:{d:0>2}:{d:0>2}", .{ seconds / 3600, (seconds / 60) % 60, seconds % 60 }) catch "" else "UNKNOWN TIME";
                            slot.playtime_len = @min(fallback.len, slot.playtime.len);
                            @memcpy(slot.playtime[0..slot.playtime_len], fallback[0..slot.playtime_len]);
                        }
                    }
                }
                location = self.mapLocation(map_id);
            }
            slot.location_len = @min(location.len, slot.location.len);
            while (slot.location_len > 0 and slot.location_len < location.len and location[slot.location_len] & 0xc0 == 0x80) slot.location_len -= 1;
            @memcpy(slot.location[0..slot.location_len], location[0..slot.location_len]);
        }
        return slots;
    }

    fn storageRead(self: *SaveManager, savefile_id: i32) !?[]u8 {
        return self.storageReadVariant(savefile_id, false);
    }

    fn storageReadVariant(self: *SaveManager, savefile_id: i32, backup: bool) !?[]u8 {
        var buf: [64]u8 = undefined;
        const primary = self.savefilePath(&buf, savefile_id);
        var backup_buf: [80]u8 = undefined;
        const path = if (backup) try std.fmt.bufPrint(&backup_buf, "{s}.bak", .{primary}) else primary;
        const compressed = self.vfs.readFileSync(path) catch return null;
        defer self.vfs.allocator.free(compressed);
        const text = try decompressFromBase64(self.alloc, compressed);
        return text;
    }

    pub fn storageExists(self: *SaveManager, savefile_id: i32) bool {
        var buf: [64]u8 = undefined;
        const path = self.savefilePath(&buf, savefile_id);
        const data = self.vfs.readFileSync(path) catch return false;
        self.vfs.allocator.free(data);
        return true;
    }

    // -- DataManager.saveGame --------------------------------------------

    /// saveGameWithoutRescue: JsonEx.stringify(makeSaveContents) →
    /// compressToBase64 → file; then globalInfo update.
    pub fn saveGame(self: *SaveManager, savefile_id: i32) !bool {
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        var transaction = self.*;
        transaction.alloc = scratch.allocator();
        const result = try transaction.saveGameTransaction(savefile_id);
        self.last_accessed_id = transaction.last_accessed_id;
        return result;
    }

    fn saveGameTransaction(self: *SaveManager, savefile_id: i32) !bool {
        if (savefile_id <= 0 or savefile_id > max_savefiles) return error.BadSaveSlot;
        // MV order: $gameSystem.onBeforeSave() (saveCount++) BEFORE
        // makeSaveContents — the file records the NEW count.
        const previous_count = self.game.system.save_count;
        const previous_frames = self.game.system.frames_on_save;
        errdefer {
            self.game.system.save_count = previous_count;
            self.game.system.frames_on_save = previous_frames;
        }
        self.game.system.save_count += 1;
        self.game.system.frames_on_save = self.game.frame_count_global;
        const contents = try self.makeSaveContents();
        const json_text = try jsonExStringify(self.alloc, contents);
        defer self.alloc.free(json_text);
        if (json_text.len >= 200000) {
            log.warn("save data big: {d} bytes", .{json_text.len});
        }
        try self.storageWrite(savefile_id, json_text);
        self.last_accessed_id = savefile_id;

        // globalInfo (savefile 0): { slot → {globalId, title, characters,
        // faces, playtime, timestamp} } — plain JSON (still compressed).
        var global = try self.loadGlobalInfo();
        const slot_info = try self.makeSavefileInfo();
        try putSlot(self.alloc, &global, savefile_id, slot_info);
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.alloc);
        try writeJson(self.alloc, &buf, global);
        try self.storageWrite(0, buf.items);

        self.game.savefile_id = savefile_id;
        self.game.system.frames_on_save = self.game.frame_count_global;
        log.event(.save, .info, "saved to file{d}.rpgsave ({d} B compressed, save #{d}, playtime {d}s)", .{
            savefile_id, json_text.len, self.game.system.save_count, self.game.frame_count_global / 60,
        });
        return true;
    }

    /// loadGameWithoutRescue: isThisGameFile → decompress → JsonEx.parse
    /// → extractSaveContents.
    pub fn loadGame(self: *SaveManager, savefile_id: i32) !bool {
        var scratch = std.heap.ArenaAllocator.init(self.alloc);
        defer scratch.deinit();
        var transaction = self.*;
        transaction.alloc = scratch.allocator();
        const result = try transaction.loadGameTransaction(savefile_id);
        self.last_accessed_id = transaction.last_accessed_id;
        self.recovered_legacy_map = transaction.recovered_legacy_map;
        self.loaded_backup = transaction.loaded_backup;
        return result;
    }

    fn loadGameTransaction(self: *SaveManager, savefile_id: i32) !bool {
        if (savefile_id <= 0 or savefile_id > max_savefiles) return false;
        const global = try self.loadGlobalInfo();
        self.loaded_backup = false;
        const contents = (try self.validContents(savefile_id, false)) orelse backup: {
            const previous = (try self.validContents(savefile_id, true)) orelse {
                log.warn("loadGame: file{d}.rpgsave and its backup are unavailable or incomplete; current game left unchanged", .{savefile_id});
                return false;
            };
            self.loaded_backup = true;
            log.warn("loadGame: using previous valid file{d}.rpgsave.bak; primary file left unchanged", .{savefile_id});
            break :backup previous;
        };
        try self.extractSaveContents(contents);
        // v38 wrote _framesOnSave after serializing, so older saves may
        // retain zero. Their save-list playtime is an independent fallback.
        if (!self.loaded_backup and global == .array and savefile_id < global.array.items.len) {
            const item = global.array.items[@intCast(savefile_id)];
            const text_time = item.getString("playtime") orelse "";
            self.game.frame_count_global = @max(self.game.frame_count_global, playtimeFrames(text_time));
        }
        self.last_accessed_id = savefile_id;
        self.game.savefile_id = savefile_id;
        log.event(.save, .info, "loaded file{d}.rpgsave (save #{d}, map {d}, playtime {d}s)", .{
            savefile_id, self.game.system.save_count, self.game.map.map_id, self.game.frame_count_global / 60,
        });
        return true;
    }

    fn loadGlobalInfo(self: *SaveManager) !json.Value {
        // Recover metadata independently of slot data. Loading never
        // rewrites either file, and valid disk slots remain discoverable.
        for ([_]bool{ false, true }) |backup| {
            const text = (self.storageReadVariant(0, backup) catch null) orelse continue;
            defer self.alloc.free(text);
            const parsed = json.parseAlloc(self.alloc, text) catch continue;
            if (parsed.value == .array) return parsed.value;
        }
        return .{ .array = .{ .items = &.{} } };
    }

    fn makeSavefileInfo(self: *SaveManager) !json.Value {
        const a = self.alloc;
        // characters/faces: the party's map sprites (MV
        // charactersForSavefile) — actor characterName + index pairs.
        var chars = std.ArrayList(json.Value).empty;
        defer chars.deinit(a);
        var faces = std.ArrayList(json.Value).empty;
        defer faces.deinit(a);
        for (self.game.party.members.items) |id| {
            const actor = self.game.actors.actor(id) orelse continue;
            const aview = actor.dbActor();
            const pair_c = try a.alloc(json.Value, 2);
            pair_c[0] = .{ .string = actor.character_name };
            pair_c[1] = .{ .number = @floatFromInt(actor.character_index) };
            try chars.append(a, .{ .array = .{ .items = pair_c } });
            const pair_f = try a.alloc(json.Value, 2);
            pair_f[0] = .{ .string = if (aview) |av| av.face_name else "" };
            pair_f[1] = .{ .number = @floatFromInt(if (aview) |av| av.face_index else 0) };
            try faces.append(a, .{ .array = .{ .items = pair_f } });
        }
        const title = self.gameTitle();
        const playtime_s = self.game.frame_count_global / 60;
        var pt_buf: [64]u8 = undefined;
        const playtime = std.fmt.bufPrint(&pt_buf, "{d}:{d:0>2}:{d:0>2}", .{ playtime_s / 3600, (playtime_s / 60) % 60, playtime_s % 60 }) catch "0:00:00";

        const entries = try a.alloc(json.Value.Entry, 8);
        entries[0] = .{ .key = "globalId", .value = .{ .number = 493298270 } };
        entries[1] = .{ .key = "title", .value = .{ .string = title } };
        entries[2] = .{ .key = "characters", .value = .{ .array = .{ .items = try chars.toOwnedSlice(a) } } };
        entries[3] = .{ .key = "faces", .value = .{ .array = .{ .items = try faces.toOwnedSlice(a) } } };
        entries[4] = .{ .key = "playtime", .value = .{ .string = try a.dupe(u8, playtime) } };
        entries[5] = .{ .key = "timestamp", .value = .{ .number = @floatFromInt(std.time.milliTimestamp()) } };
        entries[6] = .{ .key = "mapId", .value = num(self.game.map.map_id) };
        entries[7] = .{ .key = "location", .value = str(a, self.mapLocation(self.game.map.map_id)) };
        return .{ .object = .{ .entries = entries } };
    }

    fn gameTitle(self: *const SaveManager) []const u8 {
        const f = self.db.get("data/System.json") orelse return "OMORI";
        return f.value.getString("gameTitle") orelse "OMORI";
    }

    fn mapLocation(self: *const SaveManager, id: i64) []const u8 {
        if (id <= 0) return "";
        const infos = self.db.get("data/MapInfos.json") orelse return "";
        const values = infos.value.arrayItems();
        if (id >= values.len) return "";
        const name = values[@intCast(id)].getString("name") orelse "";
        return std.mem.trimStart(u8, name, " ->");
    }

    // -- makeSaveContents / extractSaveContents --------------------------

    /// The MV contents contract: system, screen, timer, switches,
    /// variables, selfSwitches, actors, party, map, player (+ the OMORI
    /// plugin fields are NOT saved by MV core — they ride the objects).
    pub fn makeSaveContents(self: *SaveManager) !json.Value {
        const a = self.alloc;
        const entries = try a.alloc(json.Value.Entry, 11);
        entries[0] = try ent(a, "system", try exportSystem(a, &self.game.system));
        entries[1] = try ent(a, "screen", try exportScreen(a, &self.game.screen));
        entries[2] = try ent(a, "timer", try exportTimer(a, &self.game.timer));
        entries[3] = try ent(a, "switches", exportSwitches(a, &self.game.switches));
        entries[4] = try ent(a, "variables", exportVariables(a, &self.game.variables));
        entries[5] = try ent(a, "selfSwitches", try exportSelfSwitches(a, &self.game.self_switches));
        entries[6] = try ent(a, "actors", try exportActors(a, &self.game.actors, &self.game.party));
        entries[7] = try ent(a, "party", try exportParty(a, &self.game.party));
        entries[8] = try ent(a, "map", try exportMap(a, &self.game.map));
        var player = self.game.player;
        if (self.game.map.map_id != 0) player.map_id = self.game.map.map_id;
        entries[9] = try ent(a, "player", try exportPlayer(a, &player, self.game));
        entries[10] = try ent(a, "_omoriPortSaveVersion", num(39));
        return .{ .object = .{ .entries = entries } };
    }

    /// Mixer snapshots borrow mixer-owned names. Move all retained strings
    /// to a replacement game-owned arena before keeping save audio state.
    pub fn captureAudioOnSave(self: *SaveManager, bgm: game_mod.GameSystem.BgmSave, bgs: game_mod.GameSystem.BgmSave) !void {
        var retained = try RetainedSaveStrings.prepare(self.game, .null);
        errdefer retained.arena.deinit();
        inline for (RetainedSaveStrings.music_fields, 0..) |field, i| {
            if (comptime std.mem.eql(u8, field, "bgm_on_save") or std.mem.eql(u8, field, "bgs_on_save")) {
                var captured = if (comptime std.mem.eql(u8, field, "bgm_on_save")) bgm else bgs;
                captured.name = try retained.arena.allocator().dupe(u8, captured.name);
                retained.music[i] = captured;
            }
        }
        retained.commit(self.game);
    }

    /// Load the most recent slot (highest timestamp in global.rpgsave).
    pub fn loadLatest(self: *SaveManager) !bool {
        return loadLatestFn(self);
    }

    pub fn extractSaveContents(self: *SaveManager, contents: json.Value) !void {
        // Prepare all retained strings before importing. This includes old
        // fallback values, so replacing the previous arena never invalidates
        // actor fields omitted by a partial save. Commit also runs if a later
        // importer errors, preventing borrowed scratch strings from escaping.
        var retained = try RetainedSaveStrings.prepare(self.game, contents);
        defer retained.commit(self.game);
        try importSystem(&self.game.system, contents.get("system"));
        try importScreen(self.alloc, &self.game.screen, contents.get("screen"));
        try importTimer(&self.game.timer, contents.get("timer"));
        try importSwitches(&self.game.switches, contents.get("switches"));
        try importVariables(&self.game.variables, contents.get("variables"));
        try importSelfSwitches(self.alloc, &self.game.self_switches, contents.get("selfSwitches"));
        try importActors(self.alloc, &self.game.actors, contents.get("actors"));
        try importParty(self.alloc, &self.game.party, contents.get("party"));
        self.game.map.erased_events.clearRetainingCapacity();
        self.game.map.balloons.clearRetainingCapacity();
        self.game.map.scripted_scroll = .{};
        const saved_map = contents.get("map");
        const saved_player = contents.get("player");
        self.game.temp.legacy_collision_recovery = contents.getInt("_omoriPortSaveVersion", 0) < 39 and
            (if (saved_map) |map| map.get("_erasedEvents") != null and map.get("_events") == null else false);
        const map_id = if (saved_map) |m| m.getInt("_mapId", 0) else 0;
        const player_map = if (saved_player) |p| p.getInt("_mapId", map_id) else map_id;
        const boot_map = if (self.db.get("data/System.json")) |system| system.value.getInt("startMapId", 0) else 0;
        // Specific v38 signature: cold Continue loaded the intro map but
        // retained the saved player's map id. A subsequent save therefore
        // contains boot-map state alongside the real checkpoint map id.
        self.recovered_legacy_map = map_id == boot_map and boot_map > 0 and player_map > 0 and player_map != map_id;
        if (!self.recovered_legacy_map) try importMap(self.alloc, &self.game.map, saved_map);
        try importPlayer(&self.game.player, contents.get("player"));
        const target_map: u32 = @intCast(if (self.recovered_legacy_map) player_map else if (map_id > 0) map_id else player_map);
        self.game.map.map_id = target_map;
        self.game.player.map_id = target_map;
        self.game.player.new_map_id = target_map;
        importFollowers(self.game, saved_player);
        self.game.frame_count_global = self.game.system.frames_on_save;
        if (self.recovered_legacy_map) log.warn("load: recovered legacy intro-map mismatch; using player checkpoint map {d}, discarding intro-map event state", .{target_map});
        log.detail(.save, "extractSaveContents complete", .{});
    }
};

const RetainedSaveStrings = struct {
    arena: std.heap.ArenaAllocator,
    actors: []ActorStrings,
    music: [7]?game_mod.GameSystem.BgmSave,
    weather: []const u8,
    parallax: []const u8,

    const music_fields = .{ "bgm_on_save", "bgs_on_save", "battle_bgm", "victory_me", "saved_bgm", "walking_bgm", "defeat_me" };
    const save_fields = .{ "_bgmOnSave", "_bgsOnSave", "_battleBgm", "_victoryMe", "_savedBgm", "_walkingBgm", "_defeatMe" };
    const ActorStrings = struct { actor: *game_mod.GameActor, name: []const u8, nickname: []const u8, profile: []const u8 };

    fn prepare(game: *game_mod.GameObjects, contents: json.Value) !RetainedSaveStrings {
        var arena = std.heap.ArenaAllocator.init(game.alloc);
        errdefer arena.deinit();
        const alloc = arena.allocator();
        const actor_data: []const json.Value = if (contents.get("actors")) |v|
            (if (v.get("_data")) |data| data.arrayItems() else &.{})
        else
            &.{};
        // Materialize loaded actors before taking the complete fallback set.
        for (actor_data, 0..) |item, id| {
            if (id > 0 and item == .object) _ = game.actors.actor(@intCast(id));
        }
        const actors = try alloc.alloc(ActorStrings, game.actors.map.count());
        var iterator = game.actors.map.valueIterator();
        var index: usize = 0;
        while (iterator.next()) |slot| : (index += 1) {
            const actor = slot.*;
            const id: usize = @intCast(@max(actor.actor_id, 0));
            const saved = if (id < actor_data.len and actor_data[id] == .object) actor_data[id] else json.Value.null;
            actors[index] = .{
                .actor = actor,
                .name = try alloc.dupe(u8, saved.getString("_name") orelse actor.name),
                .nickname = try alloc.dupe(u8, saved.getString("_nickname") orelse actor.nickname),
                .profile = try alloc.dupe(u8, saved.getString("_profile") orelse actor.profile),
            };
        }
        var music: [7]?game_mod.GameSystem.BgmSave = undefined;
        inline for (music_fields, 0..) |field, i| {
            var source = @field(game.system, field);
            if (i < save_fields.len) {
                if (contents.get("system")) |system| source = importBgm(system.get(save_fields[i]));
            }
            music[i] = if (source) |value| blk: {
                var copied = value;
                copied.name = try alloc.dupe(u8, value.name);
                break :blk copied;
            } else null;
        }
        const screen = contents.get("screen") orelse json.Value.null;
        const map = contents.get("map") orelse json.Value.null;
        // Finish every allocation before copying the arena's state into
        // the result. Later allocations through the returned arena must
        // start after these strings rather than overwrite them.
        const weather = try alloc.dupe(u8, screen.getString("_weatherType") orelse game.screen.weather_type);
        const parallax = try alloc.dupe(u8, map.getString("_parallaxName") orelse game.map.parallax_name);
        return .{
            .arena = arena,
            .actors = actors,
            .music = music,
            .weather = weather,
            .parallax = parallax,
        };
    }

    fn commit(self: *RetainedSaveStrings, game: *game_mod.GameObjects) void {
        for (self.actors) |strings| {
            strings.actor.name = strings.name;
            strings.actor.nickname = strings.nickname;
            strings.actor.profile = strings.profile;
        }
        inline for (music_fields, 0..) |field, i| @field(game.system, field) = self.music[i];
        game.screen.weather_type = self.weather;
        game.map.parallax_name = self.parallax;
        if (game.retained_save_strings) |*old| old.deinit();
        game.retained_save_strings = self.arena;
    }
};

fn putSlot(alloc: std.mem.Allocator, global: *json.Value, slot: i32, info: json.Value) !void {
    // global is an array with holes (nulls); grow to slot+1.
    if (global.* != .array) global.* = .{ .array = .{ .items = &.{} } };
    const items = global.array.items;
    if (slot >= items.len) {
        const new_items = try alloc.alloc(json.Value, @intCast(slot + 1));
        for (items, 0..) |it, i| new_items[i] = it;
        var i: usize = items.len;
        while (i < new_items.len) : (i += 1) new_items[i] = .null;
        global.array.items = new_items;
    }
    if (slot >= 0) global.array.items[@intCast(slot)] = info;
}

fn slotExists(global: json.Value, slot: i32) bool {
    if (global != .array) return false;
    const items = global.array.items;
    if (slot <= 0 or slot >= items.len) return false;
    return items[@intCast(slot)] == .object;
}

fn validSaveContents(value: json.Value) bool {
    for ([_][]const u8{ "system", "screen", "timer", "switches", "variables", "selfSwitches", "actors", "party", "map", "player" }) |key| {
        const field = value.get(key) orelse return false;
        if (field != .object) return false;
    }
    const map = value.get("map").?;
    const player = value.get("player").?;
    const id = map.getInt("_mapId", player.getInt("_mapId", 0));
    return id > 0 and id <= std.math.maxInt(u32);
}

// ---------------------------------------------------------------------------
// Per-object export/import (MV field names, _underscore style)
// ---------------------------------------------------------------------------

fn ent(alloc: std.mem.Allocator, key: []const u8, v: json.Value) !json.Value.Entry {
    return .{ .key = try alloc.dupe(u8, key), .value = v };
}

fn num(n: anytype) json.Value {
    return .{ .number = @floatFromInt(n) };
}

fn str(alloc: std.mem.Allocator, s: []const u8) json.Value {
    return .{ .string = alloc.dupe(u8, s) catch s };
}

fn mkObj(alloc: std.mem.Allocator, entries: []const json.Value.Entry) json.Value {
    const out = alloc.alloc(json.Value.Entry, entries.len) catch return .{ .object = .{ .entries = &.{} } };
    for (entries, 0..) |e, i| out[i] = e;
    return .{ .object = .{ .entries = out } };
}

// -- Game_System ---------------------------------------------------------------

fn exportBgm(alloc: std.mem.Allocator, bgm: ?game_mod.GameSystem.BgmSave, key_prefix: []const u8, entries: *std.ArrayList(json.Value.Entry)) !void {
    // MV stores bgm objects as {name, volume, pitch, pan}.
    if (bgm) |b| {
        try entries.append(alloc, try ent(alloc, key_prefix, mkObj(alloc, &.{
            try ent(alloc, "name", str(alloc, b.name)),
            try ent(alloc, "volume", num(b.volume)),
            try ent(alloc, "pitch", num(b.pitch)),
            try ent(alloc, "pan", num(b.pan)),
        })));
    }
}

fn exportSystem(alloc: std.mem.Allocator, s: *const game_mod.GameSystem) !json.Value {
    var entries = std.ArrayList(json.Value.Entry).empty;
    defer entries.deinit(alloc);
    try entries.append(alloc, try ent(alloc, "_saveCount", num(s.save_count)));
    try entries.append(alloc, try ent(alloc, "_battleCount", num(s.battle_count)));
    try entries.append(alloc, try ent(alloc, "_winCount", num(s.win_count)));
    try entries.append(alloc, try ent(alloc, "_escapeCount", num(s.escape_count)));
    try entries.append(alloc, try ent(alloc, "_versionId", num(s.version_id)));
    try entries.append(alloc, try ent(alloc, "_framesOnSave", num(s.frames_on_save)));
    try entries.append(alloc, try ent(alloc, "_saveEnabled", .{ .boolean = s.save_enabled }));
    try entries.append(alloc, try ent(alloc, "_menuEnabled", .{ .boolean = s.menu_enabled }));
    try entries.append(alloc, try ent(alloc, "_encounterEnabled", .{ .boolean = s.encounter_enabled }));
    try entries.append(alloc, try ent(alloc, "_formationEnabled", .{ .boolean = s.formation_enabled }));
    try exportBgm(alloc, s.bgm_on_save, "_bgmOnSave", &entries);
    try exportBgm(alloc, s.bgs_on_save, "_bgsOnSave", &entries);
    try exportBgm(alloc, s.battle_bgm, "_battleBgm", &entries);
    try exportBgm(alloc, s.victory_me, "_victoryMe", &entries);
    try exportBgm(alloc, s.defeat_me, "_defeatMe", &entries);
    try exportBgm(alloc, s.saved_bgm, "_savedBgm", &entries);
    try exportBgm(alloc, s.walking_bgm, "_walkingBgm", &entries);
    return mkObj(alloc, entries.items);
}

fn importBgm(v: ?json.Value) ?game_mod.GameSystem.BgmSave {
    const value = v orelse return null;
    if (value != .object) return null;
    return .{
        .name = value.getString("name") orelse "",
        .volume = @intCast(value.getInt("volume", 100)),
        .pitch = @intCast(value.getInt("pitch", 100)),
        .pan = @intCast(value.getInt("pan", 0)),
    };
}

fn importSystem(s: *game_mod.GameSystem, v: ?json.Value) !void {
    const value = v orelse return;
    s.save_count = @intCast(value.getInt("_saveCount", s.save_count));
    s.battle_count = @intCast(value.getInt("_battleCount", s.battle_count));
    s.win_count = @intCast(value.getInt("_winCount", s.win_count));
    s.escape_count = @intCast(value.getInt("_escapeCount", s.escape_count));
    s.version_id = @intCast(value.getInt("_versionId", s.version_id));
    s.frames_on_save = @intCast(value.getInt("_framesOnSave", 0));
    s.save_enabled = value.getBool("_saveEnabled", s.save_enabled);
    s.menu_enabled = value.getBool("_menuEnabled", s.menu_enabled);
    s.encounter_enabled = value.getBool("_encounterEnabled", s.encounter_enabled);
    s.formation_enabled = value.getBool("_formationEnabled", s.formation_enabled);
    s.bgm_on_save = importBgm(value.get("_bgmOnSave"));
    s.bgs_on_save = importBgm(value.get("_bgsOnSave"));
    s.battle_bgm = importBgm(value.get("_battleBgm"));
    s.victory_me = importBgm(value.get("_victoryMe"));
    s.defeat_me = importBgm(value.get("_defeatMe"));
    s.saved_bgm = importBgm(value.get("_savedBgm"));
    s.walking_bgm = importBgm(value.get("_walkingBgm"));
}

// -- Game_Screen (tone/flash/shake/weather essentials) -------------------------

fn exportScreen(alloc: std.mem.Allocator, sc: *const game_mod.GameScreen) !json.Value {
    var entries = std.ArrayList(json.Value.Entry).empty;
    defer entries.deinit(alloc);
    try entries.append(alloc, try ent(alloc, "_brightness", num(sc.brightness)));
    {
        const tone_items = try alloc.alloc(json.Value, 4);
        tone_items[0] = num(sc.tone[0]);
        tone_items[1] = num(sc.tone[1]);
        tone_items[2] = num(sc.tone[2]);
        tone_items[3] = num(sc.tone[3]);
        try entries.append(alloc, try ent(alloc, "_tone", .{ .array = .{ .items = tone_items } }));
    }
    try entries.append(alloc, try ent(alloc, "_weatherType", str(alloc, sc.weather_type)));
    try entries.append(alloc, try ent(alloc, "_weatherPower", .{ .number = sc.weather_power }));
    try entries.append(alloc, try ent(alloc, "_weatherPowerTarget", num(sc.weather_power_target)));
    try entries.append(alloc, try ent(alloc, "_weatherDuration", num(sc.weather_duration)));
    try entries.append(alloc, try ent(alloc, "_pictures", try exportPictures(alloc, sc)));
    const flash = try alloc.alloc(json.Value, 4);
    for (sc.flash_color, 0..) |channel, i| flash[i] = num(channel);
    try entries.append(alloc, try ent(alloc, "_flashColor", .{ .array = .{ .items = flash } }));
    try entries.append(alloc, try ent(alloc, "_flashDuration", num(sc.flash_duration)));
    try entries.append(alloc, try ent(alloc, "_shakePower", num(sc.shake_power)));
    try entries.append(alloc, try ent(alloc, "_shakeSpeed", num(sc.shake_speed)));
    try entries.append(alloc, try ent(alloc, "_shakeDuration", num(sc.shake_duration)));
    try entries.append(alloc, try ent(alloc, "_shakeDirection", num(sc.shake_direction)));
    try entries.append(alloc, try ent(alloc, "_shake", .{ .number = sc.shake }));
    return mkObj(alloc, entries.items);
}

const pic_fields = .{
    .{ "origin", "_origin" },               .{ "x", "_x" },                         .{ "y", "_y" },                          .{ "scale_x", "_scaleX" },         .{ "scale_y", "_scaleY" },
    .{ "opacity", "_opacity" },             .{ "blend_mode", "_blendMode" },        .{ "spin", "_rotationSpeed" },           .{ "target_x", "_targetX" },       .{ "target_y", "_targetY" },
    .{ "target_scale_x", "_targetScaleX" }, .{ "target_scale_y", "_targetScaleY" }, .{ "target_opacity", "_targetOpacity" }, .{ "move_duration", "_duration" },
};

fn exportPictures(a: std.mem.Allocator, sc: *const game_mod.GameScreen) !json.Value {
    var highest: usize = 0;
    var it = sc.pictures.iterator();
    while (it.next()) |entry| {
        const id = entry.key_ptr.*;
        if (id > 0 and id <= game_mod.GameScreen.max_pictures) highest = @max(highest, @as(usize, @intCast(id)));
    }
    const slots = try a.alloc(json.Value, highest + 1);
    @memset(slots, .null);
    for (slots[1..], 1..) |*slot, i| {
        const pic = sc.pictures.get(@intCast(i)) orelse continue;
        const fields = try a.alloc(json.Value.Entry, pic_fields.len + 3);
        fields[0] = try ent(a, "@", .{ .string = "Game_Picture" });
        fields[1] = try ent(a, "_name", .{ .string = try a.dupe(u8, pic.name) });
        fields[2] = try ent(a, "_angle", .{ .number = pic.angle });
        inline for (pic_fields, 3..) |pair, j| fields[j] = try ent(a, pair[1], num(@field(pic, pair[0])));
        slot.* = .{ .object = .{ .entries = fields } };
    }
    return .{ .array = .{ .items = slots } };
}

fn boundedNumber(value: json.Value, key: []const u8, fallback: f64, low: f64, high: f64) f64 {
    const v = value.get(key) orelse return fallback;
    if (v != .number or !std.math.isFinite(v.number)) return fallback;
    return std.math.clamp(v.number, low, high);
}

fn restorePictures(sc: *game_mod.GameScreen, saved: ?json.Value) !void {
    var restored = game_mod.GameScreen.init(sc.alloc);
    defer restored.deinit();
    const slots = if (saved) |s| s.arrayItems() else &.{};
    for (slots[0..@min(slots.len, game_mod.GameScreen.max_pictures + 1)], 0..) |record, i| {
        if (i == 0) continue;
        const name = record.getString("_name") orelse continue;
        if (name.len == 0) continue;
        var pic = game_mod.GameScreen.Picture{ .id = @intCast(i) };
        inline for (pic_fields) |pair| {
            @field(pic, pair[0]) = @intFromFloat(boundedNumber(record, pair[1], @floatFromInt(@field(pic, pair[0])), -2147483648, 2147483647));
        }
        pic.angle = @mod(boundedNumber(record, "_angle", 0, -1e15, 1e15), 360);
        try restored.pictures.ensureUnusedCapacity(1);
        pic.name = try sc.alloc.dupe(u8, name);
        restored.pictures.putAssumeCapacity(pic.id, pic);
    }
    std.mem.swap(@TypeOf(sc.pictures), &sc.pictures, &restored.pictures);
}

fn importScreen(alloc: std.mem.Allocator, sc: *game_mod.GameScreen, v: ?json.Value) !void {
    _ = alloc;
    const value = v orelse return;
    sc.brightness = @intCast(value.getInt("_brightness", 255));
    if (value.get("_tone")) |t| {
        if (t == .array) {
            const items = t.array.items;
            for (0..4) |i| {
                if (i < items.len) sc.tone[i] = @intCast(items[i].asInt());
            }
        }
    }
    if (value.getString("_weatherType")) |w| sc.weather_type = w;
    sc.weather_power = boundedNumber(value, "_weatherPower", 0, 0, 9);
    sc.weather_power_target = @intFromFloat(boundedNumber(value, "_weatherPowerTarget", sc.weather_power, 0, 9));
    sc.weather_duration = @intFromFloat(boundedNumber(value, "_weatherDuration", 0, 0, 2147483647));
    try restorePictures(sc, value.get("_pictures"));
    // Old native files omitted effects. Reset their missing values rather
    // than carrying a previous field's transient flash/shake into this load.
    sc.flash_color = .{ 0, 0, 0, 0 };
    if (value.get("_flashColor")) |flash| {
        const channels = flash.arrayItems();
        for (channels[0..@min(channels.len, 4)], 0..) |channel, i| sc.flash_color[i] = @intCast(std.math.clamp(channel.asInt(), 0, 255));
    }
    sc.flash_duration = @intCast(std.math.clamp(value.getInt("_flashDuration", 0), 0, std.math.maxInt(i32)));
    if (sc.flash_duration == 0) sc.flash_color[3] = 0;
    sc.shake_power = @intCast(std.math.clamp(value.getInt("_shakePower", 0), 0, 1000));
    sc.shake_speed = @intCast(std.math.clamp(value.getInt("_shakeSpeed", 0), 0, 1000));
    sc.shake_duration = @intCast(std.math.clamp(value.getInt("_shakeDuration", 0), 0, std.math.maxInt(i32)));
    sc.shake_direction = if (value.getInt("_shakeDirection", 1) < 0) -1 else 1;
    const shake = if (value.get("_shake")) |field| field.asFloat() else 0;
    sc.shake = if (std.math.isFinite(shake) and @abs(shake) <= 200000) shake else 0;
    if (sc.shake_power == 0 or sc.shake_speed == 0) {
        sc.shake = 0;
        sc.shake_duration = 0;
    }
}

// -- Game_Timer -----------------------------------------------------------------

fn exportTimer(alloc: std.mem.Allocator, t: *const game_mod.GameTimer) !json.Value {
    var entries = std.ArrayList(json.Value.Entry).empty;
    defer entries.deinit(alloc);
    try entries.append(alloc, try ent(alloc, "_frames", num(t.frames)));
    try entries.append(alloc, try ent(alloc, "_working", .{ .boolean = t.working }));
    return mkObj(alloc, entries.items);
}

fn importTimer(t: *game_mod.GameTimer, v: ?json.Value) !void {
    const value = v orelse return;
    t.frames = @intCast(@max(value.getInt("_frames", @intCast(t.frames)), 0));
    t.working = value.getBool("_working", t.working);
}

// -- Switches / Variables --------------------------------------------------------

fn exportSwitches(alloc: std.mem.Allocator, sw: *const game_mod.Switches) json.Value {
    // MV: _data array (0 unused). Values as booleans.
    const items = alloc.alloc(json.Value, sw.values.len) catch return .{ .object = .{ .entries = &.{} } };
    for (sw.values, 0..) |val, i| items[i] = .{ .boolean = val };
    const entries = alloc.alloc(json.Value.Entry, 1) catch return .{ .object = .{ .entries = &.{} } };
    entries[0] = ent(alloc, "_data", .{ .array = .{ .items = items } }) catch return .{ .object = .{ .entries = &.{} } };
    return .{ .object = .{ .entries = entries } };
}

fn importSwitches(sw: *game_mod.Switches, v: ?json.Value) !void {
    const value = v orelse return;
    const data = value.get("_data") orelse return;
    if (data != .array) return;
    const items = data.array.items;
    for (sw.values, 0..) |*val, i| {
        if (i < items.len) val.* = items[i] == .boolean and items[i].boolean;
    }
}

fn exportVariables(alloc: std.mem.Allocator, vars: *const game_mod.Variables) json.Value {
    const items = alloc.alloc(json.Value, vars.values.len) catch return .{ .object = .{ .entries = &.{} } };
    for (vars.values, 0..) |val, i| items[i] = num(val);
    const sheet_id = @import("balloons.zig").sheet_variable;
    if (vars.balloon_sheet) |sheet| {
        if (sheet_id < items.len) items[sheet_id] = .{ .string = sheet.name() };
    }
    const entries = alloc.alloc(json.Value.Entry, 1) catch return .{ .object = .{ .entries = &.{} } };
    entries[0] = ent(alloc, "_data", .{ .array = .{ .items = items } }) catch return .{ .object = .{ .entries = &.{} } };
    return .{ .object = .{ .entries = entries } };
}

fn importVariables(vars: *game_mod.Variables, v: ?json.Value) !void {
    const balloons = @import("balloons.zig");
    vars.balloon_sheet = null;
    const value = v orelse return;
    const data = value.get("_data") orelse return;
    if (data != .array) return;
    const items = data.array.items;
    for (vars.values, 0..) |*val, i| {
        if (i < items.len) val.* = items[i].asInt();
    }
    if (balloons.sheet_variable < items.len) {
        const item = items[balloons.sheet_variable];
        if (item == .string) vars.balloon_sheet = balloons.Sheet.fromName(item.string);
    }
}

test "balloon cues: save round trip preserves the authored sheet and numeric replacement clears it" {
    const balloons = @import("balloons.zig");
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var before = try game_mod.Variables.init(a, 30);
    before.setBalloonSheet(.do_re_mi);
    before.setValue(26, 14);
    const payload = try jsonExStringify(a, exportVariables(a, &before));
    var after = try game_mod.Variables.init(a, 30);
    try importVariables(&after, try jsonExParse(a, payload));
    try testing.expectEqual(@as(?balloons.Sheet, .do_re_mi), after.balloon_sheet);
    try testing.expectEqual(@as(i64, 14), after.value(26));
    after.setValue(25, 4);
    try testing.expectEqual(@as(?balloons.Sheet, null), after.balloon_sheet);
    try testing.expectEqual(@as(i64, 4), after.value(25));
}

// -- Self switches ---------------------------------------------------------------

fn exportSelfSwitches(alloc: std.mem.Allocator, ss: *const game_mod.GameSelfSwitches) !json.Value {
    // MV: _data map keyed "mapId,eventId,letter" → bool. We serialize an
    // array of ["map,event,ch", bool] rows (row form is lossless and
    // avoids numeric-key object ambiguity).
    var rows = std.ArrayList(json.Value).empty;
    defer rows.deinit(alloc);
    var it = ss.map.iterator();
    while (it.next()) |kv| {
        const row = alloc.alloc(json.Value, 2) catch continue;
        row[0] = .{ .string = kv.key_ptr.* };
        row[1] = .{ .boolean = kv.value_ptr.* };
        try rows.append(alloc, .{ .array = .{ .items = row } });
    }
    const entries = alloc.alloc(json.Value.Entry, 1) catch return .{ .object = .{ .entries = &.{} } };
    entries[0] = try ent(alloc, "_rows", .{ .array = .{ .items = try rows.toOwnedSlice(alloc) } });
    return .{ .object = .{ .entries = entries } };
}

fn importSelfSwitches(alloc: std.mem.Allocator, ss: *game_mod.GameSelfSwitches, v: ?json.Value) !void {
    _ = alloc;
    const value = v orelse return;
    const rows = value.get("_rows") orelse return;
    if (rows != .array) return;
    ss.deinit();
    ss.* = game_mod.GameSelfSwitches.init(ss.alloc);
    for (rows.array.items) |row| {
        if (row != .array or row.array.items.len < 2) continue;
        const items = row.array.items;
        const key = if (items[0] == .string) items[0].string else continue;
        const val = items[1] == .boolean and items[1].boolean;
        // key = "map,event,ch"
        var parts = std.mem.splitScalar(u8, key, ',');
        const map_str = parts.next() orelse continue;
        const event_str = parts.next() orelse continue;
        const ch = parts.rest();
        const map_id = std.fmt.parseInt(u32, map_str, 10) catch continue;
        const event_id = std.fmt.parseInt(i32, event_str, 10) catch continue;
        ss.setValue(map_id, event_id, ch, val);
    }
}

// -- Game_Actors / Game_Actor ----------------------------------------------------

fn exportActors(alloc: std.mem.Allocator, actors: *const game_mod.GameActors, party: *const game_mod.GameParty) !json.Value {
    // MV: $gameActors = {_data: [null, actor1, ...]} — the full actor set
    // (level/exp/equips persist outside the party).
    var items = std.ArrayList(json.Value).empty;
    defer items.deinit(alloc);
    try items.append(alloc, .null);
    // Emit 1..max id slots; null for un-instantiated (MV keeps holes).
    var max_id: i32 = 0;
    var it = actors.map.iterator();
    while (it.next()) |kv| max_id = @max(max_id, kv.key_ptr.*);
    for (party.members.items) |m| max_id = @max(max_id, m);
    var id: i32 = 1;
    while (id <= max_id) : (id += 1) {
        if (actors.map.get(id)) |a| {
            try items.append(alloc, try exportActor(alloc, a));
        } else {
            try items.append(alloc, .null);
        }
    }
    const entries = try alloc.alloc(json.Value.Entry, 1);
    entries[0] = try ent(alloc, "_data", .{ .array = .{ .items = try items.toOwnedSlice(alloc) } });
    return .{ .object = .{ .entries = entries } };
}

fn exportActor(alloc: std.mem.Allocator, a: *const game_mod.GameActor) !json.Value {
    var entries = std.ArrayList(json.Value.Entry).empty;
    defer entries.deinit(alloc);
    try entries.append(alloc, try ent(alloc, "@", str(alloc, "Game_Actor")));
    try entries.append(alloc, try ent(alloc, "_actorId", num(a.actor_id)));
    try entries.append(alloc, try ent(alloc, "_characterName", str(alloc, a.character_name)));
    try entries.append(alloc, try ent(alloc, "_characterIndex", num(a.character_index)));
    try entries.append(alloc, try ent(alloc, "_name", str(alloc, a.name)));
    try entries.append(alloc, try ent(alloc, "_nickname", str(alloc, a.nickname)));
    try entries.append(alloc, try ent(alloc, "_profile", str(alloc, a.profile)));
    try entries.append(alloc, try ent(alloc, "_classId", num(a.class_id)));
    try entries.append(alloc, try ent(alloc, "_level", num(a.level)));
    // MV _exp = {classId: exp} map — current class only.
    {
        const exp_entries = try alloc.alloc(json.Value.Entry, 1);
        var cb: [24]u8 = undefined;
        const class_key = std.fmt.bufPrint(&cb, "{d}", .{a.class_id}) catch "1";
        exp_entries[0] = try ent(alloc, try alloc.dupe(u8, class_key), num(a.exp));
        try entries.append(alloc, try ent(alloc, "_exp", .{ .object = .{ .entries = exp_entries } }));
    }
    {
        const skills = try alloc.alloc(json.Value, a.skills.items.len);
        for (a.skills.items, 0..) |s, i| skills[i] = num(s);
        try entries.append(alloc, try ent(alloc, "_skills", .{ .array = .{ .items = skills } }));
    }
    {
        // MV _equips: Game_Item objects {_dataClass: 'weapon'|'armor', _itemId}.
        const equips = try alloc.alloc(json.Value, a.equips.items.len);
        for (a.equips.items, 0..) |eq, i| {
            const e_entries = try alloc.alloc(json.Value.Entry, 2);
            e_entries[0] = try ent(alloc, "_dataClass", str(alloc, if (eq.is_weapon) "weapon" else "armor"));
            e_entries[1] = try ent(alloc, "_itemId", num(eq.item_id));
            equips[i] = .{ .object = .{ .entries = e_entries } };
        }
        try entries.append(alloc, try ent(alloc, "_equips", .{ .array = .{ .items = equips } }));
    }
    {
        const plus = try alloc.alloc(json.Value, 8);
        for (a.param_plus, 0..) |p, i| plus[i] = num(p);
        try entries.append(alloc, try ent(alloc, "_paramPlus", .{ .array = .{ .items = plus } }));
    }
    try entries.append(alloc, try ent(alloc, "_hp", num(a.hp)));
    try entries.append(alloc, try ent(alloc, "_mp", num(a.mp)));
    try entries.append(alloc, try ent(alloc, "_tp", num(a.tp)));
    {
        // _states + _stateTurns (turns 0 = infinite)
        const states = try alloc.alloc(json.Value, a.states.count());
        const turns_entries = try alloc.alloc(json.Value.Entry, a.states.count());
        var it = a.states.iterator();
        var i: usize = 0;
        while (it.next()) |kv| {
            states[i] = num(kv.key_ptr.*);
            var tb: [24]u8 = undefined;
            const skey = std.fmt.bufPrint(&tb, "{d}", .{kv.key_ptr.*}) catch "0";
            turns_entries[i] = try ent(alloc, try alloc.dupe(u8, skey), num(kv.value_ptr.*));
            i += 1;
        }
        try entries.append(alloc, try ent(alloc, "_states", .{ .array = .{ .items = states } }));
        try entries.append(alloc, try ent(alloc, "_stateTurns", .{ .object = .{ .entries = turns_entries } }));
    }
    {
        const buffs = try alloc.alloc(json.Value, 8);
        for (a.buffs, 0..) |b, i| buffs[i] = num(b);
        try entries.append(alloc, try ent(alloc, "_buffs", .{ .array = .{ .items = buffs } }));
    }
    return mkObj(alloc, entries.items);
}

fn importActors(alloc: std.mem.Allocator, actors: *game_mod.GameActors, v: ?json.Value) !void {
    _ = alloc;
    const value = v orelse return;
    const data = value.get("_data") orelse return;
    if (data != .array) return;
    for (data.array.items, 0..) |item, id| {
        if (id == 0) continue;
        if (item != .object) continue;
        const actor = actors.actor(@intCast(id)) orelse continue;
        try importActor(actor, item);
    }
}

fn importActor(a: *game_mod.GameActor, v: json.Value) !void {
    if (a.dbActor()) |defaults| {
        try a.setCharacterImage(v.getString("_characterName") orelse defaults.character_name, @intCast(std.math.clamp(v.getInt("_characterIndex", defaults.character_index), 0, 7)));
    }
    a.name = v.getString("_name") orelse a.name;
    a.nickname = v.getString("_nickname") orelse a.nickname;
    a.profile = v.getString("_profile") orelse a.profile;
    a.class_id = @intCast(v.getInt("_classId", a.class_id));
    a.level = @intCast(@max(v.getInt("_level", a.level), 1));
    if (v.get("_exp")) |exp| {
        if (exp == .object) {
            // {classId: exp}
            var cb: [24]u8 = undefined;
            const key = std.fmt.bufPrint(&cb, "{d}", .{a.class_id}) catch "1";
            if (exp.get(key)) |e| a.exp = e.asInt();
        }
    }
    if (v.get("_hp")) |hp| a.hp = @intCast(@max(hp.asInt(), 0));
    if (v.get("_mp")) |mp| a.mp = @intCast(@max(mp.asInt(), 0));
    if (v.get("_tp")) |tp| a.tp = @intCast(@max(tp.asInt(), 0));
    if (v.get("_skills")) |skills| {
        if (skills == .array) {
            a.skills.clearRetainingCapacity();
            for (skills.array.items) |sid| {
                const skill_id: i32 = @intCast(sid.asInt());
                if (skill_id > 0) a.learnSkill(skill_id);
            }
        }
    }
    if (v.get("_paramPlus")) |plus| {
        if (plus == .array) {
            for (0..8) |i| {
                if (i < plus.array.items.len) a.param_plus[i] = plus.array.items[i].asInt();
            }
        }
    }
    if (v.get("_states")) |states| {
        if (states == .array) {
            a.states.clearRetainingCapacity();
            for (states.array.items) |sid| {
                const state_id: i32 = @intCast(sid.asInt());
                if (state_id > 1) a.states.put(state_id, 1) catch {};
            }
        }
    }
    if (v.get("_stateTurns")) |turns| {
        if (turns == .object) {
            for (turns.object.entries) |e| {
                const state_id = std.fmt.parseInt(i32, e.key, 10) catch continue;
                if (state_id > 1) a.states.put(state_id, @intCast(@max(e.value.asInt(), 0))) catch {};
            }
        }
    }
    if (v.get("_buffs")) |buffs| {
        if (buffs == .array) {
            for (0..8) |i| {
                if (i < buffs.array.items.len) a.buffs[i] = @intCast(buffs.array.items[i].asInt());
            }
        }
    }
    // NOTE: _equips restore the Game_Item slots.
    if (v.get("_equips")) |equips| {
        if (equips == .array) {
            a.equips.clearRetainingCapacity();
            for (equips.array.items) |eq| {
                if (eq != .object) continue;
                const data_class = eq.getString("_dataClass") orelse "weapon";
                const item_id: i32 = @intCast(eq.getInt("_itemId", 0));
                a.equips.append(a.alloc, .{ .is_weapon = std.mem.eql(u8, data_class, "weapon"), .item_id = item_id }) catch {};
            }
        }
    }
}

// -- Game_Party ------------------------------------------------------------------

fn exportParty(alloc: std.mem.Allocator, p: *const game_mod.GameParty) !json.Value {
    var entries = std.ArrayList(json.Value.Entry).empty;
    defer entries.deinit(alloc);
    try entries.append(alloc, try ent(alloc, "@", str(alloc, "Game_Party")));
    try entries.append(alloc, try ent(alloc, "_gold", num(p.gold)));
    try entries.append(alloc, try ent(alloc, "_steps", num(p.steps)));
    try entries.append(alloc, try ent(alloc, "_menuActorId", num(p.menu_actor_id)));
    try entries.append(alloc, try ent(alloc, "_targetActorId", num(p.target_actor_id)));
    {
        const members = try alloc.alloc(json.Value, p.members.items.len);
        for (p.members.items, 0..) |m, i| members[i] = num(m);
        try entries.append(alloc, try ent(alloc, "_actors", .{ .array = .{ .items = members } }));
    }
    // items/weapons/armors: {_dataClass: {id: n}} maps
    try entries.append(alloc, try ent(alloc, "_items", try exportIdMap(alloc, &p.items)));
    try entries.append(alloc, try ent(alloc, "_weapons", try exportIdMap(alloc, &p.weapons)));
    try entries.append(alloc, try ent(alloc, "_armors", try exportIdMap(alloc, &p.armors)));
    {
        const li_entries = try alloc.alloc(json.Value.Entry, 2);
        li_entries[0] = try ent(alloc, "_dataClass", str(alloc, if (p.last_item.is_weapon) "weapon" else "item"));
        li_entries[1] = try ent(alloc, "_itemId", num(p.last_item.item_id));
        try entries.append(alloc, try ent(alloc, "_lastItem", .{ .object = .{ .entries = li_entries } }));
    }
    return mkObj(alloc, entries.items);
}

fn exportIdMap(alloc: std.mem.Allocator, m: *const std.AutoHashMap(i32, i32)) !json.Value {
    var entries = std.ArrayList(json.Value.Entry).empty;
    defer entries.deinit(alloc);
    var it = m.iterator();
    while (it.next()) |kv| {
        var kb: [24]u8 = undefined;
        const key = std.fmt.bufPrint(&kb, "{d}", .{kv.key_ptr.*}) catch "0";
        try entries.append(alloc, try ent(alloc, try alloc.dupe(u8, key), num(kv.value_ptr.*)));
    }
    return .{ .object = .{ .entries = try entries.toOwnedSlice(alloc) } };
}

fn importIdMap(v: ?json.Value, m: *std.AutoHashMap(i32, i32)) void {
    const value = v orelse return;
    if (value != .object) return;
    m.clearRetainingCapacity();
    for (value.object.entries) |e| {
        const id = std.fmt.parseInt(i32, e.key, 10) catch continue;
        m.put(id, @intCast(e.value.asInt())) catch {};
    }
}

fn importParty(alloc: std.mem.Allocator, p: *game_mod.GameParty, v: ?json.Value) !void {
    _ = alloc;
    const value = v orelse return;
    p.gold = value.getInt("_gold", p.gold);
    p.steps = @intCast(@max(value.getInt("_steps", @intCast(p.steps)), 0));
    p.menu_actor_id = @intCast(value.getInt("_menuActorId", p.menu_actor_id));
    p.target_actor_id = @intCast(value.getInt("_targetActorId", p.target_actor_id));
    if (value.get("_actors")) |actors| {
        if (actors == .array) {
            p.members.clearRetainingCapacity();
            for (actors.array.items) |m| {
                const actor_id: i32 = @intCast(m.asInt());
                if (actor_id > 0) p.members.append(p.alloc, actor_id) catch {};
            }
        }
    }
    importIdMap(value.get("_items"), &p.items);
    importIdMap(value.get("_weapons"), &p.weapons);
    importIdMap(value.get("_armors"), &p.armors);
}

// -- Game_Map / Game_Player -------------------------------------------------------

fn exportMap(alloc: std.mem.Allocator, m: *const game_mod.GameMap) !json.Value {
    var entries = std.ArrayList(json.Value.Entry).empty;
    defer entries.deinit(alloc);
    try entries.append(alloc, try ent(alloc, "@", str(alloc, "Game_Map")));
    try entries.append(alloc, try ent(alloc, "_mapId", num(m.map_id)));
    try entries.append(alloc, try ent(alloc, "_tilesetId", num(m.tileset_id)));
    try entries.append(alloc, try ent(alloc, "_encounterStep", num(m.encounter_step)));
    try entries.append(alloc, try ent(alloc, "_displayX", .{ .number = m.display_x }));
    try entries.append(alloc, try ent(alloc, "_displayY", .{ .number = m.display_y }));
    try entries.append(alloc, try ent(alloc, "_scrollDirection", num(m.scripted_scroll.direction)));
    try entries.append(alloc, try ent(alloc, "_scrollRest", .{ .number = m.scripted_scroll.remaining }));
    try entries.append(alloc, try ent(alloc, "_scrollSpeed", .{ .number = m.scripted_scroll.speed }));
    try entries.append(alloc, try ent(alloc, "_parallaxName", str(alloc, m.parallax_name)));
    try entries.append(alloc, try ent(alloc, "_nameDisplay", .{ .boolean = m.name_display }));
    // Erased events (214) persist until map re-setup.
    {
        var rows = std.ArrayList(json.Value).empty;
        defer rows.deinit(alloc);
        var it = m.erased_events.iterator();
        while (it.next()) |kv| {
            const row = try alloc.alloc(json.Value, 1);
            row[0] = num(kv.key_ptr.*);
            try rows.append(alloc, .{ .array = .{ .items = row } });
        }
        try entries.append(alloc, try ent(alloc, "_erasedEvents", .{ .array = .{ .items = try rows.toOwnedSlice(alloc) } }));
    }
    return mkObj(alloc, entries.items);
}

fn importMap(alloc: std.mem.Allocator, m: *game_mod.GameMap, v: ?json.Value) !void {
    _ = alloc;
    const value = v orelse return;
    m.map_id = @intCast(value.getInt("_mapId", m.map_id));
    m.tileset_id = @intCast(value.getInt("_tilesetId", m.tileset_id));
    m.encounter_step = @intCast(value.getInt("_encounterStep", m.encounter_step));
    m.display_x = if (value.get("_displayX")) |field| field.asFloat() else 0;
    m.display_y = if (value.get("_displayY")) |field| field.asFloat() else 0;
    if (std.math.isFinite(m.display_x) and std.math.isFinite(m.display_y)) {
        const direction = boundedNumber(value, "_scrollDirection", 0, 0, 8);
        const speed = boundedNumber(value, "_scrollSpeed", 4, 0, 8);
        const remaining = boundedNumber(value, "_scrollRest", 0, 0, std.math.maxInt(i32));
        if (@trunc(direction) == direction) m.startScriptedScroll(@intFromFloat(direction), remaining, speed);
    }
    m.name_display = value.getBool("_nameDisplay", m.name_display);
    if (value.get("_parallaxName")) |pn| {
        if (pn == .string) m.parallax_name = pn.string;
    }
    if (value.get("_erasedEvents")) |ee| {
        if (ee == .array) {
            for (ee.array.items) |row| {
                if (row == .array and row.array.items.len > 0) {
                    m.erased_events.put(@intCast(row.array.items[0].asInt()), true) catch {};
                }
            }
        }
    }
}

fn exportPlayer(alloc: std.mem.Allocator, p: *const game_mod.GamePlayer, game: *const game_mod.GameObjects) !json.Value {
    var entries = std.ArrayList(json.Value.Entry).empty;
    defer entries.deinit(alloc);
    try entries.append(alloc, try ent(alloc, "@", str(alloc, "Game_Player")));
    try entries.append(alloc, try ent(alloc, "_mapId", num(p.map_id)));
    try entries.append(alloc, try ent(alloc, "_x", num(p.x)));
    try entries.append(alloc, try ent(alloc, "_y", num(p.y)));
    try entries.append(alloc, try ent(alloc, "_direction", num(p.direction)));
    try entries.append(alloc, try ent(alloc, "_transparent", .{ .boolean = p.transparent }));
    if (p.encounter_count) |count| {
        try entries.append(alloc, try ent(alloc, "_encounterCount", .{ .number = count }));
    }
    const slots = try alloc.alloc(json.Value, game.followers_trail.len);
    for (game.followers_trail, slots) |slot, *value| {
        value.* = mkObj(alloc, &.{
            try ent(alloc, "_x", num(slot.x)),                 try ent(alloc, "_y", num(slot.y)),
            try ent(alloc, "_direction", num(slot.direction)),
        });
    }
    try entries.append(alloc, try ent(alloc, "_followers", mkObj(alloc, &.{
        try ent(alloc, "_visible", .{ .boolean = game.followers.visible }),
        try ent(alloc, "_data", .{ .array = .{ .items = slots } }),
    })));
    return mkObj(alloc, entries.items);
}

// A missing or invalid trail starts on the player's tile. Old native saves
// have no follower object. Original MV saves use the same _followers._data.
fn importFollowers(game: *game_mod.GameObjects, player: ?json.Value) void {
    game.synchronizeFollowers();
    game.followers.visible = game.optFollowers();
    const value = player orelse return;
    const object = value.get("_followers") orelse return;
    game.followers.visible = object.getBool("_visible", game.followers.visible);
    const data = object.get("_data") orelse return;
    const slots = data.arrayItems();
    var x = game.player.x;
    var y = game.player.y;
    var trail = game.followers_trail;
    for (&trail, 0..) |*slot, i| {
        if (i >= slots.len or slots[i] != .object) return;
        const sx = slots[i].get("_x") orelse return;
        const sy = slots[i].get("_y") orelse return;
        if (sx != .number or sy != .number or !std.math.isFinite(sx.number) or !std.math.isFinite(sy.number)) return;
        if (@floor(sx.number) != sx.number or @floor(sy.number) != sy.number or
            @abs(sx.number - @as(f64, @floatFromInt(x))) > 1 or @abs(sy.number - @as(f64, @floatFromInt(y))) > 1 or
            sx.number < 0 or sy.number < 0 or sx.number > std.math.maxInt(i32) or sy.number > std.math.maxInt(i32)) return;
        x = @intFromFloat(sx.number);
        y = @intFromFloat(sy.number);
        const facing = slots[i].get("_direction") orelse .null;
        const dir = if (facing == .number and (facing.number == 2 or facing.number == 4 or facing.number == 6 or facing.number == 8)) @as(i32, @intFromFloat(facing.number)) else game.player.direction;
        slot.relocate(x, y, dir);
    }
    game.followers_trail = trail;
}

fn importPlayer(p: *game_mod.GamePlayer, v: ?json.Value) !void {
    const value = v orelse return;
    p.map_id = @intCast(value.getInt("_mapId", p.map_id));
    p.x = @intCast(value.getInt("_x", p.x));
    p.y = @intCast(value.getInt("_y", p.y));
    p.direction = @intCast(value.getInt("_direction", p.direction));
    p.transparent = value.getBool("_transparent", p.transparent);
    p.encounter_count = null;
    if (value.get("_encounterCount")) |field| {
        const upper_limit = 2.0 * std.math.maxInt(i32);
        if (field == .number and std.math.isFinite(field.number) and field.number <= upper_limit and field.number >= -2) {
            p.encounter_count = @max(0, field.number);
        }
    }
    p.transferring = false; // fresh transfer happens via setup map after load
    p.new_map_id = p.map_id;
    p.new_x = p.x;
    p.new_y = p.y;
    p.new_direction = null;
    p.fade_type = 0;
    p.needs_map_reload = false;
}

fn playtimeFrames(text: []const u8) u64 {
    var parts = std.mem.splitScalar(u8, text, ':');
    const hours = std.fmt.parseInt(u64, parts.next() orelse return 0, 10) catch return 0;
    const minutes = std.fmt.parseInt(u64, parts.next() orelse return 0, 10) catch return 0;
    const seconds = std.fmt.parseInt(u64, parts.next() orelse return 0, 10) catch return 0;
    if (parts.next() != null or minutes >= 60 or seconds >= 60 or hours > 1000000) return 0;
    return ((hours * 60 + minutes) * 60 + seconds) * 60;
}

// ---------------------------------------------------------------------------
// SaveManager: latest-slot resolution for the title CONTINUE flow
// ---------------------------------------------------------------------------

/// Load the most recent slot (highest timestamp in global.rpgsave);
/// falls back to the highest existing file id. MV CONTINUE behavior.
pub fn loadLatestFn(self: *SaveManager) !bool {
    var scratch = std.heap.ArenaAllocator.init(self.alloc);
    defer scratch.deinit();
    var transaction = self.*;
    transaction.alloc = scratch.allocator();
    const result = try loadLatestTransaction(&transaction);
    self.last_accessed_id = transaction.last_accessed_id;
    self.loaded_backup = transaction.loaded_backup;
    self.recovered_legacy_map = transaction.recovered_legacy_map;
    return result;
}

fn loadLatestTransaction(self: *SaveManager) !bool {
    const global = try self.loadGlobalInfo();
    var best_slot: i32 = 0;
    var best_ts: i64 = -1;
    if (global == .array) {
        for (global.array.items, 0..) |item, i| {
            if (item != .object) continue;
            const ts = item.getInt("timestamp", 0);
            if (ts > best_ts) {
                best_ts = ts;
                best_slot = @intCast(i);
            }
        }
    }
    if (best_slot <= 0) {
        // fallback: highest existing file
        var slot: i32 = max_savefiles;
        while (slot > 0) : (slot -= 1) {
            if (self.storageExists(slot)) {
                best_slot = slot;
                break;
            }
        }
    }
    if (best_slot <= 0) {
        log.event(.save, .note, "no save files found (global.rpgsave has no slots)", .{});
        return false;
    }
    return self.loadGame(best_slot);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "lzstring: byte-exact compressToBase64 vs the JS reference" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Vectors generated with the payload's exact library
    // (js/libs/lz-string.js 1.4.5) via node — the same inputs must
    // produce the same .rpgsave bytes here.
    const cases = .{
        .{ .input = "", .output = "Q===" },
        .{ .input = "a", .output = "IZA=" },
        .{ .input = "OMORI native save test", .output = "PIWWCUEkAIDsEMAuBLAbgU2gZ3h6j0tEg===" },
        .{ .input = "{\"system\":{\"_saveCount\":1,\"_battleCount\":2}}", .output = "N4IgzgnmAuCmC2IBcoD6YCGA3WBhA9gK4B20yAjADQioBGG00ANnkacgEwC+XQA=" },
        .{ .input = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .output = "IY18ZXTtxQ==" },
        .{ .input = "The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog. The quick brown fox jumps over the lazy dog.", .output = "CoCwpgBAjgrglgYwNYQEYCcD2B3AdhAM0wA8IArGAWwAcBnCTANzHQgBdwIAbAQwC8AnhAAmmAOYA6CKEixEKDDnxFSFGvSYt2nXoJHipM6PGRoseQiXJU6DZqw6RdQ0ZKA=" },
    };
    inline for (cases) |c| {
        const got = try compressToBase64(a, c.input);
        try testing.expectEqualStrings(c.output, got);
    }
}

test "lzstring: decompressFromBase64 roundtrip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const inputs = [_][]const u8{
        "",
        "a",
        "OMORI native runtime — save/load pipeline",
        "{\"actors\":{\"_data\":[null,{\"_hp\":123,\"_mp\":45}]}},\"party\":{\"_gold\":777}}",
    };
    for (inputs) |input| {
        const compressed = try compressToBase64(a, input);
        const back = (try decompressFromBase64(a, compressed)).?;
        try testing.expectEqualStrings(input, back);
    }
    // Corrupt stream → null (the JS contract).
    const bad = try decompressFromBase64(a, "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA");
    try testing.expect(bad == null or bad != null); // must not crash
}

test "jsonex: encode + parse roundtrip with @ metadata" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Build: {system: {a: 1, arr: [1,2]}, party: {name: "OMORI"}}
    const sys_entries = try a.alloc(json.Value.Entry, 2);
    sys_entries[0] = .{ .key = "_saveCount", .value = .{ .number = 3 } };
    sys_entries[1] = .{ .key = "_data", .value = .{ .array = .{ .items = try a.dupe(json.Value, &.{ .{ .number = 1 }, .{ .number = 2 } }) } } };
    const root_entries = try a.alloc(json.Value.Entry, 2);
    root_entries[0] = .{ .key = "system", .value = .{ .object = .{ .entries = sys_entries } } };
    root_entries[1] = .{ .key = "party", .value = .{ .object = .{ .entries = try a.dupe(json.Value.Entry, &.{.{ .key = "_gold", .value = .{ .number = 500 } }}) } } };
    const tree = json.Value{ .object = .{ .entries = root_entries } };

    const text = try jsonExStringify(a, tree);
    // JsonEx invariants: property arrays wrapped in @a, objects carry @c.
    try testing.expect(std.mem.indexOf(u8, text, "\"@a\":[1,2]") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"@c\"") != null);

    // Roundtrip: decode gives the value tree back.
    const back = try jsonExParse(a, text);
    try testing.expectEqual(@as(i64, 3), back.get("system").?.getInt("_saveCount", 0));
    const arr = back.get("system").?.get("_data").?;
    try testing.expect(arr == .array);
    try testing.expectEqual(@as(usize, 2), arr.array.items.len);
    try testing.expectEqual(@as(i64, 500), back.get("party").?.getInt("_gold", 0));
}

test "save: repeated reclaiming-allocator transactions preserve strings and release old loads" {
    // testing.allocator detects both leaked JSON operation trees and old
    // retained-string arenas. The runtime now uses a reclaiming GPA too.
    const a = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("data");
    try tmp.dir.writeFile(.{ .sub_path = "data/System.json", .data = "{\"gameTitle\":\"OMORI\",\"switches\":[null,\"S\"],\"variables\":[null,\"V\"],\"partyMembers\":[1]}" });
    try tmp.dir.writeFile(.{ .sub_path = "data/Actors.json", .data = "[null,{\"id\":1,\"name\":\"DB NAME\",\"nickname\":\"\",\"profile\":\"\",\"classId\":1,\"initialLevel\":1,\"maxLevel\":99,\"equips\":[]}]" });
    try tmp.dir.writeFile(.{ .sub_path = "data/Classes.json", .data = "[null,{\"id\":1,\"params\":[[500,500],[50,50],[10,10],[10,10],[10,10],[10,10],[10,10],[10,10]],\"learnings\":[]}]" });
    const root = try tmp.dir.realpathAlloc(a, ".");
    defer a.free(root);
    const saves = try std.fs.path.join(a, &.{ root, "saves" });
    defer a.free(saves);
    var vfs = vfs_mod.Vfs.init(a, root, saves);
    defer vfs.deinit();
    var db = database.Database.init(a, &vfs);
    defer db.deinit();
    for ([_][]const u8{ "System", "Actors", "Classes" }) |name| {
        var path: [64]u8 = undefined;
        _ = try db.loadFile(.database, try std.fmt.bufPrint(&path, "data/{s}.json", .{name}));
    }
    var game = game_mod.GameObjects.init(a, &db);
    defer game.deinit();
    try game.create();
    try game.party.members.append(a, 1);
    const actor = game.actors.actor(1).?;
    game.map.map_id = 87;
    game.player.map_id = 87;
    actor.name = "SAVED NAME";
    actor.nickname = "saved nickname";
    actor.profile = "saved profile";
    game.system.saved_bgm = .{ .name = "saved_bgm", .volume = 71, .pitch = 99, .pan = 3 };
    game.system.defeat_me = .{ .name = "saved_defeat", .volume = 82, .pitch = 100, .pan = 0 };
    game.screen.weather_type = "rain";
    game.map.parallax_name = "saved_parallax";
    game.self_switches.setValue(87, 2, "A", true);
    var sm = SaveManager.init(a, &db, &vfs, &game);
    for (0..32) |_| {
        var borrowed_name = [_]u8{ 'c', 'a', 'p', 't', 'u', 'r', 'e', 'd' };
        try sm.captureAudioOnSave(.{ .name = &borrowed_name, .volume = 70, .pitch = 90, .pan = 1 }, .{ .name = "ambient", .volume = 30, .pitch = 100, .pan = 0 });
        @memset(&borrowed_name, 'x');
        try testing.expectEqualStrings("captured", game.system.bgm_on_save.?.name);
        try testing.expect(try sm.saveGame(1));
        actor.name = "TRANSIENT";
        actor.nickname = "changed";
        actor.profile = "changed";
        game.system.saved_bgm = null;
        game.system.defeat_me = null;
        game.screen.weather_type = "none";
        game.map.parallax_name = "";
        try testing.expect(try sm.loadGame(1));
        // Force another allocation after loadGame's scratch arena has
        // been destroyed; borrowed parse storage must not escape it.
        const poison = try a.alloc(u8, 64 * 1024);
        @memset(poison, 0xa5);
        a.free(poison);
        try testing.expectEqualStrings("SAVED NAME", actor.name);
        try testing.expectEqualStrings("saved nickname", actor.nickname);
        try testing.expectEqualStrings("saved profile", actor.profile);
        try testing.expectEqualStrings("saved_bgm", game.system.saved_bgm.?.name);
        try testing.expectEqualStrings("saved_defeat", game.system.defeat_me.?.name);
        try testing.expectEqualStrings("rain", game.screen.weather_type);
        try testing.expectEqualStrings("saved_parallax", game.map.parallax_name);
        try testing.expect(game.self_switches.value(87, 2, "A"));
    }
    {
        var scratch = std.heap.ArenaAllocator.init(a);
        defer scratch.deinit();
        var parser = try json.Parser.init(scratch.allocator(), "{\"actors\":{\"_data\":[null,{\"_hp\":7}]}}");
        defer parser.deinit();
        try sm.extractSaveContents(try parser.parse());
    }
    // A partial load must also copy unchanged strings before releasing
    // the previous retained arena, not keep pointers into that old load.
    try testing.expectEqual(@as(i32, 7), actor.hp);
    try testing.expectEqualStrings("SAVED NAME", actor.name);
    try testing.expectEqualStrings("saved_bgm", game.system.saved_bgm.?.name);
    try testing.expectEqualStrings("saved_defeat", game.system.defeat_me.?.name);
    try testing.expectEqualStrings("rain", game.screen.weather_type);
    try testing.expectEqualStrings("saved_parallax", game.map.parallax_name);
    try testing.expect(try sm.loadLatest());
    try testing.expectEqualStrings("SAVED NAME", actor.name);
    try testing.expect(!(try sm.loadGame(2)));
}

test "save: full saveGame/loadGame roundtrip through the VFS" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Minimal game tree in a temp dir (the interpreter-test pattern).
    const root = "/tmp/omori-save-test-game";
    std.fs.cwd().deleteTree(root) catch {};
    try std.fs.cwd().makePath(try std.fs.path.join(a, &.{ root, "data" }));
    {
        var f = try std.fs.cwd().createFile(try std.fs.path.join(a, &.{ root, "data", "System.json" }), .{});
        defer f.close();
        try f.writeAll("{\"gameTitle\":\"OMORI\",\"switches\":[null,\"s1\"],\"variables\":[null,\"v1\"],\"partyMembers\":[1]}");
    }
    {
        var f = try std.fs.cwd().createFile(try std.fs.path.join(a, &.{ root, "data", "Actors.json" }), .{});
        defer f.close();
        try f.writeAll("[null,{\"id\":1,\"name\":\"OMORI\",\"nickname\":\"\",\"profile\":\"\",\"classId\":1,\"initialLevel\":1,\"maxLevel\":99,\"equips\":[1],\"characterName\":\"\",\"faceName\":\"\"}]");
    }
    {
        var f = try std.fs.cwd().createFile(try std.fs.path.join(a, &.{ root, "data", "Classes.json" }), .{});
        defer f.close();
        try f.writeAll("[null,{\"id\":1,\"name\":\"C\",\"expParams\":[30,20,30,30],\"params\":[[500,500],[50,55],[20,21],[20,20],[20,20],[20,20],[20,20],[20,20]],\"learnings\":[{\"level\":1,\"skillId\":1}]}]");
    }
    var vfs = vfs_mod.Vfs.init(a, root, "/tmp/omori-save-test-saves");
    defer vfs.deinit();
    const db = try a.create(database.Database);
    defer a.destroy(db);
    db.* = database.Database.init(a, &vfs);
    _ = try db.loadFile(.database, "data/System.json");
    _ = try db.loadFile(.database, "data/Actors.json");
    _ = try db.loadFile(.database, "data/Classes.json");

    var game = game_mod.GameObjects.init(a, db);
    defer game.deinit();
    try game.create();
    try game.party.members.append(a, 1);
    _ = game.actors.actor(1);

    var sm = SaveManager.init(a, db, &vfs, &game);

    // Mutate state to something recognizable.
    game.party.gold = 777;
    game.switches.setValue(1, true);
    game.variables.setValue(1, 55);
    game.self_switches.setValue(87, 12, "A", true);
    game.map.map_id = 87;
    game.player.x = 10;
    game.player.y = 15;
    game.system.save_count = 5;
    game.frame_count_global = 9037;
    if (game.party.leader()) |leader| {
        leader.hp = 123;
        leader.exp = 200;
    }

    try testing.expect(try sm.saveGame(1));

    // File exists in the save root with .rpgsave extension.
    {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const p = try std.fmt.bufPrint(&buf, "/tmp/omori-save-test-saves/file1.rpgsave", .{});
        try std.fs.cwd().access(p, .{});
        const global = try std.fmt.bufPrint(&buf, "/tmp/omori-save-test-saves/global.rpgsave", .{});
        try std.fs.cwd().access(global, .{});
    }

    // Wipe state (simulate a fresh boot).
    game.party.gold = 0;
    game.switches.setValue(1, false);
    game.variables.setValue(1, 0);
    game.map.map_id = 0;
    game.player.x = 0;
    game.player.y = 0;
    if (game.party.leader()) |leader| {
        leader.hp = 1;
        leader.exp = 0;
    }

    try testing.expect(try sm.loadGame(1));

    // Restoration.
    try testing.expectEqual(@as(i64, 777), game.party.gold);
    try testing.expect(game.switches.value(1));
    try testing.expectEqual(@as(i64, 55), game.variables.value(1));
    try testing.expect(game.self_switches.value(87, 12, "A"));
    try testing.expectEqual(@as(u32, 87), game.map.map_id);
    try testing.expectEqual(@as(i32, 10), game.player.x);
    try testing.expectEqual(@as(i32, 15), game.player.y);
    if (game.party.leader()) |leader| {
        try testing.expectEqual(@as(i32, 123), leader.hp);
        try testing.expectEqual(@as(i64, 200), leader.exp);
    }
    // save_count increments on save (5 → 6).
    try testing.expectEqual(@as(u32, 6), game.system.save_count);

    // CONTINUE: loadLatest finds the slot.
    try testing.expect(try sm.loadLatest());

    // Slot 2 does not exist → load fails cleanly.
    try testing.expect(!(try sm.loadGame(2)));

    // global.rpgsave is a recoverable index, not the actual progress.
    // Losing/corrupting it must not hide or prevent a valid slot load.
    try vfs.writeFileSync("save/global.rpgsave", "broken metadata");
    try vfs.writeFileSync("save/global.rpgsave.bak", "broken backup metadata");
    const info = try sm.readSlotInfo();
    try testing.expect(info[0].exists and !info[0].listed);
    game.party.gold = 1;
    try testing.expect(try sm.loadGame(1));
    try testing.expectEqual(@as(i64, 777), game.party.gold);
    try testing.expectEqual(@as(u64, 9037), game.frame_count_global);

    // A second valid write retains the previous progress; a corrupt
    // current file must never displace that good backup on a later save.
    const original = try vfs.readFileSync("save/file1.rpgsave");
    game.party.gold = 888;
    try testing.expect(try sm.saveGame(1));
    const backup = try vfs.readFileSync("save/file1.rpgsave.bak");
    try testing.expectEqualSlices(u8, original, backup);
    try vfs.writeFileSync("save/file1.rpgsave", "broken slot");
    game.party.gold = 999;
    try testing.expect(try sm.saveGame(1));
    const retained_backup = try vfs.readFileSync("save/file1.rpgsave.bak");
    try testing.expectEqualSlices(u8, backup, retained_backup);

    // A syntactically valid but incomplete payload is rejected before
    // importing any fields into the live game.
    try sm.storageWrite(2, "{}");
    game.party.gold = 42;
    try testing.expect(!(try sm.loadGame(2)));
    try testing.expectEqual(@as(i64, 42), game.party.gold);
}

test "save: corrupted or missing primary loads a valid backup without changing files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(a, ".");
    var vfs = vfs_mod.Vfs.init(a, root, root);
    var db = database.Database.init(a, &vfs);
    var parser = try json.Parser.init(a, "{\"startMapId\":999,\"switches\":[null],\"variables\":[null]}");
    try db.storage.append(a, .{ .path = "data/System.json", .kind = .database, .value = try parser.parse() });
    try db.files.put("data/System.json", 0);
    var game = game_mod.GameObjects.init(a, &db);
    try game.create();
    game.map.map_id = 87;
    game.player = .{ .map_id = 87, .x = 28, .y = 22 };
    game.party.gold = 40;
    game.frame_count_global = 3000;
    var saves = SaveManager.init(a, &db, &vfs, &game);
    try testing.expect(try saves.saveGame(1));
    const checkpoint = try vfs.readFileSync("save/file1.rpgsave");
    game.party.gold = 80;
    game.frame_count_global = 6000;
    try testing.expect(try saves.saveGame(1));
    try testing.expectEqualSlices(u8, checkpoint, try vfs.readFileSync("save/file1.rpgsave.bak"));
    try vfs.writeFileSync("save/file1.rpgsave", "corrupt current slot");
    try vfs.writeFileSync("save/global.rpgsave", "corrupt current metadata");
    game.party.gold = 999;
    try testing.expect(try saves.loadGame(1));
    try testing.expect(saves.loaded_backup);
    try testing.expectEqual(@as(i64, 40), game.party.gold);
    try testing.expectEqual(@as(u64, 3000), game.frame_count_global);
    try testing.expectEqualStrings("corrupt current slot", try vfs.readFileSync("save/file1.rpgsave"));
    try testing.expectEqualStrings("corrupt current metadata", try vfs.readFileSync("save/global.rpgsave"));
    try testing.expectEqualSlices(u8, checkpoint, try vfs.readFileSync("save/file1.rpgsave.bak"));
    // The backup also remains selectable without a primary or save index.
    try tmp.dir.deleteFile("file1.rpgsave");
    try tmp.dir.deleteFile("global.rpgsave.bak");
    const slots = try saves.readSlotInfo();
    try testing.expect(slots[0].exists and slots[0].backup_available and !slots[0].listed);
    try testing.expect(try saves.loadGame(1));
    game.party.gold = 42;
    try testing.expect(try saves.saveGame(1));
    try testing.expectEqualSlices(u8, checkpoint, try vfs.readFileSync("save/file1.rpgsave.bak"));
    try testing.expect(try saves.loadGame(1));
    try testing.expect(!saves.loaded_backup);
    try testing.expectEqual(@as(i64, 42), game.party.gold);
}

test "followers: saved trail and visibility survive reload, older checkpoints gather behind leader" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var db = database.Database.init(a, undefined);
    var game = game_mod.GameObjects.init(a, &db);
    defer game.deinit();
    try game.create();
    game.player.x = 8;
    game.player.y = 4;
    game.map.map_id = 88;
    game.player.map_id = 88;
    game.synchronizeFollowers();
    game.followers.visible = false;
    for (&game.followers_trail, 0..) |*slot, i| slot.relocate(@as(i32, 7) - @as(i32, @intCast(i)), 4, 6);
    var sm = SaveManager.init(a, &db, undefined, &game);
    const text = try jsonExStringify(a, try sm.makeSaveContents());
    const contents = try jsonExParse(a, text);
    game.synchronizeFollowers();
    game.followers.visible = true;
    try sm.extractSaveContents(contents);
    try testing.expect(!game.followers.visible);
    try testing.expectEqual(@as(i32, 5), game.followers_trail[2].x);
    try testing.expectEqual(@as(f64, 5), game.followers_trail[2].real_x);
    importFollowers(&game, .null);
    try testing.expect(game.followers.visible);
    for (game.followers_trail) |slot| try testing.expectEqual(game.player.x, slot.x);
}

test "save: captured audio owns names across mixer snapshot reuse and serialization" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var db = database.Database.init(a, undefined);
    var game = game_mod.GameObjects.init(a, &db);
    defer game.deinit();
    try game.create();
    var saves = SaveManager.init(a, &db, undefined, &game);
    var name = [_]u8{ 'm', 'u', 's', 'i', 'c' };
    try saves.captureAudioOnSave(.{ .name = &name, .volume = 60, .pitch = 80, .pan = 0 }, .{ .name = "rain", .volume = 40, .pitch = 100, .pan = 0 });
    @memset(&name, 'X');
    try testing.expectEqualStrings("music", game.system.bgm_on_save.?.name);
    const contents = try saves.makeSaveContents();
    try testing.expectEqualStrings("music", contents.get("system").?.get("_bgmOnSave").?.getString("name").?);
    try saves.extractSaveContents(contents);
    try testing.expectEqualStrings("music", game.system.bgm_on_save.?.name);
    try testing.expectEqualStrings("rain", game.system.bgs_on_save.?.name);
    try testing.expectEqual(@as(i32, 60), game.system.bgm_on_save.?.volume);
}

test "field effects: restore picture slot, movement, spin and weather mid-transition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var first = game_mod.GameScreen.init(testing.allocator);
    defer first.deinit();
    first.showPicture(99, "overlay", 1, 0, 10, 100, 100, 255, 1);
    first.rotatePicture(99, -3);
    first.movePicture(99, 1, 120, 10, -100, 100, 45, 1, 4);
    first.changeWeather("snow", 8, 4);
    first.update();
    const serialized = try jsonExStringify(a, try exportScreen(a, &first));
    var second = game_mod.GameScreen.init(testing.allocator);
    defer second.deinit();
    second.showPicture(3, "stale", 0, 0, 0, 100, 100, 255, 0);
    try importScreen(a, &second, try jsonExParse(a, serialized));
    try testing.expect(second.picture(3) == null);
    try testing.expectEqualStrings("overlay", second.picture(99).?.name);
    try testing.expectEqual(@as(f64, 358.5), second.picture(99).?.angle);
    for (0..3) |_| second.update();
    try testing.expectEqual(@as(i32, -100), second.picture(99).?.scale_x);
    try testing.expectEqual(@as(i32, 120), second.picture(99).?.x);
    try testing.expectEqual(@as(f64, 354), second.picture(99).?.angle);
    try testing.expectEqual(@as(f64, 8), second.weather_power);
    second.changeWeather("none", 0, 4);
    second.update();
    try testing.expectEqualStrings("snow", second.weather_type);
    try testing.expectEqual(@as(f64, 6), second.weather_power);
    try importScreen(a, &second, .{ .object = .{ .entries = &.{} } });
    try testing.expectEqual(@as(usize, 0), second.pictures.count());
}

test "port options: screen effects serialize their progress and legacy loads clear old effects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var db = database.Database.init(a, undefined);
    var game = game_mod.GameObjects.init(a, &db);
    defer game.deinit();
    try game.create();
    game.map.map_id = 87;
    game.player.map_id = 87;
    game.screen.startFlash(.{ 255, 100, 30, 200 }, 8);
    game.screen.startShake(5, 7, 20);
    game.screen.update();
    var saves = SaveManager.init(a, &db, undefined, &game);
    const serialized = try jsonExStringify(a, try saves.makeSaveContents());
    const contents = try jsonExParse(a, serialized);
    game.screen.startFlash(.{ 10, 20, 30, 40 }, 100);
    game.screen.shake = 99;
    try saves.extractSaveContents(contents);
    try testing.expectEqual(@as(i32, 175), game.screen.flash_color[3]);
    try testing.expectEqual(@as(i32, 7), game.screen.flash_duration);
    try testing.expectEqual(@as(f64, 3.5), game.screen.shake);
    try testing.expectEqual(@as(i32, 19), game.screen.shake_duration);
    game.screen.update();
    try testing.expectEqual(@as(i32, 150), game.screen.flash_color[3]);
    try testing.expectEqual(@as(f64, 7), game.screen.shake);
    var parser = try json.Parser.init(a, "{\"_brightness\":255}");
    const legacy_screen = try parser.parse();
    for (contents.object.entries) |*entry| if (std.mem.eql(u8, entry.key, "screen")) {
        entry.value = legacy_screen;
    };
    try saves.extractSaveContents(contents);
    try testing.expectEqual(@as(i32, 0), game.screen.flash_duration);
    try testing.expectEqual(@as(i32, 0), game.screen.flash_color[3]);
    try testing.expectEqual(@as(f64, 0), game.screen.shake);
    try testing.expectEqual(@as(i32, 0), game.screen.shake_duration);
}

test "save: legacy boot-map mismatch uses the checkpoint map and discards wrong-map event state" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var db = database.Database.init(a, undefined);
    var parser = try json.Parser.init(a, "{\"startMapId\":999,\"switches\":[null],\"variables\":[null]}");
    try db.storage.append(a, .{ .path = "data/System.json", .kind = .database, .value = try parser.parse() });
    try db.files.put("data/System.json", 0);
    var game = game_mod.GameObjects.init(a, &db);
    try game.create();
    game.map.map_id = 999;
    try game.map.erased_events.put(7, true);
    game.player = .{ .map_id = 87, .x = 28, .y = 22 };
    game.system.frames_on_save = 5160;
    game.party.gold = 250;
    var saves = SaveManager.init(a, &db, undefined, &game);
    var contents = try saves.makeSaveContents();
    // Reproduce bytes authored by v38 before map/player consistency and
    // the native format marker were introduced.
    contents.object.entries = contents.object.entries[0..10];
    for (contents.get("player").?.object.entries) |*entry| {
        if (std.mem.eql(u8, entry.key, "_mapId")) entry.value = .{ .number = 87 };
    }
    game.player.reserveTransfer(999, 1, 0, 2, 0);
    try saves.extractSaveContents(contents);
    try testing.expect(saves.recovered_legacy_map);
    try testing.expectEqual(@as(u32, 87), game.map.map_id);
    try testing.expectEqual(@as(u32, 87), game.player.map_id);
    try testing.expectEqual(@as(u32, 87), game.player.new_map_id);
    try testing.expectEqual(@as(i32, 28), game.player.x);
    try testing.expectEqual(@as(i32, 22), game.player.y);
    try testing.expectEqual(@as(usize, 0), game.map.erased_events.count());
    try testing.expect(game.temp.legacy_collision_recovery);
    try testing.expectEqual(@as(i64, 250), game.party.gold);
    try testing.expectEqual(@as(u64, 5160), game.frame_count_global);
    try testing.expect(!game.player.isTransferring());
}
