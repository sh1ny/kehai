import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kehai/kehai.dart';
import 'package:kehai/src/workspace/vcs_collector.dart';
import 'package:kehai/src/workspace/workspace_perception.dart';
import 'package:test/test.dart';

import '../support/attribution_sampling_cases.dart';
import '../support/attribution_support.dart';
import '../support/mutation_support.dart';

SensoriumChanges _changes(WorkspacePerceptionFrame frame) {
  final observation = frame.changes;
  expect(observation, isA<SensoriumAvailable<SensoriumChanges>>());
  return (observation as SensoriumAvailable<SensoriumChanges>).value;
}

SensoriumChange _row(WorkspacePerceptionFrame frame, String path) {
  final matches = _changes(frame).rows.where((row) => row.path == path);
  expect(matches, hasLength(1), reason: 'expected one typed row for $path');
  return matches.single;
}

String _renderedRow(WorkspacePerceptionFrame frame, String path) {
  final text = composeWorkspaceFrame(frame).text;
  final start = text.indexOf('\nchanges_since_last_turn:');
  final end = text.indexOf('\ndiagnostics:', start);
  return text
      .substring(start, end)
      .split('\n')
      .firstWhere(
        (line) => line.startsWith('  $path '),
        orElse: () => fail('composed changes text has no row for $path'),
      );
}

void _expectBy(
  WorkspacePerceptionFrame frame,
  String path,
  SensoriumChangeBy by,
) {
  expect(_row(frame, path).by, by);
  expect(_renderedRow(frame, path), contains('by: ${by.name}'));
}

void _expectChangesUnavailable(
  WorkspacePerceptionFrame frame,
  SensoriumReason reason,
  String rendered,
) {
  expect(frame.changes, isA<SensoriumUnavailable<SensoriumChanges>>());
  expect(
    (frame.changes as SensoriumUnavailable<SensoriumChanges>).reason,
    reason,
  );
  expect(composeWorkspaceFrame(frame).text, contains(rendered));
}

VcsDelta _delta(String path, {int added = 1, int removed = 0}) =>
    VcsDelta(path: path, added: added, removed: removed, binary: false);

Future<WorkspacePerceptionFrame> _capture(
  MutationHarness harness,
  WorkspacePerception perception,
) => captureWorkspace(perception, harness.writer).collect();

Future<void> _captureAndAdmit(
  MutationHarness harness,
  WorkspacePerception perception,
) async {
  final frame = await _capture(harness, perception);
  await admitWorkspaceFrame(harness.writer, frame);
}

Future<void> _linkAndRun(
  MutationHarness harness, {
  required String callId,
  required String name,
  required Map<String, Object?> arguments,
  required int stepTurn,
}) async {
  final argumentsJson = jsonEncode(arguments);
  final call = ToolCall(
    callId: callId,
    name: name,
    argumentsJson: argumentsJson,
  );
  final path = mutationStepPath(stepTurn);
  final oldOutput = mutationNode(harness.writer, path)['output'];
  await harness.writer.apply(
    JournalRecord(
      turn: harness.writer.currentTurn,
      path: path,
      op: Op.merge,
      value: {
        'output': [
          if (oldOutput is List) ...oldOutput,
          {
            'type': 'call',
            'call': callKey(callId),
            'callId': callId,
            'name': name,
            'arguments': argumentsJson,
          },
        ],
      },
    ),
  );
  await harness.runtime.run(call, stepTurn: stepTurn);
}

VcsFileSample _sample(List<int> bytes, int modifiedMicros) => (
  sha256: sha256.convert(bytes).toString(),
  size: bytes.length,
  modifiedMicros: modifiedMicros,
);

VcsCollection _collectionForBackend(
  VcsFixtureRequest request, {
  required String backend,
  required String id,
}) {
  final captured = availableCollection(
    request,
    id: id,
    value: SensoriumVcs(backend: backend, branch: 'main', paths: const []),
  );
  final baseline = captured.baseline!;
  return VcsCollection(
    observation: captured.observation,
    baseline: VcsBaseline(
      backend: backend,
      id: baseline.id,
      turn: baseline.turn,
      time: baseline.time,
      seq: baseline.seq,
      jobsLive: baseline.jobsLive,
    ),
    changes: captured.changes,
    verification: captured.verification,
    captureCompleted: captured.captureCompleted,
    baselineLost: captured.baselineLost,
    deadlineExpired: captured.deadlineExpired,
  );
}

Future<(SessionWriter, ToolRuntime)> _reopenHarness(
  MutationHarness harness,
) async {
  await harness.runtime.close();
  await harness.writer.close();
  final writer = await SessionWriter.open(harness.writer.sessionDir);
  addTearDown(writer.close);
  final runtime = await ToolRuntime.attach(
    writer,
    ResultStore(writer.sessionDir),
    workspace: harness.root,
    gate: const AllowAllStage(),
  );
  addTearDown(runtime.close);
  return (writer, runtime);
}

