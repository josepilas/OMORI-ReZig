#!/usr/bin/env python3
"""
OMORI Game Data Preparation UI - PySDL2 version

Uses PySDL2 (which PortMaster provides via PYSDL2_DLL_PATH=/usr/lib)
instead of pygame or raw ctypes. PySDL2 is the standard Python SDL2
binding on PortMaster devices.

Must be run as root (via $ESUDO) to acquire KMS/DRM master, since
EmulationStation may still hold the display.

Features:
  - Fullscreen black & white UI matching OMORI's aesthetic
  - "OMORI" title with hanging lightbulb motif
  - Progress bar with percentage
  - File count and MB transferred
  - ETA calculation
  - Deletes APK on success
  - Never shows again if already extracted

If PySDL2 can't initialize (no display), falls back to text mode.
"""
import os
import sys
import traceback
import zipfile

# PortMaster does not guarantee a system PySDL2 installation. The package
# vendors the small pure-Python binding next to this script, while SDL2 itself
# is supplied by the firmware.
_VENDOR_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "vendor")
if os.path.isdir(_VENDOR_DIR) and _VENDOR_DIR not in sys.path:
    sys.path.insert(0, _VENDOR_DIR)
import threading
import time
from pathlib import Path

# v25: the launcher passes OMORI_EXTRACT_LOG so extraction progress and
# failures land in <port>/omori/logs/extract.log even in text fallback mode
# (or if this script crashes before its own error handling runs).
_EXTRACT_LOG = os.environ.get("OMORI_EXTRACT_LOG")

def xlog(msg):
    """Diagnostic line: stderr + the extract log file (if configured)."""
    print(f"OMORI: {msg}", file=sys.stderr, flush=True)
    if _EXTRACT_LOG:
        try:
            import datetime
            with open(_EXTRACT_LOG, "a", encoding="utf-8") as fh:
                fh.write(f"[{datetime.datetime.now().strftime('%H:%M:%S')}] {msg}\n")
        except Exception:
            pass

xlog(f"extract_ui.py starting: argv={sys.argv[:3]} pid={os.getpid()} "
     f"euid={getattr(os, 'geteuid', lambda: '?')()} python={sys.version.split()[0]}")
xlog(f"vendor dir: {_VENDOR_DIR} (exists: {os.path.isdir(_VENDOR_DIR)})")

# ---------------------------------------------------------------------------
# Try to import PySDL2
# ---------------------------------------------------------------------------
try:
    from sdl2 import *
    HAS_SDL2 = True
except Exception as exc:  # v25: broad — ANY import failure falls back to
    HAS_SDL2 = False       # text mode instead of crashing with a traceback
    SDL2_IMPORT_ERROR = str(exc)
xlog(f"PySDL2 import: {'OK' if HAS_SDL2 else 'FAILED (' + SDL2_IMPORT_ERROR + ')'} "
     f"PYSDL2_DLL_PATH={os.environ.get('PYSDL2_DLL_PATH', '<unset>')} "
     f"SDL_VIDEODRIVER={os.environ.get('SDL_VIDEODRIVER', '<unset>')}")

# ---------------------------------------------------------------------------
# Layout & colors
# ---------------------------------------------------------------------------
SCREEN_W = 640
SCREEN_H = 480

BLACK = (0, 0, 0)
WHITE = (255, 255, 255)
GRAY = (60, 60, 60)
LIGHT_GRAY = (180, 180, 180)
DARK_GRAY = (30, 30, 30)

