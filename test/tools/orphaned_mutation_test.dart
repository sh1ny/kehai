import 'dart:convert';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../support/attribution_support.dart' as attribution;

import 'package:kehai/src/session/mutations.dart';
import 'package:kehai/src/tools/mutation_runs.dart';
import 'package:kehai/src/workspace/vcs_collector.dart';
import 'package:kehai/src/workspace/workspace_perception.dart';

import '../support/mutation_support.dart';

bool _hasTarget(
  Map<String, Object?> records,
  String target, {
  bool finished = false,
}) => records.values.any(
  (record) =>
      record is Map &&
      record['target'] == target &&
      (!finished || record['finishedSeq'] is int),
);

Map<String, Object?> _target(Map<String, Object?> records, String target) =>
    Map<String, Object?>.from(
      records.values.singleWhere(
        (record) => record is Map && record['target'] == target,
      ) as Map,
    );

void main() {
  test(
    'rewound held rename keeps a session-owned orphan until it finishes',
    () async {
      final held = HeldRename();
      final h = await MutationHarness.create(
        seams: FileWriteSeams(rename: held.rename),
      );
      releaseMutationAfterTest(h, held);
      h.file('lib/a.dart', 'before\n');
      final unrelated = h.file('lib/unrelated.dart', 'before\n');
      await _captureHarness(h, []);
      await h.nextTurn();
      final pending = h.write('orphan', 'lib/a.dart', 'late\n', stepTurn: 1);
      await held.entered.future;
      await h.runtime.cancelTurn();
      await pending;
      await h.writer.rewind(0);
      final records = await mutationRecord(
        h.writer,
        'meta/orphanedMutations',
        (records) => _hasTarget(records, 'lib/a.dart'),
      );
      final orphan = _target(records, 'lib/a.dart');
      expect(orphan['session'], mutationNode(h.writer, 'meta')['session']);
      expect(orphan.containsKey('finishedSeq'), isFalse);
      expect(h.call('orphan'), isEmpty);
      expect(h.file('lib/a.dart').readAsStringSync(), 'before\n');
      unrelated.writeAsStringSync('first user edit\n');
      await h.nextTurn();
      final userFrame = await _captureHarness(h, [
        _delta('lib/unrelated.dart'),
      ]);
      _expectBy(
        userFrame,
        'lib/unrelated.dart',
        SensoriumChangeBy.user,
        userEdits: true,
      );

      final finished = mutationRecord(
        h.writer,
        'meta/orphanedMutations',
        (records) => _hasTarget(records, 'lib/a.dart', finished: true),
      );
      await h.drain(held);
      final finalRecord = _target(await finished, 'lib/a.dart');
      expect(finalRecord['finishedSeq'], isA<int>());
      expect(
        mutationNode(h.writer, 'meta/vcs')['seqHigh'],
        greaterThanOrEqualTo(finalRecord['finishedSeq'] as int),
      );
      expect(h.file('lib/a.dart').readAsStringSync(), 'late\n');
      unrelated.writeAsStringSync('second user edit\n');
      await h.nextTurn();
      final changedFrame = await _captureHarness(h, [
        _delta('lib/a.dart'),
        _delta('lib/unrelated.dart'),
      ]);
      _expectBy(
        changedFrame,
        'lib/a.dart',
        SensoriumChangeBy.unknown,
        userEdits: true,
      );
      _expectBy(
        changedFrame,
        'lib/unrelated.dart',
        SensoriumChangeBy.user,
        userEdits: true,
      );
      await h.nextTurn();
      final carriedFrame = await _captureHarness(h, []);
      expect(
        (carriedFrame.changes as SensoriumAvailable<SensoriumChanges>)
            .value
            .rows,
        isEmpty,
      );
      expect(carriedFrame.notices.contains(SensoriumNotice.userEdits), isFalse);
    },
  );

  test('finished orphan record survives a later rewind', () async {
    final held = HeldRename();
    final h = await MutationHarness.create(
      seams: FileWriteSeams(rename: held.rename),
    );
    releaseMutationAfterTest(h, held);
    h.file('lib/a.dart', 'before\n');
    final unrelated = h.file('lib/unrelated.txt', 'before\n');
    await _captureHarness(h, []);
    await h.nextTurn();
    final pending = h.write('durable', 'lib/a.dart', 'late\n', stepTurn: 1);
    await held.entered.future;
    await h.runtime.cancelTurn();
    await pending;
    await h.writer.rewind(0);
    unrelated.writeAsStringSync('first user edit\n');
    await h.nextTurn();
    final preFinish = await _captureHarness(h, [_delta('lib/unrelated.txt')]);
    _expectBy(
      preFinish,
      'lib/unrelated.txt',
      SensoriumChangeBy.user,
      userEdits: true,
    );
    final finished = mutationRecord(
      h.writer,
      'meta/orphanedMutations',
      (records) => _hasTarget(records, 'lib/a.dart', finished: true),
    );
    await h.drain(held);
    final record = _target(await finished, 'lib/a.dart');
    unrelated.writeAsStringSync('second user edit\n');
    await h.nextTurn();
    final applied = await _captureHarness(h, [
      _delta('lib/a.dart'),
      _delta('lib/unrelated.txt'),
    ]);
    _expectBy(
      applied,
      'lib/a.dart',
      SensoriumChangeBy.unknown,
      userEdits: true,
    );
    _expectBy(
      applied,
      'lib/unrelated.txt',
      SensoriumChangeBy.user,
      userEdits: true,
    );

    expect(
      _target(mutationNode(h.writer, 'meta/orphanedMutations'), 'lib/a.dart'),
      record,
    );
    expect(h.call('durable'), isEmpty);
    await h.nextTurn();
    final noChange = await _captureHarness(h, []);
    expect(
      (noChange.changes as SensoriumAvailable<SensoriumChanges>).value.rows,
      isEmpty,
    );
    await h.writer.rewind(1);
    unrelated.writeAsStringSync('first user edit\n');
    await h.nextTurn();
    final restored = await _captureHarness(h, [_delta('lib/a.dart')]);
    _expectBy(
      restored,
      'lib/a.dart',
      SensoriumChangeBy.unknown,
      userEdits: false,
    );
    final high = mutationNode(h.writer, 'meta/vcs')['seqHigh'];
    await h.nextTurn();
    await h.writer.rewind(1);
    expect(mutationNode(h.writer, 'meta/vcs')['seqHigh'], high);
  });

  test('65th finished record evicts oldest and raises the floor without evicting live work', () async {
    final held = HeldRenames();
    final h = await MutationHarness.create(
      seams: FileWriteSeams(rename: held.rename),
    );
    held.cleanupAfterTest(h);
    final unrelated = h.file('unrelated.txt', 'before\n');
    await _captureHarness(h, []);
    await h.nextTurn();
    final live = h.write(
      'still-live',
      'still-live.txt',
      'pending\n',
      stepTurn: 1,
    );
    await held.waitFor('still-live.txt');
    await h.runtime.cancelTurn();
    await live;
    await h.writer.rewind(0);
    await mutationRecord(
      h.writer,
      'meta/orphanedMutations',
      (records) => _hasTarget(records, 'still-live.txt'),
    );
    int? firstFinish;
    var lastFinish = 0;
    for (var i = 0; i < 65; i++) {
      await h.nextTurn();
      final path = 'finished-$i.txt';
      final pending = h.write('finished-$i', path, 'late\n', stepTurn: 1);
      final rename = await held.waitFor(path);
      await h.runtime.cancelTurn();
      await pending;
      await h.writer.rewind(0);
      final finished = mutationRecord(
        h.writer,
        'meta/orphanedMutations',
        (records) => _hasTarget(records, path, finished: true),
      );
      await h.drain(rename);
      final seq = _target(await finished, path)['finishedSeq'] as int;
      expect(seq, greaterThan(lastFinish));
      firstFinish ??= seq;
      lastFinish = seq;
    }
    final records = mutationNode(h.writer, 'meta/orphanedMutations');
    final finished = records.values.where(
      (record) => record is Map && record['finishedSeq'] is int,
    );
    expect(finished, hasLength(64));
    expect(_hasTarget(records, 'finished-0.txt'), isFalse);
    expect(
      _target(records, 'still-live.txt').containsKey('finishedSeq'),
      isFalse,
    );
    final counters = mutationNode(h.writer, 'meta/vcs');
    expect(counters['attributionFloor'], greaterThanOrEqualTo(firstFinish!));
    expect(counters['seqHigh'], greaterThanOrEqualTo(lastFinish));
    await h.nextTurn();
    await h.writer.rewind(0);
    expect(
      mutationNode(h.writer, 'meta/vcs')['attributionFloor'],
      counters['attributionFloor'],
    );
    unrelated.writeAsStringSync('user edit\n');
    await h.nextTurn();
    final overflowChanges = [
      _delta('finished-0.txt'),
      _delta('unrelated.txt'),
      for (var i = 1; i < 65; i++) _delta('finished-$i.txt'),
    ];
    final frame = await _captureHarness(h, overflowChanges);
    _expectBy(
      frame,
      'finished-0.txt',
      SensoriumChangeBy.unknown,
      userEdits: false,
    );
    _expectBy(
      frame,
      'unrelated.txt',
      SensoriumChangeBy.unknown,
      userEdits: false,
    );
  });

  test(
    'finish during collection keeps the record applying next turn',
    () async {
      final held = HeldRename();
      final h = await MutationHarness.create(
        seams: FileWriteSeams(rename: held.rename),
      );
      releaseMutationAfterTest(h, held);
      h.file('lib/a.dart', 'before\n');
      final unrelated = h.file('lib/unrelated.txt', 'before\n');
      await _captureHarness(h, []);
      await h.nextTurn();
      final pending = h.write(
        'capture-finish',
        'lib/a.dart',
        'late\n',
        stepTurn: 1,
      );
      await held.entered.future;
      await h.runtime.cancelTurn();
      await pending;
      await h.writer.rewind(0);
      await h.nextTurn();
      unrelated.writeAsStringSync('user edit\n');

      final collecting = Completer<void>();
      final finishCapture = Completer<void>();
      final observer = attribution.CallbackWorkspaceObserver((request) async {
        final captured = attribution.availableCollection(
          request,
          id: 'captured-before-finish',
          changes: [_delta('lib/unrelated.txt')],
          verification: {
            'lib/unrelated.txt': attribution.verifiedFile(unrelated),
          },
        );
        collecting.complete();
        await finishCapture.future;
        return captured;
      });
      final capture = attribution
          .captureWorkspace(
            attribution.workspacePerception(h, observer),
            h.writer,
          )
          .collect();
      await collecting.future;
      await h.drain(held);
      finishCapture.complete();
      final frame = await capture;
      attribution.composeWorkspaceFrame(frame);
      await attribution.admitWorkspaceFrame(h.writer, frame);
      _expectBy(
        frame,
        'lib/unrelated.txt',
        SensoriumChangeBy.user,
        userEdits: true,
      );

      await h.nextTurn();
      final next = await _captureHarness(h, [_delta('lib/a.dart')]);
      _expectBy(
        next,
        'lib/a.dart',
        SensoriumChangeBy.unknown,
        userEdits: false,
      );
    },
  );

  test(
    'build frozen before reconciliation keeps held rename unknown',
    () async {
      final held = HeldRename();
      final h = await MutationHarness.create(
        seams: FileWriteSeams(rename: held.rename),
      );
      releaseMutationAfterTest(h, held);
      h.file('lib/a.dart', 'before\n');
      final unrelated = h.file('lib/unrelated.txt', 'before\n');
      await _captureHarness(h, []);
      final entered = Completer<void>();
      final release = Completer<void>();
      final resumed = Completer<void>();
      final previous = h.runtime.jobs.afterReconcile;
      h.runtime.jobs.afterReconcile = () async {
        if (entered.isCompleted) {
          await previous();
          return;
        }
        entered.complete();
        await release.future;
        await previous();
        resumed.complete();
      };
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        if (entered.isCompleted) await resumed.future;
      });
      await h.nextTurn();
      final pending = h.write(
        'before-reconcile',
        'lib/a.dart',
        'late\n',
        stepTurn: 1,
      );
      await held.entered.future;
      await h.runtime.cancelTurn();
      await pending;
      await h.writer.rewind(0);
      await entered.future;
      expect(h.call('before-reconcile'), isEmpty);
      unrelated.writeAsStringSync('user edit\n');

      final collecting = Completer<void>();
      final releaseObservation = Completer<void>();
      final observer = attribution.CallbackWorkspaceObserver((request) async {
        final changes = [_delta('lib/a.dart'), _delta('lib/unrelated.txt')];
        final captured = attribution.availableCollection(
          request,
          id: 'frozen-before-reconciliation',
          changes: changes,
          verification: {
            'lib/a.dart': attribution.verifiedFile(h.file('lib/a.dart')),
            'lib/unrelated.txt': attribution.verifiedFile(unrelated),
          },
        );
        collecting.complete();
        await releaseObservation.future;
        return captured;
      });
      final capture = attribution
          .captureWorkspace(
            attribution.workspacePerception(h, observer),
            h.writer,
          )
          .collect();
      await collecting.future;
      release.complete();
      await resumed.future;
      await h.drain(held);
      releaseObservation.complete();
      final frame = await capture;
      attribution.composeWorkspaceFrame(frame);
      await attribution.admitWorkspaceFrame(h.writer, frame);
      _expectBy(
        frame,
        'lib/a.dart',
        SensoriumChangeBy.unknown,
        userEdits: true,
      );
      _expectBy(
        frame,
        'lib/unrelated.txt',
        SensoriumChangeBy.user,
        userEdits: true,
      );
    },
  );

  test(
    'surviving call preserved before rewind is finished when its run ends',
    () async {
      final held = await WriterHeldMutation.start(callSurvives: true);
      final fixture = _registryFor(held);
      await held.writer.rewind(0);
      final call = mutationNode(held.writer, held.run.callPath);
      expect(call['attempt'], held.run.runId);
      expect(call.containsKey('target'), isFalse);
      final records = mutationNode(held.writer, 'meta/orphanedMutations');
      expect(records, contains(held.run.runId));
      final preserved = _target(records, held.run.target);
      expect(preserved['session'], held.run.session);
      expect(preserved.containsKey('finishedSeq'), isFalse);
      final unrelated = File(p.join(held.workspace.path, 'unrelated.txt'))
        ..writeAsStringSync('before\n');
      await _capture(held.workspace.path, held.writer, fixture.mutations, []);
      await _finishHeld(held, fixture);

      final finished = _target(
        mutationNode(held.writer, 'meta/orphanedMutations'),
        held.run.target,
      );
      expect(finished['finishedSeq'], greaterThan(7));
      expect(
        mutationNode(held.writer, 'meta/vcs')['seqHigh'],
        finished['finishedSeq'],
      );
      expect(mutationNode(held.writer, held.run.callPath)['quiesced'], isTrue);
      expect(
        mutationNode(held.writer, held.run.callPath)['status'],
        'cancelled',
      );
      expect(held.writer.liveMutationTargets!(), isEmpty);
      unrelated.writeAsStringSync('user edit\n');
      await _nextTurn(held.writer);
      final frame = await _capture(
        held.workspace.path,
        held.writer,
        fixture.mutations,
        [_delta(held.run.target), _delta('unrelated.txt')],
      );
      _expectBy(
        frame,
        held.run.target,
        SensoriumChangeBy.unknown,
        userEdits: true,
      );
      _expectBy(
        frame,
        'unrelated.txt',
        SensoriumChangeBy.user,
        userEdits: true,
      );
    },
  );

  test(
    'preservation keeps rewind turn and invalid cuts append nothing',
    () async {
      final held = await WriterHeldMutation.start();
      final fixture = _registryFor(held);
      final before = held.journal.readAsStringSync();
      final originalTurn = held.writer.currentTurn;
      await expectLater(
        held.writer.rewind(originalTurn),
        throwsA(isA<SessionError>()),
      );
      expect(held.journal.readAsStringSync(), before);

      int? turnBeforeCut;
      held.io.onWrite = (bytes) async {
        final record = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
        if (record['op'] == Op.rewind.wire) {
          turnBeforeCut = held.writer.currentTurn;
        }
      };
      final cut = await held.writer.rewind(0);
      expect(cut.record.op, Op.rewind);
      expect(cut.record.value, 0);
      expect(cut.record.turn, originalTurn);
      expect(turnBeforeCut, originalTurn);
      expect(held.writer.currentTurn, 0);
      expect(
        mutationNode(held.writer, 'meta/orphanedMutations'),
        contains(held.run.runId),
      );
      expect(
        _target(
          mutationNode(held.writer, 'meta/orphanedMutations'),
          held.run.target,
        )['session'],
        held.run.session,
      );
      final appended = held.journal
          .readAsStringSync()
          .substring(before.length)
          .split('\n')
          .where((line) => line.isNotEmpty)
          .map((line) => jsonDecode(line) as Map<String, Object?>);
      expect(
        appended.every((record) => record['turn'] == originalTurn),
        isTrue,
      );
      final unrelated = File(p.join(held.workspace.path, 'unrelated.txt'))
        ..writeAsStringSync('before\n');
      await _capture(held.workspace.path, held.writer, fixture.mutations, []);
      await _finishHeld(held, fixture);
      unrelated.writeAsStringSync('user edit\n');
      await _nextTurn(held.writer);
      final frame = await _capture(
        held.workspace.path,
        held.writer,
        fixture.mutations,
        [_delta(held.run.target), _delta('unrelated.txt')],
      );
      _expectBy(
        frame,
        held.run.target,
        SensoriumChangeBy.unknown,
        userEdits: true,
      );
      _expectBy(
        frame,
        'unrelated.txt',
        SensoriumChangeBy.user,
        userEdits: true,
      );
    },
  );
}

