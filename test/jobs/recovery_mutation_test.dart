import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/mutation_support.dart';
import '../support/session_support.dart';
import '../support/attribution_support.dart' as attribution;

import 'package:kehai/src/session/mutations.dart';
import 'package:kehai/src/tools/mutation_runs.dart';
import 'package:kehai/src/workspace/vcs_collector.dart';
import 'package:kehai/src/workspace/workspace_perception.dart';

Future<(Directory, SessionWriter)> _restart(
  Future<void> Function(Directory, SessionWriter) seed,
) async {
  final workspace = await tempDir();
  Directory(p.join(workspace.path, '.git')).createSync();
  final original = await createWriter(workspace);
  await seed(workspace, original);
  await original.close();
  final reopened = await SessionWriter.open(original.sessionDir);
  addTearDown(reopened.close);
  return (workspace, reopened);
}

Future<ToolRuntime> _recover(Directory workspace, SessionWriter writer) async {
  final runtime = await ToolRuntime.attach(
    writer,
    ResultStore(writer.sessionDir),
    workspace: workspace,
    gate: const AllowAllStage(),
  );
  addTearDown(runtime.close);
  return runtime;
}

void main() {
  for (final tool in ['write', 'edit']) {
    test(
      'resume quiesces a terminal cancelled $tool at the resume turn',
      () async {
        final (workspace, writer) = await _restart((workspace, writer) async {
          final lib = Directory(p.join(workspace.path, 'lib'))..createSync();
          final original = File(p.join(lib.path, 'a.dart'))
            ..writeAsStringSync('before crash\n');
          final other = File(p.join(lib.path, 'b.dart'))
            ..writeAsStringSync('unrelated\n');
          final unrelated = File(p.join(workspace.path, 'user.txt'))
            ..writeAsStringSync('before user edit\n');
          Link(p.join(workspace.path, 'alias.dart')).createSync(other.path);
          await _capture(workspace, writer, _mutations(writer), []);
          original.writeAsStringSync('landed before crash\n');
          unrelated.writeAsStringSync('user edit\n');
          expect(original.readAsStringSync(), 'landed before crash\n');
          final arguments = {
            'path': 'alias.dart',
            'content': 'landed before crash\n',
          };
          final argumentsJson = jsonEncode(arguments);
          await writer.apply(
            JournalRecord(
              turn: 0,
              path: mutationStepPath(0),
              op: Op.merge,
              value: {
                'output': [
                  {
                    'type': 'call',
                    'call': callKey('interrupted'),
                    'callId': 'interrupted',
                    'name': tool,
                    'arguments': argumentsJson,
                  },
                ],
              },
            ),
          );
          await writer.apply(
            JournalRecord(
              turn: 0,
              path: 'body/calls/${callKey('interrupted')}',
              op: Op.set,
              value: {
                'tool': tool,
                'callId': 'interrupted',
                'attempt': 'original-attempt',
                'input': {
                  'path': 'alias.dart',
                  'content': 'landed before crash\n',
                },
                'target': 'lib/a.dart',
                'status': 'cancelled',
                'reason': 'user',
              },
            ),
          );
          await writer.apply(
            JournalRecord(
              turn: 1,
              path: 'body/markers/resume',
              op: Op.set,
              value: true,
            ),
          );
        });
        final runtime = await _recover(workspace, writer);
        expect(
          runtime.resumed.calls,
          0,
          reason: 'terminal quiescence bookkeeping is not an interrupted call',
        );
        final call = mutationNode(
          writer,
          'body/calls/${callKey('interrupted')}',
        );
        expect(call['quiesced'], isTrue);
        expect(call['target'], 'lib/a.dart');
        expect(call['attempt'], 'original-attempt');
        expect(call['status'], 'cancelled');
        expect(call.containsKey('effect'), isFalse);
        expect(writer.currentTurn, 1);
        expect(
          File(p.join(workspace.path, 'lib', 'b.dart')).readAsStringSync(),
          'unrelated\n',
        );
        final frame = await _capture(workspace, writer, runtime.mutations, [
          _delta('lib/a.dart'),
          _delta('user.txt'),
        ]);
        _expectBy(
          frame,
          'lib/a.dart',
          SensoriumChangeBy.unknown,
          userEdits: true,
        );
        _expectBy(frame, 'user.txt', SensoriumChangeBy.user, userEdits: true);
      },
    );
  }

  test('recovery finishes own orphan records with a fresh seq and leaves foreign records unfinished', () async {
    final (workspace, writer) = await _restart((workspace, writer) async {
      final session = mutationNode(writer, 'meta')['session'];
      final own = File(p.join(workspace.path, 'own.txt'))
        ..writeAsStringSync('own before\n');
      final foreign = File(p.join(workspace.path, 'foreign.txt'))
        ..writeAsStringSync('foreign before\n');
      final unrelated = File(p.join(workspace.path, 'user.txt'))
        ..writeAsStringSync('user before\n');
      await writer.apply(
        JournalRecord(
          turn: 0,
          path: 'meta/vcs',
          op: Op.set,
          value: {'seqHigh': 10, 'attributionFloor': 5},
        ),
      );
      await _capture(workspace, writer, _mutations(writer), []);
      await _nextTurn(writer);
      own.writeAsStringSync('own changed\n');
      foreign.writeAsStringSync('foreign changed\n');
      unrelated.writeAsStringSync('user changed\n');
      await writer.apply(
        JournalRecord(
          turn: writer.currentTurn,
          path: 'meta/orphanedMutations',
          op: Op.set,
          value: {
            'own': {'target': 'own.txt', 'session': session},
            'done': {
              'target': 'done.txt',
              'session': session,
              'finishedSeq': 8,
            },
            'foreign': {
              'target': 'foreign.txt',
              'session': 'another-session',
              'foreign': true,
            },
          },
        ),
      );
    });
    final runtime = await _recover(workspace, writer);
    final records = mutationNode(writer, 'meta/orphanedMutations');
    final own = records['own'] as Map<String, Object?>;
    final finished = own['finishedSeq'];
    expect(finished, isA<int>());
    expect(finished as int, greaterThan(10));
    expect((records['done'] as Map<String, Object?>)['finishedSeq'], 8);
    expect(
      (records['foreign'] as Map<String, Object?>).containsKey('finishedSeq'),
      isFalse,
    );
    final counters = mutationNode(writer, 'meta/vcs');
    expect(counters['seqHigh'], greaterThanOrEqualTo(finished));
    expect(counters['attributionFloor'], 5);
    final frame = await _capture(workspace, writer, runtime.mutations, [
      _delta('own.txt'),
      _delta('foreign.txt'),
      _delta('user.txt'),
    ]);
    _expectBy(frame, 'own.txt', SensoriumChangeBy.unknown, userEdits: true);
    _expectBy(frame, 'foreign.txt', SensoriumChangeBy.unknown, userEdits: true);
    _expectBy(frame, 'user.txt', SensoriumChangeBy.user, userEdits: true);
  });

  test('legacy session without mutation metadata gains no VCS keys or journal bytes on recovery', () async {
    final (workspace, writer) = await _restart((_, _) async {});
    final before = journalOf(writer.sessionDir).readAsBytesSync();
    await _recover(workspace, writer);
    expect(
      journalOf(writer.sessionDir).readAsBytesSync(),
      orderedEquals(before),
    );
    expect(writer.tree.contains(SessionPath.parse('meta/vcs')), isFalse);
    expect(
      writer.tree.contains(SessionPath.parse('meta/orphanedMutations')),
      isFalse,
    );
  });

  test(
    'resume retains the pre-cut target after engine death and a late rename',
    () async {
      final held = await WriterHeldMutation.start(
        beforeMutation: (workspace, writer) async {
          await _capture(workspace, writer, _mutations(writer), []);
        },
      );
      final unrelated = File(p.join(held.workspace.path, 'user.txt'))
        ..writeAsStringSync('before user edit\n');
      await held.writer.rewind(0);
      expect(
        mutationNode(held.writer, 'meta/orphanedMutations')[held.run.runId],
        isA<Map<String, Object?>>().having(
          (record) => record['target'],
          'target',
          held.run.target,
        ),
      );
      await held.writer.close();
      await held.land();
      unrelated.writeAsStringSync('user edit while engine is down\n');
      expect(
        File(p.join(held.workspace.path, 'lib', 'a.dart')).readAsStringSync(),
        'after\n',
      );

      final reopened = await SessionWriter.open(held.writer.sessionDir);
      addTearDown(reopened.close);
      expect(mutationNode(reopened, held.run.callPath), isEmpty);
      final runtime = await _recover(held.workspace, reopened);
      final finished = mutationNode(
        reopened,
        'meta/orphanedMutations',
      )[held.run.runId];
      expect(
        finished,
        isA<Map<String, Object?>>()
            .having((record) => record['session'], 'session', held.run.session)
            .having(
              (record) => record['finishedSeq'],
              'finishedSeq',
              greaterThan(7),
            ),
      );
      await _nextTurn(reopened);
      final frame = await _capture(
        held.workspace,
        reopened,
        runtime.mutations,
        [_delta(held.run.target), _delta('user.txt')],
      );
      _expectBy(
        frame,
        held.run.target,
        SensoriumChangeBy.unknown,
        userEdits: true,
      );
      _expectBy(frame, 'user.txt', SensoriumChangeBy.user, userEdits: true);
    },
  );

  test(
    'resume keeps call and orphan when the rewind append never commits',
    () async {
      final held = await WriterHeldMutation.start();
      final unrelated = File(p.join(held.workspace.path, 'user.txt'))
        ..writeAsStringSync('before user edit\n');
      final mutations = _mutationsForHeld(held);
      await _capture(
        held.workspace,
        held.writer,
        mutations,
        [],
        source: SensoriumSource(turn: 0, time: DateTime.utc(2026, 11, 12)),
      );
      held.io.onWrite = (bytes) async {
        final record = jsonDecode(utf8.decode(bytes)) as Map<String, Object?>;
        if (record['op'] == Op.rewind.wire) {
          throw const FileSystemException(
            'simulated stop before rewind append',
          );
        }
      };
      await expectLater(held.writer.rewind(0), throwsA(isA<StorageError>()));
      expect(held.writer.state, WriterState.broken);
      await held.writer.close();
      unrelated.writeAsStringSync('user edit while engine is down\n');
      await held.land();

      final reopened = await SessionWriter.open(held.writer.sessionDir);
      addTearDown(reopened.close);
      expect(
        mutationNode(reopened, held.run.callPath)['attempt'],
        held.run.runId,
      );
      expect(
        mutationNode(reopened, 'meta/orphanedMutations')[held.run.runId],
        isA<Map<String, Object?>>().having(
          (record) => record['target'],
          'target',
          held.run.target,
        ),
      );
      final runtime = await _recover(held.workspace, reopened);
      final finished = mutationNode(
        reopened,
        'meta/orphanedMutations',
      )[held.run.runId];
      expect(
        finished,
        isA<Map<String, Object?>>().having(
          (record) => record['finishedSeq'],
          'finishedSeq',
          greaterThan(7),
        ),
      );
      expect(mutationNode(reopened, held.run.callPath)['quiesced'], isTrue);
      await _nextTurn(reopened);
      final frame = await _capture(
        held.workspace,
        reopened,
        runtime.mutations,
        [_delta(held.run.target), _delta('user.txt')],
      );
      _expectBy(
        frame,
        held.run.target,
        SensoriumChangeBy.unknown,
        userEdits: true,
      );
      _expectBy(frame, 'user.txt', SensoriumChangeBy.user, userEdits: true);
    },
  );
}

