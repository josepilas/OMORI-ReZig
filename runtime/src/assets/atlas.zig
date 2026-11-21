//! OMORI Atlas system — native port of the "Atlas Loader" plugin pipeline.
//!
//! **Behavioral specification (from the existing project):**
//! * `data/Atlas.yaml` is parsed by the game's own jsyaml (js-yaml 4.1.0)
//!   inside `GTP_OmoriFixes.js` → `AtlasManager.initAtlasData()` →
//!   `window['$atlasData']` — 940 entries under the top-level `source:` key.
//! * Atlas processing is core runtime functionality: it participates in
//!   `Scene_Boot` (the v14 failure chain terminated exactly at
//!   `$atlasData is not defined`).
//! * Each entry: `img/<key>` → `{ atlasName, rect{x,y,width,height},
//!   sourceRect{x,y,width,height}, makeFunction?{name,arguments} }`.
//! * Atlas textures live at `img/atlases/<atlasName>.png` and load ON
//!   DEMAND through `makeBitmap` → `ImageManager.loadAtlas` (the payload's
//!   global atlas preload path is already inert — commented out).
//!
//! The YAML actually used by OMORI is a small subset: one top-level key,
//! two-space entry keys, four-space properties, inline flow maps with
//! quoted keys (`'y': 0` — the YAML 1.1 boolean trap) and whitespace before
//! commas (`width: 918 ,`). This parser implements exactly that subset —
//! same source file, same observable result, no universal YAML engine.

const std = @import("std");

pub const Rect = struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
};

pub const MakeFunction = struct {
    name: []const u8,
    arguments: []const []const u8,
};

pub const AtlasEntry = struct {
    /// Resource key, e.g. `img/pictures/OMO_WS.png`.
    key: []const u8,
    /// Atlas sheet this entry is cut from (`img/atlases/<atlasName>.png`).
    atlas_name: []const u8,
    /// Destination rectangle in the synthesized bitmap.
    rect: Rect,
    /// Source rectangle inside the atlas sheet.
    source_rect: Rect,
    /// Optional creator function (OMORI ships none, but the field is part
    /// of the contract — preserve it).
    make_function: ?MakeFunction = null,
};

pub const AtlasData = struct {
    /// All entries, insertion order preserved (matches $atlasData.source).
    entries: []const AtlasEntry,
    /// Key → index into entries.
    index: std.StringHashMap(usize),

    pub fn deinit(self: *AtlasData, alloc: std.mem.Allocator) void {
        for (self.entries) |e| {
            if (e.make_function) |mf| {
                for (mf.arguments) |arg| alloc.free(arg);
                alloc.free(mf.name);
                alloc.free(mf.arguments);
            }
            alloc.free(e.key);
            alloc.free(e.atlas_name);
        }
        alloc.free(self.entries);
        var it = self.index.iterator();
        while (it.next()) |e| alloc.free(e.key_ptr.*);
        self.index.deinit();
    }

    /// `AtlasManager.hasAltasData(key)` — `$atlasData.source[key] !== undefined`.
    pub fn has(self: *const AtlasData, key: []const u8) bool {
        return self.index.contains(key);
    }

    /// `AtlasManager.getImageAtlasName(key)`.
    pub fn atlasNameOf(self: *const AtlasData, key: []const u8) ?[]const u8 {
        const i = self.index.get(key) orelse return null;
        return self.entries[i].atlas_name;
    }

    /// `AtlasManager.makeBitmap` data source: the entry for a key.
    pub fn entry(self: *const AtlasData, key: []const u8) ?AtlasEntry {
        const i = self.index.get(key) orelse return null;
        return self.entries[i];
    }

    /// All entries referencing one atlas sheet (per-scene atlas lists).
    pub fn entriesForAtlas(self: *const AtlasData, alloc: std.mem.Allocator, atlas_name: []const u8) ![]const AtlasEntry {
        var out = std.ArrayList(AtlasEntry).empty;
        for (self.entries) |e| {
            if (std.mem.eql(u8, e.atlas_name, atlas_name)) try out.append(alloc, e);
        }
        return out.toOwnedSlice(alloc);
    }
};

pub const ParseError = error{
    NotAtlasYaml,
    SyntaxError,
    OutOfMemory,
};

