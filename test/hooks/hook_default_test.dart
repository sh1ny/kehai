import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

/// One measured row of `docs/measurements/hook-startup.md`:
/// `| platform | shell | runs | p50 ms | p95 ms |`.
final _row = RegExp(
  r'^\|\s*([^|]+?)\s*\|\s*([^|]+?)\s*\|\s*(\d+)\s*\|\s*([\d.]+)\s*\|\s*([\d.]+)\s*\|\s*$',
);

/// The recorded default: `Default hook deadline: <n> ms`.
final _default = RegExp(r'^Default hook deadline: (\d+) ms$', multiLine: true);

void main() {
  test('default deadline is at least 3x the recorded p95 and at least 2 s', () {
    final file = File('docs/measurements/hook-startup.md');
    expect(file.existsSync(), isTrue, reason: 'the measurements are recorded');
    final text = file.readAsStringSync();

    final rows = [
      for (final line in text.split('\n'))
        if (_row.firstMatch(line.trimRight()) case final m?)
          (
            platform: m[1]!,
            shell: m[2]!,
            runs: int.parse(m[3]!),
            p95: double.parse(m[5]!),
          ),
    ];
    expect(
      rows.map((r) => '${r.platform}/${r.shell}'),
      containsAll(['Windows/git-bash', 'Linux/bash']),
      reason: 'bash is measured on both platforms',
    );
    for (final row in rows) {
      expect(row.runs, greaterThanOrEqualTo(20), reason: '${row.shell} runs');
    }

    final worst = rows.map((r) => r.p95).reduce((a, b) => a > b ? a : b);
    final deadline = defaultHookTimeout.inMilliseconds;
    expect(deadline, greaterThanOrEqualTo(2000));
    expect(deadline, greaterThanOrEqualTo(3 * worst));
    expect(
      _default.firstMatch(text)?[1],
      '$deadline',
      reason: 'the file records the default the code uses',
    );
  });
}
