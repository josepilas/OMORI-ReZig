//! SDL2 loaded at runtime through dlopen — zero link-time dependency.
//!
//! Rationale (architectural pivot §15/§20): PortMaster supplies SDL2
//! through its runtime system on the device, and the development machine
//! may not carry the dev headers at all. dlopen also gives the runtime a
//! graceful headless fallback (validation mode) when no library/display is
//! present, which is exactly how the deterministic test battery runs.
//!
//! Only the surface OMORI actually needs is bound: window, renderer,
//! events (keyboard + game controller), timing. Browser-canvas emulation
//! is explicitly NOT a goal — the original JavaScript renderer remains a
//! behavioral reference only.

const std = @import("std");
const dyn = @import("dyn.zig");

pub const INIT_TIMER: u32 = 0x0000_0001;
pub const INIT_AUDIO: u32 = 0x0000_0010;
pub const INIT_VIDEO: u32 = 0x0000_0020;
pub const INIT_JOYSTICK: u32 = 0x0000_0200;
pub const INIT_GAMECONTROLLER: u32 = 0x0000_2000;
pub const INIT_EVENTS: u32 = 0x0000_4000;

pub const WINDOWPOS_CENTERED: i32 = 0x1FFF_0000;

// SDL_WindowFlags (v29: the v28 bug — 0x4 was SDL_WINDOW_SHOWN while the
// comment claimed OPENGL; the OPENGL flag is 0x2 and is REQUIRED for the
// GLES2/accelerated renderer to attach).
pub const WINDOW_OPENGL: u32 = 0x0000_0002;
pub const WINDOW_SHOWN: u32 = 0x0000_0004;
pub const WINDOW_FULLSCREEN_DESKTOP: u32 = 0x0000_1001;

pub const ACCELERATED: u32 = 0x0000_0002;
pub const PRESENTVSYNC: u32 = 0x0000_0010;

/// SDL_PIXELFORMAT_ABGR8888 — v29 bug fix: the v28 constant 0x28664067
/// was WRONG (SDL rejects it as "Unsupported YUV format", so EVERY
/// SDL_CreateTexture failed and only the clear color ever reached the
/// screen: the white-screen device report). The true value — verified
/// empirically against SDL 2.32's software renderer texture_formats —
/// is 0x16762004 (packed32, order ABGR=7, layout 8888=6, 32 bits, 4
/// bytes): components A,B,G,R from MSB of the native u32, i.e. memory
/// byte order R,G,B,A on little-endian, which is exactly our decoded
/// RGBA pixel layout.
pub const PIXELFORMAT_ABGR8888: u32 = 0x1676_2004;
/// SDL_TEXTUREACCESS_STREAMING.
pub const TEXTUREACCESS_STREAMING: c_int = 1;
/// SDL_BLENDMODE_BLEND.
pub const BLENDMODE_BLEND: u8 = 1;

// Event types (stable SDL2 ABI values).
//
// v30 — THE INPUT FIX: v29's controller constants were 0x64B/0x64C/0x64D
// — values that are NOT SDL event types at all. The v29 device run
// proved events ARRIVE (0x651/0x652 controller buttons, 0x603/0x604 joy
// buttons, 0x650/0x600 axes) but the dispatcher matched NOTHING, so the
// game was deaf: 328 events, zero menu moves, dead START+SELECT. The
// values below are the real SDL_events.h enum (0x600-series joystick,
// 0x650-series controller) — verified against SDL2 2.32.4 on the dev
// box AND the 2.32.10 KMSDRM build on the device.
pub const EVENT_QUIT: u32 = 0x100;
pub const EVENT_KEYDOWN: u32 = 0x300;
pub const EVENT_KEYUP: u32 = 0x301;
// Joystick (0x600 series) — the R36S's GO-Super Gamepad sends these for
// EVERYTHING; SELECT/START arrive ONLY here (not in the controller
// mapping — device evidence: joy 0x603/0x604 pairs without controller
// counterparts).
pub const EVENT_JOYAXISMOTION: u32 = 0x600;
pub const EVENT_JOYBALLMOTION: u32 = 0x601;
pub const EVENT_JOYHATMOTION: u32 = 0x602;
pub const EVENT_JOYBUTTONDOWN: u32 = 0x603;
pub const EVENT_JOYBUTTONUP: u32 = 0x604;
pub const EVENT_JOYDEVICEADDED: u32 = 0x605;
pub const EVENT_JOYDEVICEREMOVED: u32 = 0x606;
// Game controller (0x650 series).
pub const EVENT_CONTROLLERAXISMOTION: u32 = 0x650;
pub const EVENT_CONTROLLERBUTTONDOWN: u32 = 0x651;
pub const EVENT_CONTROLLERBUTTONUP: u32 = 0x652;
pub const EVENT_CONTROLLERDEVICEADDED: u32 = 0x653;
pub const EVENT_CONTROLLERDEVICEREMOVED: u32 = 0x654;

// Hat bitmask (SDL_JoyHatEvent.value).
pub const HAT_UP: u8 = 0x01;
pub const HAT_RIGHT: u8 = 0x02;
pub const HAT_DOWN: u8 = 0x04;
pub const HAT_LEFT: u8 = 0x08;

