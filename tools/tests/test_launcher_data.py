"""Execute the real Linux launcher with generated input and a stub runtime."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

PROJECT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('pc_fixtures', Path(__file__).with_name('test_prepare_pc.py'))
fixtures = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(fixtures)


@unittest.skipUnless(sys.platform.startswith('linux'), 'requires Linux shebang execution')
class LauncherDataTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='omori-launcher-data-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.port = self.root/'omori'
        self.original = self.port/'original'
        self.target = self.original/'extracted'
        self.bin = self.port/'bin'
        self.bin.mkdir(parents=True)
        self.original.mkdir()
        shutil.copyfile(PROJECT/'OMORI.sh', self.root/'OMORI.sh')
        (self.root/'OMORI.sh').chmod(0o755)
        for name in ('extract_ui.py','prepare_pc.py'):
            shutil.copyfile(PROJECT/'omori/bin'/name,self.bin/name)
        (self.bin/'vendor').symlink_to(PROJECT/'omori/bin/vendor',target_is_directory=True)
        (self.bin/'omori-native').write_text('#!/bin/bash\nprintf "RUNTIME_EXEC_REACHED\\n"\n',encoding='utf-8')
        (self.bin/'omori-native').chmod(0o755)
        self.wrapper = self.root/'wrapper'
        self.wrapper.write_text('#!/bin/bash\nexec "$@"\n',encoding='utf-8')
        self.wrapper.chmod(0o755)

    def pc_fixture(self):
        fixture = fixtures.PCImportTests()
        fixture.base = self.root
        fixture.original = self.original
        fixture.www = self.original/'www'
        fixture.target = self.target
        fixture.asset_key = bytes(range(16))
        fixture.key = b'0123456789abcdef0123456789abcdef'
        fixture.fixture(encrypted=True)
        fixture.write('package.json',b'{}')
        (fixture.www/'audio').mkdir(exist_ok=True)
        return fixture

    def launch(self, expected=0):
        result = subprocess.run([str(self.root/'OMORI.sh')], env={**os.environ,
            'ESUDO':str(self.wrapper),'OMORI_ALLOW_ANY_ARCH':'1'},capture_output=True,text=True,timeout=45)
        self.assertEqual(result.returncode,expected,result.stdout+result.stderr)
        return result

    def test_pc_replaces_old_android_only_after_success_then_skips(self):
        fixture = self.pc_fixture()
        self.target.mkdir()
        (self.target/'assets/www').mkdir(parents=True)
        (self.target/'assets/www/index.html').write_bytes(b'old Android index')
        (self.target/'old-android').write_bytes(b'preserved')
        result = self.launch()
        self.assertIn('RUNTIME_EXEC_REACHED',result.stdout)
        self.assertTrue((self.target/'assets/www/data/System.json').is_file())
        backups = list(self.original.glob('extracted.previous-pc-*'))
        self.assertEqual(len(backups),1)
        self.assertEqual((backups[0]/'old-android').read_bytes(),b'preserved')
        marker = self.target/fixtures.pc.MARKER
        before = marker.read_bytes()
        self.launch()
        self.assertEqual(marker.read_bytes(),before)
        self.assertIn('skipping extraction',(self.port/'logs/launcher.log').read_text())
        fixture.write('js/extra.js',b'// copied update\n')
        self.launch()
        self.assertNotEqual(marker.read_bytes(),before)
        self.assertTrue((self.target/'assets/www/js/extra.js').is_file())
        self.assertTrue((self.original/'Launch_OMORI.bat').is_file())

    def test_bad_pc_key_keeps_previous_data_and_does_not_start_runtime(self):
        self.pc_fixture()
        self.target.mkdir()
        (self.target/'keep').write_bytes(b'previous')
        (self.original/'Launch_OMORI.bat').write_bytes(b'OMORI.exe --'+b'f'*32)
        result = self.launch(expected=1)
        self.assertNotIn('RUNTIME_EXEC_REACHED',result.stdout)
        self.assertEqual((self.target/'keep').read_bytes(),b'previous')
        self.assertTrue((self.original/'www/data/System.KEL').is_file())

    def test_android_apk_and_second_launch_keep_existing_contract(self):
        apk = self.original/'OMORI.apk'
        with zipfile.ZipFile(apk,'w') as z:
            for name in ('js/','data/','img/','audio/','Languages/'):
                z.writestr('assets/www/'+name,b'')
            z.writestr('assets/www/index.html',b'<html></html>')
            z.writestr('assets/www/package.json',b'{}')
        self.assertIn('RUNTIME_EXEC_REACHED',self.launch().stdout)
        self.assertFalse(apk.exists())
        self.assertIn('RUNTIME_EXEC_REACHED',self.launch().stdout)


if __name__ == '__main__':
    unittest.main()
