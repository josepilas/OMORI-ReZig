//! OMORI language text store — native port of the `Text_Language_Processor`
//! message pipeline the interpreter (M5) drives through plugin commands.
//!
//! **The behavioral oracle** (`js/plugins/Text_Language_Processor.js`):
//!
//!   `LanguageManager.getMessageData(code)` where `code = "file.key"`:
//!   * `this._data[language].text[file][key]` — the `text` map of
//!     `Languages/<lang>/<file>.yaml`, loaded by `jsyaml.load`.
//!   * The message object fields the engine reads: `faceset`, `faceindex`,
//!     `background`, `position`, `text`, `extraFaces` (rare).
//!   * `Game_Message.showLanguageMessage(code)` copies those into the
//!     message window state and adds `data.text`.
//!
//! The default language is `"en"` (plugin parameter `Default Language`).
//!
//! YAML shape actually shipped (verified across the 209 en files):
//! two nesting levels — top-level `message_N` keys, each with scalar
//! fields (`text`, `faceset`, `faceindex`, `position`, `background`).
//! Comments (`#`) and blank lines everywhere; values are plain scalars
//! that keep MV text control codes (`\!`, `\<br>`, `\c[n]`, `\n[n]` …).
//!
//! This module implements exactly that subset: on-demand file load,
//! arena-parsed into a flat `file -> key -> MessageData` table.

const std = @import("std");
const vfs_mod = @import("../filesystem/vfs.zig");
const log = @import("../core/log.zig");

/// One language message entry (the fields Game_Message copies).
pub const MessageData = struct {
    key: []const u8 = "",
    faceset: []const u8 = "",
    faceindex: i32 = 0,
    background: i32 = 0,
    position: i32 = 2,
    text: []const u8 = "",
};

pub const TextError = error{
    OutOfMemory,
    FileUnreadable,
    ParseFailed,
};

