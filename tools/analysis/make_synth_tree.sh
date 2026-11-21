#!/usr/bin/env bash
# Builds a synthetic (schema-accurate, BYO-data-free) OMORI game tree for
# the v26 headless M1-M9 e2e validation. Mirrors the interpreter-test
# fixture pattern extended to the full boot chain: VFS tree check, 14
# database files, Languages, Atlas.yaml + a real lossless-WebP sheet,
# Map999 intro + Map87 landing, enemies/troops for M8.
set -euo pipefail
ROOT="${1:-/tmp/omori-synth-game}"
rm -rf "$ROOT"
mkdir -p "$ROOT"/data "$ROOT"/js/data "$ROOT"/img/{atlases,pictures,characters,system,tilesets,enemies} "$ROOT"/audio/bgm "$ROOT"/audio/bgs "$ROOT"/audio/me "$ROOT"/audio/se "$ROOT"/fonts "$ROOT"/Languages/en "$ROOT"/audio/{bgm,bgs,me,se} "$ROOT"/omori

echo '<!DOCTYPE html><html><head><title>OMORI</title></head><body></body></html>' > "$ROOT/index.html"
echo '{"name":"OMORI","main":"js/main.js"}' > "$ROOT/package.json"
echo 'window.onload = function(){};' > "$ROOT/js/main.js"
echo '// synthetic rpg_core' > "$ROOT/js/rpg_core.js"
echo '// synthetic rpg_managers' > "$ROOT/js/rpg_managers.js"
echo 'var $plugins = [];' > "$ROOT/js/plugins.js"

# --- database (js/data) -------------------------------------------------------
D="$ROOT/js/data"
python3 - "$D" << 'PYEOF'
import json, sys, os
d = sys.argv[1]

def w(name, obj):
    with open(os.path.join(d, name), "w") as f:
        json.dump(obj, f)

# System: 2 switches, 3 variables, party OMORI, start map 999.
w("System.json", {
    "gameTitle": "OMORI SYNTHETIC", "versionId": 0,
    "switches": [None, "S1", "S2"],
    "variables": [None, "V1", "V2", "V3"],
    "partyMembers": [1],
    "startMapId": 999, "startX": 8, "startY": 6, "startDirection": 2,
    "currencyUnit": "clams",
    "armorTypes": [None, "General Armor"],
    "weaponTypes": [None, "General Weapon"],
    "skillTypes": [None, "Magic", "Special"],
    "optFollowers": True, "optDisplayTp": False,
    "testTroopId": 1, "titleBgm": {"name": "", "volume": 90, "pitch": 100, "pan": 0},
    "sounds": {}, "battleBgm": {"name": "battle1", "volume": 90, "pitch": 100, "pan": 0},
})

# Actors: OMORI (id 1).
w("Actors.json", [None, {
    "id": 1, "name": "OMORI", "nickname": "", "profile": "You've been living here for as long as you can remember.",
    "classId": 1, "initialLevel": 1, "maxLevel": 99, "equips": [1, 0, 0, 0, 0],
    "characterName": "", "characterIndex": 0, "faceName": "", "faceIndex": 0,
    "battlerName": "omori", "battlerHue": 0, "traits": [],
}])

# Classes: params[8][2] (level rows), one learning.
w("Classes.json", [None, {
    "id": 1, "name": "OMORI CLASS",
    "expParams": [30, 20, 30, 30],
    "params": [[500, 520], [50, 55], [20, 21], [20, 20], [20, 20], [20, 20], [20, 20], [20, 20]],
    "learnings": [{"level": 1, "note": "", "skillId": 1}],
    "traits": [],
}])

# Skills: 1 = attack (MV contract), 2 = emotion hit.
w("Skills.json", [None, {
    "id": 1, "name": "Attack", "mpCost": 0, "tpCost": 0, "message1": "", "message2": "",
    "successRate": 100, "hitType": 1, "animationId": 1, "scope": 1, "damage": {
        "type": 1, "elementId": -1, "formula": "a.atk * 4 - b.def * 2",
        "variance": 20, "critical": True},
    "effects": [], "note": "",
}, {
    "id": 2, "name": "Happy Hit", "mpCost": 5, "tpCost": 0, "successRate": 100,
    "hitType": 1, "animationId": 1, "scope": 2, "damage": {
        "type": 1, "elementId": -1, "formula": "a.atk * 3 - b.def", "variance": 15, "critical": False},
    "effects": [{"code": 21, "dataId": 6, "value1": 3, "value2": 0}], "note": "",
}])

