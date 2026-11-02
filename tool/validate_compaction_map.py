"""Validate this change's scenario map against specs and single-file test logs.

Run after the pinned single-file commands recorded in local-verification.md:
  python tool/validate_compaction_map.py
No network access or test execution is performed here.
"""
from pathlib import Path
import re

change = Path('openspec/changes/context-compaction-and-window-accuracy')
expected = set()
for spec in sorted((change / 'specs').glob('*/spec.md')):
    requirement = None
    for line in spec.read_text(encoding='utf-8').splitlines():
        if line.startswith('### Requirement: '):
            requirement = line.removeprefix('### Requirement: ')
        elif line.startswith('#### Scenario: '):
            assert requirement, (spec, line)
            key = (f'{spec.parent.name} → {requirement}',
                   line.removeprefix('#### Scenario: '))
            assert key not in expected, ('duplicate scenario', key)
            expected.add(key)

rows = []
for line in (change / 'tasks.md').read_text(encoding='utf-8').splitlines():
    if line.startswith('| ') and '`test/' in line:
        cells = [cell.strip().strip('`') for cell in line.strip('|').split('|')]
        assert len(cells) == 5, line
        rows.append(cells)
actual = {(r[0], r[1]) for r in rows}
assert len(rows) == len(actual) == 65, ('row count/duplicates', len(rows), len(actual))
assert actual == expected, {'missing': sorted(expected - actual),
                            'extra': sorted(actual - expected)}
files = set()
for requirement, scenario, file, name, state in rows:
    assert state == 'green', (scenario, state)
    assert Path(file).is_file(), file
    stem = Path(file).stem
    if file == 'test/provider/compaction_test.dart':
        stem = 'provider_compaction_test'
    log = Path('.dart_tool/group7') / f'{stem}.log'
    output = log.read_text(encoding='utf-8')
    assert 'All tests passed!' in output and '[E]' not in output, log
    # Expanded test output includes the complete group-qualified test name.
    assert re.search(r'\+\d+: ' + re.escape(name) + r'\s*$', output, re.M), (file, name)
    files.add(file)
print(f'PASS: {len(expected)} spec scenarios = {len(rows)} unique green map rows; '
      f'all named tests passed across {len(files)} single-file logs')
