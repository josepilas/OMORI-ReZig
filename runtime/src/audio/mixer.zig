//! Streaming Ogg Vorbis, MP3 and WAV → software mix → SDL2 queued output.
//! Content sniffing handles PC tracks with misleading .ogg filenames.
//!
//! Design (the §11 lazy contract, finally mixing):
//!   * ONE output device: 44.1 kHz S16 stereo requested (obtained wins),
//!     callback = null (SDL_QueueAudio mode — no callback reentrancy).
//!   * A mixer thread tops the device queue up to ~90 ms ahead every
//!     15 ms; each chunk mixes: independent streaming BGM and BGS plus
//!     up to 8 one-shot SEs.
//!   * BGM streams from the decoder with a 64 KiB decode window,
//!     resampled (16.16 fixed point, nearest) to the device rate with
//!     MV pitch semantics (pitch 100 = native), loops via
//!     omori_audio_seek_start, and fades (linear, ms-accurate).
//!   * SEs are decoded fully at play time (OMORI's SEs are sub-second),
//!     normalized to device rate/channels once, then played as a copy
//!     with gain — the inner loop is branchless.
//!   * Audio failure is NEVER fatal: no device / no file / decode error
//!     → log + continue silent (the v27 lesson: the game must run).
//!
//! Thread-safety: playBgm/stopBgm/playSe/stopSe take the same mutex the
//! mixer thread holds while producing a chunk (short critical sections).
//! The global `instance` lets the interpreter (commands 241/242/245/249/
//! 250), the title scene (user_title) and the menu feedback reach the
//! one mixer without plumbing pointers through every scene struct.

const std = @import("std");
const log = @import("../core/log.zig");
const sdl = @import("../platform/sdl2.zig");
const vfs_mod = @import("../filesystem/vfs.zig");
const audio_mod = @import("audio.zig");

// ---------------------------------------------------------------------------
// Bounded streaming decoder API (audio_decode.c; see build.zig).
// ---------------------------------------------------------------------------

const Decoder = opaque {};
const DecoderInfo = extern struct {
    sample_rate: c_uint,
    channels: c_int,
};
extern fn omori_audio_open_memory(data: [*]const u8, len: c_int, error_code: ?*c_int, alloc: ?*anyopaque) ?*Decoder;
extern fn omori_audio_get_info(f: *Decoder) DecoderInfo;
extern fn omori_audio_read(f: *Decoder, num_c: c_int, buffer: [*]i16, num_shorts: c_int) c_int;
extern fn omori_audio_seek_start(f: *Decoder) c_int;
extern fn omori_audio_close(f: *Decoder) void;

/// The one mixer (set in windowed boot; headless runs stay null).
pub var instance: ?*Mixer = null;

/// User preferences multiply the authored per-track volumes at mix time.
/// They never replace volumes stored in game saves or restart decoders.
pub const Volumes = struct {
    master: u8 = 100,
    bgm: u8 = 100,
    bgs: u8 = 100,
    me: u8 = 100,
    se: u8 = 100,
};

pub fn setVolumesGlobal(volumes: Volumes) void {
    if (instance) |m| m.setVolumes(volumes);
}

/// MV `AudioManager.makeEmptyAudioObject` / the save format:
/// `{name, volume, pitch, pan, pos}`; silent channel → name '' (volume
/// and pitch 0). `pos` is dropped (tracks restart from 0 on replay).
pub const SavedAudio = struct {
    name: []const u8 = "",
    volume: u32 = 0,
    pitch: u32 = 0,
    pan: u32 = 0,
};

/// The owned mixer-side snapshot behind a SavedAudio view.
const Stash = struct { name: []u8, volume: u32, pitch: u32, pan: u32 };

const CHUNK_FRAMES: usize = 1024; // ~23 ms at 44.1 kHz
const QUEUE_CHUNKS: usize = 4; // keep ≤ ~93 ms queued
const SE_VOICES: usize = 8;

/// Convenience wrappers used by scenes/interpreter (no-op headless).
pub fn playBgmGlobal(name: []const u8, volume: u32, pitch: u32) void {
    if (instance) |m| m.playBgm(name, volume, pitch);
}
pub fn stopBgmGlobal(fade_ms: u32) void {
    if (instance) |m| m.stopBgm(fade_ms);
}
pub fn playSeGlobal(name: []const u8, volume: u32) void {
    if (instance) |m| m.playSe(name, volume);
}
pub fn playMeGlobal(name: []const u8, volume: u32, pitch: u32) void {
    if (instance) |m| m.playMe(name, volume, pitch);
}

// ---------------------------------------------------------------------------
// v36: MV AudioManager save/replay globals (no-op headless).
// ---------------------------------------------------------------------------

pub fn stopBgsGlobal(fade_ms: u32) void {
    if (instance) |m| m.stopBgs(fade_ms);
}
pub fn stopSeGlobal() void {
    if (instance) |m| m.stopSe();
}
pub fn saveBgmGlobal() SavedAudio {
    const m = instance orelse return .{};
    return m.saveLoop(.bgm);
}
pub fn saveBgsGlobal() SavedAudio {
    const m = instance orelse return .{};
    return m.saveLoop(.bgs);
}
pub fn replayBgmGlobal(bgm: SavedAudio) void {
    if (instance) |m| m.replayLoop(.bgm, bgm);
}
pub fn replayBgsGlobal(bgs: SavedAudio) void {
    if (instance) |m| m.replayLoop(.bgs, bgs);
}
/// MV `isCurrentBgm(bgm)` — name equality against the playing track
/// (empty request names never match: `!!bgm && _currentBgm`).
pub fn currentBgmNameGlobal() ?[]const u8 {
    const m = instance orelse return null;
    return m.currentLoopName(.bgm);
}
pub fn currentBgsNameGlobal() ?[]const u8 {
    const m = instance orelse return null;
    return m.currentLoopName(.bgs);
}
/// The pan-carrying play (battle BGM + replay round-trips).
pub fn playBgmPanGlobal(name: []const u8, volume: u32, pitch: u32, pan: u32) void {
    if (instance) |m| m.playBgmPan(name, volume, pitch, pan);
}
pub fn playBgsPanGlobal(name: []const u8, volume: u32, pitch: u32, pan: u32) void {
    if (instance) |m| m.playBgsPan(name, volume, pitch, pan);
}