# States: 1 = KO, 6 = HAPPY (emotion substrate).
w("States.json", [None, {
    "id": 1, "name": "KO", "restriction": 4, "priority": 100,
    "minTurns": 1, "maxTurns": 1, "traits": [], "note": "",
}, None, None, None, None, {
    "id": 6, "name": "HAPPY", "restriction": 0, "priority": 50,
    "minTurns": 3, "maxTurns": 5, "traits": [{"code": 21, "dataId": 6, "value": 0.25}],
    "note": "<emotion: happy>",
}])

# Enemies: 1 = LARVA-THING.
w("Enemies.json", [None, {
    "id": 1, "name": "LARVA-THING", "battlerName": "larva", "battlerHue": 0,
    "params": [60, 20, 12, 6, 8, 8, 10, 6], "exp": 20, "gold": 15,
    "dropItems": [{"kind": 1, "dataId": 3, "denominator": 2}],
    "actions": [
        {"skillId": 1, "rating": 5, "conditionType": 0, "conditionParam1": 0, "conditionParam2": 0},
        {"skillId": 2, "rating": 3, "conditionType": 2, "conditionParam1": 1, "conditionParam2": 100},
    ],
    "traits": [],
}])

# Troops: 1 = LARVA x2 with a turn-2 battle-event page.
w("Troops.json", [None, {
    "id": 1, "name": "LARVA-THING x2",
    "members": [
        {"enemyId": 1, "x": 300, "y": 240, "hidden": False},
        {"enemyId": 1, "x": 500, "y": 240, "hidden": False},
    ],
    "pages": [{
        "condition": {"turnValid": True, "turnA": 2, "turnB": 0,
                      "enemyValid": False, "enemyIndex": 0, "enemyHp": 50,
                      "actorValid": False, "actorId": 1, "actorHp": 50,
                      "switchValid": False, "switchId": 1},
        "span": 1,
        "list": [
            {"code": 101, "indent": 0, "parameters": ["", 0, 0, 2]},
            {"code": 401, "indent": 0, "parameters": ["The LARVA-THING wriggles menacingly!"]},
            {"code": 0, "indent": 0, "parameters": []},
        ],
    }],
}])

# Items / weapons / armors.
w("Items.json", [None, None, None, {
    "id": 3, "name": "Toast", "iconIndex": 0, "price": 50,
    "consumable": True, "scope": 7, "occasion": 1, "damage": {
        "type": 3, "elementId": -1, "formula": "0", "variance": 0, "critical": False},
    "effects": [{"code": 11, "dataId": 0, "value1": 0.5, "value2": 0}],
    "note": "",
}])
w("Weapons.json", [None, {
    "id": 1, "name": "Sturdy Toy Knife (Synthetic)", "iconIndex": 0, "price": 100,
    "params": [0, 0, 10, 0, 0, 0, 0, 0], "traits": [], "note": "",
}])
w("Armors.json", [None, {
    "id": 1, "name": "Synthetic Shirt", "iconIndex": 0, "price": 50,
    "params": [10, 0, 0, 5, 0, 0, 0, 0], "traits": [], "note": "",
}])

# Animations / Tilesets.
w("Animations.json", [None, {"id": 1, "name": "Hit (Synthetic)", "frames": [], "timings": [], "animation1Name": "", "animation1Hue": 0, "animation2Name": "", "animation2Hue": 0}])
w("Tilesets.json", [None] * 9 + [{"id": 9, "name": "SYNTH", "tilesetNames": ["", "", "", "", "", "Synth_B", "", "", ""], "flags": [0] * 256, "mode": 0, "note": ""}])

