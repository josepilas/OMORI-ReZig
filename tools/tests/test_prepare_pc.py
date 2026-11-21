"""PC import format and safe-publication regression tests (no game assets)."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


MODULE = Path(__file__).resolve().parents[2] / "omori" / "bin" / "prepare_pc.py"
SPEC = importlib.util.spec_from_file_location("prepare_pc", MODULE)
pc = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(pc)


class PCImportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.original = self.base / "original"
        self.www = self.original / "www"
        self.target = self.original / "extracted"
        self.asset_key = bytes(range(16))
        self.key = b"0123456789abcdef0123456789abcdef"

    def write(self, relative, data):
        path = self.www / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def fixture(self, encrypted=False):
        self.write("index.html", b"<html></html>")
        self.write("js/main.js", b"// test fixture only\n")
        self.write("img/system/Window.png", b"plain fixture")
        self.write("languages/en/test.yaml", b"message: test\n")
        self.write("data/System.json", json.dumps({"encryptionKey": self.asset_key.hex()}).encode())
        self.write("data/Actors.json", b"[null]")
        self.write("data/MapInfos.json", b"[null]")
        self.write("data/Atlas.yaml", b"source:\n  fixture: {}\n")
        if encrypted:
            cipher = pc.AES256CTR()
            self.original.joinpath("Launch_OMORI.bat").write_bytes(b"OMORI.exe --" + self.key + b"\r\n")
            for plain, ext in [("data/System.json", ".KEL"), ("data/Actors.json", ".KEL"),
                               ("data/MapInfos.json", ".KEL"), ("data/Atlas.yaml", ".PLUTO"),
                               ("languages/en/test.yaml", ".HERO"), ("js/main.js", ".OMORI")]:
                path = self.www / plain
                iv = bytes(range(16))
                path.with_suffix(ext).write_bytes(iv + cipher.decrypt(self.key, iv, path.read_bytes()))
                path.unlink()
            # RPG Maker only XORs the first 16 bytes after its wrapper.
            for name, signature in [("img/fixture.rpgmvp", b"\x89PNG\r\n\x1a\n"),
                                    ("audio/bgm/fixture.rpgmvo", b"OggS")]:
                payload = signature + b"x" * 48
                wrapped = bytes(b ^ self.asset_key[i] for i, b in enumerate(payload[:16]))
                self.write(name, pc.RPGMV_HEADER + wrapped + payload[16:])
        return self.original

    def test_aes_256_ctr_nist_sp800_38a(self):
        # NIST SP 800-38A F.5.5: independent known-answer vector.
        key = bytes.fromhex("603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")
        iv = bytes.fromhex("f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        ciphertext = bytes.fromhex("601ec313775789a5b7a7f504bbf3d228f443e3ca4d62b59aca84e990cacaf5c5")
        plaintext = bytes.fromhex("6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")
        self.assertEqual(pc.AES256CTR().decrypt(key, iv, ciphertext), plaintext)

    def test_detect_direct_www_and_nested_copy(self):
        self.fixture()
        self.assertEqual(Path(pc.detect_pc(self.www)["root"]), self.www)
        self.assertEqual(Path(pc.detect_pc(self.original)["root"]), self.www)
        nested = self.base / "copy" / "OMORI"
        nested.parent.mkdir()
        self.original.rename(nested)
        self.assertEqual(Path(pc.detect_pc(nested.parent)["root"]), nested / "www")

    def test_does_not_detect_an_old_extraction_as_source(self):
        self.fixture()
        destination = self.base / "only-prepared" / "extracted" / "assets" / "www"
        destination.parent.mkdir(parents=True)
        self.www.rename(destination)
        self.assertIsNone(pc.detect_pc(self.base / "only-prepared"))

    def test_plain_import_normalizes_languages_preserves_saves(self):
        self.fixture()
        self.write("save/file1.rpgsave", b"private save")
        self.write("data/file2.rpgsave", b"private save")
        self.target.mkdir()
        (self.target / "existing-save").write_bytes(b"keep me")
        states = []
        manifest = pc.prepare_pc(self.original, self.target, progress=states.append)
        output = self.target / "assets" / "www"
        self.assertEqual(manifest["kind"], "pc")
        self.assertTrue((output / "Languages/en/test.yaml").is_file())
        self.assertFalse((output / "save").exists())
        self.assertFalse((output / "data/file2.rpgsave").exists())
        self.assertTrue((self.www / "save/file1.rpgsave").is_file())
        backups = list(self.target.parent.glob("extracted.previous-pc-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "existing-save").read_bytes(), b"keep me")
        self.assertTrue(states[-1]["success"])
        self.assertEqual(states[-1]["progress"], 1.0)
        self.assertTrue(pc.is_prepared_pc(self.original, self.target))
        self.write("js/new.js", b"// new content")
        self.assertFalse(pc.is_prepared_pc(self.original, self.target))

    def test_encrypted_import_decodes_database_images_audio_and_plugins(self):
        self.fixture(encrypted=True)
        before = {p.relative_to(self.www): p.read_bytes() for p in self.www.rglob("*") if p.is_file()}
        pc.prepare_pc(self.original, self.target)
        output = self.target / "assets/www"
        self.assertEqual((output / "data/Actors.json").read_bytes(), b"[null]")
        self.assertEqual((output / "js/main.js").read_bytes(), b"// test fixture only\n")
        self.assertEqual((output / "Languages/en/test.yaml").read_bytes(), b"message: test\n")
        self.assertEqual((output / "img/fixture.png").read_bytes(), b"\x89PNG\r\n\x1a\n" + b"x" * 48)
        self.assertEqual((output / "audio/bgm/fixture.ogg").read_bytes(), b"OggS" + b"x" * 48)
        self.assertNotIn(self.key.decode(), (self.target / pc.MARKER).read_text())
        self.assertEqual(before, {p.relative_to(self.www): p.read_bytes() for p in self.www.rglob("*") if p.is_file()})

    def test_wrapped_audio_accepts_real_pc_mp3_and_wav_payloads(self):
        self.fixture(encrypted=True)
        payloads = {"mp3": b"\xff\xfb\x90\x44" + b"x" * 32,
                    "wav": b"RIFF\x28\x00\x00\x00WAVEfmt " + b"x" * 32}
        for name, payload in payloads.items():
            wrapped = bytes(b ^ self.asset_key[i] for i, b in enumerate(payload[:16]))
            self.write("audio/bgm/" + name + ".rpgmvo", pc.RPGMV_HEADER + wrapped + payload[16:])
        pc.prepare_pc(self.original, self.target)
        for name, payload in payloads.items():
            self.assertEqual((self.target / "assets/www/audio/bgm" / (name + ".ogg")).read_bytes(), payload)

    def test_invalid_wrapped_image_does_not_publish(self):
        self.fixture(encrypted=True)
        self.write("img/fixture.rpgmvp", pc.RPGMV_HEADER + b"not an image at all" * 2)
        with self.assertRaisesRegex(pc.PCImportError, "image key"):
            pc.prepare_pc(self.original, self.target)
        self.assertFalse(self.target.exists())

    def test_wrapped_images_accept_jpeg_and_webp_contents(self):
        self.fixture(encrypted=True)
        samples = (b"\xff\xd8\xff\xe1" + b"x" * 32, b"RIFF\x20\x00\x00\x00WEBPVP8L" + b"x" * 32)
        for i, payload in enumerate(samples):
            wrapped = bytes(b ^ self.asset_key[j] for j, b in enumerate(payload[:16]))
            self.write(f"img/photo{i}.rpgmvp", pc.RPGMV_HEADER + wrapped + payload[16:])
        pc.prepare_pc(self.original, self.target)
        for i, payload in enumerate(samples):
            self.assertEqual((self.target / f"assets/www/img/photo{i}.png").read_bytes(), payload)

    def test_wrong_key_keeps_previous_extraction_and_input(self):
        self.fixture(encrypted=True)
        (self.original / "Launch_OMORI.bat").write_bytes(b"OMORI.exe --" + b"f" * 32)
        self.target.mkdir()
        (self.target / "existing").write_bytes(b"old data")
        with self.assertRaisesRegex(pc.PCImportError, "could not be decoded"):
            pc.prepare_pc(self.original, self.target)
        self.assertEqual((self.target / "existing").read_bytes(), b"old data")
        self.assertTrue((self.www / "data/System.KEL").is_file())
        self.assertEqual(list(self.original.glob(".extracted.pc-import-*")), [])

    def test_cancellation_keeps_previous_extraction(self):
        self.fixture()
        self.target.mkdir()
        (self.target / "existing").write_bytes(b"old data")
        with self.assertRaises(pc.PCImportCancelled):
            pc.prepare_pc(self.original, self.target, cancelled=lambda: True)
        self.assertEqual((self.target / "existing").read_bytes(), b"old data")
        self.assertEqual(list(self.original.glob(".extracted.pc-import-*")), [])

    def test_transformed_name_collision_is_rejected(self):
        self.fixture(encrypted=True)
        self.write("data/Actors.json", b"[null]")
        with self.assertRaisesRegex(pc.PCImportError, "same prepared path"):
            pc.prepare_pc(self.original, self.target)
        self.assertFalse(self.target.exists())

    def test_destination_cannot_overwrite_supplied_tree(self):
        self.fixture()
        for destination in (self.www, self.www / "prepared", self.original):
            with self.assertRaisesRegex(pc.PCImportError, "separate"):
                pc.prepare_pc(self.original, destination)
        self.assertTrue((self.www / "data/System.json").is_file())

    def test_missing_key_reports_actionable_error(self):
        self.fixture(encrypted=True)
        (self.original / "Launch_OMORI.bat").unlink()
        with self.assertRaisesRegex(pc.PCImportError, "complete PC installation"):
            pc.prepare_pc(self.original, self.target)

    def test_plain_www_copy_accepts_explicit_key_file(self):
        self.fixture(encrypted=True)
        (self.original / "Launch_OMORI.bat").unlink()
        (self.www / pc.KEY_FILE).write_bytes(self.key + b"\n")
        output = self.base / "prepared"
        pc.prepare_pc(self.www, output)
        self.assertFalse((output / "assets/www" / pc.KEY_FILE).exists())


if __name__ == "__main__":
    unittest.main()