var _captureOrdinal = 0;

MutationRuns _mutations(SessionWriter writer) {
  final high = mutationNode(writer, 'meta/vcs')['seqHigh'] as int? ?? 0;
  final session = mutationNode(writer, 'meta')['session']! as String;
  return MutationRuns(sequence: MutationSequence(high), session: session);
}

MutationRuns _mutationsForHeld(WriterHeldMutation held) {
  final mutations = _mutations(held.writer);
  for (final target in held.writer.liveMutationTargets!()) {
    final run = mutations.reserve(
      callKey: callKey('writer-held'),
      attempt: target.runId,
      callPath: target.callPath,
    )!;
    expect(mutations.publish(run, target.target), isTrue);
  }
  return mutations;
}

Future<WorkspacePerceptionFrame> _capture(
  Directory workspace,
  SessionWriter writer,
  MutationRuns mutations,
  List<VcsDelta> changes, {
  SensoriumSource? source,
}) async {
  final observer = attribution.CallbackWorkspaceObserver((request) {
    final verification = <String, VcsVerification>{};
    for (final change in changes) {
      final file = File(
        p.joinAll([workspace.path, ...p.posix.split(change.path)]),
      );
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
          root: workspace.path,
          observer: observer,
          mutations: mutations,
        ),
        writer,
        source: source,
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