pub const Mixer = struct {
    alloc: std.mem.Allocator,
    lib: *sdl.Sdl2,
    vfs: *vfs_mod.Vfs,

    dev: u32 = 0,
    out_rate: u32 = 44100,
    enabled: bool = false,
    failed: bool = false,

    thread: ?std.Thread = null,
    running: bool = false,
    mutex: std.Thread.Mutex = .{},
    user_volumes: Volumes = .{},

    // BGM and BGS have independent decoders, gains, fades and lifetimes.
    bgm: ?Bgm = null,
    bgs: ?Bgm = null,
    bgm_serial: u64 = 0, // bumped on every swap (log correlation)

    // v36: MV AudioManager-level save snapshots (interpreter 243/244 +
    // BattleManager.saveBgmAndBgs). Names are mixer-owned copies so the
    // borrowed views handed to GameSystem / the battle flow stay valid
    // until the NEXT save on that channel replaces them.
    stash_bgm: ?Stash = null,
    stash_bgs: ?Stash = null,

    // --- SE voices ---
    voices: [SE_VOICES]Voice = @splat(.{}),
    /// ME plays once while BGM's decoder position is held; BGS continues.
    me: Voice = .{},

    // --- v31: system-sound names from data/System.json ($dataSystem) ---
    // MV's SoundManager does NOT use literal names like "cursor" — it
    // indexes the System.json "sounds" array (0=cursor, 1=decision,
    // 2=cancel, 3=buzzer, 4=equip, 5=save, 6=load) and plays that
    // entry's NAME. OMORI's payload names its SE files differently
    // (the v30 run: every hardcoded name missed while the folder held
    // 655 files). Owned copies; null = keep the raw logical name.
    system_se: [7]?[]u8 = @splat(null),
    /// v31: one-shot diagnostics — dump audio/se names on the first SE
    // resolution MISS so the payload's naming convention is in the log.
    se_names_dumped: bool = false,

    // --- mix scratch (owned by the mixer thread) ---
    acc: [CHUNK_FRAMES][2]i32 = @splat(.{ 0, 0 }),
    out: [CHUNK_FRAMES * 2]i16 = @splat(0),

    const Bgm = struct {
        channel: LoopChannel = .bgm,
        name: []u8, // owned
        bytes: []u8, // owned (decoder memory must stay alive)
        dec: *Decoder,
        src_rate: u32,
        channels: u32,
        volume: f32 = 1.0, // target (0..1)
        fade_volume: f32 = 1.0, // effective right now
        fade_step: f32 = 0, // per-chunk delta; 0 = steady
        fade_stop: bool = false, // stop when fully faded
        pitch: u32 = 100,
        // decode window: interleaved s16 at src_rate/channels
        buf: [32768]i16 = @splat(0),
        valid_from: usize = 0, // frame index of window start
        valid_to: usize = 0, // frame index of window end
        src_pos: u64 = 0, // 16.16 fixed-point frame position within window
        serial: u64 = 0,
        /// v36: the request's pan (MV round-trips it through save/replay;
        /// the mixer does not pan the output — tracked for fidelity).
        pan: u32 = 0,
    };

    const Voice = struct {
        channel: enum { se, me } = .se,
        active: bool = false,
        pcm: []i16 = &.{}, // owned, device-rate stereo interleaved
        cursor: usize = 0, // in frames
        gain: f32 = 1.0,
    };

    // -----------------------------------------------------------------------
    // lifecycle
    // -----------------------------------------------------------------------

    pub fn init(alloc: std.mem.Allocator, lib: *sdl.Sdl2, vfs: *vfs_mod.Vfs) Mixer {
        var m = Mixer{ .alloc = alloc, .lib = lib, .vfs = vfs };
        m.loadSystemSoundNames();

        // Audio subsystem SEPARATE from video: a broken audio driver can
        // never take the window down (the v30 sdl2.zig lesson).
        if (lib.InitSubSystem(sdl.INIT_AUDIO) != 0) {
            log.warn("audio: SDL_InitSubSystem(AUDIO) failed: {s} — running silent", .{std.mem.span(lib.GetError())});
            m.failed = true;
            return m;
        }
        if (lib.GetCurrentAudioDriver()) |d| {
            log.event(.audio, .note, "audio: SDL audio driver '{s}'", .{std.mem.span(d)});
        }

        var desired = sdl.AudioSpec{
            .freq = 44100,
            .format = sdl.AUDIO_S16LSB,
            .channels = 2,
            .silence = 0,
            .samples = 1024,
            .padding = 0,
            .size = 0,
            .callback = null,
            .userdata = null,
        };
        var obtained: sdl.AudioSpec = undefined;
        const dev = lib.OpenAudioDevice(null, 0, &desired, &obtained, sdl.AUDIO_ALLOW_FREQUENCY_CHANGE | sdl.AUDIO_ALLOW_SAMPLES_CHANGE);
        if (dev == 0) {
            log.warn("audio: SDL_OpenAudioDevice failed: {s} — running silent (the game is unaffected)", .{std.mem.span(lib.GetError())});
            m.failed = true;
            return m;
        }
        m.dev = dev;
        m.out_rate = if (obtained.freq > 8000) @intCast(obtained.freq) else 44100;
        m.enabled = true;
        _ = lib.PauseAudioDevice(dev, 0); // queue mode: start pumping
        log.milestone("audio: device open (id {d}, {d} Hz, s16, {d} ch) — M10 mixer armed", .{ dev, m.out_rate, obtained.channels });
        return m;
    }

    /// Spawn the mixer thread. MUST be called on the struct's FINAL
    /// address (the thread captures self) — init returns by value, so
    /// callers do: `var m = Mixer.init(...); m.start();` on a stable var.
    pub fn start(self: *Mixer) void {
        if (!self.enabled) return;
        if (self.thread != null) return;
        self.running = true;
        self.thread = std.Thread.spawn(.{}, mixerThread, .{self}) catch |e| blk: {
            log.warn("audio: mixer thread failed to spawn ({any}) — running silent", .{e});
            self.running = false;
            self.enabled = false;
            break :blk null;
        };
    }

    pub fn deinit(self: *Mixer) void {
        if (self.running) {
            self.running = false;
            if (self.thread) |t| t.join();
        }
        self.mutex.lock();
        if (self.bgm) |*b| self.freeBgm(b);
        self.bgm = null;
        if (self.bgs) |*b| self.freeBgm(b);
        self.bgs = null;
        if (self.me.pcm.len > 0) self.alloc.free(self.me.pcm);
        self.me = .{};
        if (self.stash_bgm) |s| self.alloc.free(s.name);
        self.stash_bgm = null;
        if (self.stash_bgs) |s| self.alloc.free(s.name);
        self.stash_bgs = null;
        for (&self.voices) |*v| {
            if (v.pcm.len > 0) self.alloc.free(v.pcm);
            v.* = .{};
        }
        self.mutex.unlock();
        for (&self.system_se) |*slot| {
            if (slot.*) |n| self.alloc.free(n);
            slot.* = null;
        }
        if (self.dev != 0) {
            _ = self.lib.ClearQueuedAudio(self.dev);
            self.lib.CloseAudioDevice(self.dev);
        }
    }

    fn freeBgm(self: *Mixer, b: *Bgm) void {
        omori_audio_close(b.dec);
        // v31: b.bytes came from vfs.readFileSync (VFS-allocator memory)
        // while b.name is a mixer-GPA dupe — free each with its owner.
        // (Freeing VFS memory through the mixer's GPA is an invalid-free
        // panic — caught live by the --self-raise smoke run.)
        self.vfs.allocator.free(b.bytes);
        self.alloc.free(b.name);
    }

    /// Free a buffer that came from vfs.readFileSync (VFS-owned).
    fn freeVfsBytes(self: *Mixer, bytes: []u8) void {
        self.vfs.allocator.free(bytes);
    }

    // -----------------------------------------------------------------------
    // public API (game thread)
    // -----------------------------------------------------------------------

    pub fn setVolumes(self: *Mixer, volumes: Volumes) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        inline for (.{ "master", "bgm", "bgs", "me", "se" }) |field| {
            @field(self.user_volumes, field) = @min(@field(volumes, field), 100);
        }
    }

    fn userGain(self: *const Mixer, channel: u8) f32 {
        return @as(f32, @floatFromInt(self.user_volumes.master)) * @as(f32, @floatFromInt(channel)) / 10000.0;
    }

    /// Play (or switch to) a BGM. volume/pitch are MV semantics (0-100).
    pub fn playBgm(self: *Mixer, name: []const u8, volume: u32, pitch: u32) void {
        self.playLoop(.bgm, name, volume, pitch, 0);
    }

    /// Ambient sounds loop alongside BGM, resolved from audio/bgs.
    pub fn playBgs(self: *Mixer, name: []const u8, volume: u32, pitch: u32) void {
        self.playLoop(.bgs, name, volume, pitch, 0);
    }

    /// v36: the pan-carrying variants (replay + battle BGM round-trips
    /// the saved pan; the mix itself ignores pan — MV pans, we don't).
    pub fn playBgmPan(self: *Mixer, name: []const u8, volume: u32, pitch: u32, pan: u32) void {
        self.playLoop(.bgm, name, volume, pitch, pan);
    }

    pub fn playBgsPan(self: *Mixer, name: []const u8, volume: u32, pitch: u32, pan: u32) void {
        self.playLoop(.bgs, name, volume, pitch, pan);
    }

    const LoopChannel = enum { bgm, bgs };

    fn loopSlot(self: *Mixer, channel: LoopChannel) *?Bgm {
        return switch (channel) {
            .bgm => &self.bgm,
            .bgs => &self.bgs,
        };
    }

    fn playLoop(self: *Mixer, channel: LoopChannel, name: []const u8, volume: u32, pitch: u32, pan: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const slot = self.loopSlot(channel);
        // MV playBgm/playBgs with an empty name stops that channel.
        if (name.len == 0) {
            self.stopLoopLocked(channel, 0);
            return;
        }
        if (slot.*) |*b| {
            if (std.mem.eql(u8, b.name, name)) {
                // same track: adjust volume/pitch in place (MV restarts
                // only when the name differs)
                b.volume = volF(volume);
                b.pitch = pitch;
                b.fade_volume = 1;
                b.fade_step = 0;
                b.fade_stop = false;
                return;
            }
        }
        const source_channel: audio_mod.Channel = switch (channel) {
            .bgm => .bgm,
            .bgs => .bgs,
        };
        const bytes = self.loadFileBytes(source_channel, name) orelse {
            log.event(.audio, .warn, "{s} '{s}': file not found (resolvers probed audio/{s} variants)", .{ @tagName(channel), name, @tagName(channel) });
            if (slot.*) |*old| {
                self.freeBgm(old);
                slot.* = null;
            }
            return;
        };
        var err: c_int = 0;
        const dec = omori_audio_open_memory(bytes.ptr, @intCast(bytes.len), &err, null) orelse {
            log.event(.audio, .warn, "{s} '{s}': audio open failed (err {d})", .{ @tagName(channel), name, err });
            self.freeVfsBytes(bytes);
            return;
        };
        const info = omori_audio_get_info(dec);
        const owned_name = self.alloc.dupe(u8, name) catch {
            omori_audio_close(dec);
            self.freeVfsBytes(bytes);
            return;
        };
        if (slot.*) |*old| self.freeBgm(old);
        self.bgm_serial += 1;
        slot.* = .{
            .channel = channel,
            .name = owned_name,
            .bytes = bytes,
            .dec = dec,
            .src_rate = @intCast(info.sample_rate),
            .channels = @intCast(@max(info.channels, 1)),
            .volume = volF(volume),
            .fade_volume = 1,
            .pitch = pitch,
            .pan = pan,
            .serial = self.bgm_serial,
        };
        log.event(.audio, .note, "{s} '{s}' playing (vol {d}, pitch {d}; {d} Hz, {d} ch → {d} Hz out)", .{ @tagName(channel), name, volume, pitch, info.sample_rate, info.channels, self.out_rate });
    }

    /// Stop the BGM with a linear fade (ms).
    pub fn stopBgm(self: *Mixer, fade_ms: u32) void {
        self.stopLoop(.bgm, fade_ms);
    }

    pub fn stopBgs(self: *Mixer, fade_ms: u32) void {
        self.stopLoop(.bgs, fade_ms);
    }

    /// MV playMe: a one-shot from audio/me temporarily pauses BGM.
    pub fn playMe(self: *Mixer, name: []const u8, volume: u32, pitch: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopMeLocked();
        if (name.len == 0) return;
        const bytes = self.loadFileBytes(.me, name) orelse {
            log.event(.audio, .warn, "me '{s}': file not found", .{name});
            return;
        };
        defer self.freeVfsBytes(bytes);
        const resample_rate: u32 = @intCast(@as(u64, self.out_rate) * 100 / std.math.clamp(pitch, 25, 400));
        const pcm = decodeToPcm(self.alloc, bytes, resample_rate) orelse {
            log.event(.audio, .warn, "me '{s}': audio decode failed", .{name});
            return;
        };
        self.me = .{ .channel = .me, .active = true, .pcm = pcm, .gain = volF(volume) };
        log.event(.audio, .note, "me '{s}' playing once (vol {d}, pitch {d}; {d} frames)", .{ name, volume, pitch, pcm.len / 2 });
    }

    pub fn stopMe(self: *Mixer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopMeLocked();
    }

    fn stopMeLocked(self: *Mixer) void {
        const was_playing = self.me.active;
        if (self.me.pcm.len > 0) self.alloc.free(self.me.pcm);
        self.me = .{};
        if (was_playing) {
            if (self.bgm) |*b| {
                // Preserve decoder/window position and fade the resumed BGM.
                b.fade_volume = 0;
                b.fade_step = 1.0 / @as(f32, @floatCast(fadeChunks(self.out_rate, 500)));
                b.fade_stop = false;
            }
        }
    }

    fn stopLoop(self: *Mixer, channel: LoopChannel, fade_ms: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.stopLoopLocked(channel, fade_ms);
    }

    fn stopLoopLocked(self: *Mixer, channel: LoopChannel, fade_ms: u32) void {
        const slot = self.loopSlot(channel);
        if (slot.*) |*b| {
            if (fade_ms == 0) {
                self.freeBgm(b);
                slot.* = null;
                log.event(.audio, .note, "{s} stopped (immediate)", .{@tagName(channel)});
                return;
            }
            // chunks per fade duration → per-chunk step
            const chunks = fadeChunks(self.out_rate, fade_ms);
            b.fade_step = -(b.fade_volume / @as(f32, @floatCast(chunks)));
            b.fade_stop = true;
            log.event(.audio, .note, "{s} fading out over {d} ms", .{ @tagName(channel), fade_ms });
        }
    }

    /// Chunks covered by an ms-long fade at the device rate (≥ 1).
    fn fadeChunks(out_rate: u32, ms: u32) f64 {
        return @max(@as(f64, @floatFromInt(ms)) * @as(f64, @floatFromInt(out_rate)) / (1000.0 * @as(f64, @floatFromInt(CHUNK_FRAMES))), 1.0);
    }

    /// MV `AudioManager.fadeIn(seconds)` — linear rise back to full
    /// volume (used by replayBgm; _replayFadeTime = 0.5 s).
    pub fn fadeInLoop(self: *Mixer, channel: LoopChannel, ms: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.loopSlot(channel).*) |*b| {
            const chunks = fadeChunks(self.out_rate, ms);
            b.fade_volume = 0;
            b.fade_step = 1.0 / @as(f32, @floatCast(chunks));
            b.fade_stop = false;
            log.event(.audio, .note, "{s} fading in over {d} ms", .{ @tagName(channel), ms });
        }
    }

    /// The playing track's name on a channel (null = silent). The view
    /// is the mixer's owned copy — valid until the next play/stop on the
    /// channel; callers use it immediately (MV `isCurrentBgm`).
    pub fn currentLoopName(self: *Mixer, channel: LoopChannel) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.loopSlot(channel).*) |*b| return b.name;
        return null;
    }

    /// MV `AudioManager.saveBgm` — the current channel request, or the
    /// empty object (name '') when the channel is silent. The returned
    /// view borrows the mixer's snapshot (valid until the next save on
    /// this channel); `pos` is not tracked (tracks restart from 0).
    pub fn saveLoop(self: *Mixer, channel: LoopChannel) SavedAudio {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.loopSlot(channel).*) |*b| {
            const volume: u32 = @intFromFloat(@round(b.volume * 100.0));
            const stash_slot: *?Stash = switch (channel) {
                .bgm => &self.stash_bgm,
                .bgs => &self.stash_bgs,
            };
            const owned = self.alloc.dupe(u8, b.name) catch return .{};
            if (stash_slot.*) |old| self.alloc.free(old.name);
            stash_slot.* = .{ .name = owned, .volume = volume, .pitch = b.pitch, .pan = b.pan };
            return .{ .name = owned, .volume = volume, .pitch = b.pitch, .pan = b.pan };
        }
        // makeEmptyAudioObject — MV stores the empty object; the stale
        // stash stays alive (freed by the next successful save).
        return .{};
    }

    /// MV `AudioManager.replayBgm` — same-name track: parameters only
    /// (no restart); different name: play + fadeIn(_replayFadeTime =
    /// 0.5 s). Empty name → stopBgm (playBgm('') semantics).
    pub fn replayLoop(self: *Mixer, channel: LoopChannel, a: SavedAudio) void {
        if (a.name.len == 0) {
            self.stopLoop(channel, 0);
            return;
        }
        if (self.currentLoopName(channel)) |cur| {
            if (std.mem.eql(u8, cur, a.name)) {
                // updateBgmParameters: volume/pitch only, no restart.
                self.mutex.lock();
                defer self.mutex.unlock();
                if (self.loopSlot(channel).*) |*b| {
                    b.volume = volF(a.volume);
                    b.pitch = a.pitch;
                }
                return;
            }
        }
        self.playLoop(channel, a.name, a.volume, a.pitch, a.pan);
        self.fadeInLoop(channel, 500);
    }

    /// Play a one-shot SE (decoded fully now; volume 0-100).
    /// v31: MV semantics — "cursor"/"decision"/... are LOGICAL names;
    /// the actual file comes from $dataSystem.sounds (loaded at init).
    pub fn playSe(self: *Mixer, name: []const u8, volume: u32) void {
        if (name.len == 0) return;
        const actual = self.systemSeName(name);
        if (!std.mem.eql(u8, actual, name)) {
            log.detail(.audio, "se '{s}' → $dataSystem sound '{s}'", .{ name, actual });
        }
        const bytes = self.loadFileBytes(.se, actual) orelse {
            log.event(.audio, .warn, "se '{s}': file not found", .{actual});
            self.dumpSeNamesOnce();
            return;
        };
        // v31: VFS-owned buffer (see freeVfsBytes).
        defer self.freeVfsBytes(bytes);
        const pcm = decodeToPcm(self.alloc, bytes, self.out_rate) orelse {
            log.event(.audio, .warn, "se '{s}': audio decode failed", .{name});
            return;
        };
        self.startVoice(pcm, volume, name);
    }

    /// Hand a decoded device-rate PCM buffer to the oldest free voice
    /// (else the oldest playing one) — shared by playSe/playSeRaw.
    fn startVoice(self: *Mixer, pcm: []i16, volume: u32, name: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        // replace the oldest finished slot, else the oldest playing one
        var slot: ?*Voice = null;
        for (&self.voices) |*v| {
            if (!v.active) {
                slot = v;
                break;
            }
            if (slot == null or v.cursor > slot.?.cursor) slot = v;
        }
        const v = slot orelse return;
        if (v.pcm.len > 0) self.alloc.free(v.pcm);
        v.* = .{ .active = true, .pcm = pcm, .cursor = 0, .gain = volF(volume) };
        log.event(.audio, .note, "se '{s}' (vol {d}, {d} frames)", .{ name, volume, pcm.len / 2 });
    }

    /// v36: play an SE by its literal file name — `SoundManager.playSystemSound(n)`
    /// passes the $dataSystem entry straight through, skipping the
    /// logical-name mapping playSe applies.
    pub fn playSeRaw(self: *Mixer, name: []const u8, volume: u32) void {
        if (name.len == 0) return;
        const bytes = self.loadFileBytes(.se, name) orelse {
            log.event(.audio, .warn, "se '{s}': file not found (raw)", .{name});
            return;
        };
        defer self.freeVfsBytes(bytes);
        const pcm = decodeToPcm(self.alloc, bytes, self.out_rate) orelse {
            log.event(.audio, .warn, "se '{s}': audio decode failed (raw)", .{name});
            return;
        };
        self.startVoice(pcm, volume, name);
    }

    /// MV command 250: stop all SEs.
    pub fn stopSe(self: *Mixer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.voices) |*v| {
            v.active = false;
        }
    }

    /// Resolve + read an audio file through the VFS identity layer.
    ///
    /// v32 CRITICAL FIX — the v31 title-screen SIGSEGV (silent exit 139
    /// right after "read 'audio/bgm/user_title.ogg'"): `resolve()` returns
    /// a slice OWNED BY THE RESOLVER'S CACHE MAP — the same pointer is
    /// stored as the map's value. v31 freed it here (defer free(path)) AND
    /// freed it again via `resolver.deinit()` walking the map — a double
    /// free by construction. v30 survived only because the mixer's
    /// allocator was the arena (arena free = memset, never unmaps). v31's
    /// GPA actually recycles: the FIRST free emptied the bucket page, the
    /// GPA UNMAPPED it, and the second free's unconditional
    /// `Allocator.free` poison-memset (`@memset(ptr, undefined)` = 0xaa ×
    /// 24 bytes, exactly len("audio/bgm/user_title.ogg")) landed on
    /// unmapped memory → SIGSEGV. Reproduced deterministically on x86
    /// (harness: runtime/repro.zig) with the full crash report pinning
    /// AudioManager.deinit → Allocator.free.
    ///
    /// Ownership now: the resolver map owns the path and frees it exactly
    /// once in deinit(); this function only BORROWS it.
    fn loadFileBytes(self: *Mixer, channel: audio_mod.Channel, name: []const u8) ?[]u8 {
        var resolver = audio_mod.AudioManager.init(self.alloc, self.vfs);
        defer resolver.deinit();
        const path = (resolver.resolve(channel, name) catch return null) orelse return null;
        return self.vfs.readFileSync(path) catch null;
    }

    // -------------------------------------------------------------------
    // v31: $dataSystem sound names (the MV-correct SE identity layer)
    // -------------------------------------------------------------------

    /// data/System.json "sounds" array indices (rpg_managers.js
    /// SoundManager: playCursor→0, playDecision→1, playCancel→2,
    /// playBuzzer→3, playEquip→4, playSave→5, playLoad→6).
    fn systemSeIndex(logical: []const u8) ?usize {
        const table = [_][]const u8{ "cursor", "decision", "cancel", "buzzer", "equip", "save", "load" };
        for (table, 0..) |t, i| {
            if (std.mem.eql(u8, t, logical)) return i;
        }
        return null;
    }

    /// The name actually on disk for a logical system sound: the
    /// $dataSystem entry when present, else the raw logical name (the
    /// VFS's case-insensitive fallback still applies downstream).
    fn systemSeName(self: *const Mixer, logical: []const u8) []const u8 {
        if (systemSeIndex(logical)) |i| {
            if (self.system_se[i]) |n| return n;
        }
        return logical;
    }

    /// Parse data/System.json once at init and dupe the first seven
    /// sound names. Any failure logs a note and leaves the raw fallback.
    fn loadSystemSoundNames(self: *Mixer) void {
        const text = self.vfs.readFileSync("data/System.json") catch |e| {
            log.event(.audio, .note, "se identity: data/System.json unreadable ({any}) — logical names pass through", .{e});
            return;
        };
        // v31: VFS-owned buffer — free with the VFS's allocator.
        defer self.vfs.allocator.free(text);
        const parsed = std.json.parseFromSlice(std.json.Value, self.alloc, text, .{}) catch |e| {
            log.event(.audio, .note, "se identity: System.json parse failed ({any}) — logical names pass through", .{e});
            return;
        };
        defer parsed.deinit();
        const sounds = switch (parsed.value) {
            .object => |o| o.get("sounds") orelse return,
            else => return,
        };
        const arr = switch (sounds) {
            .array => |a| a,
            else => return,
        };
        var loaded: usize = 0;
        for (arr.items, 0..) |item, i| {
            if (i >= self.system_se.len) break;
            const name = switch (item) {
                .object => |o| switch (o.get("name") orelse continue) {
                    .string => |s| s,
                    else => continue,
                },
                .string => |s| s, // tolerant: bare string arrays too
                else => continue,
            };
            if (name.len == 0) continue;
            self.system_se[i] = self.alloc.dupe(u8, name) catch continue;
            loaded += 1;
        }
        if (loaded > 0) {
            var names_buf: [320]u8 = undefined;
            var len: usize = 0;
            for (self.system_se, 0..) |slot, i| {
                const nm = slot orelse continue;
                if (len > 0 and len < names_buf.len) {
                    names_buf[len] = ',';
                    len += 1;
                }
                if (len + nm.len >= names_buf.len) break;
                @memcpy(names_buf[len..][0..nm.len], nm);
                len += nm.len;
                _ = i;
            }
            log.event(.audio, .note, "se identity: $dataSystem sounds loaded ({d}/7): {s}", .{ loaded, names_buf[0..len] });
        } else {
            log.event(.audio, .note, "se identity: System.json has no sound names — logical names pass through", .{});
        }
    }

    /// One-shot: dump the first 40 audio/se names so the payload's
    /// naming convention lands in the log on the first miss.
    fn dumpSeNamesOnce(self: *Mixer) void {
        if (self.se_names_dumped) return;
        self.se_names_dumped = true;
        const names = self.vfs.readdirSync("audio/se") catch return;
        // v31: VFS-owned listing — free with the VFS's allocator.
        defer {
            for (names) |n| self.vfs.allocator.free(n);
            self.vfs.allocator.free(names);
        }
        var buf: [1024]u8 = undefined;
        var len: usize = 0;
        var shown: usize = 0;
        for (names) |n| {
            if (shown >= 40) break;
            if (len > 0 and len + 2 < buf.len) {
                buf[len] = ',';
                buf[len + 1] = ' ';
                len += 2;
            }
            if (len + n.len + 1 >= buf.len) break;
            @memcpy(buf[len..][0..n.len], n);
            len += n.len;
            shown += 1;
        }
        log.event(.audio, .note, "se identity: audio/se holds {d} file(s); first {d}: {s}{s}", .{
            names.len, shown, buf[0..len], if (names.len > shown) " …" else "",
        });
    }

    // -----------------------------------------------------------------------
    // mixer thread
    // -----------------------------------------------------------------------

    fn mixerThread(self: *Mixer) void {
        const chunk_bytes: u32 = @intCast(CHUNK_FRAMES * 2 * @sizeOf(i16));
        while (self.running) {
            const queued = self.lib.GetQueuedAudioSize(self.dev);
            if (queued < chunk_bytes * QUEUE_CHUNKS) {
                self.mutex.lock();
                self.produceChunk();
                self.mutex.unlock();
            }
            std.Thread.sleep(15 * std.time.ns_per_ms);
        }
    }

    const CHUNK_BYTES: u32 = @intCast(CHUNK_FRAMES * 2 * @sizeOf(i16));

    /// Mix exactly CHUNK_FRAMES device frames into self.out and queue.
    fn produceChunk(self: *Mixer) void {
        if (!self.enabled) return;
        @memset(&self.acc, .{ 0, 0 });

        // --- BGM ---
        if (!self.me.active) {
            if (self.bgm) |*b| {
                if (!self.mixBgm(b)) self.bgm = null;
            }
        }
        // --- BGS (ambient loop, independently controlled) ---
        if (self.bgs) |*b| {
            if (!self.mixBgm(b)) self.bgs = null;
        }

        // --- ME (one-shot jingle; BGM resumes after this chunk) ---
        if (self.me.active) {
            if (self.mixVoice(&self.me)) self.stopMeLocked();
        }

        // --- SE voices ---
        for (&self.voices) |*v| {
            if (!v.active) continue;
            if (self.mixVoice(v)) v.active = false;
        }

        // --- clamp + interleave ---
        var i: usize = 0;
        while (i < CHUNK_FRAMES) : (i += 1) {
            self.out[i * 2] = clamp16(self.acc[i][0]);
            self.out[i * 2 + 1] = clamp16(self.acc[i][1]);
        }
        _ = self.lib.QueueAudio(self.dev, &self.out, CHUNK_BYTES);
    }

    /// Mix a device-rate stereo voice, returning true at its end.
    fn mixVoice(self: *Mixer, v: *Voice) bool {
        const frames = v.pcm.len / 2;
        const user_gain = self.userGain(if (v.channel == .me) self.user_volumes.me else self.user_volumes.se);
        const g: i32 = @intFromFloat(v.gain * user_gain * 256.0);
        var f: usize = 0;
        while (f < CHUNK_FRAMES and v.cursor < frames) : (f += 1) {
            const s: usize = v.cursor * 2;
            self.acc[f][0] += @divTrunc(@as(i32, v.pcm[s]) * g, 256);
            self.acc[f][1] += @divTrunc(@as(i32, v.pcm[s + 1]) * g, 256);
            v.cursor += 1;
        }
        return v.cursor >= frames;
    }

    /// Stream-mix the BGM for one chunk with resampling + fade.
    fn mixBgm(self: *Mixer, b: *Bgm) bool {
        // fade progression
        if (b.fade_step != 0) {
            b.fade_volume += b.fade_step;
            if (b.fade_volume <= 0) {
                b.fade_volume = 0;
                if (b.fade_stop) {
                    self.freeBgm(b);
                    return false;
                }
                b.fade_step = 0;
            } else if (b.fade_volume > 1) {
                b.fade_volume = 1;
                b.fade_step = 0;
            }
        }
        const channel_volume = if (b.channel == .bgm) self.user_volumes.bgm else self.user_volumes.bgs;
        const gain_f: f32 = b.volume * b.fade_volume * self.userGain(channel_volume);
        const gain: i32 = @intFromFloat(gain_f * 256.0);

        // 16.16 step: source frames per device frame (pitch-aware)
        const step_num: u64 = @as(u64, b.src_rate) * b.pitch;
        const step_den: u64 = @as(u64, self.out_rate) * 100;
        const step: u64 = (step_num << 16) / step_den;

        var f: usize = 0;
        while (f < CHUNK_FRAMES) : (f += 1) {
            // ensure a source frame is available at the current position
            const rel: usize = @intCast(b.src_pos >> 16);
            while (b.valid_from + rel >= b.valid_to) {
                if (!self.refillBgm(b)) return false; // decoder dead (track freed)
            }
            const idx: usize = (b.valid_from + rel) * b.channels;
            const l: i32 = b.buf[idx];
            const r: i32 = if (b.channels >= 2) b.buf[idx + 1] else b.buf[idx];
            self.acc[f][0] += @divTrunc(l * gain, 256);
            self.acc[f][1] += @divTrunc(r * gain, 256);
            b.src_pos += step;
            // window compaction when the integer part passes the window
            if ((b.src_pos >> 16) >= WINDOW_FRAMES - 2) {
                compactBgm(b);
            }
        }
        return true;
    }

    const WINDOW_FRAMES: usize = 32768 / 2; // s16 stereo worst case

    fn compactBgm(b: *Bgm) void {
        const consumed: usize = @intCast(b.src_pos >> 16);
        if (consumed == 0) return;
        const keep = b.valid_to - (b.valid_from + consumed);
        if (keep > 0) {
            const src_frames = b.valid_from + consumed;
            const copy_shorts = keep * b.channels;
            const dst = b.buf[0..copy_shorts];
            const src = b.buf[src_frames * b.channels ..][0..copy_shorts];
            std.mem.copyForwards(i16, dst, src);
        }
        b.valid_from = 0;
        b.valid_to = keep;
        b.src_pos &= 0xFFFF; // keep the fractional part
    }

    /// Decode more frames into the window (looping at EOF). Returns
    /// false when the decoder is dead (bgm freed + cleared).
    fn refillBgm(self: *Mixer, b: *Bgm) bool {
        // decode frames until the window is full or EOF
        const cap_frames: usize = 32768 / b.channels;
        while (b.valid_to < cap_frames) {
            const want_shorts: c_int = @intCast((cap_frames - b.valid_to) * b.channels);
            const got = omori_audio_read(b.dec, @intCast(b.channels), b.buf[b.valid_to * b.channels ..].ptr, want_shorts);
            if (got <= 0) {
                // EOF → loop (seek_start keeps the same memory bytes)
                if (omori_audio_seek_start(b.dec) != 1) {
                    log.event(.audio, .warn, "bgm '{s}': loop seek failed — stopping track", .{b.name});
                    self.freeBgm(b);
                    return false;
                }
                const retry = omori_audio_read(b.dec, @intCast(b.channels), b.buf[b.valid_to * b.channels ..].ptr, want_shorts);
                if (retry <= 0) {
                    self.freeBgm(b);
                    return false;
                }
                b.valid_to += @intCast(retry);
                continue;
            }
            b.valid_to += @intCast(got);
        }
        return true;
    }

    fn clamp16(v: i32) i16 {
        return @intCast(std.math.clamp(v, -32768, 32767));
    }

    fn volF(v: u32) f32 {
        return @as(f32, @floatFromInt(@min(v, 100))) / 100.0;
    }
};