/// Parse `data/Atlas.yaml` text into an `AtlasData` (all storage owned by
/// `alloc`; call `deinit` when done).
pub fn parseAtlasYaml(alloc: std.mem.Allocator, text: []const u8) ParseError!AtlasData {
    var entries = std.ArrayList(AtlasEntry).empty;
    errdefer {
        for (entries.items) |e| {
            if (e.make_function) |mf| {
                for (mf.arguments) |arg| alloc.free(arg);
                alloc.free(mf.name);
                alloc.free(mf.arguments);
            }
            alloc.free(e.key);
            alloc.free(e.atlas_name);
        }
        entries.deinit(alloc);
    }

    var saw_source = false;
    var current: ?AtlasEntry = null;
    var pending_props = std.ArrayList(Prop).empty;
    defer pending_props.deinit(alloc);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#') continue; // banner comments / separators

        const indent = countIndent(raw_line);

        if (indent == 0) {
            // Top-level key — must be `source:` (the only one OMORI ships).
            if (std.mem.eql(u8, line, "source:")) {
                saw_source = true;
                continue;
            }
            // Unknown top-level key: skip its block (defensive; none exist).
            continue;
        }

        if (!saw_source) continue;

        if (indent <= 2) {
            // Entry key line: `  img/pictures/OMO_WS.png:` or
            // `  img/system/w_1.png: {flow}`.
            if (current) |*c| {
                try finalizeEntry(alloc, c, &pending_props);
                try entries.append(alloc, c.*);
                current = null;
            }
            var key_part = line;
            var flow_part: []const u8 = "";
            if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
                key_part = std.mem.trim(u8, line[0..colon], " \t");
                flow_part = std.mem.trim(u8, line[colon + 1 ..], " \t");
            } else return ParseError.SyntaxError;
            if (key_part.len == 0) return ParseError.SyntaxError;

            var e = AtlasEntry{
                .key = try alloc.dupe(u8, key_part),
                .atlas_name = "",
                .rect = .{},
                .source_rect = .{},
            };
            if (flow_part.len > 0 and flow_part[0] == '{') {
                try applyFlow(alloc, &e, flow_part);
                try entries.append(alloc, e);
            } else {
                // Multi-line block form: reset the prop accumulator.
                current = e;
            }
            continue;
        }

        // Property line under a multi-line entry.
        if (current != null) {
            try pending_props.append(alloc, try parseProp(alloc, line));
        }
    }
    if (current) |*c| {
        try finalizeEntry(alloc, c, &pending_props);
        try entries.append(alloc, c.*);
    }

    if (!saw_source) return ParseError.NotAtlasYaml;
    if (entries.items.len == 0) return ParseError.NotAtlasYaml;

    var index = std.StringHashMap(usize).init(alloc);
    errdefer {
        var it = index.iterator();
        while (it.next()) |en| alloc.free(en.key_ptr.*);
        index.deinit();
    }
    for (entries.items, 0..) |e, i| {
        const key_copy = try alloc.dupe(u8, e.key);
        try index.put(key_copy, i);
    }

    return .{
        .entries = try entries.toOwnedSlice(alloc),
        .index = index,
    };
}

const Prop = struct {
    name: []const u8, // owned
    value: []const u8, // owned
    flow: ?[]const u8 = null, // owned flow-map body (without braces)
};

fn parseProp(alloc: std.mem.Allocator, line: []const u8) !Prop {
    const colon = std.mem.indexOfScalar(u8, line, ':') orelse return ParseError.SyntaxError;
    var name = std.mem.trim(u8, line[0..colon], " \t");
    var value = std.mem.trim(u8, line[colon + 1 ..], " \t");
    // Quoted property names ('y': 0 — the YAML 1.1 boolean trap).
    if (name.len >= 2 and name[0] == '\'' and name[name.len - 1] == '\'') {
        name = name[1 .. name.len - 1];
    }
    if (value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'') {
        value = value[1 .. value.len - 1];
    }
    if (value.len > 0 and value[0] == '{') {
        return .{
            .name = try alloc.dupe(u8, name),
            .value = try alloc.dupe(u8, value),
            .flow = try alloc.dupe(u8, value),
        };
    }
    return .{
        .name = try alloc.dupe(u8, name),
        .value = try alloc.dupe(u8, value),
    };
}

/// Apply a property (already parsed) to an entry.
fn applyProp(alloc: std.mem.Allocator, e: *AtlasEntry, prop: Prop) !void {
    defer {
        alloc.free(prop.name);
        alloc.free(prop.value);
        if (prop.flow) |f| alloc.free(f);
    }
    if (std.mem.eql(u8, prop.name, "atlasName")) {
        e.atlas_name = try alloc.dupe(u8, prop.value);
    } else if (std.mem.eql(u8, prop.name, "rect")) {
        if (prop.flow) |f| e.rect = try parseFlowRect(alloc, f) else return ParseError.SyntaxError;
    } else if (std.mem.eql(u8, prop.name, "sourceRect")) {
        if (prop.flow) |f| e.source_rect = try parseFlowRect(alloc, f) else return ParseError.SyntaxError;
    } else if (std.mem.eql(u8, prop.name, "makeFunction")) {
        if (prop.flow) |f| e.make_function = try parseFlowMakeFunction(alloc, f);
    }
    // Unknown properties are preserved by the JS object model; the native
    // runtime ignores what OMORI never reads.
}

