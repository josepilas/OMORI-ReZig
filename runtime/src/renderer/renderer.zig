//! Native renderer bootstrap (SDL2 / OpenGL-ES-adjacent path).
//!
//! v29 — THE PRESENT FIX. The v28 device run proved everything up to the
//! window works (detailed.txt 20:12:33: SDL_Init OK, kmsdrm window
//! 640x480, controller opened, game loop started) and then NOTHING: a
//! white screen, dead input, Start+Select ignored, hard power-off.
//!
//! v28 root cause #1 — THE WINDOW FLAGS BUG: the window was created with
//! 0x00000004 (SDL_WINDOW_SHOWN) while the comment claimed
//! SDL_WINDOW_OPENGL (0x2). Without the OpenGL flag no GL/EGL surface is
//! attached to the KMSDRM window, so the GLES2 accelerated render driver
//! refuses to match ("Couldn't find matching render driver") and SDL falls
//! back to the SOFTWARE renderer, whose KMSDRM present path can stall on
//! the RK3326's 4.4 kernel. v29 creates the window WITH SDL_WINDOW_OPENGL
//! (0x2) first — the GLES2 driver then attaches and presents through
//! eglSwapBuffers (non-blocking, GPU-scaled). A non-GL window is kept as
//! an explicit retry for systems without EGL.
//!
//! v29 hardening — nothing may hang the player on the device again:
//!   * PRESENT WATCHDOG: a background thread monitors a frame heartbeat;
//!     a stall > 10 s logs the ring buffer, flushes both log files and
//!     exits(2) — the launcher shows the outcome instead of a frozen
//!     screen the user can only escape by powering off.
//!   * SIGTERM/SIGINT handlers: PortMaster's stop scripts get a clean
//!     flush-and-exit instead of an unresponsive process.
//!   * Every SDL texture/render error is LOGGED (v28 continued silently).
//!   * SDL_GetVersion + SDL_GetRendererInfo + controller names are logged
//!     so one device run answers "which SDL2? which renderer?".
//!   * LRU-free texture cache keyed on stable surface pixel pointers:
//!     the 6 MiB title sheet uploads once, not per frame.

const std = @import("std");
const sdl = @import("../platform/sdl2.zig");
const log = @import("../core/log.zig");
const input_mod = @import("../input/input.zig");
const FrameClock = @import("../core/frame_clock.zig").FrameClock;

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// The shipped OMORI configuration uses a 640x480 logical canvas.
pub const GAME_WIDTH: c_int = @import("../core/canvas.zig").WIDTH;
pub const GAME_HEIGHT: c_int = @import("../core/canvas.zig").HEIGHT;

pub const Mode = enum {
    /// Real window through dlopen'd SDL2.
    windowed,
    /// No display available — validation mode (--headless / OMORI_HEADLESS).
    headless,
    /// SDL2/display failure in a NORMAL run — fatal (exit 3), never a
    /// silent fallback. The user sees a loud error and the logs carry
    /// every dlopen attempt + SDL_GetError string.
    failed,
};

/// Which video drivers to try, in order (after the inherited env).
const driver_retry_chain = [_][]const u8{ "kmsdrm", "x11", "wayland", "auto" };

// ---------------------------------------------------------------------------
// v29 texture cache (draw.zig renders through it; see draw.zig render())
// ---------------------------------------------------------------------------

/// Entries keyed by the surface's pixel base pointer. Stable pixel stores
/// (scene-owned sheets, cached label runs) hit; per-frame allocations
/// simply miss and create per-frame as in v28. The GameLoop flushes the
/// cache on every state transition so a recycled heap address can never
/// alias a stale entry.
pub const TexCache = struct {
    pub const SLOTS = 24;

    const Entry = struct {
        key: ?*const anyopaque = null,
        w: u32 = 0,
        h: u32 = 0,
        tex: ?*anyopaque = null,
        hits: u64 = 0,
    };

    entries: [SLOTS]Entry = @splat(.{}),
    next: usize = 0,
    lookups: u64 = 0,
    hits: u64 = 0,
    uploads: u64 = 0,

    pub fn get(self: *TexCache, lib: *sdl.Sdl2, renderer: *anyopaque, key: *const anyopaque, w: u32, h: u32) ?*anyopaque {
        _ = lib;
        _ = renderer;
        self.lookups += 1;
        for (&self.entries) |*e| {
            if (e.key == key and e.w == w and e.h == h) {
                if (e.tex) |t| {
                    self.hits += 1;
                    e.hits += 1;
                    return t;
                }
            }
        }
        return null;
    }

    /// Create + upload + store a cache slot (cache MISS path). Returns
    /// the texture (owned by the cache) or null on failure.
    pub fn put(self: *TexCache, lib: *sdl.Sdl2, renderer: *anyopaque, key: *const anyopaque, w: u32, h: u32, pixels: []const u8) ?*anyopaque {
        self.uploads += 1;
        const tex = lib.CreateTexture(renderer, sdl.PIXELFORMAT_ABGR8888, sdl.TEXTUREACCESS_STREAMING, @intCast(w), @intCast(h));
        if (tex == null) {
            textureFailure("SDL_CreateTexture (cache)");
            return null;
        }
        _ = lib.SetTextureBlendMode(tex, sdl.BLENDMODE_BLEND);
        if (lib.UpdateTexture(tex, null, pixels.ptr, @intCast(w * 4)) != 0) {
            log.warn("renderer: texture cache upload failed ({d}x{d}): {s}", .{ w, h, std.mem.span(lib.GetError()) });
            lib.DestroyTexture(tex);
            return null;
        }
        // evict: first empty slot, else least-hit entry
        var slot: usize = 0;
        var best: i64 = -1;
        for (&self.entries, 0..) |*e, i| {
            if (e.key == null) {
                slot = i;
                best = -2; // sentinel: empty slot wins
                break;
            }
            if (best == -1 or @as(i64, @intCast(e.hits)) < best) {
                best = @intCast(e.hits);
                slot = i;
            }
        }
        if (self.entries[slot].tex) |old| lib.DestroyTexture(old);
        self.entries[slot] = .{ .key = key, .w = w, .h = h, .tex = tex, .hits = 1 };
        self.next = (slot + 1) % SLOTS;
        return tex;
    }

    /// Release scene-owned textures using the caller's live SDL table.
    /// Renderer.init returns by value: retaining &self.sdl inside a cache
    /// kept a pointer into the init stack frame after the Renderer moved.
    /// The explicit argument keeps function dispatch valid across moves.
    /// OMORI_FLUSH_DESTROY=0 retains the old leak policy for diagnosis.
    pub fn flush(self: *TexCache, lib: *sdl.Sdl2, destroy: bool, reason: []const u8) usize {
        var handled: usize = 0;
        for (&self.entries, 0..) |*e, slot| {
            if (e.tex) |t| {
                const key_addr: usize = if (e.key) |k| @intFromPtr(k) else 0;
                if (destroy) {
                    log.event(.gpu, .note, "  FLUSH-DESTROY [{s}] slot {d}: tex=0x{x} key=0x{x} {d}x{d} hits={d}", .{ reason, slot, @intFromPtr(t), key_addr, e.w, e.h, e.hits });
                    lib.DestroyTexture(t);
                } else {
                    log.event(.gpu, .note, "  FLUSH-DROP   [{s}] slot {d}: tex=0x{x} key=0x{x} {d}x{d} hits={d} (diagnostic leak — OMORI_FLUSH_DESTROY=0)", .{ reason, slot, @intFromPtr(t), key_addr, e.w, e.h, e.hits });
                }
                handled += 1;
            }
            e.* = .{};
        }
        self.next = 0;
        return handled;
    }

    pub fn stats(self: *const TexCache) struct { lookups: u64, hits: u64, uploads: u64 } {
        return .{ .lookups = self.lookups, .hits = self.hits, .uploads = self.uploads };
    }
};

