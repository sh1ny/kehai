import 'dart:convert';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

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
      await h.nextTurn();
      final pending = h.write('orphan', 'lib/a.dart', 'late\n');
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
    },
  );

  test('finished orphan record survives a later rewind', () async {
    final held = HeldRename();
    final h = await MutationHarness.create(
      seams: FileWriteSeams(rename: held.rename),
    );
    releaseMutationAfterTest(h, held);
    h.file('lib/a.dart', 'before\n');
    await h.nextTurn();
    final pending = h.write('durable', 'lib/a.dart', 'late\n');
    await held.entered.future;
    await h.runtime.cancelTurn();
    await pending;
    await h.writer.rewind(0);
    final finished = mutationRecord(
      h.writer,
      'meta/orphanedMutations',
      (records) => _hasTarget(records, 'lib/a.dart', finished: true),
    );
    await h.drain(held);
    final record = _target(await finished, 'lib/a.dart');
    final high = mutationNode(h.writer, 'meta/vcs')['seqHigh'];
    await h.nextTurn();
    await h.writer.rewind(0);

    expect(
      _target(mutationNode(h.writer, 'meta/orphanedMutations'), 'lib/a.dart'),
      record,
    );
    expect(mutationNode(h.writer, 'meta/vcs')['seqHigh'], high);
    expect(h.call('durable'), isEmpty);
  });

  test('65th finished record evicts oldest and raises the floor without evicting live work', () async {
    final held = HeldRenames();
    final h = await MutationHarness.create(
      seams: FileWriteSeams(rename: held.rename),
    );
    held.cleanupAfterTest(h);
    await h.nextTurn();
    final live = h.write('still-live', 'still-live.txt', 'pending\n');
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
      final pending = h.write('finished-$i', path, 'late\n');
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
  });

  test(
    'surviving call preserved before rewind is finished when its run ends',
    () async {
      final held = await WriterHeldMutation.start(callSurvives: true);
      await held.writer.rewind(0);
      final call = mutationNode(held.writer, held.run.callPath);
      expect(call['attempt'], held.run.runId);
      expect(call.containsKey('target'), isFalse);
      final records = mutationNode(held.writer, 'meta/orphanedMutations');
      expect(records, contains(held.run.runId));
      final preserved = _target(records, held.run.target);
      expect(preserved['session'], held.run.session);
      expect(preserved.containsKey('finishedSeq'), isFalse);

      await held.finish();
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
    },
  );

  test(
    'preservation keeps rewind turn and invalid cuts append nothing',
    () async {
      final held = await WriterHeldMutation.start();
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
    },
  );
}
