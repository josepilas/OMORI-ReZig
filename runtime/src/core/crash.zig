//! Crash reporter — captures everything into the dual-file logs.
//!
//! Catches:
//!   * POSIX signals: SIGSEGV, SIGILL, SIGBUS, SIGFPE, SIGABRT
//!   * Zig runtime panics (root `pub const panic = FullPanic(panicHook)`)
//!
//! The signal path is async-signal-safe in practice: it uses ONLY
//! fixed static buffers, raw write(2) on pre-opened descriptors, and
//! pre-computed data. No locks, no allocation, no libc formatting.
//!
//! Each CRASH REPORT contains:
//!   * signal number/code, fault address, thread id
//!   * RAISED-signal detection: si_code < 0 (SI_TKILL/SI_USER) means
//!     somebody called raise()/kill() — e.g. SDL2's own fatal-signal
//!     handler chain (appsignal.c) re-raising OUR catch through libc.
//!     v32's device reports were exactly that (code -6, si_addr = the
//!     pid) and the ORIGINAL fault was hidden. v33 also sets
//!     SDL_NO_SIGNAL_HANDLERS=1 in main so the chain never installs.
//!   * integer registers (x86_64 gregs / aarch64 regs + SP/PC)
//!   * aarch64 ucontext decode using the Linux ABI: uc_mcontext at
//!     +176, including uc_sigmask and alignment padding. A NULL or wild
//!     PC remains the saved PC; mapping permissions never choose an ABI.
//!   * raw PC/LR and mapping-relative code-address hints for offline
//!     symbolization against the matching ELF
//!   * v34: sym-hints — EVERY register slot that lands in an executable
//!     mapping gets a mapping-relative offset line (the v33 device
//!     report's PC/LR were garbage while X29 symbolized into
//!     GameLoop.run — never bet on one slot again)
//!   * raw FIRST 512 BYTES of the ucontext for offline inspection
//!   * frame-pointer backtrace (raw addresses, up to 48 frames)
//!   * /proc/self/maps excerpt around the fault address + map count
//!   * ring snapshot: the last ~96 log events before the crash
//!   * re-raise with default disposition (correct wait status / core)
//!
//! The panic hook runs in normal context (locks and allocation allowed):
//! it logs the message, a native stack trace, flushes, and aborts.

const std = @import("std");
const builtin = @import("builtin");
const log = @import("log.zig");

// ---------------------------------------------------------------------------
// Signal installation
// ---------------------------------------------------------------------------

const watched = [_]u6{
    std.posix.SIG.SEGV,
    std.posix.SIG.ILL,
    std.posix.SIG.BUS,
    std.posix.SIG.FPE,
    std.posix.SIG.ABRT,
};

var installed: bool = false;
// Read before any signal arrives; ET_EXEC addresses are already ELF
// virtual addresses. Subtracting the first /proc/self/maps range breaks
// addr2line for the shipped non-PIE executable.
var executable_elf_type: u16 = 0;

fn readExecutableElfType() void {
    const file = std.fs.openFileAbsolute("/proc/self/exe", .{}) catch return;
    defer file.close();
    var header: [18]u8 = undefined;
    const n = file.readAll(&header) catch return;
    if (n != header.len or !std.mem.eql(u8, header[0..4], "\x7fELF")) return;
    const endian: std.builtin.Endian = switch (header[5]) {
        1 => .little,
        2 => .big,
        else => return,
    };
    executable_elf_type = std.mem.readInt(u16, header[16..18], endian);
}

/// v32: the alternate signal stack. A stack-overflow SIGSEGV lands the
/// handler on the (exhausted) faulting stack — the kernel cannot even push
/// the signal frame, so SA_RESETHAND hands the SECOND fault the default
/// disposition and the process dies with exit 139 and NO report (exactly
/// the v31 device signature). SA_ONSTACK runs the handler here instead:
/// 64 KiB is ~2.6× the handler's own measured use (~24 KiB ring_out + the
/// register/report buffers).
var alt_stack: [64 * 1024]u8 align(16) linksection(".bss") = @splat(0);