/// Fully decode an ogg + convert to device-rate stereo s16 (for SEs).
fn decodeToPcm(alloc: std.mem.Allocator, bytes: []u8, out_rate: u32) ?[]i16 {
    var err: c_int = 0;
    const dec = omori_audio_open_memory(bytes.ptr, @intCast(bytes.len), &err, null) orelse return null;
    defer omori_audio_close(dec);
    const info = omori_audio_get_info(dec);
    const channels: usize = @intCast(@max(info.channels, 1));
    const src_rate: u32 = @intCast(info.sample_rate);

    // decode all frames (native)
    var native = std.ArrayList(i16).empty;
    defer native.deinit(alloc);
    var frame: [16384]i16 = undefined; // one vorbis frame max
    while (true) {
        const got = omori_audio_read(dec, @intCast(channels), &frame, @intCast(frame.len));
        if (got <= 0) break;
        native.appendSlice(alloc, frame[0 .. @as(usize, @intCast(got)) * channels]) catch return null;
    }
    const src_frames = native.items.len / channels;
    if (src_frames == 0) return null;

    // resample (nearest, 16.16) to device rate + upmix to stereo
    const step_num: u64 = @as(u64, src_rate) << 16;
    const step: u64 = step_num / out_rate;
    const out_frames: usize = @intCast((@as(u64, src_frames) << 16) / step + 1);
    const out = alloc.alloc(i16, out_frames * 2) catch return null;
    errdefer alloc.free(out);
    var pos: u64 = 0;
    var f: usize = 0;
    while (f < out_frames) : (f += 1) {
        const idx: usize = @as(usize, @intCast(pos >> 16)) * channels;
        if (idx >= native.items.len) break;
        out[f * 2] = native.items[idx];
        out[f * 2 + 1] = if (channels >= 2) native.items[idx + 1] else native.items[idx];
        pos += step;
    }
    // Rounding may allocate one frame beyond the last source sample.
    // Return only initialized PCM so one-shots never play allocator poison.
    return alloc.realloc(out, f * 2) catch {
        alloc.free(out);
        return null;
    };
}

