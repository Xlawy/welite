import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import subprocess
import zipfile

spec=importlib.util.spec_from_file_location('runner',Path(__file__).resolve().parents[1]/'scripts/test_welite.py')
runner=importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

class MappingTests(unittest.TestCase):
    def test_repository_mapping(self):
        self.assertIn('weread/ui/welite/home.lua',runner.check()['modules'])

    def test_missing_mapping_and_test_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'tests').mkdir(); (root/'weread/ui/welite').mkdir(parents=True)
            (root/'weread/ui/welite/test.lua').write_text('return {}')
            manifest=root/'tests/module-map.json'
            manifest.write_text(json.dumps({'modules':{}}))
            with self.assertRaisesRegex(ValueError,'Unmapped'): runner.check(root)
            manifest.write_text(json.dumps({'modules':{'weread/ui/welite/test.lua':['absent.lua']}}))
            with self.assertRaisesRegex(ValueError,'Missing test'): runner.check(root)

class PackageTests(unittest.TestCase):
    def test_release_contains_only_runtime_material(self):
        with tempfile.TemporaryDirectory() as directory:
            archive=Path(directory)/'release.zip'
            subprocess.run(['bash','scripts/package_release.sh',str(archive)],cwd=runner.ROOT,
                           check=True,stdout=subprocess.DEVNULL)
            with zipfile.ZipFile(archive) as package:
                names=package.namelist()
                self.assertIn('weread.koplugin/weread/ui/welite/home.lua',names)
                self.assertIn('weread.koplugin/LICENSE',names)
                self.assertIn('weread.koplugin/NOTICE',names)
                for name in names:
                    self.assertTrue(name.startswith('weread.koplugin/'))
                    self.assertFalse(any(part in {'tests','spec','scripts','.dev','.git','cache','settings'} for part in name.split('/')))
                    self.assertFalse(name.endswith(('.cookies','.log','.py','.pyc')))

if __name__=='__main__': unittest.main()
