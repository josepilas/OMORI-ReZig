#!/bin/bash
# =============================================================================
#  OMORI  --  PortMaster port for R36S / RK3326
#  v32: THE TITLE-SCREEN CRASH FIX — the v31 SIGSEGV root-caused as a
#       DOUBLE FREE in Mixer.loadFileBytes (fixed + regression-pinned),
#       plus the crash-handler hardening (SA_ONSTACK alt stack +
#       maps-validated backtrace — no more silent exit-139 reports);
#       v31: THE D-PAD FIX (direction provenance + joy-button arbitration +
#       dual SELECT/START), the crash-handler double-fault fix, $dataSystem
#       SE names, and a thread-safe mixer allocator;
#       v30: THE INPUT FIX (real SDL event constants + joy fallback) + M10 AUDIO
#            (the v29 "title image shows, nothing responds" device report);
#            v29: the present fix (pixel format + GL window + watchdog)
#            v28: dynamic glibc + real SDL2 window + the interactive game shell
#
#        the game stopped opening at all):
#
#    Deterministic death right after "read 'audio/bgm/user_title.ogg'":
#    exit 139 (SIGSEGV), NO crash report, no panic lines — twice in a
#    row. The v31 handler fixes were proven working (--self-raise), so
#    a silent 139 meant the handler itself was dying.
#
#    ROOT CAUSE (reproduced + proven on x86 with a dedicated harness):
#      * Mixer.loadFileBytes did `defer self.alloc.free(path)` — but
#        AudioManager.resolve() returns the slice STORED IN ITS OWN
#        cache map, and `defer resolver.deinit()` walks that map and
#        frees the same pointer AGAIN. A DOUBLE FREE by construction.
#        v30 never crashed because the mixer used the ARENA (arena free
#        is a no-op that never unmaps). v31 gave the mixer the GPA —
#        the first free emptied the bucket page and the GPA UNMAPPED
#        it; the second free's unconditional Allocator.free poison
#        memset (@memset(ptr, undefined) = 0xaa × 24 bytes, exactly
#        len("audio/bgm/user_title.ogg")) wrote onto unmapped memory.
#      * The silent report: on the device the crash handler then
#        faulted during its own frame-pointer walk (the FP chain led
#        off the just-unmapped page), SA_RESETHAND handed the second
#        fault the default disposition, and the process died at 139
#        with the report lost. v32 hardens the handler so that can
#        never happen again (below).
#
#    v32 changes (runtime only; extractor FROZEN):
#      * mixer.zig: loadFileBytes no longer frees the resolve() result —
#        the resolver cache map owns it (freed exactly once in deinit);
#        the ownership contract is documented + pinned by a regression
#        test (std.testing.allocator catches both double-free and leak).
#      * crash.zig: SA_ONSTACK + a 64 KiB alternate signal stack (a
#        stack-overflow crash can no longer kill the report before it
#        starts), and the frame-pointer walk now validates every
#        dereference against a /proc/self/maps range table read ONCE
#        at handler entry — a garbage/unmapped FP ends the walk
#        gracefully instead of faulting the handler. Also: the maps
#        read now LOOPS (a single read() returns only ~4 KiB — every
#        earlier report's map list was silently truncated at ~42
#        lines, which is why the main [stack] region never appeared)
#        and the buffer grew to 64 KiB / 512 ranges.
#      * runtime/repro.zig: the audio regression harness that caught
#        the bug (full BGM+SE lifecycle on the GPA; --crash mode
#        self-tests the hardened handler under real audio load).
#      * 88/88 deterministic tests; input selftest (v31 fixes carried
#        unchanged) PASS through a real SDL2; the harness completes
#        the full audio lifecycle crash-free on x86.
#
#        v048r0 — audio works, video works, then):
#
#    The v30 device run: video ✅, audio ✅ ("sounds great"), title ✅ —
#    but the D-pad was COMPLETELY dead, the stick only moved the menu
#    on diagonals, B confirmed while A ALSO confirmed, NEW GAME crashed
#    the process (exit 134), and START+SELECT never fired.
#
#    Root causes (three proven, one masked):
#      * THE WIPE BUG — pollSticks read the resting analog stick every
#        frame and AUTHORITATIVELY cleared the four direction bits AFTER
#        pumpEvents had set them from D-pad events: a D-pad press was
#        dead by construction. v31 splits direction provenance
#        (pad bits vs stick bits, effective = OR) so a resting stick can
#        only ever clear its own contribution.
#      * THE A/B DOUBLE-MAP — the GO-Super's SDL controller mapping
#        swaps A/B Nintendo-style, and v30 applied BOTH the controller
#        twin AND the joystick twin of every press: physical B fired
#        confirm AND cancel ("B confirms, A also triggers it"). v31:
#        whenever a raw joystick device exists its evdev button order —
#        the gptokeyb-VERIFIED R36S mapping — is authoritative and
#        controller buttons are ignored.
#      * THE CONFIRM CRASH — a userspace-raised signal (negative
#        si_code) hit the MAIN thread inside the first DestroyTexture
#        of the title→field texture-cache flush; the crash handler then
#        PANICKED on `@intCast(si_code)` ("integer does not fit in
#        destination type") — a DOUBLE FAULT that replaced the real
#        crash report. v31: signed si_code printing, a re-entry guard,
#        wrapping maps arithmetic, a THREAD-SAFE mixer allocator (the
#        unsynchronized arena was shared by the mixer thread), and
#        LIBC_FATAL_STDERR_=1 below so glibc's own abort messages
#        (normally sent to /dev/tty, INVISIBLE in a piped runtime.log)
#        land in the log. The next device run now produces a COMPLETE
#        signal report (number, si_code, fault address, registers).
#      * THE SE NAMES — every hardcoded "cursor"/"decision"/"cancel"
#        missed while audio/se holds 655 files: MV reads the names from
#        $dataSystem.sounds. v31 does the same, plus a one-shot dump of
#        the folder's names into the log.
#
#    v31 changes (runtime + launcher env; extractor FROZEN):
#      * input: direction-provenance split, joy-button arbitration,
#        dual SELECT/START numbering (8/9 AND 10/11), MV key-repeat,
#        button/hat/key events logged for the WHOLE session (the v30
#        100-event budget was eaten by stick jitter in 4 seconds),
#      * crash: the double-fault fixes above,
#      * audio: $dataSystem SE identity + the mixer's own GPA,
#      * launcher: LIBC_FATAL_STDERR_=1 (runtime invocation ONLY —
#        the extractor env is untouched, as always).
#
#  v30 — THE INPUT FIX + AUDIO (from the v29 device logs, pixeldrain yUdNiHp4):
#
#    The v29 device run finally RENDERED: opengles2 accelerated driver,
#    60 fps, the title sheet on screen ("it just showed an image of
#    OMORI... a splash image"). But the game was DEAF: 328 input events
#    arrived (pad buttons + stick), zero menu moves, no quit combo, and
#    the session ended in another force power-off.
#
#    Root cause — THE EVENT TYPE CONSTANTS WERE WRONG (the third
#    hand-typed SDL constant bug in a row, after the pixel format and
#    the window flags): the controller events were declared as
#    0x64B/0x64C/0x64D — values that are NOT SDL event types. Real SDL2
#    emits 0x651/0x652 (controller buttons), 0x603/0x604 (joy buttons),
#    0x650 (axes). The dispatcher matched NOTHING: every button fell
#    through ignored.
#
#      * The R36S's GO-Super Gamepad also sends SELECT/START ONLY as
#        raw JOYSTICK events (device log: 0x603/0x604 pairs with no
#        controller counterpart — they are missing from SDL's
#        controller mapping), so a controller-only path can never
#        deliver the quit combo. v30 maps the joy buttons too.
#
#    v30 changes (runtime + launcher audio env; extractor FROZEN):
#      * real SDL2 event constants + joy-button/joy-hat/axis dispatch,
#      * START+SELECT quit works through either path (0.5 s hold),
#      * SDL2 keyboard constants (v29 carried SDL 1.2 numbers),
#      * first 100 events fully DECODED in the log (name + logical
#        mapping) — the next device run shows exactly what the pad
#        emits AND what it mapped to,
#      * --selftest-input: pushes synthetic events through a REAL
#        SDL2 and proves the dispatch chain (15/15 checks),
#      * title menu VISIBLE: 24px commands, selected = inverted
#        black-on-white (v29's 16px gray labels were easy to miss),
#      * M10 AUDIO: Ogg Vorbis decode (stb_vorbis) → software mixer
#        (BGM streaming with pitch/loop/fade + 8 SE voices) → SDL2
#        audio device; interpreter commands 241/242/245/249/250 drive
#        it; title BGM user_title + menu cursor/decision/cancel SEs;
#      * the launcher no longer forces SDL_AUDIODRIVER=dummy for the
#        RUNTIME (SDL auto-discovers alsa; failure = silent, never
#        fatal).
#
#  v29 — THE PRESENT FIX (from the v28 device logs, pixeldrain Cr6UZcKH):
#
#    The v28 device run booted everything (database, atlas, title scene,
#    SDL_Init kmsdrm, window 640x480, controller, game loop started) —
#    and then showed a WHITE screen with dead input: Start+Select did
#    nothing and the device had to be powered off. Two independent bugs:
#
#      1. PIXEL FORMAT CONSTANT WRONG: v28's SDL_PIXELFORMAT_ABGR8888 was
#         0x28664067 — a value SDL2 rejects as "Unsupported YUV format",
#         so EVERY SDL_CreateTexture failed silently and only the white
#         clear color ever reached the screen. (Reproduced and fixed on
#         the dev box: SDL 2.32 software renderer; the true constant is
#         0x16762004, verified empirically against texture_formats.)
#      2. WINDOW FLAGS BUG: the window was created with 0x4 (SHOWN) while
#         the code believed it was SDL_WINDOW_OPENGL (0x2) — no GL/EGL
#         surface, so the GLES2 accelerated renderer can never attach
#         ("Couldn't find matching render driver") and SDL fell back to
#         the SOFTWARE renderer, whose KMSDRM present path can stall on
#         the RK3326's 4.4 kernel → frozen loop, no input polling.
#
#    v29 changes (runtime only — the extractor stays FROZEN):
#      * correct ABGR8888 constant → sprites and text actually draw,
#      * window created WITH SDL_WINDOW_OPENGL first (GLES2 + eglSwap-
#        Buffers present; non-GL retry kept as fallback),
#      * PRESENT WATCHDOG thread: a >10 s frame stall logs the evidence
#        and exits(2) — never again a hard power-off,
#      * SIGTERM/SIGINT handled (clean exit from PortMaster stop),
#      * every log line flushed immediately (v28 lost the detailed.txt
#        tail to buffering),
#      * renderer/controller/input DIAGNOSTICS: SDL2 version, active
#        render driver name, controller names, first 40 raw events,
#        per-240-frame heartbeat (present ms + texture cache + events),
#      * texture cache for stable scene surfaces (the 6 MiB title sheet
#        uploads once per scene, not per frame).
#
#    The extraction pipeline remains FROZEN (v25 device report: "the
#    extraction part runned fine, so don't mess with it").
#
#
#    The v27 device run proved the kernel-4.4 fs fix worked: the whole
#    M1-M9 battery ran on the R36S (database, atlas, intro interpreter,
#    battle, save/load) — but ONLY in "headless validation mode":
#    every SDL2 dlopen failed with "Dynamic loading not supported".
#    That is the signature of the v27 binary being STATIC MUSL — a
#    static binary cannot dlopen, so SDL2 could never load, no window
#    ever opened, and the runtime silently self-tested for 2 seconds
#    and exited. "The title didn't appear. Nothing."
#
#    v28 changes:
#      * the runtime is now DYNAMICALLY linked (aarch64-linux-gnu,
#        glibc 2.31 floor = Ubuntu 20.04 / ArkOS): dlopen resolves
#        SDL2 from the system paths, $OMORI_SDL2, or the port's own
#        omori/libs/ fallback copy,
#      * a VIDEO-DRIVER RETRY CHAIN (env → kmsdrm → x11 → wayland →
#        auto) so a wrong SDL_VIDEODRIVER cannot kill the launch,
#      * HONEST FAILURE: without a display a windowed run exits 3 with
#        a loud log — never again a silent headless self-test,
#      * THE INTERACTIVE GAME SHELL: a real 60 Hz state machine (title
#        menu → field: walk/events/dialogue/choices/pictures/transfers
#        → menu: ITEM/SKILL/SAVE/OPTIONS/QUIT → turn-based battle UI)
#        driven by the R36S pad. The headless battery still runs with
#        --headless / OMORI_HEADLESS=1 (validation mode).
#
#    The extraction pipeline remains FROZEN (v25 device report: "the
#    extraction part runned fine, so don't mess with it").
#
#  v27 — THE DEVICE FIX (from the v26 device logs):
#
#    The v26 device run proved the logging guarantee worked (the launcher
#    stub detailed.txt captured the failure) and pinpointed the runtime's
#    two identical failures: "logs: cannot create dir" and "game tree
#    verification failed: 'index.html' is missing". Root cause: Zig 0.15's
#    std.fs stats files with the statx syscall (Linux 4.11+); the R36S's
#    RK3326 vendor kernel is 4.4.189 — statx returns ENOSYS there, so
#    makePath on the EXISTING logs dir failed and statSync reported every
#    file missing → BadGameTree exit before any window. v27's runtime does
#    all stats/reads/mkdirs through an fstatat-based compat layer
#    (core/fs_compat.zig): syscall profile verified 4.4-safe end-to-end.
#
#  v26 logging contract ("I want logs even if it doesn't open"):
#
#    The v25 device report: three shell logs (launcher/extract/runtime)
#    existed, but NO detailed.txt and no title. Conclusion: whatever
#    phase failed, runtime-level log files must exist after EVERY run.
#
#    1. LOGS FIRST (kept from v25): omori/logs/ (with a /tmp fallback)
#       is created before any other check; every step is timestamped
#       into launcher.log; short.txt is written on every exit path.
#
#    2. NEW — runtime-log GUARANTEE: after the native runtime exits (and
#       in the EXIT trap for every earlier failure), the launcher checks
#       for detailed.txt. If the runtime did not create it (never
#       started, died before its logging init, or the dir was not
#       writable), the LAUNCHER writes detailed.txt + simple.txt itself:
#       a full diagnostic dump (exit code, arch, binary stat, runtime.log
#       content, extract.log tail, environment). A detailed.txt now
#       exists after every single run — no exceptions.
#
#    3. The runtime itself boots logs-first (log init before argv
#       parsing; crash reporter installed immediately after) and logs
#       every SDL2 dlopen attempt + dlerror.
#
#    4. The extraction pipeline is FROZEN (v25 device report: "the
#       extraction part runned fine, so don't mess with it") — the v21
#       extractor and its invocation contract are untouched in v26.
#
#  No Weston, no Xwayland, no NW.js, no browser. The complete reference
#  stack is preserved under reference/nwjs/ in the project repository as
#  a behavioral oracle (not shipped in this package).
# =============================================================================

