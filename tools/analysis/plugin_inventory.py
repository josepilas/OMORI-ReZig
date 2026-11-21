#!/usr/bin/env python3
"""OMORI payload analysis: plugin inventory (§13 of the pivot spec).

Inventories every plugin the payload ships (js/plugins.js), groups them,
and reports which ones the native runtime must investigate for behavioral
reimplementation. Never assumes plugins away — outputs the work list.

Usage: python3 plugin_inventory.py <game_root> [--json out.json]
"""
import json
import os
import re
import sys


def parse_plugins(path):
    # plugins.js is JavaScript: `var $plugins = [...]` with raw control
    # characters inside strings. Use a JS-capable parser if available,
    # else a tolerant extraction.
    try:
        import subprocess
        out = subprocess.run(
            ["node", "-e",
             "const fs=require('fs');eval(fs.readFileSync(process.argv[1],'utf8'));"
             "process.stdout.write(JSON.stringify($plugins))", path],
            capture_output=True, text=True, check=True, timeout=30)
        return json.loads(out.stdout)
    except Exception:
        pass
    src = open(path, encoding="utf-8", errors="replace").read()
    m = re.search(r"\$plugins\s*=\s*(\[.*\])\s*;", src, re.S)
    return json.loads(m.group(1), strict=False)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    root = sys.argv[1]
    plugins_path = os.path.join(root, "js", "plugins.js")
    plugins = parse_plugins(plugins_path)
    print(f"total plugins: {len(plugins)}")

    enabled = [p for p in plugins if p.get("status")]
    print(f"enabled: {len(enabled)}")

    # Groups the pivot calls out as behaviorally critical (evidence from
    # the v1-v21 failure chain and boot milestones).
    critical = ("OmoriFixes", "Aetherflow", "Atlas Loader",
                "Text_Language_Processor", "Community_Basic",
                "Cordova", "YSP_VideoPlayer", "Storage")
    print("\n-- behaviorally critical (documented evidence) --")
    for i, p in enumerate(plugins):
        if any(k in p.get("name", "") for k in critical):
            print(f"  [{i:3d}] {p['name']}  (status={p.get('status')})")

    print(f"\n-- work list: {len(enabled)} enabled plugins to inventory "
          "for native reimplementation (sorted by name) --")
    for p in sorted(enabled, key=lambda x: x.get("name", "")):
        print(f"  {p.get('name')}")

    out_path = None
    if "--json" in sys.argv:
        out_path = sys.argv[sys.argv.index("--json") + 1]
    if out_path:
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(plugins, f, indent=1)
        print(f"\nwrote {out_path}")


if __name__ == "__main__":
    sys.exit(main())