// Keycodes used by the OMORI control model (gptokeyb mapping evidence).
// v30: SDL2 keysym values — v29 carried SDL 1.2 numbers (273..) which
// SDL2 never emits (arrows/modifiers are 0x4000xxxx). Printable keys are
// ASCII in both.
pub const K_RETURN: i32 = 13;
pub const K_ESCAPE: i32 = 27;
pub const K_SPACE: i32 = 32;
pub const K_UP: i32 = 0x4000_0052;
pub const K_DOWN: i32 = 0x4000_0051;
pub const K_RIGHT: i32 = 0x4000_0050;
pub const K_LEFT: i32 = 0x4000_004F;
pub const K_LSHIFT: i32 = 0x4000_00E1;
pub const K_RSHIFT: i32 = 0x4000_00E5;
pub const K_F12: i32 = 0x4000_0045;
pub const K_A: i32 = 97;
pub const K_Q: i32 = 113;
pub const K_W: i32 = 119;
pub const K_LCTRL: i32 = 0x4000_00E0;
pub const K_Z: i32 = 122;
pub const K_X: i32 = 120;
pub const K_L: i32 = 108;
pub const K_R: i32 = 114;

// Game controller buttons (SDL2 ABI order).
pub const CB_A: u8 = 0;
pub const CB_B: u8 = 1;
pub const CB_X: u8 = 2;
pub const CB_Y: u8 = 3;
pub const CB_BACK: u8 = 4;
pub const CB_GUIDE: u8 = 5;
pub const CB_START: u8 = 6;
pub const CB_LEFTSTICK: u8 = 7;
pub const CB_RIGHTSTICK: u8 = 8;
pub const CB_LEFTSHOULDER: u8 = 9;
pub const CB_RIGHTSHOULDER: u8 = 10;
pub const CB_DPUP: u8 = 11;
pub const CB_DPDOWN: u8 = 12;
pub const CB_DPLEFT: u8 = 13;
pub const CB_DPRIGHT: u8 = 14;

/// SDL_RendererInfo (SDL2 ABI: name ptr + flags + 32 mod + max w/h).
pub const RendererInfo = extern struct {
    name: ?[*:0]const u8,
    flags: u32,
    num_texture_formats: u32,
    texture_formats: [16]u32,
    max_texture_width: c_int,
    max_texture_height: c_int,
};

/// SDL_AudioSpec — the queue-mode (callback = null) output contract.
pub const AudioSpec = extern struct {
    freq: c_int,
    format: u16,
    channels: u8,
    silence: u8,
    samples: u16,
    padding: u16,
    size: u32,
    callback: ?*const fn (?*anyopaque, [*]u8, u32) callconv(.c) void,
    userdata: ?*anyopaque,
};

/// AUDIO_S16LSB (0x8010) + AUDIO_ALLOW_* flags for OpenAudioDevice.
pub const AUDIO_S16LSB: u16 = 0x8010;
pub const AUDIO_ALLOW_FREQUENCY_CHANGE: c_int = 0x01;
pub const AUDIO_ALLOW_SAMPLES_CHANGE: c_int = 0x08;

/// SDL_version (3 x u8).
pub const Version = extern struct {
    major: u8,
    minor: u8,
    patch: u8,
};

pub const Keysym = extern struct {
    scancode: i32,
    sym: i32,
    mod: u16,
    unused: u32,
};

pub const KeyEvent = extern struct {
    type: u32,
    timestamp: u32,
    windowID: u32,
    state: u8,
    repeat: u8,
    padding2: [2]u8,
    keysym: Keysym,
};

pub const ControllerButtonEvent = extern struct {
    type: u32,
    timestamp: u32,
    which: i32,
    button: u8,
    state: u8,
    padding1: u8,
    padding2: u8,
};

/// SDL_JoyButtonEvent — same ABI layout as the controller variant
/// (SDL_events.h: type, timestamp, which, button, state, pad).
pub const JoyButtonEvent = extern struct {
    type: u32,
    timestamp: u32,
    which: i32,
    button: u8,
    state: u8,
    padding1: u8,
    padding2: u8,
};

/// SDL_JoyHatEvent — hat index + 4-bit direction mask.
pub const JoyHatEvent = extern struct {
    type: u32,
    timestamp: u32,
    which: i32,
    hat: u8,
    value: u8,
    padding1: u8,
    padding2: u8,
};

/// SDL_ControllerAxisEvent — axis u8 at offset 12, value i16 at 16.
pub const ControllerAxisEvent = extern struct {
    type: u32,
    timestamp: u32,
    which: i32,
    axis: u8,
    padding1: u8,
    padding2: u8,
    padding3: u8,
    value: i16,
    padding4: u16,
};

/// SDL_JoyAxisEvent — same shape, value i16 at offset 16 after
/// padding (SDL2 ≥ 2.0.10 ABI on 64-bit: type, ts, which, axis u8,
/// padding[3], value i16).
pub const JoyAxisEvent = extern struct {
    type: u32,
    timestamp: u32,
    which: i32,
    axis: u8,
    padding1: u8,
    padding2: u8,
    padding3: u8,
    value: i16,
    padding4: u16,
};

pub const CommonEvent = extern struct {
    type: u32,
    timestamp: u32,
};

/// SDL_Event is a 56-byte union in SDL2.
pub const Event = extern union {
    type: u32,
    key: KeyEvent,
    cbutton: ControllerButtonEvent,
    caxis: ControllerAxisEvent,
    jbutton: JoyButtonEvent,
    jhat: JoyHatEvent,
    jaxis: JoyAxisEvent,
    common: CommonEvent,
    padding: [56]u8,
};

pub const Rect = extern struct {
    x: i32,
    y: i32,
    w: i32,
    h: i32,
};

pub const Point = extern struct { x: c_int, y: c_int };

