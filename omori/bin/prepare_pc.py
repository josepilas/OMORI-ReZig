#!/usr/bin/env python3
"""Prepare a user-supplied OMORI PC data tree for the native port.

The shipped JavaScript loaders define the file formats: AES-256-CTR with a
16-byte IV for database/plugin files, and RPG Maker MV's header/XOR wrapper
for PNG/Ogg assets.  No game executable or authorization code is changed.
Only Python's standard library and the firmware's OpenSSL are required.
"""

import argparse
import ctypes
import ctypes.util
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import uuid


FORMAT_VERSION = 1
MARKER = ".omori-pc-import.json"
RPGMV_HEADER = bytes.fromhex("5250474d560000000003010000000000")
AES_EXTENSIONS = {".kel": ".json", ".aubrey": ".json", ".pluto": ".yaml",
                  ".hero": ".yaml", ".omori": ".js"}
MV_EXTENSIONS = {".rpgmvp": ".png", ".rpgmvo": ".ogg", ".rpgmvm": ".m4a"}
SKIP_DIRS = {"save", "saves", "logs", "extracted", "__pycache__", ".git"}
KEY_FILE = "omori-pc-key.txt"


class PCImportError(RuntimeError):
    pass


class PCImportCancelled(PCImportError):
    pass


def _child(directory, name):
    """Find a directory entry on both case-sensitive Linux and PC filesystems."""
    directory = Path(directory)
    exact = directory / name
    if exact.exists():
        return exact
    if directory.is_dir():
        matches = [p for p in directory.iterdir() if p.name.casefold() == name.casefold()]
        if len(matches) == 1:
            return matches[0]
    return exact


def _looks_like_www(path):
    return (path.is_dir() and _child(path, "index.html").is_file()
            and _child(path, "img").is_dir() and _child(path, "js").is_dir()
            and any(_child(_child(path, "data"), n).is_file()
                    for n in ("System.KEL", "System.json")))


def detect_pc(original_dir):
    """Return the copied PC www root, accepting direct and nested installs.

    Search only the input itself and two installation levels; never recurse
    into an existing prepared extraction or backup and mistake it for input.
    """
    original = Path(original_dir).expanduser().resolve()
    if not original.is_dir():
        return None
    candidates = []
    for candidate in (original, _child(original, "www")):
        if _looks_like_www(candidate):
            candidates.append(candidate)
    if not candidates:
        for entry in sorted(original.iterdir(), key=lambda p: p.name.casefold()):
            if (not entry.is_dir() or entry.is_symlink()
                    or entry.name.casefold() in SKIP_DIRS
                    or entry.name.startswith(".") or ".previous-pc-" in entry.name):
                continue
            for candidate in (entry, _child(entry, "www")):
                if _looks_like_www(candidate):
                    candidates.append(candidate)
    roots = sorted(set(p.resolve() for p in candidates), key=str)
    if len(roots) > 1:
        raise PCImportError("More than one PC game installation is present in original; keep one installation there.")
    if not roots:
        return None
    return {"kind": "pc", "root": str(roots[0]), "original": str(original)}


def _files(root):
    result = []
    for directory, dirs, files in os.walk(root, followlinks=False):
        folder = Path(directory)
        for name in dirs:
            if (folder / name).is_symlink():
                raise PCImportError("PC data contains a directory link; copy the real game files instead.")
        dirs[:] = sorted(d for d in dirs if d.casefold() not in SKIP_DIRS
                         and not d.startswith("."))
        for name in sorted(files):
            path = folder / name
            if path.is_symlink():
                raise PCImportError("PC data contains a file link; copy the real game files instead.")
            if (name.startswith(".") or name.casefold() == KEY_FILE
                    or path.suffix.casefold() in (".rpgsave", ".bak")):
                continue
            result.append(path)
    return result


def _key_candidates(original, root):
    parents = [original, root, root.parent]
    result = []
    for parent in parents:
        if not parent.is_dir():
            continue
        for p in parent.iterdir():
            if p.is_file() and (p.name.casefold() == KEY_FILE or
                               (p.suffix.casefold() in (".bat", ".cmd", ".sh")
                                and "omori" in p.name.casefold())):
                if p not in result:
                    result.append(p)
    return sorted(result, key=str)