var texture_fail_logged: bool = false;
fn textureFailure(what: []const u8) void {
    if (texture_fail_logged) return;
    texture_fail_logged = true;
    log.warn("renderer: texture op FAILED ('{s}') — SDL error: check detailed.txt GetError above; subsequent failures silent", .{what});
}

// ---------------------------------------------------------------------------
// v34: content-addressed TEXT texture cache
// ---------------------------------------------------------------------------

/// Content-addressed text uploads, reused across frames and transitions.
/// The cache owns at most SLOTS textures and destroys replaced entries.
/// It retains no pointers into the enclosing Renderer, which may move.
pub const TextTexCache = struct {
    pub const SLOTS = 32;

    pub const Entry = struct {
        hash: u64 = 0,
        w: u32 = 0,
        h: u32 = 0,
        tex: ?*anyopaque = null,
        hits: u64 = 0,
        last_use: u64 = 0,
    };

    entries: [SLOTS]Entry = @splat(.{}),
    lookups: u64 = 0,
    hits: u64 = 0,
    uploads: u64 = 0,
    evictions: u64 = 0,
    clock: u64 = 0,
    /// v34: TEXT-DIAG-2 one-shot diagnostics (first N text draws log the
    /// full SDL-side state — query/blend/mod/dst — so one device run
    /// localizes any remaining invisibility to the exact call).
    diag_logged: u32 = 0,

    /// FNV-1a over the (tinted) pixel bytes + dims + tint.
    pub fn keyOf(pixels: []const u8, w: u32, h: u32, r: u8, g: u8, b: u8) u64 {
        var hash: u64 = 0xcbf29ce484222325;
        const seed = [_]u8{ @truncate(w), @truncate(w >> 8), @truncate(h), @truncate(h >> 8), r, g, b, 0 };
        for (seed) |c| {
            hash ^= c;
            hash *%= 0x100000001b3;
        }
        for (pixels) |c| {
            hash ^= c;
            hash *%= 0x100000001b3;
        }
        return hash;
    }

    pub fn get(self: *TextTexCache, key: u64) ?*anyopaque {
        self.lookups += 1;
        self.clock += 1;
        for (&self.entries) |*e| {
            if (e.hash == key) {
                if (e.tex) |t| {
                    self.hits += 1;
                    e.hits += 1;
                    e.last_use = self.clock;
                    return t;
                }
            }
        }
        return null;
    }

    /// Create + upload + store (MISS path). Returns the texture (owned
    /// by the cache) or null on failure.
    pub fn put(self: *TextTexCache, lib: *sdl.Sdl2, renderer: *anyopaque, key: u64, w: u32, h: u32, tinted_pixels: []const u8) ?*anyopaque {
        self.uploads += 1;
        const tex = lib.CreateTexture(renderer, sdl.PIXELFORMAT_ABGR8888, sdl.TEXTUREACCESS_STREAMING, @intCast(w), @intCast(h));
        if (tex == null) {
            textureFailure("SDL_CreateTexture (text cache)");
            return null;
        }
        _ = lib.SetTextureBlendMode(tex, sdl.BLENDMODE_BLEND);
        // v34: belt and braces — explicit identity mods (default per SDL
        // spec, but a stale mod from a recycled texture slot must never
        // blank the text).
        _ = lib.SetTextureColorMod(tex, 255, 255, 255);
        _ = lib.SetTextureAlphaMod(tex, 255);
        if (lib.UpdateTexture(tex, null, tinted_pixels.ptr, @intCast(w * 4)) != 0) {
            log.warn("renderer: text texture upload failed ({d}x{d}): {s}", .{ w, h, std.mem.span(lib.GetError()) });
            lib.DestroyTexture(tex);
            return null;
        }
        // Evict the least-recently-used upload once all slots are full.
        var slot: usize = 0;
        var best: u64 = std.math.maxInt(u64);
        for (&self.entries, 0..) |*e, i| {
            if (e.tex == null) {
                slot = i;
                break;
            }
            if (e.last_use < best) {
                best = e.last_use;
                slot = i;
            }
        }
        if (self.entries[slot].tex) |old| {
            self.evictions += 1;
            lib.DestroyTexture(old);
        }
        self.entries[slot] = .{ .hash = key, .w = w, .h = h, .tex = tex, .hits = 1, .last_use = self.clock };
        return tex;
    }

    pub fn flush(self: *TextTexCache, lib: *sdl.Sdl2) void {
        for (&self.entries) |*entry| {
            if (entry.tex) |tex| lib.DestroyTexture(tex);
            entry.* = .{};
        }
    }

    pub fn stats(self: *const TextTexCache) struct { lookups: u64, hits: u64, uploads: u64 } {
        return .{ .lookups = self.lookups, .hits = self.hits, .uploads = self.uploads };
    }
};

/// Destroy textures normally. The explicit =0 diagnostic override leaks
/// transition uploads and should only be used to compare device runs.
var flush_destroy_cache: ?bool = null;
pub fn flushDestroyEnabled() bool {
    if (flush_destroy_cache) |v| return v;
    const v = if (std.posix.getenv("OMORI_FLUSH_DESTROY")) |s|
        (s.len > 0 and s[0] != '0')
    else
        true;
    flush_destroy_cache = v;
    return v;
}

// ---------------------------------------------------------------------------
// v29 present watchdog
// ---------------------------------------------------------------------------