/// Apply a full inline flow map `{atlasName: X, rect: {...}, ...}`.
fn applyFlow(alloc: std.mem.Allocator, e: *AtlasEntry, flow: []const u8) !void {
    const body = unwrapBraces(flow) orelse return ParseError.SyntaxError;
    var it = FlowIterator{ .src = body };
    while (it.next()) |pair| {
        const prop = try parseFlowPair(alloc, pair);
        try applyProp(alloc, e, prop);
    }
}

fn unwrapBraces(flow: []const u8) ?[]const u8 {
    if (flow.len < 2 or flow[0] != '{' or flow[flow.len - 1] != '}') return null;
    return flow[1 .. flow.len - 1];
}

fn parseFlowPair(alloc: std.mem.Allocator, pair: []const u8) !Prop {
    var trimmed = std.mem.trim(u8, pair, " \t");
    // Find the top-level colon (not inside a nested flow map).
    var depth: usize = 0;
    var colon_idx: ?usize = null;
    for (trimmed, 0..) |c, i| {
        switch (c) {
            '{', '[' => depth += 1,
            '}', ']' => {
                if (depth > 0) depth -= 1;
            },
            ':' => {
                if (depth == 0 and colon_idx == null) colon_idx = i;
            },
            else => {},
        }
    }
    const ci = colon_idx orelse return ParseError.SyntaxError;
    var name = std.mem.trim(u8, trimmed[0..ci], " \t");
    var value = std.mem.trim(u8, trimmed[ci + 1 ..], " \t");
    if (name.len >= 2 and name[0] == '\'' and name[name.len - 1] == '\'') name = name[1 .. name.len - 1];
    if (name.len >= 2 and name[0] == '"' and name[name.len - 1] == '"') name = name[1 .. name.len - 1];
    if (value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'') value = value[1 .. value.len - 1];
    if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') value = value[1 .. value.len - 1];
    return .{
        .name = try alloc.dupe(u8, name),
        .value = try alloc.dupe(u8, value),
        .flow = if (value.len > 0 and value[0] == '{') try alloc.dupe(u8, value) else null,
    };
}

/// Split a flow-map body at top-level commas, tolerating arbitrary
/// whitespace around separators (`width: 918 , height: 351`).
const FlowIterator = struct {
    src: []const u8,
    pos: usize = 0,

    fn next(self: *FlowIterator) ?[]const u8 {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t')) self.pos += 1;
        if (self.pos >= self.src.len) return null;
        const start = self.pos;
        var depth: usize = 0;
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            switch (c) {
                '{', '[' => depth += 1,
                '}', ']' => {
                    if (depth > 0) depth -= 1;
                },
                ',' => {
                    if (depth == 0) {
                        const piece = self.src[start..self.pos];
                        self.pos += 1;
                        return piece;
                    }
                },
                else => {},
            }
            self.pos += 1;
        }
        return self.src[start..self.pos];
    }
};

fn parseFlowRect(alloc: std.mem.Allocator, flow: []const u8) !Rect {
    _ = alloc;
    const body = unwrapBraces(std.mem.trim(u8, flow, " \t")) orelse return ParseError.SyntaxError;
    var rect = Rect{};
    var it = FlowIterator{ .src = body };
    while (it.next()) |pair| {
        const ci = std.mem.indexOfScalar(u8, pair, ':') orelse return ParseError.SyntaxError;
        var name = std.mem.trim(u8, pair[0..ci], " \t");
        const value = std.mem.trim(u8, pair[ci + 1 ..], " \t");
        if (name.len >= 2 and name[0] == '\'' and name[name.len - 1] == '\'') name = name[1 .. name.len - 1];
        const n = std.fmt.parseInt(i32, value, 10) catch return ParseError.SyntaxError;
        if (std.mem.eql(u8, name, "x")) rect.x = n;
        if (std.mem.eql(u8, name, "y")) rect.y = n;
        if (std.mem.eql(u8, name, "width")) rect.width = n;
        if (std.mem.eql(u8, name, "height")) rect.height = n;
    }
    return rect;
}

