//! Dual-file logging system — `<port>/omori/logs/`.
//!
//! **detailed.txt** — hyper-detailed, hyper-technical. Every subsystem
//! event with wall-clock + monotonic time and sequence numbers, structured
//! key=value records, hex dumps, VFS resolution traces, data-load stats,
//! memory samples, and full crash reports (signal, fault address,
//! registers, backtrace, /proc/self/maps excerpt, ring snapshot of the
//! last events).
//!
//! **simple.txt** — one human-readable line per notable event
//! (`[HH:MM:SS] LEVEL message`), plus a one-line crash pointer.
//!
//! **boot.state** — the v20 single-writer milestone contract, kept for the
//! supervisor tooling; written on milestones and FATAL lines.
//!
//! **stderr trail** — the classic `[OMORI]` console trail (PortMaster
//! log visibility), preserved for milestone/warn/err levels.
//!
//! Compatibility: the previous public API (milestone/warn/err/debug,
//! `log_dir`, `verbose`) is preserved and routed into the dual-file
//! system, so existing call sites keep compiling and the test battery
//! keeps running without a log directory.
//!
//! Crash safety: the crash reporter (core/crash.zig) NEVER takes the
//! mutex. It writes with raw write(2) to pre-opened descriptors
//! (`detailed_fd_raw` / `simple_fd_raw`) and reads the event ring with
//! per-slot seqlocks (best effort; torn slots are skipped).
//!
//! Rotation: on init, existing files are renamed to `<name>.old` — one
//! previous session (and its crash report) is kept.

const std = @import("std");
const builtin = @import("builtin");
const fs_compat = @import("fs_compat.zig");

pub const Category = enum {
    sys, // process, config, boot, shutdown
    vfs, // virtual filesystem, _DIRECTORY, path resolution
    data, // database / map / json / yaml loading
    atlas, // Atlas.yaml + $atlasData
    mv, // MV core: Game_*, scenes, interpreter
    res, // resource manager: images, caches
    mem, // memory diagnostics
    save, // save/load
    gpu, // renderer
    input, // input
    audio, // audio
    @"test", // test harness (quoted: keyword)
    crash, // crash reporter

    pub fn name(self: Category) []const u8 {
        return switch (self) {
            .sys => "SYS",
            .vfs => "VFS",
            .data => "DATA",
            .atlas => "ATLAS",
            .mv => "MV",
            .res => "RES",
            .mem => "MEM",
            .save => "SAVE",
            .gpu => "GPU",
            .input => "INPUT",
            .audio => "AUDIO",
            .@"test" => "TEST",
            .crash => "CRASH",
        };
    }
};

pub const Severity = enum(u3) {
    trace = 0,
    debug = 1,
    info = 2,
    note = 3,
    warn = 4,
    err = 5,
    fatal = 6,

    pub fn tag(self: Severity) []const u8 {
        return switch (self) {
            .trace => "TRC",
            .debug => "DBG",
            .info => "INF",
            .note => "NOT",
            .warn => "WRN",
            .err => "ERR",
            .fatal => "FTL",
        };
    }
};

// ---------------------------------------------------------------------------
// Ring buffer (seqlock) — read by the crash handler without locks
// ---------------------------------------------------------------------------

pub const ring_slots = 96;
pub const ring_line_max = 192;

const RingSlot = struct {
    seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    len: usize = 0,
    buf: [ring_line_max]u8 = undefined,
};

var ring: [ring_slots]RingSlot = [_]RingSlot{.{}} ** ring_slots;
var ring_head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0);

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

const State = struct {
    alloc: std.mem.Allocator,
    dir: []u8, // owned
    detailed: std.fs.File,
    simple: std.fs.File,
    start_mono_ns: i128,
    seq: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    events_since_flush: usize = 0,
    bytes_detailed: u64 = 0,
    bytes_simple: u64 = 0,
    dropped: u64 = 0, // write failures
};

var state: ?State = null;
var mutex: std.Thread.Mutex = .{};

// Static buffers (no allocation on the log path).
var det_buf: [64 * 1024]u8 = undefined;
var det_len: usize = 0;
var sim_buf: [16 * 1024]u8 = undefined;
var sim_len: usize = 0;

// Raw descriptors for the crash handler (no locks, write(2) only).
pub var detailed_fd_raw: std.posix.fd_t = -1;
pub var simple_fd_raw: std.posix.fd_t = -1;

