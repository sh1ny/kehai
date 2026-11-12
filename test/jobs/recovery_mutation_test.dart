import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/mutation_support.dart';
import '../support/session_support.dart';

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
            ..writeAsStringSync('landed before crash\n');
          final other = File(p.join(lib.path, 'b.dart'))
            ..writeAsStringSync('unrelated\n');
          Link(p.join(workspace.path, 'alias.dart')).createSync(other.path);
          expect(original.readAsStringSync(), 'landed before crash\n');
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
        await _recover(workspace, writer);
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
      },
    );
  }

  test('recovery finishes own orphan records with a fresh seq and leaves foreign records unfinished', () async {
    final (workspace, writer) = await _restart((_, writer) async {
      final session = mutationNode(writer, 'meta')['session'];
      await writer.apply(
        JournalRecord(
          turn: 0,
          path: 'meta/vcs',
          op: Op.set,
          value: {'seqHigh': 10, 'attributionFloor': 5},
        ),
      );
      await writer.apply(
        JournalRecord(
          turn: 0,
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
    await _recover(workspace, writer);
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
      final held = await WriterHeldMutation.start();
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
      expect(
        File(p.join(held.workspace.path, 'lib', 'a.dart')).readAsStringSync(),
        'after\n',
      );

      final reopened = await SessionWriter.open(held.writer.sessionDir);
      addTearDown(reopened.close);
      expect(mutationNode(reopened, held.run.callPath), isEmpty);
      await _recover(held.workspace, reopened);
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
    },
  );

  test(
    'resume keeps call and orphan when the rewind append never commits',
    () async {
      final held = await WriterHeldMutation.start();
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
      await _recover(held.workspace, reopened);
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
    },
  );
}