SCRIPT_START=$(date +%s)

# --- port directory: THIS script's own location (the v21 contract) -------
PORT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
if [ -z "$PORT_DIR" ]; then
    echo "[OMORI FATAL] Cannot determine port directory." >&2
    exit 99
fi
OMORI_DIR="${PORT_DIR}/omori"
# Tolerate an unexpected flat layout (bin/omori-native directly next to us).
if [ ! -d "$OMORI_DIR" ] && [ -x "${PORT_DIR}/bin/omori-native" ]; then
    OMORI_DIR="$PORT_DIR"
fi

ORIGINAL_DIR="${OMORI_DIR}/original"
EXTRACTED_DIR="${ORIGINAL_DIR}/extracted"
# Android and PC preparation publish the same assets/www game root.
GAME_ROOT="${EXTRACTED_DIR}/assets/www"
SAVE_DIR="${OMORI_DIR}/saves"
RUNTIME_BIN="${OMORI_DIR}/bin/omori-native"
EXTRACT_UI="${OMORI_DIR}/bin/extract_ui.py"
PC_PREPARE="${OMORI_DIR}/bin/prepare_pc.py"

# =============================================================================
# Logging — created BEFORE anything can fail. Files in ${OMORI_DIR}/logs/:
#   launcher.log  every launcher step (timestamped)
#   extract.log   the extractor's own output (progress, UI diagnostics)
#   runtime.log   the native runtime's stdout/stderr
#   short.txt     the outcome summary (rewritten on every exit)
#   detailed.txt / simple.txt / boot.state  (written by the native runtime)
# If ${OMORI_DIR} is not writable, logs fall back to /tmp/omori-logs.
# =============================================================================
LOGS_DIR="${OMORI_DIR}/logs"
mkdir -p "$LOGS_DIR" 2>/dev/null || true
if [ ! -w "$LOGS_DIR" ]; then
    LOGS_DIR="/tmp/omori-logs"
    mkdir -p "$LOGS_DIR" 2>/dev/null || true
