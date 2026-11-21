//! RPG Maker MV core state primitives — Game_Switches / Game_Variables
//! (milestone-4 groundwork, honest scope: the containers, indexing and
//! mutation semantics from `rpg_objects.js`, with the event interpreter
//! consuming them in a later milestone).
//!
//! MV semantics preserved:
//! * Switches and variables are 1-indexed arrays with $dataSystem-provided
//!   names; index 0 is the null entry (`$gameSwitches.value(0)` is never
//!   legal in event data but the engine never throws on read either).
//! * `onChange` dirty-flag notification (the save system and refresh
//!   pipeline key on it).

const std = @import("std");

pub const Switches = struct {
    allocator: std.mem.Allocator,
    values: []bool,
    dirty: bool = false,

    pub fn init(alloc: std.mem.Allocator, count: usize) !Switches {
        const values = try alloc.alloc(bool, count + 1); // 1-indexed, index 0 null
        @memset(values, false);
        return .{ .allocator = alloc, .values = values };
    }

    pub fn deinit(self: *Switches) void {
        self.allocator.free(self.values);
    }

    pub fn value(self: *const Switches, id: usize) bool {
        if (id == 0 or id >= self.values.len) return false;
        return self.values[id];
    }

    pub fn setValue(self: *Switches, id: usize, v: bool) void {
        if (id == 0 or id >= self.values.len) return;
        if (self.values[id] != v) {
            self.values[id] = v;
            self.dirty = true;
        }
    }

    pub fn onChange(self: *Switches) void {
        self.dirty = false;
    }
};

pub const Variables = struct {
    allocator: std.mem.Allocator,
    values: []i64,
    dirty: bool = false,
    // OMORI uses variable 25 for a string-valued system sprite sheet.
    balloon_sheet: ?@import("balloons.zig").Sheet = null,

    pub fn init(alloc: std.mem.Allocator, count: usize) !Variables {
        const values = try alloc.alloc(i64, count + 1);
        @memset(values, 0);
        return .{ .allocator = alloc, .values = values };
    }

    pub fn deinit(self: *Variables) void {
        self.allocator.free(self.values);
    }

    pub fn value(self: *const Variables, id: usize) i64 {
        if (id == 0 or id >= self.values.len) return 0;
        return self.values[id];
    }

    pub fn setValue(self: *Variables, id: usize, v: i64) void {
        if (id == 0 or id >= self.values.len) return;
        if (id == @import("balloons.zig").sheet_variable and self.balloon_sheet != null) {
            self.balloon_sheet = null;
            self.dirty = true;
        }
        if (self.values[id] != v) {
            self.values[id] = v;
            self.dirty = true;
        }
    }

    pub fn setBalloonSheet(self: *Variables, sheet: @import("balloons.zig").Sheet) void {
        const id = @import("balloons.zig").sheet_variable;
        if (id >= self.values.len) return;
        self.values[id] = 0;
        self.balloon_sheet = sheet;
        self.dirty = true;
    }

    /// MV `$gameVariables.operateValue` — the arithmetic used by event
    /// commands 122 (control variables).
    pub fn operate(self: *Variables, id: usize, op: Operation, operand: i64) void {
        const cur = self.value(id);
        const next: i64 = switch (op) {
            .add => cur + operand,
            .sub => cur - operand,
            .mul => cur * operand,
            .div => if (operand != 0) @divTrunc(cur, operand) else cur,
            .mod => if (operand != 0) @rem(cur, operand) else cur,
        };
        self.setValue(id, next);
    }

    pub const Operation = enum { add, sub, mul, div, mod };

    pub fn onChange(self: *Variables) void {
        self.dirty = false;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "switches: 1-indexed, dirty tracking, bounds-safe" {
    var sw = try Switches.init(testing.allocator, 10);
    defer sw.deinit();
    sw.setValue(3, true);
    try testing.expect(sw.value(3));
    try testing.expect(sw.dirty);
    sw.onChange();
    try testing.expect(!sw.dirty);
    // Setting the same value is not a change.
    sw.setValue(3, true);
    try testing.expect(!sw.dirty);
    // Out-of-range is a no-op, never a crash.
    sw.setValue(0, true);
    sw.setValue(999, true);
    try testing.expect(!sw.value(999));
}

test "variables: control-variable arithmetic (event command 122)" {
    var vars = try Variables.init(testing.allocator, 10);
    defer vars.deinit();
    vars.setValue(5, 10);
    vars.operate(5, .add, 32);
    try testing.expectEqual(@as(i64, 42), vars.value(5));
    vars.operate(5, .mul, 2);
    try testing.expectEqual(@as(i64, 84), vars.value(5));
    vars.operate(5, .div, 7);
    try testing.expectEqual(@as(i64, 12), vars.value(5));
    vars.operate(5, .mod, 5);
    try testing.expectEqual(@as(i64, 2), vars.value(5));
    // Division by zero never throws (MV leaves the value).
    vars.setValue(7, 8);
    vars.operate(7, .div, 0);
    try testing.expectEqual(@as(i64, 8), vars.value(7));
}
