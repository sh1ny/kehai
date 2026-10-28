import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/session_support.dart';

/// Stores [text] as a result of [writer] and records its descriptor.
Future<ResultDescriptor> storeFor(SessionWriter writer, String text) async {
  final write = await ResultStore(writer.sessionDir)
      .storeResult(Stream.value(utf8.encode(text)));
  final descriptor = (write as ResultComplete).descriptor;
  await writer.recordResult(descriptor);
  return descriptor;
}

List<String> entriesOf(Directory dir) =>
    dir.listSync().map((e) => p.basename(e.path)).toList()..sort();

void main() {
  late Directory root;
  setUp(() async => root = await tempDir());

  test('fork survives parent deletion with readable handles', () async {
    final parent = await SessionWriter.create(root);
    await parent.apply(rec(1, 'body/a', Op.set, {'x': 1}));
    final r1 = await storeFor(parent, 'one\ntwo\n');
    await parent.apply(rec(2, 'body/b', Op.set, 'two'));
    final r2 = await storeFor(parent, 'alpha\nbeta\ngamma\n');
    await parent.apply(rec(3, 'body/late', Op.set, true));
    final r3 = await storeFor(parent, 'only in the parent\n');
    final journalBefore = journalOf(parent.sessionDir).readAsBytesSync();

    final forked = await parent.fork(2);

    expect(journalOf(parent.sessionDir).readAsBytesSync(), journalBefore);
    expect(forked.copiedResults, 2);
    expect(forked.childDir.existsSync(), isTrue);
    expect(p.basename(forked.childDir.path), forked.childId);

    final child = await SessionWriter.open(forked.childDir);
    await child.apply(rec(3, 'body/c', Op.set, 'mine'));
    await child.close();
    await parent.close();
    await parent.sessionDir.delete(recursive: true);

    final read = materialize(forked.childDir);
    expect(read.tree.get(SessionPath.parse('body/a')), {'x': 1});
    expect(read.tree.get(SessionPath.parse('body/b')), 'two');
    expect(read.tree.get(SessionPath.parse('body/c')), 'mine');
    expect(read.tree.contains(SessionPath.parse('body/late')), isFalse);
    for (final (descriptor, text) in [
      (r1, 'one\ntwo\n'),
      (r2, 'alpha\nbeta\ngamma\n'),
    ]) {
      final file = resolveHandle(
        read.tree,
        forked.childDir,
        descriptor.handle,
      ).file;
      expect(utf8.decode(file.readAsBytesSync()), text);
      expect(descriptor.bytes, text.length);
    }
    expect(
      () => resolveHandle(read.tree, forked.childDir, r3.handle),
      throwsA(
        isA<ResultError>().having(
          (e) => e.message,
          'message',
          'unknown handle ${r3.handle}',
        ),
      ),
    );
    expect(
      File(p.join(forked.childDir.path, resultsDirName, r3.sha256))
          .existsSync(),
      isFalse,
    );
    expect(entriesOf(root), [forked.childId]);
  });

  test('fork keeps current meta with replaced identity keys', () async {
    final parent = await createWriter(root);
    await parent.apply(rec(1, 'meta/settings', Op.set, {'model': 'a'}));
    await parent.admit('req1', 'fp');
    await parent.apply(rec(2, 'body/old', Op.set, 1));
    await parent.apply(rec(3, 'body/mid', Op.set, 2));
    await parent.apply(rec(4, 'meta/settings/model', Op.set, 'b'));
    await parent.apply(rec(4, 'body/new', Op.set, 3));
    final parentTree = parent.tree;

    final forked = await parent.fork(2);
    final child = materialize(forked.childDir).tree;

    expect(child.get(SessionPath.parse('meta/settings/model')), 'b');
    expect(child.contains(SessionPath.parse('body/new')), isFalse);
    expect(child.contains(SessionPath.parse('body/mid')), isFalse);
    expect(child.get(SessionPath.parse('body/old')), 1);
    final parentId = parentTree.get(SessionPath.parse('meta/session'));
    expect(child.get(SessionPath.parse('meta/session')), forked.childId);
    expect(forked.childId, isNot(parentId));
    expect(child.get(SessionPath.parse('meta/lineage')), {
      'parent': parentId,
      'parentTurn': 2,
    });
    expect(child.get(SessionPath.parse('meta/requests')), isEmpty);
    expect(child.get(SessionPath.parse('meta/format')), 1);
    expect(parent.tree.canonical(), parentTree.canonical());

    final reopened = await SessionWriter.open(forked.childDir);
    addTearDown(reopened.close);
    expect(reopened.currentTurn, 2);
    await reopened.apply(rec(3, 'body/x', Op.set, 1));
    await reopened.rewind(2);
    expect(reopened.currentTurn, 2);
    await expectLater(
      reopened.rewind(1),
      throwsA(
        isA<SessionError>().having(
          (e) => e.reason,
          'reason',
          'invalid rewind target',
        ),
      ),
    );
  });

  test('fork failure leaves no child directory', () async {
    final parent = await createWriter(root);
    await parent.apply(rec(1, 'body/a', Op.set, 1));
    final good = await storeFor(parent, 'present\n');
    final lost = await storeFor(parent, 'about to vanish\n');
    File(p.join(parent.sessionDir.path, resultsDirName, lost.sha256))
        .deleteSync();
    final journalBefore = journalOf(parent.sessionDir).readAsBytesSync();
    final treeBefore = parent.tree.canonical();

    await expectLater(
      parent.fork(1),
      throwsA(
        isA<SessionError>().having(
          (e) => e.message,
          'message',
          allOf(contains('fork failed'), contains(lost.handle)),
        ),
      ),
    );

    expect(entriesOf(root), [p.basename(parent.sessionDir.path)]);
    expect(journalOf(parent.sessionDir).readAsBytesSync(), journalBefore);
    expect(parent.tree.canonical(), treeBefore);
    expect(good.handle, isNot(lost.handle));
    expect(parent.state, WriterState.ready);
  });

  test('fork rejects a turn outside the allowed range', () async {
    final parent = await createWriter(root);
    await parent.apply(rec(1, 'body/a', Op.set, 1));

    for (final bad in [-1, 2, 99]) {
      await expectLater(
        parent.fork(bad),
        throwsA(
          isA<SessionError>()
              .having((e) => e.reason, 'reason', 'invalid fork turn')
              .having((e) => e.message, 'message', contains('from 0 to 1')),
        ),
      );
    }
    expect(entriesOf(root), [p.basename(parent.sessionDir.path)]);
    expect((await parent.fork(0)).childDir.existsSync(), isTrue);
  });
}
