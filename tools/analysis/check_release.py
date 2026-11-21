#!/usr/bin/env python3
"""Check the bytes Linux will execute, including the install ZIP's Unix modes.

Run under Linux/WSL for the complete preflight. --static-only is an explicit
Windows fallback; it cannot establish Linux execution or shell syntax.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import zipfile


class PreflightError(ValueError):
    pass


def check_shell_bytes(data: bytes, label: str) -> None:
    if data.startswith(b"\xef\xbb\xbf"):
        raise PreflightError(f"{label}: UTF-8 BOM precedes the Linux shebang")
    if b"\r" in data:
        raise PreflightError(f"{label}: CR/CRLF bytes are not valid release shell line endings")
    if not data.startswith(b"#!/bin/bash\n"):
        raise PreflightError(f"{label}: expected exact LF-terminated #!/bin/bash shebang")
    try:
        data.decode("utf-8")
    except UnicodeDecodeError as error:
        raise PreflightError(f"{label}: shell text is not UTF-8") from error


def check_arm64_elf(data: bytes, label: str) -> None:
    if len(data) < 64 or data[:6] != b"\x7fELF\x02\x01":
        raise PreflightError(f"{label}: expected ELF64 little-endian executable")
    if struct.unpack_from("<H", data, 18)[0] != 183:
        raise PreflightError(f"{label}: executable is not AArch64")


def check_linux_execution(data: bytes) -> None:
    if not sys.platform.startswith("linux"):
        raise PreflightError("Linux checks require Linux/WSL; use --static-only only for static checks")
    bash = shutil.which("bash")
    if not bash:
        raise PreflightError("bash is required for the Linux syntax check")
    with tempfile.TemporaryDirectory(prefix="omori-release-preflight-") as temporary:
        root = Path(temporary)
        launcher = root / "OMORI.sh"
        launcher.write_bytes(data)
        result = subprocess.run([bash, "-n", str(launcher)], capture_output=True, text=True)
        if result.returncode:
            raise PreflightError(f"launcher bash -n failed: {result.stderr.strip()}")
        # Exercise kernel shebang lookup, without executing the real launcher
        # or touching its port/log/save paths. 'bash file' would miss this bug.
        stub = root / "shebang-exec.sh"
        stub.write_bytes(data.split(b"\n", 1)[0] + b"\nprintf 'OMORI_SHEBANG_EXEC_OK\\n'\n")
        stub.chmod(0o755)
        try:
            result = subprocess.run([str(stub)], capture_output=True, text=True)
        except OSError as error:
            raise PreflightError(f"Linux direct-exec shebang failed: {error}") from error
        if result.returncode or result.stdout != "OMORI_SHEBANG_EXEC_OK\n":
            raise PreflightError("Linux direct-exec shebang did not reach the script body")


def check_zip(archive: Path, launcher: bytes, executable: bytes) -> int:
    with zipfile.ZipFile(archive) as zipped:
        damaged = zipped.testzip()
        if damaged:
            raise PreflightError(f"ZIP failed CRC check: {damaged}")
        for name, expected in (("OMORI.sh", launcher), ("omori/bin/omori-native", executable)):
            try:
                item = zipped.getinfo(name)
            except KeyError as error:
                raise PreflightError(f"ZIP missing required member: {name}") from error
            if name.endswith(".sh"):
                check_shell_bytes(zipped.read(item), f"ZIP:{name}")
            if zipped.read(item) != expected:
                raise PreflightError(f"ZIP contains stale/different bytes: {name}")
            mode = item.external_attr >> 16
            if item.create_system != 3 or not stat.S_ISREG(mode) or not mode & stat.S_IXUSR:
                raise PreflightError(f"ZIP lacks executable Unix file mode: {name}")
        shell_count = 0
        for item in zipped.infolist():
            if not item.is_dir() and item.filename.endswith(".sh"):
                check_shell_bytes(zipped.read(item), f"ZIP:{item.filename}")
                shell_count += 1
        return shell_count


def check_release(project: Path, archive: Path | None = None, *, static_only: bool = False) -> dict:
    launcher_path = project / "OMORI.sh"
    executable_path = project / "omori/bin/omori-native"
    launcher = launcher_path.read_bytes()
    executable = executable_path.read_bytes()
    check_shell_bytes(launcher, str(launcher_path))
    check_arm64_elf(executable, str(executable_path))
    if not static_only:
        check_linux_execution(launcher)
    shell_count = check_zip(archive, launcher, executable) if archive else 0
    return {
        "launcher_utf8_lf_shebang": "passed",
        "arm64_elf_header": "passed",
        "linux_bash_syntax_and_direct_exec": "not_run" if static_only else "passed",
        "archive_bytes_and_unix_execute_modes": "passed" if archive else "not_run",
        "archive_shell_files_checked": shell_count,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--project", type=Path, required=True)
    parser.add_argument("--archive", type=Path)
    parser.add_argument("--static-only", action="store_true")
    args = parser.parse_args()
    try:
        result = check_release(args.project, args.archive, static_only=args.static_only)
    except (PreflightError, OSError, zipfile.BadZipFile) as error:
        print(f"RELEASE PREFLIGHT FAILED: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