# CommonEvents: 1 = a simple switch setter.
w("CommonEvents.json", [None, {
    "id": 1, "name": "SET FLAG", "trigger": 0, "switchId": 1, "list": [
        {"code": 121, "indent": 0, "parameters": [1, 1, 0]},
        {"code": 0, "indent": 0, "parameters": []},
    ]}])

# Map999: the intro (autorun event 1) + a transfer to Map87.
w("Map999.json", {
    "id": 999, "name": "INTRO (SYNTHETIC)", "note": "", "width": 17, "height": 13,
    "tilesetId": 9, "encounterList": [], "encounterStep": 30,
    "autoplayBgm": False, "autoplayBgs": False, "bgm": {"name": "", "volume": 90, "pitch": 100, "pan": 0},
    "bgs": {"name": "", "volume": 90, "pitch": 100, "pan": 0},
    "parallaxName": "", "parallaxLoopX": False, "parallaxLoopY": False,
    "parallaxSx": 0, "parallaxSy": 0, "parallaxShow": False,
    "scrollType": 0, "specifyBattleback": False, "battleback1Name": "", "battleback2Name": "",
    "data": [1] * (17 * 13) + [0] * (17 * 13 * 5),
    "events": [None, {
        "id": 1, "name": "INTRO", "note": "", "x": 8, "y": 6, "pages": [{
            "id": 1, "name": "", "note": "", "conditions": {"actorId": 1, "actorValid": False, "itemValid": False, "itemId": 1, "selfSwitchCh": "A", "selfSwitchValid": False, "switchId": 1, "switchValid": False, "variableId": 1, "variableValid": False, "variableValue": 0},
            "trigger": 3, "list": [
                {"code": 101, "indent": 0, "parameters": ["", 0, 0, 2]},
                {"code": 401, "indent": 0, "parameters": ["..."]},
                {"code": 401, "indent": 0, "parameters": ["(SYNTHETIC INTRO) You wake up in WHITE SPACE."]},
                {"code": 101, "indent": 0, "parameters": ["", 0, 0, 2]},
                {"code": 401, "indent": 0, "parameters": ["Something is different today..."]},
                {"code": 301, "indent": 0, "parameters": [0, 1, 1, 0]},
                {"code": 601, "indent": 0, "parameters": []},
                {"code": 121, "indent": 1, "parameters": [2, 2, 0]},
                {"code": 604, "indent": 0, "parameters": []},
                {"code": 123, "indent": 0, "parameters": ["A", 0]},
                {"code": 201, "indent": 0, "parameters": [0, 87, 5, 5, 2, 0]},
                {"code": 0, "indent": 0, "parameters": []},
            ],
        }],
    }],
})

# Map87: the landing map.
w("Map087.json", {
    "id": 87, "name": "NEIGHBORHOOD (SYNTHETIC)", "note": "", "width": 17, "height": 13,
    "tilesetId": 9, "encounterList": [{"troopId": 1, "weight": 5, "regionSet": []}],
    "encounterStep": 30, "autoplayBgm": False, "autoplayBgs": False,
    "bgm": {"name": "", "volume": 90, "pitch": 100, "pan": 0},
    "bgs": {"name": "", "volume": 90, "pitch": 100, "pan": 0},
    "parallaxName": "", "parallaxLoopX": False, "parallaxLoopY": False,
    "parallaxSx": 0, "parallaxSy": 0, "parallaxShow": False,
    "scrollType": 0, "specifyBattleback": False, "battleback1Name": "", "battleback2Name": "",
    "data": [1] * (17 * 13) + [0] * (17 * 13 * 5),
    "events": [None],
})
print("database written")
PYEOF

# --- Languages (the M5 language pipeline) -------------------------------------
cat > "$ROOT/Languages/en/t.yaml" << 'EOF'
language: en
messages:
  nothing: "nothing."
  blue1: "It's a beautiful day."
  blue2: "The lightbulb flickers."
EOF

cat > "$ROOT/Languages/en/XX_BLUE.yaml" << 'EOF'
Omori_Title_Screen:
  commands:
    - NEW GAME
    - CONTINUE
    - OPTIONS
    - PORTED BY
EOF

