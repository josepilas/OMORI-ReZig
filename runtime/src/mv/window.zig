//! v28 — windows: the 9-slice system window + message/choice/text
//! rendering used by the field, menu, and battle shells.
//!
//! MV semantics implemented:
//!   * Window skin: img/system/Window.png, 9-slice (corners/edges), with
//!     a solid dark fallback (1x1 white surface scaled + alpha) when the
//!     skin cannot be decoded, so text is NEVER lost.
//!   * Window_Message: bottom-anchored (positionType 2), 4 text lines,
//!     face graphic (img/faces/<name>.png, 4-col sheet) at the left,
//!     pause indicator, input advances pages.
//!   * Window_ChoiceList: right-aligned above the message window,
//!     up/down selection, highlight.
//!
//! OMORI look approximated: near-black windows, white GameFont text.
//! The exact windowskin pixels come from the real Window.png when it
//! decodes.

const std = @import("std");
const log = @import("../core/log.zig");
const draw_mod = @import("../renderer/draw.zig");
const font_mod = @import("../text/font.zig");
const sprites_mod = @import("sprites.zig");
const game_mod = @import("game.zig");
const dialogue = @import("dialogue.zig");

pub const GAME_W: i32 = draw_mod.GAME_W;
pub const GAME_H: i32 = draw_mod.GAME_H;

/// 9-slice margin of the MV windowskin.
pub const SKIN_MARGIN: i32 = 24;
/// Message window metrics (MV: 4 lines).
pub const LINE_HEIGHT: i32 = 30;
pub const FONT_SIZE: u32 = 24;
pub const MSG_FONT_SIZE: u32 = 28;
pub const MSG_LINE_HEIGHT: i32 = 24;
pub const MSG_WINDOW_HEIGHT: i32 = MSG_LINE_HEIGHT * 4 + 16;
pub const MSG_WINDOW_Y: i32 = GAME_H - MSG_WINDOW_HEIGHT - 8;
pub const MSG_WINDOW_X: i32 = 16;
pub const MSG_WINDOW_WIDTH: i32 = GAME_W - 32;
pub const FACE_SIZE: i32 = 96;

/// A 1x1 white RGBA pixel used to draw solid/tinted rects through the
/// sprite path (the draw list's only rect primitive).
const white_px = [4]u8{ 255, 255, 255, 255 };
const black_px = [4]u8{ 0, 0, 0, 255 };