pub const Sdl2 = struct {
    handle: *anyopaque,

    // Function table (bound once at load).
    Init: *const fn (flags: u32) callconv(.c) c_int,
    Quit: *const fn () callconv(.c) void,
    GetError: *const fn () callconv(.c) [*:0]const u8,
    CreateWindow: *const fn ([*:0]const u8, x: i32, y: i32, w: c_int, h: c_int, flags: u32) callconv(.c) ?*anyopaque,
    DestroyWindow: *const fn (?*anyopaque) callconv(.c) void,
    CreateRenderer: *const fn (?*anyopaque, idx: c_int, flags: u32) callconv(.c) ?*anyopaque,
    DestroyRenderer: *const fn (?*anyopaque) callconv(.c) void,
    SetRenderDrawColor: *const fn (?*anyopaque, r: u8, g: u8, b: u8, a: u8) callconv(.c) c_int,
    RenderClear: *const fn (?*anyopaque) callconv(.c) c_int,
    RenderFillRect: *const fn (?*anyopaque, ?*const Rect) callconv(.c) c_int,
    RenderPresent: *const fn (?*anyopaque) callconv(.c) void,
    RenderSetLogicalSize: *const fn (?*anyopaque, w: c_int, h: c_int) callconv(.c) c_int,
    PollEvent: *const fn (*Event) callconv(.c) c_int,
    GetTicks: *const fn () callconv(.c) u32,
    Delay: *const fn (ms: u32) callconv(.c) void,
    NumJoysticks: *const fn () callconv(.c) c_int,
    JoystickOpen: *const fn (c_int) callconv(.c) ?*anyopaque,
    JoystickClose: *const fn (?*anyopaque) callconv(.c) void,
    JoystickInstanceID: *const fn (?*anyopaque) callconv(.c) i32,
    JoystickGetButton: *const fn (?*anyopaque, c_int) callconv(.c) u8,
    JoystickGetHat: *const fn (?*anyopaque, c_int) callconv(.c) u8,
    JoystickGetAxis: *const fn (?*anyopaque, c_int) callconv(.c) i16,
    JoystickNumButtons: *const fn (?*anyopaque) callconv(.c) c_int,
    JoystickNumAxes: *const fn (?*anyopaque) callconv(.c) c_int,
    JoystickNumHats: *const fn (?*anyopaque) callconv(.c) c_int,
    GameControllerOpen: *const fn (idx: c_int) callconv(.c) ?*anyopaque,
    GameControllerClose: *const fn (?*anyopaque) callconv(.c) void,
    GameControllerGetButton: *const fn (?*anyopaque, button: c_int) callconv(.c) u8,
    IsGameController: *const fn (idx: c_int) callconv(.c) c_int,
    // v28 interactive shell additions.
    GetWindowSize: *const fn (?*anyopaque, ?*c_int, ?*c_int) callconv(.c) void,
    SetRenderDrawBlendMode: *const fn (?*anyopaque, blend: c_int) callconv(.c) c_int,
    RenderFillRects: *const fn (?*anyopaque, [*]const Rect, count: c_int) callconv(.c) c_int,
    GameControllerGetAxis: *const fn (?*anyopaque, axis: c_int) callconv(.c) i16,
    SetHint: *const fn (name: [*:0]const u8, value: [*:0]const u8) callconv(.c) c_int,
    WasInit: *const fn (flags: u32) callconv(.c) u32,
    ClearError: *const fn () callconv(.c) void,
    // M6 sprite pipeline: textures + blit.
    CreateTexture: *const fn (?*anyopaque, format: u32, access: c_int, w: c_int, h: c_int) callconv(.c) ?*anyopaque,
    DestroyTexture: *const fn (?*anyopaque) callconv(.c) void,
    UpdateTexture: *const fn (?*anyopaque, ?*const Rect, pixels: ?*const anyopaque, pitch: c_int) callconv(.c) c_int,
    RenderCopy: *const fn (?*anyopaque, ?*anyopaque, ?*const Rect, ?*const Rect) callconv(.c) c_int,
    RenderCopyEx: *const fn (?*anyopaque, ?*anyopaque, ?*const Rect, ?*const Rect, f64, ?*const Point, c_int) callconv(.c) c_int,
    SetTextureBlendMode: *const fn (?*anyopaque, blend: c_int) callconv(.c) c_int,
    SetTextureAlphaMod: *const fn (?*anyopaque, alpha: u8) callconv(.c) c_int,
    /// v34: color mod + query (TEXT-DIAG-2 and identity-mod hygiene).
    SetTextureColorMod: *const fn (?*anyopaque, r: u8, g: u8, b: u8) callconv(.c) c_int,
    QueryTexture: *const fn (?*anyopaque, ?*u32, ?*c_int, ?*c_int, ?*c_int) callconv(.c) c_int,
    // v29 diagnostics: version, renderer info, controller names.
    GetVersion: *const fn (*Version) callconv(.c) void,
    GetRendererInfo: *const fn (?*anyopaque, *RendererInfo) callconv(.c) c_int,
    GameControllerName: *const fn (?*anyopaque) callconv(.c) ?[*:0]const u8,
    JoystickNameForIndex: *const fn (c_int) callconv(.c) ?[*:0]const u8,
    // v30 input fix: inject synthetic events (self-test on dev + qemu).
    PushEvent: *const fn (*Event) callconv(.c) c_int,
    PumpEvent: *const fn () callconv(.c) void,
    // v30: separate subsystem init so a broken audio driver can NEVER
    // take the video path down (SDL_Init is all-or-error).
    InitSubSystem: *const fn (u32) callconv(.c) c_int,
    QuitSubSystem: *const fn (u32) callconv(.c) void,
    // v30 audio milestone (M10) — queue-based output, no callback.
    OpenAudioDevice: *const fn (?[*:0]const u8, c_int, *const AudioSpec, ?*AudioSpec, c_int) callconv(.c) u32,
    CloseAudioDevice: *const fn (u32) callconv(.c) void,
    PauseAudioDevice: *const fn (u32, c_int) callconv(.c) void,
    QueueAudio: *const fn (u32, ?*const anyopaque, u32) callconv(.c) c_int,
    GetQueuedAudioSize: *const fn (u32) callconv(.c) u32,
    ClearQueuedAudio: *const fn (u32) callconv(.c) void,
    GetCurrentAudioDriver: *const fn () callconv(.c) ?[*:0]const u8,

    /// v28: the fixed candidate table (sonames + system absolute paths)
    /// plus a runtime probe of the port-local libs/ directory (derived
    /// from /proc/self/exe) and the $OMORI_SDL2 override. The v27 device
    /// failure — every dlopen returning "Dynamic loading not supported"
    /// — was the STATIC-musl binary itself, not the paths; v28 is
    /// dynamically linked against glibc so dlopen actually resolves
    /// dependencies. Candidates are still tried in order and every
    /// attempt + dlerror is logged for device-side diagnosis.
    pub const fixed_candidates = [_][:0]const u8{
        "libSDL2-2.0.so.0", // soname: ldconfig cache + LD_LIBRARY_PATH
        "/usr/lib/aarch64-linux-gnu/libSDL2-2.0.so.0",
        "/usr/lib/libSDL2-2.0.so.0",
        "/usr/local/lib/libSDL2-2.0.so.0",
        "/usr/lib/libSDL2-2.0.so.0",
        "libSDL2.so",
        "libSDL2-2.0.so.1",
    };

    /// dlopen SDL2 and bind the function table. Returns null when the
    /// library is unavailable (the caller decides headless vs fatal).
    pub fn load(alloc: std.mem.Allocator) ?Sdl2 {
        const log = @import("../core/log.zig");

        var tried: usize = 0;

        // 1. explicit override
        if (std.posix.getenv("OMORI_SDL2")) |path| {
            tried += 1;
            if (tryOne(alloc, path)) |sdl| return sdl;
        }

        // 2. fixed candidates
        inline for (fixed_candidates) |name| {
            tried += 1;
            if (tryOne(alloc, name)) |sdl| return sdl;
        }

        // 3. port-local bundled copy: <exe_dir>/../libs/libSDL2-2.0.so.0
        //    (bin/omori-native → omori/libs/). /proc/self/exe is read so
        //    the path is correct wherever the port is installed.
        if (selfExePortLibs(alloc)) |libs_dir| {
            defer alloc.free(libs_dir);
            const bundled = std.fmt.allocPrintSentinel(alloc, "{s}/libSDL2-2.0.so.0", .{libs_dir}, 0) catch null;
            if (bundled) |b| {
                defer alloc.free(b);
                tried += 1;
                if (tryOne(alloc, b)) |sdl| return sdl;
            }
            const bundled2 = std.fmt.allocPrintSentinel(alloc, "{s}/SDL2.so", .{libs_dir}, 0) catch null;
            if (bundled2) |b| {
                defer alloc.free(b);
                tried += 1;
                if (tryOne(alloc, b)) |sdl| return sdl;
            }
        }

        log.warn("SDL2: no candidate library could be opened ({d} tried)", .{tried});
        return null;
    }

    fn tryOne(alloc: std.mem.Allocator, name: []const u8) ?Sdl2 {
        const log = @import("../core/log.zig");
        const nameZ = alloc.dupeZ(u8, name) catch return null;
        defer alloc.free(nameZ);
        if (dyn.open(nameZ, dyn.RTLD_NOW)) |handle| {
            log.event(.gpu, .note, "SDL2 dlopen('{s}') OK", .{name});
            if (bind(alloc, handle, name)) |sdl| return sdl;
            log.warn("SDL2 dlopen('{s}') OK but symbol binding failed", .{name});
            return null;
        } else {
            log.event(.gpu, .note, "SDL2 dlopen('{s}') failed: {s}", .{ name, dyn.errorString() });
            return null;
        }
    }

    /// /proc/self/exe → <dir>/../libs (owned, caller frees).
    fn selfExePortLibs(alloc: std.mem.Allocator) ?[]u8 {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const self_exe = std.fs.cwd().readLink("/proc/self/exe", &buf) catch return null;
        const dir = std.fs.path.dirname(self_exe) orelse return null; // .../omori/bin
        const port_root = std.fs.path.dirname(dir) orelse return null; // .../omori
        return std.fs.path.join(alloc, &.{ port_root, "libs" }) catch null;
    }

    fn bind(alloc: std.mem.Allocator, handle: *anyopaque, name: []const u8) ?Sdl2 {
        _ = alloc;
        _ = name;

        // Each symbol must exist, else the whole load fails (a partially
        // bound SDL is worse than none).
        const S = struct {
            fn cast(comptime FnPtr: type, ptr: *anyopaque) FnPtr {
                return @ptrCast(@alignCast(ptr));
            }
        };

        const init_ptr = dyn.sym(handle, "SDL_Init") orelse return null;
        const quit_ptr = dyn.sym(handle, "SDL_Quit") orelse return null;
        const geterror_ptr = dyn.sym(handle, "SDL_GetError") orelse return null;
        const createwindow_ptr = dyn.sym(handle, "SDL_CreateWindow") orelse return null;
        const destroywindow_ptr = dyn.sym(handle, "SDL_DestroyWindow") orelse return null;
        const createrenderer_ptr = dyn.sym(handle, "SDL_CreateRenderer") orelse return null;
        const destroyrenderer_ptr = dyn.sym(handle, "SDL_DestroyRenderer") orelse return null;
        const setdrawcolor_ptr = dyn.sym(handle, "SDL_SetRenderDrawColor") orelse return null;
        const renderclear_ptr = dyn.sym(handle, "SDL_RenderClear") orelse return null;
        const renderfillrect_ptr = dyn.sym(handle, "SDL_RenderFillRect") orelse return null;
        const renderpresent_ptr = dyn.sym(handle, "SDL_RenderPresent") orelse return null;
        const renderlogical_ptr = dyn.sym(handle, "SDL_RenderSetLogicalSize") orelse return null;
        const pollevent_ptr = dyn.sym(handle, "SDL_PollEvent") orelse return null;
        const getticks_ptr = dyn.sym(handle, "SDL_GetTicks") orelse return null;
        const delay_ptr = dyn.sym(handle, "SDL_Delay") orelse return null;
        const getwindowsize_ptr = dyn.sym(handle, "SDL_GetWindowSize") orelse return null;
        const setblendmode_ptr = dyn.sym(handle, "SDL_SetRenderDrawBlendMode") orelse return null;
        const fillrects_ptr = dyn.sym(handle, "SDL_RenderFillRects") orelse return null;
        const gcgetaxis_ptr = dyn.sym(handle, "SDL_GameControllerGetAxis") orelse return null;
        const sethint_ptr = dyn.sym(handle, "SDL_SetHint") orelse return null;
        const wasinit_ptr = dyn.sym(handle, "SDL_WasInit") orelse return null;
        const clearerror_ptr = dyn.sym(handle, "SDL_ClearError") orelse return null;
        const numjoysticks_ptr = dyn.sym(handle, "SDL_NumJoysticks") orelse return null;
        const JoystickOpen_ptr = dyn.sym(handle, "SDL_JoystickOpen") orelse return null;
        const JoystickClose_ptr = dyn.sym(handle, "SDL_JoystickClose") orelse return null;
        const JoystickInstanceID_ptr = dyn.sym(handle, "SDL_JoystickInstanceID") orelse return null;
        const JoystickGetButton_ptr = dyn.sym(handle, "SDL_JoystickGetButton") orelse return null;
        const JoystickGetHat_ptr = dyn.sym(handle, "SDL_JoystickGetHat") orelse return null;
        const JoystickGetAxis_ptr = dyn.sym(handle, "SDL_JoystickGetAxis") orelse return null;
        const JoystickNumButtons_ptr = dyn.sym(handle, "SDL_JoystickNumButtons") orelse return null;
        const JoystickNumAxes_ptr = dyn.sym(handle, "SDL_JoystickNumAxes") orelse return null;
        const JoystickNumHats_ptr = dyn.sym(handle, "SDL_JoystickNumHats") orelse return null;
        const gcopen_ptr = dyn.sym(handle, "SDL_GameControllerOpen") orelse return null;
        const gcclose_ptr = dyn.sym(handle, "SDL_GameControllerClose") orelse return null;
        const gcgetbutton_ptr = dyn.sym(handle, "SDL_GameControllerGetButton") orelse return null;
        const isgc_ptr = dyn.sym(handle, "SDL_IsGameController") orelse return null;
        const createtexture_ptr = dyn.sym(handle, "SDL_CreateTexture") orelse return null;
        const destroytexture_ptr = dyn.sym(handle, "SDL_DestroyTexture") orelse return null;
        const updatetexture_ptr = dyn.sym(handle, "SDL_UpdateTexture") orelse return null;
        const rendercopy_ptr = dyn.sym(handle, "SDL_RenderCopy") orelse return null;
        const setblend_ptr = dyn.sym(handle, "SDL_SetTextureBlendMode") orelse return null;
        const setalpha_ptr = dyn.sym(handle, "SDL_SetTextureAlphaMod") orelse return null;
        const setcolormod_ptr = dyn.sym(handle, "SDL_SetTextureColorMod") orelse return null;
        const querytexture_ptr = dyn.sym(handle, "SDL_QueryTexture") orelse return null;
        // v29: optional diagnostics symbols — the function table keeps
        // working on old SDL2 builds when these are absent.
        const getversion_ptr = dyn.sym(handle, "SDL_GetVersion");
        const getrendererinfo_ptr = dyn.sym(handle, "SDL_GetRendererInfo");
        const gcname_ptr = dyn.sym(handle, "SDL_GameControllerName");
        const joyname_ptr = dyn.sym(handle, "SDL_JoystickNameForIndex");
        // v30: PushEvent (input self-test) + audio (M10). PushEvent is
        // SDL2-core-forever; audio symbols are optional so a stripped
        // SDL2 still loads the video path.
        const pushevent_ptr = dyn.sym(handle, "SDL_PushEvent");
        const pumpevent_ptr = dyn.sym(handle, "SDL_PumpEvents");
        const initsub_ptr = dyn.sym(handle, "SDL_InitSubSystem");
        const quitsub_ptr = dyn.sym(handle, "SDL_QuitSubSystem");
        const openaudio_ptr = dyn.sym(handle, "SDL_OpenAudioDevice");
        const closeaudio_ptr = dyn.sym(handle, "SDL_CloseAudioDevice");
        const pauseaudio_ptr = dyn.sym(handle, "SDL_PauseAudioDevice");
        const queueaudio_ptr = dyn.sym(handle, "SDL_QueueAudio");
        const getqueued_ptr = dyn.sym(handle, "SDL_GetQueuedAudioSize");
        const clearqueued_ptr = dyn.sym(handle, "SDL_ClearQueuedAudio");
        const curaudio_ptr = dyn.sym(handle, "SDL_GetCurrentAudioDriver");

        const Fn = struct {
            const InitFn = *const fn (u32) callconv(.c) c_int;
            const QuitFn = *const fn () callconv(.c) void;
            const GetErrorFn = *const fn () callconv(.c) [*:0]const u8;
            const CreateWindowFn = *const fn ([*:0]const u8, i32, i32, c_int, c_int, u32) callconv(.c) ?*anyopaque;
            const DestroyWindowFn = *const fn (?*anyopaque) callconv(.c) void;
            const CreateRendererFn = *const fn (?*anyopaque, c_int, u32) callconv(.c) ?*anyopaque;
            const DestroyRendererFn = *const fn (?*anyopaque) callconv(.c) void;
            const SetColorFn = *const fn (?*anyopaque, u8, u8, u8, u8) callconv(.c) c_int;
            const ClearFn = *const fn (?*anyopaque) callconv(.c) c_int;
            const FillRectFn = *const fn (?*anyopaque, ?*const Rect) callconv(.c) c_int;
            const PresentFn = *const fn (?*anyopaque) callconv(.c) void;
            const LogicalSizeFn = *const fn (?*anyopaque, c_int, c_int) callconv(.c) c_int;
            const PollEventFn = *const fn (*Event) callconv(.c) c_int;
            const GetTicksFn = *const fn () callconv(.c) u32;
            const DelayFn = *const fn (u32) callconv(.c) void;
            const NumJoysticksFn = *const fn () callconv(.c) c_int;
            const GetWindowSizeFn = *const fn (?*anyopaque, ?*c_int, ?*c_int) callconv(.c) void;
            const SetBlendModeFn = *const fn (?*anyopaque, c_int) callconv(.c) c_int;
            const FillRectsFn = *const fn (?*anyopaque, [*]const Rect, c_int) callconv(.c) c_int;
            const GcGetAxisFn = *const fn (?*anyopaque, c_int) callconv(.c) i16;
            const SetHintFn = *const fn ([*:0]const u8, [*:0]const u8) callconv(.c) c_int;
            const WasInitFn = *const fn (u32) callconv(.c) u32;
            const ClearErrorFn = *const fn () callconv(.c) void;
            const GcOpenFn = *const fn (c_int) callconv(.c) ?*anyopaque;
            const GcCloseFn = *const fn (?*anyopaque) callconv(.c) void;
            const GcGetButtonFn = *const fn (?*anyopaque, c_int) callconv(.c) u8;
            const IsGcFn = *const fn (c_int) callconv(.c) c_int;
            const CreateTextureFn = *const fn (?*anyopaque, u32, c_int, c_int, c_int) callconv(.c) ?*anyopaque;
            const DestroyTextureFn = *const fn (?*anyopaque) callconv(.c) void;
            const UpdateTextureFn = *const fn (?*anyopaque, ?*const Rect, ?*const anyopaque, c_int) callconv(.c) c_int;
            const RenderCopyFn = *const fn (?*anyopaque, ?*anyopaque, ?*const Rect, ?*const Rect) callconv(.c) c_int;
            const SetBlendFn = *const fn (?*anyopaque, c_int) callconv(.c) c_int;
            const SetAlphaFn = *const fn (?*anyopaque, u8) callconv(.c) c_int;
            const SetColorModFn = *const fn (?*anyopaque, u8, u8, u8) callconv(.c) c_int;
            const QueryTextureFn = *const fn (?*anyopaque, ?*u32, ?*c_int, ?*c_int, ?*c_int) callconv(.c) c_int;
            const GetVersionFn = *const fn (*Version) callconv(.c) void;
            const GetRendererInfoFn = *const fn (?*anyopaque, *RendererInfo) callconv(.c) c_int;
            const GcNameFn = *const fn (?*anyopaque) callconv(.c) ?[*:0]const u8;
            const JoyNameFn = *const fn (c_int) callconv(.c) ?[*:0]const u8;
            const PushEventFn = *const fn (*Event) callconv(.c) c_int;
            const PumpEventFn = *const fn () callconv(.c) void;
            const InitSubSystemFn = *const fn (u32) callconv(.c) c_int;
            const QuitSubSystemFn = *const fn (u32) callconv(.c) void;
            const OpenAudioDeviceFn = *const fn (?[*:0]const u8, c_int, *const AudioSpec, ?*AudioSpec, c_int) callconv(.c) u32;
            const CloseAudioDeviceFn = *const fn (u32) callconv(.c) void;
            const PauseAudioDeviceFn = *const fn (u32, c_int) callconv(.c) void;
            const QueueAudioFn = *const fn (u32, ?*const anyopaque, u32) callconv(.c) c_int;
            const GetQueuedAudioSizeFn = *const fn (u32) callconv(.c) u32;
            const ClearQueuedAudioFn = *const fn (u32) callconv(.c) void;
            const GetCurrentAudioDriverFn = *const fn () callconv(.c) ?[*:0]const u8;
        };

        return .{
            .handle = handle,
            .Init = S.cast(Fn.InitFn, init_ptr),
            .Quit = S.cast(Fn.QuitFn, quit_ptr),
            .GetError = S.cast(Fn.GetErrorFn, geterror_ptr),
            .CreateWindow = S.cast(Fn.CreateWindowFn, createwindow_ptr),
            .DestroyWindow = S.cast(Fn.DestroyWindowFn, destroywindow_ptr),
            .CreateRenderer = S.cast(Fn.CreateRendererFn, createrenderer_ptr),
            .DestroyRenderer = S.cast(Fn.DestroyRendererFn, destroyrenderer_ptr),
            .SetRenderDrawColor = S.cast(Fn.SetColorFn, setdrawcolor_ptr),
            .RenderClear = S.cast(Fn.ClearFn, renderclear_ptr),
            .RenderFillRect = S.cast(Fn.FillRectFn, renderfillrect_ptr),
            .RenderPresent = S.cast(Fn.PresentFn, renderpresent_ptr),
            .RenderSetLogicalSize = S.cast(Fn.LogicalSizeFn, renderlogical_ptr),
            .PollEvent = S.cast(Fn.PollEventFn, pollevent_ptr),
            .GetTicks = S.cast(Fn.GetTicksFn, getticks_ptr),
            .Delay = S.cast(Fn.DelayFn, delay_ptr),
            .NumJoysticks = S.cast(Fn.NumJoysticksFn, numjoysticks_ptr),
            .JoystickOpen = S.cast(*const fn (c_int) callconv(.c) ?*anyopaque, JoystickOpen_ptr),
            .JoystickClose = S.cast(*const fn (?*anyopaque) callconv(.c) void, JoystickClose_ptr),
            .JoystickInstanceID = S.cast(*const fn (?*anyopaque) callconv(.c) i32, JoystickInstanceID_ptr),
            .JoystickGetButton = S.cast(*const fn (?*anyopaque, c_int) callconv(.c) u8, JoystickGetButton_ptr),
            .JoystickGetHat = S.cast(*const fn (?*anyopaque, c_int) callconv(.c) u8, JoystickGetHat_ptr),
            .JoystickGetAxis = S.cast(*const fn (?*anyopaque, c_int) callconv(.c) i16, JoystickGetAxis_ptr),
            .JoystickNumButtons = S.cast(*const fn (?*anyopaque) callconv(.c) c_int, JoystickNumButtons_ptr),
            .JoystickNumAxes = S.cast(*const fn (?*anyopaque) callconv(.c) c_int, JoystickNumAxes_ptr),
            .JoystickNumHats = S.cast(*const fn (?*anyopaque) callconv(.c) c_int, JoystickNumHats_ptr),
            .GameControllerOpen = S.cast(Fn.GcOpenFn, gcopen_ptr),
            .GameControllerClose = S.cast(Fn.GcCloseFn, gcclose_ptr),
            .GameControllerGetButton = S.cast(Fn.GcGetButtonFn, gcgetbutton_ptr),
            .IsGameController = S.cast(Fn.IsGcFn, isgc_ptr),
            .GetWindowSize = S.cast(Fn.GetWindowSizeFn, getwindowsize_ptr),
            .SetRenderDrawBlendMode = S.cast(Fn.SetBlendModeFn, setblendmode_ptr),
            .RenderFillRects = S.cast(Fn.FillRectsFn, fillrects_ptr),
            .GameControllerGetAxis = S.cast(Fn.GcGetAxisFn, gcgetaxis_ptr),
            .SetHint = S.cast(Fn.SetHintFn, sethint_ptr),
            .WasInit = S.cast(Fn.WasInitFn, wasinit_ptr),
            .ClearError = S.cast(Fn.ClearErrorFn, clearerror_ptr),
            .CreateTexture = S.cast(Fn.CreateTextureFn, createtexture_ptr),
            .DestroyTexture = S.cast(Fn.DestroyTextureFn, destroytexture_ptr),
            .UpdateTexture = S.cast(Fn.UpdateTextureFn, updatetexture_ptr),
            .RenderCopy = S.cast(Fn.RenderCopyFn, rendercopy_ptr),
            .RenderCopyEx = @ptrCast(@alignCast(dyn.sym(handle, "SDL_RenderCopyEx") orelse return null)),
            .SetTextureBlendMode = S.cast(Fn.SetBlendFn, setblend_ptr),
            .SetTextureAlphaMod = S.cast(Fn.SetAlphaFn, setalpha_ptr),
            .SetTextureColorMod = S.cast(Fn.SetColorModFn, setcolormod_ptr),
            .QueryTexture = S.cast(Fn.QueryTextureFn, querytexture_ptr),
            .GetVersion = if (getversion_ptr) |p| S.cast(Fn.GetVersionFn, p) else defaultGetVersion,
            .GetRendererInfo = if (getrendererinfo_ptr) |p| S.cast(Fn.GetRendererInfoFn, p) else defaultGetRendererInfo,
            .GameControllerName = if (gcname_ptr) |p| S.cast(Fn.GcNameFn, p) else defaultGcName,
            .JoystickNameForIndex = if (joyname_ptr) |p| S.cast(Fn.JoyNameFn, p) else defaultJoyName,
            .PushEvent = if (pushevent_ptr) |p| S.cast(Fn.PushEventFn, p) else defaultPushEvent,
            .PumpEvent = if (pumpevent_ptr) |p| S.cast(Fn.PumpEventFn, p) else defaultPumpEvent,
            .InitSubSystem = if (initsub_ptr) |p| S.cast(Fn.InitSubSystemFn, p) else defaultInitSubSystem,
            .QuitSubSystem = if (quitsub_ptr) |p| S.cast(Fn.QuitSubSystemFn, p) else defaultQuitSubSystem,
            .OpenAudioDevice = if (openaudio_ptr) |p| S.cast(Fn.OpenAudioDeviceFn, p) else defaultOpenAudioDevice,
            .CloseAudioDevice = if (closeaudio_ptr) |p| S.cast(Fn.CloseAudioDeviceFn, p) else defaultCloseAudioDevice,
            .PauseAudioDevice = if (pauseaudio_ptr) |p| S.cast(Fn.PauseAudioDeviceFn, p) else defaultPauseAudioDevice,
            .QueueAudio = if (queueaudio_ptr) |p| S.cast(Fn.QueueAudioFn, p) else defaultQueueAudio,
            .GetQueuedAudioSize = if (getqueued_ptr) |p| S.cast(Fn.GetQueuedAudioSizeFn, p) else defaultGetQueuedAudioSize,
            .ClearQueuedAudio = if (clearqueued_ptr) |p| S.cast(Fn.ClearQueuedAudioFn, p) else defaultClearQueuedAudio,
            .GetCurrentAudioDriver = if (curaudio_ptr) |p| S.cast(Fn.GetCurrentAudioDriverFn, p) else defaultGetCurrentAudioDriver,
        };
    }

    // v29 stubs for optional symbols.
    fn defaultGetVersion(v: *Version) callconv(.c) void {
        v.* = .{ .major = 0, .minor = 0, .patch = 0 };
    }
    fn defaultGetRendererInfo(r: ?*anyopaque, info: *RendererInfo) callconv(.c) c_int {
        _ = r;
        info.* = .{ .name = null, .flags = 0, .num_texture_formats = 0, .texture_formats = @splat(0), .max_texture_width = 0, .max_texture_height = 0 };
        return 0;
    }
    fn defaultGcName(gc: ?*anyopaque) callconv(.c) ?[*:0]const u8 {
        _ = gc;
        return null;
    }
    fn defaultJoyName(idx: c_int) callconv(.c) ?[*:0]const u8 {
        _ = idx;
        return null;
    }
    // v30 stubs (SDL2 always has these; the stubs keep a hypothetical
    // stripped build loadable).
    fn defaultPushEvent(ev: *Event) callconv(.c) c_int {
        _ = ev;
        return 0;
    }
    fn defaultPumpEvent() callconv(.c) void {}
    fn defaultInitSubSystem(flags: u32) callconv(.c) c_int {
        _ = flags;
        return -1;
    }
    fn defaultQuitSubSystem(flags: u32) callconv(.c) void {
        _ = flags;
    }
    fn defaultOpenAudioDevice(device: ?[*:0]const u8, iscapture: c_int, desired: *const AudioSpec, obtained: ?*AudioSpec, changes: c_int) callconv(.c) u32 {
        _ = device;
        _ = iscapture;
        _ = desired;
        _ = obtained;
        _ = changes;
        return 0; // 0 = failure (SDL semantics)
    }
    fn defaultCloseAudioDevice(dev: u32) callconv(.c) void {
        _ = dev;
    }
    fn defaultPauseAudioDevice(dev: u32, pause: c_int) callconv(.c) void {
        _ = dev;
        _ = pause;
    }
    fn defaultQueueAudio(dev: u32, data: ?*const anyopaque, len: u32) callconv(.c) c_int {
        _ = dev;
        _ = data;
        _ = len;
        return -1;
    }
    fn defaultGetQueuedAudioSize(dev: u32) callconv(.c) u32 {
        _ = dev;
        return 0;
    }
    fn defaultClearQueuedAudio(dev: u32) callconv(.c) void {
        _ = dev;
    }
    fn defaultGetCurrentAudioDriver() callconv(.c) ?[*:0]const u8 {
        return null;
    }
};