// ---------------------------------------------------------------------------
// Tests (fixture: a generated ogg — see scripts/make_ogg_fixture.py; the
// test skips silently when the fixture is absent).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "mixer: user gains affect each live channel without restarting playback" {
    var m = Mixer{ .alloc = testing.allocator, .lib = undefined, .vfs = undefined };
    m.setVolumes(.{ .bgm = 0, .bgs = 100, .me = 0, .se = 50 });
    var loop = Mixer.Bgm{ .name = &.{}, .bytes = &.{}, .dec = undefined, .src_rate = 44100, .channels = 2, .valid_to = 16384 };
    @memset(&loop.buf, 1000);
    try testing.expect(m.mixBgm(&loop));
    try testing.expectEqual(@as(i32, 0), m.acc[0][0]);
    try testing.expect(loop.src_pos > 0);
    const position = loop.src_pos;
    loop.channel = .bgs;
    try testing.expect(m.mixBgm(&loop));
    try testing.expectEqual(@as(i32, 1000), m.acc[0][0]);
    try testing.expect(loop.src_pos > position);
    var pcm: [CHUNK_FRAMES * 2]i16 = @splat(1000);
    var voice = Mixer.Voice{ .active = true, .pcm = &pcm, .channel = .me };
    @memset(&m.acc, .{ 0, 0 });
    try testing.expect(m.mixVoice(&voice));
    try testing.expectEqual(@as(i32, 0), m.acc[0][0]);
    voice.cursor = 0;
    voice.channel = .se;
    try testing.expect(m.mixVoice(&voice));
    try testing.expectEqual(@as(i32, 500), m.acc[0][0]);
    m.setVolumes(.{ .master = 0 });
    @memset(&m.acc, .{ 0, 0 });
    try testing.expect(m.mixBgm(&loop));
    try testing.expectEqual(@as(i32, 0), m.acc[0][0]);
    try testing.expectEqual(@as(f32, 1), loop.volume);
    m.setVolumes(.{ .master = 255, .se = 255 });
    try testing.expectEqual(@as(u8, 100), m.user_volumes.master);
    try testing.expectEqual(@as(u8, 100), m.user_volumes.se);
}

