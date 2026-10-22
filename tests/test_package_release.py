"""Exercise release naming and the runtime-only archive boundary."""
from pathlib import Path
import re
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
            for name in ('fonts', 'icons', 'welite'):
                (repo / name).mkdir()
            shutil.copy(ROOT / 'fonts/NotoEmoji-Regular.ttf', repo / 'fonts')
            shutil.copy(ROOT / 'fonts/LICENSE', repo / 'fonts')
            shutil.copy(ROOT / 'welite/identity.lua', repo / 'welite')
            (repo / 'private-cookie.txt').write_text('must not ship')
            subprocess.run(['bash', 'scripts/package_release.sh'], cwd=repo,
                           check=True, capture_output=True, text=True)
            version = re.search(r'^\s*version\s*=\s*"(\d+\.\d+\.\d+)"',
                                (repo / 'welite/identity.lua').read_text(), re.MULTILINE)
            self.assertIsNotNone(version, 'plugin metadata must declare its release version')
            archive = repo / f'dist/welite.koplugin-v{version.group(1)}.zip'
            self.assertTrue(archive.is_file())
            with zipfile.ZipFile(archive) as packed:
                names = packed.namelist()
                self.assertTrue(all(name.startswith('welite.koplugin/') for name in names))
                for name in ('main.lua', '_meta.lua', 'LICENSE', 'NOTICE',
                             'fonts/NotoEmoji-Regular.ttf', 'fonts/LICENSE'):
                    self.assertIn('welite.koplugin/' + name, names)
                self.assertNotIn('welite.koplugin/private-cookie.txt', names)
                self.assertFalse(any('/scripts/' in name for name in names))
                meta = packed.read('welite.koplugin/_meta.lua').decode()
                identity = packed.read('welite.koplugin/welite/identity.lua').decode()
                self.assertIn(f'version = "{version.group(1)}"', meta)
                self.assertIn(f'version = "{version.group(1)}"', identity)
                self.assertNotIn('require("welite.identity")', meta)
                self.assertFalse(any(name.startswith(('welite.koplugin/weread/',
                                                     'welite.koplugin/integrations/')) for name in names))

    def test_release_notes_select_welite_version_and_retain_upstream_history(self):
        result = subprocess.run(['bash', str(ROOT / 'scripts/extract_release_notes.sh'), '1.0.1'],
                                check=True, capture_output=True, text=True)
        self.assertIn('WeLite', result.stdout)
        self.assertIn('welite/cache', result.stdout)
        self.assertIn('262144', result.stdout)
        self.assertTrue((ROOT / 'docs/upstream-changelog.md').is_file())
        self.assertEqual((ROOT / 'CHANGELOG.md').read_text().count('## [1.0.1]'), 1)
