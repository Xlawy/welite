"""Exercise release naming and the runtime-only archive boundary."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


class PackageReleaseTest(unittest.TestCase):
    def test_welite_archive_keeps_compatible_directory_and_licensed_font(self):
        with tempfile.TemporaryDirectory() as folder:
            repo = Path(folder)
            (repo / 'scripts').mkdir()
            shutil.copy(ROOT / 'scripts/package_release.sh', repo / 'scripts')
            for name in ('_meta.lua', 'main.lua', 'LICENSE', 'NOTICE', 'README.md'):
                shutil.copy(ROOT / name, repo / name)
            for name in ('fonts', 'icons', 'integrations', 'weread'):
                (repo / name).mkdir()
            shutil.copy(ROOT / 'fonts/NotoEmoji-Regular.ttf', repo / 'fonts')
            shutil.copy(ROOT / 'fonts/LICENSE', repo / 'fonts')
            (repo / 'private-cookie.txt').write_text('must not ship')
            subprocess.run(['bash', 'scripts/package_release.sh'], cwd=repo,
                           check=True, capture_output=True, text=True)
            archive = repo / 'dist/welite.koplugin-v1.0.0.zip'
            self.assertTrue(archive.is_file())
            with zipfile.ZipFile(archive) as packed:
                names = packed.namelist()
                self.assertTrue(all(name.startswith('welite.koplugin/') for name in names))
                for name in ('main.lua', '_meta.lua', 'LICENSE', 'NOTICE',
                             'fonts/NotoEmoji-Regular.ttf', 'fonts/LICENSE'):
                    self.assertIn('welite.koplugin/' + name, names)
                self.assertNotIn('welite.koplugin/private-cookie.txt', names)
                self.assertFalse(any('/scripts/' in name for name in names))