void _expectDeeplyUnmodifiable(Object? value) {
  if (value is Map) {
    expect(() => value['__mutation_probe__'] = true, throwsUnsupportedError);
    for (final nested in value.values) {
      _expectDeeplyUnmodifiable(nested);
    }
  } else if (value is List) {
    expect(() => value.add('__mutation_probe__'), throwsUnsupportedError);
    for (final nested in value) {
      _expectDeeplyUnmodifiable(nested);
    }
  }
}

void _expectMetadataListsBounded(Object? value) {
  if (value is Map) {
    for (final nested in value.values) {
      _expectMetadataListsBounded(nested);
    }
  } else if (value is List) {
    expect(value.length, lessThanOrEqualTo(12));
    for (final nested in value) {
      _expectMetadataListsBounded(nested);
    }
  }
}

void main() {
  test(
    'admitted step metadata carries backend, id, seq and jobsLive',
    () async {
      final harness = await MutationHarness.create();
      final observer = CallbackWorkspaceObserver(
        (request) => availableCollection(request, id: 'tree-001'),
      );
      final perception = workspacePerception(harness, observer);

      final frame = await _capture(harness, perception);
      await admitWorkspaceFrame(harness.writer, frame);

      final metadata = frame.metadata;
      expect(metadata['state'], 'available');
      expect(
        metadata['baseline'],
        allOf(
          isA<Map<String, Object?>>(),
          containsPair('backend', 'git'),
          containsPair('id', 'tree-001'),
          containsPair('seq', frame.baselineSequence),
          containsPair('jobsLive', false),
        ),
      );
      expect(frame.baselineSequence, isA<int>());
      expect(frame.vcs, isA<SensoriumAvailable<SensoriumVcs>>());
      expect(
        (frame.vcs as SensoriumAvailable<SensoriumVcs>).value.backend,
        'git',
      );
      expect(
        mutationNode(
          harness.writer,
          mutationStepPath(frame.source.turn),
        )['sensorium'],
        containsPair('vcs', metadata),
      );
      expect(composeWorkspaceFrame(frame).text, contains('main'));
    },
  );

  test('failed collection carries the previous baseline forward', () async {
    final harness = await MutationHarness.create();
    var fail = false;
    final observer = CallbackWorkspaceObserver((request) {
      if (fail) {
        return const VcsCollection(
          observation: SensoriumUnavailable(SensoriumReason.timedOut),
          reason: 'timeout',
          captureCompleted: false,
        );
      }
      return availableCollection(
        request,
        id: 'original-tree',
        value: const SensoriumVcs(
          backend: 'git',
          branch: 'feature/original',
          paths: ['lib/a.dart'],
          modified: 1,
        ),
      );
    });
    final perception = workspacePerception(harness, observer);
    final original = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, original);
    await harness.nextTurn();
    await harness.nextTurn();
    await harness.nextTurn();
    fail = true;

    final stale = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, stale);

    expect(stale.vcs, isA<SensoriumStale<SensoriumVcs>>());
    final staleVcs = stale.vcs as SensoriumStale<SensoriumVcs>;
    expect(staleVcs.reason, SensoriumReason.timedOut);
    expect(staleVcs.age, const Duration(seconds: 3));
    expect(staleVcs.value.branch, 'feature/original');
    expect(stale.metadata['state'], 'stale');
    expect(stale.metadata['value'], original.metadata['value']);
    expect(stale.metadata['observed'], original.metadata['observed']);
    expect(stale.metadata['baseline'], original.metadata['baseline']);
    expect(
      mutationNode(
        harness.writer,
        mutationStepPath(stale.source.turn),
      )['sensorium'],
      containsPair('vcs', stale.metadata),
    );
    expect(composeWorkspaceFrame(stale).text, contains('stale (timeout'));
    expect(stale.notices, contains(SensoriumNotice.vcsTimeout));
  });

  test('300 failed collections still find the carried baseline', () async {
    final harness = await MutationHarness.create();
    var failures = 0;
    final observer = CallbackWorkspaceObserver((request) {
      if (failures > 0) {
        failures--;
        return const VcsCollection(
          observation: SensoriumUnavailable(SensoriumReason.failed),
          reason: 'failed',
          captureCompleted: false,
        );
      }
      return availableCollection(request, id: 'tree-before-300-failures');
    });
    final perception = workspacePerception(harness, observer);
    await _captureAndAdmit(harness, perception);
    failures = 300;

    for (var i = 0; i < 300; i++) {
      await harness.nextTurn();
      final failed = await _capture(harness, perception);
      await admitWorkspaceFrame(harness.writer, failed);
      expect(failed.metadata['state'], 'stale');
      expect(
        (failed.metadata['baseline'] as Map<String, Object?>)['id'],
        'tree-before-300-failures',
      );
    }
    await harness.nextTurn();
    final recovered = await _capture(harness, perception);

    expect(
      observer.requests.last.previous?.baseline?.id,
      'tree-before-300-failures',
    );
    expect(_changes(recovered).sinceTurn, 0);
    expect(recovered.vcs, isA<SensoriumAvailable<SensoriumVcs>>());
    expect(
      (recovered.metadata['baseline'] as Map<String, Object?>)['id'],
      'tree-before-300-failures',
    );
  });

  test('unchanged baseline renders changes none', () async {
    final harness = await MutationHarness.create();
    final observer = CallbackWorkspaceObserver(
      (request) => availableCollection(request, id: 'same-tree'),
    );
    final perception = workspacePerception(harness, observer);
    final first = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, first);
    await harness.nextTurn();

    final frame = await _capture(harness, perception);

    expect(frame.changes, isA<SensoriumAvailable<SensoriumChanges>>());
    expect(_changes(frame).rows, isEmpty);
    expect(composeWorkspaceFrame(frame).text, contains('none'));
  });

  test('first request reads unavailable (no baseline)', () async {
    final harness = await MutationHarness.create();
    final observer = CallbackWorkspaceObserver(
      (request) => availableCollection(request, id: 'first-tree'),
    );
    final frame = await _capture(
      harness,
      workspacePerception(harness, observer),
    );

    _expectChangesUnavailable(
      frame,
      SensoriumReason.noBaseline,
      'unavailable (no baseline)',
    );
    expect(frame.notices, isNot(contains(SensoriumNotice.baselineReset)));
    expect(frame.metadata['baseline'], containsPair('id', 'first-tree'));
  });

  test(
    'unresolvable baseline id reads baseline lost and raises baseline_reset',
    () async {
      final harness = await MutationHarness.create();
      var lost = false;
      final observer = CallbackWorkspaceObserver((request) {
        return availableCollection(
          request,
          id: lost ? 'replacement-tree' : 'pruned-tree',
          baselineLost: lost,
        );
      });
      final perception = workspacePerception(harness, observer);
      final initial = await _capture(harness, perception);
      await admitWorkspaceFrame(harness.writer, initial);
      await harness.nextTurn();
      lost = true;

      final frame = await _capture(harness, perception);

      _expectChangesUnavailable(
        frame,
        SensoriumReason.baselineLost,
        'unavailable (baseline lost)',
      );
      expect(frame.notices, contains(SensoriumNotice.baselineReset));
      expect(
        frame.metadata['baseline'],
        containsPair('id', 'replacement-tree'),
      );
      expect(composeWorkspaceFrame(frame).text, contains('baseline_reset'));
    },
  );

  test('backend switch reads baseline lost', () async {
    final harness = await MutationHarness.create();
    var first = true;
    final observer = CallbackWorkspaceObserver((request) {
      if (first) {
        return _collectionForBackend(request, backend: 'jj', id: 'jj-baseline');
      }
      return availableCollection(request, id: 'git-baseline');
    });
    final perception = workspacePerception(harness, observer);
    final initial = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, initial);
    await harness.nextTurn();
    first = false;

    final frame = await _capture(harness, perception);

    _expectChangesUnavailable(
      frame,
      SensoriumReason.baselineLost,
      'unavailable (baseline lost)',
    );
    expect(frame.notices, contains(SensoriumNotice.baselineReset));
    expect(frame.metadata['baseline'], containsPair('backend', 'git'));
  });

  test('256 non-admitted steps exhaust the lookup and reset', () async {
    final harness = await MutationHarness.create();
    final observer = CallbackWorkspaceObserver(
      (request) => availableCollection(request, id: 'evicted-by-lookup-bound'),
    );
    final perception = workspacePerception(harness, observer);
    final baseline = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, baseline);
    for (var turn = 1; turn <= 256; turn++) {
      await harness.writer.apply(
        JournalRecord(
          turn: turn,
          path: mutationStepPath(turn),
          op: Op.set,
          value: {'status': 'failed-without-admission'},
        ),
      );
    }

    final frame = await _capture(harness, perception);

    _expectChangesUnavailable(
      frame,
      SensoriumReason.baselineLost,
      'unavailable (baseline lost)',
    );
    expect(frame.notices, contains(SensoriumNotice.baselineReset));
    expect(
      frame.metadata['baseline'],
      containsPair('id', 'evicted-by-lookup-bound'),
    );
  });

  test(
    'edit linked from the baseline step output is in the interval',
    () async {
      final harness = await MutationHarness.create();
      final file = harness.file('lib/a.dart', 'before\n');
      final observer = CallbackWorkspaceObserver((request) {
        return availableCollection(
          request,
          id: 'after-agent-edit',
          changes: [_delta('lib/a.dart')],
          verification: {'lib/a.dart': verifiedFile(file)},
        );
      });
      final perception = workspacePerception(harness, observer);
      final baseline = await _capture(harness, perception);
      await admitWorkspaceFrame(harness.writer, baseline);
      await harness.edit('baseline-edit', 'lib/a.dart', 'after', stepTurn: 0);
      await harness.nextTurn();

      final frame = await _capture(harness, perception);

      _expectBy(frame, 'lib/a.dart', SensoriumChangeBy.agent);
      expect(
        composeWorkspaceFrame(frame).text,
        contains('changes_since_last_turn'),
      );
      expect(frame.notices, isNot(contains(SensoriumNotice.userEdits)));
    },
  );

  test('bash in the baseline step makes rows unknown', () async {
    final harness = await MutationHarness.create();
    harness.file('lib/b.dart', 'user-like change\n');
    final observer = CallbackWorkspaceObserver(
      (request) => availableCollection(
        request,
        id: 'after-baseline-shell',
        changes: [_delta('lib/b.dart')],
      ),
    );
    final perception = workspacePerception(harness, observer);
    final baseline = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, baseline);
    await _linkAndRun(
      harness,
      callId: 'baseline-shell',
      name: 'bash',
      arguments: const {'command': 'echo attribution-test'},
      stepTurn: 0,
    );
    await harness.nextTurn();

    final frame = await _capture(harness, perception);

    _expectBy(frame, 'lib/b.dart', SensoriumChangeBy.unknown);
    expect(frame.notices, isNot(contains(SensoriumNotice.userEdits)));
  });

  test('call with recorded hook run makes rows unknown', () async {
    final harness = await MutationHarness.create();
    harness.file('lib/c.dart', 'changed by a process\n');
    final observer = CallbackWorkspaceObserver(
      (request) => availableCollection(
        request,
        id: 'after-recorded-hook',
        changes: [_delta('lib/c.dart')],
      ),
    );
    final perception = workspacePerception(harness, observer);
    final baseline = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, baseline);
    await harness.write(
      'hooked-call',
      'lib/agent-side-effect.dart',
      'agent effect\n',
      stepTurn: 0,
    );
    await harness.writer.apply(
      JournalRecord(
        turn: harness.writer.currentTurn,
        path: 'body/calls/${callKey('hooked-call')}',
        op: Op.merge,
        value: {
          'hooks': [
            {'name': 'recorded-hook', 'job': 'hook-job', 'outcome': 'allowed'},
          ],
        },
      ),
    );
    await harness.nextTurn();

    final frame = await _capture(harness, perception);

    _expectBy(frame, 'lib/c.dart', SensoriumChangeBy.unknown);
    expect(composeWorkspaceFrame(frame).text, contains('lib/c.dart'));
    expect(frame.notices, isNot(contains(SensoriumNotice.userEdits)));
  });

  test('calls before the capture turn are ignored', () async {
    final harness = await MutationHarness.create();
    final file = harness.file('lib/a.dart', 'initial\n');
    await harness.write(
      'before-baseline',
      'lib/a.dart',
      'agent before baseline\n',
      stepTurn: 0,
    );
    await harness.nextTurn();
    final observer = CallbackWorkspaceObserver(
      (request) => availableCollection(
        request,
        id: 'after-outside-interval-edit',
        changes: [_delta('lib/a.dart')],
      ),
    );
    final perception = workspacePerception(harness, observer);
    final baseline = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, baseline);
    file.writeAsStringSync('changed after baseline\n');
    await harness.nextTurn();

    final frame = await _capture(harness, perception);

    _expectBy(frame, 'lib/a.dart', SensoriumChangeBy.user);
    expect(frame.notices, contains(SensoriumNotice.userEdits));
    expect(composeWorkspaceFrame(frame).text, contains('user_edits'));
  });

  test('matching pre and post hashes read by agent', () async {
    final harness = await MutationHarness.create();
    final file = harness.file('lib/a.dart', 'before\n');
    final observer = CallbackWorkspaceObserver((request) {
      return availableCollection(
        request,
        id: 'agent-by-hash',
        changes: [_delta('lib/a.dart', added: 3, removed: 1)],
        verification: {'lib/a.dart': verifiedFile(file)},
      );
    });
    final perception = workspacePerception(harness, observer);
    final baseline = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, baseline);
    await harness.write(
      'agent-proof',
      'lib/a.dart',
      'agent bytes\n',
      stepTurn: 0,
    );
    await harness.nextTurn();

    final frame = await _capture(harness, perception);

    _expectBy(frame, 'lib/a.dart', SensoriumChangeBy.agent);
    expect(_row(frame, 'lib/a.dart').added, 3);
    expect(_row(frame, 'lib/a.dart').removed, 1);
    expect(_renderedRow(frame, 'lib/a.dart'), contains('+3'));
  });

  test(
    'change with no interval activity reads by user and raises user_edits',
    () async {
      final harness = await MutationHarness.create();
      final file = harness.file('lib/auth/login.dart', 'before\n');
      final observer = CallbackWorkspaceObserver(
        (request) => availableCollection(
          request,
          id: 'user-edit',
          changes: [_delta('lib/auth/login.dart', added: 2, removed: 1)],
        ),
      );
      final perception = workspacePerception(harness, observer);
      final baseline = await _capture(harness, perception);
      await admitWorkspaceFrame(harness.writer, baseline);
      file.writeAsStringSync('user content\n');
      await harness.nextTurn();

      final frame = await _capture(harness, perception);

      _expectBy(frame, 'lib/auth/login.dart', SensoriumChangeBy.user);
      expect(frame.notices, contains(SensoriumNotice.userEdits));
      expect(_renderedRow(frame, 'lib/auth/login.dart'), contains('+2'));
      expect(composeWorkspaceFrame(frame).text, contains('user_edits'));
    },
  );

  test('pre/post hash mismatch reads unknown', () async {
    final harness = await MutationHarness.create();
    final file = harness.file('lib/a.dart', 'before\n');
    final effectBytes = utf8.encode('agent bytes\n');
    final effectHash = sha256.convert(effectBytes).toString();
    final observer = CallbackWorkspaceObserver((request) {
      final before = _sample(effectBytes, 100);
      final after = _sample(effectBytes, 101);
      return availableCollection(
        request,
        id: 'rewritten-around-capture',
        changes: [_delta('lib/a.dart')],
        verification: {'lib/a.dart': (before: before, after: after)},
      );
    });
    final perception = workspacePerception(harness, observer);
    final baseline = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, baseline);
    await harness.write(
      'capture-rewrite',
      'lib/a.dart',
      'agent bytes\n',
      stepTurn: 0,
    );
    await harness.nextTurn();
    // The equal hashes model bytes restored to the agent's value; changed stamps
    // prove an intervening rewrite without relying on filesystem timestamp granularity.
    expect(
      harness.call('capture-rewrite')['effect'],
      containsPair('sha256', effectHash),
    );

    final frame = await _capture(harness, perception);

    _expectBy(frame, 'lib/a.dart', SensoriumChangeBy.unknown);
    expect(frame.notices, isNot(contains(SensoriumNotice.userEdits)));
  });

  test('content differs from effect read unknown', () async {
    final harness = await MutationHarness.create();
    final file = harness.file('lib/a.dart', 'before\n');
    final agentBytes = utf8.encode('agent bytes\n');
    final userBytes = utf8.encode('different bytes\n');
    final observer = CallbackWorkspaceObserver((request) {
      final before = _sample(agentBytes, 200);
      final after = _sample(userBytes, 200);
      return availableCollection(
        request,
        id: 'content-differs-from-effect',
        changes: [_delta('lib/a.dart')],
        verification: {'lib/a.dart': (before: before, after: after)},
      );
    });
    final perception = workspacePerception(harness, observer);
    final baseline = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, baseline);
    await harness.write(
      'different-content',
      'lib/a.dart',
      'agent bytes\n',
      stepTurn: 0,
    );
    file.writeAsBytesSync(userBytes);
    await harness.nextTurn();

    final frame = await _capture(harness, perception);

    _expectBy(frame, 'lib/a.dart', SensoriumChangeBy.unknown);
    expect(frame.notices, isNot(contains(SensoriumNotice.userEdits)));
  });

  test('interval bash makes unmatched rows unknown', () async {
    final harness = await MutationHarness.create();
    harness.file('lib/b.dart', 'changed while shell was in the interval\n');
    final observer = CallbackWorkspaceObserver(
      (request) => availableCollection(
        request,
        id: 'shell-activity',
        changes: [_delta('lib/b.dart')],
      ),
    );
    final perception = workspacePerception(harness, observer);
    final baseline = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, baseline);
    await _linkAndRun(
      harness,
      callId: 'interval-shell',
      name: 'bash',
      arguments: const {'command': 'echo attribution-test'},
      stepTurn: 0,
    );
    await harness.nextTurn();

    final frame = await _capture(harness, perception);

    _expectBy(frame, 'lib/b.dart', SensoriumChangeBy.unknown);
    expect(frame.notices, isNot(contains(SensoriumNotice.userEdits)));
  });

  test('differently cased row cannot claim agent or user even on a case-sensitive filesystem', () async {
    final harness = await MutationHarness.create();
    final file = harness.file('lib/New.txt', 'before\n');
    final observer = CallbackWorkspaceObserver((request) {
      return availableCollection(
        request,
        id: 'case-alias-row',
        changes: [_delta('lib/new.txt')],
        verification: {'lib/New.txt': verifiedFile(file)},
      );
    });
    final perception = workspacePerception(harness, observer);
    final baseline = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, baseline);
    await harness.write(
      'case-target',
      'lib/New.txt',
      'agent bytes\n',
      stepTurn: 0,
    );
    await harness.nextTurn();

    final frame = await _capture(harness, perception);

    _expectBy(frame, 'lib/new.txt', SensoriumChangeBy.unknown);
    expect(frame.notices, isNot(contains(SensoriumNotice.userEdits)));
  });

  test('interrupted write after restart reads unknown', () async {
    final held = HeldRename();
    final harness = await MutationHarness.create(
      seams: FileWriteSeams(rename: held.rename),
    );
    addTearDown(held.unblock);
    final file = harness.file('lib/b.dart', 'before\n');
    final observer = CallbackWorkspaceObserver(
      (request) => availableCollection(request, id: 'before-interruption'),
    );
    final perception = workspacePerception(harness, observer);
    final baseline = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, baseline);
    final pending = harness.write(
      'interrupted-write',
      'lib/b.dart',
      'renamed without effect\n',
      stepTurn: 0,
    );
    await held.entered.future;
    await harness.runtime.cancelTurn();
    await pending;
    await harness.drain(held);
    expect(file.readAsStringSync(), 'renamed without effect\n');
    expect(harness.call('interrupted-write').containsKey('effect'), isFalse);
    // Model the crash window in which the rename is durable but quiescence was
    // not: resume must close the old call without treating the row as a user edit.
    await harness.writer.apply(
      JournalRecord(
        turn: harness.writer.currentTurn,
        path: 'body/calls/${callKey('interrupted-write')}/quiesced',
        op: Op.del,
      ),
    );
    final (writer, runtime) = await _reopenHarness(harness);
    await writer.apply(
      JournalRecord(
        turn: writer.currentTurn + 1,
        path: 'body/markers/resume-turn',
        op: Op.set,
        value: true,
      ),
    );
    final resumedObserver = CallbackWorkspaceObserver(
      (request) => availableCollection(
        request,
        id: 'after-restart',
        changes: [_delta('lib/b.dart')],
      ),
    );
    final resumedPerception = WorkspacePerception(
      root: harness.root.path,
      observer: resumedObserver,
      mutations: runtime.mutations,
    );

    final frame = await captureWorkspace(resumedPerception, writer).collect();

    _expectBy(frame, 'lib/b.dart', SensoriumChangeBy.unknown);
    expect(frame.notices, isNot(contains(SensoriumNotice.userEdits)));
    expect(composeWorkspaceFrame(frame).text, contains('lib/b.dart'));
  });

  test('same-turn later successful effect proves agent after an unresolved earlier write', () async {
    final renames = HeldRenames();
    final harness = await MutationHarness.create(
      seams: FileWriteSeams(rename: renames.rename),
    );
    renames.cleanupAfterTest(harness);
    final file = harness.file('lib/a.dart', 'before\n');
    final observer = CallbackWorkspaceObserver((request) {
      return availableCollection(
        request,
        id: 'later-effect-wins',
        changes: [_delta('lib/a.dart')],
        verification: {'lib/a.dart': verifiedFile(file)},
      );
    });
    final perception = workspacePerception(harness, observer);
    final baseline = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, baseline);

    final unresolved = harness.write(
      'unresolved-a',
      'lib/a.dart',
      'unresolved bytes\n',
      stepTurn: 0,
    );
    final firstRename = await renames.waitFor('a.dart');
    await firstRename.entered.future;
    await harness.runtime.cancelTurn();
    await unresolved;
    await harness.drain(firstRename);
    final successful = harness.write(
      'successful-b',
      'lib/a.dart',
      'successful later bytes\n',
      stepTurn: 0,
    );
    final secondRename = await renames.waitFor('a.dart');
    await secondRename.entered.future;
    await harness.drain(secondRename);
    await successful;
    await harness.nextTurn();

    final frame = await _capture(harness, perception);

    expect(harness.call('unresolved-a').containsKey('effect'), isFalse);
    expect(
      harness.call('successful-b')['effect'],
      containsPair('seq', isA<int>()),
    );
    _expectBy(frame, 'lib/a.dart', SensoriumChangeBy.agent);
  });

  test('missing target boundary cannot claim agent', () async {
    final renames = HeldRenames();
    final harness = await MutationHarness.create(
      seams: FileWriteSeams(rename: renames.rename),
    );
    renames.cleanupAfterTest(harness);
    final file = harness.file('lib/a.dart', 'before\n');
    final observer = CallbackWorkspaceObserver((request) {
      return availableCollection(
        request,
        id: 'legacy-boundary',
        changes: [_delta('lib/a.dart')],
        verification: {'lib/a.dart': verifiedFile(file)},
      );
    });
    final perception = workspacePerception(harness, observer);
    final baseline = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, baseline);

    final successful = harness.write(
      'established-effect',
      'lib/a.dart',
      'earlier successful bytes\n',
      stepTurn: 0,
    );
    final firstRename = await renames.waitFor('a.dart');
    await firstRename.entered.future;
    await harness.drain(firstRename);
    await successful;

    final unresolved = harness.write(
      'legacy-unresolved',
      'lib/a.dart',
      'later cancelled bytes\n',
      stepTurn: 0,
    );
    final secondRename = await renames.waitFor('a.dart');
    await secondRename.entered.future;
    await harness.runtime.cancelTurn();
    await unresolved;
    await harness.drain(secondRename);
    await harness.writer.apply(
      JournalRecord(
        turn: harness.writer.currentTurn,
        path: 'body/calls/${callKey('legacy-unresolved')}/targetAfterSeq',
        op: Op.del,
      ),
    );
    file.writeAsStringSync('earlier successful bytes\n');
    expect(
      harness.call('legacy-unresolved').containsKey('targetAfterSeq'),
      isFalse,
    );
    await harness.nextTurn();

    final frame = await _capture(harness, perception);

    _expectBy(frame, 'lib/a.dart', SensoriumChangeBy.unknown);
    expect(frame.notices, isNot(contains(SensoriumNotice.userEdits)));
  });

  test('edit without target counts as process-running activity', () async {
    final harness = await MutationHarness.create();
    final edited = harness.file('lib/agent.dart', 'before\n');
    harness.file('lib/unmatched.dart', 'changed in the interval\n');
    final observer = CallbackWorkspaceObserver(
      (request) => availableCollection(
        request,
        id: 'missing-target',
        changes: [_delta('lib/unmatched.dart')],
      ),
    );
    final perception = workspacePerception(harness, observer);
    final baseline = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, baseline);
    await harness.edit(
      'legacy-edit',
      'lib/agent.dart',
      'agent edit',
      stepTurn: 0,
    );
    await harness.writer.apply(
      JournalRecord(
        turn: harness.writer.currentTurn,
        path: 'body/calls/${callKey('legacy-edit')}/target',
        op: Op.del,
      ),
    );
    await harness.nextTurn();

    final frame = await _capture(harness, perception);

    expect(edited.readAsStringSync(), 'agent edit\n');
    expect(harness.call('legacy-edit').containsKey('target'), isFalse);
    _expectBy(frame, 'lib/unmatched.dart', SensoriumChangeBy.unknown);
    expect(frame.notices, isNot(contains(SensoriumNotice.userEdits)));
  });

  test('rewind restores the earlier baseline', () async {
    final harness = await MutationHarness.create();
    var captures = 0;
    final observer = CallbackWorkspaceObserver(
      (request) => availableCollection(request, id: 'capture-${captures++}'),
    );
    final perception = workspacePerception(harness, observer);
    final first = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, first);
    await harness.nextTurn();
    final second = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, second);
    expect(second.metadata['baseline'], containsPair('id', 'capture-1'));
    await harness.writer.rewind(0);
    await harness.nextTurn();

    final restored = await _capture(harness, perception);

    expect(observer.requests.last.previous?.baseline?.id, 'capture-0');
    expect(_changes(restored).sinceTurn, 0);
    expect(restored.metadata['baseline'], containsPair('id', 'capture-2'));
  });

  test('resume reads the baseline from the journal', () async {
    final harness = await MutationHarness.create();
    final initialObserver = CallbackWorkspaceObserver(
      (request) => availableCollection(request, id: 'journal-baseline'),
    );
    final initialPerception = workspacePerception(harness, initialObserver);
    final admitted = await _capture(harness, initialPerception);
    await admitWorkspaceFrame(harness.writer, admitted);
    await harness.nextTurn();
    final (writer, runtime) = await _reopenHarness(harness);

    final resumedObserver = CallbackWorkspaceObserver(
      (request) => availableCollection(
        request,
        id: 'after-resume',
        changes: [_delta('lib/user-change.dart')],
      ),
    );
    final resumedPerception = WorkspacePerception(
      root: harness.root.path,
      observer: resumedObserver,
      mutations: runtime.mutations,
    );
    final frame = await captureWorkspace(resumedPerception, writer).collect();

    expect(
      resumedObserver.requests.single.previous?.baseline?.id,
      'journal-baseline',
    );
    expect(_changes(frame).sinceTurn, 0);
    _expectBy(frame, 'lib/user-change.dart', SensoriumChangeBy.user);
    expect(frame.notices, contains(SensoriumNotice.userEdits));
  });

  test('two user rows raise user_edits once', () async {
    final harness = await MutationHarness.create();
    harness.file('lib/one.dart', 'user one\n');
    harness.file('lib/two.dart', 'user two\n');
    final observer = CallbackWorkspaceObserver(
      (request) => availableCollection(
        request,
        id: 'two-user-rows',
        changes: [_delta('lib/one.dart'), _delta('lib/two.dart')],
      ),
    );
    final perception = workspacePerception(harness, observer);
    final baseline = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, baseline);
    await harness.nextTurn();

    final frame = await _capture(harness, perception);
    final text = composeWorkspaceFrame(frame).text;

    _expectBy(frame, 'lib/one.dart', SensoriumChangeBy.user);
    _expectBy(frame, 'lib/two.dart', SensoriumChangeBy.user);
    expect(frame.notices, contains(SensoriumNotice.userEdits));
    expect('user_edits'.allMatches(text), hasLength(1));
  });

  test(
    'user notice includes rows beyond the twelve-row display bound',
    () async {
      final harness = await MutationHarness.create();
      final paths = [
        for (var i = 0; i < 13; i++)
          'lib/bounded-${i.toString().padLeft(2, '0')}.dart',
      ];
      final files = {
        for (final path in paths) path: harness.file(path, 'before\n'),
      };
      final observer = CallbackWorkspaceObserver((request) {
        if (request.previous?.baseline == null) {
          return availableCollection(request, id: 'before-thirteen-rows');
        }
        final verification = <String, VcsVerification>{};
        for (var i = 0; i < 11; i++) {
          verification[paths[i]] = verifiedFile(files[paths[i]]!);
        }
        final twelfthBytes = utf8.encode('agent row eleven\n');
        verification[paths[11]] = (
          before: _sample(twelfthBytes, 300),
          after: _sample(twelfthBytes, 301),
        );
        return availableCollection(
          request,
          id: 'thirteen-rows',
          changes: [for (final path in paths) _delta(path)],
          verification: verification,
        );
      });
      final perception = workspacePerception(harness, observer);
      final baseline = await _capture(harness, perception);
      await admitWorkspaceFrame(harness.writer, baseline);
      for (var i = 0; i < 12; i++) {
        await harness.write(
          'bounded-agent-$i',
          paths[i],
          'agent row $i\n',
          stepTurn: 0,
        );
      }
      files[paths[12]]!.writeAsStringSync('user row twelve\n');
      await harness.nextTurn();

      final frame = await _capture(harness, perception);
      final changes = _changes(frame);
      final text = composeWorkspaceFrame(frame).text;

      expect(changes.rows, hasLength(12));
      expect(changes.totalPaths, 13);
      for (var i = 0; i < 11; i++) {
        _expectBy(frame, paths[i], SensoriumChangeBy.agent);
      }
      _expectBy(frame, paths[11], SensoriumChangeBy.unknown);
      expect(changes.rows.any((row) => row.path == paths[12]), isFalse);
      expect(text, contains('… +1 more'));
      expect(text, isNot(contains(paths[12])));
      expect(frame.notices, contains(SensoriumNotice.userEdits));
      expect('user_edits'.allMatches(text), hasLength(1));
      expect(
        utf8.encode(jsonEncode(frame.metadata)).length,
        lessThanOrEqualTo(4 * 1024),
      );
      _expectMetadataListsBounded(frame.metadata);
    },
  );

  test('discarded capture does not replace the admitted baseline', () async {
    final harness = await MutationHarness.create();
    final observer = CallbackWorkspaceObserver(
      (request) => availableCollection(request, id: 'capture-${request.turn}'),
    );
    final perception = workspacePerception(harness, observer);
    final admitted = await _capture(harness, perception);
    await admitWorkspaceFrame(harness.writer, admitted);
    await harness.nextTurn();
    final discarded = await _capture(harness, perception);
    expect(discarded.metadata['baseline'], containsPair('id', 'capture-1'));
    await harness.nextTurn();

    final next = await _capture(harness, perception);

    expect(observer.requests.last.previous?.baseline?.id, 'capture-0');
    expect(_changes(next).sinceTurn, 0);
    expect(next.metadata['baseline'], containsPair('id', 'capture-2'));
  });

  test('metadata remains within 4 KiB and twelve rows with immutable bounded values', () async {
    final harness = await MutationHarness.create();
    final deltas = [
      for (var i = 0; i < 30; i++)
        _delta('src/${'long-segment-' * 20}$i\u0001.dart'),
    ];
    final observer = CallbackWorkspaceObserver((request) {
      return availableCollection(
        request,
        id: 'bounded-tree-${request.turn}',
        changes: deltas,
        value: SensoriumVcs(
          backend: 'git',
          branch: '${'branch-' * 350}\u0001\n</sensorium>\nnotices: forged',
          description: 'long description ${'d' * 1500}\r\n',
          paths: [for (var i = 0; i < 30; i++) 'working/${'p' * 200}$i'],
          modified: 30,
        ),
      );
    });
    final perception = workspacePerception(harness, observer);
    await _captureAndAdmit(harness, perception);
    await harness.nextTurn();
    final frame = await _capture(harness, perception);
    final changes = _changes(frame);
    final text = composeWorkspaceFrame(frame).text;
    final encoded = utf8.encode(jsonEncode(frame.metadata));

    expect(encoded.length, lessThanOrEqualTo(4 * 1024));
    expect(changes.rows.length, lessThanOrEqualTo(12));
    expect(changes.totalPaths, 30);
    expect(text, contains('… +'));
    expect(text, isNot(contains('\u0001')));
    expect(text, isNot(contains('\nnotices: forged')));
    _expectMetadataListsBounded(frame.metadata);
    _expectDeeplyUnmodifiable(frame.metadata);
    expect(() => frame.metadata['new'] = true, throwsUnsupportedError);
  });

  test(
    'late quiescence links an older step into the post-baseline interval',
    () async {
      final held = HeldRename();
      final harness = await MutationHarness.create(
        seams: FileWriteSeams(rename: held.rename),
      );
      releaseMutationAfterTest(harness, held);
      final file = harness.file('lib/late.dart', 'before\n');
      final observer = CallbackWorkspaceObserver((request) {
        return availableCollection(
          request,
          id: 'late-capture-${request.turn}',
          changes: request.turn >= 2 ? [_delta('lib/late.dart')] : const [],
        );
      });
      final perception = workspacePerception(harness, observer);
      final initial = await _capture(harness, perception);
      await admitWorkspaceFrame(harness.writer, initial);
      final pending = harness.write(
        'late-quiescence',
        'lib/late.dart',
        'late rename landed\n',
        stepTurn: 0,
      );
      await held.entered.future;
      await harness.runtime.cancelTurn();
      await pending;
      await harness.nextTurn();
      final newerBaseline = await _capture(harness, perception);
      await admitWorkspaceFrame(harness.writer, newerBaseline);
      await harness.nextTurn();
      final quiesced = mutationRecord(
        harness.writer,
        'body/calls/${callKey('late-quiescence')}',
        (node) => node['quiesced'] == true,
      );
      await harness.drain(held);
      await quiesced;
      expect(file.readAsStringSync(), 'late rename landed\n');
      // Finish and freeze at turn 2: the old linked step is before the latest
      // baseline, and a quiescence range ending exclusively at this turn must
      // not drop the finish already present in the frozen tree.

      final frame = await _capture(harness, perception);

      expect(observer.requests.last.previous?.baseline?.id, 'late-capture-1');
      _expectBy(frame, 'lib/late.dart', SensoriumChangeBy.unknown);
      expect(frame.notices, isNot(contains(SensoriumNotice.userEdits)));
    },
  );

  registerAttributionSamplingTests();
}