/// Kept for compatibility with the v22 API surface.
pub var log_dir: ?[]const u8 = null;
pub var verbose: bool = false;

pub fn isInit() bool {
    return state != null;
}

// ---------------------------------------------------------------------------
// Init / deinit
// ---------------------------------------------------------------------------

/// Initialize dual-file logging in `dir` (created recursively). Previous
/// runs are rotated to `.old`. On failure the runtime keeps running with
/// the console trail only (a logging failure must never kill the game).
pub fn init(alloc: std.mem.Allocator, dir: []const u8) void {
    if (isInit()) return;

    // fs_compat: std's makePath fails with error.Unexpected on kernels
    // without statx (the R36S's 4.4.189) whenever the dir already exists
    // (EEXIST → statFile → ENOSYS) — the "cannot create dir" device log.
    fs_compat.makePath(std.fs.cwd(), dir) catch {
        std.debug.print("[OMORI:ERR] logs: cannot create dir '{s}' — console-only logging\n", .{dir});
        return;
    };

    rotatePrevious(dir, "detailed.txt");
    rotatePrevious(dir, "simple.txt");

    const det_path = std.fmt.allocPrint(alloc, "{s}/detailed.txt", .{dir}) catch return;
    defer alloc.free(det_path);
    const sim_path = std.fmt.allocPrint(alloc, "{s}/simple.txt", .{dir}) catch return;
    defer alloc.free(sim_path);

    const detailed = std.fs.cwd().createFile(det_path, .{ .truncate = true }) catch |e| {
        std.debug.print("[OMORI:ERR] logs: cannot create detailed.txt ({s}) — console-only logging\n", .{@errorName(e)});
        return;
    };
    const simple = std.fs.cwd().createFile(sim_path, .{ .truncate = true }) catch |e| {
        std.debug.print("[OMORI:ERR] logs: cannot create simple.txt ({s}) — console-only logging\n", .{@errorName(e)});
        detailed.close();
        return;
    };
    const dir_copy = alloc.dupe(u8, dir) catch {
        detailed.close();
        simple.close();
        return;
    };

    state = .{
        .alloc = alloc,
        .dir = dir_copy,
        .detailed = detailed,
        .simple = simple,
        .start_mono_ns = std.time.nanoTimestamp(),
    };
    detailed_fd_raw = detailed.handle;
    simple_fd_raw = simple.handle;
    log_dir = dir_copy;

    writeEnvHeader();

    // Banner in both files + console.
    writeBanner("OMORI NATIVE RUNTIME — session start");
    event(.sys, .note, "logging initialized: dir='{s}' files=detailed.txt,simple.txt (+boot.state)", .{dir});
}

/// Default initialization when no port root is known.
pub fn initDefault(alloc: std.mem.Allocator) void {
    init(alloc, "omori/logs");
}

/// v26: retarget the log files to a new directory (used when the CLI
/// `--log-dir` differs from the directory chosen at early-init time).
/// Closes the current files, rotates in the new dir, and reopens. All
/// events after the switch land in the new files (pre-switch events stay
/// in the old ones — the old dir keeps a record of the early boot).
pub fn retarget(alloc: std.mem.Allocator, dir: []const u8) void {
    if (state == null) {
        init(alloc, dir);
        return;
    }
    mutex.lock();
    const cur_dir = state.?.dir;
    const same = std.mem.eql(u8, cur_dir, dir);
    mutex.unlock();
    if (same) return;

    warn("log retarget: '{s}' -> '{s}' (early-boot records stay in the old dir)", .{ cur_dir, dir });
    // Flush + close the old session, then init in the new dir.
    deinit();
    init(alloc, dir);
}

