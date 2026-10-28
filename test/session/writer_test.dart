import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/session_support.dart';

Matcher sessionError(String reason, {String? op, String? path}) =>
    isA<SessionError>()
        .having((e) => e.reason, 'reason', reason)
        .having((e) => e.op, 'op', op)
        .having((e) => e.path, 'path', path);

void main() {
  late Directory root;
  setUp(() async => root = await tempDir());

  group('writer validation', () {
    test('invalid op use is rejected before append', () async {
      final writer = await createWriter(root);
      await writer.apply(rec(1, 'body/n', Op.set, 5));
      final journal = journalOf(writer.sessionDir);
      final length = journal.lengthSync();

      await expectLater(
        writer.applyWire(turn: 1, path: 'body/n', op: 'patch', value: {'a': 1}),
        throwsA(sessionError('unsupported op', op: 'patch', path: 'body/n')),
      );
      await expectLater(
        writer.apply(rec(1, 'body/missing', Op.del)),
        throwsA(
          sessionError('path not found', op: 'del', path: 'body/missing'),
        ),
      );
      await expectLater(
        writer.apply(rec(1, 'body/n', Op.merge, {'a': 1})),
        throwsA(sessionError('not a map', op: 'merge', path: 'body/n')),
      );
      expect(journal.lengthSync(), length);
      expect(writer.state, WriterState.ready);
    });
  });

  group('storage failure', () {
    test('storage failure is not published and breaks the writer', () async {
      for (final failFlush in [false, true]) {
        final dir = await tempDir();
        final (writer, io) = await createHooked(dir);
        final updates = <CommittedUpdate>[];
        final sub = writer.subscribe().listen(updates.add);
        addTearDown(sub.cancel);
        final before = writer.tree.canonical();
        final length = journalOf(writer.sessionDir).lengthSync();
        final record = rec(1, 'body/x', Op.set, 'value');

        if (failFlush) {
          io.beforeFlush = () async => throw const FileSystemException('full');
        } else {
          io.onWrite = (bytes) async {
            // A partial line reaches the disk before the failure.
            await io.inner.writeFrom(bytes.sublist(0, 10));
            throw const FileSystemException('full');
          };
        }

        await expectLater(writer.apply(record), throwsA(isA<StorageError>()));
        await pumpEventQueue();
        expect(updates, isEmpty);
        expect(writer.tree.canonical(), before);
        expect(writer.state, WriterState.broken);

        await expectLater(
          writer.apply(rec(1, 'body/y', Op.set, 1)),
          throwsA(sessionError('writer broken', op: 'set', path: 'body/y')),
        );

        await writer.close();
        final reopened = await SessionWriter.open(writer.sessionDir);
        addTearDown(reopened.close);
        if (failFlush) {
          // The fully written line persists although it was never acknowledged.
          expect(reopened.tree.get(SessionPath.parse('body/x')), 'value');
          expect(reopened.tornTail, isNull);
        } else {
          expect(reopened.tornTail!.bytes, 10);
          expect(reopened.tree.canonical(), before);
          expect(journalOf(writer.sessionDir).lengthSync(), length);
        }
        expect(reopened.state, WriterState.ready);
      }
    });
  });
}
