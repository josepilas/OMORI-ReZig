//! v32 audio regression harness — the exact path that crashed v31 on
//! the R36S (silent SIGSEGV / exit 139 right after
//! "read 'audio/bgm/user_title.ogg'").
//!
//! The v31 bug (root-caused here): `Mixer.loadFileBytes` freed the
//! resolve() result (`defer self.alloc.free(path)`) AND freed it again
//! through the resolver cache map's deinit — a double free the v30 arena
//! masked, and which the v31 GPA turned into a SIGSEGV (the second free's
//! `Allocator.free` poison-memset hit a page the GPA had just unmapped).
//! Fixed in v32: the resolver map owns the path; this harness proves the
//! full audio lifecycle survives on the GPA allocator.
//!
//! Usage:
//!   zig build repro -Doptimize=ReleaseSafe
//!   SDL_AUDIODRIVER=dummy SDL_VIDEODRIVER=dummy \
//!     OMORI_LOG_DIR=/tmp/repro-logs \
//!     ./zig-out/bin/omori-repro <data-root> [seconds] [--crash]
//!
//! <data-root> needs: data/System.json (sounds array), audio/bgm/*.ogg,
//! audio/se/*.ogg — see scripts/make_fixture_tree.sh (dev box).
//! `--crash` deliberately SIGSEGVs while the BGM is playing: the
//! crash-reporter self-test under real audio load (SA_ONSTACK + the
//! maps-validated backtrace).

const std = @import("std");
const log = @import("src/core/log.zig");
const crash = @import("src/core/crash.zig");
const sdl = @import("src/platform/sdl2.zig");
const vfs_mod = @import("src/filesystem/vfs.zig");
const mixer_mod = @import("src/audio/mixer.zig");

pub fn main() !void {
    // EXACTLY the v32 main.zig allocator topology: the thread-safe GPA
    // services the mixer; the arena (GPA-backed) services the VFS.
    var gpa_state = std.heap.GeneralPurposeAllocator(.{ .thread_safe = true }){};
    defer _ = gpa_state.deinit();
    const mixer_alloc = gpa_state.allocator();
    var arena_state = std.heap.ArenaAllocator.init(gpa_state.allocator());
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    log.earlyInit(alloc);
    crash.install();
    log.milestone("repro: v32 audio regression harness starting", .{});

    const args = try std.process.argsAlloc(alloc);
    defer std.process.argsFree(alloc, args);
    const data_root = if (args.len > 1) args[1] else "/home/z/my-project/fixture";
    const run_secs: u64 = if (args.len > 2) (std.fmt.parseInt(u64, args[2], 10) catch 8) else 8;
    const crash_test = args.len > 3 and std.mem.eql(u8, args[3], "--crash");

    const save_root = try std.fmt.allocPrint(alloc, "{s}/save", .{data_root});
    defer alloc.free(save_root);
    var vfs = vfs_mod.Vfs.init(alloc, data_root, save_root);
    defer vfs.deinit();

    var lib = sdl.Sdl2.load(alloc) orelse return error.NoSDL2;
    _ = lib.Init(0);

    var m = mixer_mod.Mixer.init(mixer_alloc, &lib, &vfs);
    m.start();
    mixer_mod.instance = if (m.enabled) &m else null;
    log.milestone("repro: mixer armed (enabled={})", .{m.enabled});

    // BGM — the exact v31 crash window: VFS read (logged) →
    // stb_vorbis_open_memory → get_info → mixer thread streams + loops.
    m.playBgm("user_title", 100, 100);
    log.milestone("repro: playBgm returned", .{});

    if (crash_test) {
        std.Thread.sleep(200 * std.time.ns_per_ms); // let some chunks mix
        log.milestone("repro: deliberate SIGSEGV NOW (handler self-test under audio load)", .{});
        const p_null: *volatile u8 = @ptrFromInt(0x1);
        p_null.* = 1;
    }

    // Stream for a while; SEs layer on top (the $dataSystem identity path).
    var i: u64 = 0;
    while (i < run_secs) : (i += 1) {
        std.Thread.sleep(1 * std.time.ns_per_s);
        m.playSe("cursor", 100);
        m.playSe("decision", 100);
    }

    // Same-track volume/pitch adjust (the in-place path).
    m.playBgm("user_title", 50, 90);

    // Fade-out (freeBgm from the mixer thread — the v31 split-allocator
    // free path: VFS-owned bytes via the VFS allocator).
    m.stopBgm(200);
    std.Thread.sleep(1 * std.time.ns_per_s);

    log.milestone("repro: harness complete — no crash", .{});
    log.flush();
}