fi
LAUNCHER_LOG="${LOGS_DIR}/launcher.log"
EXTRACT_LOG="${LOGS_DIR}/extract.log"
RUNTIME_LOG="${LOGS_DIR}/runtime.log"
SHORT_LOG="${LOGS_DIR}/short.txt"

# v26: every log file exists from the very start — an absent runtime.log
# would otherwise be ambiguous (never launched vs launched-and-died).
touch "$EXTRACT_LOG" "$RUNTIME_LOG" 2>/dev/null || true

LAST_FATAL=""
RUNTIME_EXIT=""
LOGS_HINT="logs: ${LOGS_DIR}"

log() {
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >&2
    printf '[%s] %s\n' "$(date '+%H:%M:%S')" "$*" >> "$LAUNCHER_LOG" 2>/dev/null || true
}
die() { LAST_FATAL="$*"; log "FATAL: $*"; exit 1; }

# v26 — THE runtime-log GUARANTEE.
# If the native runtime did not create detailed.txt (never launched, died
# before its logging init, dir not writable), the launcher writes it — a
# full diagnostic dump. This is what makes "logs even if it doesn't open"
# structural: no failure phase can end without detailed.txt + simple.txt.
ensure_runtime_logs() {
    [ -f "${LOGS_DIR}/detailed.txt" ] && return 0
    local DET="${LOGS_DIR}/detailed.txt"
    local SIM="${LOGS_DIR}/simple.txt"
    {
        echo "========================================================================="
        echo " OMORI native runtime — detailed log (LAUNCHER-WRITTEN STUB)"
        echo " $(date)"
        echo "========================================================================="
        echo ""
        echo " WHY THIS FILE EXISTS: the native runtime did not create its own"
        echo " detailed.txt this run. It either never started (exec failure,"
        echo " missing binary, launcher died earlier) or it died before its"
        echo " logging initialized (pre-main crash). This stub was written by"
        echo " the launcher so a detailed log ALWAYS exists."
        echo ""
        echo " ----------------------------------------------------------------------"
        echo " RUN OUTCOME"
        echo " ----------------------------------------------------------------------"
        if [ -n "${LAST_FATAL}" ]; then
            echo " outcome      : FAILED (launcher) — ${LAST_FATAL}"
        elif [ -n "${RUNTIME_EXIT}" ]; then
            echo " outcome      : native runtime exit code ${RUNTIME_EXIT}"
            if [ "${RUNTIME_EXIT}" -eq 0 ]; then
                echo " (exited 0 but without detailed.txt — suspicious: the log dir"
                echo "  may have been swapped mid-run, or logs were deleted)"
            else
                echo " (nonzero exit without runtime logging — the runtime died"
                echo "  before its logger initialized, e.g. at exec/startup)"
            fi
        else
            echo " outcome      : the native runtime was never launched"
        fi
        echo " date         : $(date)"
        echo " duration     : $(( $(date +%s) - SCRIPT_START ))s"
        echo ""
        echo " ----------------------------------------------------------------------"
        echo " DEVICE / ENVIRONMENT"
        echo " ----------------------------------------------------------------------"
        echo " uname        : $(uname -a 2>/dev/null)"
        echo " arch         : $(uname -m 2>/dev/null)"
        echo " bash         : ${BASH_VERSION}"
        echo " whoami       : $(whoami 2>/dev/null)"
        echo " ESUDO        : ${ESUDO:-<unset>}"
        echo " SDL_VIDEODRIVER : ${SDL_VIDEODRIVER:-<unset>}"
        echo " XDG_RUNTIME_DIR : ${XDG_RUNTIME_DIR:-<unset>}"
        echo " DISPLAY      : ${DISPLAY:-<unset>}"
        echo ""
        echo " ----------------------------------------------------------------------"
        echo " PORT / BINARY"
        echo " ----------------------------------------------------------------------"
        echo " port dir     : ${PORT_DIR}"
        echo " omori dir    : ${OMORI_DIR}"
        echo " game root    : ${GAME_ROOT}"
        echo " runtime bin  : ${RUNTIME_BIN}"
        if [ -e "${RUNTIME_BIN}" ]; then
            echo " binary stat  : $(stat -c 'size=%s mode=%A owner=%U:%G' "${RUNTIME_BIN}" 2>/dev/null)"
            echo " binary magic: $(head -c 20 "${RUNTIME_BIN}" 2>/dev/null | od -An -tx1 | head -2)"
            echo " (ELF magic 7f 45 4c 46 + machine field: b7 00 = aarch64, 3e 00 = x86_64,"
            echo "  28 00 = arm, 08 00 = mips. Exec-format failures leave a message in"
            echo "  the runtime.log dump below.)"
        else
            echo " binary stat  : MISSING — the runtime binary does not exist!"
        fi
        echo ""
        echo " ----------------------------------------------------------------------"
        echo " runtime.log (FULL — the runtime's stdout+stderr)"
        echo " ----------------------------------------------------------------------"
        if [ -s "${RUNTIME_LOG}" ]; then
            cat "${RUNTIME_LOG}"
        else
            echo " (empty — the runtime produced no console output at all,"
            echo "  which means it never executed a single line of code)"
        fi
        echo ""
        echo " ----------------------------------------------------------------------"
        echo " extract.log tail (last 30 lines)"
        echo " ----------------------------------------------------------------------"
        tail -n 30 "${EXTRACT_LOG}" 2>/dev/null || echo " (none)"
        echo ""
        echo " ----------------------------------------------------------------------"
        echo " launcher.log tail (last 40 lines)"
        echo " ----------------------------------------------------------------------"
        tail -n 40 "${LAUNCHER_LOG}" 2>/dev/null || echo " (none)"
        echo ""
        echo " ======================================================================="
        echo " Read short.txt for the one-paragraph summary."
    } > "$DET" 2>/dev/null || true
    if [ ! -f "$SIM" ]; then
        {
            echo "[$(date '+%H:%M:%S')] RUNTIME LOGGING NEVER STARTED — detailed.txt was written by the launcher."
            if [ -n "${LAST_FATAL}" ]; then
                echo "[$(date '+%H:%M:%S')] Cause (launcher): ${LAST_FATAL}"
            elif [ -n "${RUNTIME_EXIT}" ]; then
                echo "[$(date '+%H:%M:%S')] Runtime exit code: ${RUNTIME_EXIT} — see detailed.txt for the full dump."
            else
                echo "[$(date '+%H:%M:%S')] The native runtime was never launched — see detailed.txt."
            fi
        } > "$SIM" 2>/dev/null || true
    fi
}

