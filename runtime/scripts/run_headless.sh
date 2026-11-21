#!/bin/sh
# Full M1-M9 headless validation, including the scripted interactive shell.
# Usage: ./scripts/run_headless.sh <game-root> [log-dir] [save-dir]
# Set OMORI_NATIVE_BIN to validate an explicitly selected build.
set -eu

GAME_ROOT="${1:?usage: run_headless.sh <game-root> [log-dir] [save-dir]}"
LOG_DIR="${2:-./tmp_headless_logs}"
SAVE_DIR="${3:-$LOG_DIR/saves}"
BIN="${OMORI_NATIVE_BIN:-./zig-out/bin/omori-native}"

if [ ! -x "$BIN" ]; then
    if [ -n "${OMORI_NATIVE_BIN:-}" ]; then
        echo "SMOKE FAILED: executable not found: $BIN" >&2
        exit 1
    fi
    echo "building $BIN first ..."
    zig build
fi

mkdir -p "$LOG_DIR" "$SAVE_DIR"

OUT_FILE="$LOG_DIR/smoke_output.txt"
# Capture the runtime's status directly; POSIX sh's tee pipeline would
# report tee's success even if the runtime failed after printing a marker.
if "$BIN" --data-root "$GAME_ROOT" --save-root "$SAVE_DIR" --headless --log-dir "$LOG_DIR" > "$OUT_FILE" 2>&1; then
    cat "$OUT_FILE"
else
    status=$?
    cat "$OUT_FILE"
    echo "SMOKE FAILED: runtime exited $status (see $OUT_FILE)" >&2
    exit "$status"
fi

if grep -Fq "headless validation complete — all milestones reached (M1-M9 + interactive shell)" "$OUT_FILE" &&
   grep -Fq "scripted shell: VERIFIED — interactive title/new-game/walk/battle/save/continue chain completed" "$OUT_FILE"; then
    echo "SMOKE OK: M1-M9 and interactive shell reached (logs in $LOG_DIR)"
    exit 0
else
    echo "SMOKE FAILED: complete validation evidence is missing (see $OUT_FILE)" >&2
    exit 1
fi
