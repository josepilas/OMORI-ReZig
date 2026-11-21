//! Offline GameFont accent/metrics probe; the font remains external.
//! font-check <font.ttf> <credit-line.ppm>
const std = @import("std");
const font_mod = @import("text/font.zig");
const draw = @import("renderer/draw.zig");
comptime {
    _ = font_mod;
}

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const a = gpa.allocator();
    const args = try std.process.argsAlloc(a);
    defer std.process.argsFree(a, args);
    if (args.len != 3) return error.Usage;
    const data = try std.fs.cwd().readFileAlloc(a, args[1], 16 * 1024 * 1024);
    defer a.free(data);
    var font = try font_mod.Font.init(a, data);
    defer font.deinit();
    const base_id = font.glyphId('e');
    const acute_id = font.glyphId(0x00e9);
    if (base_id == 0 or acute_id == 0) return error.MissingCreditGlyph;
    for ([_]u32{ 24, 32, 48 }) |size| {
        const base = (try font.rasterize(base_id, size)).*;
        const accented = (try font.rasterize(acute_id, size)).*;
        if (accented.advance != base.advance or accented.top <= base.top) return error.BadAcuteMetrics;
        if (font.measureText("Jose Pilas", size).width != font.measureText("José Pilas", size).width) return error.CreditWidthChanged;
        const ox: usize = @intCast(base.bearing_x - accented.bearing_x);
        const oy: usize = @intCast(accented.top - base.top);
        for (0..base.height) |y| {
            if (!std.mem.eql(u8, base.coverage[y * base.width ..][0..base.width], accented.coverage[(oy + y) * accented.width + ox ..][0..base.width])) return error.BaseInkChanged;
        }
        std.debug.print("GAMEFONT ACUTE PASS: size{d}, gid{d}, advance{d}, body pixels unchanged, top{d}->{d}\n", .{ size, acute_id, accented.advance, base.top, accented.top });
    }
    var dl = draw.DrawList.init(a);
    defer dl.deinit();
    var glyphs: std.ArrayList(draw.DrawList.LaidGlyph) = .empty;
    defer glyphs.deinit(a);
    const text = "R36S PORT BY José Pilas";
    const size: u32 = 32;
    var pen: i32 = 0;
    var previous: u16 = 0;
    var iter = std.unicode.Utf8Iterator{ .bytes = text, .i = 0 };
    while (iter.nextCodepoint()) |cp| {
        const id = font.glyphId(cp);
        if (id == 0) return error.MissingCreditGlyph;
        pen += @intFromFloat(@round(@as(f64, @floatFromInt(font.kernUnits(previous, id))) * font.scale(size)));
        const glyph = (try font.rasterize(id, size)).*;
        try glyphs.append(a, .{ .glyph = glyph, .x = pen });
        pen += glyph.advance;
        previous = id;
    }
    const measure = font.measureText(text, size);
    if (pen != measure.width) return error.LayoutMismatch;
    const index = dl.addTextRun(glyphs.items, @intCast(measure.width), size + 4);
    const run = dl.runs.items[index];
    const rgb = try a.alloc(u8, @as(usize, run.width) * run.height * 3);
    defer a.free(rgb);
    for (0..@as(usize, run.width) * run.height) |i| @memset(rgb[i * 3 ..][0..3], run.pixels[i * 4 + 3]);
    const header = try std.fmt.allocPrint(a, "P6\n{d} {d}\n255\n", .{ run.width, run.height });
    defer a.free(header);
    var file = try std.fs.cwd().createFile(args[2], .{});
    defer file.close();
    try file.writeAll(header);
    try file.writeAll(rgb);
    std.debug.print("GAMEFONT CREDIT PASS: {d}x{d}, e/é same advance, spelling preserved\n", .{ run.width, run.height });
}