def _fingerprint(info, files):
    digest = hashlib.sha256()
    root = Path(info["root"])
    for path in files:
        st = path.stat()
        digest.update(path.relative_to(root).as_posix().encode("utf-8"))
        digest.update(("\0%d:%d\n" % (st.st_size, st.st_mtime_ns)).encode("ascii"))
    for path in _key_candidates(Path(info["original"]), root):
        st = path.stat()
        digest.update((path.name + "\0%d:%d\n" % (st.st_size, st.st_mtime_ns)).encode("utf-8"))
    return digest.hexdigest()


def _critical_tree(www):
    return all((www / p).is_file() for p in
               ("index.html", "data/System.json", "data/Actors.json", "data/MapInfos.json",
                "data/Atlas.yaml")) and (www / "img").is_dir() and (www / "Languages").is_dir()


def is_prepared_pc(original_dir, extract_to):
    info = detect_pc(original_dir)
    if not info:
        return False
    target = Path(extract_to).resolve()
    try:
        manifest = json.loads((target / MARKER).read_text(encoding="utf-8"))
        return (manifest.get("formatVersion") == FORMAT_VERSION
                and manifest.get("kind") == "pc"
                and manifest.get("fingerprint") == _fingerprint(info, _files(Path(info["root"])))
                and _critical_tree(target / "assets" / "www"))
    except (OSError, ValueError):
        return False


def _read_key(info):
    keys = set()
    for path in _key_candidates(Path(info["original"]), Path(info["root"])):
        if path.stat().st_size > 65536:
            continue
        raw = path.read_bytes()
        if path.name.casefold() == KEY_FILE:
            token = raw.strip()
            if len(token) == 32:
                keys.add(token)
        else:
            # This is the raw UTF-8 command-line argument used by the game's
            # JavaScript loader, not a hexadecimal key to be decoded.
            for match in re.finditer(rb"--([A-Za-z0-9]{32})(?![A-Za-z0-9])", raw):
                keys.add(match.group(1))
    if not keys:
        raise PCImportError("Encrypted PC data needs its supplied launcher. Copy the complete PC installation contents, including Launch_OMORI.bat, into original; alternatively include its 32-character data key in omori-pc-key.txt.")
    if len(keys) != 1:
        raise PCImportError("Conflicting PC data keys were found in original; keep files from one installation.")
    return keys.pop()


class AES256CTR:
    """Small OpenSSL EVP binding; the imported game never executes on the host."""

    def __init__(self):
        names = [ctypes.util.find_library("crypto"), "libcrypto.so.3", "libcrypto.so.1.1",
                 "libcrypto.so", "libcrypto.dylib", "libcrypto-3.dll", "libcrypto-3-x64.dll",
                 str(Path(sys.base_prefix) / "DLLs" / "libcrypto-3.dll")]
        self.lib = None
        for name in names:
            if not name:
                continue
            try:
                lib = ctypes.CDLL(name)
                lib.EVP_CIPHER_CTX_new.restype = ctypes.c_void_p
                lib.EVP_CIPHER_CTX_free.argtypes = [ctypes.c_void_p]
                lib.EVP_aes_256_ctr.restype = ctypes.c_void_p
                lib.EVP_DecryptInit_ex.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                                  ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p]
                lib.EVP_DecryptInit_ex.restype = ctypes.c_int
                lib.EVP_DecryptUpdate.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                                 ctypes.POINTER(ctypes.c_int), ctypes.c_void_p,
                                                 ctypes.c_int]
                lib.EVP_DecryptUpdate.restype = ctypes.c_int
                lib.EVP_DecryptFinal_ex.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                                   ctypes.POINTER(ctypes.c_int)]
                lib.EVP_DecryptFinal_ex.restype = ctypes.c_int
                self.lib = lib
                break
            except (OSError, AttributeError):
                continue
        self.openssl = shutil.which("openssl") if self.lib is None else None
        if self.lib is None and not self.openssl:
            raise PCImportError("PC preparation needs the firmware OpenSSL library (libcrypto) or openssl command.")

    def decrypt(self, key, iv, data):
        if len(key) != 32 or len(iv) != 16:
            raise PCImportError("Invalid encrypted PC file header.")
        if self.lib is None:
            result = subprocess.run([self.openssl, "enc", "-d", "-aes-256-ctr", "-K", key.hex(),
                                     "-iv", iv.hex()], input=data, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, check=False)
            if result.returncode:
                raise PCImportError("OpenSSL could not decode a PC data file.")
            return result.stdout
        lib = self.lib
        ctx = lib.EVP_CIPHER_CTX_new()
        if not ctx:
            raise PCImportError("OpenSSL could not allocate the PC file decoder.")
        try:
            output = ctypes.create_string_buffer(len(data) + 32)
            length = ctypes.c_int()
            tail = ctypes.c_int()
            if (lib.EVP_DecryptInit_ex(ctx, lib.EVP_aes_256_ctr(), None, key, iv) != 1
                    or lib.EVP_DecryptUpdate(ctx, output, ctypes.byref(length), data, len(data)) != 1
                    or lib.EVP_DecryptFinal_ex(ctx, ctypes.byref(output, length.value), ctypes.byref(tail)) != 1):
                raise PCImportError("OpenSSL could not decode a PC data file.")
            return output.raw[:length.value + tail.value]
        finally:
            lib.EVP_CIPHER_CTX_free(ctx)