# 5x7 bitmap font (each char is 7 rows of 5 bits)
FONT_DATA = {
    'A': ["01110","10001","10001","11111","10001","10001","10001"],
    'B': ["11110","10001","10001","11110","10001","10001","11110"],
    'C': ["01110","10001","10000","10000","10000","10001","01110"],
    'D': ["11110","10001","10001","10001","10001","10001","11110"],
    'E': ["11111","10000","10000","11110","10000","10000","11111"],
    'F': ["11111","10000","10000","11110","10000","10000","10000"],
    'G': ["01110","10001","10000","10111","10001","10001","01111"],
    'H': ["10001","10001","10001","11111","10001","10001","10001"],
    'I': ["11111","00100","00100","00100","00100","00100","11111"],
    'K': ["10001","10010","10100","11000","10100","10010","10001"],
    'L': ["10000","10000","10000","10000","10000","10000","11111"],
    'M': ["10001","11011","10101","10001","10001","10001","10001"],
    'N': ["10001","11001","10101","10011","10001","10001","10001"],
    'O': ["01110","10001","10001","10001","10001","10001","01110"],
    'P': ["11110","10001","10001","11110","10000","10000","10000"],
    'R': ["11110","10001","10001","11110","10100","10010","10001"],
    'S': ["01111","10000","10000","01110","00001","00001","11110"],
    'T': ["11111","00100","00100","00100","00100","00100","00100"],
    'U': ["10001","10001","10001","10001","10001","10001","01110"],
    'V': ["10001","10001","10001","10001","10001","01010","00100"],
    'W': ["10001","10001","10001","10001","10101","10101","01010"],
    'X': ["10001","10001","01010","00100","01010","10001","10001"],
    'Y': ["10001","10001","10001","01010","00100","00100","00100"],
    'Z': ["11111","00001","00010","00100","01000","10000","11111"],
    '0': ["01110","10001","10011","10101","11001","10001","01110"],
    '1': ["00100","01100","00100","00100","00100","00100","01110"],
    '2': ["01110","10001","00001","00010","00100","01000","11111"],
    '3': ["11111","00010","00100","00010","00001","10001","01110"],
    '4': ["00010","00110","01010","10010","11111","00010","00010"],
    '5': ["11111","10000","11110","00001","00001","10001","01110"],
    '6': ["00110","01000","10000","11110","10001","10001","01110"],
    '7': ["11111","00001","00010","00100","01000","01000","01000"],
    '8': ["01110","10001","10001","01110","10001","10001","01110"],
    '9': ["01110","10001","10001","01111","00001","00010","01100"],
    ' ': ["00000","00000","00000","00000","00000","00000","00000"],
    '%': ["11001","11010","00100","01011","10011","00000","00000"],
    '/': ["00001","00010","00010","00100","01000","01000","10000"],
    '-': ["00000","00000","00000","11111","00000","00000","00000"],
    '.': ["00000","00000","00000","00000","00000","00100","00100"],
    ':': ["00000","00100","00000","00000","00000","00100","00000"],
    '!': ["00100","00100","00100","00100","00100","00000","00100"],
}

def get_font_bitmap(ch):
    """Get the 5x7 bitmap for a character."""
    return FONT_DATA.get(ch.upper(), FONT_DATA.get('?', FONT_DATA[' ']))


# ---------------------------------------------------------------------------
# Extraction logic (shared between UI and text mode)
# ---------------------------------------------------------------------------
def extract_apk(apk_path, extract_to, index_file, state):
    """Extract APK and update state dict. Returns True on success."""
    try:
        state['status'] = 'Reading APK...'
        with zipfile.ZipFile(apk_path, 'r') as zf:
            infos = zf.infolist()
            state['files_total'] = len(infos)
            state['bytes_total'] = sum(i.file_size for i in infos)
            state['status'] = 'Extracting...'

            for i, info in enumerate(infos):
                if state.get('cancel'):
                    state['error'] = 'Cancelled'
                    state['status'] = 'Cancelled'
                    return False
                state['current_file'] = info.filename
                zf.extract(info, extract_to)
                state['files_done'] = i + 1
                state['bytes_done'] += info.file_size
                if state['bytes_total'] > 0:
                    state['progress'] = state['bytes_done'] / state['bytes_total']

        www = os.path.dirname(index_file)
        if not all(os.path.exists(os.path.join(www, name)) for name in
                   ('index.html', 'package.json', 'js', 'data', 'img', 'audio', 'Languages')):
            state['error'] = 'Required game files not found after extraction'
            state['status'] = 'Error: not OMORI?'
            return False

        state['done'] = True
        state['status'] = 'Done!'
        return True
    except Exception as e:
        state['error'] = str(e)
        state['status'] = f'Error: {e}'
        return False


def delete_apk(apk_path):
    """Delete the APK file."""
    if not os.path.isfile(apk_path) or Path(apk_path).suffix.lower() != '.apk':
        return False
    try:
        os.remove(apk_path)
        return True
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Text-mode fallback
# ---------------------------------------------------------------------------
def extract_source(source, extract_to, index_file, state):
    """Use one progress screen for Android APKs and copied PC game data."""
    if not os.path.isdir(source):
        return extract_apk(source, extract_to, index_file, state)
    try:
        from prepare_pc import prepare_pc
        state['status'] = 'Preparing PC game data...'
        prepare_pc(source, extract_to, progress=state.update,
                   cancelled=lambda: bool(state.get('cancel')))
        if not os.path.isfile(index_file):
            raise ValueError('Prepared PC game data is incomplete')
        state.update(done=True, status='Done!', progress=1.0)
        return True
    except Exception as error:
        state.update(error=str(error), status='PC preparation failed')
        xlog(f'PC preparation failed: {error}')
        return False


