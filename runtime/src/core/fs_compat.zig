//! Kernel-4.4-compatible filesystem operations — THE v26 device fix.
//!
//! **Root cause (proven from the v26 device logs):** Zig 0.15's std.fs
//! calls the `statx` syscall (Linux 4.11+) in exactly two places —
//! `Dir.statFile` and `File.stat` — and those poison three public APIs:
//!
//! * `Dir.statFile(path)` → statx
//! * `File.stat()` / `File.getEndPos()` → statx  ⇒ `Dir.readFileAlloc`
//!   (it asks the open file for its size) fails too
//! * `Dir.makePath(path)` → mkdir fails EEXIST on an existing directory,
//!   then stats it with `statFile` to check it is a directory → statx
//!
//! The R36S's RK3326 vendor kernel is **4.4.189** — `statx` does not
//! exist there (syscall 382 returns ENOSYS), so std.fs maps it to
//! `error.Unexpected`. On the real device this killed the runtime twice:
//!
//! ```text
//! [OMORI:ERR] logs: cannot create dir '/roms2/ports/omori/logs'
//!   → makePath → EEXIST (launcher had created the dir) → statFile → ENOSYS
//! [OMORI:ERR] game tree verification failed: 'index.html' is missing
//!   → Vfs.statSync → statFile → ENOSYS → "MISS" → BadGameTree → exit(1)
//! ```
//!
//! …which is precisely why v25/v26 showed *no window and no title*: the
//! runtime died at the first stat after the banner. The same ENOSYS would
//! also have killed every `readFileAlloc` (database, Atlas, images, fonts,
//! saves) had boot progressed that far.
//!
//! **The fix:** every filesystem stat/read/mkdir in the runtime goes
//! through this module, built exclusively on syscalls that exist on every
//! kernel the port targets: `fstatat` (Linux 2.6.16+, present in ALL
//! aarch64 kernels), `mkdirat`, `openat`, `read`. `std.fs` remains in use
//! only for open/create/rename/delete/iterate — openat/mkdirat/renameat/
//! unlinkat/getdents64, all 4.4-safe.
//!
//! `statxAvailable()` probes the kernel once at boot so detailed.txt
//! records which layer ran (on a 4.4 device: "unavailable"; everywhere
//! else: "available but deliberately unused").

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

// ---------------------------------------------------------------------------
// statx probe (diagnostic only — the compat layer is used unconditionally)
// ---------------------------------------------------------------------------

var statx_state: enum { unknown, available, unavailable } = .unknown;

/// True when this kernel implements the statx syscall. Linux < 4.11
/// (e.g. the R36S's 4.4.189 RK3326 vendor kernel) does not — the probe
/// sees ENOSYS. One syscall, cached; never used for data paths.
pub fn statxAvailable() bool {
    switch (statx_state) {
        .available => return true,
        .unavailable => return false,
        .unknown => {},
    }
    if (builtin.os.tag != .linux) {
        statx_state = .available;
        return true;
    }
    var stx: std.os.linux.Statx = std.mem.zeroes(std.os.linux.Statx);
    // AT.EMPTY_PATH stats the dirfd itself; fd 0 (stdin) is only a probe
    // target — any errno other than ENOSYS means the syscall exists.
    const rc = std.os.linux.statx(0, "", std.os.linux.AT.EMPTY_PATH, std.os.linux.STATX_TYPE, &stx);
    const available = std.os.linux.E.init(rc) != .NOSYS;
    statx_state = if (available) .available else .unavailable;
    return available;
}

/// One-line boot diagnostic for detailed.txt (call once after logging is
/// retargeted — the device log then shows which layer ran and why).
pub fn logDiag() void {
    const log = @import("log.zig");
    if (statxAvailable()) {
        log.event(.vfs, .note, "fs compat layer: statx available on this kernel (unused by design — fstatat paths only)", .{});
    } else {
        log.event(.vfs, .note, "fs compat layer: statx UNAVAILABLE on this kernel (< 4.11) — fstatat paths only; this is the v26 'BadGameTree / cannot create logs dir' device failure, fixed", .{});
    }
}

// ---------------------------------------------------------------------------
// statFile — Dir.statFile replacement (follows symlinks, like std's)
// ---------------------------------------------------------------------------

pub const StatError = error{
    FileNotFound,
    AccessDenied,
    PermissionDenied,
    NameTooLong,
    SymLinkLoop,
    SystemResources,
    InvalidUtf8,
    Unexpected,
};

/// `statFile` — identical observable semantics to `std.fs.Dir.statFile`
/// on Linux, minus the statx syscall. Follows symlinks (flags = 0).
pub fn statFile(dir: std.fs.Dir, sub_path: []const u8) StatError!std.fs.File.Stat {
    const st = try posix.fstatat(dir.fd, sub_path, 0);
    return std.fs.File.Stat.fromPosix(st);
}

// ---------------------------------------------------------------------------
// makePath — mkdir -p that tolerates existing directories on old kernels
// ---------------------------------------------------------------------------

pub const MakePathError = posix.MakeDirError || error{Unexpected};