# Short summary — written on EVERY exit ("logs even if it doesn't open").
gen_short() {
    ensure_runtime_logs
    local rt=$(( $(date +%s) - SCRIPT_START ))
    local outcome="" cause=""
    if [ -n "$LAST_FATAL" ]; then
        outcome="FAILED"; cause="$LAST_FATAL"
    elif [ -n "${RUNTIME_EXIT:-}" ]; then
        if [ "$RUNTIME_EXIT" -eq 0 ]; then
            outcome="OK - game exited normally"
        elif [ "$RUNTIME_EXIT" -eq 3 ]; then
            outcome="FAILED - no usable display (SDL2/window unavailable)"
            cause="Read ${LOGS_DIR}/detailed.txt: the 'SDL2 dlopen' trail shows every library attempt and SDL_GetError for each driver retry."
        elif [ "$RUNTIME_EXIT" -eq 4 ]; then
            outcome="FAILED - GameFont missing (fonts/OMORI_GAME2.ttf)"
            cause="The extraction may be incomplete; check ${EXTRACT_LOG} and ${GAME_ROOT}/fonts."
        else
            outcome="FAILED - native runtime exited with code ${RUNTIME_EXIT}"
            cause="Read ${LOGS_DIR}/detailed.txt + simple.txt + runtime.log (the runtime's own logs)."
        fi
    else
        outcome="FAILED - the native runtime was never reached"
        cause="Read ${LOGS_DIR}/launcher.log (and extract.log) for the phase that failed."
    fi
    {
        echo "OMORI PortMaster port — run summary"
        echo "date: $(date)"
        echo "duration: ${rt}s"
        echo "port dir: ${PORT_DIR}"
        echo "logs dir: ${LOGS_DIR}"
        echo "outcome: ${outcome}"
        if [ -n "$cause" ]; then echo "cause: ${cause}"; fi
        echo
        echo "files: launcher.log (all launcher steps) / extract.log (extractor)"
        echo "       runtime.log (game stdout+stderr) / detailed.txt + simple.txt"
        echo "       + boot.state (written by the game itself)"
    } > "$SHORT_LOG" 2>/dev/null || true
}
trap gen_short EXIT

