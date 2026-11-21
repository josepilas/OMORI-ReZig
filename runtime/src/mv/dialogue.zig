const std = @import("std");

/// Offsets point into the expanded, UTF-8 text. Wraps never split a codepoint.
pub const Control = enum { wait_short, wait_long, pause, fast_on, fast_off, auto_end };
pub const Cue = struct { offset: usize, control: Control };

/// The window prepares this once, when a message first appears. Visual layout
/// and input use the same lines even when variable expansion adds extra pages.
pub const Layout = struct {
    text: []u8,
    lines: [][]const u8,
    cues: []Cue,
    cursor: usize = 0,
    cue_index: usize = 0,
    wait: u8 = 0,
    paused: bool = false,
    ready: bool = false,
    fast_line: bool = false,
    auto_end: bool = false,

    pub fn deinit(self: Layout, a: std.mem.Allocator) void {
        a.free(self.lines);
        a.free(self.cues);
        a.free(self.text);
    }

    fn offset(self: Layout, line: []const u8) usize {
        return @intFromPtr(line.ptr) - @intFromPtr(self.text.ptr);
    }

    pub fn visible(self: Layout, line: []const u8) []const u8 {
        return line[0..@min(line.len, self.cursor -| self.offset(line))];
    }

    pub fn nextPage(self: *Layout) void {
        self.ready = false;
        self.fast_line = false;
    }

    /// True when existing page/choice handling may use this frame's input.
    /// A key used to finish revealing text or release a pause is consumed.
    pub fn tick(self: *Layout, page: usize, confirm: bool, instant: bool) bool {
        if (self.ready) return true;
        if (self.wait > 0) {
            self.wait -= 1;
            return false;
        }
        const first_next_line = (page + 1) * 4;
        const final_page = first_next_line >= self.lines.len;
        const end = if (final_page) self.text.len else self.offset(self.lines[first_next_line]);
        const resuming = self.paused;
        if (resuming) {
            if (!confirm) return false;
            self.paused = false;
        }
        const reveal = instant or (confirm and !resuming);
        var drew_character = false;
        while (true) {
            while (self.cue_index < self.cues.len) {
                const cue = self.cues[self.cue_index];
                if (cue.offset > self.cursor or (cue.offset == end and !final_page)) break;
                self.cue_index += 1;
                switch (cue.control) {
                    .wait_short, .wait_long => {
                        self.wait = if (cue.control == .wait_short) 15 else 60;
                        return false;
                    },
                    .pause => {
                        // A final pause is the ordinary end-of-page prompt.
                        if (self.cursor < end or self.cue_index < self.cues.len) self.paused = true else self.ready = true;
                        return false;
                    },
                    .fast_on => self.fast_line = true,
                    .fast_off => self.fast_line = false,
                    .auto_end => self.auto_end = true,
                }
            }
            if (self.cursor >= end) {
                self.ready = true;
                return false;
            }
            if (drew_character and !reveal and !self.fast_line) return false;
            const byte = self.text[self.cursor];
            self.cursor += std.unicode.utf8ByteSequenceLength(byte) catch 1;
            if (byte == '\n') self.fast_line = false else drew_character = true;
        }
    }
};
