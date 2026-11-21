#!/usr/bin/env python3
"""M5 command-code census over the full OMORI payload.

Counts every event-command code used across:
  * all Map###.json event pages
  * all $dataCommonEvents lists
  * Troops pages (battle events)
Also counts 111 condition types, 122 operand kinds, and the nested
move-route codes inside 205 parameters.

Usage: python3 command_census.py <game_root>
"""
import json
import os
import sys
from collections import Counter

NAMES = {
    0: "empty", 101: "ShowText", 102: "ShowChoices", 103: "InputNumber",
    104: "SelectItem", 105: "ScrollingText", 108: "Comment",
    111: "If", 112: "Loop", 113: "BreakLoop", 115: "ExitProcessing",
    117: "CommonEvent", 118: "Label", 119: "JumpToLabel",
    121: "Switches", 122: "Variables", 123: "SelfSwitch", 124: "Timer",
    125: "Gold", 126: "Items", 127: "Weapons", 128: "Armors",
    129: "PartyMember", 132: "BattleBGM", 133: "VictoryME",
    134: "SaveAccess", 135: "MenuAccess", 136: "Encounter",
    137: "FormationAccess", 138: "WindowColor", 139: "DefeatME",
    140: "VehicleBGM",
    201: "TransferPlayer", 202: "VehicleLocation", 203: "EventLocation",
    204: "ScrollMap", 205: "MovementRoute", 206: "VehicleOnOff",
    211: "Transparency", 212: "Animation", 213: "Balloon",
    214: "EraseEvent", 216: "Followers", 217: "GatherFollowers",
    221: "Fadeout", 222: "Fadein", 223: "Tint", 224: "Flash",
    225: "Shake", 230: "Wait", 231: "ShowPicture", 232: "MovePicture",
    233: "RotatePicture", 234: "TintPicture", 235: "ErasePicture",
    236: "Weather",
    241: "PlayBGM", 242: "FadeoutBGM", 243: "SaveBGM", 244: "ResumeBGM",
    245: "PlayBGS", 246: "FadeoutBGS", 249: "PlayME", 250: "PlaySE",
    251: "StopSE", 261: "PlayMovie",
    281: "ChangeTileset", 282: "ChangeBattleback", 283: "ChangeParallax",
    301: "BattleProcessing", 302: "ShopProcessing", 303: "NameInput",
    311: "ChangeHP", 312: "ChangeMP", 313: "ChangeState", 314: "RecoverAll",
    315: "ChangeEXP", 316: "ChangeLevel", 317: "ChangeParam",
    318: "ChangeSkill", 319: "ChangeEquip", 320: "ChangeName",
    321: "ChangeClass", 322: "ChangeActorImages", 323: "ChangeVehicleImage",
    324: "ChangeNickname", 325: "ChangeProfile",
    331: "EnemyHP", 332: "EnemyMP", 333: "EnemyState", 334: "EnemyRecover",
    335: "EnemyAppear", 336: "EnemyTransform", 337: "BattleAnim",
    339: "ForceAction", 340: "AbortBattle",
    342: "EnemyTP", 351: "OpenMenu", 352: "OpenSave", 353: "GameOver",
    354: "ReturnToTitle", 355: "Script", 356: "PluginCommand",
    357: "SelfVariables",
    401: "TextData", 402: "When[**]", 403: "WhenCancel", 405: "ScrollData",
    408: "CommentCont", 411: "Else", 412: "EndIf", 413: "RepeatAbove",
    601: "IfWin", 602: "IfEscape", 603: "IfLose", 655: "ScriptCont",
    505: "MoveRouteCmd",
}

# Which codes the M5 field interpreter must implement vs. defer.
BATTLE_ONLY = {301, 331, 332, 333, 334, 335, 336, 337, 339, 340, 342,
               601, 602, 603}
SCENE_ONLY = {351, 352, 353, 354, 355, 356}


def walk_commands(lst, stats):
    for cmd in lst:
        code = cmd.get("code", 0)
        stats[code] += 1
        params = cmd.get("parameters") or []
        # nested move-route commands inside 205 params[1].list
        if code == 205 and len(params) > 1 and isinstance(params[1], dict):
            for ic in params[1].get("list") or []:
                stats[("move", ic.get("code", 0))] += 1
        if code == 122:
            if len(params) > 3:
                stats[("122_operand", params[3])] += 1
        if code == 111:
            if params:
                stats[("111_type", params[0])] += 1


def main():
    root = sys.argv[1]
    data = os.path.join(root, "data")
    stats = Counter()
    maps_scanned = 0
    common_scanned = 0
    troops_scanned = 0

    for name in sorted(os.listdir(data)):
        if not (name.startswith("Map") and name.endswith(".json")):
            continue
        try:
            with open(os.path.join(data, name), "r", encoding="utf-8") as fh:
                m = json.load(fh)
        except Exception as e:
            print(f"  !! {name}: {e}")
            continue
        maps_scanned += 1
        events = m.get("events") if isinstance(m, dict) else None
        for ev in events or []:
            if not ev:
                continue
            for page in ev.get("pages") or []:
                walk_commands(page.get("list") or [], stats)

    with open(os.path.join(data, "CommonEvents.json"), "r", encoding="utf-8") as fh:
        ces = json.load(fh)
    for ce in ces:
        if not ce:
            continue
        common_scanned += 1
        walk_commands(ce.get("list") or [], stats)

    with open(os.path.join(data, "Troops.json"), "r", encoding="utf-8") as fh:
        troops = json.load(fh)
    for tr in troops:
        if not tr:
            continue
        troops_scanned += 1
        for page in tr.get("pages") or []:
            walk_commands(page.get("list") or [], stats)

    print(f"scanned: {maps_scanned} maps, {common_scanned} common events, "
          f"{troops_scanned} troops")
    print()

    plain = {k: v for k, v in stats.items() if isinstance(k, int)}
    print("=== event command codes (all sources) ===")
    field_codes = []
    for code in sorted(plain):
        n = plain[code]
        nm = NAMES.get(code, "???")
        where = "FIELD" if code not in BATTLE_ONLY | SCENE_ONLY else (
            "BATTLE" if code in BATTLE_ONLY else "SCENE")
        print(f"  {code:4d} {nm:22s} {n:7d}  [{where}]")
        if where == "FIELD":
            field_codes.append(code)

    print()
    print("=== nested move-route codes (inside 205) ===")
    for (tag, code), n in sorted(((k, v) for k, v in stats.items()
                                  if isinstance(k, tuple) and k[0] == "move"),
                                 key=lambda kv: kv[0][1]):
        print(f"  move {code:4d} x{n}")

    print()
    print("=== 111 condition types ===")
    for (tag, t), n in sorted(((k, v) for k, v in stats.items()
                               if isinstance(k, tuple) and k[0] == "111_type"),
                              key=lambda kv: kv[0][1]):
        print(f"  type {t} x{n}")

    print()
    print("=== 122 operand kinds ===")
    for (tag, t), n in sorted(((k, v) for k, v in stats.items()
                               if isinstance(k, tuple) and k[0] == "122_operand"),
                              key=lambda kv: kv[0][1]):
        print(f"  operand {t} x{n}")

    print()
    print(f"FIELD codes for M5 ({len(field_codes)}): {field_codes}")


if __name__ == "__main__":
    main()
