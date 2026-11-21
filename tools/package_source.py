#!/usr/bin/env python3
"""Build the OMORI ReZig source ZIP from this checkout."""

import argparse
import os
from pathlib import Path
import stat
import tempfile
import zipfile


PROJECT = Path(__file__).resolve().parents[1]
ARCHIVE_ROOT = "OMORI-ReZig"
REQUIRED = (
    ".gitattributes",
    ".gitignore",
    "LICENSE",
    "README.MD",
    "R36S.MD",
    "FOR_DEVS.MD",
    "OMORI.sh",
    "port.json",
    "gameinfo.xml",
    "docs/ARCHITECTURE.md",
    "docs/BUILDING.md",
    "docs/COMPATIBILITY.md",
    "docs/CONTRIBUTING.md",
    "docs/README.md",
    "docs/PORTING.md",
    "docs/THIRD_PARTY.md",
    "docs/VERIFICATION.md",
    "omori/README.md",
    "omori/THIRD_PARTY.md",
    "omori/bin/extract_ui.py",
    "omori/bin/prepare_pc.py",
    "omori/licenses/MPL-2.0.txt",
    "runtime/README.md",
    "runtime/build.zig",
    "runtime/build.zig.zon",
    "runtime/src/main.zig",
    "runtime/src/tests.zig",
    "runtime/src/audio/test-tone.txt",
    "runtime/src/audio/test-tone.mp3",
    "runtime/src/audio/test-tone.ogg",
    "runtime/src/audio/test-tone.wav",
    "tools/analysis/make_synth_tree.sh",
    "tools/package_source.py",
)
SOURCE_PATTERNS = (
    "docs/BEHAVIORAL_SPEC.md",
    "docs/LOGGING.md",
    "docs/REFERENCE-COMPARISON.md",
    "docs/VALIDATION-v3[6-9].md",
    "docs/VALIDATION-v4[0-9].md",
    "omori/VALIDATION-v*.md",
    "omori/licenses/*.txt",
    "omori/gptokeyb/*.gptk",
    "omori/bin/vendor/sdl2/*.py",
    "runtime/*.zig",
    "runtime/src/**/*.zig",
    "runtime/src/**/*.c",
    "runtime/src/**/*.h",
    "runtime/src/**/*-source.json",
    "runtime/scripts/*.sh",
    "tools/analysis/*.py",
    "tools/tests/*.py",
)
EMPTY_FOLDERS = ("omori/original", "omori/saves", "omori/logs")


def source_files(project: Path) -> list[Path]:
    """Select source and license files without traversing saved game data."""
    files = {project / name for name in REQUIRED}
    for pattern in SOURCE_PATTERNS:
        files.update(path for path in project.glob(pattern) if path.is_file())

    for path in files:
        if path.is_symlink() or path.resolve() != path:
            raise ValueError(f"Source archive does not accept linked files: {path}")
        if not path.is_file():
            raise FileNotFoundError(path)
    return sorted(files, key=lambda path: path.relative_to(project).as_posix())


def write_entry(archive: zipfile.ZipFile, name: str, data: bytes) -> None:
    info = zipfile.ZipInfo(f"{ARCHIVE_ROOT}/{name}")
    info.create_system = 3
    mode = 0o755 if name.endswith(".sh") else 0o644
    info.external_attr = (stat.S_IFREG | mode) << 16
    archive.writestr(info, data, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)


def package(destination: Path, project: Path = PROJECT) -> int:
    project = project.resolve()
    destination = destination.resolve()
    files = source_files(project)
    if destination in files or destination.suffix.lower() != ".zip":
        raise ValueError("Destination must be a ZIP archive separate from the source files")
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as temp:
        temporary_path = Path(temp.name)
    try:
        with zipfile.ZipFile(temporary_path, "w") as archive:
            for path in files:
                write_entry(archive, path.relative_to(project).as_posix(), path.read_bytes())
            for folder in EMPTY_FOLDERS:
                write_entry(archive, f"{folder}/.gitkeep", b"")
        with zipfile.ZipFile(temporary_path) as archive:
            if bad_file := archive.testzip():
                raise ValueError(f"Could not verify archived file: {bad_file}")
        os.replace(temporary_path, destination)
    finally:
        temporary_path.unlink(missing_ok=True)
    return len(files) + len(EMPTY_FOLDERS)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path, help="path of the source ZIP")
    args = parser.parse_args()
    count = package(args.destination)
    print(f"Archived {count} source files to {args.destination.resolve()}")


if __name__ == "__main__":
    main()