pub fn install() void {
    if (installed) return;
    readExecutableElfType();
    // v32: register the alternate stack FIRST (best-effort: a failure
    // logs and the handler still runs on the faulting stack, like v31).
    {
        var st = std.posix.stack_t{
            .sp = @ptrCast(&alt_stack),
            .size = alt_stack.len,
            .flags = 0,
        };
        std.posix.sigaltstack(&st, null) catch |e| {
            log.detail(.crash, "sigaltstack registration failed ({any}) — handler runs on the faulting stack", .{e});
        };
    }
    var act = std.posix.Sigaction{
        .handler = .{ .sigaction = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.SIGINFO | std.posix.SA.RESETHAND | std.posix.SA.ONSTACK,
    };
    for (watched) |sig| {
        // 0.15.2: std.posix.sigaction returns void; failures are
        // unreachable per std (SIGKILL/SIGSTOP only — not in our set).
        std.posix.sigaction(sig, &act, null);
    }
    installed = true;
    log.detail(.crash, "signal handlers installed: SEGV ILL BUS FPE ABRT (SA_SIGINFO|SA_RESETHAND|SA_ONSTACK, 64 KiB alt stack)", .{});
}

// ---------------------------------------------------------------------------
// Zig panic hook (normal context)
// ---------------------------------------------------------------------------

pub fn panicHook(message: []const u8, ret_addr: ?usize) noreturn {
    // The logger may or may not be initialized; event() handles both.
    log.event(.crash, .fatal, "ZIG PANIC: {s} (ret_addr=0x{x})", .{ message, ret_addr orelse 0 });

    // Native stack trace into the crash log (best effort).
    var addresses: [64]usize = undefined;
    var trace = std.builtin.StackTrace{
        .index = 0,
        .instruction_addresses = &addresses,
    };
    std.debug.captureStackTrace(ret_addr orelse @returnAddress(), &trace);
    log.event(.crash, .fatal, "panic backtrace: {d} frames follow in detailed.txt", .{trace.index});
    for (trace.instruction_addresses[0..trace.index]) |addr| {
        log.detail(.crash, "  frame 0x{x}", .{addr});
    }

    // Ring snapshot → detailed.txt directly (normal context, locked path OK).
    log.section("CRASH REPORT — Zig panic");
    log.detail(.crash, "message: {s}", .{message});
    log.detail(.crash, "panic backtrace ({d} frames):", .{trace.index});
    for (trace.instruction_addresses[0..trace.index], 0..) |addr, i| {
        log.detail(.crash, "  #{d}  0x{x}", .{ i, addr });
    }
    writeRingIntoDetailed();
    log.event(.crash, .fatal, "aborting (SIGABRT); see detailed.txt for the full report", .{});
    log.flush();

    // Die exactly like the signal path: unblock SIGABRT, then raw kill()
    // (std.posix.raise parked instead of dying — libc raise interacts with
    // the already-installed ABRT handler; the raw path is proven by the
    // --self-crash test).
    {
        var set: u64 = @as(u64, 1) << @as(u6, std.posix.SIG.ABRT - 1);
        _ = std.os.linux.syscall4(.rt_sigprocmask, 1, @intFromPtr(&set), 0, @sizeOf(u64));
        const pid = std.os.linux.syscall0(.getpid);
        _ = std.os.linux.syscall2(.kill, pid, std.posix.SIG.ABRT);
    }
    while (true) std.atomic.spinLoopHint();
}

fn writeRingIntoDetailed() void {
    var buf: [24 * 1024]u8 = undefined;
    const n = log.ringSnapshot(&buf);
    if (n == 0) return;
    // Emit through raw write so it works even mid-teardown.
    log.writeRaw(log.detailed_fd_raw, "!! last events before crash (ring snapshot):\n");
    log.writeRaw(log.detailed_fd_raw, buf[0..n]);
}

// ---------------------------------------------------------------------------
// Signal path (async-signal-safe)
// ---------------------------------------------------------------------------

var report_buf: [48 * 1024]u8 align(8) = undefined;
var report_len: usize = 0;
var fault_addr: usize = 0;

/// v31: re-entry guard — a signal arriving while the crash report is
/// being built (the double-fault class) skips the report entirely and
/// re-raises immediately. The v30 run panicked twice inside the handler
/// before the process finally died with a usable report LOST.
var in_signal_handler: bool = false;

fn put(s: []const u8) void {
    if (report_len + s.len > report_buf.len) return;
    @memcpy(report_buf[report_len..][0..s.len], s);
    report_len += s.len;
}

fn putDec(v: u64) void {
    if (v == 0) {
        put("0");
        return;
    }
    var tmp: [24]u8 = undefined;
    var i: usize = tmp.len;
    var x = v;
    while (x > 0) : (x /= 10) {
        i -= 1;
        tmp[i] = @intCast('0' + @as(u8, @intCast(x % 10)));
    }
    put(tmp[i..]);
}

/// v31: SIGNED decimal — the v30 crash handler died in its own report
/// path: a userspace-raised signal (glibc abort / tgkill) carries
/// si_code = SI_TKILL = -6, and `putDec(@intCast(info.code))` PANICKED
/// with "integer does not fit in destination type" — a double fault
/// that REPLACED the real crash report with the handler's own panic
/// (the v30 device run's entire "ZIG PANIC" trail was this artifact).
fn putDecS(v: i64) void {
    if (v < 0) {
        put("-");
        // magnitude via two's-complement unsigned negate (no overflow:
        // @as(u64, @intCast(-v)) would panic at i64 min; bitcast instead).
        const mag: u64 = 0 -% @as(u64, @bitCast(v));
        putDec(mag);
    } else {
        putDec(@intCast(v));
    }
}

fn putHex(v: u64) void {
    if (v == 0) {
        put("0x0");
        return;
    }
    var tmp: [18]u8 = "0x0000000000000000".*;
    var i: usize = 18; // last hex digit lives at tmp[17]
    var x = v;
    while (x > 0) : (x >>= 4) {
        i -= 1;
        tmp[i] = "0123456789abcdef"[x & 0xf];
    }
    put(tmp[0..]);
}

fn handleSignal(sig: i32, info: *const std.posix.siginfo_t, ctx_ptr: ?*anyopaque) callconv(.c) void {
    // v31: re-entrant delivery (a second signal while reporting, e.g.
    // the panicHook's re-raise reaching a still-installed handler) →
    // restore the default disposition and die; NEVER build a second
    // report on top of a torn first one.
    if (in_signal_handler) {
        reRaise(sig);
    }
    in_signal_handler = true;

    report_len = 0;
    fault_addr = sigFaultAddress(info);

    // v32: read /proc/self/maps ONCE up front and parse it into a range
    // table. The frame-pointer walk below dereferences whatever the
    // saved FP register happens to hold — on the v31 device run that
    // pointer walked straight off the GPA page the double-free had just
    // unmapped, the walk itself faulted, SA_RESETHAND restored the
    // default disposition, and the process died at exit 139 with the
    // WHOLE report lost. Every readWord now validates its address
    // against this table first: a garbage FP ends the walk (with the
    // frames gathered so far) instead of ending the report.
    readMapsOnce();

    put("\n\n");
    put("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n");
    put("!! CRASH REPORT — signal ");
    putDec(@intCast(@as(u32, @bitCast(sig))));
    put(" (");
    put(sigName(sig));
    put(") code ");
    // v31: si_code can be NEGATIVE (SI_TKILL = -6 for userspace-raised
    // signals — glibc abort paths). The v30 @intCast(u64) here PANICKED
    // on exactly that, double-faulting the crash reporter.
    putDecS(info.code);
    put("\n");
    // v33: a NEGATIVE si_code (SI_TKILL = -6 / SI_USER = 0 with si_addr =
    // the sender pid) means the signal was RAISED from userspace — not a
    // memory fault. v32's device crashes were exactly this: SDL2 installs
    // its own fatal-signal handlers during SDL_Init (SDL_NO_SIGNAL_HANDLERS
    // disables that), its handler restored OUR disposition and re-raised
    // through libc raise() (tgkill), so we caught the re-raise and the
    // ORIGINAL fault's context was lost. main.zig now sets the env var;
    // if this note still fires, a fatal handler chain is still alive.
    if (info.code < 0) {
        put("!! NOTE: si_code < 0 — this signal was RAISED via raise()/tgkill\n");
        put("!! (userspace sender, si_addr holds the sender pid, not a fault\n");
        put("!! address). The register dump below is from the raise site.\n");
    }
    put("!! fault address: ");
    putHex(fault_addr);
    put("\n");
    put("!! pid: ");
    putDec(@as(u64, @intCast(std.c.getpid())));
    put("  thread id: ");
    putDec(std.Thread.getCurrentId());
    put("\n");

    if (ctx_ptr) |ctx| {
        dumpRegisters(ctx);
        put("!! backtrace (frame-pointer walk, maps-validated, raw addresses):\n");
        var fp = framePointerOf(ctx);
        var depth: usize = 0;
        while (fp != 0 and depth < 48) : (depth += 1) {
            if (fp < 0x1000) break;
            const ra_addr = fp + @sizeOf(usize);
            const ra = readWord(ra_addr) orelse break;
            const next = readWord(fp) orelse break;
            put("  #");
            putDec(depth);
            put("  ra=");
            putHex(ra);
            put("  fp=");
            putHex(fp);
            put("\n");
            if (next <= fp) break; // frame pointers must grow upward
            fp = next;
        }
        if (depth == 0) {
            put("  (no frame pointers available");
            if (map_range_count > 0) {
                put("; fp=");
                putHex(fp);
                put(" mapped=");
                put(if (addrIsMapped(fp)) "yes" else "no");
                put(" ranges=");
                putDec(map_range_count);
            } else {
                put("; maps table empty");
            }
            put(")\n");
        }
    } else {
        put("!! no ucontext delivered\n");
    }

    put("!! /proc/self/maps (excerpt around fault address + first maps):\n");
    dumpMapsExcerpt();

    put("!! last events before crash (ring snapshot):\n");
    {
        var ring_out: [24 * 1024]u8 = undefined;
        const n = log.ringSnapshot(&ring_out);
        put(ring_out[0..n]);
    }

    put("!! end of crash report — default disposition restored, re-raising\n");
    put("!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n");

    // Emit: detailed.txt (full), simple.txt + stderr (one line).
    log.writeRaw(log.detailed_fd_raw, report_buf[0..report_len]);
    {
        var sbuf: [256]u8 = undefined;
        var slen: usize = 0;
        const S = struct {
            fn app(b: []u8, l: *usize, s: []const u8) void {
                const n = @min(s.len, b.len - l.*);
                @memcpy(b[l.*..][0..n], s[0..n]);
                l.* += n;
            }
        };
        S.app(&sbuf, &slen, "[CRASH] signal ");
        var num: [32]u8 = undefined;
        const ns = std.fmt.bufPrint(&num, "{d} ({s}) at 0x{x}", .{ sig, sigName(sig), fault_addr }) catch "unknown";
        S.app(&sbuf, &slen, ns);
        S.app(&sbuf, &slen, " — full report in detailed.txt\n");
        log.writeRaw(log.simple_fd_raw, sbuf[0..slen]);
        log.writeRaw(std.posix.STDERR_FILENO, sbuf[0..slen]);
    }

    // Re-raise with the default disposition (SA_RESETHAND already
    // restored it).
    reRaise(sig);

    // Should not return; park forever as a last resort.
    while (true) std.atomic.spinLoopHint();
}

/// v31: the re-raise tail, shared by the normal path and the re-entry
/// guard. The kernel BLOCKS the signal while its handler runs, so
/// unblock it first — otherwise the re-raise stays pending forever and
/// the process hangs. Raw syscalls only (async-signal-safe).
fn reRaise(sig: i32) noreturn {
    // sigset bit (sig-1); SIG_UNBLOCK = 1 on Linux. Real signals are
    // 1..64 (the watched set); a pathological value parks instead of
    // panicking inside the crash path (the v30 lesson — the handler
    // must never fault on its own reporting).
    const sigu: u32 = @bitCast(sig);
    if (sigu == 0 or sigu > 64) {
        while (true) std.atomic.spinLoopHint();
    }
    var set: u64 = @as(u64, 1) << @as(u6, @intCast(sigu - 1));
    _ = std.os.linux.syscall4(
        .rt_sigprocmask,
        1, // SIG_UNBLOCK
        @intFromPtr(&set),
        0,
        @sizeOf(u64),
    );
    const pid = std.os.linux.syscall0(.getpid);
    _ = std.os.linux.syscall2(.kill, pid, @as(usize, @bitCast(@as(isize, sig))));
    while (true) std.atomic.spinLoopHint();
}

fn sigFaultAddress(info: *const std.posix.siginfo_t) usize {
    // si_addr: siginfo_t { signo, errno, code, fields union (8-aligned) }.
    // On Linux x86_64 and aarch64 the fault address sits at offset 16
    // (verified against the kernel uapi layout both arches use).
    const raw: [*]const u8 = @ptrCast(info);
    const off = 16;
    return std.mem.readInt(usize, raw[off..][0..@sizeOf(usize)], builtin.cpu.arch.endian());
}

/// Safe-ish read of one pointer-sized word during the crash walk.
/// v32: the address is validated against the /proc/self/maps range table
/// BEFORE dereferencing — an unmapped or garbage FP now ends the walk
/// cleanly instead of faulting inside the crash handler (the v31 device
/// run lost its whole report to exactly that).
fn readWord(addr: usize) ?usize {
    if (addr < 0x1000) return null;
    const aligned = addr & ~@as(usize, @sizeOf(usize) - 1);
    const last = aligned +% (@sizeOf(usize) - 1);
    if (last < aligned) return null; // address-space wrap: refuse
    if (!addrIsMapped(aligned) or !addrIsMapped(last)) return null;
    const p: *const usize = @ptrFromInt(aligned);
    return p.*;
}

// ---------------------------------------------------------------------------
// v32: /proc/self/maps snapshot + range table (read once, reused by both
// the validated frame walk and the maps excerpt printing)
// ---------------------------------------------------------------------------

var maps_buf: [64 * 1024]u8 = undefined;
var maps_len: usize = 0;
var maps_lines: usize = 0;
const MapRange = struct { start: usize, end: usize, exec: bool = false };
var map_ranges: [512]MapRange = undefined;
var map_range_count: usize = 0;
/// Read /proc/self/maps once and parse the range table (async-signal-safe:
/// open/read/close + fixed buffers only).
/// v32: LOOP the read — a single read() on /proc/self/maps returns only
/// ~4 KiB (one seq_file page), which truncated every previous report's
/// map list at ~42 lines: the main [stack] region (the LAST line) never
/// made it in, so even the v31 walk's own stack frames were invisible to
/// the validation table.
fn readMapsOnce() void {
    maps_len = 0;
    maps_lines = 0;
    map_range_count = 0;
    const fd = std.posix.open("/proc/self/maps", .{ .ACCMODE = .RDONLY }, 0) catch return;
    defer std.posix.close(fd);
    var total: usize = 0;
    while (total < maps_buf.len) {
        const n = std.posix.read(fd, maps_buf[total..]) catch break;
        if (n == 0) break; // EOF — the whole map list is in
        total += n;
    }
    maps_len = total;
    if (maps_len == 0) return;
    parseMapsSnapshot();
}

/// Parse maps_buf[0..maps_len] into the range table + line count.
/// Also records whether each mapping is executable ('x' perms).
fn parseMapsSnapshot() void {
    maps_lines = 0;
    map_range_count = 0;
    if (maps_len == 0) return;
    var it = std.mem.splitScalar(u8, maps_buf[0..maps_len], '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        maps_lines += 1;
        if (map_range_count >= map_ranges.len) return; // table full: walk stays conservative
        const dash = std.mem.indexOfScalar(u8, line, '-') orelse continue;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
        if (sp <= dash + 1) continue;
        const start = std.fmt.parseInt(usize, line[0..dash], 16) catch continue;
        const end = std.fmt.parseInt(usize, line[dash + 1 .. sp], 16) catch continue;
        if (end <= start) continue;
        // perms field: "r-xp"/"rw-p"... right after the range
        var exec = false;
        if (sp + 4 <= line.len) exec = line[sp + 3] == 'x'; // perms at sp+1: [r][w][x][p]
        map_ranges[map_range_count] = .{ .start = start, .end = end, .exec = exec };
        map_range_count += 1;
    }
}

/// Is `addr` inside any mapped range from the snapshot?
fn addrIsMapped(addr: usize) bool {
    return mapContaining(addr) != null;
}

fn mapContaining(addr: usize) ?MapRange {
    for (map_ranges[0..map_range_count]) |r| {
        if (addr >= r.start and addr < r.end) return r;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Register dumps (Linux ucontext layouts)
// ---------------------------------------------------------------------------

/// Linux x86_64: ucontext_t { flags(8), link(8), stack(24) } → mcontext at
/// 40; gregs[23] at mcontext+0. Indices: 0..7=R8..R15, 8=RDI, 9=RSI,
/// 10=RBP, 11=RBX, 12=RDX, 13=RAX, 14=RCX, 15=RSP, 16=RIP.
/// Linux aarch64: the same 40-byte prefix is followed by a 128-byte
/// signal mask (kernel sigset plus reserved bytes), then 8 bytes of
/// alignment padding. mcontext therefore starts at +176 in BOTH the
/// Linux uapi and glibc layouts. +40 is the x86_64 offset only.
/// Choosing the layout from executable mappings loses the real context
/// precisely when an indirect branch jumps to NULL or a wild address.
const AARCH64_MCONTEXT_OFFSET = 176;
const Aarch64Mcontext = extern struct {
    fault_address: u64,
    regs: [31]u64,
    sp: u64,
    pc: u64,
    pstate: u64,
};

fn aarch64Mcontext(ctx: *const anyopaque) *align(1) const Aarch64Mcontext {
    const raw: [*]const u8 = @ptrCast(ctx);
    return @ptrCast(raw + AARCH64_MCONTEXT_OFFSET);
}

/// Read one u64 at byte offset `off` from the ucontext (align-safe).
fn u64At(raw: [*]const u8, off: usize) u64 {
    var v: u64 = 0;
    var i: usize = 8;
    while (i > 0) {
        i -= 1;
        v = (v << 8) | raw[off + i];
    }
    return v;
}

/// Decode the architecture's ABI independently of the values saved in
/// the registers. In particular, a faulting PC need not be executable.
fn dumpRegisters(ctx: *anyopaque) void {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            const U = extern struct {
                flags: u64,
                link: u64,
                ss_sp: u64,
                ss_flags: i32,
                _pad: u32,
                ss_size: u64,
                gregs: [23]u64,
                fpregs: u64,
                reserved: [8]u64,
            };
            const uc: *const U = @ptrCast(@alignCast(ctx));
            const names = [_][]const u8{
                "R8",  "R9",  "R10",    "R11", "R12",    "R13",     "R14", "R15",
                "RDI", "RSI", "RBP",    "RBX", "RDX",    "RAX",     "RCX", "RSP",
                "RIP", "EFL", "CSGSFS", "ERR", "TRAPNO", "OLDMASK", "CR2",
            };
            put("!! registers (x86_64):\n");
            for (uc.gregs, 0..) |v, i| {
                if (i >= names.len) break;
                put("  ");
                put(names[i]);
                put("=");
                putHex(v);
                put("\n");
            }
        },
        .aarch64 => {
            const raw: [*]const u8 = @ptrCast(ctx);
            const mc = aarch64Mcontext(ctx);
            put("!! registers (aarch64, Linux ABI mcontext@+176):\n");
            put("  fault_address=");
            putHex(mc.fault_address);
            put("\n");
            var i: usize = 0;
            while (i < 31) : (i += 1) {
                put("  X");
                putDec(i);
                put("=");
                putHex(mc.regs[i]);
                if (i == 29) put("  (FP)");
                if (i == 30) put("  (LR)");
                put("\n");
            }
            const sp = mc.sp;
            const pc = mc.pc;
            put("  SP=");
            putHex(sp);
            put("\n  PC=");
            putHex(pc);
            put("\n  PSTATE=");
            putHex(mc.pstate);
            put("\n");
            if (!addrIsExec(pc)) {
                if (pc == fault_addr) {
                    put("  (PC == fault address: instruction fetch fault at the saved PC;\n");
                    put("   inspect LR for the caller of a NULL or wild indirect branch.)\n");
                } else {
                    put("  (saved PC is not in an executable mapping; inspect LR,\n");
                    put("   fault address, and si_code. This does not change the ABI.)\n");
                }
            }
            if (executable_elf_type == 2) { // ELF ET_EXEC
                put("  symbolization: main executable is ET_EXEC; pass its RAW\n");
                put("  addresses unchanged to addr2line -e omori-native -f -C.\n");
                put("  Library addresses need their matching ELF and load bias.\n");
            }
            // v34: SYMBOLIZATION HINTS — the v33 device report's PC/LR
            // read as garbage (PC=0x34, LR=0x10) while X29 carried a
            // plausible code address (later symbolized into
            // GameLoop.run). Rather than betting on one slot, EVERY
            // register-slot value that lands in an executable mapping
            // gets its containing mapping's offset. This is useful for
            // matching /proc/self/maps, but is NOT an ELF virtual address
            // or an addr2line argument (a mapping may start mid-image).
            {
                // X0..X30, then SP and PC.
                var hints: usize = 0;
                var k: usize = 0;
                while (k <= 32) : (k += 1) {
                    const v = if (k <= 30)
                        mc.regs[k]
                    else if (k == 31)
                        sp
                    else
                        pc;
                    const mapping = mapContaining(v) orelse continue;
                    if (!mapping.exec) continue;
                    put("  sym-hint ");
                    if (k <= 30) {
                        put("X");
                        putDec(k);
                    } else if (k == 31) {
                        put("SP");
                    } else {
                        put("PC");
                    }
                    put("=");
                    putHex(v);
                    put(" -> mapping-relative ");
                    putHex(v - mapping.start);
                    put(" (mapping starts ");
                    putHex(mapping.start);
                    put(")");
                    put("\n");
                    hints += 1;
                    if (hints >= 6) break;
                }
                if (hints == 0) {
                    put("  (no register slot carries a code address — a\n");
                    put("   wild jump to non-code memory, or the frame is\n");
                    put("   a re-raise; see si_code above.)\n");
                }
            }
            // Preserve the prefix and complete general-register context
            // for independent offline inspection (PC is at +440).
            put("  raw ucontext (+0..+512, 8 bytes/line):\n");
            var bi: usize = 0;
            while (bi < 512) : (bi += 8) {
                put("    +");
                putDec(bi);
                put(": ");
                putHex(u64At(raw, bi));
                put("\n");
            }
        },
        else => {
            put("!! registers: not implemented for this architecture\n");
        },
    }
}

fn framePointerOf(ctx: *anyopaque) usize {
    switch (builtin.cpu.arch) {
        .x86_64 => {
            const U = extern struct {
                flags: u64,
                link: u64,
                ss_sp: u64,
                ss_flags: i32,
                _pad: u32,
                ss_size: u64,
                gregs: [23]u64,
            };
            const uc: *const U = @ptrCast(@alignCast(ctx));
            return uc.gregs[10]; // RBP
        },
        .aarch64 => {
            return @intCast(aarch64Mcontext(ctx).regs[29]); // X29 = FP
        },
        else => return 0,
    }
}

/// v33: is `addr` inside an EXECUTABLE mapping from the snapshot?
fn addrIsExec(addr: usize) bool {
    const mapping = mapContaining(addr) orelse return false;
    return mapping.exec;
}

fn dumpMapsExcerpt() void {
    // v32: formats from the snapshot read by readMapsOnce() (no file I/O
    // here — the handler is deep in async-signal-safe territory).
    if (maps_len == 0) {
        put("  (could not read /proc/self/maps)\n");
        return;
    }
    var printed: usize = 0;
    var it = std.mem.splitScalar(u8, maps_buf[0..maps_len], '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.indexOfScalar(u8, line, '-')) |dash| {
            const sp = std.mem.indexOfScalar(u8, line, ' ') orelse line.len;
            const start = std.fmt.parseInt(usize, line[0..dash], 16) catch 0;
            const end = std.fmt.parseInt(usize, line[dash + 1 .. sp], 16) catch 0;
            // v31: wrapping add — a maps entry ending near maxInt(usize)
            // would overflow-panic the crash handler (the same
            // double-fault class as the si_code cast).
            const near = fault_addr >= (start -% 4096) and fault_addr < (end +% 4096);
            if (near or printed < 20) {
                put("  ");
                put(line);
                put("\n");
                if (!near) printed += 1;
            }
        }
    }
    put("  (maps lines in first 64K read: ");
    putDec(maps_lines);
    put(")\n");
}