log "OMORI ReZig launcher (0.0.1, build v42, R36S port by José Pilas — camera pans, reaction cues and encounter pacing) — port dir ${PORT_DIR}"
log "device: $(uname -m 2>/dev/null) / $(uname -r 2>/dev/null), bash ${BASH_VERSION}, user $(whoami 2>/dev/null)"
log "mount of port dir: $(df -h "${PORT_DIR}" 2>/dev/null | tail -1 || echo '(df unavailable)')"
log "logs: ${LOGS_DIR} (launcher.log, extract.log, runtime.log, short.txt; the game adds detailed.txt/simple.txt — guaranteed by the launcher if the game cannot log)"

# --- sanity: architecture (aarch64 binary; test bypass for dev boxes) ----
if [ "${OMORI_ALLOW_ANY_ARCH:-0}" != "1" ]; then
    case "$(uname -m)" in
        aarch64) ;;
        *)
            die "This port targets aarch64 (R36S / RK3326). Refusing to run on $(uname -m)."
            ;;
    esac
fi

# --- privilege helper (v21 contract: the extractor and the game runtime
#     want root for KMS/DRM master; PortMaster provides $ESUDO) -----------
RUNAS=""
if [ -n "${ESUDO:-}" ]; then
    RUNAS="$ESUDO"
