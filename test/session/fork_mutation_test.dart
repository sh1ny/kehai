import 'dart:async';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/mutation_support.dart';

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
    'child recovery leaves the parent held rename foreign and unfinished',
    () async {
      final held = HeldRename();
      final parent = await MutationHarness.create(
        seams: FileWriteSeams(rename: held.rename),
      );
      releaseMutationAfterTest(parent, held);
      parent.file('lib/a.dart', 'before\n');
      await parent.nextTurn();
      final pending = parent.write('parent-open', 'lib/a.dart', 'late\n');
      await held.entered.future;
      final fork = await parent.writer.fork(parent.writer.currentTurn);
      final (child, _) = await _openChild(parent, fork);

      expect(
        _foreign(child).map((record) => record['target']),
        contains('lib/a.dart'),
      );
      final record = _foreign(child)
          .singleWhere((record) => record['target'] == 'lib/a.dart');
      expect(record['session'], mutationNode(parent.writer, 'meta')['session']);
      expect(record.containsKey('finishedSeq'), isFalse);
      expect(parent.call('parent-open')['quiesced'], isNot(true));
      expect(parent.file('lib/a.dart').readAsStringSync(), 'before\n');
      await parent.drain(held);
      await pending;
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
    final fork = await parent.writer.fork(0);
    final (child, _) = await _openChild(parent, fork);
    await parent.write('after-fork', 'later.txt', 'parent bytes\n');
    expect(parent.call('after-fork')['target'], 'later.txt');
    expect(mutationNode(child, 'body/calls/${callKey('after-fork')}'), isEmpty);
    expect(
      _foreign(child).where((record) => record['target'] == 'later.txt'),
      isEmpty,
    );
    expect(parent.file('later.txt').readAsStringSync(), 'parent bytes\n');
  });

  test('more than 16 foreign records set the overflow marker', () async {
    final held = HeldRename();
    final parent = await MutationHarness.create(
      seams: FileWriteSeams(rename: held.rename),
    );
    releaseMutationAfterTest(parent, held);
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
    final pending = parent.write('seventeenth', 'own-open.txt', 'late\n');
    await held.entered.future;
    final fork = await parent.writer.fork(0);
    final (child, _) = await _openChild(parent, fork);
    expect(_foreign(child), hasLength(16));
    expect(mutationNode(child, 'meta/vcs')['foreignOverflow'], isTrue);
    expect(
      _foreign(child).every((record) => !record.containsKey('finishedSeq')),
      isTrue,
    );
    await parent.drain(held);
    await pending;
  });

  test(
    'fork before post-rewind reconciliation retains the live target as foreign',
    () async {
      final held = HeldRename();
      final parent = await MutationHarness.create(
        seams: FileWriteSeams(rename: held.rename),
      );
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
      final pending = parent.write('gap', 'lib/a.dart', 'late\n');
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
      final (child, _) = await _openChild(parent, fork);
      expect(
        _foreign(child).any((record) => record['target'] == 'lib/a.dart'),
        isTrue,
      );
      release.complete();
      await resumed.future;
      await parent.drain(held);
    },
  );
}