test "mixer: Ogg MP3 and WAV stream by content and rewind" {
    const fixtures = .{ @embedFile("test-tone.ogg"), @embedFile("test-tone.mp3"), @embedFile("test-tone.wav") };
    inline for (fixtures) |bytes| {
        var code: c_int = -1;
        const decoder = omori_audio_open_memory(bytes, @intCast(bytes.len), &code, null) orelse return error.TestUnexpectedResult;
        defer omori_audio_close(decoder);
        try testing.expectEqual(@as(c_int, 0), code);
        const info = omori_audio_get_info(decoder);
        try testing.expect(info.sample_rate > 0 and info.channels >= 1 and info.channels <= 2);
        var samples: [8192]i16 = undefined;
        var frames: usize = 0;
        var nonzero = false;
        for (0..64) |_| {
            const got = omori_audio_read(decoder, info.channels, &samples, samples.len);
            if (got == 0) break;
            try testing.expect(got > 0);
            frames += @intCast(got);
            for (samples[0..@as(usize, @intCast(got * info.channels))]) |sample| {
                if (sample != 0) nonzero = true;
            }
        }
        try testing.expect(frames > 0 and nonzero);
        try testing.expectEqual(@as(c_int, 1), omori_audio_seek_start(decoder));
        try testing.expect(omori_audio_read(decoder, info.channels, &samples, samples.len) > 0);
    }
}

