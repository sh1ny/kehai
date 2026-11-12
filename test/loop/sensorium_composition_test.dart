import 'package:kehai/kehai.dart';
import 'package:kehai/src/session/scratch.dart';
import 'package:test/test.dart';

const _order = [
  'turn',
  'budget',
  'vcs',
  'changes_since_last_turn',
  'diagnostics',
  'tests',
  'processes',
  'plan',
  'scratch',
  'checkpoints',
  'notices',
];
const _folds = [
  SensoriumFold.processes,
  SensoriumFold.vcs,
  SensoriumFold.diagnostics,
  SensoriumFold.tests,
  SensoriumFold.changes,
  SensoriumFold.checkpoints,
];

String _section(String text, String name) {
  final headers = RegExp(
    r'^([a-z_]+):',
    multiLine: true,
  ).allMatches(text).toList();
  final index = headers.indexWhere((match) => match[1] == name);
  expect(index, greaterThanOrEqualTo(0), reason: 'missing $name section');
  final end = index + 1 < headers.length
      ? headers[index + 1].start
      : text.lastIndexOf('</sensorium>');
  return text
      .substring(headers[index].start, end)
      .replaceFirst(RegExp(r'\n$'), '');
}

String _id(String prefix, int i) => '$prefix-${i.toString().padLeft(2, '0')}';

SensoriumSnapshot _snapshot({
  ScratchState? scratch,
  int used = 41200,
  SensoriumObservation<SensoriumVcs>? vcs,
  SensoriumObservation<Iterable<SensoriumDiagnostic>>? diagnostics,
  SensoriumObservation<SensoriumTests>? tests,
  SensoriumObservation<String>? plan,
  Iterable<SensoriumProcess>? processes,
}) => SensoriumSnapshot(
  source: SensoriumSource(
    turn: 14,
    time: DateTime.utc(2026, 10, 30, 9, 5),
    offset: 99,
  ),
  workspaceName: 'proj',
  budget: SensoriumBudget(
    model: 'gpt-5.5',
    used: used,
    window: 200000,
    compactionThreshold: 180000,
    turnsSinceCompaction: 4,
  ),
  vcs:
      vcs ??
      SensoriumAvailable(
        SensoriumVcs(
          branch: 'feature',
          paths: List.generate(13, (i) => '${_id('vcs-path', i)}.dart'),
        ),
      ),
  changes: SensoriumAvailable(
    List.generate(
      6,
      (i) => SensoriumChange(
        '${_id('changed-path', i)}.dart',
        added: 12345,
        removed: 6789,
      ),
    ),
  ),
  diagnostics:
      diagnostics ??
      SensoriumAvailable(
        List.generate(
          11,
          (i) => SensoriumDiagnostic(
            '${_id('diag-path', i)}.dart',
            '${_id('error', i)} ${'x' * 30}',
          ),
        ),
      ),
  tests:
      tests ??
      SensoriumAvailable(
        SensoriumTests(
          passed: 100,
          failedNames: List.generate(9, (i) => _id('failing-test', i)),
        ),
      ),
  processes:
      processes ??
      List.generate(
        3,
        (i) => SensoriumProcess(
          id: _id('job', i),
          kind: 'shell',
          command: '${_id('command', i)} ${'x' * 35}',
          state: 'running',
          started: DateTime.utc(2026, 10, 30, 9, 3),
        ),
      ),
  plan: plan ?? SensoriumAvailable('Keep the API unchanged. ${'p' * 90}'),
  scratch:
      scratch ??
      ScratchState.read({
        'goal': {'value': 'Preserve every constraint.\n  café🧭\r\n'},
      }),
  checkpoints: SensoriumAvailable(
    List.generate(
      6,
      (i) => SensoriumCheckpoint('${_id('checkpoint', i)}-snapshot'),
    ),
  ),
  notices: const {
    SensoriumNotice.compactionRecovery,
    SensoriumNotice.legacyWindowIgnored,
  },
);

