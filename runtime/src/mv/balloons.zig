//! Field reaction cues. The supplied OMORI plugins use 32×24 cells and
//! retain the base animation speed of eight ticks per cell.
const std = @import("std");

pub const cell_width = 32;
pub const cell_height = 24;
pub const ticks_per_cell = 8;
pub const duration = 8 * ticks_per_cell;
pub const sheet_variable = 25;

pub const Sheet = enum {
    standard,
    do_re_mi,

    pub fn name(self: Sheet) []const u8 {
        return switch (self) {
            .standard => "Balloon",
            .do_re_mi => "BalloonDoReMi",
        };
    }

    pub fn fromName(value: []const u8) ?Sheet {
        for ([_]Sheet{ .standard, .do_re_mi }) |sheet| {
            if (std.mem.eql(u8, value, sheet.name())) return sheet;
        }
        return null;
    }
};

pub const Cue = struct {
    row: u8,
    sheet: Sheet,
    age: u8 = 0,

    pub fn column(self: Cue) i32 {
        return self.age / ticks_per_cell;
    }
};

pub const Active = std.AutoHashMapUnmanaged(i32, Cue);

pub fn tick(active: *Active) void {
    var iterator = active.iterator();
    while (iterator.next()) |entry| {
        entry.value_ptr.age += 1;
        if (entry.value_ptr.age >= duration) active.removeByPtr(entry.key_ptr);
    }
}