/// v26: EARLY logging bootstrap — safe to call as the first statement of
/// main(). Resolves the log directory from (in priority order):
///   1. $OMORI_LOG_DIR
///   2. <exe_dir>/../logs   (port layout: omori/bin/omori-native -> omori/logs)
///   3. omori/logs (cwd-relative)
/// The point is that detailed.txt/simple.txt exist BEFORE anything else
/// can fail — argv parsing, allocator setup, data checks — so "no logs
/// when it doesn't open" becomes impossible. Uses `alloc` only; falls
/// back silently (console trail) when no directory is writable.
pub fn earlyInit(alloc: std.mem.Allocator) void {
    if (isInit()) return;

    if (std.posix.getenv("OMORI_LOG_DIR")) |ld| {
        if (ld.len > 0) {
            init(alloc, ld);
            return;
        }
    }

    // <exe_dir>/../logs — derived from /proc/self/exe (Linux).
    if (builtin.os.tag == .linux) {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const self_exe = std.fs.selfExePath(&path_buf) catch null;
        if (self_exe) |exe| {
            const bin_dir = std.fs.path.dirname(exe) orelse ".";
            const port_dir = std.fs.path.dirname(bin_dir) orelse ".";
            var join_buf: [std.fs.max_path_bytes]u8 = undefined;
            const logs = std.fmt.bufPrint(&join_buf, "{s}/logs", .{port_dir}) catch "";
            if (logs.len > 0) {
                // Only use it if it exists or can be created; otherwise
                // fall through to the cwd-relative default. (fs_compat:
                // EEXIST-tolerant on kernels without statx.)
                fs_compat.makePath(std.fs.cwd(), logs) catch {};
                if (std.fs.cwd().access(logs, .{})) |_| {
                    init(alloc, logs);
                    return;
                } else |_| {}
            }
        }
    }

    initDefault(alloc);
}

pub fn deinit() void {
    if (state == null) return;
    mutex.lock();
    defer mutex.unlock();
    eventLocked(.sys, .note, null, "runtime shutting down; flushing logs ({d} B detailed, {d} B simple, {d} dropped)", .{
        state.?.bytes_detailed, state.?.bytes_simple, state.?.dropped,
    });
    flushLocked() catch {};
    state.?.detailed.close();
    state.?.simple.close();
    detailed_fd_raw = -1;
    simple_fd_raw = -1;
    state.?.alloc.free(state.?.dir);
    state = null;
    log_dir = null;
}

fn rotatePrevious(dir: []const u8, name: []const u8) void {
    // v33: numbered history — the v32 runs proved the single `.old`
    // rotation loses whole crash sessions (three device runs, one
    // overwritten report). Keep the last 9 generations: name.txt ->
    // name-001.txt .. name-009.txt (oldest shifted off the tail).
    var bufs: [10][std.fs.max_path_bytes]u8 = undefined;
    var paths: [10][]const u8 = undefined;
    paths[0] = std.fmt.bufPrint(&bufs[0], "{s}/{s}", .{ dir, name }) catch return;
    // "detailed.txt" -> "detailed" (numbered generations re-add the ext)
    const stem = if (std.mem.lastIndexOfScalar(u8, name, '.')) |dot| name[0..dot] else name;
    var i: usize = 1;
    while (i < 10) : (i += 1) {
        paths[i] = std.fmt.bufPrint(&bufs[i], "{s}/{s}-00{d}.txt", .{ dir, stem, i }) catch return;
    }
    // Only rotate when the current file exists.
    std.fs.cwd().access(paths[0], .{}) catch return;
    // 009 -> dropped; 008 -> 009; ... ; 001 -> 002; current -> 001.
    var j: usize = 9;
    while (j > 1) : (j -= 1) {
        std.fs.cwd().rename(paths[j - 1], paths[j]) catch {};
    }
    std.fs.cwd().rename(paths[0], paths[1]) catch {};
}

// ---------------------------------------------------------------------------
// Public API — legacy surface (compat) + rich events
// ---------------------------------------------------------------------------

