//! Port preferences are separate from original game configuration and saves.
const std = @import("std");
const vfs_mod = @import("../filesystem/vfs.zig");

pub const path = "save/port-options.json";
pub const Row = enum(usize) { always_run, master_volume, bgm_volume, bgs_volume, me_volume, se_volume, flashes, shake, instant_text, reset };
pub const row_count = @typeInfo(Row).@"enum".fields.len;

pub const Settings = struct {
    version: u32 = 2,
    always_run: bool = false,
    master_volume: u8 = 100,
    bgm_volume: u8 = 100,
    bgs_volume: u8 = 100,
    me_volume: u8 = 100,
    se_volume: u8 = 100,
    flashes: bool = true,
    shake: bool = true,
    instant_text: bool = false,

    pub fn load(vfs: *vfs_mod.Vfs) Settings {
        const bytes = vfs.readFileSync(path) catch return .{};
        defer vfs.allocator.free(bytes);
        return parse(vfs.allocator, bytes);
    }

    pub fn save(self: Settings, vfs: *vfs_mod.Vfs) !void {
        const bytes = try std.json.Stringify.valueAlloc(vfs.allocator, self, .{ .whitespace = .indent_2 });
        defer vfs.allocator.free(bytes);
        try vfs.writeFileSync(path, bytes);
    }

    pub fn value(self: Settings, row: Row) u8 {
        return switch (row) {
            .always_run => @intFromBool(self.always_run),
            .master_volume => self.master_volume,
            .bgm_volume => self.bgm_volume,
            .bgs_volume => self.bgs_volume,
            .me_volume => self.me_volume,
            .se_volume => self.se_volume,
            .flashes => @intFromBool(self.flashes),
            .shake => @intFromBool(self.shake),
            .instant_text => @intFromBool(self.instant_text),
            .reset => 0,
        };
    }

    pub fn adjust(self: *Settings, row: Row, direction: i32, wrap: bool) bool {
        const previous = self.*;
        switch (row) {
            .always_run => self.always_run = !self.always_run,
            .flashes => self.flashes = !self.flashes,
            .shake => self.shake = !self.shake,
            .instant_text => self.instant_text = !self.instant_text,
            .reset => self.* = .{},
            else => {
                const old = self.value(row);
                const next: u8 = if (wrap and old == 100 and direction > 0) 0 else @intCast(std.math.clamp(@as(i32, old) + direction * 10, 0, 100));
                switch (row) {
                    .master_volume => self.master_volume = next,
                    .bgm_volume => self.bgm_volume = next,
                    .bgs_volume => self.bgs_volume = next,
                    .me_volume => self.me_volume = next,
                    .se_volume => self.se_volume = next,
                    else => unreachable,
                }
            },
        }
        return !std.meta.eql(previous, self.*);
    }
};

pub fn label(row: Row) []const u8 {
    return switch (row) {
        .always_run => "ALWAYS RUN",
        .master_volume => "MASTER VOLUME",
        .bgm_volume => "MUSIC VOLUME",
        .bgs_volume => "AMBIENCE VOLUME",
        .me_volume => "JINGLE VOLUME",
        .se_volume => "SOUND VOLUME",
        .flashes => "SCREEN FLASHES",
        .shake => "SCREEN SHAKE",
        .instant_text => "INSTANT TEXT",
        .reset => "RESTORE DEFAULTS",
    };
}

pub fn description(row: Row) []const u8 {
    return switch (row) {
        .always_run => "INVERT WALK AND HELD DASH",
        .master_volume => "ADJUST ALL AUDIO; KEEP CHANNEL BALANCE",
        .bgm_volume => "BACKGROUND MUSIC",
        .bgs_volume => "LOOPING AMBIENT SOUNDS",
        .me_volume => "VICTORY AND OTHER SHORT MUSIC",
        .se_volume => "EFFECTS AND MENU SOUNDS",
        .flashes => "TURN OFF FLASH OVERLAYS; FADES STILL PLAY",
        .shake => "TURN OFF CAMERA SHAKE",
        .instant_text => "SHOW TEXT AT ONCE BETWEEN STORY PAUSES",
        .reset => "RESET THESE PREFERENCES; SAVES STAY INTACT",
    };
}