Future<WorkspacePerceptionFrame> _capture(
  String root,
  SessionWriter writer,
  MutationRuns mutations,
  List<VcsDelta> changes,
) async {
  final observer = attribution.CallbackWorkspaceObserver((request) {
    final verification = <String, VcsVerification>{};
    for (final change in changes) {
      final file = File(p.joinAll([root, ...p.posix.split(change.path)]));
      if (file.existsSync()) {
        verification[change.path] = attribution.verifiedFile(file);
      }
    }
    return attribution.availableCollection(
      request,
      id: 'fixture-${request.turn}',
      changes: changes,
      verification: verification,
    );
  });
  final frame = await attribution
      .captureWorkspace(
        WorkspacePerception(
          root: root,
          observer: observer,
          mutations: mutations,
        ),
        writer,
      )
      .collect();
  attribution.composeWorkspaceFrame(frame);
  await attribution.admitWorkspaceFrame(writer, frame);
  return frame;
}

Future<WorkspacePerceptionFrame> _captureHarness(
  MutationHarness h,
  List<VcsDelta> changes,
) => _capture(h.root.path, h.writer, h.runtime.mutations, changes);

void _expectBy(
  WorkspacePerceptionFrame frame,
  String path,
  SensoriumChangeBy by, {
  required bool userEdits,
}) {
  final changes = frame.changes;
  expect(changes, isA<SensoriumAvailable<SensoriumChanges>>());
  final rows = (changes as SensoriumAvailable<SensoriumChanges>).value.rows;
  expect(rows.singleWhere((row) => row.path == path).by, by);
  expect(frame.notices.contains(SensoriumNotice.userEdits), userEdits);
  final text = attribution.composeWorkspaceFrame(frame).text;
  expect(text, contains(path));
  expect(text, contains('by: ${by.name}'));
  expect(text.contains('user_edits'), userEdits);
}