pub fn milestone(comptime fmt: []const u8, args: anytype) void {
    event(.sys, .info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    event(.sys, .warn, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    event(.sys, .err, fmt, args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    event(.sys, .debug, fmt, args);
}

/// Trace-level record: detailed.txt only (hyper-technical trail).
pub fn detail(cat: Category, comptime fmt: []const u8, args: anytype) void {
    event(cat, .trace, fmt, args);
}

/// Structured key=value record: detailed.txt only.
pub fn kv(cat: Category, key: []const u8, comptime fmt: []const u8, args: anytype) void {
    if (state == null) return;
    mutex.lock();
    defer mutex.unlock();
    kvLocked(cat, key, fmt, args);
}

/// Hex dump: detailed.txt only.
pub fn dump(cat: Category, title: []const u8, bytes: []const u8) void {
    if (state == null) return;
    mutex.lock();
    defer mutex.unlock();
    dumpLocked(cat, title, bytes);
}

/// Big banner: both files + stderr.
pub fn section(title: []const u8) void {
    if (state == null) {
        std.debug.print("==== {s} ====\n", .{title});
        return;
    }
    mutex.lock();
    defer mutex.unlock();
    var det: [160]u8 = undefined;
    if (std.fmt.bufPrint(&det, "==================== {s} ====================\n", .{title})) |line| {
        appendDetailed(line);
    } else |_| {}
    var sim: [160]u8 = undefined;
    if (std.fmt.bufPrint(&sim, "==== {s} ====\n", .{title})) |line| {
        appendSimple(line);
    } else |_| {}
}

/// Full event: detailed.txt always; simple.txt by severity policy; stderr
/// for milestone/warn/err (+debug when verbose); boot.state for milestones.
pub fn event(cat: Category, sev: Severity, comptime fmt: []const u8, args: anytype) void {
    // Console trail (policy: milestones and problems, never trace spam).
    const to_console = switch (sev) {
        .info, .warn, .err, .fatal => true,
        .debug => verbose,
        .trace, .note => false,
    };
    var cbuf: [1024]u8 = undefined;
    var console_line: ?[]const u8 = null;
    if (to_console) {
        const prefix: []const u8 = switch (sev) {
            .info => "[OMORI]",
            .warn => "[OMORI:WARN]",
            .err => "[OMORI:ERR]",
            .fatal => "[OMORI:ERR]",
            .debug => "[OMORI:DBG]",
            else => unreachable,
        };
        if (std.fmt.bufPrint(&cbuf, "{s} " ++ fmt ++ "\n", .{prefix} ++ args)) |l| {
            console_line = l;
        } else |_| {
            cbuf[cbuf.len - 1] = '\n';
            console_line = cbuf[0..cbuf.len];
        }
    }

    if (state == null) {
        if (console_line) |l| std.debug.print("{s}", .{l});
        if (log_dir) |d| {
            if (sevAtLeast(sev, .info)) appendState(d, console_line orelse "");
        }
        return;
    }

    mutex.lock();
    defer mutex.unlock();
    if (console_line) |l| std.debug.print("{s}", .{l});
    eventLocked(cat, sev, console_line, fmt, args);

    if (sevAtLeast(sev, .info) and log_dir != null and console_line != null) {
        appendState(log_dir.?, console_line.?);
    }
}

pub fn flush() void {
    if (state == null) return;
    mutex.lock();
    defer mutex.unlock();
    flushLocked() catch {};
}

// ---------------------------------------------------------------------------
// Locked internals
// ---------------------------------------------------------------------------

fn eventLocked(cat: Category, sev: Severity, console_line: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
    const st = &state.?;
    const seq = st.seq.fetchAdd(1, .monotonic);

    var msg: [1024]u8 = undefined;
    const m = std.fmt.bufPrint(&msg, fmt, args) catch blk: {
        const n = msg.len - 1;
        const marker = [12]u8{ '<', 'T', 'R', 'U', 'N', 'C', 'A', 'T', 'E', 'D', '>', '.' };
        msg[n - 12 .. n][0..12].* = marker;
        break :blk msg[0..n];
    };

    const wall = formatWall(std.time.milliTimestamp());
    const mono_s = @divTrunc(std.time.nanoTimestamp() - st.start_mono_ns, std.time.ns_per_s);

    var det: [1280]u8 = undefined;
    if (std.fmt.bufPrint(&det, "[{s}] [{d:>10}s] [{d:0>6}] [{s} {s}] {s}\n", .{
        wall, mono_s, seq, cat.name(), sev.tag(), m,
    })) |line| {
        appendDetailed(line);
    } else |_| {}

    pushRing(cat, sev, m);

    if (wantsSimple(cat, sev)) {
        var sim: [640]u8 = undefined;
        var sim_line: []const u8 = undefined;
        if (console_line) |cl| {
            // Reuse the console text (already prefixed) with wall time.
            const body = std.mem.trimRight(u8, cl, "\n");
            sim_line = std.fmt.bufPrint(&sim, "[{s}] {s}\n", .{ wall, body }) catch return;
        } else {
            sim_line = std.fmt.bufPrint(&sim, "[{s}] {s} {s} {s}\n", .{ wall, sev.tag(), cat.name(), m }) catch return;
        }
        appendSimple(sim_line);
    }

    st.events_since_flush += 1;
    // v29: flush EVERY event. The v28 device run lost the detailed.txt
    // tail (last 5 lines, SIGKILL during the white-screen freeze) because
    // this gate only flushed every 256 events / on warns. Small raw
    // write(2) per line is cheap; a lost tail is unfixable.
    flushLocked() catch {};
}

fn kvLocked(cat: Category, key: []const u8, comptime fmt: []const u8, args: anytype) void {
    const st = &state.?;
    const seq = st.seq.fetchAdd(1, .monotonic);
    var val: [768]u8 = undefined;
    const v = std.fmt.bufPrint(&val, fmt, args) catch return;
    const wall = formatWall(std.time.milliTimestamp());
    var det: [1100]u8 = undefined;
    if (std.fmt.bufPrint(&det, "[{s}] [{d:0>6}] [{s} KV] {s} = {s}\n", .{ wall, seq, cat.name(), key, v })) |line| {
        appendDetailed(line);
    } else |_| {}
    st.events_since_flush += 1;
}

fn dumpLocked(cat: Category, title: []const u8, bytes: []const u8) void {
    var hdr: [200]u8 = undefined;
    if (std.fmt.bufPrint(&hdr, "---- HEXDUMP {s}: {s} ({d} bytes) ----\n", .{ cat.name(), title, bytes.len })) |h| {
        appendDetailed(h);
    } else |_| {}

    var offset: usize = 0;
    while (offset < bytes.len) : (offset += 16) {
        const n = @min(16, bytes.len - offset);
        var row: [128]u8 = undefined;
        var used: usize = 0;

        used += (std.fmt.bufPrint(row[used..], "  {x:0>8}  ", .{offset}) catch return).len;
        var i: usize = 0;
        while (i < 16) : (i += 1) {
            if (i < n) {
                used += (std.fmt.bufPrint(row[used..], "{X:0>2} ", .{bytes[offset + i]}) catch return).len;
            } else {
                used += (std.fmt.bufPrint(row[used..], "   ", .{}) catch return).len;
            }
            if (i == 7) used += (std.fmt.bufPrint(row[used..], " ", .{}) catch return).len;
        }
        used += (std.fmt.bufPrint(row[used..], " |", .{}) catch return).len;
        i = 0;
        while (i < n) : (i += 1) {
            const c = bytes[offset + i];
            row[used] = if (c >= 0x20 and c < 0x7f) c else '.';
            used += 1;
        }
        row[used] = '|';
        used += 1;
        row[used] = '\n';
        used += 1;
        appendDetailed(row[0..used]);
    }
    var tail: [80]u8 = undefined;
    if (std.fmt.bufPrint(&tail, "---- END HEXDUMP ({d} bytes) ----\n", .{bytes.len})) |t| {
        appendDetailed(t);
    } else |_| {}
}

fn appendDetailed(line: []const u8) void {
    const st = &state.?;
    if (det_buf.len - det_len < line.len) {
        flushLocked() catch {};
    }
    if (line.len > det_buf.len) {
        // Oversized line: write directly.
        st.detailed.writeAll(line) catch {
            st.dropped += 1;
        };
        st.bytes_detailed += line.len;
        return;
    }
    @memcpy(det_buf[det_len..][0..line.len], line);
    det_len += line.len;
    st.bytes_detailed += line.len;
}

fn appendSimple(line: []const u8) void {
    const st = &state.?;
    if (sim_buf.len - sim_len < line.len) {
        flushLocked() catch {};
    }
    if (line.len > sim_buf.len) {
        st.simple.writeAll(line) catch {
            st.dropped += 1;
        };
        st.bytes_simple += line.len;
        return;
    }
    @memcpy(sim_buf[sim_len..][0..line.len], line);
    sim_len += line.len;
    st.bytes_simple += line.len;
}

fn flushLocked() !void {
    if (state == null) return;
    if (det_len > 0) {
        try state.?.detailed.writeAll(det_buf[0..det_len]);
        det_len = 0;
    }
    if (sim_len > 0) {
        try state.?.simple.writeAll(sim_buf[0..sim_len]);
        sim_len = 0;
    }
    state.?.events_since_flush = 0;
}

// ---------------------------------------------------------------------------
// Ring buffer
// ---------------------------------------------------------------------------

fn pushRing(cat: Category, sev: Severity, msg: []const u8) void {
    const idx = ring_head.fetchAdd(1, .monotonic) % ring_slots;
    const slot = &ring[idx];
    const seq = slot.seq.load(.monotonic);
    slot.seq.store(seq + 1, .monotonic); // odd => writer active
    var tag: [ring_line_max + 24]u8 = undefined;
    const m = std.fmt.bufPrint(&tag, "{s} {s} {s}", .{ sev.tag(), cat.name(), msg }) catch blk: {
        const n = @min(msg.len, ring_line_max);
        break :blk msg[0..n];
    };
    const mm = @min(m.len, ring_line_max);
    @memcpy(slot.buf[0..mm], m[0..mm]);
    slot.len = mm;
    slot.seq.store(seq + 2, .release); // even => stable
}

/// Best-effort lock-free snapshot for the crash handler. Returns bytes
/// written into `out` (one line per slot, oldest first).
pub fn ringSnapshot(out: []u8) usize {
    var written: usize = 0;
    const base = ring_head.load(.acquire);
    var i: usize = 0;
    while (i < ring_slots) : (i += 1) {
        const idx = (base + i) % ring_slots; // oldest .. newest
        const slot = &ring[idx];
        const s1 = slot.seq.load(.acquire);
        if (s1 & 1 != 0) continue; // writer active
        const len = slot.len;
        if (len == 0 or len > ring_line_max) continue;
        var tmp: [ring_line_max]u8 = undefined;
        @memcpy(tmp[0..len], slot.buf[0..len]);
        const s2 = slot.seq.load(.acquire);
        if (s1 != s2 or (s2 & 1) != 0) continue; // torn read
        const line = std.fmt.bufPrint(out[written..], "  {s}\n", .{tmp[0..len]}) catch break;
        written += line.len;
    }
    return written;
}

// ---------------------------------------------------------------------------
// Policies & helpers
// ---------------------------------------------------------------------------

fn sevAtLeast(a: Severity, b: Severity) bool {
    return @intFromEnum(a) >= @intFromEnum(b);
}

/// Which events appear in simple.txt: warnings/errors always; notes+
/// for high-signal cats; info+ for milestone cats.
fn wantsSimple(cat: Category, sev: Severity) bool {
    if (sevAtLeast(sev, .warn)) return true;
    return switch (cat) {
        .sys, .mv, .data, .atlas, .save, .crash, .@"test" => sevAtLeast(sev, .info),
        else => sevAtLeast(sev, .note),
    };
}

/// Wall clock "HH:MM:SS" (UTC — deterministic across environments).
fn formatWall(unix_ms: i64) [8]u8 {
    const secs = @divFloor(unix_ms, 1000);
    const epoch_secs: u64 = @intCast(@max(secs, 0));
    const tod = epoch_secs % 86400;
    const hh = tod / 3600;
    const mm = (tod % 3600) / 60;
    const ss = tod % 60;
    var out: [8]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>2}:{d:0>2}:{d:0>2}", .{ hh, mm, ss }) catch {
        @memcpy(&out, "00:00:00");
    };
    return out;
}

/// Append a milestone line to `<log_dir>/boot.state` (the v20 contract:
/// single writer, best effort — a logging failure must never kill the game).
fn appendState(dir: []const u8, line: []const u8) void {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/boot.state", .{dir}) catch return;
    var file = std.fs.cwd().createFile(path, .{ .truncate = false }) catch return;
    defer file.close();
    file.seekFromEnd(0) catch return;
    file.writeAll(line) catch return;
}

// ---------------------------------------------------------------------------
// Hyper-technical environment header (detailed.txt)
// ---------------------------------------------------------------------------

fn writeBanner(title: []const u8) void {
    var buf: [160]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "==================== {s} ====================\n", .{title})) |l| {
        appendDirect(l);
    } else |_| {}
    var sb: [160]u8 = undefined;
    if (std.fmt.bufPrint(&sb, "==== {s} ====\n", .{title})) |l| {
        appendSimpleDirect(l);
    } else |_| {}
    std.debug.print("==== {s} ====\n", .{title});
}