pub const WindowRenderer = struct {
    alloc: std.mem.Allocator,
    font: *font_mod.Font,
    loader: *sprites_mod.Loader,
    game: ?*game_mod.GameObjects = null,
    skin: ?sprites_mod.Sprite = null,
    skin_checked: bool = false,
    solid: draw_mod.Surface = .{ .width = 1, .height = 1, .pixels = &white_px },
    dark: draw_mod.Surface = .{ .width = 1, .height = 1, .pixels = &black_px },
    /// Pause-indicator blink state.
    blink_frame: u64 = 0,

    pub fn init(alloc: std.mem.Allocator, font: *font_mod.Font, loader: *sprites_mod.Loader) WindowRenderer {
        return .{ .alloc = alloc, .font = font, .loader = loader };
    }

    /// Register the 1x1 solid surface with this frame's draw list and
    /// draw a solid rect (x,y,w,h) with 0..255 opacity.
    fn fillRect(self: *WindowRenderer, dl: *draw_mod.DrawList, x: i32, y: i32, w: i32, h: i32, opacity: u8) void {
        const handle = dl.addSurface(&self.solid);
        dl.pushSpriteStable(handle, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .x = x, .y = y, .w = w, .h = h }, opacity);
    }

    /// Fetch the windowskin once (fallback: flat dark window).
    fn skinSprite(self: *WindowRenderer, dl: *draw_mod.DrawList) ?sprites_mod.Sprite {
        if (!self.skin_checked) {
            self.skin_checked = true;
            self.skin = self.loader.get(dl, "img/system/Window.png");
            if (self.skin == null) {
                log.event(.res, .note, "window: no decodable Window.png — flat dark window style", .{});
            }
        }
        if (self.skin != null) {
            // re-register the sheet surface each frame (cheap pointer add)
            return self.loader.get(dl, "img/system/Window.png");
        }
        return null;
    }

    /// 9-slice draw of a window rect at (x,y,w,h).
    pub fn drawWindow(self: *WindowRenderer, dl: *draw_mod.DrawList, x: i32, y: i32, w: i32, h: i32) void {
        if (self.skinSprite(dl)) |s| {
            const m = SKIN_MARGIN;
            // MV Window.png is a collection of regions, not one large
            // nine-slice. The 96px background is top-left; the frame is
            // top-right. Its lower half contains cursor/pause/palette.
            const ox = s.src.x;
            const oy = s.src.y;
            const frame_x = ox + 96;
            blit(dl, s, .{ .x = ox, .y = oy, .w = 96, .h = 96 }, .{ .x = x, .y = y, .w = w, .h = h });
            blit(dl, s, .{ .x = frame_x, .y = oy, .w = m, .h = m }, .{ .x = x, .y = y, .w = m, .h = m });
            blit(dl, s, .{ .x = frame_x + 96 - m, .y = oy, .w = m, .h = m }, .{ .x = x + w - m, .y = y, .w = m, .h = m });
            blit(dl, s, .{ .x = frame_x, .y = oy + 96 - m, .w = m, .h = m }, .{ .x = x, .y = y + h - m, .w = m, .h = m });
            blit(dl, s, .{ .x = frame_x + 96 - m, .y = oy + 96 - m, .w = m, .h = m }, .{ .x = x + w - m, .y = y + h - m, .w = m, .h = m });
            blit(dl, s, .{ .x = frame_x + m, .y = oy, .w = 96 - 2 * m, .h = m }, .{ .x = x + m, .y = y, .w = w - 2 * m, .h = m });
            blit(dl, s, .{ .x = frame_x + m, .y = oy + 96 - m, .w = 96 - 2 * m, .h = m }, .{ .x = x + m, .y = y + h - m, .w = w - 2 * m, .h = m });
            blit(dl, s, .{ .x = frame_x, .y = oy + m, .w = m, .h = 96 - 2 * m }, .{ .x = x, .y = y + m, .w = m, .h = h - 2 * m });
            blit(dl, s, .{ .x = frame_x + 96 - m, .y = oy + m, .w = m, .h = 96 - 2 * m }, .{ .x = x + w - m, .y = y + m, .w = m, .h = h - 2 * m });
        } else {
            // flat fallback: dark translucent body + bright hairline border
            const dark_handle = dl.addSurface(&self.dark);
            dl.pushSpriteStable(dark_handle, .{ .x = 0, .y = 0, .w = 1, .h = 1 }, .{ .x = x + 2, .y = y + 2, .w = w - 4, .h = h - 4 }, 232);
            self.fillRect(dl, x, y, w, 2, 255);
            self.fillRect(dl, x, y + h - 2, w, 2, 255);
            self.fillRect(dl, x, y, 2, h, 255);
            self.fillRect(dl, x + w - 2, y, 2, h, 255);
        }
    }

    /// Wrap `text` to max_width, appending owned slices into lines_out
    /// (pointers into `text` — the caller keeps it alive for the frame).
    pub fn wrapLine(self: *WindowRenderer, text: []const u8, max_width: i32, lines_out: *std.ArrayList([]const u8)) void {
        self.wrapLineSized(text, max_width, FONT_SIZE, lines_out) catch {};
    }

    fn wrapLineSized(self: *WindowRenderer, text: []const u8, max_width: i32, size: u32, lines_out: *std.ArrayList([]const u8)) !void {
        if (std.mem.indexOfScalar(u8, text, '\n') != null) {
            var paragraphs = std.mem.splitScalar(u8, text, '\n');
            while (paragraphs.next()) |paragraph| try self.wrapLineSized(paragraph, max_width, size, lines_out);
            return;
        }
        if (text.len == 0) {
            try lines_out.append(self.alloc, text);
            return;
        }
        var start: usize = 0;
        while (start < text.len) {
            var end = text.len;
            while (end > start + 1) {
                const slice = text[start..end];
                const m = self.font.measureText(slice, size);
                if (m.width <= max_width) break;
                // back up to a space for word wrap when possible
                if (std.mem.lastIndexOfScalar(u8, text[start..end], ' ')) |sp| {
                    if (sp > 0) {
                        end = start + sp;
                        continue;
                    }
                }
                // Keep at least one whole character even for an oversized glyph.
                var previous = end - 1;
                while (previous > start and (text[previous] & 0xc0) == 0x80) previous -= 1;
                if (previous == start) break;
                end = previous;
            }
            if (end <= start) end = start + 1;
            try lines_out.append(self.alloc, text[start..end]);
            start = end;
            if (start < text.len and text[start] == ' ') start += 1;
        }
    }

    /// Draw a text line at (x, y) with an RGB color.
    pub fn drawText(self: *WindowRenderer, dl: *draw_mod.DrawList, x: i32, y: i32, text: []const u8, r: u8, g: u8, b: u8) void {
        self.drawTextSized(dl, x, y, text, FONT_SIZE, r, g, b);
    }

    pub fn drawTextSized(self: *WindowRenderer, dl: *draw_mod.DrawList, x: i32, y: i32, text: []const u8, size: u32, r: u8, g: u8, b: u8) void {
        if (text.len == 0) return;
        const run = rasterizeLineSized(self.alloc, dl, self.font, text, size) catch return;
        dl.pushText(run, x, y, r, g, b);
    }

    /// The message window (Game_Message → visual).
    pub fn drawMessage(self: *WindowRenderer, dl: *draw_mod.DrawList, msg: *game_mod.GameMessage) void {
        self.blink_frame += 1;

        const pos_y: i32 = switch (msg.position_type) {
            0 => 8, // top (OMORI inset)
            1 => (GAME_H - MSG_WINDOW_HEIGHT) / 2,
            else => MSG_WINDOW_Y, // bottom (2)
        };
        const has_face = msg.face_name.len > 0;
        const text_x: i32 = MSG_WINDOW_X + if (has_face) FACE_SIZE + 24 else @as(i32, 18);
        const inner_w: i32 = MSG_WINDOW_X + MSG_WINDOW_WIDTH - text_x - 18;

        self.drawWindow(dl, MSG_WINDOW_X, pos_y, MSG_WINDOW_WIDTH, MSG_WINDOW_HEIGHT);

        if (has_face) {
            const key = std.fmt.allocPrint(self.alloc, "img/faces/{s}.png", .{msg.face_name}) catch null;
            if (key) |k| {
                defer self.alloc.free(k);
                if (self.loader.get(dl, k)) |face| {
                    if (faceSourceRect(face, msg.face_index)) |fsrc|
                        blit(dl, face, fsrc, .{ .x = MSG_WINDOW_X + 8, .y = pos_y + 8, .w = FACE_SIZE, .h = FACE_SIZE });
                }
            }
        }

        if (msg.texts.items.len == 0) return;
        if (msg.layout == null) {
            msg.layout = self.layoutMessage(msg, inner_w) catch return;
            msg.display_line_count = msg.layout.?.lines.len;
        }
        const layout = &msg.layout.?;
        const start = msg.page_index * 4;
        const stop = @min(start + 4, layout.lines.len);
        if (start < stop) for (layout.lines[start..stop], 0..) |line, index| {
            const visible = if (msg.is_scroll_text) line else layout.visible(line);
            self.drawTextSized(dl, text_x, pos_y + 4 + @as(i32, @intCast(index)) * MSG_LINE_HEIGHT, visible, MSG_FONT_SIZE, 255, 255, 255);
        };
        const waiting = layout.paused or (layout.ready and !layout.auto_end and !msg.choicesVisible());
        if (waiting and (self.blink_frame / 20) % 2 == 0) {
            self.drawText(dl, GAME_W / 2 - 6, pos_y + MSG_WINDOW_HEIGHT - 28, "v", 200, 200, 200);
        }
    }

    fn layoutMessage(self: *WindowRenderer, msg: *const game_mod.GameMessage, width: i32) !dialogue.Layout {
        var bytes: std.ArrayList(u8) = .empty;
        defer bytes.deinit(self.alloc);
        var cues: std.ArrayList(dialogue.Cue) = .empty;
        defer cues.deinit(self.alloc);
        for (msg.texts.items, 0..) |raw, i| {
            if (i != 0) try bytes.append(self.alloc, '\n');
            try appendNormalized(self.alloc, &bytes, raw, self.game, &cues);
        }
        const text = try bytes.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(text);
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        var lines: std.ArrayList([]const u8) = .empty;
        defer lines.deinit(self.alloc);
        try self.wrapLineSized(text, width, MSG_FONT_SIZE, &lines);
        const owned_lines = try lines.toOwnedSlice(self.alloc);
        errdefer self.alloc.free(owned_lines);
        return .{ .text = text, .lines = owned_lines, .cues = try cues.toOwnedSlice(self.alloc) };
    }

    /// The choice window (right-aligned above the message window).
    pub fn drawChoices(self: *WindowRenderer, dl: *draw_mod.DrawList, msg: *const game_mod.GameMessage) void {
        if (msg.choices.items.len == 0) return;
        var max_w: i32 = 96;
        for (msg.choices.items) |c| {
            const readable = normalizeMessage(self.alloc, c, self.game) catch continue;
            defer self.alloc.free(readable);
            const m = self.font.measureText(readable, FONT_SIZE);
            if (m.width > max_w) max_w = m.width;
        }
        const w = @min(max_w + 48, GAME_W - 32);
        const visible: usize = @min(msg.choices.items.len, @as(usize, @intCast((MSG_WINDOW_Y - 24) / LINE_HEIGHT)));
        const selection: usize = @intCast(std.math.clamp(msg.choice_index, 0, @as(i32, @intCast(msg.choices.items.len)) - 1));
        const first = if (selection >= visible) selection - visible + 1 else 0;
        const h = @as(i32, @intCast(visible)) * LINE_HEIGHT + 16;
        const x = GAME_W - w - 18;
        const y = @max(8, MSG_WINDOW_Y - h - 12);

        self.drawWindow(dl, x, y, w, h);
        for (msg.choices.items[first..][0..visible], first..) |c, idx| {
            const selected = idx == msg.choice_index;
            const color: u8 = if (selected) 255 else 150;
            const readable = normalizeMessage(self.alloc, c, self.game) catch continue;
            defer self.alloc.free(readable);
            self.drawText(dl, x + 26, y + 8 + @as(i32, @intCast(idx - first)) * LINE_HEIGHT, readable, color, color, color);
            if (selected) {
                self.drawText(dl, x + 8, y + 8 + @as(i32, @intCast(idx - first)) * LINE_HEIGHT, ">", 255, 255, 255);
            }
        }
    }
};