fn parseFlowMakeFunction(alloc: std.mem.Allocator, flow: []const u8) !MakeFunction {
    const body = unwrapBraces(std.mem.trim(u8, flow, " \t")) orelse return ParseError.SyntaxError;
    var name: []const u8 = "";
    var args = std.ArrayList([]const u8).empty;
    errdefer {
        for (args.items) |a| alloc.free(a);
        args.deinit(alloc);
    }
    var it = FlowIterator{ .src = body };
    while (it.next()) |pair| {
        const ci = std.mem.indexOfScalar(u8, pair, ':') orelse return ParseError.SyntaxError;
        const pname = std.mem.trim(u8, pair[0..ci], " \t");
        const value = std.mem.trim(u8, pair[ci + 1 ..], " \t");
        if (std.mem.eql(u8, pname, "name")) {
            name = try alloc.dupe(u8, value);
        } else if (std.mem.eql(u8, pname, "arguments")) {
            // Array literal of quoted strings.
            if (value.len >= 2 and value[0] == '[' and value[value.len - 1] == ']') {
                var ait = std.mem.splitScalar(u8, value[1 .. value.len - 1], ',');
                while (ait.next()) |raw| {
                    var arg = std.mem.trim(u8, raw, " \t");
                    if (arg.len >= 2 and arg[0] == '"' and arg[arg.len - 1] == '"') arg = arg[1 .. arg.len - 1];
                    if (arg.len >= 2 and arg[0] == '\'' and arg[arg.len - 1] == '\'') arg = arg[1 .. arg.len - 1];
                    if (arg.len > 0) try args.append(alloc, try alloc.dupe(u8, arg));
                }
            }
        }
    }
    return .{ .name = name, .arguments = try args.toOwnedSlice(alloc) };
}

fn countIndent(line: []const u8) usize {
    var n: usize = 0;
    for (line) |c| {
        if (c == ' ') n += 1 else break;
    }
    return n;
}

/// Apply accumulated property lines to a multi-line entry and free them.
fn finalizeEntry(alloc: std.mem.Allocator, e: *AtlasEntry, pending_props: *std.ArrayList(Prop)) !void {
    for (pending_props.items) |prop| {
        try applyProp(alloc, e, prop);
    }
    pending_props.clearRetainingCapacity();
}

// ---------------------------------------------------------------------------
// Tests — including the real payload quirks (quoted 'y', spaces before
// commas, inline flow entries, banner comments).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "parse Atlas.yaml subset: multi-line + flow + quoted keys" {
    const alloc = testing.allocator;
    const src =
        \\source:
        \\
        \\###################################################################
        \\# SYSTEM ATLAS
        \\###################################################################
        \\
        \\  img/pictures/OMO_WS.png:
        \\    atlasName: Omori_TitleScreen
        \\    rect: {x: 0, y: 0, width: 918, height: 351}
        \\    sourceRect: {x: 0, y: 0, width: 918 , height: 351}
        \\
        \\  img/system/w_1.png: {atlasName: itemWeapon, rect: {x: 0, 'y': 0, width: 106, height: 106}, sourceRect: {x: 1, 'y': 1, width: 106 , height: 106}}
        \\
        \\  img/pictures/OMO_TITLE_WS.png:
        \\    atlasName: Omori_TitleScreen
        \\    rect: {x: 0, y: 0, width: 277, height: 150}
        \\    sourceRect: {x: 918, y: 0, width: 277, height: 150}
        \\
    ;
    var data = try parseAtlasYaml(alloc, src);
    defer data.deinit(alloc);

    try testing.expectEqual(@as(usize, 3), data.entries.len);

    const ws = data.entry("img/pictures/OMO_WS.png").?;
    try testing.expectEqualStrings("Omori_TitleScreen", ws.atlas_name);
    try testing.expectEqual(@as(i32, 918), ws.rect.width);
    try testing.expectEqual(@as(i32, 351), ws.rect.height);
    try testing.expectEqual(@as(i32, 0), ws.source_rect.y);

    // Flow-style entry with quoted 'y' keys and space before comma.
    const w1 = data.entry("img/system/w_1.png").?;
    try testing.expectEqualStrings("itemWeapon", w1.atlas_name);
    try testing.expectEqual(@as(i32, 1), w1.source_rect.x);
    try testing.expectEqual(@as(i32, 106), w1.source_rect.width);

    // Manager API semantics.
    try testing.expect(data.has("img/pictures/OMO_WS.png"));
    try testing.expect(!data.has("img/missing.png"));
    try testing.expectEqualStrings("itemWeapon", data.atlasNameOf("img/system/w_1.png").?);

    // Per-atlas listing.
    const title = try data.entriesForAtlas(alloc, "Omori_TitleScreen");
    defer alloc.free(title);
    try testing.expectEqual(@as(usize, 2), title.len);
}

test "missing source key is rejected loudly" {
    const alloc = testing.allocator;
    try testing.expectError(ParseError.NotAtlasYaml, parseAtlasYaml(alloc, "notatlas: yes"));
}
