import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/session_support.dart';

Map<String, Object?>? node(SessionTree tree, String id) =>
    tree.get(SessionPath.parse('meta/requests/$id')) as Map<String, Object?>?;

int linesMentioning(Directory dir, String text) =>
    journalOf(dir)
        .readAsLinesSync()
        .where((line) => line.contains(text))
        .length;

Future<Object?> outcomeOf(Future<Object?> call) =>
    call.then<Object?>((v) => v, onError: (Object e) => e);

void main() {
  late Directory root;
  setUp(() async => root = await tempDir());

  group('request admission', () {
    test('duplicate after rewind returns recorded outcome', () async {
      final writer = await createWriter(root);
      await writer.apply(rec(1, 'body/a', Op.set, 1));
      await writer.apply(rec(2, 'body/b', Op.set, 2));
      final first = await writer.admit('q1', 'fp-1');
      expect(first.isNew, isTrue);
      await writer.complete('q1', {'answer': 42});
      await writer.rewind(1);
      final length = journalOf(writer.sessionDir).lengthSync();

      final again = await writer.admit('q1', 'fp-1');

      expect(again.isNew, isFalse);
      expect(again.state, 'completed');
      expect(again.node!['outcome'], {'answer': 42});
      expect(journalOf(writer.sessionDir).lengthSync(), length);
      expect(writer.currentTurn, 1);
    });

    test('simultaneous duplicate admissions admit exactly once', () async {
      final writer = await createWriter(root);
      final results = await Future.wait([
        writer.admit('q2', 'same'),
        writer.admit('q2', 'same'),
      ]);

      expect(results.where((a) => a.isNew), hasLength(1));
      final other = results.singleWhere((a) => !a.isNew);
      expect(other.state, 'admitted');
      expect(linesMentioning(writer.sessionDir, 'meta/requests/q2'), 1);
      expect(node(writer.tree, 'q2')!['fingerprint'], 'same');
    });

    test('request id collision is rejected including concurrently', () async {
      final writer = await createWriter(root);
      await writer.admit('q3', 'f1');
      final length = journalOf(writer.sessionDir).lengthSync();
      await expectLater(
        writer.admit('q3', 'f2'),
        throwsA(
          isA<RequestCollision>()
              .having((e) => e.id, 'id', 'q3')
              .having((e) => e.message, 'message', contains('q3'))
              .having((e) => e.reason, 'reason', 'request id collision'),
        ),
      );
      expect(journalOf(writer.sessionDir).lengthSync(), length);

      final results = await Future.wait([
        outcomeOf(writer.admit('q4', 'a')),
        outcomeOf(writer.admit('q4', 'b')),
      ]);
      expect(results[0], isA<Admission>());
      expect(results[1], isA<RequestCollision>());
      expect(linesMentioning(writer.sessionDir, 'meta/requests/q4'), 1);
      expect(node(writer.tree, 'q4')!['fingerprint'], 'a');
    });

    test('invalid ids and outcomes are rejected', () async {
      final writer = await createWriter(root);
      await expectLater(
        writer.admit('a/b', 'f'),
        throwsA(
          isA<SessionError>().having((e) => e.reason, 'r', 'invalid path'),
        ),
      );
      await expectLater(
        writer.complete('nope', 1),
        throwsA(isA<SessionError>()),
      );
      await writer.admit('q5', 'f');
      await writer.complete('q5', 'done');
      await expectLater(writer.complete('q5', 2), throwsA(isA<SessionError>()));
      await writer.admit('q6', 'f');
      await writer.fail('q6', reason: 'boom', outcome: {'code': 1});
      final failed = node(writer.tree, 'q6')!;
      expect(failed['state'], 'failed');
      expect(failed['reason'], 'boom');
      expect(failed['outcome'], {'code': 1});
      expect(node(writer.tree, 'q5')!['outcome'], 'done');
    });
  });

  group('request recovery', () {
    test('admitted request becomes interrupted on reopen', () async {
      final writer = await createWriter(root);
      await writer.admit('q7', 'fp-7');
      await writer.admit('q8', 'fp-8');
      await writer.complete('q8', 'ok');
      final dir = writer.sessionDir;
      await writer.close();
      expect(node(materialize(dir).tree, 'q7')!['state'], 'admitted');

      final reopened = await SessionWriter.open(dir);
      addTearDown(reopened.close);

      expect(reopened.interruptedRequests, 1);
      final q7 = node(reopened.tree, 'q7')!;
      expect(q7['state'], 'interrupted');
      expect(q7['reason'], 'effect-uncertain');
      expect(q7['fingerprint'], 'fp-7');
      expect(node(reopened.tree, 'q8')!['state'], 'completed');
      final duplicate = await reopened.admit('q7', 'fp-7');
      expect(duplicate.isNew, isFalse);
      expect(duplicate.state, 'interrupted');
      final length = journalOf(dir).lengthSync();
      await reopened.close();

      final third = await SessionWriter.open(dir);
      addTearDown(third.close);
      expect(third.interruptedRequests, 0);
      expect(journalOf(dir).lengthSync(), length);
    });

    test('recovery append failure fails the open', () async {
      final writer = await createWriter(root);
      await writer.admit('q9', 'fp-9');
      final dir = writer.sessionDir;
      await writer.close();
      final length = journalOf(dir).lengthSync();

      await expectLater(
        SessionWriter.open(
          dir,
          decorate: (inner) =>
              HookedIo(inner)
                ..onWrite = (_) async =>
                    throw const FileSystemException('full'),
        ),
        throwsA(isA<StorageError>()),
      );
      expect(journalOf(dir).lengthSync(), length);

      final retry = await SessionWriter.open(dir);
      addTearDown(retry.close);
      expect(retry.interruptedRequests, 1);
      expect(node(retry.tree, 'q9')!['state'], 'interrupted');
    });
  });
}