fn faceSourceRect(face: sprites_mod.Sprite, index: i32) ?draw_mod.Rect {
    if (index < 0) return null;
    // OMORI BASE sets Window_Base._faceWidth/_faceHeight to 106.
    // MainCharacters_DreamWorld is 424×1378: four columns, 13 rows.
    const cell = 106;
    const x = @mod(index, 4) * cell;
    const y = @divTrunc(index, 4) * cell;
    if (x + cell > face.width or y + cell > face.height) return null;
    return .{ .x = face.src.x + x, .y = face.src.y + y, .w = cell, .h = cell };
}

/// The visible subset of MV/YEP escape conversion. Layout consumes line
/// breaks; timing, color and animation commands must not become glyphs.
fn normalizeMessage(alloc: std.mem.Allocator, text: []const u8, game: ?*game_mod.GameObjects) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    try appendNormalized(alloc, &out, text, game, null);
    return out.toOwnedSlice(alloc);
}

fn appendNormalized(alloc: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, game: ?*game_mod.GameObjects, cues: ?*std.ArrayList(dialogue.Cue)) !void {
    var index: usize = 0;
    scan: while (index < text.len) {
        if (text[index] == '<') {
            if (std.mem.indexOfScalarPos(u8, text, index, '>')) |end| {
                const tag = text[index + 1 .. end];
                if (std.ascii.eqlIgnoreCase(tag, "br") or std.ascii.eqlIgnoreCase(tag, "line break")) {
                    try out.append(alloc, '\n');
                    index = end + 1;
                    continue;
                }
                if (std.ascii.eqlIgnoreCase(tag, "wordwrap")) {
                    index = end + 1;
                    continue;
                }
            }
        }
        if (text[index] != '\\') {
            try out.append(alloc, text[index]);
            index += 1;
            continue;
        }
        index += 1;
        if (index == text.len) break;
        if (text[index] == '\\') {
            try out.append(alloc, '\\');
            index += 1;
            continue;
        }
        // YEP quick macros are matched by their configured prefix even
        // beside a word: \aubWhy must retain "Why". These macros set a
        // speaker name in the original UI; the face already identifies
        // the speaker in this message renderer.
        for ([_][]const u8{ "spxh", "omo", "aub", "kel", "her", "bas", "who", "mar", "min", "art", "mai", "swh", "smm", "jaw" }) |macro| {
            if (index + macro.len <= text.len and std.ascii.eqlIgnoreCase(text[index .. index + macro.len], macro)) {
                index += macro.len;
                continue :scan;
            }
        }
        const start = index;
        while (index < text.len and std.ascii.isAlphabetic(text[index])) : (index += 1) {}
        const code = text[start..index];
        if (code.len == 0) {
            const ctrl: ?dialogue.Control = switch (text[index]) {
                '.' => .wait_short,
                '|' => .wait_long,
                '!' => .pause,
                '>' => .fast_on,
                '<' => .fast_off,
                '^' => .auto_end,
                else => null,
            };
            if (cues) |list| if (ctrl) |control| try list.append(alloc, .{ .offset = out.items.len, .control = control });
            index += 1;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(code, "lb")) {
            try out.append(alloc, '\n');
            continue;
        }
        // YEP's speaker tag, e.g. \n<SNAKE>. Keep its content readable.
        if (std.ascii.eqlIgnoreCase(code, "n") and index < text.len and text[index] == '<') {
            if (std.mem.indexOfScalarPos(u8, text, index, '>')) |end| {
                try out.appendSlice(alloc, text[index + 1 .. end]);
                try out.appendSlice(alloc, ":\n");
                index = end + 1;
                continue;
            }
        }
        var argument: ?i32 = null;
        if (index < text.len and text[index] == '[') {
            if (std.mem.indexOfScalarPos(u8, text, index, ']')) |end| {
                argument = std.fmt.parseInt(i32, text[index + 1 .. end], 10) catch null;
                index = end + 1;
            }
        }
        if (game) |objects| {
            if (argument) |value| {
                if (std.ascii.eqlIgnoreCase(code, "v")) {
                    var number: [32]u8 = undefined;
                    try out.appendSlice(alloc, try std.fmt.bufPrint(&number, "{d}", .{objects.variables.value(@intCast(@max(value, 0)))}));
                } else if (std.ascii.eqlIgnoreCase(code, "n")) {
                    if (objects.actors.actor(value)) |actor| try out.appendSlice(alloc, actor.name);
                } else if (std.ascii.eqlIgnoreCase(code, "p")) {
                    if (value > 0 and value <= objects.party.members.items.len) {
                        if (objects.actors.actor(objects.party.members.items[@intCast(value - 1)])) |actor| try out.appendSlice(alloc, actor.name);
                    }
                } else {
                    const path: ?[]const u8 = if (std.ascii.eqlIgnoreCase(code, "ni")) "data/Items.json" else if (std.ascii.eqlIgnoreCase(code, "nw")) "data/Weapons.json" else if (std.ascii.eqlIgnoreCase(code, "na")) "data/Armors.json" else if (std.ascii.eqlIgnoreCase(code, "ns")) "data/Skills.json" else null;
                    if (path) |file_path| {
                        if (objects.db.get(file_path)) |file| {
                            const entries = file.value.arrayItems();
                            if (value >= 0 and value < entries.len) try out.appendSlice(alloc, entries[@intCast(value)].getString("name") orelse "");
                        }
                    }
                }
            } else if (std.ascii.eqlIgnoreCase(code, "itemget")) {
                try out.appendSlice(alloc, objects.party.lastGainedItemName());
                const amount: i64 = objects.party.last_gained.amount;
                if (@abs(amount) > 1) {
                    var count_text: [32]u8 = undefined;
                    try out.appendSlice(alloc, try std.fmt.bufPrint(&count_text, " x{d}", .{@abs(amount)}));
                }
            } else if (std.ascii.eqlIgnoreCase(code, "g")) {
                if (objects.db.get("data/System.json")) |file| try out.appendSlice(alloc, file.value.getString("currencyUnit") orelse "CLAMS");
            }
        }
    }
}