def run_text_mode(apk_path, extract_to, index_file):
    """Plain text extraction to stderr — no UI."""
    state = {
        'progress': 0.0, 'current_file': '', 'files_total': 0,
        'files_done': 0, 'bytes_total': 0, 'bytes_done': 0,
        'status': '', 'error': None, 'done': False, 'cancel': False,
    }
    xlog(f"text mode: extracting {apk_path} -> {extract_to}")
    thread = threading.Thread(target=extract_source,
                              args=(apk_path, extract_to, index_file, state))
    thread.start()
    last_pct = -1
    while thread.is_alive():
        thread.join(0.5)
        pct = int(state['progress'] * 100)
        mb_done = state['bytes_done'] // (1024 * 1024)
        mb_total = state['bytes_total'] // (1024 * 1024)
        print(f"  [{pct:3d}%] {state['files_done']}/{state['files_total']} files, "
              f"{mb_done}MB/{mb_total}MB", file=sys.stderr, flush=True)
        if _EXTRACT_LOG and pct != last_pct and pct % 10 == 0:
            last_pct = pct
            xlog(f"progress {pct}% ({state['files_done']}/{state['files_total']} files, "
                 f"{mb_done}/{mb_total} MB) — current: {state['current_file']}")
    if state['done']:
        xlog("text mode: game data preparation complete")
        if os.path.isfile(apk_path):
            delete_apk(apk_path)
        return 0
    else:
        xlog(f"text mode: EXTRACTION FAILED: {state['error']}")
        return 4


# ---------------------------------------------------------------------------
# PySDL2 drawing helpers
# ---------------------------------------------------------------------------
def set_color(renderer, color):
    SDL_SetRenderDrawColor(renderer, color[0], color[1], color[2], 255)


def fill_rect(renderer, x, y, w, h):
    rect = SDL_Rect(x, y, w, h)
    SDL_RenderFillRect(renderer, rect)


def draw_text(renderer, text, x, y, scale=4, color=WHITE):
    """Draw text using the 5x7 bitmap font."""
    set_color(renderer, color)
    cx = x
    for ch in text:
        bitmap = get_font_bitmap(ch)
        for row_idx, row in enumerate(bitmap):
            for col_idx, bit in enumerate(row):
                if bit == '1':
                    fill_rect(renderer,
                              cx + col_idx * scale,
                              y + row_idx * scale,
                              scale, scale)
        cx += 6 * scale


def text_width(text, scale=4):
    return len(text) * 6 * scale


