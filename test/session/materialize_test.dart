import 'dart:async';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/session_support.dart';

void main() {
  late Directory root;
  setUp(() async => root = await tempDir());

  group('read-only materialization', () {
    test('read-only materialization alongside a writer is observed', () async {
      final writer = await createWriter(root);
      await writer.apply(rec(1, 'body/a', Op.set, {'x': 1}));

      final read = materialize(writer.sessionDir);
      expect(read.observed, isTrue);
      expect(read.trailingBytes, 0);
      expect(read.recordCount, 2);
      expect(read.tree.canonical(), writer.tree.canonical());

      await writer.close();
      expect(materialize(writer.sessionDir).observed, isFalse);
    });

    test('record visible before a failed flush is not acknowledged', () async {
      final (writer, io) = await createHooked(root);
      final updates = <CommittedUpdate>[];
      final sub = writer.subscribe().listen(updates.add);
      addTearDown(sub.cancel);
      final path = SessionPath.parse('body/x');
      final reached = Completer<void>();
      final release = Completer<void>();
      io.beforeFlush = () async {
        reached.complete();
        await release.future;
        throw const FileSystemException('flush failed');
      };

      final pending = expectLater(
        writer.apply(rec(1, 'body/x', Op.set, 'v')),
        throwsA(isA<StorageError>()),
      );
      await reached.future;
      final read = materialize(writer.sessionDir);
      expect(read.observed, isTrue);
      expect(read.tree.get(path), 'v');

      release.complete();
      await pending;
      await pumpEventQueue();
      expect(updates, isEmpty);
      // The writer's tree is the acknowledged state a fork would take.
      expect(writer.tree.contains(path), isFalse);
      expect(writer.state, WriterState.broken);
    });
  });
}