elif command -v sudo >/dev/null 2>&1; then
    RUNAS="sudo"
fi
log "privilege: ${RUNAS:-plain user (no sudo/ESUDO found)}"

# --- sanity: native runtime present ---------------------------------------
if [ ! -x "${RUNTIME_BIN}" ]; then
    die "native runtime missing or not executable: ${RUNTIME_BIN}"
fi
log "native runtime: ${RUNTIME_BIN} ($(stat -c%s "$RUNTIME_BIN" 2>/dev/null) bytes)"

# Did the privilege WRAPPER itself fail (as opposed to the program)? rc
# 126/127 = wrapper/launch failure; a sudo password prompt also means the
# program never ran. Used to decide whether a plain-user retry makes sense.
wrapper_failed() {
    local rc="$1" logf="$2" tail_line
    if [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then return 0; fi
    if [ -f "$logf" ]; then
        while IFS= read -r tail_line; do
            case "$tail_line" in
                *"password is required"*|*"a terminal is required"*|\
                *"sudo:"*"not found"*|*"not in the sudoers file"*)
                    return 0 ;;
            esac
        done < <(tail -n 6 "$logf" 2>/dev/null)
    fi
    return 1
}

# --- first-run preparation: Android APK or copied PC install ---------------
PY=""
if command -v python3 >/dev/null 2>&1; then
    PY=python3
elif command -v python >/dev/null 2>&1; then
    PY=python
fi
SOURCE_KIND=android
SOURCE=""
NEEDS_PREPARATION=0
if [ -n "$PY" ] && [ -f "$PC_PREPARE" ]; then
    PC_DETECTION="$("$PY" "$PC_PREPARE" --detect "$ORIGINAL_DIR" 2>>"$LAUNCHER_LOG")"
    PC_DETECT_RC=$?
    if [ "$PC_DETECT_RC" -eq 0 ]; then
        SOURCE_KIND=pc
        SOURCE="$ORIGINAL_DIR"
        log "PC game data detected: ${PC_DETECTION}"
        if ! "$PY" "$PC_PREPARE" --ready "$ORIGINAL_DIR" "$EXTRACTED_DIR" >>"$LAUNCHER_LOG" 2>&1; then
            NEEDS_PREPARATION=1
        fi
    elif [ "$PC_DETECT_RC" -ne 1 ]; then
        die "PC game data detection failed. Check ${LAUNCHER_LOG}."
    fi
fi
for entry in index.html package.json js data img audio Languages; do
    if [ ! -e "${GAME_ROOT}/${entry}" ]; then NEEDS_PREPARATION=1; fi