test "event union layout matches SDL2 ABI sizes" {
    // SDL_Event is 56 bytes; our overlay must not exceed it.
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(Event));
    // KeyEvent layout: 4+4+4+1+1+2(pad)+Keysym(4+4+2+2pad=16) = 32 bytes.
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(KeyEvent));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Keysym));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(ControllerButtonEvent));
    // v30: joy + axis event ABI (SDL2 64-bit).
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(JoyButtonEvent));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(JoyHatEvent));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(ControllerAxisEvent));
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(JoyAxisEvent));
    // Field offsets: button at 12, value at 16 (axis).
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(ControllerButtonEvent, "button"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(JoyButtonEvent, "button"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(ControllerAxisEvent, "value"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(JoyAxisEvent, "value"));
}

test "v30: event type constants are the real SDL2 enum values" {
    // The v29 constants (0x64B/0x64C/0x64D) matched nothing — this test
    // pins the correct 0x600/0x650-series values forever.
    try std.testing.expectEqual(@as(u32, 0x651), EVENT_CONTROLLERBUTTONDOWN);
    try std.testing.expectEqual(@as(u32, 0x652), EVENT_CONTROLLERBUTTONUP);
    try std.testing.expectEqual(@as(u32, 0x653), EVENT_CONTROLLERDEVICEADDED);
    try std.testing.expectEqual(@as(u32, 0x650), EVENT_CONTROLLERAXISMOTION);
    try std.testing.expectEqual(@as(u32, 0x603), EVENT_JOYBUTTONDOWN);
    try std.testing.expectEqual(@as(u32, 0x604), EVENT_JOYBUTTONUP);
    try std.testing.expectEqual(@as(u32, 0x602), EVENT_JOYHATMOTION);
    try std.testing.expectEqual(@as(u32, 0x600), EVENT_JOYAXISMOTION);
    try std.testing.expectEqual(@as(u32, 0x605), EVENT_JOYDEVICEADDED);
}