/// Frame heartbeat + watchdog thread. The watchdog exits the process when
/// the render loop stalls — the v28 failure mode (KMSDRM software present
/// blocking forever) must never require a hard power-off again.
const watchdog = struct {
    var heartbeat: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);
    var running: std.atomic.Value(bool) = std.atomic.Value(bool).init(false);
    var thread: ?std.Thread = null;

    fn beat() void {
        _ = heartbeat.fetchAdd(1, .monotonic);
    }

    fn start() void {
        if (running.load(.acquire)) return;
        running.store(true, .release);
        thread = std.Thread.spawn(.{}, loop, .{}) catch |e| {
            log.warn("renderer: watchdog thread failed to start ({any}) — no stall protection", .{e});
            running.store(false, .release);
            return;
        };
    }

    fn loop() void {
        // 15 s initial grace: boot-time PNG decode / font load before the
        // first presented frame is legitimate work.
        var last = heartbeat.load(.acquire);
        var since_change_ms: u64 = 0;
        var armed = false;
        while (running.load(.acquire)) {
            std.Thread.sleep(200 * std.time.ns_per_ms);
            const cur = heartbeat.load(.acquire);
            if (cur != last) {
                last = cur;
                since_change_ms = 0;
                armed = true;
                continue;
            }
            since_change_ms += 200;
            if (!armed) {
                // still in the boot grace window
                if (since_change_ms > 15_000) {
                    log.err("renderer: WATCHDOG — no frame presented within 15 s of renderer start (boot stall); exiting for diagnosis", .{});
                    log.flush();
                    std.process.exit(2);
                }
                continue;
            }
            if (since_change_ms > 10_000) {
                log.err("renderer: WATCHDOG — frame pipeline stalled > 10 s (last beat {d}); this is the v28 white-screen class of failure; exiting for diagnosis", .{last});
                log.flush();
                std.process.exit(2);
            }
        }
    }
};

/// v29: SIGTERM/SIGINT → clean exit (PortMaster stop scripts).
/// Async-signal-safe: raw write(2) to stderr + _exit. Log files are
/// already complete because v29 flushes EVERY event immediately.
var term_installed: bool = false;
fn onTerm(_: c_int) callconv(.c) void {
    const msg = "[OMORI] SIGTERM/SIGINT received — exiting (logs already flushed)\n";
    _ = std.posix.write(2, msg) catch {};
    std.posix.exit(0);
}
extern "c" fn signal(signum: c_int, handler: ?*const fn (c_int) callconv(.c) void) ?*const fn (c_int) callconv(.c) void;

fn installTermHandlers() void {
    if (term_installed) return;
    term_installed = true;
    _ = signal(15, onTerm); // SIGTERM
    _ = signal(2, onTerm); // SIGINT
}

/// v30: feed the present watchdog from outside the render loop (the
/// input self-test never presents frames but legitimately sleeps).
pub fn feedWatchdogBeat() void {
    watchdog.beat();
}