fn blit(dl: *draw_mod.DrawList, s: sprites_mod.Sprite, src: draw_mod.Rect, dst: draw_mod.Rect) void {
    // Small windows can have no interior after the two skin margins.
    // Such slices contribute no pixels and must not become invalid draws.
    if (src.w <= 0 or src.h <= 0 or dst.w <= 0 or dst.h <= 0) return;
    // clamp src inside the sprite's real rect (defensive vs atlas data)
    var r = src;
    if (r.x + r.w > s.src.x + s.src.w) r.w = s.src.x + s.src.w - r.x;
    if (r.y + r.h > s.src.y + s.src.h) r.h = s.src.y + s.src.h - r.y;
    if (r.w <= 0 or r.h <= 0) return;
    dl.pushSpriteStable(s.handle, r, dst, 255);
}

fn rasterizeLineSized(alloc: std.mem.Allocator, dl: *draw_mod.DrawList, font: *font_mod.Font, text: []const u8, size: u32) !u32 {
    const m = font.measureText(text, size);
    var glyphs: std.ArrayList(draw_mod.DrawList.LaidGlyph) = .empty;
    defer glyphs.deinit(alloc);
    var pen_x: i32 = 0;
    var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    var prev_gid: u16 = 0;
    const sc = font.scale(size);
    while (iter.nextCodepoint()) |cp| {
        const gid = font.glyphId(cp);
        const kern: i32 = @intFromFloat(@round(@as(f64, @floatFromInt(font.kernUnits(prev_gid, gid))) * sc));
        pen_x += kern;
        const g = try font.rasterize(gid, size);
        glyphs.append(alloc, .{ .glyph = g.*, .x = pen_x }) catch {};
        pen_x += g.advance;
        prev_gid = gid;
    }
    const height: u32 = @intCast(@max(@as(i32, @intCast(size)) + 4, 18));
    return dl.addTextRun(glyphs.items, @intCast(@max(m.width, 0)), height);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "dialogue: normalized UTF-8, waits, fast text and choice input share a single layout" {
    const a = testing.allocator;
    const path = std.process.getEnvVarOwned(a, "OMORI_FONT_SMOKE_PATH") catch return error.SkipZigTest;
    defer a.free(path);
    const bytes = try std.fs.cwd().readFileAlloc(a, path, 32 * 1024 * 1024);
    defer a.free(bytes);
    var font = try font_mod.Font.init(a, bytes);
    defer font.deinit();
    var window = WindowRenderer.init(a, &font, undefined);
    var msg = game_mod.GameMessage.init(a);
    defer msg.deinit();
    msg.add("éQ\\!日\\.B\\|\\>Fast\\<é.");
    msg.setChoices(&.{ "ONE", "TWO" }, 0, -1);
    msg.layout = try window.layoutMessage(&msg, 500);
    const layout = &msg.layout.?;
    const line = layout.lines[0];
    try testing.expectEqualStrings("éQ日BFasté.", line);
    msg.update(false, false, null);
    try testing.expectEqualStrings("é", layout.visible(line));
    msg.update(true, false, null);
    try testing.expectEqualStrings("éQ", layout.visible(line));
    try testing.expect(layout.paused and !msg.choicesVisible());
    msg.update(false, false, null);
    try testing.expect(layout.paused);
    msg.update(true, false, null);
    try testing.expectEqualStrings("éQ日", layout.visible(line));
    try testing.expectEqual(@as(u8, 15), layout.wait);
    for (0..15) |_| msg.update(true, false, null);
    try testing.expectEqualStrings("éQ日", layout.visible(line));
    msg.update(false, false, null);
    try testing.expectEqual(@as(u8, 60), layout.wait);
    for (0..60) |_| msg.update(false, false, null);
    msg.update(false, false, null);
    try testing.expectEqualStrings("éQ日BFast", layout.visible(line));
    msg.update(true, false, null);
    try testing.expectEqualStrings(line, layout.visible(line));
    try testing.expect(msg.choicesVisible() and msg.choice_result == null);
    msg.update(false, true, null); // Cancel disabled by this event.
    try testing.expect(msg.choicesVisible());
    msg.choice_index = 1;
    msg.update(true, false, null);
    try testing.expectEqual(@as(?i32, 1), msg.choice_result);
    try testing.expect(!msg.isBusy());

    msg.instant_text = true;
    msg.add("first\\!second\\^");
    msg.layout = try window.layoutMessage(&msg, 500);
    msg.update(false, false, null);
    try testing.expectEqualStrings("first", msg.layout.?.visible(msg.layout.?.lines[0]));
    msg.update(true, false, null);
    try testing.expect(msg.layout.?.ready);
    msg.update(false, false, null);
    try testing.expect(!msg.isBusy()); // Authored no-end-pause.

    msg.add("à<br>é<br>î<br>ò<br>ú");
    msg.layout = try window.layoutMessage(&msg, 180);
    msg.display_line_count = msg.layout.?.lines.len;
    msg.setChoices(&.{"OK"}, 0, -2);
    msg.update(false, false, null);
    try testing.expect(!msg.choicesVisible());
    msg.update(true, false, null);
    try testing.expectEqual(@as(usize, 1), msg.page_index);
    try testing.expectEqualStrings("", msg.layout.?.visible(msg.layout.?.lines[4]));
    msg.update(false, false, null);
    try testing.expect(msg.choicesVisible());
    msg.update(false, true, null);
    try testing.expectEqual(@as(?i32, -2), msg.choice_result);

    msg.add("éééé");
    msg.layout = try window.layoutMessage(&msg, 1);
    try testing.expectEqual(@as(usize, 4), msg.layout.?.lines.len);
    for (msg.layout.?.lines) |wrapped| try testing.expectEqualStrings("é", wrapped);
}

test "message portrait: OMORI face cells include late Hero rows" {
    const face = sprites_mod.Sprite{ .handle = 0, .src = .{ .x = 0, .y = 0, .w = 424, .h = 1378 }, .width = 424, .height = 1378 };
    try testing.expectEqual(draw_mod.Rect{ .x = 318, .y = 0, .w = 106, .h = 106 }, faceSourceRect(face, 3).?);
    try testing.expectEqual(draw_mod.Rect{ .x = 0, .y = 1060, .w = 106, .h = 106 }, faceSourceRect(face, 40).?);
    try testing.expect(faceSourceRect(face, 52) == null);
}

test "message text: itemget names gained weapons and stacked items" {
    const a = testing.allocator;
    var db = @import("../data/database.zig").Database.init(a, undefined);
    defer db.deinit();
    const files = [_][2][]const u8{
        .{ "data/Weapons.json", "[null,{\"name\":\"STUFFED TOY\"}]" },
        .{ "data/Items.json", "[null,{\"name\":\"CANDY\"}]" },
        .{ "data/Armors.json", "[null,{\"name\":\"CHARM\"}]" },
    };
    for (files) |file| {
        var parser = try @import("../data/json.zig").Parser.init(db.arena.allocator(), file[1]);
        try db.storage.append(a, .{ .path = file[0], .kind = .database, .value = try parser.parse() });
        try db.files.put(try a.dupe(u8, file[0]), db.storage.items.len - 1);
    }
    var game = game_mod.GameObjects.init(a, &db);
    try game.create();
    defer game.deinit();
    game.party.gainWeapon(1, 1);
    const weapon = try normalizeMessage(a, "You got \\c[13]\\itemget\\c[0]!", &game);
    defer a.free(weapon);
    try testing.expectEqualStrings("You got STUFFED TOY!", weapon);
    game.party.gainItem(1, 3);
    const items = try normalizeMessage(a, "You got \\itemget!", &game);
    defer a.free(items);
    try testing.expectEqualStrings("You got CANDY x3!", items);
    game.party.gainArmor(1, 1);
    try testing.expectEqualStrings("CHARM", game.party.lastGainedItemName());
    // Gaining an item does not overwrite MV's last-used battle item.
    try testing.expectEqual(@as(i32, 0), game.party.last_item.item_id);
}

test "message text: TV line breaks, speaker tags and presentation escapes are readable" {
    const a = testing.allocator;
    const tv = try normalizeMessage(a, "There's a movie on TV.\\!<br>Four boys are walking on railroad tracks.", null);
    defer a.free(tv);
    try testing.expectEqualStrings("There's a movie on TV.\nFour boys are walking on railroad tracks.", tv);
    const speech = try normalizeMessage(a, "<WordWrap>\\n<SNAKE>\\sinv[1]Sssss...?\\sinv[0]\\! \\c[13]Hello\\c[0].", null);
    defer a.free(speech);
    try testing.expectEqualStrings("SNAKE:\nSssss...? Hello.", speech);
    const quick_macro = try normalizeMessage(a, "\\aubWhy is he mean?\\!<br>\\herWhat's up?", null);
    defer a.free(quick_macro);
    try testing.expectEqualStrings("Why is he mean?\nWhat's up?", quick_macro);
}

test "windowskin: 48px save toast has valid slices across frames" {
    const a = testing.allocator;
    var atlas = @import("../assets/atlas.zig").AtlasData{
        .entries = &.{},
        .index = std.StringHashMap(usize).init(a),
    };
    defer atlas.index.deinit();
    var loader = sprites_mod.Loader.init(a, undefined, &atlas);
    defer loader.deinit();
    const pixels = try a.alloc(u8, 192 * 192 * 4);
    @memset(pixels, 255);
    const key = try a.dupe(u8, "img/system/Window.png");
    try loader.cache.put(key, .{
        .pixels = pixels,
        .width = 192,
        .height = 192,
        .surface = .{ .width = 192, .height = 192, .pixels = pixels },
        .last_use = 0,
        .bytes = pixels.len,
    });
    loader.used_bytes = pixels.len;
    var win = WindowRenderer.init(a, undefined, &loader);
    var dl = draw_mod.DrawList.init(a);
    defer dl.deinit();
    for (0..2) |_| {
        win.drawWindow(&dl, 300, 40, 216, 48);
        const validation = dl.validate();
        try testing.expectEqual(@as(usize, 0), validation.errors);
        try testing.expectEqual(@as(usize, 7), validation.sprites);
        for (dl.ops.items) |command| {
            if (command == .sprite) try testing.expect(command.sprite.src.y + command.sprite.src.h <= 96);
        }
        dl.clear();
        loader.beginFrame();
    }
}

test "wrapLine: splits long lines, keeps short ones" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Fake font? Font.init needs a real TTF. Use the pattern from
    // title_scene tests: skip when the payload font is unavailable.
    const font_data = std.fs.cwd().readFileAlloc(a, "/tmp/omori-synth-game/fonts/OMORI_GAME2.ttf", 1024 * 1024) catch return;
    var font = try font_mod.Font.init(a, font_data);
    const vfs = try a.create(@import("../filesystem/vfs.zig").Vfs);
    vfs.* = @import("../filesystem/vfs.zig").Vfs.init(a, "/tmp/omori-synth-game", "/tmp/omori-synth-save");
    var atlas = @import("../assets/atlas.zig").AtlasData{ .entries = &.{}, .index = std.StringHashMap(usize).init(a) };
    var assets = @import("../assets/manager.zig").Manager.init(a, vfs, 8 * 1024 * 1024);
    var loader = sprites_mod.Loader.init(a, &assets, &atlas);
    var win = WindowRenderer.init(a, &font, &loader);

    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(a);

    // a short line stays single
    win.wrapLine("HELLO WORLD", 400, &lines);
    try testing.expectEqual(@as(usize, 1), lines.items.len);

    // a long line wraps into several, all fitting
    lines.clearRetainingCapacity();
    win.wrapLine("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", 100, &lines);
    try testing.expect(lines.items.len > 1);

    // empty line placeholder
    lines.clearRetainingCapacity();
    win.wrapLine("", 100, &lines);
    try testing.expectEqual(@as(usize, 1), lines.items.len);
}
