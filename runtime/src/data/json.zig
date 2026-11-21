//! Tolerant dynamic JSON parser for RPG Maker MV data.
//!
//! Why not `std.json`? The OMORI payload's data files are *almost* JSON:
//!
//! * `js/plugins.js` is JavaScript (`var $plugins = [...]`), and its string
//!   literals contain RAW control characters (unescaped newlines) that strict
//!   JSON rejects. The game only ever evaluates it as JS.
//! * Some generated data files carry trailing commas in a few editor edge
//!   cases, and the original engine's JSON.parse is fed them after light
//!   preprocessing.
//!
//! This parser reproduces what the engine actually observes: a dynamic value
//! tree with tolerant strings, trailing commas, and a JS-prefix stripper
//! (`var $plugins =`). Numbers preserve integer/float distinction the way
//! JavaScript's Number would observe them (all parsed to f64, with an exact
//! integer accessor).
//!
//! Behavior contract: parse NEVER fails the whole file on recoverable
//! quirks; genuine structural corruption returns error.SyntaxError.

const std = @import("std");

pub const Value = union(enum) {
    null,
    boolean: bool,
    number: f64,
    string: []const u8,
    array: Array,
    object: Object,

    pub const Array = struct { items: []Value };
    pub const Object = struct { entries: []Entry };

    pub const Entry = struct { key: []const u8, value: Value };

    pub fn isNumber(self: Value) bool {
        return self == .number;
    }

    /// Integer view (JS number semantics: truncate toward zero).
    pub fn asInt(self: Value) i64 {
        return switch (self) {
            .number => |n| @intFromFloat(n),
            .boolean => |b| @intFromBool(b),
            else => 0,
        };
    }

    pub fn asFloat(self: Value) f64 {
        return switch (self) {
            .number => |n| n,
            .boolean => |b| if (b) 1 else 0,
            else => 0,
        };
    }

    /// Object field lookup (first match; later duplicates override in JS,
    /// but MV data never relies on duplicate keys — first match is fine
    /// for reads).
    pub fn get(self: Value, key: []const u8) ?Value {
        switch (self) {
            .object => |obj| {
                for (obj.entries) |e| {
                    if (std.mem.eql(u8, e.key, key)) return e.value;
                }
                return null;
            },
            else => return null,
        }
    }

    pub fn getString(self: Value, key: []const u8) ?[]const u8 {
        const v = self.get(key) orelse return null;
        return switch (v) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn getInt(self: Value, key: []const u8, default: i64) i64 {
        const v = self.get(key) orelse return default;
        return v.asInt();
    }

    pub fn getBool(self: Value, key: []const u8, default: bool) bool {
        const v = self.get(key) orelse return default;
        return switch (v) {
            .boolean => |b| b,
            .number => |n| n != 0,
            else => default,
        };
    }

    pub fn arrayItems(self: Value) []Value {
        return switch (self) {
            .array => |a| a.items,
            else => &.{},
        };
    }

    pub fn objectEntries(self: Value) []Entry {
        return switch (self) {
            .object => |o| o.entries,
            else => &.{},
        };
    }
};

pub const Error = error{
    SyntaxError,
    OutOfMemory,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    arena: std.heap.ArenaAllocator,

    pub fn init(allocator: std.mem.Allocator, src: []const u8) !Parser {
        return .{
            .allocator = allocator,
            .src = src,
            .arena = std.heap.ArenaAllocator.init(allocator),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
    }

    /// Parse and return a value tree whose storage is owned by the parser's
    /// arena (freed on deinit).
    pub fn parse(self: *Parser) Error!Value {
        self.skipWs();
        const v = try self.parseValue();
        self.skipWs();
        if (self.pos != self.src.len) return Error.SyntaxError; // trailing garbage
        return v;
    }

    /// Parse after stripping a `var $name =` JavaScript prefix (plugins.js).
    pub fn parseJsAssignment(self: *Parser) Error!Value {
        self.skipWs();
        if (std.mem.startsWith(u8, self.src[self.pos..], "var")) {
            self.pos += 3;
            self.skipWs();
            // skip identifier
            while (self.pos < self.src.len and
                (std.ascii.isAlphanumeric(self.src[self.pos]) or self.src[self.pos] == '_' or self.src[self.pos] == '$')) : (self.pos += 1)
            {}
            self.skipWs();
            if (self.pos < self.src.len and self.src[self.pos] == '=') {
                self.pos += 1;
                self.skipWs();
            }
        }
        // Trim a trailing `;` before delegating to the strict tail check.
        var body = self.src;
        if (body.len > 0 and body[body.len - 1] == ';') body = body[0 .. body.len - 1];
        self.src = body;
        const v = try self.parseValue();
        self.skipWs();
        if (self.pos != self.src.len) return Error.SyntaxError;
        return v;
    }

    fn skipWs(self: *Parser) void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
                self.pos += 1;
            } else if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') self.pos += 1;
            } else if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '*') {
                self.pos += 2;
                while (self.pos + 1 < self.src.len and !(self.src[self.pos] == '*' and self.src[self.pos + 1] == '/')) self.pos += 1;
                if (self.pos + 1 < self.src.len) self.pos += 2;
            } else {
                break;
            }
        }
    }

    fn peek(self: *Parser) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    fn parseValue(self: *Parser) Error!Value {
        const c = self.peek() orelse return Error.SyntaxError;
        return switch (c) {
            '{' => self.parseObject(),
            '[' => self.parseArray(),
            '"' => .{ .string = try self.parseString() },
            't', 'f' => self.parseBool(),
            'n' => self.parseNull(),
            else => self.parseNumber(),
        };
    }

    fn parseObject(self: *Parser) Error!Value {
        self.pos += 1; // '{'
        var entries = std.ArrayList(Value.Entry).empty;
        errdefer entries.deinit(self.arena.allocator());
        self.skipWs();
        if (self.peek() == '}') {
            self.pos += 1;
            return .{ .object = .{ .entries = try entries.toOwnedSlice(self.arena.allocator()) } };
        }
        while (true) {
            self.skipWs();
            const key = switch (self.peek() orelse return Error.SyntaxError) {
                '"' => try self.parseString(),
                // Bare keys (tolerant: some MV files use them in comments
                // that we already strip; kept for safety).
                else => try self.parseBareKey(),
            };
            self.skipWs();
            if (self.peek() != ':') return Error.SyntaxError;
            self.pos += 1;
            self.skipWs();
            const value = try self.parseValue();
            try entries.append(self.arena.allocator(), .{ .key = key, .value = value });
            self.skipWs();
            const c = self.peek() orelse return Error.SyntaxError;
            if (c == ',') {
                self.pos += 1;
                self.skipWs();
                // Tolerant trailing comma.
                if (self.peek() == '}') {
                    self.pos += 1;
                    break;
                }
                continue;
            }
            if (c == '}') {
                self.pos += 1;
                break;
            }
            return Error.SyntaxError;
        }
        return .{ .object = .{ .entries = try entries.toOwnedSlice(self.arena.allocator()) } };
    }

    fn parseArray(self: *Parser) Error!Value {
        self.pos += 1; // '['
        var items = std.ArrayList(Value).empty;
        errdefer items.deinit(self.arena.allocator());
        self.skipWs();
        if (self.peek() == ']') {
            self.pos += 1;
            return .{ .array = .{ .items = try items.toOwnedSlice(self.arena.allocator()) } };
        }
        while (true) {
            self.skipWs();
            const v = try self.parseValue();
            try items.append(self.arena.allocator(), v);
            self.skipWs();
            const c = self.peek() orelse return Error.SyntaxError;
            if (c == ',') {
                self.pos += 1;
                self.skipWs();
                // Tolerant trailing comma.
                if (self.peek() == ']') {
                    self.pos += 1;
                    break;
                }
                continue;
            }
            if (c == ']') {
                self.pos += 1;
                break;
            }
            return Error.SyntaxError;
        }
        return .{ .array = .{ .items = try items.toOwnedSlice(self.arena.allocator()) } };
    }

    /// Tolerant string: standard escapes AND raw control characters (the
    /// plugins.js descriptions contain real newlines). Raw control chars
    /// are preserved literally, exactly as a JS engine would see them.
    fn parseString(self: *Parser) Error![]const u8 {
        self.pos += 1; // opening quote
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.arena.allocator());
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '"') {
                self.pos += 1;
                return out.toOwnedSlice(self.arena.allocator());
            }
            if (c == '\\') {
                self.pos += 1;
                if (self.pos >= self.src.len) return Error.SyntaxError;
                const esc = self.src[self.pos];
                self.pos += 1;
                switch (esc) {
                    '"' => try out.append(self.arena.allocator(), '"'),
                    '\\' => try out.append(self.arena.allocator(), '\\'),
                    '/' => try out.append(self.arena.allocator(), '/'),
                    'b' => try out.append(self.arena.allocator(), 8),
                    'f' => try out.append(self.arena.allocator(), 12),
                    'n' => try out.append(self.arena.allocator(), '\n'),
                    'r' => try out.append(self.arena.allocator(), '\r'),
                    't' => try out.append(self.arena.allocator(), '\t'),
                    'u' => {
                        if (self.pos + 4 > self.src.len) return Error.SyntaxError;
                        const hex = self.src[self.pos .. self.pos + 4];
                        self.pos += 4;
                        const cp = std.fmt.parseInt(u21, hex, 16) catch return Error.SyntaxError;
                        var buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &buf) catch return Error.SyntaxError;
                        try out.appendSlice(self.arena.allocator(), buf[0..len]);
                    },
                    else => return Error.SyntaxError,
                }
                continue;
            }
            // Raw character — including raw control characters (tolerance).
            try out.append(self.arena.allocator(), c);
            self.pos += 1;
        }
        return Error.SyntaxError; // unterminated
    }

    fn parseBareKey(self: *Parser) Error![]const u8 {
        const start = self.pos;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '$') {
                self.pos += 1;
            } else break;
        }
        if (self.pos == start) return Error.SyntaxError;
        return self.src[start..self.pos];
    }

    fn parseBool(self: *Parser) Error!Value {
        if (std.mem.startsWith(u8, self.src[self.pos..], "true")) {
            self.pos += 4;
            return .{ .boolean = true };
        }
        if (std.mem.startsWith(u8, self.src[self.pos..], "false")) {
            self.pos += 5;
            return .{ .boolean = false };
        }
        return Error.SyntaxError;
    }

    fn parseNull(self: *Parser) Error!Value {
        if (std.mem.startsWith(u8, self.src[self.pos..], "null")) {
            self.pos += 4;
            return .null;
        }
        return Error.SyntaxError;
    }

    fn parseNumber(self: *Parser) Error!Value {
        const start = self.pos;
        if (self.peek() == '-') self.pos += 1;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (std.ascii.isDigit(c) or c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-') {
                self.pos += 1;
            } else break;
        }
        if (self.pos == start) return Error.SyntaxError;
        const text = self.src[start..self.pos];
        const n = std.fmt.parseFloat(f64, text) catch return Error.SyntaxError;
        return .{ .number = n };
    }
};