done
if [ "$NEEDS_PREPARATION" -eq 1 ]; then
    [ -n "$PY" ] || die "python3 is required to prepare game data"
    [ -f "$EXTRACT_UI" ] || die "Game data preparation UI not found: ${EXTRACT_UI}"
    if [ "$SOURCE_KIND" = android ]; then
        SOURCE="$(find "${ORIGINAL_DIR}" -maxdepth 2 -iname '*.apk' -print -quit 2>/dev/null)"
        if [ -z "$SOURCE" ]; then
            die "No usable game data in ${ORIGINAL_DIR}. Copy your OMORI Android APK or the complete PC installation contents (including www and its supplied launch script) into original, then relaunch. ${LOGS_HINT}"
        fi
        SOURCE_SIZE=$(stat -c%s "$SOURCE" 2>/dev/null || echo 0)
        log "APK found: ${SOURCE} (${SOURCE_SIZE} bytes)"
        unzip -l "$SOURCE" >/dev/null 2>&1 || die "APK is not a valid zip archive: ${SOURCE}"
        # Preserve any incomplete earlier extraction for diagnosis/recovery.
        if [ -e "$EXTRACTED_DIR" ]; then
            PREVIOUS="${ORIGINAL_DIR}/.extracted-previous-android-$(date +%Y%m%d-%H%M%S)-$$"
            mv "$EXTRACTED_DIR" "$PREVIOUS" || die "Cannot preserve previous extraction"
            log "previous extraction preserved: ${PREVIOUS}"
        fi
        mkdir -p "$EXTRACTED_DIR" || die "Cannot create extraction directory"
    fi
    log "preparing ${SOURCE_KIND} data: ${PY} ${EXTRACT_UI} ($(${PY} --version 2>&1))"

    # --- The v21 invocation contract (restored in v25): root via $ESUDO for
    # KMS/DRM master + the SDL/PySDL2 environment the graphical extractor
    # UI needs on PortMaster. Output teed to extract.log. If the privilege
    # wrapper itself fails, retry WITHOUT privileges (text-mode extraction
    # works as a plain user).
    # ------------------------------------------------------------------------
    : > "$EXTRACT_LOG" 2>/dev/null || true
    log "launching extraction UI (privileged: ${RUNAS:-no}) — output: ${EXTRACT_LOG}"

    set -o pipefail
    if [ -n "$RUNAS" ]; then
        "$RUNAS" env \
            SDL_VIDEODRIVER=kmsdrm \
            SDL_AUDIODRIVER=dummy \
            SDL_VIDEO_EGL_DRIVER=libEGL.so \
            SDL_GAMECONTROLLERCONFIG_FILE="${SDL_GAMECONTROLLERCONFIG_FILE:-}" \
            PYSDL2_DLL_PATH="${PYSDL2_DLL_PATH:-/usr/lib}" \
            PYTHONPATH="${OMORI_DIR}/bin/vendor${PYTHONPATH:+:${PYTHONPATH}}" \
            XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}" \
            HOME="${HOME:-/root}" \
            OMORI_EXTRACT_LOG="$EXTRACT_LOG" \
            "$PY" "$EXTRACT_UI" "$SOURCE" "$EXTRACTED_DIR" 2>&1 | tee -a "$EXTRACT_LOG"
        EXTRACT_RC=${PIPESTATUS[0]}
    else
        env \
            SDL_VIDEODRIVER=kmsdrm \
            SDL_AUDIODRIVER=dummy \
            SDL_VIDEO_EGL_DRIVER=libEGL.so \
            PYSDL2_DLL_PATH="${PYSDL2_DLL_PATH:-/usr/lib}" \
            PYTHONPATH="${OMORI_DIR}/bin/vendor${PYTHONPATH:+:${PYTHONPATH}}" \
            XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}" \
            HOME="${HOME:-/root}" \
            OMORI_EXTRACT_LOG="$EXTRACT_LOG" \
            "$PY" "$EXTRACT_UI" "$SOURCE" "$EXTRACTED_DIR" 2>&1 | tee -a "$EXTRACT_LOG"
        EXTRACT_RC=${PIPESTATUS[0]}
    fi
    set +o pipefail
    log "extractor exit code: ${EXTRACT_RC}"

    if [ "$EXTRACT_RC" -ne 0 ] && wrapper_failed "$EXTRACT_RC" "$EXTRACT_LOG"; then
        log "WARN: privileged extractor run failed at the privilege wrapper — retrying WITHOUT privileges (text mode)"
        set -o pipefail
        env \
            SDL_VIDEODRIVER=kmsdrm \
            SDL_AUDIODRIVER=dummy \
            SDL_VIDEO_EGL_DRIVER=libEGL.so \
            PYSDL2_DLL_PATH="${PYSDL2_DLL_PATH:-/usr/lib}" \
            PYTHONPATH="${OMORI_DIR}/bin/vendor${PYTHONPATH:+:${PYTHONPATH}}" \
            XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}" \
            HOME="${HOME:-/root}" \
            OMORI_EXTRACT_LOG="$EXTRACT_LOG" \
            "$PY" "$EXTRACT_UI" "$SOURCE" "$EXTRACTED_DIR" 2>&1 | tee -a "$EXTRACT_LOG"
        EXTRACT_RC=${PIPESTATUS[0]}
        set +o pipefail
        log "extractor (unprivileged retry) exit code: ${EXTRACT_RC}"
    fi

    if [ "$EXTRACT_RC" -ne 0 ]; then
        log "game data preparation FAILED (rc=${EXTRACT_RC}); input and previous data preserved"
        die "Extraction failed (rc=${EXTRACT_RC}). See ${EXTRACT_LOG} and ${LAUNCHER_LOG}."
    fi
    log "extraction complete"
else
    log "game data present — skipping extraction (${GAME_ROOT})"
fi

# --- critical tree verification (the V21 contract) ------------------------
for entry in index.html package.json js data img audio Languages; do
    if [ ! -e "${GAME_ROOT}/${entry}" ]; then
        die "Incomplete extraction: '${entry}' missing in ${GAME_ROOT}. Check the copied APK or PC installation and the preparation log. ${LOGS_HINT}"
    fi