/// Per-language store: file name → message table.
pub const TextStore = struct {
    allocator: std.mem.Allocator,
    vfs: *vfs_mod.Vfs,
    language: []const u8,
    /// Everything parsed lives in this arena (freed wholesale).
    arena: std.heap.ArenaAllocator,
    /// file (without .yaml) → flat message list.
    files: std.StringHashMap([]MessageData),
    /// file (without .yaml) → key → index into the list.
    index: std.StringHashMap(std.StringHashMap(usize)),

    pub fn init(allocator: std.mem.Allocator, vfs: *vfs_mod.Vfs, language: []const u8) TextStore {
        return .{
            .allocator = allocator,
            .vfs = vfs,
            .language = allocator.dupe(u8, language) catch "en",
            .arena = std.heap.ArenaAllocator.init(allocator),
            .files = std.StringHashMap([]MessageData).init(allocator),
            .index = std.StringHashMap(std.StringHashMap(usize)).init(allocator),
        };
    }

    pub fn deinit(self: *TextStore) void {
        var fit = self.files.iterator();
        while (fit.next()) |e| self.allocator.free(e.key_ptr.*);
        self.files.deinit();
        var iit = self.index.iterator();
        while (iit.next()) |e| {
            var inner = e.value_ptr.*;
            var kit = inner.iterator();
            while (kit.next()) |k| self.allocator.free(k.key_ptr.*);
            inner.deinit();
            self.allocator.free(e.key_ptr.*);
        }
        self.index.deinit();
        self.arena.deinit();
        self.allocator.free(self.language);
    }

    /// `LanguageManager.getMessageData("file.key")`.
    /// Loads `Languages/<lang>/<file>.yaml` on demand.
    pub fn getMessageData(self: *TextStore, code: []const u8) TextError!?MessageData {
        var it = std.mem.splitScalar(u8, code, '.');
        const file = it.next() orelse return null;
        const key = it.next() orelse return null;

        if (!self.files.contains(file)) {
            self.loadFile(file) catch |e| switch (e) {
                // Unknown language file → message miss (null), like
                // LanguageManager returning undefined data.
                error.FileUnreadable => return null,
                else => return e,
            };
        }
        const table = self.files.get(file) orelse return null;
        const lookup = self.index.get(file) orelse return null;
        const idx = lookup.get(key) orelse {
            log.event(.mv, .warn, "language message '{s}' not found in {s}.yaml", .{ key, file });
            return null;
        };
        return table[idx];
    }

    fn loadFile(self: *TextStore, file: []const u8) TextError!void {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "Languages/{s}/{s}.yaml", .{ self.language, file }) catch return error.FileUnreadable;
        const text = self.vfs.readFileSync(path) catch |e| {
            log.event(.mv, .warn, "language file '{s}' unreadable ({s})", .{ path, @errorName(e) });
            return error.FileUnreadable;
        };
        defer self.allocator.free(text);

        const t0 = std.time.milliTimestamp();
        var msgs = std.ArrayList(MessageData){};
        var parser = LangYamlParser{
            .alloc = self.arena.allocator(),
            .src = text,
        };
        parser.parseInto(&msgs) catch {
            msgs.deinit(self.arena.allocator());
            return error.ParseFailed;
        };
        const dt = std.time.milliTimestamp() - t0;

        const owned = msgs.toOwnedSlice(self.arena.allocator()) catch {
            return error.OutOfMemory;
        };

        // key → index lookup (owned by self.allocator, freed in deinit).
        var lookup = std.StringHashMap(usize).init(self.allocator);
        errdefer {
            var kit = lookup.iterator();
            while (kit.next()) |k| self.allocator.free(k.key_ptr.*);
            lookup.deinit();
        }
        for (owned, 0..) |m, i| {
            const k = self.allocator.dupe(u8, m.key) catch return error.OutOfMemory;
            lookup.put(k, i) catch {
                self.allocator.free(k);
                return error.OutOfMemory;
            };
        }
        const file_key_files = self.allocator.dupe(u8, file) catch return error.OutOfMemory;
        const file_key_index = self.allocator.dupe(u8, file) catch {
            self.allocator.free(file_key_files);
            return error.OutOfMemory;
        };
        self.files.put(file_key_files, owned) catch {
            self.allocator.free(file_key_files);
            self.allocator.free(file_key_index);
            return error.OutOfMemory;
        };
        self.index.put(file_key_index, lookup) catch {
            // remove the files entry we just inserted
            _ = self.files.remove(file_key_files);
            self.allocator.free(file_key_files);
            self.allocator.free(file_key_index);
            return error.OutOfMemory;
        };
        log.event(.mv, .info, "language file loaded: {s} ({d} messages, {d} ms)", .{ path, owned.len, dt });
    }
};

// ---------------------------------------------------------------------------
// The language-file YAML subset parser
//
// Grammar (what the payload actually ships):
//   file    := (comment | blank | entry)*
//   entry   := KEY ':' NL (field)*            — KEY at indent 0
//   field   := IND KEY ':' ' ' value NL        — deeper indent
//   value   := rest-of-line scalar (trimmed; may be empty)
// Lists (extraFaces) are counted and skipped (rare; log once per file).
// ---------------------------------------------------------------------------

