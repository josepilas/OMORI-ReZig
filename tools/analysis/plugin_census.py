#!/usr/bin/env python3
"""Plugin-command (356) + Script (355) census for M5.

OMORI uses 34,797 356 PluginCommand and 10,878 355 Script commands —
the interpreter must know which plugin names / top-level script
statements actually appear, so the native dispatcher can be sized
honestly (implemented / logged-and-skipped).

Usage: python3 plugin_census.py <game_root>
"""
import json
import os
import re
import sys
from collections import Counter


def main():
    root = sys.argv[1]
    data = os.path.join(root, "data")

    plugin_cmds = Counter()      # (plugin command name -> count)
    script_stmts = Counter()     # (first identifier of each script line)
    sources = Counter()          # which database the commands came from

    def scan_list(lst, tag):
        for cmd in lst:
            code = cmd.get("code", 0)
            if code == 356:
                p = cmd.get("parameters") or [""]
                text = (p[0] or "").strip()
                if not text:
                    continue
                name = text.split(" ")[0]
                plugin_cmds[name] += 1
                sources[tag] += 1
            elif code == 355:
                p = cmd.get("parameters") or [""]
                text = (p[0] or "")
                # collect 655 continuations is done by caller; here just
                # first token of first line
                for line in text.splitlines():
                    line = line.strip()
                    if not line or line.startswith("//"):
                        continue
                    m = re.match(r"^[A-Za-z_$][A-Za-z0-9_$.]*", line)
                    if m:
                        script_stmts[m.group(0)] += 1
                    break

    # maps
    for name in sorted(os.listdir(data)):
        if not (name.startswith("Map") and name.endswith(".json")):
            continue
        try:
            with open(os.path.join(data, name), "r", encoding="utf-8") as fh:
                m = json.load(fh)
        except Exception:
            continue
        if not isinstance(m, dict):
            continue
        for ev in m.get("events") or []:
            if not ev:
                continue
            for page in ev.get("pages") or []:
                scan_list(page.get("list") or [], "maps")

    with open(os.path.join(data, "CommonEvents.json"), "r", encoding="utf-8") as fh:
        for ce in json.load(fh):
            if ce:
                scan_list(ce.get("list") or [], "common")

    with open(os.path.join(data, "Troops.json"), "r", encoding="utf-8") as fh:
        for tr in json.load(fh):
            if not tr:
                continue
            for page in tr.get("pages") or []:
                scan_list(page.get("list") or [], "troops")

    print("=== 356 plugin command names ===")
    for name, n in plugin_cmds.most_common():
        print(f"  {n:7d}  {name}")

    print()
    print(f"sources: {dict(sources)}")
    print()
    print("=== 355 script first-tokens (top 60) ===")
    for name, n in script_stmts.most_common(60):
        print(f"  {n:7d}  {name}")


if __name__ == "__main__":
    main()
