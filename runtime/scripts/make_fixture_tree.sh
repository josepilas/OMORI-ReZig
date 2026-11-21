#!/bin/bash
# Build a synthetic OMORI game tree that exercises the v31 audio path
# exactly as the device does: Mixer.init (data/System.json sounds identity)
# + playBgm("user_title") on a real ~560KB stereo 44.1kHz vorbis file.
set -e

ROOT="${1:-/home/z/my-project/fixture}"

rm -rf "$ROOT"
mkdir -p "$ROOT/data" "$ROOT/audio/bgm" "$ROOT/audio/se" "$ROOT/save"

# --- data/System.json: the $dataSystem sounds array (device names) ---------
python3 - "$ROOT" <<'EOF'
import json, sys
root = sys.argv[1]
system = {
    "gameTitle": "OMORI",
    "sounds": [
        {"name": "sys_cursor1", "pan": 0, "pitch": 100, "pitch_reserve": 0, "volume": 90},
        {"name": "SYS_select",  "pan": 0, "pitch": 100, "pitch_reserve": 0, "volume": 90},
        {"name": "sys_cancel",  "pan": 0, "pitch": 100, "pitch_reserve": 0, "volume": 90},
        {"name": "sys_buzzer",  "pan": 0, "pitch": 100, "pitch_reserve": 0, "volume": 90},
        {"name": "sys_equip",   "pan": 0, "pitch": 100, "pitch_reserve": 0, "volume": 90},
        {"name": "SYS_save",    "pan": 0, "pitch": 100, "pitch_reserve": 0, "volume": 90},
        {"name": "SE_load",     "pan": 0, "pitch": 100, "pitch_reserve": 0, "volume": 90}
    ]
}
with open(f"{root}/data/System.json", "w") as f:
    json.dump(system, f)
EOF

# --- audio/bgm/user_title.ogg: ~40s stereo 44.1kHz vorbis, ~560KB ----------
# (mimics the device file: 561081 bytes)
ffmpeg -y -loglevel error -f lavfi -i "sine=frequency=220:duration=40" \
       -f lavfi -i "sine=frequency=277:duration=40" \
       -filter_complex "[0:a][1:a]amerge=inputs=2[a]" -map "[a]" \
       -c:a libvorbis -b:a 112k -ar 44100 -ac 2 "$ROOT/audio/bgm/user_title.ogg"
SIZE=$(stat -c%s "$ROOT/audio/bgm/user_title.ogg")
echo "user_title.ogg: $SIZE bytes (device: 561081)"

# --- SE files (short vorbis bursts) ----------------------------------------
for n in sys_cursor1 SYS_select sys_cancel sys_buzzer sys_equip SYS_save SE_load; do
    ffmpeg -y -loglevel error -f lavfi -i "sine=frequency=880:duration=0.15" \
           -c:a libvorbis -b:a 96k -ar 44100 -ac 2 "$ROOT/audio/se/$n.ogg"
done

echo "fixture tree ready at $ROOT"
