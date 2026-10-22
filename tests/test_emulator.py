import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
import emulator


class EmulatorTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name) / 'fork'
        self.root.mkdir()
        self.source = Path(self.temp.name) / 'old-runtime'
        for name in emulator.REQUIRED:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('fixture')
        self.environment = {'PATH': '/usr/bin:/bin'}

    def test_import_materializes_links_and_excludes_old_data(self):
        external = Path(self.temp.name) / 'external'
        external.write_text('runtime asset')
        (self.source / 'asset').symlink_to(external)
        for name in ['cache/secret', 'settings/credentials', 'plugins/welite.koplugin/main.lua',
                     'plugins/weread.koplugin/main.lua', 'spec/front/unit/welite_old_spec.lua']:
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text('old data')
        (self.source / 'spec/front/unit/welite_missing_spec.lua').symlink_to('/missing-fixture')
        runtime = emulator.migrate(self.source, self.root)
        external.unlink()
        self.assertEqual((runtime / 'asset').read_text(), 'runtime asset')
        self.assertFalse((runtime / 'asset').is_symlink())
        for name in ['cache', 'settings', 'plugins/welite.koplugin', 'plugins/weread.koplugin',
                     'spec/front/unit/welite_old_spec.lua', 'spec/front/unit/welite_missing_spec.lua']:
            self.assertFalse((runtime / name).exists())
        self.assertTrue((self.source / 'cache/secret').exists())
        with self.assertRaisesRegex(ValueError, 'overwrite'):
            emulator.migrate(self.source, self.root)

    def test_runtime_selection_and_invalid_override(self):
        with self.assertRaisesRegex(ValueError, 'make migrate-emulator'):
            emulator.find_runtime(self.root, {})
        runtime = emulator.migrate(self.source, self.root)
        self.assertEqual(emulator.find_runtime(self.root, {}), runtime)
        self.assertEqual(emulator.find_runtime(self.root, {'KOREADER_RUNTIME': str(self.source)}), self.source)
        with self.assertRaises(ValueError):
            emulator.find_runtime(self.root, {'KOREADER_RUNTIME': '/missing-runtime'})

    def test_launch_passes_geometry_profile_and_live_plugin_then_cleans_link(self):
        script = self.source / 'koreader.sh'
        script.write_text('#!/usr/bin/env python3\nimport os,json,pathlib,sys\n'
                          'p=pathlib.Path("plugins/welite.koplugin")\n'
                          'assert p.is_symlink()\n'
                          'pathlib.Path(os.environ["KO_HOME"], "probe.json").write_text(json.dumps({'
                          '"plugin":str(p.resolve()), "width":os.environ["EMULATE_READER_W"],'
                          '"height":os.environ["EMULATE_READER_H"],"dpi":os.environ["EMULATE_READER_DPI"],'
                          '"language":os.environ["LANGUAGE"],"args":sys.argv[1:]}))\n')
        script.chmod(0o755)
        runtime = emulator.migrate(self.source, self.root)
        emulator.launch(self.root, 1072, 1448, 300, self.environment)
        probe = json.loads((self.root / '.dev/profile/probe.json').read_text())
        self.assertEqual(probe, {'plugin': str(self.root), 'width': '1072', 'height': '1448',
                                 'dpi': '300', 'language': 'zh_CN', 'args': ['-d']})
        emulator.launch(self.root, environ=dict(self.environment, LANGUAGE='en_US'))
        self.assertEqual(json.loads((self.root / '.dev/profile/probe.json').read_text())['language'], 'en_US')
        plugin = runtime / 'plugins/welite.koplugin'
        self.assertFalse(plugin.is_symlink())
        (runtime / 'koreader.sh').write_text('#!/bin/sh\nexit 7\n')
        with self.assertRaises(subprocess.CalledProcessError):
            emulator.launch(self.root, environ=self.environment)
        self.assertFalse(plugin.is_symlink())
        plugin.mkdir()
        with self.assertRaisesRegex(ValueError, 'already exists'):
            emulator.launch(self.root, environ=self.environment)
        self.assertTrue(plugin.is_dir())
        with self.assertRaisesRegex(ValueError, 'positive'):
            emulator.launch(self.root, width=0, environ=self.environment)

    def test_failed_copy_does_not_leave_partial_runtime(self):
        (self.source / 'broken-asset').symlink_to('/missing-asset')
        with self.assertRaises(OSError):
            emulator.migrate(self.source, self.root)
        self.assertFalse((self.root / '.dev/emulator').exists())
        self.assertEqual(list((self.root / '.dev').iterdir()), [])


if __name__ == '__main__':
    unittest.main()
