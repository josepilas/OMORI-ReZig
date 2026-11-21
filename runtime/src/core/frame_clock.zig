//! Millisecond SDL frame pacing with a rational 60 Hz period.
//! 16 ms every frame is 62.5 Hz; 16/17/17 sums to exactly 50 ms.
const std = @import("std");

pub const FrameClock = struct {
    last_tick: u32 = 0,
    remainder: u32 = 0,

    pub fn delayForNextFrame(self: *FrameClock, now: u32) u32 {
        self.remainder += 1000;
        const period = self.remainder / 60;
        self.remainder %= 60;
        const elapsed = now -% self.last_tick;
        return period -| elapsed;
    }

    /// Start the next interval at the actual completed frame, rather
    /// than replaying accumulated updates after a slow render/stall.
    pub fn completed(self: *FrameClock, now: u32) void {
        self.last_tick = now;
    }
};

test "frame clock: sixty updates occupy exactly one second without a 62.5Hz shortcut" {
    var clock = FrameClock{};
    var now: u32 = 0;
    for (0..600) |index| {
        now += @as(u32, @intCast(index % 7)); // varying sub-budget render time
        now += clock.delayForNextFrame(now);
        clock.completed(now);
        if ((index + 1) % 60 == 0) try std.testing.expectEqual(@as(u32, @intCast((index + 1) / 60 * 1000)), now);
    }
}

test "frame clock: slow frames and SDL tick wrap never create a catch-up burst" {
    var clock = FrameClock{ .last_tick = std.math.maxInt(u32) - 10 };
    var now = clock.last_tick +% 4;
    try std.testing.expectEqual(@as(u32, 12), clock.delayForNextFrame(now));
    now +%= 12;
    clock.completed(now);
    now +%= 400;
    try std.testing.expectEqual(@as(u32, 0), clock.delayForNextFrame(now));
    clock.completed(now);
    now +%= 1;
    try std.testing.expectEqual(@as(u32, 16), clock.delayForNextFrame(now));
}