pub const Renderer = struct {
    allocator: std.mem.Allocator,
    mode: Mode,
    sdl: ?sdl.Sdl2,
    window: ?*anyopaque = null,
    renderer: ?*anyopaque = null,
    /// Up to 4 controllers (R36S pad + any extra).
    controllers: [4]?*anyopaque = .{ null, null, null, null },
    joysticks: [4]?*anyopaque = @splat(null),
    input_instances: [4]i32 = @splat(-1),
    controller_mapped: [4]bool = @splat(false),
    controller_swaps: [4]bool = @splat(false),
    raw_go_super: [4]bool = @splat(false),
    /// Frame pacing (60 Hz target; vsync usually paces already).
    frame_clock: FrameClock = .{},
    /// Diagnostic chord counter. START+SELECT exits on the first overlap.
    quit_combo_frames: u32 = 0,
    /// At least one raw device handle is open. Per-slot controller_mapped
    /// decides event ownership; GO-Super raw Select/Start remain enabled.
    have_joy: bool = false,
    /// v31: one-shot log for the arbitration decision (first pump).
    arbitration_logged: bool = false,
    /// Actual window pixel size (for diagnostics).
    window_w: i32 = 0,
    window_h: i32 = 0,
    /// v29 texture cache + present timing.
    cache: TexCache = .{},
    /// v34: content-addressed text texture cache (the invisible-text fix).
    text_cache: TextTexCache = .{},
    frames_presented: u64 = 0,
    present_ms_total: u64 = 0,
    present_ms_max: u32 = 0,
    /// v29 event diagnostics: log the first events raw (proof of life).
    events_seen: u64 = 0,
    events_logged: u64 = 0,
    /// v34: GO-Super A/B swap — physical A (SDL 'B') → confirm, physical
    /// B (SDL 'A') → cancel. Detected from the controller NAME (any
    /// opened controller matching "GO-Super"); OMORI_SWAP_AB=0/1 is the
    /// manual override. See input.swapAbButton.
    swap_ab: bool = false,
    swap_ab_logged: bool = false,

    pub fn init(alloc: std.mem.Allocator, headless_forced: bool) Renderer {
        var self = Renderer{
            .allocator = alloc,
            .mode = .headless,
            .sdl = null,
        };
        if (headless_forced) {
            log.milestone("renderer: headless (forced by --headless)", .{});
            return self;
        }

        installTermHandlers();

        const lib = sdl.Sdl2.load(alloc) orelse {
            // v28 honesty: a normal run without SDL2 is fatal, not headless.
            log.err("renderer: FATAL — SDL2 could not be loaded on a normal (windowed) run", .{});
            log.err("  tried: $OMORI_SDL2, soname, system paths, port-local omori/libs (see dlopen trail above)", .{});
            self.mode = .failed;
            return self;
        };
        self.sdl = lib;

        // v29: log the ACTUAL SDL2 runtime version (which lib loaded).
        var ver: sdl.Version = undefined;
        lib.GetVersion(&ver);
        log.milestone("renderer: SDL2 runtime version {d}.{d}.{d}", .{ ver.major, ver.minor, ver.patch });

        // --- init + video-driver retry chain ---------------------------
        // v30: the joystick/gamecontroller subsystems init SEPARATELY —
        // the v29 combined SDL_Init made a missing udev/pad (qemu, or a
        // pad-less system) fail the VIDEO path too ("Could not
        // initialize UDEV" on every retry). Video must never depend on
        // input hardware; a pad-less run logs a warning and continues.
        const init_flags = sdl.INIT_VIDEO | sdl.INIT_EVENTS | sdl.INIT_TIMER;
        var inited = false;
        var attempt: usize = 0;
        while (attempt <= driver_retry_chain.len) : (attempt += 1) {
            if (attempt > 0) {
                const driver = driver_retry_chain[attempt - 1];
                const driver_z = std.fmt.allocPrintSentinel(alloc, "{s}", .{driver}, 0) catch break;
                defer alloc.free(driver_z);
                if (setenv("SDL_VIDEODRIVER", driver_z.ptr, 1) != 0) break;
                log.warn("renderer: retrying SDL_Init with SDL_VIDEODRIVER={s}", .{driver});
            }
            lib.ClearError();
            if (lib.Init(init_flags) == 0) {
                inited = true;
                const env_driver = std.posix.getenv("SDL_VIDEODRIVER") orelse "(auto)";
                log.milestone("renderer: SDL_Init OK (SDL_VIDEODRIVER={s})", .{env_driver});
                break;
            }
            log.warn("renderer: SDL_Init failed: {s}", .{std.mem.span(lib.GetError())});
            lib.Quit(); // fully reset SDL between driver attempts
        }
        if (!inited) {
            _ = unsetenv("SDL_VIDEODRIVER");
            log.err("renderer: FATAL — SDL_Init failed across the whole driver retry chain ({d} attempts)", .{attempt});
            self.sdl = null;
            self.mode = .failed;
            return self;
        }

        // Pad subsystem: non-fatal by design (v30). On the R36S this
        // succeeds; under qemu (no udev) it warns and the window lives.
        if (lib.InitSubSystem(sdl.INIT_JOYSTICK | sdl.INIT_GAMECONTROLLER) == 0) {
            log.event(.gpu, .note, "renderer: joystick + gamecontroller subsystems initialized", .{});
        } else {
            log.warn("renderer: joystick/gamecontroller subsystem unavailable ({s}) — pad input disabled; keyboard + pushed events continue", .{std.mem.span(lib.GetError())});
        }

        // --- window (v29: OPENGL flag first — THE v28 bug) --------------
        // Attempt 1: SDL_WINDOW_OPENGL | FULLSCREEN_DESKTOP — the GL/EGL
        // surface lets the GLES2 accelerated renderer attach and present
        // through eglSwapBuffers (the KMSDRM software-present stall of the
        // v28 device run becomes unreachable).
        self.window = lib.CreateWindow(
            "OMORI",
            sdl.WINDOWPOS_CENTERED,
            sdl.WINDOWPOS_CENTERED,
            640,
            480,
            sdl.WINDOW_OPENGL | sdl.WINDOW_FULLSCREEN_DESKTOP,
        );
        if (self.window != null) {
            log.milestone("renderer: window created WITH SDL_WINDOW_OPENGL (GLES2 render driver can attach)", .{});
        } else {
            log.warn("renderer: GL window failed: {s} — retrying without the OpenGL flag (software renderer path)", .{std.mem.span(lib.GetError())});
            self.window = lib.CreateWindow(
                "OMORI",
                sdl.WINDOWPOS_CENTERED,
                sdl.WINDOWPOS_CENTERED,
                640,
                480,
                sdl.WINDOW_SHOWN | sdl.WINDOW_FULLSCREEN_DESKTOP,
            );
            if (self.window != null) {
                log.warn("renderer: window created WITHOUT OpenGL — software renderer expected; the present watchdog is armed", .{});
            }
        }
        if (self.window == null) {
            log.err("renderer: FATAL — window creation failed: {s}", .{std.mem.span(lib.GetError())});
            lib.Quit();
            self.sdl = null;
            self.mode = .failed;
            return self;
        }
        lib.GetWindowSize(self.window, &self.window_w, &self.window_h);
        log.milestone("renderer: window {d}x{d} (fullscreen desktop)", .{ self.window_w, self.window_h });

        // --- renderer (accelerated+vsync → software) --------------------
        self.renderer = lib.CreateRenderer(self.window, -1, sdl.ACCELERATED | sdl.PRESENTVSYNC);
        if (self.renderer == null) {
            log.warn("renderer: accelerated renderer unavailable: {s} — software fallback", .{std.mem.span(lib.GetError())});
            self.renderer = lib.CreateRenderer(self.window, -1, 0);
        }
        if (self.renderer == null) {
            log.err("renderer: FATAL — no SDL renderer: {s}", .{std.mem.span(lib.GetError())});
            lib.DestroyWindow(self.window);
            lib.Quit();
            self.sdl = null;
            self.window = null;
            self.mode = .failed;
            return self;
        }
        // v29: prove WHICH renderer we got (name + flags) — the single
        // most important v28 unknown. software=1, accelerated=2, vsync=16.
        var info: sdl.RendererInfo = undefined;
        if (lib.GetRendererInfo(self.renderer, &info) == 0) {
            const nm: []const u8 = if (info.name) |n| std.mem.span(n) else "(unknown)";
            const acc = (info.flags & sdl.ACCELERATED) != 0;
            const vs = (info.flags & sdl.PRESENTVSYNC) != 0;
            log.milestone("renderer: active render driver '{s}' (accelerated={s}, vsync={s}, max texture {d}x{d})", .{
                nm, if (acc) "yes" else "NO — software", if (vs) "yes" else "no", info.max_texture_width, info.max_texture_height,
            });
            if (!acc) {
                log.warn("renderer: SOFTWARE renderer active — KMSDRM software present can stall on old kernels; watchdog will exit(2) after 10 s if it does", .{});
            }
        }
        _ = lib.SetRenderDrawBlendMode(self.renderer, sdl.BLENDMODE_BLEND);
        _ = lib.RenderSetLogicalSize(self.renderer, GAME_WIDTH, GAME_HEIGHT);

        // Open the raw device even without an SDL game-controller
        // mapping: SDL only delivers that fallback's input while open.
        const n = lib.NumJoysticks();
        var i: c_int = 0;
        while (i < n) : (i += 1) self.openInputDevice(i);
        var opened: usize = 0;
        for (self.controllers) |controller| {
            if (controller != null) opened += 1;
        }

        self.frame_clock.completed(lib.GetTicks());
        self.mode = .windowed;
        log.milestone("renderer: SDL2 window ready, logical {d}x{d}, {d} controller(s)", .{ GAME_WIDTH, GAME_HEIGHT, opened });

        // v29: arm the present watchdog LAST — from here on, a windowed
        // run must either present frames or exit with evidence.
        watchdog.start();
        return self;
    }

    fn openInputDevice(self: *Renderer, index: c_int) void {
        const lib = self.sdl orelse return;
        const joy = lib.JoystickOpen(index) orelse {
            log.warn("input: joystick {d} could not open: {s}", .{ index, std.mem.span(lib.GetError()) });
            return;
        };
        const id = lib.JoystickInstanceID(joy);
        for (self.input_instances) |existing| {
            if (existing == id and id >= 0) {
                lib.JoystickClose(joy);
                return;
            }
        }
        var slot: usize = 0;
        while (slot < self.joysticks.len and self.joysticks[slot] != null) : (slot += 1) {}
        if (slot == self.joysticks.len or id < 0) {
            lib.JoystickClose(joy);
            return;
        }
        const name = if (lib.JoystickNameForIndex(index)) |value| std.mem.span(value) else "unknown";
        self.joysticks[slot] = joy;
        self.input_instances[slot] = id;
        self.raw_go_super[slot] = input_mod.nameRequestsAbSwap(name);
        self.have_joy = true;
        self.arbitration_logged = false;
        if (lib.IsGameController(index) == 1) self.controllers[slot] = lib.GameControllerOpen(index);
        self.controller_mapped[slot] = self.controllers[slot] != null;
        self.controller_swaps[slot] = if (std.posix.getenv("OMORI_SWAP_AB")) |value| value.len > 0 and value[0] != '0' else input_mod.nameRequestsAbSwap(name);
        if (slot == 0) self.swap_ab = self.controller_swaps[slot];
        log.event(.sys, .note, "input device slot{d} instance{d}: '{s}', mapped={any}, raw-profile={s}, swapAB={any}, buttons={d} axes={d} hats={d}", .{ slot, id, name, self.controller_mapped[slot], if (self.raw_go_super[slot]) "GO-Super (dpad8-11/select12/start13)" else "standard (select8/start9)", self.controller_swaps[slot], lib.JoystickNumButtons(joy), lib.JoystickNumAxes(joy), lib.JoystickNumHats(joy) });
    }

    fn inputSlot(self: *const Renderer, instance: i32) ?usize {
        var any = false;
        for (self.input_instances, 0..) |id, slot| {
            if (id >= 0) any = true;
            if (id == instance and id >= 0) return slot;
        }
        // SDL_PushEvent self-tests without attached hardware use id0.
        return if (!any and instance == 0) 0 else null;
    }

    pub fn removeInputDevice(self: *Renderer, instance: i32, input: *input_mod.Input) void {
        for (self.input_instances, 0..) |id, slot| {
            if (id != instance or id < 0) continue;
            if (self.sdl) |lib| {
                if (self.controllers[slot]) |controller| lib.GameControllerClose(controller);
                if (self.joysticks[slot]) |joy| lib.JoystickClose(joy);
            }
            self.controllers[slot] = null;
            self.joysticks[slot] = null;
            self.controller_mapped[slot] = false;
            self.controller_swaps[slot] = false;
            self.raw_go_super[slot] = false;
            self.input_instances[slot] = -1;
            input.clearDevice(slot);
            self.quit_combo_frames = 0;
            self.arbitration_logged = false;
            log.event(.sys, .note, "input device instance{d} removed; held buttons cleared", .{instance});
        }
        self.have_joy = false;
        for (self.joysticks) |joy| {
            self.have_joy = self.have_joy or joy != null;
        }
    }

    fn controllerOpen(self: *const Renderer) bool {
        for (self.controller_mapped) |mapped| {
            if (mapped) return true;
        }
        return false;
    }

    fn mappedButton(self: *const Renderer, slot: usize, button: u8) u8 {
        // No physical metadata means a synthetic self-test uses the
        // existing global override; real pads use their own name/layout.
        const swap = if (self.input_instances[slot] < 0) self.swap_ab else self.controller_swaps[slot];
        return if (swap) input_mod.swapAbButton(button) else button;
    }

    /// A standard PortMaster chord is a press, not a frame-count hold.
    /// Evaluate during queue dispatch too: down/down/up/up can all have
    /// arrived since the previous slow frame and must still exit.
    pub fn quitChordPressed(self: *Renderer, input: *const input_mod.Input) bool {
        if (input.isPressed(.menu) and input.isPressed(.debug_3)) {
            self.quit_combo_frames += 1;
            log.event(.sys, .note, "START+SELECT pressed — exiting", .{});
            return true;
        }
        self.quit_combo_frames = 0;
        return false;
    }

    fn pollInputButtons(self: *Renderer, input: *input_mod.Input) void {
        const lib = self.sdl orelse return;
        for (self.controllers, 0..) |controller, slot| {
            const gc = controller orelse continue;
            for (0..15) |button| {
                const b: u8 = @intCast(button);
                input.applyControllerButtonFor(slot, self.mappedButton(slot, b), lib.GameControllerGetButton(gc, @intCast(button)) != 0);
            }
        }
        for (self.joysticks, 0..) |joystick, slot| {
            const joy = joystick orelse continue;
            const count: usize = @intCast(@min(@max(lib.JoystickNumButtons(joy), 0), 32));
            for (0..count) |button| {
                if (self.controller_mapped[slot] and !(self.raw_go_super[slot] and (button == 12 or button == 13))) continue;
                input.applyJoyButtonFor(slot, @intCast(button), lib.JoystickGetButton(joy, @intCast(button)) != 0, self.raw_go_super[slot]);
            }
        }
    }

    /// v34: map an SDL controller button through the GO-Super A/B swap.
    pub fn mapControllerButton(self: *const Renderer, b: u8) u8 {
        if (!self.swap_ab) return b;
        return input_mod.swapAbButton(b);
    }

    /// v34: occupied-slot count of the sprite texture cache (the
    /// TRANSITION 02 pre-flush diagnostic).
    pub fn cacheEntryCount(self: *const Renderer) usize {
        var n: usize = 0;
        for (self.cache.entries) |e| {
            if (e.tex != null) n += 1;
        }
        return n;
    }

    pub fn deinit(self: *Renderer) void {
        watchdog.running.store(false, .release);
        if (self.sdl != null) {
            const lib: *sdl.Sdl2 = &self.sdl.?;
            _ = self.cache.flush(lib, flushDestroyEnabled(), "shutdown");
            self.text_cache.flush(lib);
            for (self.controllers) |c| {
                if (c) |gc| lib.GameControllerClose(gc);
            }
            for (self.joysticks) |j| {
                if (j) |joy| lib.JoystickClose(joy);
            }
            if (self.renderer) |r| lib.DestroyRenderer(r);
            if (self.window) |w| lib.DestroyWindow(w);
            lib.Quit();
        }
    }

    /// Pump events; feeds the Input model; returns false when the
    /// runtime should exit (window close or START+SELECT combo).
    pub fn pumpEvents(self: *Renderer, input: *input_mod.Input) bool {
        const lib = self.sdl orelse return false;
        var ev: sdl.Event = undefined;
        var quit_requested = false;
        while (lib.PollEvent(&ev) == 1) {
            self.events_seen += 1;
            // v30: the first 100 events get FULLY DECODED diagnostics
            // (name + button/axis + logical mapping) — the v29 run only
            // proved "events arrive"; v30 must prove "events dispatch".
            // v31: the 100-slot budget was eaten by analog-stick jitter
            // within 4 seconds on the device, so BUTTON/HAT/KEY events
            // are now logged for the WHOLE session (they are rare), and
            // only axis motion stays under the budget.
            const milestone = isInputMilestoneEvent(&ev);
            if (milestone or self.events_logged < 100) self.logEvent(&ev, milestone);
            switch (ev.type) {
                sdl.EVENT_QUIT => return false,
                sdl.EVENT_KEYDOWN => {
                    if (ev.key.repeat == 0) input.applyKey(ev.key.keysym.sym, true);
                },
                sdl.EVENT_KEYUP => input.applyKey(ev.key.keysym.sym, false),
                sdl.EVENT_CONTROLLERBUTTONDOWN, sdl.EVENT_CONTROLLERBUTTONUP => {
                    if (self.inputSlot(ev.cbutton.which)) |slot|
                        input.applyControllerButtonFor(slot, self.mappedButton(slot, ev.cbutton.button), ev.type == sdl.EVENT_CONTROLLERBUTTONDOWN);
                },
                sdl.EVENT_JOYBUTTONDOWN, sdl.EVENT_JOYBUTTONUP => {
                    if (self.inputSlot(ev.jbutton.which)) |slot| {
                        if (!self.controller_mapped[slot] or (self.raw_go_super[slot] and (ev.jbutton.button == 12 or ev.jbutton.button == 13)))
                            input.applyJoyButtonFor(slot, ev.jbutton.button, ev.type == sdl.EVENT_JOYBUTTONDOWN, self.raw_go_super[slot]);
                    }
                },
                sdl.EVENT_JOYHATMOTION => {
                    if (ev.jhat.hat == 0) if (self.inputSlot(ev.jhat.which)) |slot| {
                        if (!self.controller_mapped[slot]) input.applyJoyHatFor(slot, ev.jhat.value);
                    };
                },
                sdl.EVENT_CONTROLLERAXISMOTION => {
                    if (self.inputSlot(ev.caxis.which)) |slot| input.applyStickAxisFor(slot, ev.caxis.axis, ev.caxis.value);
                },
                sdl.EVENT_JOYAXISMOTION => {
                    if (self.inputSlot(ev.jaxis.which)) |slot| {
                        if (!self.controller_mapped[slot]) input.applyStickAxisFor(slot, ev.jaxis.axis, ev.jaxis.value);
                    }
                },
                sdl.EVENT_JOYDEVICEADDED, sdl.EVENT_CONTROLLERDEVICEADDED => self.openInputDevice(ev.jbutton.which),
                sdl.EVENT_JOYDEVICEREMOVED, sdl.EVENT_CONTROLLERDEVICEREMOVED => self.removeInputDevice(ev.jbutton.which, input),
                else => {},
            }
            // Latch an overlap at the exact event that creates it, then
            // finish the batch so its queued releases are also consumed.
            if (!quit_requested and self.quitChordPressed(input)) quit_requested = true;
        }

        self.pollInputButtons(input);
        if (!self.arbitration_logged) {
            self.arbitration_logged = true;
            log.event(.sys, .note, "input: per-device SDL controller mapping; explicit raw fallback; GO-Super raw12/13 exit; press START+SELECT together", .{});
        }
        if (!quit_requested and self.quitChordPressed(input)) quit_requested = true;

        return !quit_requested;
    }

    /// v30: fully decoded event trail — type name, button/axis VALUE,
    /// and the logical mapping result. One device run now answers
    /// "what does the pad emit" AND "what did it map to".
    /// v31: `milestone` = button/hat/key events, logged for the whole
    /// session (they are rare); axis motion stays under the 100-event
    /// budget (stick jitter produced 29 events/second on the device and
    /// starved the v30 log within 4 seconds).
    fn logEvent(self: *Renderer, ev: *const sdl.Event, milestone: bool) void {
        if (!milestone) self.events_logged += 1;
        const n = self.events_seen;
        switch (ev.type) {
            sdl.EVENT_KEYDOWN, sdl.EVENT_KEYUP => {
                log.event(.gpu, .note, "event #{d}: key {s} sym=0x{x}", .{ n, if (ev.type == sdl.EVENT_KEYDOWN) "down" else "up", @as(u32, @bitCast(ev.key.keysym.sym)) });
            },
            sdl.EVENT_CONTROLLERBUTTONDOWN, sdl.EVENT_CONTROLLERBUTTONUP => {
                const mapped = if (self.inputSlot(ev.cbutton.which)) |slot| self.mappedButton(slot, ev.cbutton.button) else ev.cbutton.button;
                log.event(.gpu, .note, "event #{d}: pad instance{d} '{s}' {s} (logical '{s}'{s})", .{ n, ev.cbutton.which, controllerButtonName(ev.cbutton.button), if (ev.type == sdl.EVENT_CONTROLLERBUTTONDOWN) "down" else "up", controllerLogicalName(mapped), if (mapped != ev.cbutton.button) " [A/B SWAPPED]" else "" });
            },
            sdl.EVENT_JOYBUTTONDOWN, sdl.EVENT_JOYBUTTONUP => {
                const slot = self.inputSlot(ev.jbutton.which);
                const go_super = if (slot) |index| self.raw_go_super[index] else false;
                const ignored = if (slot) |index| self.controller_mapped[index] and !(go_super and (ev.jbutton.button == 12 or ev.jbutton.button == 13)) else true;
                log.event(.gpu, .note, "event #{d}: joy instance{d} btn {d} '{s}' {s} (logical '{s}'{s})", .{ n, ev.jbutton.which, ev.jbutton.button, joyButtonName(ev.jbutton.button, go_super), if (ev.type == sdl.EVENT_JOYBUTTONDOWN) "down" else "up", joyLogicalName(ev.jbutton.button, go_super), if (ignored) " [IGNORED]" else "" });
            },
            sdl.EVENT_JOYHATMOTION => {
                log.event(.gpu, .note, "event #{d}: joy hat {d} value 0x{x} (logical {s})", .{ n, ev.jhat.hat, ev.jhat.value, hatLogicalName(ev.jhat.value) });
            },
            sdl.EVENT_CONTROLLERAXISMOTION => {
                log.event(.gpu, .note, "event #{d}: pad axis {d} = {d}", .{ n, ev.caxis.axis, ev.caxis.value });
            },
            sdl.EVENT_JOYAXISMOTION => {
                log.event(.gpu, .note, "event #{d}: joy axis {d} = {d}", .{ n, ev.jaxis.axis, ev.jaxis.value });
            },
            sdl.EVENT_CONTROLLERDEVICEADDED => log.event(.gpu, .note, "event #{d}: controller added (idx {d})", .{ n, ev.cbutton.which }),
            sdl.EVENT_JOYDEVICEADDED => log.event(.gpu, .note, "event #{d}: joystick added (idx {d})", .{ n, ev.jbutton.which }),
            else => {
                log.event(.gpu, .note, "event #{d}: type 0x{x}", .{ n, ev.type });
            },
        }
    }

    fn controllerButtonName(b: u8) []const u8 {
        return switch (b) {
            sdl.CB_A => "A",
            sdl.CB_B => "B",
            sdl.CB_X => "X",
            sdl.CB_Y => "Y",
            sdl.CB_BACK => "SELECT",
            sdl.CB_GUIDE => "GUIDE",
            sdl.CB_START => "START",
            sdl.CB_LEFTSHOULDER => "L1",
            sdl.CB_RIGHTSHOULDER => "R1",
            sdl.CB_DPUP => "DPAD-UP",
            sdl.CB_DPDOWN => "DPAD-DOWN",
            sdl.CB_DPLEFT => "DPAD-LEFT",
            sdl.CB_DPRIGHT => "DPAD-RIGHT",
            else => "?",
        };
    }

    fn controllerLogicalName(b: u8) []const u8 {
        return switch (b) {
            sdl.CB_A => "confirm",
            sdl.CB_B => "cancel",
            sdl.CB_X => "dash",
            sdl.CB_Y => "tag",
            sdl.CB_BACK => "select",
            sdl.CB_START => "menu",
            sdl.CB_LEFTSHOULDER => "page-up",
            sdl.CB_RIGHTSHOULDER => "page-down",
            sdl.CB_DPUP => "up",
            sdl.CB_DPDOWN => "down",
            sdl.CB_DPLEFT => "left",
            sdl.CB_DPRIGHT => "right",
            else => "unmapped",
        };
    }

    fn joyButtonName(b: u8, go_super: bool) []const u8 {
        if (!go_super and b >= 8) return switch (b) {
            8 => "SELECT",
            9 => "START",
            else => "unmapped",
        };
        return switch (b) {
            0 => "A",
            1 => "B",
            2 => "X",
            3 => "Y",
            4 => "L1",
            5 => "R1",
            6 => "L2",
            7 => "R2",
            // v33: the v32 device logs PROVED raw 8..11 are the GO-Super
            // Gamepad's D-PAD (each press fires pad 'DPAD-*' + joy 8..11
            // together) — v31 read them as SELECT/START/L3/R3 and every
            // D-pad tap armed the quit combo.
            8 => "DPAD-UP (GO-Super)",
            9 => "DPAD-DOWN (GO-Super)",
            10 => "DPAD-LEFT (GO-Super)",
            11 => "DPAD-RIGHT (GO-Super)",
            // v36 device logs confirm the actual GO-Super pair.
            12 => "SELECT (GO-Super)",
            13 => "START (GO-Super)",
            else => "?",
        };
    }

    fn joyLogicalName(b: u8, go_super: bool) []const u8 {
        if (b >= 8) return if (go_super) switch (b) {
            8 => "up",
            9 => "down",
            10 => "left",
            11 => "right",
            12 => "select (quit combo)",
            13 => "menu (quit combo)",
            else => "unmapped",
        } else switch (b) {
            8 => "select (quit combo)",
            9 => "menu (quit combo)",
            else => "unmapped",
        };
        return switch (b) {
            0 => "confirm",
            1 => "cancel",
            2 => "dash",
            3 => "tag",
            4 => "page-up",
            5 => "page-down",
            6 => "debug-1",
            7 => "debug-2",
            else => "unmapped",
        };
    }

    fn hatLogicalName(v: u8) []const u8 {
        // Static slices: the old assembled label escaped a stack buffer.
        return switch (v) {
            0 => "centered",
            1 => "up",
            2 => "right",
            3 => "up+right",
            4 => "down",
            5 => "up+down",
            6 => "down+right",
            7 => "up+down+right",
            8 => "left",
            9 => "up+left",
            10 => "left+right",
            11 => "up+left+right",
            12 => "down+left",
            13 => "up+down+left",
            14 => "down+left+right",
            15 => "up+down+left+right",
            else => "unknown",
        };
    }

    /// v31: button/hat/key events are "milestones" — logged for the
    /// whole session instead of sharing the v30 100-event budget that
    /// stick jitter exhausted in 4 seconds on the device.
    fn isInputMilestoneEvent(ev: *const sdl.Event) bool {
        return switch (ev.type) {
            sdl.EVENT_KEYDOWN,
            sdl.EVENT_KEYUP,
            sdl.EVENT_CONTROLLERBUTTONDOWN,
            sdl.EVENT_CONTROLLERBUTTONUP,
            sdl.EVENT_JOYBUTTONDOWN,
            sdl.EVENT_JOYBUTTONUP,
            sdl.EVENT_JOYHATMOTION,
            => true,
            else => false,
        };
    }

    /// Analog-stick → dpad synthesis (polled each frame; ±16000 dead
    /// zone like SDL's own joystick-guideline value). v30: routed
    /// through one shared semantic with the event path. v31: that
    /// semantic is applyStickAxis writing the STICK-provenance bits —
    /// a resting stick clears only the stick's contribution and can
    /// never erase a live D-pad press again (the v30 wipe bug).
    pub fn pollSticks(self: *Renderer, input: *input_mod.Input) void {
        const lib = self.sdl orelse return;
        for (self.controllers, 0..) |controller, slot| {
            const gc = controller orelse continue;
            input.applyStickAxisFor(slot, 0, lib.GameControllerGetAxis(gc, 0));
            input.applyStickAxisFor(slot, 1, lib.GameControllerGetAxis(gc, 1));
        }
        for (self.joysticks, 0..) |joystick, slot| {
            const joy = joystick orelse continue;
            if (self.controller_mapped[slot]) continue;
            const count = lib.JoystickNumAxes(joy);
            if (count > 0) input.applyStickAxisFor(slot, 0, lib.JoystickGetAxis(joy, 0));
            if (count > 1) input.applyStickAxisFor(slot, 1, lib.JoystickGetAxis(joy, 1));
            if (lib.JoystickNumHats(joy) > 0) input.applyJoyHatFor(slot, lib.JoystickGetHat(joy, 0));
        }
    }

    /// Present a frame of the given draw list (windowed mode), then
    /// pace to ~60 Hz. beginFrame/endFrame remain for simple clear
    /// loops; the game shell uses presentList.
    ///
    /// Per-frame textures created by DrawList.render are released after
    /// RenderPresent. Cache eviction separately uses SDL_DestroyTexture's
    /// normal queue-flushing contract.
    ///
    pub fn presentList(self: *Renderer, dl: anytype) void {
        const lib_ptr = &(self.sdl orelse return);
        const lib: *sdl.Sdl2 = lib_ptr;
        const ren = self.renderer orelse return;
        const t0 = lib.GetTicks();
        dl.render(lib, @ptrCast(ren), &self.cache, &self.text_cache);
        lib.RenderPresent(ren);
        // v34: per-frame textures die HERE — after the present.
        dl.finishFrame(lib);
        const dur = lib.GetTicks() - t0;
        self.present_ms_total += dur;
        if (dur > self.present_ms_max) self.present_ms_max = dur;
        self.frames_presented += 1;
        watchdog.beat();
        // v29 liveness heartbeat: every 240 frames (~4 s at 60 Hz) the
        // logs PROVE the loop is alive and how fast presenting is.
        // v34: text-cache stats ride along (uploads should go to ~0 once
        // the static labels are cached — the created-once semantics).
        if (self.frames_presented % 240 == 0) {
            const avg: u64 = if (self.frames_presented > 0) self.present_ms_total / self.frames_presented else 0;
            const st = self.cache.stats();
            const tcs = self.text_cache.stats();
            log.event(.sys, .info, "frame {d}: present avg {d} ms (max {d}), tex cache {d}/{d} hits, text cache {d}/{d} hits ({d} uploads), events {d}", .{
                self.frames_presented, avg, self.present_ms_max, st.hits, st.lookups, tcs.hits, tcs.lookups, tcs.uploads, self.events_seen,
            });
        }
        self.pace();
    }

    /// v33/v34: flush the texture cache (called by the game loop on every
    /// state transition — scenes reallocate their pixel stores there).
    /// Returns the number of texture slots that were occupied.
    ///
    /// Resolve SDL from this Renderer's current address, after any move.
    pub fn flushTextureCache(self: *Renderer, reason: []const u8) usize {
        const lib = if (self.sdl) |*live| live else return 0;
        return self.cache.flush(lib, flushDestroyEnabled(), reason);
    }

    /// Text cache keys describe pixel content and tint, so uploads remain
    /// reusable across scene transitions. Eviction and shutdown release
    /// their handles; no scene-specific flush is needed.
    pub fn flushTextCache(self: *Renderer) void {
        _ = self;
    }

    /// Begin a frame: clear with the OMORI boot color.
    pub fn beginFrame(self: *Renderer) void {
        const lib = self.sdl orelse return;
        _ = lib.SetRenderDrawColor(self.renderer, 16, 16, 24, 255);
        _ = lib.RenderClear(self.renderer);
    }

    /// Finish a frame: present + pace.
    pub fn endFrame(self: *Renderer) void {
        const lib = self.sdl orelse return;
        lib.RenderPresent(self.renderer);
        self.frames_presented += 1;
        watchdog.beat();
        self.pace();
    }

    fn pace(self: *Renderer) void {
        const lib = self.sdl orelse return;
        const delay = self.frame_clock.delayForNextFrame(lib.GetTicks());
        if (delay > 0) lib.Delay(delay);
        self.frame_clock.completed(lib.GetTicks());
    }
};

