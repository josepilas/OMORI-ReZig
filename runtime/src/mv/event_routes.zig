//! Event routes that animate a character in place. A route containing a
//! spatial or unknown operation is left to the movement interpreter as a unit.
const std = @import("std");
const json = @import("../data/json.zig");
const maps = @import("map.zig");

pub const Cell = struct { x: u8, y: u8 };
const Graphic = struct {
    bytes: [128]u8 = @splat(0),
    len: u8 = 0,
    index: u8 = 0,

    pub fn name(self: *const Graphic) []const u8 {
        return self.bytes[0..@min(self.len, self.bytes.len)];
    }
};

const Op = union(enum) {
    end, jump, clear_frame,
    wait: u16,
    turn: u8,
    speed: u8,
    frequency: u8,
    stepping: bool,
    fixed: bool,
    hidden: bool,
    graphic: Graphic,
    alpha: u8,
    frame: Cell,
};

fn number(args: []const json.Value, index: usize, max: u16) ?u16 {
    if (index >= args.len or args[index] != .number) return null;
    const n = args[index].number;
    if (!std.math.isFinite(n) or n < 0 or n > @as(f64, @floatFromInt(max)) or @trunc(n) != n) return null;
    return @intFromFloat(n);
}

fn frameScript(script: []const u8) ?Op {
    const s = std.mem.trim(u8, script, " \t\r\n;");
    const prefix = "this.setCustomFrameXY(";
    if (!std.mem.startsWith(u8, s, prefix) or !std.mem.endsWith(u8, s, ")")) return null;
    const args = s[prefix.len .. s.len - 1];
    const comma = std.mem.indexOfScalar(u8, args, ',') orelse return null;
    const x = std.mem.trim(u8, args[0..comma], " \t");
    const y = std.mem.trim(u8, args[comma + 1 ..], " \t");
    if (std.mem.eql(u8, x, "null") and std.mem.eql(u8, y, "null")) return .clear_frame;
    return .{ .frame = .{ .x = std.fmt.parseInt(u8, x, 10) catch return null, .y = std.fmt.parseInt(u8, y, 10) catch return null } };
}

fn decode(code: i64, args: []const json.Value) ?Op {
    return switch (code) {
        0 => .end,
        14 => if (number(args, 0, 0) != null and number(args, 1, 0) != null) .jump else null,
        15 => .{ .wait = number(args, 0, 65535) orelse return null },
        16...26 => .{ .turn = @intCast(code) },
        29 => .{ .speed = @intCast(number(args, 0, 6) orelse return null) },
        30 => .{ .frequency = @intCast(number(args, 0, 5) orelse return null) },
        33, 34 => .{ .stepping = code == 33 },
        35, 36 => .{ .fixed = code == 35 },
        39, 40 => .{ .hidden = code == 39 },
        41 => blk: {
            if (args.len != 2 or args[0] != .string) return null;
            const name = args[0].string;
            var g: Graphic = .{ .index = @intCast(number(args, 1, 7) orelse return null) };
            if (name.len > g.bytes.len) return null;
            @memcpy(g.bytes[0..name.len], name);
            g.len = @intCast(name.len);
            break :blk .{ .graphic = g };
        },
        42 => .{ .alpha = @intCast(number(args, 0, 255) orelse return null) },
        45 => if (args.len == 1 and args[0] == .string) frameScript(args[0].string) else null,
        else => null,
    };
}

pub const Facing = struct { dx: i64, dy: i64 };
pub const Pose = struct {
    dir: u8 = 2,
    speed: u8 = 3,
    frequency: u8 = 3,
    fixed: bool = false,
    stepping: bool = false,
    hidden: bool = false,
    alpha: u8 = 255,
    graphic: ?Graphic = null,
    frame: ?Cell = null,
    jump_peak: u8 = 0,
    jump_left: u8 = 0,

    pub fn height(self: *const Pose) i32 {
        const peak: i32 = self.jump_peak;
        const elapsed = @as(i32, self.jump_left) - peak;
        return @max(0, @divTrunc(peak * peak - elapsed * elapsed, 2));
    }
};