done
log "game tree verification passed (7 entries)"

# --- launch the native runtime --------------------------------------------
mkdir -p "${SAVE_DIR}" "$LOGS_DIR"
log "save dir: ${SAVE_DIR}"
log "game root: ${GAME_ROOT}"

# --- v28: SDL2 probe (diagnostic; the runtime dlopens in this order) ------
log "SDL2 probe (system paths, then the port-local fallback):"
for cand in \
    /usr/lib/aarch64-linux-gnu/libSDL2-2.0.so.0 \
    /usr/lib/libSDL2-2.0.so.0 \
    /usr/local/lib/libSDL2-2.0.so.0 \
    "${OMORI_DIR}/libs/libSDL2-2.0.so.0"; do
    if [ -e "$cand" ]; then
        log "  FOUND: ${cand} ($(stat -c '%s' "$cand" 2>/dev/null) bytes)"
    fi
done
if [ -n "${OMORI_SDL2:-}" ]; then
    log "  OMORI_SDL2 override set: ${OMORI_SDL2}"
fi
log "  SDL_VIDEODRIVER=${SDL_VIDEODRIVER:-<unset>} (runtime retries kmsdrm/x11/wayland/auto if it fails)"

NATIVE_ARGS=(
    --data-root "${GAME_ROOT}"
    --save-root "${SAVE_DIR}"
    --log-dir "${LOGS_DIR}"
    --image-cache-mib "${OMORI_IMAGE_CACHE_MIB:-48}"
)
if [ -n "${OMORI_LOG_DIR:-}" ]; then
    NATIVE_ARGS+=(--log-dir "${OMORI_LOG_DIR}")
fi
if [ "${OMORI_HEADLESS:-0}" = "1" ]; then
    NATIVE_ARGS+=(--headless)
    log "OMORI_HEADLESS=1 — headless validation mode (diagnostics, not gameplay)"
fi

log "launching native runtime: ${RUNTIME_BIN} ${NATIVE_ARGS[*]}"
: > "$RUNTIME_LOG" 2>/dev/null || true

# The runtime writes its own dual-file logs (detailed.txt + simple.txt +
# boot.state) into ${LOGS_DIR} and captures its own crashes; its console
# output lands in runtime.log. If the privilege wrapper fails, retry plain.
if [ -n "$RUNAS" ]; then
    set -o pipefail
    "$RUNAS" env \
        SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-kmsdrm}" \
        SDL_GAMECONTROLLERCONFIG_FILE="${SDL_GAMECONTROLLERCONFIG_FILE:-}" \
        XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/0}" \
        LIBC_FATAL_STDERR_=1 \
        "${RUNTIME_BIN}" "${NATIVE_ARGS[@]}" 2>&1 | tee -a "$RUNTIME_LOG"
    RUNTIME_EXIT=${PIPESTATUS[0]}
    set +o pipefail
    if [ "$RUNTIME_EXIT" -ne 0 ] && wrapper_failed "$RUNTIME_EXIT" "$RUNTIME_LOG"; then
        log "WARN: privileged runtime run failed at the privilege wrapper — retrying WITHOUT privileges"
        set -o pipefail
        env \
            SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-kmsdrm}" \
            SDL_GAMECONTROLLERCONFIG_FILE="${SDL_GAMECONTROLLERCONFIG_FILE:-}" \
            XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}" \
            LIBC_FATAL_STDERR_=1 \
            "${RUNTIME_BIN}" "${NATIVE_ARGS[@]}" 2>&1 | tee -a "$RUNTIME_LOG"
        RUNTIME_EXIT=${PIPESTATUS[0]}
        set +o pipefail
    fi
else
    set -o pipefail
    env \
        SDL_VIDEODRIVER="${SDL_VIDEODRIVER:-kmsdrm}" \
        SDL_GAMECONTROLLERCONFIG_FILE="${SDL_GAMECONTROLLERCONFIG_FILE:-}" \
        XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/tmp}" \
        LIBC_FATAL_STDERR_=1 \
        "${RUNTIME_BIN}" "${NATIVE_ARGS[@]}" 2>&1 | tee -a "$RUNTIME_LOG"
    RUNTIME_EXIT=${PIPESTATUS[0]}
    set +o pipefail
fi
log "native runtime exited: ${RUNTIME_EXIT} (runtime.log + detailed.txt + simple.txt in ${LOGS_DIR})"

# v26: a root-run runtime leaves root-owned log/save files that would
# break the NEXT user-run (rotation/truncation fails). Repair ownership
# and permissions so every future run can log.
if [ "$(id -u 2>/dev/null)" = "0" ] || [ -n "${RUNAS}" ]; then
    chown -R "${SUDO_USER:-$(stat -c '%U' "${OMORI_DIR}" 2>/dev/null || echo root)}" "${LOGS_DIR}" "${SAVE_DIR}" 2>/dev/null || true
    chmod -R a+rwX "${LOGS_DIR}" "${SAVE_DIR}" 2>/dev/null || true
fi
exit "$RUNTIME_EXIT"