test "mixer: malformed audio headers are rejected" {
    const invalid = .{ "", "OggS", "ID3xxx", "\xff\xfb\x90\x00", "RIFF\x10\x00\x00\x00WAVE" };
    inline for (invalid) |bytes| {
        var code: c_int = 0;
        const decoder = omori_audio_open_memory(bytes, @intCast(bytes.len), &code, null);
        if (decoder) |d| omori_audio_close(d);
        try testing.expect(decoder == null);
    }
}

test "mixer: BGS resolves and stops independently of BGM" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("audio/bgm");
    try tmp.dir.makePath("audio/bgs");
    // Generated 440 Hz sine; no game data is needed by this regression.
    const tone = @embedFile("test-tone.ogg");
    try tmp.dir.writeFile(.{ .sub_path = "audio/bgm/music.ogg", .data = tone });
    try tmp.dir.writeFile(.{ .sub_path = "audio/bgs/ambient.ogg", .data = tone });
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    var vfs = vfs_mod.Vfs.init(testing.allocator, root, root);
    defer vfs.deinit();
    var m = Mixer{ .alloc = testing.allocator, .lib = undefined, .vfs = &vfs };
    defer m.deinit();

    m.playBgm("music", 80, 100);
    try testing.expect(m.bgm != null);
    const music_decoder = m.bgm.?.dec;
    m.playBgs("ambient", 50, 100);
    try testing.expect(m.bgs != null);
    try testing.expectEqual(music_decoder, m.bgm.?.dec);
    try testing.expect(m.bgs.?.dec != music_decoder);
    try testing.expectApproxEqAbs(@as(f32, 0.5), m.bgs.?.volume, 0.0001);
    try testing.expectEqual(@as(f32, 1), m.bgs.?.fade_volume);

    // A looping BGS must actually decode non-silent samples.
    try testing.expect(m.mixBgm(&m.bgs.?));
    var peak: i32 = 0;
    for (m.acc) |frame| peak = @max(peak, frame[0]);
    try testing.expect(peak > 100);

    m.stopBgs(3000);
    try testing.expect(m.bgs.?.fade_stop);
    try testing.expect(!m.bgm.?.fade_stop);
    // Three seconds is about 129 chunks, rather than the old 50 ms.
    try testing.expectApproxEqAbs(@as(f32, -1024.0 / (3.0 * 44100.0)), m.bgs.?.fade_step, 0.000001);
    var chunks: usize = 0;
    while (m.bgs != null and chunks < 140) : (chunks += 1) {
        if (!m.mixBgm(&m.bgs.?)) m.bgs = null;
    }
    try testing.expect(chunks >= 128 and chunks <= 131);
    try testing.expect(m.bgs == null);
    try testing.expectEqual(music_decoder, m.bgm.?.dec);

    m.playBgs("ambient", 90, 100);
    const ambient_decoder = m.bgs.?.dec;
    m.stopBgm(0);
    try testing.expect(m.bgm == null);
    try testing.expectEqual(ambient_decoder, m.bgs.?.dec);
    m.playBgs("", 90, 100);
    try testing.expect(m.bgs == null);
}