/// `makePath` — mkdir -p semantics. std's version fails with
/// `error.Unexpected` on kernels without statx whenever the directory
/// already exists (EEXIST → statFile → ENOSYS); this version verifies
/// existing entries with `fstatat` instead, so it works on the R36S's
/// 4.4.189 kernel where the launcher pre-creates the logs/saves dirs.
pub fn makePath(dir: std.fs.Dir, sub_path: []const u8) MakePathError!void {
    if (sub_path.len == 0) return;
    dir.makeDir(sub_path) catch |err| switch (err) {
        error.PathAlreadyExists => try verifyExistingDir(dir, sub_path),
        error.FileNotFound => blk: {
            // Missing parent: create the chain, then retry this component.
            const parent = std.fs.path.dirname(sub_path) orelse
                return error.FileNotFound;
            if (parent.len == 0 or std.mem.eql(u8, parent, sub_path))
                return error.FileNotFound;
            try makePath(dir, parent);
            break :blk dir.makeDir(sub_path) catch |err2| switch (err2) {
                // A racing creator may have made it between the two calls.
                error.PathAlreadyExists => try verifyExistingDir(dir, sub_path),
                else => return err2,
            };
        },
        else => return err,
    };
}

fn verifyExistingDir(dir: std.fs.Dir, sub_path: []const u8) MakePathError!void {
    const st = posix.fstatat(dir.fd, sub_path, 0) catch
        return error.FileNotFound; // vanished between mkdir and stat
    if (!posix.S.ISDIR(st.mode)) return error.NotDir;
}

// ---------------------------------------------------------------------------
// readFileAlloc — no getEndPos (that is statx on Linux)
// ---------------------------------------------------------------------------

/// `readFileAlloc` — std's implementation asks the open file for its size
/// via `getEndPos` → `File.stat` → statx, which fails on Linux < 4.11.
/// This version reads in 64 KiB chunks until EOF: openat + read only.
/// Same contract: caller owns the buffer; `error.FileTooBig` past
/// `max_bytes`; `error.FileNotFound` when the path is missing.
pub fn readFileAlloc(
    dir: std.fs.Dir,
    alloc: std.mem.Allocator,
    sub_path: []const u8,
    max_bytes: usize,
) ![]u8 {
    var file = try dir.openFile(sub_path, .{});
    defer file.close();

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(alloc);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break; // EOF
        if (list.items.len + n > max_bytes) return error.FileTooBig;
        try list.appendSlice(alloc, buf[0..n]);
    }
    return list.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Tests: the deterministic battery for the compat layer.
// ---------------------------------------------------------------------------

const testing = std.testing;

test "statFile: file, directory, missing — the game-tree-verification shape" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try dir.writeFile(.{ .sub_path = "index.html", .data = "<html/>" });
    try makePath(dir, "data");

    const st_file = try statFile(dir, "index.html");
    try testing.expectEqualStrings("file", @tagName(st_file.kind));
    try testing.expectEqual(@as(u64, "<html/>".len), st_file.size);

    const st_dir = try statFile(dir, "data");
    try testing.expectEqualStrings("directory", @tagName(st_dir.kind));

    try testing.expectError(error.FileNotFound, statFile(dir, "missing.json"));
}

test "makePath: nested creation, existing-dir tolerance, file-in-the-way" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    // Fresh nested creation.
    try makePath(dir, "a/b/c");
    // Existing directory — THE v26 device failure shape (launcher had
    // already created the dir; std's makePath dies on statx here).
    try makePath(dir, "a/b/c");
    try makePath(dir, "a");
    // A file where a directory is needed.
    try dir.writeFile(.{ .sub_path = "blocker", .data = "x" });
    try testing.expectError(error.NotDir, makePath(dir, "blocker/sub"));
}

test "readFileAlloc: exact bytes, FileTooBig, missing" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    // A payload larger than one 64 KiB chunk.
    var big: [200 * 1024]u8 = undefined;
    for (&big, 0..) |*b, i| b.* = @truncate(i *% 31);
    try dir.writeFile(.{ .sub_path = "sheet.png", .data = &big });

    const data = try readFileAlloc(dir, alloc, "sheet.png", 512 * 1024);
    defer alloc.free(data);
    try testing.expectEqual(@as(usize, big.len), data.len);
    try testing.expectEqualSlices(u8, &big, data);

    try testing.expectError(error.FileTooBig, readFileAlloc(dir, alloc, "sheet.png", 1024));
    try testing.expectError(error.FileNotFound, readFileAlloc(dir, alloc, "missing.png", 1024));
}

test "statxAvailable: probe never crashes, result cached" {
    const first = statxAvailable();
    const second = statxAvailable();
    try testing.expectEqual(first, second);
}

test "roundtrip: makePath + write + statFile + readFileAlloc (the boot path)" {
    const alloc = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = tmp.dir;

    try makePath(dir, "omori/logs");
    try dir.writeFile(.{ .sub_path = "omori/logs/detailed.txt", .data = "session-start" });
    // The exact sequence the device failed on: stat an existing file
    // inside an existing directory created by makePath.
    const st = try statFile(dir, "omori/logs/detailed.txt");
    try testing.expectEqual(@as(u64, "session-start".len), st.size);
    const text = try readFileAlloc(dir, alloc, "omori/logs/detailed.txt", 1024);
    defer alloc.free(text);
    try testing.expectEqualStrings("session-start", text);
}