# --- Atlas + sheet (a real lossless WebP with .png extension — the payload contract)
python3 - "$ROOT" << 'PYEOF'
import sys, os
from PIL import Image, ImageDraw
root = sys.argv[1]
# 64x48 RGB lossless WebP saved as .png (the payload's naming contract).
img = Image.new("RGB", (64, 48), (32, 32, 48))
for x in range(0, 64, 8):
    for y in range(0, 48, 8):
        img.putpixel((x, y), (200, 200, 220))
img.save(os.path.join(root, "img/atlases/Synth_Sheet.png"), "WEBP", lossless=True)
print("atlas sheet written (lossless webp, .png name)")

# Procedural test art covers every title source rectangle and the live
# field/window paths. These are synthetic shapes, not game assets.
title = Image.new("RGB", (1464, 1053), (245, 245, 245))
pen = ImageDraw.Draw(title)
pen.rectangle((24, 24, 893, 326), fill=(35, 35, 45))
pen.rectangle((930, 12, 1180, 138), fill=(120, 140, 180))
pen.ellipse((1400, 22, 1462, 148), fill=(240, 210, 70))
title.save(os.path.join(root, "img/atlases/Omori_TitleScreen.png"), "WEBP", lossless=True)

# OMORI's normal character sheet is 6 columns by 16 rows.
chars = Image.new("RGBA", (288, 768), (0, 0, 0, 0))
pen = ImageDraw.Draw(chars)
for col in range(6):
    for row in range(16):
        x, y = col * 48, row * 48
        pen.rectangle((x + 12, y + 6, x + 35, y + 46), fill=(200, 210, 230, 255))
chars.save(os.path.join(root, "img/characters/OMORI.png"), "WEBP", lossless=True)

skin = Image.new("RGB", (96, 96), (25, 25, 35))
ImageDraw.Draw(skin).rectangle((0, 0, 95, 95), outline=(220, 220, 230), width=4)
skin.save(os.path.join(root, "img/system/Window.png"), "WEBP", lossless=True)

tiles = Image.new("RGB", (768, 768), (60, 75, 95))
pen = ImageDraw.Draw(tiles)
for x in range(0, 768, 48):
    for y in range(0, 768, 48):
        pen.rectangle((x, y, x + 47, y + 47), outline=(90, 105, 125))
tiles.save(os.path.join(root, "img/tilesets/Synth_B.png"), "WEBP", lossless=True)
enemy = Image.new("RGBA", (96, 96), (0, 0, 0, 0))
ImageDraw.Draw(enemy).ellipse((8, 20, 88, 88), fill=(170, 120, 95, 255))
enemy.save(os.path.join(root, "img/enemies/larva.png"), "WEBP", lossless=True)
print("synthetic title, character, windowskin, tileset and enemy written")
PYEOF

cat > "$ROOT/data/Atlas.yaml" << 'EOF'
source:

  img/pictures/SYNTH_BG.png:
    atlasName: Synth_Sheet
    rect: {x: 0, y: 0, width: 64, height: 48}
    sourceRect: {x: 0, y: 0, width: 64, height: 48}
EOF

# --- fonts: a real rasterizable TTF (v28 needs one for the window/text
#     shell; the real payload supplies OMORI_GAME2.ttf — BYO-data). A
#     system DejaVu/Noto font stands in on synthetic trees.
if [ -f /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf ]; then
    cp /usr/share/fonts/truetype/dejavu/DejaVuSans.ttf "$ROOT/fonts/OMORI_GAME2.ttf"
elif [ -f /usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf ]; then
    cp /usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf "$ROOT/fonts/OMORI_GAME2.ttf"
fi

# --- audio stubs (the registry probes extensions; empty files are fine)
for f in battle1.ogg; do : > "$ROOT/audio/bgm/$f"; done

# The payload contract: data/*.json at the root (nwjs path) mirrors
# js/data (browser path) — the runtime boots from data/.
cp "$ROOT"/js/data/*.json "$ROOT"/data/
echo '{"nullArray":[null,"Map 999: INTRO","Map 87: NEIGHBORHOOD"]}' > "$ROOT/data/MapInfos.json"
echo "synthetic tree ready: $ROOT"