pub fn isVolume(row: Row) bool {
    return switch (row) {
        .master_volume, .bgm_volume, .bgs_volume, .me_volume, .se_volume => true,
        else => false,
    };
}

pub fn parse(a: std.mem.Allocator, bytes: []const u8) Settings {
    const parsed = std.json.parseFromSlice(std.json.Value, a, bytes, .{ .ignore_unknown_fields = true }) catch return .{};
    defer parsed.deinit();
    if (parsed.value != .object) return .{};
    var result: Settings = .{};
    if (parsed.value.object.get("version")) |version| {
        // v40 always displayed the whole line at once.
        result.instant_text = version == .integer and version.integer == 1;
    }
    inline for (.{ "always_run", "flashes", "shake", "instant_text" }) |field| {
        if (parsed.value.object.get(field)) |value| {
            if (value == .bool) @field(result, field) = value.bool;
        }
    }
    inline for (.{ "master_volume", "bgm_volume", "bgs_volume", "me_volume", "se_volume" }) |field| {
        if (parsed.value.object.get(field)) |value| {
            if (value == .integer) @field(result, field) = @intCast(std.math.clamp(value.integer, 0, 100));
        }
    }
    return result;
}

test "port options: defaults, bounds and malformed preferences" {
    const a = std.testing.allocator;
    const bounded = parse(a, "{\"bgm_volume\":-99,\"se_volume\":300,\"always_run\":true,\"flashes\":false,\"shake\":\"bad\",\"master_volume\":5.5}");
    try std.testing.expectEqual(@as(u8, 0), bounded.bgm_volume);
    try std.testing.expectEqual(@as(u8, 100), bounded.se_volume);
    try std.testing.expectEqual(@as(u8, 100), bounded.master_volume);
    try std.testing.expect(bounded.always_run and !bounded.flashes and bounded.shake);
    try std.testing.expectEqualDeep(Settings{}, parse(a, "incomplete"));
    try std.testing.expectEqualDeep(Settings{}, parse(a, "[]"));
    try std.testing.expect(parse(a, "{\"version\":1,\"master_volume\":80}").instant_text);
    try std.testing.expect(!parse(a, "{\"version\":2}").instant_text);
    var settings: Settings = .{};
    try std.testing.expect(settings.adjust(.bgm_volume, -1, false));
    try std.testing.expectEqual(@as(u8, 90), settings.bgm_volume);
    try std.testing.expect(settings.adjust(.reset, 1, true));
    try std.testing.expectEqualDeep(Settings{}, settings);
}

test "port options: persisted separately and restored on a fresh load" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root);
    var vfs = vfs_mod.Vfs.init(std.testing.allocator, root, root);
    defer vfs.deinit();
    try vfs.writeFileSync("save/file1.rpgsave", "DO NOT TOUCH");
    try vfs.writeFileSync("save/config.rpgsave", "ORIGINAL CONFIG");
    const saved: Settings = .{ .always_run = true, .master_volume = 70, .bgm_volume = 20, .se_volume = 0, .flashes = false, .shake = false, .instant_text = true };
    try saved.save(&vfs);
    try std.testing.expectEqualDeep(saved, Settings.load(&vfs));
    const original = try vfs.readFileSync("save/config.rpgsave");
    defer vfs.allocator.free(original);
    try std.testing.expectEqualStrings("ORIGINAL CONFIG", original);
    const checkpoint = try vfs.readFileSync("save/file1.rpgsave");
    defer vfs.allocator.free(checkpoint);
    try std.testing.expectEqualStrings("DO NOT TOUCH", checkpoint);
}
