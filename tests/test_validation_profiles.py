"""Offline developer tools must read WeLite's current login, including logout."""
from pathlib import Path
import tempfile
import sys
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/'scripts'))
import verify_book_footnotes as footnotes
import verify_progress_sync as progress


class ValidationProfilesTest(unittest.TestCase):
    def test_default_profile_and_explicit_override(self):
        for module in (footnotes,progress):
            with self.subTest(module=module.__name__):
                with patch.object(sys,'argv',['verify']):
                    self.assertEqual(Path('settings/welite-state.lua'),module.parse_args().settings)
                with patch.object(sys,'argv',['verify','--settings','custom.lua']):
                    self.assertEqual(Path('custom.lua'),module.parse_args().settings)

    def test_logout_does_not_fall_back_to_original_plugin_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            root=Path(directory)
            old=root/'weread.lua';new=root/'welite-state.lua'
            old.write_text('return {api_key="fixture-key",cookies={wr_vid="42",wr_skey="fixture-cookie"}}')
            new.write_text('return {api_key="",cookies={}}')
            self.assertEqual('fixture-key',progress.load_settings(old)['api_key'])
            with self.assertRaisesRegex(progress.ValidationError,'does not contain api_key'):
                progress.load_settings(new)
            new.unlink()
            with self.assertRaisesRegex(progress.ValidationError,'Cannot read settings'):
                progress.load_settings(new)

    def test_footnote_tool_executes_relocated_lua_transform(self):
        source='<html><body><p><a class="noteref" href="#note">[1]</a></p><p id="note">[1] 合成脚注</p></body></html>'
        transformed,css,stats=footnotes.lua_transform(ROOT,source,{'chapterUid':'7','chapterIdx':1})
        self.assertEqual(1,stats['converted']);self.assertEqual(0,stats['unresolved'])
        self.assertIn('合成脚注',transformed);self.assertIn('doc-noteref',transformed)
        self.assertTrue(css)