const LangYamlParser = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,

    const Field = struct { key: []const u8, value: []const u8 };

    fn parseInto(self: *LangYamlParser, out: *std.ArrayList(MessageData)) !void {
        var current: ?MessageData = null;
        var list_skips: usize = 0;

        while (self.pos < self.src.len) {
            const line = self.nextRawLine();
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0 or trimmed[0] == '#') continue;

            const indent = countIndent(line);
            if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
                const key = std.mem.trim(u8, trimmed[0..colon], " \t");
                var value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t");
                // strip trailing comment on field lines (only when the
                // value does not start with '#')
                if (value.len > 0 and value[0] != '#' and value[0] != '"' and value[0] != '\'') {
                    if (findUnquotedComment(value)) |cpos| value = std.mem.trim(u8, value[0..cpos], " \t");
                }

                if (indent == 0) {
                    // new top-level entry: flush the previous one
                    if (current) |msg| try out.append(self.alloc, msg);
                    current = .{ .key = try self.alloc.dupe(u8, key) };
                } else if (current != null) {
                    try self.applyField(&current.?, key, value);
                }
            } else if (indent > 0 and trimmed.len > 0) {
                // list item ("- something") or continuation inside an
                // entry — the engine's extraFaces; skip but count.
                list_skips += 1;
            }
        }
        if (current) |msg| try out.append(self.alloc, msg);
        if (list_skips > 0) {
            log.detail(.mv, "language yaml: {d} list/continuation lines skipped (extraFaces etc.)", .{list_skips});
        }
    }

    fn applyField(self: *LangYamlParser, msg: *MessageData, key: []const u8, value: []const u8) !void {
        if (std.mem.eql(u8, key, "text")) {
            msg.text = try decodeScalar(self.alloc, value);
        } else if (std.mem.eql(u8, key, "faceset")) {
            msg.faceset = try decodeScalar(self.alloc, value);
        } else if (std.mem.eql(u8, key, "faceindex")) {
            msg.faceindex = std.fmt.parseInt(i32, value, 10) catch 0;
        } else if (std.mem.eql(u8, key, "background")) {
            msg.background = std.fmt.parseInt(i32, value, 10) catch 0;
        } else if (std.mem.eql(u8, key, "position")) {
            msg.position = std.fmt.parseInt(i32, value, 10) catch 2;
        }
        // extraFaces / other keys: ignored (list-valued in the oracle).
    }

    fn nextRawLine(self: *LangYamlParser) []const u8 {
        const start = self.pos;
        while (self.pos < self.src.len and self.src[self.pos] != '\n') : (self.pos += 1) {}
        const line = self.src[start..self.pos];
        if (self.pos < self.src.len) self.pos += 1; // consume \n
        return line;
    }
};

fn countIndent(line: []const u8) usize {
    var n: usize = 0;
    for (line) |c| {
        if (c == ' ') n += 1 else break;
    }
    return n;
}

fn findUnquotedComment(value: []const u8) ?usize {
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        if (value[i] == '#' and (i == 0 or value[i - 1] == ' ')) return i;
    }
    return null;
}