def _output_path(relative):
    parts = list(relative.parts)
    if parts[0].casefold() == "languages":
        parts[0] = "Languages"
    elif parts[0].casefold() in {"data", "img", "audio", "maps", "fonts", "js", "movies", "icon"}:
        parts[0] = parts[0].lower()
    mapped = Path(*parts)
    ext = relative.suffix.casefold()
    return mapped.with_suffix(AES_EXTENSIONS.get(ext, MV_EXTENSIONS.get(ext, mapped.suffix)))


def _write_mv(source, destination, key, extension):
    with source.open("rb") as src, destination.open("wb") as dst:
        if src.read(16) != RPGMV_HEADER:
            raise PCImportError("Invalid RPG Maker header: " + source.name)
        first = src.read(16)
        if len(first) != 16 or len(key) != 16:
            raise PCImportError("Truncated RPG Maker asset: " + source.name)
        first = bytes(value ^ key[i] for i, value in enumerate(first))
        png = first.startswith(b"\x89PNG\r\n\x1a\n")
        jpeg = first.startswith(b"\xff\xd8\xff")
        webp = first.startswith(b"RIFF") and first[8:12] == b"WEBP"
        if extension == ".rpgmvp" and not (png or jpeg or webp):
            raise PCImportError("PC image key does not match this installation: " + source.name)
        # Several shipped jukebox tracks contain MP3/WAV despite their
        # .rpgmvo names. The native streaming decoder sniffs contents.
        mp3 = first.startswith(b"ID3") or (first[0] == 0xff and first[1] & 0xe0 == 0xe0)
        wav = first.startswith(b"RIFF") and first[8:12] == b"WAVE"
        if extension == ".rpgmvo" and not (first.startswith(b"OggS") or mp3 or wav):
            raise PCImportError("PC audio key does not match this installation: " + source.name)
        dst.write(first)
        shutil.copyfileobj(src, dst, 1024 * 1024)


def _decode_aes(path, cipher, key):
    raw = path.read_bytes()
    if len(raw) < 16:
        raise PCImportError("Truncated encrypted PC file: " + path.name)
    result = cipher.decrypt(key, raw[:16], raw[16:])
    try:
        decoded = result.decode("utf-8-sig")
        if path.suffix.casefold() in (".kel", ".aubrey"):
            json.loads(decoded)
    except (UnicodeError, ValueError):
        raise PCImportError("PC data could not be decoded; its launcher key may belong to another version: " + path.name) from None
    return result


