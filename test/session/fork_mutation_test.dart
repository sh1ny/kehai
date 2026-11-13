import 'dart:async';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/mutation_support.dart';
import '../support/attribution_support.dart' as attribution;

import 'package:kehai/src/workspace/vcs_collector.dart';
import 'package:kehai/src/workspace/workspace_perception.dart';

Future<(SessionWriter, ToolRuntime)> _openChild(
  MutationHarness parent,
  ForkResult fork,
) async {
  final writer = await SessionWriter.open(fork.childDir);
  addTearDown(writer.close);
  final runtime = await ToolRuntime.attach(
    writer,
    ResultStore(writer.sessionDir),
    workspace: parent.root,
    gate: const AllowAllStage(),
  );
  addTearDown(runtime.close);
  return (writer, runtime);
}

Iterable<Map<Object?, Object?>> _foreign(SessionWriter writer) =>
    mutationNode(writer, 'meta/orphanedMutations').values
        .whereType<Map<Object?, Object?>>()
        .where((record) => record['foreign'] == true);

void main() {
  test(
    'finished parent orphan expires after the child admits its finish',
    () async {
      final held = HeldRename();
      final parent = await MutationHarness.create(
        seams: FileWriteSeams(rename: held.rename),
      );
      releaseMutationAfterTest(parent, held);
      final file = parent.file('lib/a.dart', 'before\n');
      await _capture(parent, parent.writer, parent.runtime, []);
      await parent.nextTurn();
      final pending = parent.write(
        'finished-parent',
        'lib/a.dart',
        'late\n',
        stepTurn: 1,
      );
      await held.entered.future;
      await parent.runtime.cancelTurn();
      await pending;
      await parent.writer.rewind(0);
      final finished = mutationRecord(
        parent.writer,
        'meta/orphanedMutations',
        (records) => records.values.any(
          (record) =>
              record is Map &&
              record['target'] == 'lib/a.dart' &&
              record['finishedSeq'] is int,
        ),
      );
      await parent.drain(held);
      await finished;
      final fork = await parent.writer.fork(parent.writer.currentTurn);
      final (child, childRuntime) = await _openChild(parent, fork);
      final first = await _capture(parent, child, childRuntime, [
        _delta('lib/a.dart'),
      ]);
      _expectBy(
        first,
        'lib/a.dart',
        SensoriumChangeBy.unknown,
        userEdits: false,
      );
      file.writeAsStringSync('user after child baseline\n');
      await _nextTurn(child);
      final next = await _capture(parent, child, childRuntime, [
        _delta('lib/a.dart'),
      ]);
      _expectBy(next, 'lib/a.dart', SensoriumChangeBy.user, userEdits: true);
    },
  );

  test(
    'child recovery leaves the parent held rename foreign and unfinished',
    () async {
      final held = HeldRename();
      final parent = await MutationHarness.create(
        seams: FileWriteSeams(rename: held.rename),
      );
      releaseMutationAfterTest(parent, held);
      parent.file('lib/a.dart', 'before\n');
      final unrelated = parent.file('lib/unrelated.txt', 'before\n');
      await _capture(parent, parent.writer, parent.runtime, []);
      await parent.nextTurn();
      final pending = parent.write(
        'parent-open',
        'lib/a.dart',
        'late\n',
        stepTurn: 1,
      );
      await held.entered.future;
      final fork = await parent.writer.fork(parent.writer.currentTurn);
      final (child, childRuntime) = await _openChild(parent, fork);

      expect(
        _foreign(child).map((record) => record['target']),
        contains('lib/a.dart'),
      );
      final record = _foreign(child)
          .singleWhere((record) => record['target'] == 'lib/a.dart');
      expect(record['session'], mutationNode(parent.writer, 'meta')['session']);
      expect(record.containsKey('finishedSeq'), isFalse);
      expect(parent.call('parent-open')['quiesced'], isNot(true));
      await _capture(parent, child, childRuntime, []);
      expect(parent.file('lib/a.dart').readAsStringSync(), 'before\n');
      await parent.drain(held);
      await pending;
      unrelated.writeAsStringSync('user edit\n');
      await _nextTurn(child);
      final frame = await _capture(parent, child, childRuntime, [
        _delta('lib/a.dart'),
        _delta('lib/unrelated.txt'),
      ]);
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
      expect(
        _foreign(child)
            .singleWhere((record) => record['target'] == 'lib/a.dart'),
        record,
      );
    },
  );

  test(
    'forking an earlier turn still copies currently open parent targets',
    () async {
      final held = HeldRename();
      final parent = await MutationHarness.create(
        seams: FileWriteSeams(rename: held.rename),
      );
      releaseMutationAfterTest(parent, held);
      await parent.nextTurn();
      final pending = parent.write('after-prefix', 'later.txt', 'late\n');
      await held.entered.future;
      final fork = await parent.writer.fork(0);
      final (child, _) = await _openChild(parent, fork);
      expect(
        mutationNode(child, 'body/calls/${callKey('after-prefix')}'),
        isEmpty,
      );
      expect(
        _foreign(child).any((record) => record['target'] == 'later.txt'),
        isTrue,
      );
      await parent.drain(held);
      await pending;
    },
  );

  test('parent write after the fork is outside child provenance', () async {
    final parent = await MutationHarness.create();
    parent.file('later.txt', 'before\n');
    parent.file('unrelated.txt', 'before\n');
    await _capture(parent, parent.writer, parent.runtime, []);
    final fork = await parent.writer.fork(0);
    final (child, childRuntime) = await _openChild(parent, fork);
    await _capture(parent, child, childRuntime, []);
    await parent.write(
      'after-fork',
      'later.txt',
      'parent bytes\n',
      stepTurn: 0,
    );
    expect(parent.call('after-fork')['target'], 'later.txt');
    expect(mutationNode(child, 'body/calls/${callKey('after-fork')}'), isEmpty);
    expect(
      _foreign(child).where((record) => record['target'] == 'later.txt'),
      isEmpty,
    );
    expect(parent.file('later.txt').readAsStringSync(), 'parent bytes\n');
    await _nextTurn(child);
    final frame = await _capture(parent, child, childRuntime, [
      _delta('later.txt'),
    ]);
    _expectBy(frame, 'later.txt', SensoriumChangeBy.user, userEdits: true);
  });

  test('more than 16 foreign records set the overflow marker', () async {
    final held = HeldRename();
    final parent = await MutationHarness.create(
      seams: FileWriteSeams(rename: held.rename),
    );
    releaseMutationAfterTest(parent, held);
    final unrelated = parent.file('unrelated.txt', 'before\n');
    await parent.writer.apply(
      JournalRecord(
        turn: parent.writer.currentTurn,
        path: 'meta/orphanedMutations',
        op: Op.set,
        value: {
          for (var i = 0; i < 16; i++)
            'inherited-$i': {
              'target': 'inherited-$i.txt',
              'session': 'ancestor',
              'foreign': true,
            },
        },
      ),
    );
    await parent.nextTurn();
    final pending = parent.write(
      'seventeenth',
      'own-open.txt',
      'late\n',
      stepTurn: 1,
    );
    await held.entered.future;
    final fork = await parent.writer.fork(0);
    final (child, childRuntime) = await _openChild(parent, fork);
    expect(_foreign(child), hasLength(16));
    expect(mutationNode(child, 'meta/vcs')['foreignOverflow'], isTrue);
    expect(
      _foreign(child).every((record) => !record.containsKey('finishedSeq')),
      isTrue,
    );
    await _capture(parent, child, childRuntime, []);
    await parent.drain(held);
    await pending;
    unrelated.writeAsStringSync('user edit\n');
    await _nextTurn(child);
    final frame = await _capture(parent, child, childRuntime, [
      _delta('own-open.txt'),
      _delta('unrelated.txt'),
    ]);
    _expectBy(
      frame,
      'own-open.txt',
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
    'fork before post-rewind reconciliation retains the live target as foreign',
    () async {
      final held = HeldRename();
      final parent = await MutationHarness.create(
        seams: FileWriteSeams(rename: held.rename),
      );
      parent.file('lib/a.dart', 'before\n');
      final unrelated = parent.file('lib/unrelated.txt', 'before\n');
      await _capture(parent, parent.writer, parent.runtime, []);
      releaseMutationAfterTest(parent, held);
      final entered = Completer<void>();
      final release = Completer<void>();
      final resumed = Completer<void>();
      final previous = parent.runtime.jobs.afterReconcile;
      parent.runtime.jobs.afterReconcile = () async {
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
      await parent.nextTurn();
      final pending = parent.write('gap', 'lib/a.dart', 'late\n', stepTurn: 1);
      await held.entered.future;
      await parent.runtime.cancelTurn();
      await pending;
      await parent.writer.rewind(0);
      await entered.future;
      expect(parent.call('gap'), isEmpty);
      final preserved = mutationNode(parent.writer, 'meta/orphanedMutations');
      expect(
        preserved.values,
        contains(
          isA<Map<String, Object?>>().having(
            (record) => record['target'],
            'target',
            'lib/a.dart',
          ),
        ),
      );
      final fork = await parent.writer.fork(0);
      final (child, childRuntime) = await _openChild(parent, fork);
      expect(
        _foreign(child).any((record) => record['target'] == 'lib/a.dart'),
        isTrue,
      );
      await _capture(parent, child, childRuntime, []);
      release.complete();
      await resumed.future;
      await parent.drain(held);
      unrelated.writeAsStringSync('user edit\n');
      await _nextTurn(child);
      final frame = await _capture(parent, child, childRuntime, [
        _delta('lib/a.dart'),
        _delta('lib/unrelated.txt'),
      ]);
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
}

var _captureOrdinal = 0;

Future<WorkspacePerceptionFrame> _capture(
  MutationHarness parent,
  SessionWriter writer,
  ToolRuntime runtime,
  List<VcsDelta> changes,
) async {
  final observer = attribution.CallbackWorkspaceObserver((request) {
    final verification = <String, VcsVerification>{};
    for (final change in changes) {
      final file = parent.file(change.path);
      if (file.existsSync())
        verification[change.path] = attribution.verifiedFile(file);
    }
    return attribution.availableCollection(
      request,
      id: 'fixture-${request.turn}-${_captureOrdinal++}',
      changes: changes,
      verification: verification,
    );
  });
  final frame = await attribution
      .captureWorkspace(
        WorkspacePerception(
          root: parent.root.path,
          observer: observer,
          mutations: runtime.mutations,
        ),
        writer,
      )
      .collect();
  attribution.composeWorkspaceFrame(frame);
  await attribution.admitWorkspaceFrame(writer, frame);
  return frame;
}

Future<void> _nextTurn(SessionWriter writer) => writer.apply(
  JournalRecord(
    turn: writer.currentTurn + 1,
    path: 'body/markers/${writer.currentTurn + 1}',
    op: Op.set,
    value: true,
  ),
);

VcsDelta _delta(String path) =>
    VcsDelta(path: path, added: 1, removed: 0, binary: false);

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