pub const State = struct {
    page: usize,
    pose: Pose,
    autonomous: bool,
    auto_index: usize = 0,
    auto_wait: u16 = 0,
    stop_ticks: u16 = 0,
    forced: []const Op = &.{},
    force_index: usize = 0,
    force_wait: u16 = 0,
    force_repeat: bool = false,
    rng: u32 = 1,

    fn init(id: i32, event: *const maps.RawEvent, page: *const maps.Page) State {
        var automatic = page.move_type == 3 and page.move_route.list.len != 0;
        if (automatic) for (page.move_route.list) |cmd| {
            if (decode(cmd.code, cmd.parameters) == null) {
                automatic = false;
                break;
            }
        };
        return .{ .page = pageIndex(event, page), .autonomous = automatic, .rng = @bitCast(id), .pose = .{
            .dir = @intCast(std.math.clamp(if (page.image) |im| im.getInt("direction", 2) else 2, 2, 8)),
            .speed = @intCast(std.math.clamp(page.move_speed, 1, 6)),
            .frequency = @intCast(std.math.clamp(page.move_frequency, 1, 5)),
            .fixed = page.direction_fix, .stepping = page.step_anime,
        } };
    }

    fn stopForce(self: *State, a: std.mem.Allocator) void {
        a.free(self.forced);
        self.forced = &.{};
        self.force_index = 0;
        self.force_wait = 0;
        self.force_repeat = false;
    }

    fn turn(self: *State, code: u8, player: Facing) void {
        if (self.pose.fixed) return;
        const direction = self.pose.dir;
        const clockwise: u8 = switch (direction) { 2 => 4, 4 => 8, 8 => 6, else => 2 };
        self.rng = self.rng *% 1664525 +% 1013904223;
        if ((code == 25 or code == 26) and player.dx == 0 and player.dy == 0) return;
        const toward: u8 = if (@abs(player.dx) > @abs(player.dy))
            (if (player.dx > 0) 6 else 4)
        else if (player.dy > 0) 2 else 8;
        self.pose.dir = switch (code) {
            16...19 => (code - 15) * 2,
            20 => clockwise,
            21 => 10 - clockwise,
            22 => 10 - direction,
            23 => if (self.rng >> 31 == 0) clockwise else 10 - clockwise,
            24 => @intCast((self.rng >> 30) * 2 + 2),
            25 => toward,
            26 => 10 - toward,
            else => direction,
        };
    }

    fn apply(self: *State, op: Op, wait: *u16, player: Facing) void {
        switch (op) {
            .end => {},
            .wait => |frames| wait.* = frames -| 1,
            .turn => |code| self.turn(code, player),
            .speed => |speed| self.pose.speed = speed,
            .frequency => |freq| self.pose.frequency = freq,
            .fixed => |v| self.pose.fixed = v,
            .stepping => |v| self.pose.stepping = v,
            .hidden => |v| self.pose.hidden = v,
            .alpha => |v| self.pose.alpha = v,
            .graphic => |sheet| self.pose.graphic = sheet,
            .frame => |cell| self.pose.frame = cell,
            .clear_frame => self.pose.frame = null,
            .jump => {
                self.pose.jump_peak = @as(u8, 10) - @min(self.pose.speed, 6);
                self.pose.jump_left = 2 * self.pose.jump_peak;
                self.stop_ticks = 0;
            },
        }
    }

    fn tick(self: *State, a: std.mem.Allocator, page: *const maps.Page, player: Facing) void {
        if (self.pose.jump_left > 0) {
            self.pose.jump_left -= 1;
            return;
        }
        self.stop_ticks +|= 1;
        if (self.forced.len > 0) {
            if (self.force_wait != 0) {
                self.force_wait -= 1;
                return;
            }
            if (self.force_index >= self.forced.len or self.forced[self.force_index] == .end) {
                if (self.force_repeat) self.force_index = 0 else self.stopForce(a);
                return;
            }
            const op = self.forced[self.force_index];
            self.force_index += 1;
            self.apply(op, &self.force_wait, player);
            return;
        }
        if (!self.autonomous or self.stop_ticks <= 30 * @as(u16, 5 - @min(5, self.pose.frequency))) return;
        if (self.auto_wait > 0) {
            self.auto_wait -= 1;
            return;
        }
        const list = page.move_route.list;
        if (self.auto_index >= list.len or list[self.auto_index].code == 0) {
            if (page.move_route.repeat) self.auto_index = 0 else self.autonomous = false;
            return;
        }
        const cmd = list[self.auto_index];
        self.auto_index += 1;
        if (decode(cmd.code, cmd.parameters)) |op| self.apply(op, &self.auto_wait, player);
    }
};

fn pageIndex(event: *const maps.RawEvent, page: *const maps.Page) usize {
    return (@intFromPtr(page) - @intFromPtr(event.pages.items.ptr)) / @sizeOf(maps.Page);
}