fn appendDirect(line: []const u8) void {
    if (state == null) return;
    state.?.detailed.writeAll(line) catch {
        state.?.dropped += 1;
    };
    state.?.bytes_detailed += line.len;
}

fn appendSimpleDirect(line: []const u8) void {
    if (state == null) return;
    state.?.simple.writeAll(line) catch {
        state.?.dropped += 1;
    };
    state.?.bytes_simple += line.len;
}

fn writeEnvHeader() void {
    var big: [48 * 1024]u8 = undefined;
    var len: usize = 0;

    const wall = formatWall(std.time.milliTimestamp());
    const S = struct {
        fn put(b: []u8, l: *usize, s: []const u8) void {
            const n = @min(s.len, b.len - l.*);
            @memcpy(b[l.*..][0..n], s[0..n]);
            l.* += n;
        }
        fn print(b: []u8, l: *usize, comptime fmt: []const u8, args: anytype) void {
            const s = std.fmt.bufPrint(b[l.*..], fmt, args) catch return;
            l.* += s.len;
        }
    };

    S.print(&big, &len, "OMORI NATIVE RUNTIME — DETAILED TECHNICAL LOG\n", .{});
    S.print(&big, &len, "================================================================================\n", .{});
    S.print(&big, &len, "  session start (UTC)      : {s}\n", .{wall});
    S.print(&big, &len, "  target                   : {s}-{s}-{s}\n", .{
        @tagName(builtin.cpu.arch),
        @tagName(builtin.os.tag),
        @tagName(builtin.abi),
    });
    S.print(&big, &len, "  cpu model (native)       : {s}\n", .{builtin.cpu.model.name});
    S.print(&big, &len, "  build mode               : {s}\n", .{@tagName(builtin.mode)});
    S.print(&big, &len, "  endianness               : {s}\n", .{@tagName(builtin.cpu.arch.endian())});
    S.print(&big, &len, "  pointer size             : {d} bytes\n", .{@sizeOf(usize)});
    S.print(&big, &len, "  page size                : {d}\n", .{std.heap.pageSize()});
    S.print(&big, &len, "  pid / ppid               : {d} / {d}\n", .{ std.c.getpid(), std.c.getppid() });
    S.print(&big, &len, "  cpu count                : {d}\n", .{std.Thread.getCpuCount() catch 0});

    // argv
    S.print(&big, &len, "  argv                     :", .{});
    if (std.process.argsAlloc(state.?.alloc)) |argv| {
        defer std.process.argsFree(state.?.alloc, argv);
        for (argv) |a| {
            S.print(&big, &len, " [{s}]", .{a});
        }
    } else |_| {}
    S.put(&big, &len, "\n");

    // Environment of interest.
    const interesting = [_][]const u8{
        "OMORI_LOG_DIR", "OMORI_HEADLESS", "OMORI_IMAGE_CACHE_MIB",
        "HOME",         "USER",           "LANG",
        "LC_ALL",       "DISPLAY",        "WAYLAND_DISPLAY",
        "XDG_RUNTIME_DIR", "LD_LIBRARY_PATH", "SDL_AUDIODRIVER",
    };
    for (interesting) |key| {
        if (std.posix.getenv(key)) |val| {
            S.print(&big, &len, "  env {s: <22} = {s}\n", .{ key, val });
        }
    }

    // /proc excerpts.
    procExcerpt(&big, &len, "/proc/self/status", 2048);
    procExcerpt(&big, &len, "/proc/version", 300);
    procExcerpt(&big, &len, "/proc/self/limits", 1200);

    S.print(&big, &len, "================================================================================\n", .{});

    appendDirect(big[0..len]);
}

