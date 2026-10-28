import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/session_support.dart';

Object? at(SessionTree tree, String path) => tree.get(SessionPath.parse(path));

Stream<List<int>> _bytes(String text, {bool fail = false}) async* {
  yield utf8.encode(text);
  if (fail) throw StateError('producer broke');
}

Matcher _resultError(String message) =>
    isA<ResultError>().having((e) => e.message, 'message', message);

Future<ResultDescriptor> _store(
  SessionWriter w,
  String text, {
  bool fail = false,
}) async {
  final write = await ResultStore(w.sessionDir)
      .storeResult(_bytes(text, fail: fail));
  return switch (write) {
    ResultComplete(:final descriptor) => descriptor,
    ResultProducerFailed(:final descriptor) => descriptor,
    ResultStorageFailed() => throw StateError('storage failed'),
  };
}

void main() {
  late Directory root;
  setUp(() async => root = await tempDir());

  test('handle resolves through the tree', () async {
    final writer = await createWriter(root);
    await writer.apply(rec(1, 'body/t1/user', Op.set, 'one'));
    await writer.apply(rec(2, 'body/t2/user', Op.set, 'two'));
    final stored = await _store(writer, 'a\nb\nc\n');
    final update = await writer.recordResult(stored);
    expect(update!.record.turn, 2);
    expect(update.record.path, 'results/${stored.handle.substring(2)}');
    await writer.apply(rec(3, 'body/t3/user', Op.set, 'three'));
    await writer.apply(rec(4, 'body/t4/user', Op.set, 'four'));

    final resolved = resolveHandle(
      writer.tree,
      writer.sessionDir,
      stored.handle,
    );

    expect(resolved.descriptor, stored);
    expect(resolved.descriptor.bytes, 6);
    expect(resolved.descriptor.lines, 3);
    expect(
      resolved.file.path,
      p.join(writer.sessionDir.path, resultsDirName, stored.sha256),
    );
    final page = await readMore(
      resolved.file,
      resolved.descriptor,
      from: 2,
      lines: 1,
    );
    expect(page, contains('b'));
  });

  test(
    'identical bytes keep per-occurrence completion in both orders',
    () async {
      for (final failedFirst in [false, true]) {
        final dir = await root.createTemp('order_');
        final writer = await createWriter(dir);
        await writer.apply(rec(1, 'body/t1/user', Op.set, 'go'));
        final first = await _store(writer, 'abc', fail: failedFirst);
        final firstUpdate = await writer.recordResult(first);
        expect(firstUpdate, isNotNull);
        final nodePath = 'results/${first.handle.substring(2)}';
        final node = at(writer.tree, nodePath);
        final linesBefore = journalOf(writer.sessionDir).readAsLinesSync();

        final second = await _store(writer, 'abc', fail: !failedFirst);
        final secondUpdate = await writer.recordResult(second);

        expect(second, first);
        expect(secondUpdate, isNull);
        expect(journalOf(writer.sessionDir).readAsLinesSync(), linesBefore);
        expect(at(writer.tree, nodePath), node);
        await writer.apply(
          rec(1, 'body/t1/calls/c1/result', Op.set, {
            'handle': first.handle,
            'complete': !failedFirst,
          }),
        );
        await writer.apply(
          rec(1, 'body/t1/calls/c2/result', Op.set, {
            'handle': second.handle,
            'complete': failedFirst,
          }),
        );
        final c1 = 'body/t1/calls/c1/result';
        final c2 = 'body/t1/calls/c2/result';
        expect(at(writer.tree, '$c1/complete'), !failedFirst);
        expect(at(writer.tree, '$c2/complete'), failedFirst);
        expect(at(writer.tree, '$c1/handle'), at(writer.tree, '$c2/handle'));
      }
    },
  );

  test('unknown or broken handle fails explicitly', () async {
    final writer = await createWriter(root);
    await writer.apply(rec(1, 'body/t1/user', Op.set, 'one'));
    await writer.apply(rec(2, 'body/t2/user', Op.set, 'two'));
    final stored = await _store(writer, 'hello\n');
    await writer.recordResult(stored);

    expect(
      () => resolveHandle(writer.tree, writer.sessionDir, 'r/000000000000'),
      throwsA(_resultError('unknown handle r/000000000000')),
    );

    final file = File(
      p.join(writer.sessionDir.path, resultsDirName, stored.sha256),
    );
    final original = file.readAsBytesSync();
    file.writeAsBytesSync(utf8.encode('hel'));
    expect(
      () => resolveHandle(writer.tree, writer.sessionDir, stored.handle),
      throwsA(_resultError('result bytes missing for ${stored.handle}')),
    );
    file.deleteSync();
    expect(
      () => resolveHandle(writer.tree, writer.sessionDir, stored.handle),
      throwsA(_resultError('result bytes missing for ${stored.handle}')),
    );
    file.writeAsBytesSync(original);

    await writer.rewind(1);
    expect(
      () => resolveHandle(writer.tree, writer.sessionDir, stored.handle),
      throwsA(_resultError('unknown handle ${stored.handle}')),
    );
  });

  test('a different hash at the same handle is a collision', () async {
    final writer = await createWriter(root);
    final stored = await _store(writer, 'abc');
    await writer.recordResult(stored);
    final forged = ResultDescriptor(
      handle: stored.handle,
      sha256: '${stored.handle.substring(2)}${'0' * 52}',
      bytes: 3,
      lines: 1,
    );

    await expectLater(
      writer.recordResult(forged),
      throwsA(
        isA<SessionError>().having(
          (e) => e.reason,
          'reason',
          'handle collision',
        ),
      ),
    );
    expect(writer.state, WriterState.ready);
  });

  group('descriptor validation', () {
    const id = 'aaaaaaaaaaaa';
    final good = 'a' * 64;

    ResultDescriptor make({
      String? handle,
      String? sha256,
      int bytes = 3,
      int lines = 1,
    }) => ResultDescriptor(
      handle: handle ?? 'r/$id',
      sha256: sha256 ?? good,
      bytes: bytes,
      lines: lines,
    );

    test('recordResult rejects malformed descriptors', () async {
      final writer = await createWriter(root);
      final bad = <String, ResultDescriptor>{
        'traversal': make(sha256: '$id/../../journal.jsonl'),
        'uppercase': make(sha256: 'A' * 64, handle: 'r/${'A' * 12}'),
        'short': make(sha256: 'a' * 63),
        'long': make(sha256: 'a' * 65),
        'non-hex': make(sha256: '${'a' * 63}g'),
        'negative bytes': make(bytes: -1),
        'negative lines': make(lines: -1),
        'uppercase handle': make(handle: 'r/${'A' * 12}'),
      };
      for (final MapEntry(:key, :value) in bad.entries) {
        await expectLater(
          writer.recordResult(value),
          throwsA(isA<SessionError>()),
          reason: key,
        );
      }
      expect(writer.state, WriterState.ready);
      expect(at(writer.tree, 'results'), isNull);
      await expectLater(writer.recordResult(make()), completes);
    });

    test('fromJson rejects malformed descriptors with ResultError', () {
      for (final json in <Map<String, Object?>>[
        {...make().toJson(), 'sha256': '$id/../../journal.jsonl'},
        {...make().toJson(), 'sha256': 'a' * 63},
        {...make().toJson(), 'bytes': -1},
        {...make().toJson(), 'lines': -1},
        {...make().toJson(), 'handle': 'r/${'b' * 12}'},
        {...make().toJson(), 'handle': 'x/$id'},
        {...make().toJson()..remove('lines')},
      ]) {
        expect(
          () => ResultDescriptor.fromJson(json),
          throwsA(isA<ResultError>()),
        );
      }
      expect(ResultDescriptor.fromJson(make().toJson()), make());
    });

    test('resolveHandle never follows a traversal hash from the tree', () {
      final session = Directory(p.join(root.path, 'sess'))
        ..createSync(recursive: true);
      Directory(p.join(session.path, resultsDirName, id))
          .createSync(recursive: true);
      File(p.join(session.path, 'secret.bin')).writeAsBytesSync([1, 2, 3]);
      const traversal = '$id/../../secret.bin';
      final tree = SessionTree.fromJson({
        'results': {
          id: {'handle': 'r/$id', 'sha256': traversal, 'bytes': 3, 'lines': 1},
        },
      });

      expect(
        () => resolveHandle(tree, session, 'r/$id'),
        throwsA(_resultError('unknown handle r/$id')),
      );
    });

    test('resolveHandle rejects a descriptor stored under another id', () {
      final session = Directory(p.join(root.path, 'sess'))
        ..createSync(recursive: true);
      final tree = SessionTree.fromJson({
        'results': {'bbbbbbbbbbbb': make().toJson()},
      });
      expect(
        () => resolveHandle(tree, session, 'r/bbbbbbbbbbbb'),
        throwsA(_resultError('unknown handle r/bbbbbbbbbbbb')),
      );
    });
  });
}