pub const Routes = struct {
    entries: std.AutoHashMapUnmanaged(i32, State) = .{},

    pub fn clear(self: *Routes, a: std.mem.Allocator) void {
        var it = self.entries.valueIterator();
        while (it.next()) |s| a.free(s.forced);
        self.entries.deinit(a);
        self.* = .{};
    }

    pub fn remove(self: *Routes, a: std.mem.Allocator, id: i32) void {
        if (self.entries.fetchRemove(id)) |old| a.free(old.value.forced);
    }

    fn get(self: *Routes, a: std.mem.Allocator, ev: *const maps.RawEvent, page: *const maps.Page) !*State {
        const entry = try self.entries.getOrPut(a, ev.id);
        if (!entry.found_existing) entry.value_ptr.* = State.init(ev.id, ev, page)
        else if (entry.value_ptr.page != pageIndex(ev, page)) {
            entry.value_ptr.stopForce(a);
            entry.value_ptr.* = State.init(ev.id, ev, page);
        }
        return entry.value_ptr;
    }

    pub fn pose(self: *const Routes, ev: *const maps.RawEvent, page: *const maps.Page) ?*const Pose {
        const state = self.entries.getPtr(ev.id) orelse return null;
        return if (state.page == pageIndex(ev, page)) &state.pose else null;
    }

    pub fn tick(self: *Routes, a: std.mem.Allocator, ev: *const maps.RawEvent, page: *const maps.Page, player: Facing) void {
        if (page.move_type != 3 and !self.entries.contains(ev.id)) return;
        const state = self.get(a, ev, page) catch return;
        state.tick(a, page, player);
    }

    pub fn forcing(self: *const Routes, id: i32) bool {
        const state = self.entries.getPtr(id) orelse return false;
        return state.forced.len != 0;
    }

    pub fn force(self: *Routes, a: std.mem.Allocator, ev: *const maps.RawEvent, page: *const maps.Page, route: json.Value) bool {
        // Replacing a route also stops any older visual route on this target.
        if (self.entries.getPtr(ev.id)) |old| old.stopForce(a);
        const list = route.get("list") orelse return false;
        if (list != .array or list.array.items.len == 0) return false;
        const commands = list.array.items;
        var ops: std.ArrayList(Op) = .empty;
        defer ops.deinit(a);
        for (commands) |cmd| {
            const args = if (cmd.get("parameters")) |p| p.arrayItems() else &.{};
            const op = decode(cmd.getInt("code", -1), args) orelse return false;
            ops.append(a, op) catch return false;
        }
        const state = self.get(a, ev, page) catch return false;
        state.forced = ops.toOwnedSlice(a) catch return false;
        state.force_repeat = route.getBool("repeat", false);
        return true;
    }
};

test "visual route: frames, authored waits and hiding reset with the active page" {
    const a = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var parser = try json.Parser.init(arena.allocator(),
        \\{"list":[{"code":45,"parameters":["this.setCustomFrameXY(2, 1)"]},
        \\{"code":15,"parameters":[3]},{"code":42,"parameters":[128]},
        \\{"code":39},{"code":0}],"repeat":false}
    );
    const forced = try parser.parse();
    var event: maps.RawEvent = .{ .id = 7, .name = "probe", .x = 1, .y = 1, .meta = undefined };
    try event.pages.appendSlice(arena.allocator(), &.{ .{ .meta = undefined }, .{ .meta = undefined } });
    const page = &event.pages.items[0];
    var routes: Routes = .{};
    defer routes.clear(a);
    try std.testing.expect(routes.force(a, &event, page, forced));
    const facing: Facing = .{ .dx = 0, .dy = 0 };
    routes.tick(a, &event, page, facing);
    try std.testing.expectEqual(Cell{ .x = 2, .y = 1 }, routes.pose(&event, page).?.frame.?);
    for (0..3) |_| {
        routes.tick(a, &event, page, facing);
        try std.testing.expectEqual(@as(u8, 255), routes.pose(&event, page).?.alpha);
    }
    routes.tick(a, &event, page, facing);
    try std.testing.expectEqual(@as(u8, 128), routes.pose(&event, page).?.alpha);
    routes.tick(a, &event, page, facing);
    try std.testing.expect(routes.pose(&event, page).?.hidden);
    routes.tick(a, &event, &event.pages.items[1], facing);
    try std.testing.expect(!routes.forcing(event.id));
    try std.testing.expect(!routes.pose(&event, &event.pages.items[1]).?.hidden);
}
