#!/usr/bin/env python3
"""Byte-exact validation of the native VP8L decoder against Pillow.

Compares RGBA pixels of the Zig decoder output (dumped via vp8l_check's
stderr format) with Pillow's decode of the same file.
"""
import subprocess
import sys
from PIL import Image


def zig_pixels(path):
    out = subprocess.run(["/tmp/vp8l_check", path], capture_output=True, text=True, timeout=600)
    if out.returncode != 0 or "OK " not in out.stderr:
        print(f"ZIG DECODE FAILED for {path}: {out.stderr.strip()[:200]}")
        return None
    line = [l for l in out.stderr.splitlines() if l.startswith("OK ")][0]
    w, h = map(int, line.split()[1].split("x"))
    return w, h


def ref_pixels(path):
    im = Image.open(path).convert("RGBA")
    return im.size, list(im.getdata())


def main():
    path = sys.argv[1]
    zinfo = zig_pixels(path)
    if zinfo is None:
        return 1
    (w, h), ref = ref_pixels(path)
    if (w, h) != zinfo:
        print(f"SIZE MISMATCH: zig {zinfo} vs ref {(w, h)}")
        return 1

    # full byte compare: have the Zig side write raw RGBA to a file
    # (via the harness's pixels — extend: rerun with raw output)
    import os
    raw_path = "/tmp/zig_rgba.raw"
    # zig harness already computed; make it dump raw by re-running with env
    env = dict(os.environ)
    env["VP8L_DUMP"] = raw_path
    out = subprocess.run(["/tmp/vp8l_check", path], capture_output=True, text=True, timeout=600, env=env)
    _ = out
    if not os.path.exists(raw_path):
        print("no raw dump support; falling back to sample compare")
        return 1
    with open(raw_path, "rb") as fh:
        zig = fh.read()
    import struct
    ref_bytes = b"".join(struct.pack("4B", *p) for p in ref)
    if zig == ref_bytes:
        print(f"MATCH: {path} ({w}x{h}, {len(zig)} bytes RGBA) — byte-identical to Pillow")
        return 0
    diff = sum(1 for a, b in zip(zig, ref_bytes) if a != b)
    print(f"PIXEL MISMATCH: {path} — {diff}/{len(ref_bytes)} bytes differ")
    for i, (a, b) in enumerate(zip(zig, ref_bytes)):
        if a != b:
            print(f"  first diff at byte {i} (pixel {i//4}, channel {i%4}): zig={a} ref={b}")
            break
    return 1


if __name__ == "__main__":
    sys.exit(main())