fn procExcerpt(buf: []u8, len: *usize, path: []const u8, max: usize) void {
    const f = std.fs.openFileAbsolute(path, .{}) catch return;
    defer f.close();
    var rb: [4096]u8 = undefined;
    const n = f.readAll(&rb) catch 0;
    if (n == 0) return;
    const lim = @min(n, max);
    const S = struct {
        fn print(b: []u8, l: *usize, comptime fmt: []const u8, args: anytype) void {
            const s = std.fmt.bufPrint(b[l.*..], fmt, args) catch return;
            l.* += s.len;
        }
    };
    S.print(buf, len, "  ---- {s} (first {d} bytes) ----\n", .{ path, lim });
    var it = std.mem.splitScalar(u8, rb[0..lim], '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        S.print(buf, len, "  | {s}\n", .{line});
    }
}

// ---------------------------------------------------------------------------
// Raw write for the crash handler
// ---------------------------------------------------------------------------

/// write(2) loop — async-signal-safe; used by core/crash.zig.
pub fn writeRaw(fd: std.posix.fd_t, bytes: []const u8) void {
    if (fd < 0) return;
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.posix.write(fd, bytes[off..]) catch return;
        if (n == 0) return;
        off += n;
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "milestone writes without a log dir (console-only)" {
    milestone("test milestone {d}", .{42});
}

test "formatWall determinism" {
    const s = formatWall(0);
    try testing.expectEqualStrings("00:00:00", &s);
}

test "ring push and snapshot" {
    pushRing(.@"test", .info, "hello ring");
    var out: [ring_slots * (ring_line_max + 8)]u8 = undefined;
    const n = ringSnapshot(&out);
    try testing.expect(n > 0);
}

test "event with initialized logger writes both files" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const tmp = "/tmp/omori-log-test";
    std.fs.cwd().deleteTree(tmp) catch {};
    defer std.fs.cwd().deleteTree(tmp) catch {};

    init(arena.allocator(), tmp);
    try testing.expect(isInit());
    defer deinit();

    event(.sys, .info, "hello {s}", .{"world"});
    detail(.vfs, "trace-level line {d}", .{7});
    kv(.data, "Actors.json", "entries={d}", .{9});
    dump(.@"test", "tiny", &[_]u8{ 0xDE, 0xAD, 0xBE, 0xEF });
    section("TEST SECTION");
    event(.vfs, .note, "vfs note (simple gets this)", .{});
    flush();

    // detailed.txt must contain everything.
    const det = try std.fs.cwd().readFileAlloc(arena.allocator(), tmp ++ "/detailed.txt", 1 << 20);
    try testing.expect(std.mem.indexOf(u8, det, "hello world") != null);
    try testing.expect(std.mem.indexOf(u8, det, "trace-level line 7") != null);
    try testing.expect(std.mem.indexOf(u8, det, "Actors.json = entries=9") != null);
    try testing.expect(std.mem.indexOf(u8, det, "HEXDUMP") != null);
    try testing.expect(std.mem.indexOf(u8, det, "DE AD BE EF") != null);
    try testing.expect(std.mem.indexOf(u8, det, "DETAILED TECHNICAL LOG") != null);
    try testing.expect(std.mem.indexOf(u8, det, "TEST SECTION") != null);
    try testing.expect(std.mem.indexOf(u8, det, "pid / ppid") != null);

    // simple.txt: milestones and crash-style lines only, no trace spam.
    const sim = try std.fs.cwd().readFileAlloc(arena.allocator(), tmp ++ "/simple.txt", 1 << 20);
    try testing.expect(std.mem.indexOf(u8, sim, "hello world") != null);
    try testing.expect(std.mem.indexOf(u8, sim, "TEST SECTION") != null);
    try testing.expect(std.mem.indexOf(u8, sim, "trace-level line 7") == null);
    try testing.expect(std.mem.indexOf(u8, sim, "HEXDUMP") == null);

    // v33 rotation: second init shifts the previous file to -001.
    deinit();
    init(arena.allocator(), tmp);
    event(.sys, .info, "second session", .{});
    deinit();
    const gen1 = try std.fs.cwd().readFileAlloc(arena.allocator(), tmp ++ "/detailed-001.txt", 1 << 20);
    try testing.expect(std.mem.indexOf(u8, gen1, "hello world") != null);
    const det2 = try std.fs.cwd().readFileAlloc(arena.allocator(), tmp ++ "/detailed.txt", 1 << 20);
    try testing.expect(std.mem.indexOf(u8, det2, "second session") != null);

    // v33: a third session shifts again — 001 becomes 002, history lives.
    init(arena.allocator(), tmp);
    event(.sys, .info, "third session", .{});
    deinit();
    const gen2 = try std.fs.cwd().readFileAlloc(arena.allocator(), tmp ++ "/detailed-002.txt", 1 << 20);
    try testing.expect(std.mem.indexOf(u8, gen2, "hello world") != null);
    const det3 = try std.fs.cwd().readFileAlloc(arena.allocator(), tmp ++ "/detailed.txt", 1 << 20);
    try testing.expect(std.mem.indexOf(u8, det3, "third session") != null);
}
