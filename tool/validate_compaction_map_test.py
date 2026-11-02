"""Offline regression tests for the scenario-map validator."""
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


VALIDATOR = Path(__file__).with_name('validate_compaction_map.py').resolve()


class ValidateCompactionMapTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.change = self.root / 'openspec/changes/context-compaction-and-window-accuracy'
        spec = self.change / 'specs/example/spec.md'
        spec.parent.mkdir(parents=True)
        spec.write_text('### Requirement: Contract\n#### Scenario: Normative\n', encoding='utf-8')
        self.rows = [self.row('example → Contract', 'Normative', 'normative'),
                     self.row('Amendment regression', 'Supplemental', 'supplemental')]
        test = self.root / 'test/example_test.dart'
        test.parent.mkdir()
        test.touch()
        self.log = self.root / '.dart_tool/group7/example_test.log'
        self.log.parent.mkdir(parents=True)
        self.log.write_text('+1: normative\n+2: supplemental\nAll tests passed!\n', encoding='utf-8')

    def row(self, requirement, scenario, name):
        return f'| {requirement} | {scenario} | `test/example_test.dart` | `{name}` | green |'

    def validate(self, passes=False):
        (self.change / 'tasks.md').write_text('\n'.join(self.rows), encoding='utf-8')
        result = subprocess.run([sys.executable, str(VALIDATOR)], cwd=self.root,
                                capture_output=True, text=True, encoding='utf-8')
        self.assertEqual(result.returncode == 0, passes, result.stdout + result.stderr)

    def test_spec_derived_count_and_supplemental_set(self):
        self.validate(passes=True)

    def test_duplicate_normative_row(self):
        self.rows.append(self.rows[0])
        self.validate()

    def test_missing_normative_row(self):
        self.rows.pop(0)
        self.validate()

    def test_extra_normative_row(self):
        self.rows.append(self.row('example → Contract', 'Extra', 'normative'))
        self.validate()

    def test_duplicate_supplemental_scenario(self):
        self.rows.append(self.row('Amendment regression', 'Supplemental', 'normative'))
        self.validate()

    def test_supplemental_duplicates_normative_scenario(self):
        self.rows[1] = self.row('Amendment regression', 'Normative', 'supplemental')
        self.validate()

    def test_missing_file_in_either_set(self):
        for index in (0, 1):
            with self.subTest(index=index):
                original = self.rows[index]
                self.rows[index] = original.replace('example_test.dart', 'missing_test.dart')
                self.validate()
                self.rows[index] = original

    def test_missing_passed_test_in_either_set(self):
        for index in (0, 1):
            with self.subTest(index=index):
                original = self.rows[index]
                name = 'normative' if index == 0 else 'supplemental'
                self.rows[index] = original.replace(f'`{name}`', '`not run`')
                self.validate()
                self.rows[index] = original

    def test_failed_single_file_log(self):
        self.log.write_text('+1: normative\n+2: supplemental\n[E]\nAll tests passed!\n', encoding='utf-8')
        self.validate()


if __name__ == '__main__':
    unittest.main()
