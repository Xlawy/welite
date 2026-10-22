import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import subprocess
import zipfile
import sys
import shutil
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))

spec=importlib.util.spec_from_file_location('runner',Path(__file__).resolve().parents[1]/'scripts/test_welite.py')
runner=importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)

class MappingTests(unittest.TestCase):
    def test_repository_mapping(self):
        self.assertIn('welite/ui/welite/home.lua',runner.check()['modules'])

    def test_missing_mapping_and_test_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            (root/'tests').mkdir(); (root/'welite/ui/welite').mkdir(parents=True)
            (root/'welite/ui/welite/test.lua').write_text('return {}')
            manifest=root/'tests/module-map.json'
            manifest.write_text(json.dumps({'modules':{}}))
            with self.assertRaisesRegex(ValueError,'Unmapped'): runner.check(root)
            manifest.write_text(json.dumps({'modules':{'welite/ui/welite/test.lua':['absent.lua']}}))
            with self.assertRaisesRegex(ValueError,'Missing test'): runner.check(root)

    def test_library_and_integration_modules_cannot_escape_mapping(self):
        for name in ('welite/lib/new.lua','welite/integrations/new.lua','main.lua'):
            with self.subTest(module=name), tempfile.TemporaryDirectory() as directory:
                root=Path(directory);(root/'tests').mkdir()
                module=root/name;module.parent.mkdir(parents=True,exist_ok=True);module.write_text('return {}')
                (root/'tests/module-map.json').write_text(json.dumps({'modules':{}}))
                with self.assertRaisesRegex(ValueError,'Unmapped'): runner.check(root)

    def test_namespace_guard_rejects_old_imports_and_directories(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory);(root/'scripts').mkdir();(root/'welite/lib').mkdir(parents=True)
            shutil.copy(runner.ROOT/'scripts/check_lua_namespace.sh',root/'scripts')
            (root/'_meta.lua').write_text('return {}');(root/'main.lua').write_text('require("welite.lib.client")')
            command=['bash','scripts/check_lua_namespace.sh']
            self.assertEqual(0,subprocess.run(command,cwd=root,capture_output=True).returncode)
            for source in ('require("weread.lib.client")','require("integrations.init")',
                           'package.loaded["weread.lib.client"] = {}'):
                (root/'main.lua').write_text(source)
                self.assertNotEqual(0,subprocess.run(command,cwd=root,capture_output=True).returncode)
            (root/'main.lua').write_text('return {}');(root/'weread').mkdir()
            self.assertNotEqual(0,subprocess.run(command,cwd=root,capture_output=True).returncode)

    def test_fixture_is_real_pinned_upstream_without_local_settings(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture=runner.upstream_fixture(runner.ROOT,directory)
            self.assertIn('version = "1.6.0"',(fixture/'_meta.lua').read_text())
            self.assertIn('finlater/weread.koplugin',(fixture/'weread/lib/updater.lua').read_text())
            self.assertFalse((fixture/'settings').exists())
            self.assertFalse((fixture/'welite').exists())
        with tempfile.TemporaryDirectory() as directory:
            fixture=runner.upstream_fixture(runner.ROOT,directory,runner.PREVIOUS_REF)
            self.assertIn('version = "1.0.4"',(fixture/'_meta.lua').read_text())
            self.assertIn('Xlawy/welite',(fixture/'weread/lib/updater.lua').read_text())

class PackageTests(unittest.TestCase):
    def test_release_contains_only_runtime_material(self):
        with tempfile.TemporaryDirectory() as directory:
            archive=Path(directory)/'release.zip'
            subprocess.run(['bash','scripts/package_release.sh',str(archive)],cwd=runner.ROOT,
                           check=True,stdout=subprocess.DEVNULL)
            with zipfile.ZipFile(archive) as package:
                names=package.namelist()
                self.assertIn('welite.koplugin/welite/ui/welite/home.lua',names)
                self.assertIn('welite.koplugin/LICENSE',names)
                self.assertIn('welite.koplugin/NOTICE',names)
                for name in names:
                    self.assertTrue(name.startswith('welite.koplugin/'))
                    self.assertFalse(any(part in {'tests','spec','scripts','.dev','.git','cache','settings'} for part in name.split('/')))
                    self.assertFalse(name.endswith(('.cookies','.log','.py','.pyc')))

if __name__=='__main__': unittest.main()