def prepare_pc(original_dir, extract_to, progress=None, cancelled=None):
    """Stage, verify, then publish canonical data; never erase supplied files.

    progress receives dictionaries compatible with extract_ui's worker state.
    Cancellation or validation failures leave the previous extraction intact.
    Existing extractions are preserved as named siblings on successful import.
    """
    info = detect_pc(original_dir)
    if not info:
        raise PCImportError("No PC game data found. Copy the PC installation contents (including www) into original.")
    root = Path(info["root"])
    target = Path(extract_to).expanduser().resolve()
    if target == root or root in target.parents or target in root.parents:
        raise PCImportError("The prepared destination must be separate from the supplied PC www tree.")
    paths = _files(root)
    fingerprint = _fingerprint(info, paths)
    encrypted = any(p.suffix.casefold() in AES_EXTENSIONS for p in paths)
    key = _read_key(info) if encrypted else None
    cipher = AES256CTR() if encrypted else None
    total_bytes = sum(p.stat().st_size for p in paths)
    state = {"files_total": len(paths), "files_done": 0, "bytes_total": total_bytes,
             "bytes_done": 0, "progress": 0.0, "status": "Preparing PC game data",
             "current_file": "", "success": False, "error": None}

    def report(**values):
        state.update(values)
        if progress:
            progress(dict(state))

    def check_cancel():
        if cancelled and cancelled():
            raise PCImportCancelled("PC preparation cancelled; original files were kept.")

    target.parent.mkdir(parents=True, exist_ok=True)
    stage = target.parent / ("." + target.name + ".pc-import-" + uuid.uuid4().hex)
    www = stage / "assets" / "www"
    backup = None
    published = False
    report()
    try:
        check_cancel()
        www.mkdir(parents=True)
        planned = []
        names = set()
        for path in paths:
            relative = _output_path(path.relative_to(root))
            name = relative.as_posix().casefold()
            if name in names:
                raise PCImportError("PC files would overwrite the same prepared path: " + relative.as_posix())
            names.add(name)
            planned.append((path, relative))
        system_path = _child(_child(root, "data"), "System.KEL")
        system_raw = (_decode_aes(system_path, cipher, key) if system_path.is_file()
                      else _child(_child(root, "data"), "System.json").read_bytes())
        try:
            system = json.loads(system_raw.decode("utf-8-sig"))
            image_key = bytes.fromhex(system.get("encryptionKey", ""))
        except (ValueError, UnicodeError):
            raise PCImportError("PC System data has an invalid asset key.") from None
        for path, relative in planned:
            check_cancel()
            destination = www / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            report(current_file=relative.as_posix())
            ext = path.suffix.casefold()
            if ext in AES_EXTENSIONS:
                destination.write_bytes(_decode_aes(path, cipher, key))
            elif ext in MV_EXTENSIONS:
                _write_mv(path, destination, image_key, ext)
            else:
                shutil.copyfile(path, destination)
            state["files_done"] += 1
            state["bytes_done"] += path.stat().st_size
            report(progress=state["bytes_done"] / max(1, total_bytes))
        if not _critical_tree(www):
            raise PCImportError("PC game data is incomplete (database, Atlas, images or Languages missing).")
        atlas = (www / "data" / "Atlas.yaml").read_text(encoding="utf-8-sig")
        if not re.search(r"(?m)^source\s*:", atlas):
            raise PCImportError("PC Atlas data could not be decoded.")
        check_cancel()
        if _fingerprint(info, _files(root)) != fingerprint:
            raise PCImportError("PC input changed during preparation; please launch again after copying finishes.")
        manifest = {"formatVersion": FORMAT_VERSION, "kind": "pc", "fingerprint": fingerprint,
                    "files": len(paths), "sourceBytes": total_bytes,
                    "preparedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}
        (stage / MARKER).write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
        report(status="Installing prepared PC data", current_file="")
        if target.exists():
            backup = target.parent / (target.name + ".previous-pc-" + time.strftime("%Y%m%d-%H%M%S")
                                      + "-" + uuid.uuid4().hex[:8])
            target.rename(backup)
        try:
            stage.rename(target)
            published = True
        except OSError:
            if backup is not None and not target.exists():
                backup.rename(target)
            raise
        report(success=True, progress=1.0, status="PC game data ready")
        return manifest
    except Exception as exc:
        report(error=str(exc), status="PC preparation stopped")
        raise
    finally:
        # Only this invocation's private staging directory can be removed.
        if not published and stage.is_dir() and stage.parent == target.parent and stage.name.startswith("." + target.name + ".pc-import-"):
            shutil.rmtree(stage)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--detect", action="store_true", help="Print detected PC input as JSON")
    parser.add_argument("--ready", action="store_true", help="Exit 0 when copied PC data is already prepared")
    parser.add_argument("original")
    parser.add_argument("extracted", nargs="?")
    args = parser.parse_args(argv)
    try:
        if args.detect:
            info = detect_pc(args.original)
            print(json.dumps(info))
            return 0 if info else 1
        if not args.extracted:
            parser.error("extracted destination is required")
        if args.ready:
            return 0 if is_prepared_pc(args.original, args.extracted) else 1
        manifest = prepare_pc(args.original, args.extracted)
        print(json.dumps(manifest))
        return 0
    except (PCImportError, OSError) as exc:
        print("OMORI PC preparation: " + str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
