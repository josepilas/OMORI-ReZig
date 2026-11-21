#!/usr/bin/env python3
"""Payload format census — the tool that discovered the WebP-in-.png fact.

Walks the extracted game root and reports actual stream signatures
(PNG / WebP / JPEG / OGG / M4A / WEBM / JSON / other) regardless of file
extension. This is the evidence base for the behavioral spec §4 and for
the decoder decisions in the renderer/audio milestones.

Usage: python3 format_census.py <game_root>
"""
import os
import sys
from collections import Counter


def signature(head, name):
    if head[:8] == bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]):
        return "png"
    if head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "webp"
    if head[:2] == b"\xff\xd8":
        return "jpeg"
    if head[:4] == b"OggS":
        return "ogg"
    if head[:4] == b"ftyp":
        return "m4a/mp4"
    if head[:4] == b"\x1a\x45\xdf\xa3":
        return "webm/mkv"
    if name.endswith(".json") or head[:1] in (b"[", b"{"):
        return "json/text"
    if head[:5] == b"<?xml" or head[:4] == b"img/" or head[:7] == b"source:":
        return "xml/yaml/text"
    return "other:" + head[:4].hex()


def main():
    root = sys.argv[1]
    by_ext = Counter()      # (extension -> actual format)
    by_fmt = Counter()
    mismatches = Counter()  # extension says X, stream says Y
    for dirpath, _dirs, files in os.walk(root):
        for name in files:
            path = os.path.join(dirpath, name)
            try:
                with open(path, "rb") as fh:
                    head = fh.read(16)
            except OSError:
                continue
            fmt = signature(head, name)
            ext = os.path.splitext(name)[1].lower() or "(none)"
            by_ext[(ext, fmt)] += 1
            by_fmt[fmt] += 1
            if ext == ".png" and fmt != "png":
                mismatches[f".png -> {fmt}"] += 1

    print("== formats by actual stream signature ==")
    for fmt, n in by_fmt.most_common():
        print(f"  {fmt:20s} {n}")

    print("\n== extension vs signature mismatches ==")
    for m, n in mismatches.most_common():
        print(f"  {m:30s} {n}")

    print("\n== extension/format matrix (top 20) ==")
    for (ext, fmt), n in by_ext.most_common(20):
        print(f"  {ext:10s} {fmt:20s} {n}")


if __name__ == "__main__":
    main()
