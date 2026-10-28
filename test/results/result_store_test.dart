import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/session_support.dart';

const _chunkSize = 64 * 1024;
const _lineCount = 1000000;
const _totalBytes = 52428800;

/// Lines below this index are 53 bytes, the rest 52, totalling 50 MiB.
const _longLines = 428800;

/// Yields the 50 MiB stream in 64 KiB chunks, calling [onChunk] with the
/// chunk number just before each one is delivered.
Stream<List<int>> _bigStream(void Function(int index) onChunk) async* {
  var buffer = Uint8List(_chunkSize);
  var filled = 0;
  var index = 0;
  for (var i = 0; i < _lineCount; i++) {
    final length = i < _longLines ? 53 : 52;
    final number = i.toString().padLeft(6, '0');
    for (var j = 0; j < length; j++) {
      final byte = j == length - 1
          ? 0x0a
          : j < 6
          ? number.codeUnitAt(j)
          : 0x78;
      buffer[filled++] = byte;
      if (filled == _chunkSize) {
        onChunk(index++);
        yield buffer;
        buffer = Uint8List(_chunkSize);
        filled = 0;
      }
    }
  }
  if (filled > 0) {
    onChunk(index);
    yield Uint8List.sublistView(buffer, 0, filled);
  }
}

Directory _sessionDir(Directory root, [String name = 's']) =>
    Directory(p.join(root.path, name))..createSync();

List<String> _resultFiles(Directory sessionDir) =>
    Directory(p.join(sessionDir.path, resultsDirName))
        .listSync()
        .map((e) => p.basename(e.path))
        .toList()
      ..sort();

void main() {
  late Directory root;
  setUp(() async => root = await tempDir());

  test('50 MiB result stored whole with backpressure', () async {
    final dir = _sessionDir(root);
    final events = <String>[];
    final store = ResultStore(
      dir,
      hooks: ResultStoreHooks(afterWrite: (i) => events.add('written $i')),
    );

    final watch = Stopwatch()..start();
    final write = await store.storeResult(
      _bigStream((i) => events.add('delivered $i')),
    );
    watch.stop();
    // ignore: avoid_print
    print('50 MiB stored in ${watch.elapsedMilliseconds} ms');

    final complete = write as ResultComplete;
    expect(complete.descriptor.bytes, _totalBytes);
    expect(complete.descriptor.lines, _lineCount);

    // Independent regeneration is hashed chunk by chunk, never held whole.
    final sink = _DigestSink();
    final hash = sha256.startChunkedConversion(sink);
    await for (final chunk in _bigStream((_) {})) {
      hash.add(chunk);
    }
    hash.close();
    expect(complete.descriptor.sha256, sink.value.toString());

    final file = File(
      p.join(dir.path, resultsDirName, complete.descriptor.sha256),
    );
    expect(file.lengthSync(), _totalBytes);
    final stored = await sha256.bind(file.openRead()).first;
    expect(stored.toString(), complete.descriptor.sha256);

    const chunks = _totalBytes ~/ _chunkSize;
    expect(chunks, 800);
    for (var i = 1; i < chunks; i++) {
      expect(
        events.indexOf('delivered $i'),
        greaterThan(events.indexOf('written ${i - 1}')),
        reason: 'chunk $i was delivered before chunk ${i - 1} was written',
      );
    }
    expect(events.where((e) => e.startsWith('written')), hasLength(chunks));
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('producer failure finalizes the accepted prefix', () async {
    final dir = _sessionDir(root);
    final line = '${'x' * 99}\n';
    Stream<List<int>> producer() async* {
      for (var i = 0; i < 10; i++) {
        yield utf8.encode(line * 10);
      }
      throw StateError('producer broke');
    }

    final write = await ResultStore(dir).storeResult(producer());

    final failed = write as ResultProducerFailed;
    expect(failed.error, isA<StateError>());
    expect(failed.descriptor.bytes, 10000);
    expect(failed.descriptor.lines, 100);
    final file = File(
      p.join(dir.path, resultsDirName, failed.descriptor.sha256),
    );
    expect(file.lengthSync(), 10000);
    final page = await readMore(file, failed.descriptor, from: 1, lines: 3);
    expect(page, contains('x' * 99));
    expect(_resultFiles(dir), [failed.descriptor.sha256]);
  });

  test(
    'storage failure returns no descriptor and names the temp file',
    () async {
      final dir = _sessionDir(root);
      var cancelled = false;
      final controller = StreamController<List<int>>(
        onCancel: () => cancelled = true,
      );
      for (var i = 0; i < 5; i++) {
        controller.add(List.filled(1000, 0x61));
      }
      final store = ResultStore(
        dir,
        hooks: ResultStoreHooks(
          beforeWrite: (i, chunk) async {
            if (i == 2) throw const FileSystemException('disk full');
          },
        ),
      );

      final write = await store.storeResult(controller.stream);

      final failed = write as ResultStorageFailed;
      expect(failed.bytesAccepted, 2000);
      expect(failed.error, isA<FileSystemException>());
      expect(failed.message, contains('2000'));
      expect(failed.message, contains(failed.tempPath));
      expect(p.basename(failed.tempPath), startsWith('.tmp-'));
      expect(File(failed.tempPath).existsSync(), isTrue);
      expect(_resultFiles(dir), [p.basename(failed.tempPath)]);
      expect(cancelled, isTrue);
      await controller.close();
    },
  );

  test('flush and rename failures leave no final-name file', () async {
    var n = 0;
    for (final hooks in [
      ResultStoreHooks(beforeFlush: () async => throw StateError('flush')),
      ResultStoreHooks(beforeRename: () async => throw StateError('rename')),
    ]) {
      final dir = _sessionDir(root, 's${n++}');
      final write = await ResultStore(
        dir,
        hooks: hooks,
      ).storeResult(Stream.value(utf8.encode('abc\n')));
      final failed = write as ResultStorageFailed;
      expect(failed.bytesAccepted, 4);
      expect(_resultFiles(dir), [p.basename(failed.tempPath)]);
    }
  });

  test('identical bytes are stored once', () async {
    final dir = _sessionDir(root);
    final store = ResultStore(dir);
    final a = await store.storeResult(Stream.value(utf8.encode('abc')));
    final b = await store.storeResult(
      Stream.fromIterable([utf8.encode('a'), utf8.encode('bc')]),
    );
    expect((a as ResultComplete).descriptor, (b as ResultComplete).descriptor);
    expect(a.descriptor.lines, 1);
    expect(a.descriptor.handle, 'r/${a.descriptor.sha256.substring(0, 12)}');
    expect(_resultFiles(dir), [a.descriptor.sha256]);
  });
}

final class _DigestSink implements Sink<Digest> {
  late final Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
