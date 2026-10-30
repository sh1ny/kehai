import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/session_support.dart';

const _spool = '.spool-l1-stdout';

void main() {
  late Directory sessionDir;
  late ResultStore store;
  setUp(() async {
    sessionDir = await tempDir();
    store = ResultStore(sessionDir);
  });

  File file(String name) => File(p.join(sessionDir.path, resultsDirName, name));

  List<String> names() =>
      Directory(p.join(sessionDir.path, resultsDirName))
          .listSync()
          .map((e) => p.basename(e.path))
          .toList()
        ..sort();

  String digestOf(String text) => sha256.convert(utf8.encode(text)).toString();

  Future<ResultDescriptor> sealed(String text) async {
    final live = await store.begin(_spool);
    await live.write(utf8.encode(text));
    return live.seal();
  }

  group('ResultStore.begin', () {
    test('seal returns the descriptor without renaming', () async {
      final live = await store.begin(_spool);
      await live.write(utf8.encode('one\ntw'));
      await live.write(utf8.encode('o\nthree'));
      final descriptor = await live.seal();

      const text = 'one\ntwo\nthree';
      expect(descriptor.sha256, digestOf(text));
      expect(descriptor.handle, 'r/${digestOf(text).substring(0, 12)}');
      expect(descriptor.bytes, text.length);
      expect(descriptor.lines, 3);
      expect(names(), [_spool]);
      expect(file(_spool).readAsStringSync(), text);
      expect(await live.seal(), descriptor);
    });

    test('an empty spool seals to zero bytes and lines', () async {
      final descriptor = await (await store.begin(_spool)).seal();

      expect(descriptor.bytes, 0);
      expect(descriptor.lines, 0);
      expect(descriptor.sha256, digestOf(''));
    });

    test('snapshot stores the accepted prefix and leaves the spool', () async {
      final live = await store.begin(_spool);
      await live.write(utf8.encode('a\nb\n'));

      final first = await live.snapshot();
      await live.write(utf8.encode('c\n'));
      final second = await live.snapshot();

      final firstDescriptor = (first as ResultComplete).descriptor;
      expect(firstDescriptor.sha256, digestOf('a\nb\n'));
      expect(firstDescriptor.lines, 2);
      final secondDescriptor = (second as ResultComplete).descriptor;
      expect(secondDescriptor.sha256, digestOf('a\nb\nc\n'));
      expect(file(firstDescriptor.sha256).readAsStringSync(), 'a\nb\n');
      expect(file(_spool).readAsStringSync(), 'a\nb\nc\n');

      expect(await live.seal(), secondDescriptor);
    });

    // Feedback round 3: a flush that fails is a storage failure, so the bash
    // hand-off takes its cancelling path; and sealing still closes the spool.
    test('a snapshot whose flush fails is a storage failure', () async {
      final path = p.join(sessionDir.path, resultsDirName, _spool);
      final real = await store.begin(_spool);
      await real.seal();
      final failing = _FlushFails(
        await File(path).open(mode: FileMode.writeOnly),
      );
      final live = LiveResult(store, _spool, failing);
      await live.write(utf8.encode('abc'));

      final outcome = await live.snapshot();

      expect(outcome, isA<ResultStorageFailed>());
      final failed = outcome as ResultStorageFailed;
      expect(failed.bytesAccepted, 3);
      expect(failed.tempPath, path);
      expect(failed.error, isA<FileSystemException>());
      await failing.inner.close();
    });

    test('a seal whose flush fails still closes the spool', () async {
      final path = p.join(sessionDir.path, resultsDirName, _spool);
      await (await store.begin(_spool)).seal();
      final failing = _FlushFails(
        await File(path).open(mode: FileMode.writeOnly),
      );
      final live = LiveResult(store, _spool, failing);

      await expectLater(live.seal(), throwsA(isA<FileSystemException>()));

      expect(failing.closed, isTrue);
      // The handle is gone, so the spool can be deleted on every platform.
      File(path).deleteSync();
    });

    test('write after seal fails', () async {
      final live = await store.begin(_spool);
      await live.seal();

      expect(() => live.write([1]), throwsStateError);
    });

    test('rejects a name that is not a spool file', () async {
      await expectLater(store.begin('../x'), throwsA(isA<ResultError>()));
      await expectLater(store.begin('abc'), throwsA(isA<ResultError>()));
      await expectLater(store.adopt('.spool-a/b'), throwsA(isA<ResultError>()));
    });
  });

  group('ResultStore.publish', () {
    test('renames the spool to its hash and writes nothing else', () async {
      final descriptor = await sealed('hello\n');

      await store.publish(_spool, descriptor);

      expect(names(), [descriptor.sha256]);
      expect(file(descriptor.sha256).readAsStringSync(), 'hello\n');
    });

    test('keeps an existing file of the same size, drops the spool', () async {
      final stored = await store.storeResult(
        Stream.value(utf8.encode('same\n')),
      );
      final descriptor = await sealed('same\n');
      expect((stored as ResultComplete).descriptor, descriptor);

      await store.publish(_spool, descriptor);

      expect(names(), [descriptor.sha256]);
    });

    test('replaces an existing file of another size', () async {
      final descriptor = await sealed('right\n');
      file(descriptor.sha256).writeAsStringSync('bad');

      await store.publish(_spool, descriptor);

      expect(names(), [descriptor.sha256]);
      expect(file(descriptor.sha256).readAsStringSync(), 'right\n');
    });

    test('a repeated publish is harmless', () async {
      final descriptor = await sealed('x\n');
      await store.publish(_spool, descriptor);

      await store.publish(_spool, descriptor);

      expect(names(), [descriptor.sha256]);
    });

    test('fails when the spool is missing or its size differs', () async {
      final descriptor = await sealed('abc\n');
      file(_spool).writeAsStringSync('abcd\n');

      await expectLater(
        store.publish(_spool, descriptor),
        throwsA(isA<ResultError>()),
      );
      await expectLater(
        store.publish('.spool-none', descriptor),
        throwsA(isA<ResultError>()),
      );
      expect(names(), [_spool]);
    });
  });

  group('ResultStore.adopt', () {
    test('hashes an existing spool as seal would', () async {
      final descriptor = await sealed('p\nq');

      expect(await store.adopt(_spool), descriptor);
      expect(names(), [_spool]);
    });

    test('fails for a spool that does not exist', () async {
      await Directory(p.join(sessionDir.path, resultsDirName)).create();

      await expectLater(
        store.adopt('.spool-none'),
        throwsA(isA<ResultError>()),
      );
    });
  });
}

/// A spool file whose flush always fails, as a deferred ENOSPC would.
final class _FlushFails implements RandomAccessFile {
  _FlushFails(this.inner);

  final RandomAccessFile inner;
  bool closed = false;

  @override
  Future<RandomAccessFile> flush() async =>
      throw const FileSystemException('flush failed');

  @override
  Future<RandomAccessFile> writeFrom(
    List<int> buffer, [
    int start = 0,
    int? end,
  ]) async {
    await inner.writeFrom(buffer, start, end);
    return this;
  }

  @override
  Future<void> close() async {
    closed = true;
    await inner.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
