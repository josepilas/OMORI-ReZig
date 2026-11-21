from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

import check_release as preflight


LAUNCHER = b"#!/bin/bash\nset -eu\nprintf 'fixture only\\n'\n"


class ReleasePreflightTests(unittest.TestCase):
    def make_project(self, root):
        project = Path(root) / "project"
        (project / "omori/bin").mkdir(parents=True)
        (project / "OMORI.sh").write_bytes(LAUNCHER)
        elf = bytearray(64)
        elf[:6] = b"\x7fELF\x02\x01"
        struct.pack_into("<H", elf, 18, 183)
        (project / "omori/bin/omori-native").write_bytes(elf)
        return project

    def make_archive(self, project, archive, *, execute=True, stale_launcher=False):
        with zipfile.ZipFile(archive, "w") as zipped:
            for name in ("OMORI.sh", "omori/bin/omori-native"):
                info = zipfile.ZipInfo(name)
                info.create_system = 3
                info.external_attr = (stat.S_IFREG | (0o755 if execute else 0o644)) << 16
                data = (project / name).read_bytes()
                if stale_launcher and name == "OMORI.sh": data += b"# stale\n"
                zipped.writestr(info, data)

    def test_v37_crlf_regression_rejected_before_execution(self):
        with self.assertRaisesRegex(preflight.PreflightError, "CR/CRLF"):
            preflight.check_shell_bytes(LAUNCHER.replace(b"\n", b"\r\n"), "v37")

    def test_bom_and_missing_shebang_rejected(self):
        for data in (b"\xef\xbb\xbf" + LAUNCHER, b"echo no shebang\n"):
            with self.assertRaises(preflight.PreflightError):
                preflight.check_shell_bytes(data, "bad")

    def test_utf8_porter_credit_allowed(self):
        preflight.check_shell_bytes(LAUNCHER + "# José Pilas\n".encode(), "unicode")

    def test_valid_archive_and_execute_modes_pass(self):
        with tempfile.TemporaryDirectory() as temporary:
            project = self.make_project(temporary)
            archive = Path(temporary) / "install.zip"
            self.make_archive(project, archive)
            result = preflight.check_release(project, archive, static_only=True)
            self.assertEqual(result["archive_bytes_and_unix_execute_modes"], "passed")
            self.assertEqual(result["linux_bash_syntax_and_direct_exec"], "not_run")

    def test_zip_without_executable_mode_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            project = self.make_project(temporary)
            archive = Path(temporary) / "install.zip"
            self.make_archive(project, archive, execute=False)
            with self.assertRaisesRegex(preflight.PreflightError, "executable Unix"):
                preflight.check_release(project, archive, static_only=True)

    def test_stale_packaged_launcher_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            project = self.make_project(temporary)
            archive = Path(temporary) / "install.zip"
            self.make_archive(project, archive, stale_launcher=True)
            with self.assertRaisesRegex(preflight.PreflightError, "stale/different"):
                preflight.check_release(project, archive, static_only=True)

    def test_wrong_architecture_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            project = self.make_project(temporary)
            executable = project / "omori/bin/omori-native"
            data = bytearray(executable.read_bytes())
            struct.pack_into("<H", data, 18, 62)
            executable.write_bytes(data)
            with self.assertRaisesRegex(preflight.PreflightError, "AArch64"):
                preflight.check_release(project, static_only=True)

    @unittest.skipUnless(sys.platform.startswith("linux"), "requires Linux/WSL direct exec")
    def test_linux_real_shebang_exec_and_bad_shell_syntax(self):
        preflight.check_linux_execution(LAUNCHER)
        with self.assertRaisesRegex(preflight.PreflightError, "bash -n"):
            preflight.check_linux_execution(b"#!/bin/bash\nif then\n")

    @unittest.skipUnless(sys.platform.startswith("linux"), "requires Linux/WSL direct exec")
    def test_linux_kernel_rejects_the_v37_crlf_interpreter_path(self):
        with tempfile.TemporaryDirectory() as temporary:
            script = Path(temporary) / "CRLF.sh"
            script.write_bytes(b"#!/bin/bash\r\nprintf 'SHOULD_NOT_EXECUTE\\n'\n")
            script.chmod(0o755)
            self.assertTrue(script.is_file())
            with self.assertRaises(FileNotFoundError):
                subprocess.run([str(script)], capture_output=True, check=True)


if __name__ == "__main__":
    unittest.main()