// Fake SDL texture ownership checks run without a display or an SDL2
// library. Only the texture operations under test are initialized.
const CacheTestSdl = struct {
    var created: usize = 0;
    var destroyed: usize = 0;
    var live: [256]bool = @splat(false);
    var invalid_destroy: bool = false;
    var stale_dispatch: bool = false;

    fn reset() void {
        created = 0;
        destroyed = 0;
        live = @splat(false);
        invalid_destroy = false;
        stale_dispatch = false;
    }

    fn create(_: ?*anyopaque, _: u32, _: c_int, _: c_int, _: c_int) callconv(.c) ?*anyopaque {
        created += 1;
        live[created] = true;
        return @ptrFromInt(created);
    }
    fn destroy(tex: ?*anyopaque) callconv(.c) void {
        const id = @intFromPtr(tex orelse return);
        if (id >= live.len or !live[id]) {
            invalid_destroy = true;
            return;
        }
        live[id] = false;
        destroyed += 1;
    }
    fn staleDestroy(_: ?*anyopaque) callconv(.c) void {
        stale_dispatch = true;
    }
    fn blend(_: ?*anyopaque, _: c_int) callconv(.c) c_int {
        return 0;
    }
    fn alpha(_: ?*anyopaque, _: u8) callconv(.c) c_int {
        return 0;
    }
    fn color(_: ?*anyopaque, _: u8, _: u8, _: u8) callconv(.c) c_int {
        return 0;
    }
    fn upload(_: ?*anyopaque, _: ?*const sdl.Rect, _: ?*const anyopaque, _: c_int) callconv(.c) c_int {
        return 0;
    }
    fn table() sdl.Sdl2 {
        var lib: sdl.Sdl2 = undefined;
        lib.CreateTexture = create;
        lib.DestroyTexture = destroy;
        lib.SetTextureBlendMode = blend;
        lib.SetTextureAlphaMod = alpha;
        lib.SetTextureColorMod = color;
        lib.UpdateTexture = upload;
        return lib;
    }
};

