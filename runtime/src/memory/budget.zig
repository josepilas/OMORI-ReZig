//! Memory budget as a first-class runtime subsystem (architectural pivot
//! §25). The R36S has ~896 MiB RAM; the existing project's memory
//! documentation (110.8 MiB Aetherflow preload, 305 MiB cache target,
//! 220/160/100 MiB governor thresholds) is preserved as the engineering
//! baseline, and the native runtime exposes live diagnostics instead of
//! waiting for a crash:
//!
//!   * RSS via /proc/self/statm (VmRSS pages).
//!   * Asset memory / texture memory from the AssetManager stats.
//!   * Peak tracking for both.
//!
//! Governor policy (trim-only, never a kill switch — the validated V21
//! philosophy) hooks into the asset manager's eviction budget.

const std = @import("std");
const log = @import("../core/log.zig");

pub const PAGE_SIZE: u64 = 4096;

pub const Snapshot = struct {
    /// Resident set size in bytes.
    rss_bytes: u64 = 0,
    /// Asset manager decoded-byte estimate.
    asset_bytes: u64 = 0,
    /// Peak values observed since boot.
    rss_peak_bytes: u64 = 0,
    asset_peak_bytes: u64 = 0,

    pub fn totalBytes(self: Snapshot) u64 {
        return self.rss_bytes + self.asset_bytes;
    }
};

pub const Budget = struct {
    allocator: std.mem.Allocator,
    snapshot: Snapshot = .{},
    /// Soft budget for total process memory (default: 256 MiB on R36S).
    soft_budget_bytes: u64 = 256 * 1024 * 1024,
    /// Pressure tier thresholds (V21 evidence: 220/160/100 MiB trim-only).
    warn_bytes: u64 = 220 * 1024 * 1024,
    critical_bytes: u64 = 160 * 1024 * 1024,
    emergency_bytes: u64 = 100 * 1024 * 1024,
    last_tier: Tier = .normal,

    pub const Tier = enum { normal, warning, critical, emergency };

    pub fn init(alloc: std.mem.Allocator) Budget {
        return .{ .allocator = alloc };
    }

    /// Sample /proc/self/statm (page granularity, 1 fault tolerance).
    fn sampleRss(self: *Budget) u64 {
        var buf: [128]u8 = undefined;
        const f = std.fs.cwd().openFile("/proc/self/statm", .{}) catch return self.snapshot.rss_bytes;
        defer f.close();
        const n = f.readAll(&buf) catch return self.snapshot.rss_bytes;
        // statm: "total resident shared text lib data dt" — resident is field 1.
        var it = std.mem.tokenizeScalar(u8, buf[0..n], ' ');
        _ = it.next(); // total
        const resident_pages = it.next() orelse return self.snapshot.rss_bytes;
        const pages = std.fmt.parseInt(u64, std.mem.trim(u8, resident_pages, "\n"), 10) catch
            return self.snapshot.rss_bytes;
        return pages * PAGE_SIZE;
    }

    /// Take a memory snapshot and log the current tier transitions.
    pub fn sample(self: *Budget, asset_bytes: u64) Snapshot {
        self.snapshot.rss_bytes = self.sampleRss();
        self.snapshot.asset_bytes = asset_bytes;
        if (self.snapshot.rss_bytes > self.snapshot.rss_peak_bytes) self.snapshot.rss_peak_bytes = self.snapshot.rss_bytes;
        if (self.snapshot.asset_bytes > self.snapshot.asset_peak_bytes) self.snapshot.asset_peak_bytes = self.snapshot.asset_bytes;

        const total = self.snapshot.totalBytes();
        const tier: Tier = if (total >= self.warn_bytes)
            .warning
        else if (total >= self.critical_bytes) Tier.critical else .normal;
        // Note: emergency/critical apply to AVAILABLE system memory in the
        // V21 governor; the native equivalent reads /proc/meminfo
        // MemAvailable (below) and is reported, not acted on, until the
        // event system exists to safely trim.
        if (tier != self.last_tier) {
            switch (tier) {
                .warning => log.warn("memory: warning tier (rss={d} asset={d})", .{ self.snapshot.rss_bytes, asset_bytes }),
                else => {},
            }
            self.last_tier = tier;
        }
        return self.snapshot;
    }

    /// System-wide available memory (the V21 governor's actual signal).
    pub fn systemAvailableBytes(self: *Budget) ?u64 {
        _ = self;
        var buf: [4096]u8 = undefined;
        const f = std.fs.cwd().openFile("/proc/meminfo", .{}) catch return null;
        defer f.close();
        const n = f.readAll(&buf) catch return null;
        const text = buf[0..n];
        const marker = "MemAvailable:";
        const idx = std.mem.indexOf(u8, text, marker) orelse return null;
        var rest = std.mem.trimLeft(u8, text[idx + marker.len ..], " \t");
        const kb_end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        const kb = std.fmt.parseInt(u64, std.mem.trim(u8, rest[0..kb_end], " \tkB"), 10) catch return null;
        return kb * 1024;
    }

    pub fn renderDiagnostics(self: *const Budget, buf: []u8) []const u8 {
        const s = self.snapshot;
        return std.fmt.bufPrint(buf, "rss={d} rss_peak={d} asset={d} asset_peak={d} total={d} budget={d}", .{
            s.rss_bytes, s.rss_peak_bytes, s.asset_bytes, s.asset_peak_bytes, s.totalBytes(), self.soft_budget_bytes,
        }) catch "diagnostics-overflow";
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "memory snapshot and peak tracking" {
    var budget = Budget.init(testing.allocator);
    // First sample: real RSS from statm.
    _ = budget.sample(1024);
    try testing.expect(budget.snapshot.rss_bytes > 0); // the test binary itself
    try testing.expectEqual(@as(u64, 1024), budget.snapshot.asset_bytes);
    // Peak grows.
    _ = budget.sample(2048);
    try testing.expectEqual(@as(u64, 2048), budget.snapshot.asset_peak_bytes);
    // Peak does not shrink.
    _ = budget.sample(0);
    try testing.expectEqual(@as(u64, 2048), budget.snapshot.asset_peak_bytes);
}

test "system available memory parses" {
    var budget = Budget.init(testing.allocator);
    const avail = budget.systemAvailableBytes();
    try testing.expect(avail != null and avail.? > 0);
}