VcsDelta _delta(String path) =>
    VcsDelta(path: path, added: 1, removed: 0, binary: false);

typedef _LiveFixture = ({MutationRuns mutations, MutationRun run});

_LiveFixture _registryFor(WriterHeldMutation held) {
  final high = mutationNode(held.writer, 'meta/vcs')['seqHigh'] as int? ?? 0;
  final mutations = MutationRuns(
    sequence: MutationSequence(high),
    session: held.run.session,
  );
  final actual = held.writer.liveMutationTargets!().single;
  expect(actual, held.run);
  final run = mutations.reserve(
    callKey: callKey('writer-held'),
    attempt: actual.runId,
    callPath: actual.callPath,
  )!;
  expect(mutations.publish(run, actual.target), isTrue);
  return (mutations: mutations, run: run);
}

Future<void> _finishHeld(WriterHeldMutation held, _LiveFixture fixture) async {
  await held.land();
  await held.writer.finishMutation(
    held.run,
    sequence: fixture.mutations.sequence,
    retire: (read) {
      fixture.mutations.retire(fixture.run, currentCallOpen: false);
      held.retire(read);
    },
  );
}

Future<void> _nextTurn(SessionWriter writer) => writer.apply(
  JournalRecord(
    turn: writer.currentTurn + 1,
    path: 'body/markers/${writer.currentTurn + 1}',
    op: Op.set,
    value: true,
  ),
);