/// Convenience: parse a data file's bytes into an arena-owned Value.
/// Caller receives the parser (arena) and must deinit it.
pub fn parseAlloc(allocator: std.mem.Allocator, src: []const u8) !struct { parser: Parser, value: Value } {
    var parser = try Parser.init(allocator, src);
    errdefer parser.deinit();
    const value = try parser.parse();
    return .{ .parser = parser, .value = value };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parse standard MV map data" {
    const src =
        \\{"autoplayBgm":false,"bgm":{"name":"","volume":90},"events":[null,{"id":1,"name":"EV001","pages":[{"list":[{"code":101,"indent":0,"parameters":["",0,0,2]}]}]}],"height":13,"width":17}
    ;
    var p = try Parser.init(testing.allocator, src);
    defer p.deinit();
    const v = try p.parse();
    try testing.expectEqual(false, v.getBool("autoplayBgm", true));
    try testing.expectEqual(@as(i64, 13), v.getInt("height", 0));
    try testing.expectEqual(@as(i64, 17), v.getInt("width", 0));
    const events = v.get("events").?.arrayItems();
    try testing.expectEqual(@as(usize, 2), events.len);
    try testing.expect(events[0] == .null);
    const ev1 = events[1];
    try testing.expectEqualStrings("EV001", ev1.getString("name").?);
    const cmd = ev1.get("pages").?.arrayItems()[0].get("list").?.arrayItems()[0];
    try testing.expectEqual(@as(i64, 101), cmd.getInt("code", 0));
    try testing.expectEqualStrings("", cmd.get("parameters").?.arrayItems()[0].string);
}

test "parse plugins.js JS prefix + raw newlines + trailing comma" {
    const src = "var $plugins = [\n {\"name\": \"A\", \"status\": true, \"description\": \"line1\nline2 with, commas\", \"parameters\": {\"K\": \"V\",},},\n];";
    var p = try Parser.init(testing.allocator, src);
    defer p.deinit();
    const v = try p.parseJsAssignment();
    const items = v.arrayItems();
    try testing.expectEqual(@as(usize, 1), items.len);
    const first = items[0];
    try testing.expectEqualStrings("A", first.getString("name").?);
    try testing.expect(first.getBool("status", false));
    // The raw newline inside the description is preserved.
    const desc = first.getString("description").?;
    try testing.expect(std.mem.indexOf(u8, desc, "line1\nline2") != null);
    try testing.expectEqualStrings("V", first.get("parameters").?.getString("K").?);
}

test "malformed JSON returns SyntaxError" {
    var p = try Parser.init(testing.allocator, "{not json at all");
    defer p.deinit();
    try testing.expectError(Error.SyntaxError, p.parse());
}
