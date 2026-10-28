import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Creates a temp directory that is deleted when the test ends.
Future<Directory> tempDir() async {
  final dir = await Directory.systemTemp.createTemp('kehai_');
  addTearDown(() async {
    if (dir.existsSync()) await dir.delete(recursive: true);
  });
  return dir;
}

/// Shorthand for a journal record.
JournalRecord rec(int turn, String path, Op op, [Object? value]) =>
    JournalRecord(turn: turn, path: path, op: op, value: value);

/// A journal file inside [sessionDir].
File journalOf(Directory sessionDir) =>
    File(p.join(sessionDir.path, journalFileName));

/// The origin line for a hand-written journal.
String originLine({String session = 's1'}) => rec(0, '', Op.set, {
  'meta': {
    'format': 1,
    'session': session,
    'lineage': {'parent': null},
  },
}).encode();

/// Writes [content] as the journal of a new session directory under [root].
Directory writeSession(Directory root, List<int> content) {
  final dir = Directory(p.join(root.path, 's1'))..createSync(recursive: true);
  journalOf(dir).writeAsBytesSync(content);
  return dir;
}

/// UTF-8 bytes of [lines] joined with no separator.
List<int> bytesOf(Iterable<String> lines) => utf8.encode(lines.join());

/// A [JournalIo] decorator that can fail, pause or skip operations.
final class HookedIo implements JournalIo {
  HookedIo(this.inner);

  final JournalIo inner;

  /// Runs before each write; may throw or write partially through [inner].
  Future<void> Function(List<int> bytes)? onWrite;

  /// Runs before each flush; may wait or throw.
  Future<void> Function()? beforeFlush;

  /// Skips the real flush, to keep large tests fast.
  bool skipFlush = false;

  @override
  Future<void> writeFrom(List<int> bytes) async {
    await onWrite?.call(bytes);
    await inner.writeFrom(bytes);
  }

  @override
  Future<void> flush() async {
    await beforeFlush?.call();
    if (!skipFlush) await inner.flush();
  }

  @override
  Future<void> close() => inner.close();
}

/// Creates a session whose journal file goes through a [HookedIo].
Future<(SessionWriter, HookedIo)> createHooked(Directory root) async {
  late HookedIo io;
  final writer = await SessionWriter.create(
    root,
    decorate: (inner) => io = HookedIo(inner),
  );
  addTearDown(writer.close);
  return (writer, io);
}

/// Creates a plain session and closes it when the test ends.
Future<SessionWriter> createWriter(Directory root) async {
  final writer = await SessionWriter.create(root);
  addTearDown(writer.close);
  return writer;
}
