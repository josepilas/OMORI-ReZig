#!/usr/bin/env python3
"""Batch byte-exact validation of the native VP8L decoder against Pillow.

Iterates over EVERY .png-under-.png-clothing image in the payload's img/
tree, decodes each with the Zig vp8l_check harness (raw RGBA dump), and
compares bytes with Pillow's decode (tobytes, C-level speed).

Usage: python3 vp8l_batch_validate.py <game_root> <vp8l_check_bin> [limit]
Prints progress every 50 files; final line is the verdict.
"""
import os
import subprocess
import sys
from PIL import Image

RAW = "/tmp/zig_rgba_batch.raw"


def main():
    game_root = sys.argv[1]
    bin_path = sys.argv[2]
    limit = int(sys.argv[3]) if len(sys.argv) > 3 else 0

    # Collect all images under img/ (the payload's WebP-in-.png set).
    images = []
    for dirpath, _dirs, files in os.walk(os.path.join(game_root, "img")):
        for f in sorted(files):
            if f.lower().endswith((".png", ".webp")):
                images.append(os.path.join(dirpath, f))
    images.sort()
    if limit:
        images = images[:limit]

    total = len(images)
    matched = 0
    mismatched = 0
    failed = 0
    failures = []

    print(f"validating {total} images against Pillow decode ...")

    for i, path in enumerate(images):
        try:
            if os.path.exists(RAW):
                os.unlink(RAW)
            env = dict(os.environ)
            env["VP8L_DUMP"] = RAW
            out = subprocess.run(
                [bin_path, path], capture_output=True, text=True,
                timeout=120, env=env,
            )
            if out.returncode != 0 or "OK " not in out.stderr:
                failed += 1
                failures.append((path, "zig decode failed: " + out.stderr.strip()[:160]))
                continue
            line = [l for l in out.stderr.splitlines() if l.startswith("OK ")][0]
            w, h = (int(x) for x in line.split()[1].split("x"))
            with open(RAW, "rb") as fh:
                zig = fh.read()
            with Image.open(path) as im:
                im = im.convert("RGBA")
                if im.size != (w, h):
                    failed += 1
                    failures.append((path, f"size zig {w}x{h} vs ref {im.size}"))
                    continue
                ref = im.tobytes()
            if zig == ref:
                matched += 1
            else:
                diff = sum(1 for a, b in zip(zig, ref) if a != b)
                mismatched += 1
                failures.append((path, f"pixel mismatch {diff}/{len(ref)} bytes"))
        except Exception as e:  # noqa: BLE001 — report and continue
            failed += 1
            failures.append((path, f"exception {e}"))
        if (i + 1) % 50 == 0:
            print(f"  {i+1}/{total}: {matched} match, {mismatched} mismatch, {failed} failed")

    print(f"\nVP8L BATCH VERDICT: {matched}/{total} byte-identical, "
          f"{mismatched} mismatched, {failed} failed")
    for path, why in failures[:20]:
        print(f"  FAIL {path}: {why}")
    if failures:
        print(f"  ... {len(failures)} failure line(s) total")
    return 0 if (mismatched == 0 and failed == 0) else 1


if __name__ == "__main__":
    sys.exit(main())