fn sigName(sig: i32) []const u8 {
    return switch (sig) {
        4 => "SIGILL",
        6 => "SIGABRT",
        7 => "SIGBUS",
        8 => "SIGFPE",
        11 => "SIGSEGV",
        else => "SIG?",
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "put helpers format" {
    report_len = 0;
    put("a");
    putHex(0x1234);
    put(" ");
    putDec(4321);
    // putHex emits fixed 16-hex-digit width (register-style).
    try std.testing.expectEqualStrings("a0x0000000000001234 4321", report_buf[0..report_len]);
}

test "v31: putDecS handles negative si_code (SI_TKILL = -6) without panicking" {
    // The v30 double-fault: a userspace-raised signal aborts the crash
    // reporter itself. Signed print must survive i32::min too.
    report_len = 0;
    putDecS(-6);
    try std.testing.expectEqualStrings("-6", report_buf[0..report_len]);
    report_len = 0;
    putDecS(2);
    try std.testing.expectEqualStrings("2", report_buf[0..report_len]);
    report_len = 0;
    putDecS(std.math.minInt(i32));
    try std.testing.expectEqualStrings("-2147483648", report_buf[0..report_len]);
}

test "sigName mapping" {
    try std.testing.expectEqualStrings("SIGSEGV", sigName(11));
    try std.testing.expectEqualStrings("SIGABRT", sigName(6));
}

test "aarch64 Linux ucontext preserves NULL PC and caller registers" {
    // Independent offsets verified with offsetof(ucontext_t, ...) from
    // both the Linux uapi and glibc headers, and a real QEMU SIGSEGV.
    // The old executable-PC heuristic interpreted +40 as mcontext when
    // the actual +440 PC was NULL, fabricating register values.
    var raw: [512]u8 = @splat(0);
    std.mem.writeInt(u64, raw[304..312], 0x12345678, .little); // old +40 PC slot
    std.mem.writeInt(u64, raw[176..184], 0, .little); // fault_address
    std.mem.writeInt(u64, raw[184..192], 0xabc, .little); // X0
    std.mem.writeInt(u64, raw[416..424], 0x70001000, .little); // X29
    std.mem.writeInt(u64, raw[424..432], 0x10002000, .little); // X30/LR
    std.mem.writeInt(u64, raw[432..440], 0x70000000, .little); // SP
    std.mem.writeInt(u64, raw[440..448], 0, .little); // NULL branch target
    std.mem.writeInt(u64, raw[448..456], 0x60000000, .little); // PSTATE

    const mc = aarch64Mcontext(&raw);
    try std.testing.expectEqual(@as(u64, 0), mc.pc);
    try std.testing.expectEqual(@as(u64, 0), mc.fault_address);
    try std.testing.expectEqual(@as(u64, 0xabc), mc.regs[0]);
    try std.testing.expectEqual(@as(u64, 0x70001000), mc.regs[29]);
    try std.testing.expectEqual(@as(u64, 0x10002000), mc.regs[30]);
    try std.testing.expectEqual(@as(u64, 0x70000000), mc.sp);
    try std.testing.expectEqual(@as(u64, 0x60000000), mc.pstate);
    if (builtin.cpu.arch == .aarch64) {
        try std.testing.expectEqual(@as(usize, 0x70001000), framePointerOf(&raw));
    }
}

test "v32: maps range table gates readWord (the v31 silent-report death)" {
    // The v31 device run: the double-free's second fault walked the FP
    // chain onto a page the GPA had just unmapped; readWord dereferenced
    // it, the handler itself faulted, and the whole report was lost.
    // v32: readWord validates against the maps range table FIRST.
    map_range_count = 2;
    map_ranges[0] = .{ .start = 0x1000, .end = 0x2000 };
    map_ranges[1] = .{ .start = 0x500000, .end = 0x600000 };

    // unmapped, below the first page, and wrapping → all refused
    try std.testing.expect(readWord(0x0) == null);
    try std.testing.expect(readWord(0x800) == null);
    try std.testing.expect(readWord(0x3000) == null);
    try std.testing.expect(readWord(0x4fffff8) == null); // just below range #1
    try std.testing.expect(readWord(0x600000) == null); // one past the end

    // mapped (range #1 exists; nothing is actually allocated there in the
    // test process, so we only verify the GATE logic via addrIsMapped).
    try std.testing.expect(addrIsMapped(0x1000));
    try std.testing.expect(addrIsMapped(0x599999));
    try std.testing.expect(!addrIsMapped(0x2fff));

    // no table at all → refuse everything (frameless report, never a
    // silent death)
    map_range_count = 0;
    try std.testing.expect(readWord(0x1000) == null);
    try std.testing.expect(!addrIsMapped(0x1000));
}

test "v32: maps parser extracts ranges from a snapshot" {
    const snapshot = "0000000000001000-0000000000002000 r--p 00000000 00:00 0\n" ++
        "0000000000002000-0000000000003000 rw-p 00000000 00:00 0 \n" ++
        "000000000000500000-0000000000600000 r-xp 00000000 00:29 123 /usr/lib/x.so\n" ++
        "garbage line without dashes\n" ++
        "\n";
    @memcpy(maps_buf[0..snapshot.len], snapshot);
    maps_len = snapshot.len;
    maps_lines = 0;
    map_range_count = 0;
    parseMapsSnapshot();
    try std.testing.expectEqual(@as(usize, 3), map_range_count);
    try std.testing.expectEqual(@as(usize, 4), maps_lines);
    try std.testing.expectEqual(@as(usize, 0x1000), map_ranges[0].start);
    try std.testing.expectEqual(@as(usize, 0x2000), map_ranges[0].end);
    try std.testing.expectEqual(@as(usize, 0x500000), map_ranges[2].start);
    try std.testing.expectEqual(@as(usize, 0x600000), map_ranges[2].end);
    maps_len = 0;
    maps_lines = 0;
    map_range_count = 0;
}