test "mixer: save/replay round-trips the request (MV AudioManager)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("audio/bgm");
    try tmp.dir.makePath("audio/bgs");
    const tone = @embedFile("test-tone.ogg");
    try tmp.dir.writeFile(.{ .sub_path = "audio/bgm/map_a.ogg", .data = tone });
    try tmp.dir.writeFile(.{ .sub_path = "audio/bgm/map_b.ogg", .data = tone });
    try tmp.dir.writeFile(.{ .sub_path = "audio/bgs/ambient.ogg", .data = tone });
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    var vfs = vfs_mod.Vfs.init(testing.allocator, root, root);
    defer vfs.deinit();
    var m = Mixer{ .alloc = testing.allocator, .lib = undefined, .vfs = &vfs };
    defer m.deinit();

    // saveBgm on a silent channel → the empty object
    const empty = m.saveLoop(.bgm);
    try testing.expectEqualStrings("", empty.name);
    try testing.expectEqual(@as(u32, 0), empty.volume);

    // play + save → the request round-trips (volume/pitch/pan)
    m.playBgmPan("map_a", 70, 130, 40);
    const saved = m.saveLoop(.bgm);
    try testing.expectEqualStrings("map_a", saved.name);
    try testing.expectEqual(@as(u32, 70), saved.volume);
    try testing.expectEqual(@as(u32, 130), saved.pitch);
    try testing.expectEqual(@as(u32, 40), saved.pan);

    // replay same-name → parameters only, the decoder does NOT restart
    const decoder_a = m.bgm.?.dec;
    m.replayLoop(.bgm, saved);
    try testing.expectEqual(decoder_a, m.bgm.?.dec);
    try testing.expectEqual(@as(f32, 1), m.bgm.?.fade_volume);

    // replay different-name → restart + 0.5 s fade-in (30 chunks @ 44.1k)
    m.replayLoop(.bgm, .{ .name = "map_b", .volume = 90, .pitch = 100 });
    try testing.expect(m.bgm != null);
    try testing.expectEqualStrings("map_b", m.bgm.?.name);
    try testing.expectEqual(@as(f32, 0), m.bgm.?.fade_volume);
    try testing.expect(m.bgm.?.fade_step > 0);
    try testing.expect(!m.bgm.?.fade_stop);

    // replayBgs with an empty snapshot stops the channel (playBgm(''))
    m.playBgs("ambient", 50, 100);
    try testing.expect(m.bgs != null);
    m.replayLoop(.bgs, .{});
    try testing.expect(m.bgs == null);

    // another save on the playing channel → a fresh coherent view
    // (the previous view is stale by contract and must not be reused).
    const saved2 = m.saveLoop(.bgm);
    try testing.expectEqualStrings("map_b", saved2.name);
    try testing.expectEqual(@as(u32, 90), saved2.volume);

    // save on a silent channel → the empty object
    m.stopBgm(0);
    const silent = m.saveLoop(.bgm);
    try testing.expectEqualStrings("", silent.name);
    try testing.expectEqual(@as(u32, 0), silent.volume);
}