/// YAML plain scalars preserve backslashes. Single-quoted scalars only
/// unescape doubled apostrophes; double-quoted scalars decode escapes.
/// The distinction matters: "\\\\!" is the MV pause code, not a literal
/// backslash followed by an exclamation mark on screen.
fn decodeScalar(alloc: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (value.len == 0 or (value[0] != '"' and value[0] != '\'')) return alloc.dupe(u8, value);
    const quote = value[0];
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    var index: usize = 1;
    while (index < value.len) {
        const c = value[index];
        index += 1;
        if (c == quote) {
            if (quote == '\'' and index < value.len and value[index] == '\'') {
                try out.append(alloc, '\'');
                index += 1;
            } else return out.toOwnedSlice(alloc);
        } else if (c == '\\' and quote == '"') {
            if (index == value.len) return error.InvalidQuotedScalar;
            const escape = value[index];
            index += 1;
            switch (escape) {
                '0' => try out.append(alloc, 0),
                'a' => try out.append(alloc, 7),
                'b' => try out.append(alloc, 8),
                't', '\t' => try out.append(alloc, '\t'),
                'n' => try out.append(alloc, '\n'),
                'v' => try out.append(alloc, 11),
                'f' => try out.append(alloc, 12),
                'r' => try out.append(alloc, '\r'),
                'e' => try out.append(alloc, 27),
                ' ', '"', '/', '\\' => try out.append(alloc, escape),
                'x', 'u', 'U', 'N', '_', 'L', 'P' => {
                    const digits: usize = switch (escape) {
                        'x' => 2,
                        'u' => 4,
                        'U' => 8,
                        else => 0,
                    };
                    if (index + digits > value.len) return error.InvalidQuotedScalar;
                    const codepoint: u21 = if (digits > 0)
                        std.fmt.parseInt(u21, value[index .. index + digits], 16) catch return error.InvalidQuotedScalar
                    else switch (escape) {
                        'N' => 0x85,
                        '_' => 0xA0,
                        'L' => 0x2028,
                        'P' => 0x2029,
                        else => unreachable,
                    };
                    index += digits;
                    var encoded: [4]u8 = undefined;
                    const length = std.unicode.utf8Encode(codepoint, &encoded) catch return error.InvalidQuotedScalar;
                    try out.appendSlice(alloc, encoded[0..length]);
                },
                else => return error.InvalidQuotedScalar,
            }
        } else try out.append(alloc, c);
    }
    return error.InvalidQuotedScalar;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "language yaml: plain and quoted scalars preserve distinct escape semantics" {
    const a = testing.allocator;
    const cases = [_][2][]const u8{
        .{ "Plain\\!<br>line", "Plain\\!<br>line" },
        .{ "\"A white door.\\\\!<br>What now?\"", "A white door.\\!<br>What now?" },
        .{ "\"OPEN THE DOOR\" # trailing comment", "OPEN THE DOOR" },
        .{ "'It''s a path\\!<br>next'", "It's a path\\!<br>next" },
        .{ "\"Line\\n\\\"quoted\\\"\\u2026\"", "Line\n\"quoted\"…" },
    };
    for (cases) |example| {
        const decoded = try decodeScalar(a, example[0]);
        defer a.free(decoded);
        try testing.expectEqualStrings(example[1], decoded);
    }
}

fn makeLangTree(alloc: std.mem.Allocator, lang: []const u8, file: []const u8, content: []const u8) ![]const u8 {
    const root = "/tmp/omori-text-test";
    std.fs.cwd().deleteTree(root) catch {};
    const dir = try std.fs.path.join(alloc, &.{ root, "Languages", lang });
    defer alloc.free(dir);
    try std.fs.cwd().makePath(dir);
    const p = try std.fs.path.join(alloc, &.{ root, "Languages", lang, file });
    defer alloc.free(p);
    var f = try std.fs.cwd().createFile(p, .{});
    defer f.close();
    try f.writeAll(content);
    return root;
}

test "language text store: message data load and lookup" {
    const alloc = testing.allocator;
    const root = try makeLangTree(alloc, "en", "dw_flavor_text.yaml",
        \\# header comment
        \\
        \\message_0:
        \\      text: A floating mirror.\!<br>Your friends smile warmly behind you.
        \\
        \\message_1:
        \\      text:
        \\
        \\message_11:
        \\      faceset: MainCharacters_DreamWorld
        \\      faceindex: 2
        \\      text: Oh hi.
        \\
    );
    defer std.fs.cwd().deleteTree(root) catch {};

    var vfs = vfs_mod.Vfs.init(alloc, root, "/tmp/omori-text-save");
    defer vfs.deinit();
    var store = TextStore.init(alloc, &vfs, "en");
    defer store.deinit();

    const m0 = (try store.getMessageData("dw_flavor_text.message_0")).?;
    try testing.expectEqualStrings("A floating mirror.\\!<br>Your friends smile warmly behind you.", m0.text);

    const m11 = (try store.getMessageData("dw_flavor_text.message_11")).?;
    try testing.expectEqualStrings("MainCharacters_DreamWorld", m11.faceset);
    try testing.expectEqual(@as(i32, 2), m11.faceindex);
    try testing.expectEqualStrings("Oh hi.", m11.text);

    // empty text value → empty string (jsyaml null → data.text undefined →
    // addText(undefined) — engine treats as empty)
    const m1 = (try store.getMessageData("dw_flavor_text.message_1")).?;
    try testing.expectEqualStrings("", m1.text);

    // unknown key / unknown file → null, not a crash
    try testing.expect((try store.getMessageData("dw_flavor_text.nothing")) == null);
    try testing.expect((try store.getMessageData("no_such_file.msg")) == null);
}

test "language yaml: comment stripping and indent handling" {
    const alloc = testing.allocator;
    const root = try makeLangTree(alloc, "en", "t.yaml",
        \\message_1:
        \\  text: Hello # trailing comment
        \\message_2:
        \\      position: 0
        \\      background: 1
        \\
    );
    defer std.fs.cwd().deleteTree(root) catch {};
    var vfs = vfs_mod.Vfs.init(alloc, root, "/tmp/omori-text-save");
    defer vfs.deinit();
    var store = TextStore.init(alloc, &vfs, "en");
    defer store.deinit();
    const m1 = (try store.getMessageData("t.message_1")).?;
    try testing.expectEqualStrings("Hello", m1.text);
    const m2 = (try store.getMessageData("t.message_2")).?;
    try testing.expectEqual(@as(i32, 0), m2.position);
    try testing.expectEqual(@as(i32, 1), m2.background);
}