test "renderer: moving Renderer flushes through its live SDL table" {
    CacheTestSdl.reset();
    const previous_policy = flush_destroy_cache;
    flush_destroy_cache = true;
    defer flush_destroy_cache = previous_policy;

    var original = Renderer{
        .allocator = std.testing.allocator,
        .mode = .windowed,
        .sdl = CacheTestSdl.table(),
    };
    const pixels = [_]u8{ 255, 255, 255, 255 };
    _ = original.cache.put(&original.sdl.?, @ptrFromInt(0x1000), @ptrCast(pixels[0..].ptr), 1, 1, &pixels).?;
    var moved = original;
    // Any retained pointer into the original table now dispatches to
    // the wrong callback. The moved Renderer must resolve its own table.
    original.sdl.?.DestroyTexture = CacheTestSdl.staleDestroy;
    try std.testing.expectEqual(@as(usize, 1), moved.flushTextureCache("move regression"));
    try std.testing.expectEqual(@as(usize, 1), CacheTestSdl.destroyed);
    try std.testing.expect(!CacheTestSdl.stale_dispatch);
    try std.testing.expectEqual(@as(usize, 0), moved.flushTextureCache("empty regression"));
    try std.testing.expect(!CacheTestSdl.invalid_destroy);
}

test "renderer: sprite and text eviction release every replaced texture" {
    CacheTestSdl.reset();
    var lib = CacheTestSdl.table();
    var sprites = TexCache{};
    var texts = TextTexCache{};
    const pixels = [_]u8{ 255, 255, 255, 255 };
    for (0..TexCache.SLOTS + 7) |i| {
        _ = sprites.put(&lib, @ptrFromInt(0x1000), @ptrFromInt(i + 1), 1, 1, &pixels).?;
        try std.testing.expect(CacheTestSdl.created - CacheTestSdl.destroyed <= TexCache.SLOTS);
    }
    try std.testing.expectEqual(@as(usize, TexCache.SLOTS), sprites.flush(&lib, true, "eviction regression"));
    try std.testing.expectEqual(CacheTestSdl.created, CacheTestSdl.destroyed);

    for (0..TextTexCache.SLOTS + 9) |i| {
        _ = texts.get(i + 1);
        _ = texts.put(&lib, @ptrFromInt(0x1000), i + 1, 1, 1, &pixels).?;
        try std.testing.expect(CacheTestSdl.created - CacheTestSdl.destroyed <= TextTexCache.SLOTS);
    }
    try std.testing.expectEqual(@as(u64, 9), texts.evictions);
    texts.flush(&lib);
    texts.flush(&lib);
    try std.testing.expectEqual(CacheTestSdl.created, CacheTestSdl.destroyed);
    try std.testing.expect(!CacheTestSdl.invalid_destroy);
}