test "mixer: ME plays once and resumes BGM while BGS continues" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    inline for (.{ "bgm", "bgs", "me" }) |folder| {
        try tmp.dir.makePath("audio/" ++ folder);
        try tmp.dir.writeFile(.{ .sub_path = "audio/" ++ folder ++ "/tone.ogg", .data = @embedFile("test-tone.ogg") });
    }
    const root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(root);
    var vfs = vfs_mod.Vfs.init(testing.allocator, root, root);
    defer vfs.deinit();
    const FakeQueue = struct {
        fn queue(_: u32, _: ?*const anyopaque, _: u32) callconv(.c) c_int {
            return 0;
        }
    };
    var lib: sdl.Sdl2 = undefined;
    lib.QueueAudio = FakeQueue.queue;
    var m = Mixer{ .alloc = testing.allocator, .lib = &lib, .vfs = &vfs, .enabled = true };
    defer m.deinit();
    m.playBgm("tone", 80, 100);
    m.playBgs("tone", 50, 100);
    m.produceChunk();
    const music_decoder = m.bgm.?.dec;
    const music_position = m.bgm.?.src_pos;
    const ambient_position = m.bgs.?.src_pos;
    m.playMe("tone", 90, 100);
    try testing.expect(m.me.active);
    // The generated tone is exactly 0.1 seconds. No uninitialized tail.
    try testing.expectEqual(@as(usize, 4410 * 2), m.me.pcm.len);
    m.produceChunk();
    try testing.expectEqual(music_position, m.bgm.?.src_pos);
    try testing.expect(m.bgs.?.src_pos != ambient_position);
    m.stopSe();
    try testing.expect(m.me.active);
    var chunks: usize = 1;
    while (m.me.active and chunks < 10) : (chunks += 1) m.produceChunk();
    try testing.expectEqual(@as(usize, 5), chunks);
    try testing.expect(!m.me.active);
    try testing.expectEqual(@as(usize, 0), m.me.pcm.len);
    try testing.expectEqual(music_decoder, m.bgm.?.dec);
    try testing.expectEqual(music_position, m.bgm.?.src_pos);
    try testing.expectEqual(@as(f32, 0), m.bgm.?.fade_volume);
    m.produceChunk();
    try testing.expect(m.bgm.?.src_pos != music_position);
    try testing.expect(m.bgm.?.fade_volume > 0);
    // A replacement empty request stops ME and resumes the same BGM.
    m.playMe("tone", 100, 100);
    m.playMe("", 100, 100);
    try testing.expect(!m.me.active);
    try testing.expectEqual(music_decoder, m.bgm.?.dec);
}

test "mixer: optional real files queue PCM through SDL" {
    // Set OMORI_AUDIO_SMOKE_ROOT to a user-supplied extracted assets/www.
    // SDL_AUDIODRIVER=dummy makes this deterministic without speakers.
    const root = std.process.getEnvVarOwned(testing.allocator, "OMORI_AUDIO_SMOKE_ROOT") catch return error.SkipZigTest;
    defer testing.allocator.free(root);
    var vfs = vfs_mod.Vfs.init(testing.allocator, root, root);
    defer vfs.deinit();
    var lib = sdl.Sdl2.load(testing.allocator) orelse return error.SdlUnavailable;
    try testing.expectEqual(@as(c_int, 0), lib.Init(0));
    defer lib.Quit();
    var m = Mixer.init(testing.allocator, &lib, &vfs);
    defer m.deinit();
    try testing.expect(m.enabled);
    lib.PauseAudioDevice(m.dev, 1);
    m.playBgm("user_title", 80, 100);
    try testing.expect(m.bgm != null);
    const music_decoder = m.bgm.?.dec;
    const ambient_names = [_][]const u8{ "AMB_SLIDE", "BGS_abstract_echo" };
    for (ambient_names) |name| {
        m.playBgs(name, 90, 100);
        try testing.expect(m.bgs != null);
        try testing.expectEqual(music_decoder, m.bgm.?.dec);
        // Isolate BGS output by muting BGM without altering its state.
        m.bgm.?.volume = 0;
        var peak: u16 = 0;
        for (0..256) |_| {
            m.produceChunk();
            for (m.out) |sample| peak = @max(peak, @abs(sample));
        }
        try testing.expect(peak > 100);
        try testing.expect(lib.GetQueuedAudioSize(m.dev) > 0);
        std.debug.print("real BGS {s}: peak={d}, queued={d} bytes\n", .{ name, peak, lib.GetQueuedAudioSize(m.dev) });
        lib.ClearQueuedAudio(m.dev);
    }
    m.playMe("xx_victory", 90, 100);
    try testing.expect(m.me.active);
    const paused_position = m.bgm.?.src_pos;
    var chunks: usize = 0;
    var peak: u16 = 0;
    m.stopBgs(0);
    while (m.me.active and chunks < 2048) : (chunks += 1) {
        m.produceChunk();
        for (m.out) |sample| peak = @max(peak, @abs(sample));
    }
    try testing.expect(!m.me.active);
    try testing.expect(chunks > 0 and chunks < 2048);
    try testing.expect(peak > 100);
    try testing.expectEqual(paused_position, m.bgm.?.src_pos);
    try testing.expectEqual(music_decoder, m.bgm.?.dec);
    std.debug.print("real ME xx_victory: peak={d}, chunks={d}, BGM position preserved\n", .{ peak, chunks });
}

test "decode: vorbis fixture decodes to device-rate stereo pcm" {
    const alloc = testing.allocator;
    const path = "/tmp/omori-mixer-test/se.ogg";
    const bytes = std.fs.cwd().readFileAlloc(alloc, path, 1024 * 1024) catch return; // skip without fixture
    defer alloc.free(bytes);
    const pcm = decodeToPcm(alloc, bytes, 44100) orelse return error.TestUnexpectedResult;
    defer alloc.free(pcm);
    try testing.expect(pcm.len >= 2);
    // stereo interleave: a mono/stereo source still yields 2 samples per frame
    try testing.expect(pcm.len % 2 == 0);
    // a sine fixture must produce non-silent audio
    var peak: i32 = 0;
    for (pcm) |s| peak = @max(peak, @as(i32, s));
    try testing.expect(peak > 1000);
}