def draw_text_centered(renderer, text, y, scale=4, color=WHITE):
    w = text_width(text, scale)
    draw_text(renderer, text, (SCREEN_W - w) // 2, y, scale, color)


def draw_progress_bar(renderer, x, y, w, h, progress):
    """Draw a progress bar: dark background + white fill + gray border."""
    set_color(renderer, GRAY)
    fill_rect(renderer, x, y, w, h)
    fill_w = int(w * progress)
    if fill_w > 0:
        set_color(renderer, WHITE)
        fill_rect(renderer, x, y, fill_w, h)
    set_color(renderer, LIGHT_GRAY)
    fill_rect(renderer, x, y, w, 2)
    fill_rect(renderer, x, y + h - 2, w, 2)
    fill_rect(renderer, x, y, 2, h)
    fill_rect(renderer, x + w - 2, y, 2, h)


def draw_lightbulb(renderer, cx, cy, size=40):
    """Draw OMORI's signature hanging lightbulb icon."""
    set_color(renderer, WHITE)
    r = size // 3
    # Cord (vertical line from top)
    fill_rect(renderer, cx - 1, 0, 2, cy - r)
    # Bulb (circle approximated with horizontal lines)
    for dy in range(-r, r + 1):
        dx = int((r * r - dy * dy) ** 0.5)
        fill_rect(renderer, cx - dx, cy + dy, dx * 2 + 1, 1)
    # Filament (horizontal line inside bulb)
    set_color(renderer, BLACK)
    fill_rect(renderer, cx - r // 2, cy, r, 2)
    # Base (rectangle below bulb)
    set_color(renderer, WHITE)
    base_w = r + 4
    base_h = size // 4
    fill_rect(renderer, cx - base_w // 2, cy + r, base_w, 2)
    fill_rect(renderer, cx - base_w // 2, cy + r + base_h - 2, base_w, 2)
    fill_rect(renderer, cx - base_w // 2, cy + r, 2, base_h)
    fill_rect(renderer, cx + base_w // 2 - 2, cy + r, 2, base_h)


# ---------------------------------------------------------------------------
# PySDL2 UI mode
# ---------------------------------------------------------------------------
def run_sdl2_ui(apk_path, extract_to, index_file):
    """Pretty PySDL2-based extraction UI."""
    # SDL2 environment setup for PortMaster/KMSDRM
    # These MUST be set before SDL_Init
    os.environ.setdefault('SDL_VIDEODRIVER', 'kmsdrm')
    os.environ.setdefault('SDL_AUDIODRIVER', 'dummy')
    os.environ.setdefault('SDL_VIDEO_EGL_DRIVER', 'libEGL.so')
    # KMSDRM needs XDG_RUNTIME_DIR to be set and writable
    if not os.environ.get('XDG_RUNTIME_DIR'):
        os.environ['XDG_RUNTIME_DIR'] = '/run/user/0'  # root's runtime dir

    if SDL_Init(SDL_INIT_VIDEO) != 0:
        msg = f"SDL_Init failed: {SDL_GetError().decode()}"
        print(f"OMORI: {msg}", file=sys.stderr)
        xlog(f"SDL UI: {msg} — falling back to text mode")
        return None  # signal fallback to text mode

    # Try fullscreen first, then windowed
    window = SDL_CreateWindow(b"OMORI", 0, 0, SCREEN_W, SCREEN_H,
                              SDL_WINDOW_FULLSCREEN)
    if not window:
        window = SDL_CreateWindow(b"OMORI", 0, 0, SCREEN_W, SCREEN_H,
                                  SDL_WINDOW_SHOWN)
    if not window:
        msg = f"SDL_CreateWindow failed: {SDL_GetError().decode()}"
        print(f"OMORI: {msg}", file=sys.stderr)
        xlog(f"SDL UI: {msg}")
        SDL_Quit()
        return None

    # Try accelerated renderer, then software
    renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED)
    if not renderer:
        renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_SOFTWARE)
    if not renderer:
        msg = f"SDL_CreateRenderer failed: {SDL_GetError().decode()}"
        print(f"OMORI: {msg}", file=sys.stderr)
        xlog(f"SDL UI: {msg}")
        SDL_DestroyWindow(window)
        SDL_Quit()
        return None

    # Shared state
    state = {
        'progress': 0.0, 'current_file': '', 'files_total': 0,
        'files_done': 0, 'bytes_total': 0, 'bytes_done': 0,
        'status': 'Starting...', 'error': None, 'done': False,
        'cancel': False,
    }
    start_time = time.time()

    # Start extraction in background
    thread = threading.Thread(target=extract_source,
                              args=(apk_path, extract_to, index_file, state))
    thread.start()

    # Main UI loop
    running = True
    done_timer = 0
    error_timer = 0
    event = SDL_Event()

    while running:
        # Handle events
        while SDL_PollEvent(event):
            if event.type == SDL_QUIT:
                if not state['done']:
                    state['cancel'] = True
                running = False
            elif event.type == SDL_KEYDOWN:
                if state['done'] or state['error']:
                    running = False

        # --- Render ---
        set_color(renderer, BLACK)
        SDL_RenderClear(renderer)

        # Lightbulb icon
        draw_lightbulb(renderer, SCREEN_W // 2, 55, size=36)

        # Title "OMORI"
        draw_text_centered(renderer, "OMORI", 95, scale=6, color=WHITE)

        # Subtitle
        if state['done']:
            subtitle = "READY TO PLAY"
        elif state['error']:
            subtitle = "EXTRACTION FAILED"
        else:
            subtitle = "EXTRACTING GAME FILES"
        draw_text_centered(renderer, subtitle, 160, scale=2, color=LIGHT_GRAY)

        # Progress bar
        bar_x, bar_y, bar_w, bar_h = 80, 210, 480, 24
        draw_progress_bar(renderer, bar_x, bar_y, bar_w, bar_h,
                          state['progress'])

        # Big percentage
        pct = int(state['progress'] * 100)
        if state['done']:
            pct_str = "100%"
        elif state['error']:
            pct_str = "!!"
        else:
            pct_str = f"{pct}%"
        draw_text_centered(renderer, pct_str, 270, scale=8, color=WHITE)

        # Stats: files and MB
        mb_done = state['bytes_done'] // (1024 * 1024)
        mb_total = state['bytes_total'] // (1024 * 1024)
        if state['bytes_total'] > 0:
            stats = f"{state['files_done']} / {state['files_total']} FILES  {mb_done} / {mb_total} MB"
        else:
            stats = state['status']
        draw_text_centered(renderer, stats, 370, scale=2, color=LIGHT_GRAY)

        # Status line with elapsed time and ETA
        elapsed = time.time() - start_time
        if state['done']:
            status = f"DONE IN {elapsed:.1F}S - CLEANING UP"
            status_color = WHITE
        elif state['error']:
            status = state['status'][:40]
            status_color = WHITE
            error_timer += 1
        elif state['progress'] > 0.02:
            eta = elapsed / state['progress'] - elapsed
            status = f"{int(elapsed)}S ELAPSED  ~{int(eta)}S REMAINING"
            status_color = LIGHT_GRAY
        else:
            status = f"{int(elapsed)}S ELAPSED"
            status_color = LIGHT_GRAY
        draw_text_centered(renderer, status, 410, scale=2, color=status_color)

        # Bottom hint
        if state['done']:
            draw_text_centered(renderer, "PRESS ANY KEY", 450, scale=2,
                               color=GRAY)
            done_timer += 1
            if done_timer > 90:  # ~3 seconds at 30fps
                running = False
        elif state['error'] and error_timer > 60:
            draw_text_centered(renderer, "PRESS ANY KEY TO EXIT", 450,
                               scale=2, color=GRAY)

        SDL_RenderPresent(renderer)
        SDL_Delay(33)  # ~30 FPS

    # Wait for extraction thread to finish
    thread.join(timeout=5)

    # Cleanup SDL2
    SDL_DestroyRenderer(renderer)
    SDL_DestroyWindow(window)
    SDL_Quit()

    # Preserve copied PC input. APK deletion retains the Android contract.
    if state['done']:
        delete_apk(apk_path)
        return 0
    elif state.get('cancel'):
        return 5
    elif state.get('error'):
        return 4
    return 0


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    if len(sys.argv) < 3:
        print("Usage: extract_ui.py <apk_or_original_directory> <extract_to_dir>", file=sys.stderr)
        return 2

    apk_path = sys.argv[1]
    extract_to = sys.argv[2]
    index_file = os.path.join(extract_to, "assets", "www", "index.html")

    # --- "Never show again" check ---
    pc_source = os.path.isdir(apk_path)
    if pc_source:
        from prepare_pc import is_prepared_pc
        ready = is_prepared_pc(apk_path, extract_to)
    else:
        www = os.path.dirname(index_file)
        ready = all(os.path.exists(os.path.join(www, name)) for name in
                    ('index.html', 'package.json', 'js', 'data', 'img', 'audio', 'Languages'))
    if ready:
        xlog(f"already extracted ({index_file} exists), skipping")
        return 0

    # --- Verify source exists ---
    if not os.path.exists(apk_path):
        xlog(f"Game data source not found: {apk_path}")
        return 3

    os.makedirs(extract_to, exist_ok=True)

    # --- Check if we're root (needed for KMS/DRM) ---
    if os.geteuid() != 0:
        xlog("WARNING: not running as root — SDL2/KMSDRM may fail; "
             "the launcher should run this script via $ESUDO")

    # --- Try PySDL2 UI mode ---
    if not HAS_SDL2:
        reason = globals().get("SDL2_IMPORT_ERROR", "PySDL2 unavailable")
        print(f"OMORI: graphical extraction UI unavailable ({reason}); using text mode.", file=sys.stderr)
        return run_text_mode(apk_path, extract_to, index_file)

    result = run_sdl2_ui(apk_path, extract_to, index_file)
    if result is not None:
        xlog(f"SDL UI finished with exit code {result}")
        return result

    # If result is None, SDL2 init failed — fall through to text mode
    print("OMORI: SDL2 UI failed, falling back to text mode.", file=sys.stderr)
    xlog("SDL2 UI failed — falling back to text mode")
    return run_text_mode(apk_path, extract_to, index_file)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except BaseException:
        # v25: ANY unexpected crash lands in stderr + the extract log with a
        # full traceback — never a silent death.
        tb = traceback.format_exc()
        print(f"OMORI: extract_ui.py CRASHED:\n{tb}", file=sys.stderr, flush=True)
        if _EXTRACT_LOG:
            try:
                with open(_EXTRACT_LOG, "a", encoding="utf-8") as fh:
                    fh.write(f"CRASH: {tb}\n")
            except Exception:
                pass
        sys.exit(99)
