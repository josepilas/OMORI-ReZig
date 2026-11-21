//! rpg_objects.js Game_CharacterBase updateAnimation, in half-count units.
const std = @import("std");

pub const CharacterAnimation = struct {
    pattern_index: i32 = 1,
    original_pattern: i32 = 1,
    half_count: i32 = 0,

    pub fn init(original: i32) CharacterAnimation {
        return .{ .pattern_index = original, .original_pattern = original };
    }

    pub fn pattern(self: CharacterAnimation) i32 {
        return if (self.pattern_index < 3) self.pattern_index else 1;
    }

    pub fn update(self: *CharacterAnimation, moving: bool, step_anime: bool, move_speed: i32) void {
        if (moving) {
            self.half_count += 3; // moving with walkAnime: +1.5
        } else if (step_anime or self.pattern() != self.original_pattern) {
            self.half_count += 2;
        }
        const wait = (9 - std.math.clamp(move_speed, 1, 8)) * 3 * 2;
        if (self.half_count >= wait) {
            if (!step_anime and !moving) {
                self.pattern_index = self.original_pattern;
            } else {
                self.pattern_index = @mod(self.pattern_index + 1, 4);
            }
            self.half_count = 0;
        }
    }
};

test "character animation: walking and dashing use authored MV cadence and four-step sequence" {
    for ([_]i32{ 4, 5 }, [_]usize{ 10, 8 }) |speed, ticks| {
        var anim = CharacterAnimation{};
        for ([_]i32{ 2, 1, 0, 1 }) |expected| {
            for (0..ticks - 1) |_| anim.update(true, false, speed);
            const before = anim.pattern();
            anim.update(true, false, speed);
            try std.testing.expectEqual(expected, anim.pattern());
            try std.testing.expect(before != anim.pattern());
        }
    }
}

test "character animation: stationary step animation and stopping preserve authored idle pattern" {
    var stepping = CharacterAnimation.init(0);
    for (0..17) |_| stepping.update(false, true, 3);
    try std.testing.expectEqual(@as(i32, 0), stepping.pattern());
    stepping.update(false, true, 3);
    try std.testing.expectEqual(@as(i32, 1), stepping.pattern());
    var still = CharacterAnimation.init(2);
    for (0..100) |_| still.update(false, false, 3);
    try std.testing.expectEqual(@as(i32, 2), still.pattern());
    var walker = CharacterAnimation{};
    for (0..10) |_| walker.update(true, false, 4);
    try std.testing.expectEqual(@as(i32, 2), walker.pattern());
    for (0..15) |_| walker.update(false, false, 4);
    try std.testing.expectEqual(@as(i32, 1), walker.pattern());
}