// Search a finite range of *direct* ceilings, rather than pinning incidental
// labels/rounding or adding a force-fold implementation switch. This fixture
// gives every stage positive savings, so every prefix must be reachable.
(SensoriumComposition, int) _atFold(SensoriumSnapshot snapshot, int count) {
  final full = composeSensorium(snapshot, maxTokens: 10000);
  expect(full.folds, isEmpty);
  for (
    var ceiling = full.tokens + SensoriumAllocations.budget;
    ceiling > 0;
    ceiling--
  ) {
    try {
      final result = composeSensorium(snapshot, maxTokens: ceiling);
      expect(
        result.folds,
        _folds.take(result.folds.length).toList(),
        reason: 'folds must always be a source-order prefix at $ceiling',
      );
      expect(result.tokens, estimateText(result.text));
      expect(result.tokens, lessThanOrEqualTo(ceiling));
      if (result.folds.length == count) return (result, ceiling);
    } on SensoriumCompositionError catch (error) {
      expect(error.code, 'ceiling');
    }
  }
  fail('no ceiling admits exactly $count folds; a required stage was skipped');
}

void main() {
  group('Finite sensorium composition', () {
    test(
      'typed supplied observations preserve section order and availability',
      () {
        final result = composeSensorium(
          _snapshot(
            vcs: const SensoriumUnavailable(SensoriumReason.timedOut),
            diagnostics: const SensoriumStale(
              [SensoriumDiagnostic('last.dart', 'last-known-error')],
              age: Duration(minutes: 7),
              reason: SensoriumReason.failed,
            ),
            tests: const SensoriumAvailable(
              SensoriumTests(passed: 0, failedNames: []),
            ),
            plan: const SensoriumUnavailable(SensoriumReason.notCollected),
            processes: const [],
            scratch: ScratchState.read(null),
          ),
        );
        expect(
          RegExp(
            r'^([a-z_]+):',
            multiLine: true,
          ).allMatches(result.text).map((match) => match[1]).toList(),
          _order,
        );
        expect(result.mode, 'full');
        expect(_section(result.text, 'vcs'), contains('unavailable'));
        expect(
          _section(result.text, 'vcs'),
          matches(RegExp(r'time.?out', caseSensitive: false)),
        );
        final stale = _section(result.text, 'diagnostics');
        expect(stale, contains('stale'));
        expect(stale, contains('failed'));
        expect(stale, contains('last-known-error'));
        expect(stale, matches(RegExp(r'\b(?:7m|420s|7 min(?:utes)?)\b')));
        expect(_section(result.text, 'tests'), 'tests: none');
        expect(_section(result.text, 'processes'), 'processes: none');
        expect(_section(result.text, 'scratch'), 'scratch: none');
        expect(
          _section(result.text, 'plan'),
          contains('unavailable (not collected)'),
        );
      },
    );

    test('known compaction facts and unavailable cost stay within budget allocation', () {
      final result = composeSensorium(_snapshot(), maxTokens: 10000);
      final budget = _section(result.text, 'budget');
      expect(budget, contains('41k/200k ctx (21%)'));
      expect(budget, contains('180k'));
      expect(
        budget,
        matches(
          RegExp(r'(?:since|turns)[^\n]*\b4\b|\b4\b[^\n]*(?:since|turns)'),
        ),
      );
      expect(budget, matches(RegExp(r'cost[^\n]*(?:unavailable|\?)')));
      expect(
        estimateText(budget),
        lessThanOrEqualTo(SensoriumAllocations.budget),
      );
    });

    test('process preview counts a large single-pass source without retaining all details', () {
      var enumerations = 0;
      var visited = 0;
      Iterable<SensoriumProcess> jobs() sync* {
        enumerations++;
        expect(
          enumerations,
          1,
          reason: 'freeze bounded previews and counts once',
        );
        for (var i = 0; i < 10000; i++) {
          visited++;
          yield SensoriumProcess(
            id: 'j-${i.toString().padLeft(5, '0')}',
            kind: 'shell',
            command: 'command-$i ${'x' * 1000}',
            state: 'running',
            started: DateTime.utc(2026, 10, 30, 9, 3),
          );
        }
      }

      final result = composeSensorium(
        _snapshot(processes: jobs()),
        maxTokens: 10000,
      );
      final processes = _section(result.text, 'processes');
      final shown = RegExp(r'j-\d{5}')
          .allMatches(processes)
          .map((match) => match[0])
          .toSet()
          .length;
      expect(enumerations, 1);
      expect(
        visited,
        10000,
        reason: 'count every live source node despite bounded previews',
      );
      expect(shown, lessThan(10000));
      expect(processes, contains('… +${10000 - shown} more'));
      expect(processes, isNot(contains('x' * 1000)));
      expect(
        estimateText(processes),
        lessThanOrEqualTo(SensoriumAllocations.processes),
      );
      expect(result.folds, isEmpty);
    });

    test('source previews cap at 12 paths 10 diagnostics 8 tests and 5 checkpoints', () {
      final result = composeSensorium(_snapshot(), maxTokens: 10000);
      expect(result.folds, isEmpty);
      for (final (section, prefix, shown, total) in [
        ('vcs', 'vcs-path', 12, 13),
        ('diagnostics', 'error', 10, 11),
        ('tests', 'failing-test', 8, 9),
        ('checkpoints', 'checkpoint', 5, 6),
      ]) {
        final text = _section(result.text, section);
        expect(RegExp('$prefix-\\d{2}').allMatches(text), hasLength(shown));
        expect(text, contains('… +${total - shown} more'));
      }
      expect(_section(result.text, 'vcs'), contains('vcs-path-00.dart'));
      expect(_section(result.text, 'vcs'), contains('vcs-path-11.dart'));
      expect(_section(result.text, 'vcs'), isNot(contains('vcs-path-12.dart')));
      expect(_section(result.text, 'diagnostics'), contains('error-09'));
      expect(_section(result.text, 'diagnostics'), isNot(contains('error-10')));
      expect(
        _section(result.text, 'checkpoints'),
        contains('checkpoint-05-snapshot'),
      );
      for (final entry in SensoriumAllocations.sectionCaps.entries) {
        expect(
          estimateText(_section(result.text, entry.key)),
          lessThanOrEqualTo(entry.value),
          reason: '${entry.key} must count its own labels and markers',
        );
      }
    });

    test('diagnostic messages truncate visibly at 120 characters before section capping', () {
      final message = 'D${'x' * 119}DO_NOT_RENDER';
      final result = composeSensorium(
        _snapshot(
          diagnostics: SensoriumAvailable([
            SensoriumDiagnostic('one.dart', message),
          ]),
        ),
        maxTokens: 10000,
      );
      final section = _section(result.text, 'diagnostics');
      expect(section, contains('D${'x' * 118}…'));
      expect(section, isNot(contains('DO_NOT_RENDER')));
      expect(section, isNot(contains('x' * 119)));
      expect(
        estimateText(section),
        lessThanOrEqualTo(SensoriumAllocations.diagnostics),
      );
    });

    for (var stage = 1; stage <= _folds.length; stage++) {
      test(
        'source-order folds preserve immutable sections and omission counts: ${_folds[stage - 1].name}',
        () {
          final snapshot = _snapshot();
          final full = composeSensorium(snapshot, maxTokens: 10000);
          final (result, ceiling) = _atFold(snapshot, stage);
          expect(result.folds, _folds.take(stage).toList());
          expect(result.mode, 'full');
          expect(result.tokens, lessThanOrEqualTo(ceiling));
          for (final name in SensoriumAllocations.immutableCaps.keys) {
            expect(
              _section(result.text, name),
              _section(full.text, name),
              reason: '$name must never fold or trim',
            );
          }
          final processes = _section(result.text, 'processes');
          expect(processes, contains('3'));
          expect(processes, isNot(contains('command-00')));
          expect(
            estimateText(processes),
            lessThanOrEqualTo(SensoriumAllocations.foldedProcesses),
          );
          if (stage >= 2) {
            final vcs = _section(result.text, 'vcs');
            expect(vcs, contains('13'));
            expect(vcs, isNot(contains('vcs-path-00')));
            expect(
              estimateText(vcs),
              lessThanOrEqualTo(SensoriumAllocations.foldedVcs),
            );
          } else {
            expect(_section(result.text, 'vcs'), contains('vcs-path-00'));
          }
          if (stage >= 3) {
            final diagnostics = _section(result.text, 'diagnostics');
            for (var i = 0; i < 3; i++) {
              expect(diagnostics, contains(_id('error', i)));
            }
            expect(diagnostics, isNot(contains('error-03')));
            expect(diagnostics, contains('… +8 more'));
          } else {
            expect(_section(result.text, 'diagnostics'), contains('error-03'));
          }
          if (stage >= 4) {
            final tests = _section(result.text, 'tests');
            expect(tests, contains('9'));
            expect(tests, isNot(contains('failing-test-00')));
            expect(
              estimateText(tests),
              lessThanOrEqualTo(SensoriumAllocations.foldedTests),
            );
          } else {
            expect(_section(result.text, 'tests'), contains('failing-test-00'));
          }
          final changes = _section(result.text, 'changes_since_last_turn');
          expect(changes, contains('changed-path-00.dart'));
          if (stage >= 5) {
            expect(changes, isNot(contains('12345')));
            expect(changes, isNot(contains('6789')));
          } else {
            expect(changes, contains('12345'));
            expect(changes, contains('6789'));
          }
          final checkpoints = _section(result.text, 'checkpoints');
          expect(checkpoints, contains('checkpoint-05-snapshot'));
          if (stage >= 6) {
            expect(
              RegExp(r'checkpoint-\d{2}').allMatches(checkpoints),
              hasLength(1),
            );
            expect(checkpoints, contains('… +5 more'));
          } else {
            expect(
              RegExp(r'checkpoint-\d{2}').allMatches(checkpoints),
              hasLength(5),
            );
            expect(checkpoints, contains('… +1 more'));
          }
        },
      );
    }

    test(
      'stale reason age and total omissions survive diagnostics folding',
      () {
        final snapshot = _snapshot(
          diagnostics: SensoriumStale(
            List.generate(
              11,
              (i) => SensoriumDiagnostic(
                'd$i.dart',
                '${_id('error', i)} ${'x' * 30}',
              ),
            ),
            age: const Duration(minutes: 7),
            reason: SensoriumReason.failed,
          ),
        );
        final (result, _) = _atFold(snapshot, 3);
        final section = _section(result.text, 'diagnostics');
        expect(section, contains('stale'));
        expect(section, contains('failed'));
        expect(section, matches(RegExp(r'\b(?:7m|420s|7 min(?:utes)?)\b')));
        expect(section, contains('… +8 more'));
        expect(section, isNot(contains('error-03')));
      },
    );

    test(
      'fold selection reserves full budget allocation independent of used text',
      () {
        final low = _snapshot(used: 0);
        final high = _snapshot(used: 1234567);
        final full = composeSensorium(low, maxTokens: 10000);
        // Covers each threshold and its neighbours, not just one lucky ceiling.
        final visited = <SensoriumFold>{};
        for (
          var ceiling = full.tokens + SensoriumAllocations.budget;
          ceiling > 0;
          ceiling--
        ) {
          SensoriumComposition? a;
          SensoriumComposition? b;
          SensoriumCompositionError? errorA;
          SensoriumCompositionError? errorB;
          try {
            a = composeSensorium(low, maxTokens: ceiling);
          } on SensoriumCompositionError catch (error) {
            errorA = error;
          }
          try {
            b = composeSensorium(high, maxTokens: ceiling);
          } on SensoriumCompositionError catch (error) {
            errorB = error;
          }
          expect(errorA?.code, errorB?.code, reason: 'ceiling $ceiling');
          expect(
            a?.folds,
            b?.folds,
            reason: 'budget text cannot reselect folds at $ceiling',
          );
          if (a != null && b != null) {
            visited.addAll(a.folds);
            expect(a.tokens, lessThanOrEqualTo(ceiling));
            expect(b.tokens, lessThanOrEqualTo(ceiling));
            for (final name in _order.where((name) => name != 'budget')) {
              expect(_section(a.text, name), _section(b.text, name));
            }
          }
        }
        expect(visited, containsAll(_folds));
      },
    );

    test(
      'shared safe minimum is immutable 550 plus folded 740 plus framing 20',
      () {
        int sum(Iterable<int> values) => values.fold(0, (a, b) => a + b);
        expect(SensoriumAllocations.sectionCaps, {
          'turn': 30,
          'budget': 40,
          'vcs': 250,
          'changes_since_last_turn': 200,
          'diagnostics': 300,
          'tests': 150,
          'processes': 150,
          'plan': 60,
          'scratch': maxScratchSectionTokens,
          'checkpoints': 60,
          'notices': 80,
        });
        expect(sum(SensoriumAllocations.immutableCaps.values), 550);
        expect(sum(SensoriumAllocations.foldedCaps.values), 740);
        expect(SensoriumAllocations.framing, 20);
        final calculated =
            sum(SensoriumAllocations.immutableCaps.values) +
            sum(SensoriumAllocations.foldedCaps.values) +
            SensoriumAllocations.framing;
        expect(SensoriumAllocations.minimumMaxTokens, calculated);
        expect(calculated, 1310);
        expect(SensoriumAllocations.defaultMaxTokens, 1500);
      },
    );

    test('maximum admitted scratch plus every folded section fits shared safe minimum', () {
      // 63 bytes of header/prefixes/separators + 5 * 227 = 1198 bytes.
      final scratch = ScratchState.read({
        for (var i = 0; i < 5; i++) 'k$i': {'value': 's' * 227},
      });
      expect(scratch.tokens, maxScratchSectionTokens);
      final snapshot = _snapshot(scratch: scratch);
      final result = composeSensorium(
        snapshot,
        maxTokens: SensoriumAllocations.minimumMaxTokens,
      );
      expect(_section(result.text, 'scratch'), scratch.text);
      expect(
        result.tokens,
        lessThanOrEqualTo(SensoriumAllocations.minimumMaxTokens),
      );
      expect(result.tokens, estimateText(result.text));
      final (folded, _) = _atFold(snapshot, 6);
      for (final entry in SensoriumAllocations.foldedCaps.entries) {
        expect(
          estimateText(_section(folded.text, entry.key)),
          lessThanOrEqualTo(entry.value),
        );
      }
      // Stronger than this fixture's actual sizes: use the worst allocation of
      // every folded section, all immutable maxima and framing simultaneously.
      final worst =
          SensoriumAllocations.immutableCaps.values.fold<int>(
            0,
            (a, b) => a + b,
          ) +
          SensoriumAllocations.foldedCaps.values.fold<int>(0, (a, b) => a + b) +
          SensoriumAllocations.framing;
      expect(worst, lessThanOrEqualTo(SensoriumAllocations.minimumMaxTokens));
      expect(_section(folded.text, 'scratch'), scratch.text);
      expect(
        _section(folded.text, 'notices'),
        _section(result.text, 'notices'),
      );
    });

    test('immutable overflow refuses with typed safe sizes without modifying scratch', () {
      final scratch = ScratchState.read({
        'goal': {'value': 'PRIVATE-SCRATCH ${'x' * 180}'},
      });
      final snapshot = _snapshot(scratch: scratch);
      const ceiling =
          1; // Explicit direct seam, deliberately below startup minimum.
      expect(
        () => composeSensorium(snapshot, maxTokens: ceiling),
        throwsA(
          isA<SensoriumCompositionError>()
              .having((e) => e.code, 'code', 'ceiling')
              .having(
                (e) => e.message.length,
                'bounded diagnostic',
                lessThanOrEqualTo(500),
              )
              .having((e) => e.message, 'configured size', contains('$ceiling'))
              .having(
                (e) => e.message,
                'required size',
                matches(RegExp(r'requir\w*\D+\d+', caseSensitive: false)),
              )
              .having(
                (e) => e.message,
                'no raw scratch',
                isNot(contains('PRIVATE-SCRATCH')),
              ),
        ),
      );
      expect(scratch.values['goal'], 'PRIVATE-SCRATCH ${'x' * 180}');
    });
  });
}
