import importlib.util
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('tb_ime_repair', Path(__file__).with_name('repair.py'))
repair = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repair)


class ConfigTests(unittest.TestCase):
    def test_changes_only_target_key(self):
        old = '# Keep this\n[Behavior]\nActiveByDefault=True\nPreeditEnabledByDefault=True\n[Other]\nValue=stay\n'
        self.assertEqual(repair.preedit_config(old), old.replace('PreeditEnabledByDefault=True', 'PreeditEnabledByDefault=False'))

    def test_missing_key_inserted_inside_behavior(self):
        old = '[Behavior]\nActiveByDefault=True\n[Other]\nValue=stay\n'
        self.assertEqual(repair.preedit_config(old), '[Behavior]\nActiveByDefault=True\nPreeditEnabledByDefault=False\n[Other]\nValue=stay\n')

    def test_missing_section_and_empty_config(self):
        self.assertEqual(repair.preedit_config('[Other]\nValue=stay'), '[Other]\nValue=stay\n[Behavior]\nPreeditEnabledByDefault=False\n')
        self.assertEqual(repair.preedit_config(''), '[Behavior]\nPreeditEnabledByDefault=False\n')

    def test_crlf_and_idempotency(self):
        old = '[Behavior]\r\nPreeditEnabledByDefault = True\r\n[Other]\r\nValue=stay\r\n'
        expected = old.replace('= True', '= False')
        self.assertEqual(repair.preedit_config(old), expected)
        self.assertEqual(repair.preedit_config(expected), expected)

    def test_duplicate_keys_and_sections_refused(self):
        for value in ('[Behavior]\n[Behavior]\n', '[Behavior]\nPreeditEnabledByDefault=True\nPreeditEnabledByDefault=False\n'):
            with self.assertRaises(ValueError):
                repair.preedit_config(value)

    def test_file_and_directory_snapshot_restore(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            f = root/'config'
            f.write_text('private local config')
            f.chmod(0o600)
            self.assertTrue(repair.snapshot_target(f, root/'backup'))
            repair.write_atomic(f, b'changed')
            repair.restore_target(f, root/'backup', True)
            self.assertEqual(f.read_text(), 'private local config')
            self.assertEqual(f.stat().st_mode & 0o777, 0o600)
            ext = root/'extension'
            ext.mkdir()
            (ext/'extension.js').write_text('old source')
            self.assertTrue(repair.snapshot_target(ext, root/'backup-extension'))
            (ext/'extension.js').write_text('new source')
            repair.restore_target(ext, root/'backup-extension', True)
            self.assertEqual((ext/'extension.js').read_text(), 'old source')

    def test_new_target_removed_on_rollback(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            f = root/'new-config'
            self.assertFalse(repair.snapshot_target(f, root/'unused-backup'))
            repair.write_atomic(f, b'created')
            repair.restore_target(f, root/'unused-backup', False)
            self.assertFalse(f.exists())

    def test_symlinks_refused_without_modifying_target(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original = root/'original'
            original.write_text('unchanged')
            link = root/'link'
            link.symlink_to(original)
            with self.assertRaises(ValueError):
                repair.write_atomic(link, b'wrong')
            with self.assertRaises(ValueError):
                repair.snapshot_target(link, root/'backup')
            with self.assertRaises(ValueError):
                repair.restore_target(link, root/'backup', False)
            self.assertEqual(original.read_text(), 'unchanged')


if __name__ == '__main__':
    unittest.main()
