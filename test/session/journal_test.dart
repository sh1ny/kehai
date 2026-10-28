import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/session_support.dart';

Matcher corruption(int line, int offset, String reason) =>
    isA<JournalCorruption>()
        .having((e) => e.line, 'line', line)
        .having((e) => e.offset, 'offset', offset)
        .having((e) => e.reason, 'reason', reason);

void main() {
  late Directory root;
  setUp(() async => root = await tempDir());

  group('journal open', () {
    test('record with an extra or missing field is rejected on open', () async {
      final origin = originLine();
      final offset = utf8.encode(origin).length;
      for (final bad in [
        '{"turn":1,"path":"body/x","op":"set","value":1,"id":"a"}\n',
        '{"turn":1,"path":"body/x","op":"set"}\n',
      ]) {
        final dir = writeSession(root, bytesOf([origin, bad]));
        final before = journalOf(dir).readAsBytesSync();
        expect(
          () => materialize(dir),
          throwsA(corruption(2, offset, 'invalid record')),
        );
        await expectLater(
          SessionWriter.open(dir),
          throwsA(corruption(2, offset, 'invalid record')),
        );
        expect(journalOf(dir).readAsBytesSync(), before);
        dir.deleteSync(recursive: true);
      }
    });

    test('torn tail is preserved and truncated on write open', () async {
      final complete = rec(1, 'body/x', Op.set, 1).encode();
      final full = utf8.encode(rec(1, 'body/y', Op.set, 'abcdefgh').encode());
      final torn = full.sublist(0, 37);
      final committed = bytesOf([originLine(), complete]);
      final dir = writeSession(root, [...committed, ...torn]);

      final read = materialize(dir);
      expect(read.trailingBytes, 37);
      expect(read.recordCount, 2);
      expect(journalOf(dir).lengthSync(), committed.length + 37);

      final writer = await SessionWriter.open(dir);
      addTearDown(writer.close);
      final tail = writer.tornTail!;
      expect(tail.bytes, 37);
      expect(File(tail.recoveryPath!).readAsBytesSync(), torn);
      expect(
        p.basename(tail.recoveryPath!),
        matches(RegExp('^torn-${committed.length}-\\d{8}T\\d{6}Z\\.bin\$')),
      );
      expect(p.basename(p.dirname(tail.recoveryPath!)), 'recovery');
      expect(journalOf(dir).readAsBytesSync(), committed);
      expect(writer.tree.canonical(), read.tree.canonical());
    });

    test('repeated recovery at one offset and second keeps every tail', () {
      final committed = bytesOf([originLine()]);
      final at = DateTime.utc(2026, 1, 2, 3, 4, 5);
      final dir = writeSession(root, committed);
      final tails = [
        [for (var i = 0; i < 10; i++) 0x41],
        [for (var i = 0; i < 12; i++) 0x42],
        [for (var i = 0; i < 14; i++) 0x43],
      ];
      final paths = <String>[];
      for (final tail in tails) {
        journalOf(dir).writeAsBytesSync([...committed, ...tail]);
        final scan = scanJournal(journalOf(dir));
        final torn = recoverTornTail(dir, journalOf(dir), scan, now: at);
        paths.add(torn.recoveryPath!);
        expect(journalOf(dir).readAsBytesSync(), committed);
      }
      final stem = 'torn-${committed.length}-20260102T030405Z';
      expect(paths.map(p.basename), [
        '$stem.bin',
        '$stem-1.bin',
        '$stem-2.bin',
      ]);
      for (var i = 0; i < tails.length; i++) {
        expect(File(paths[i]).readAsBytesSync(), tails[i]);
      }
    });

    test('valid record without newline is torn', () async {
      final committed = bytesOf([originLine()]);
      final unterminated = utf8.encode(
        rec(1, 'body/x', Op.set, 1).encode().trimRight(),
      );
      final dir = writeSession(root, [...committed, ...unterminated]);

      final read = materialize(dir);
      expect(read.recordCount, 1);
      expect(read.trailingBytes, unterminated.length);
      expect(read.tree.contains(SessionPath.parse('body/x')), isFalse);

      final writer = await SessionWriter.open(dir);
      addTearDown(writer.close);
      expect(writer.tornTail!.bytes, unterminated.length);
      expect(
        File(writer.tornTail!.recoveryPath!).readAsBytesSync(),
        unterminated,
      );
      expect(journalOf(dir).readAsBytesSync(), committed);
      expect(writer.tree.contains(SessionPath.parse('body/x')), isFalse);
    });

    test('corrupt interior line stops open and read', () async {
      final lines = [
        originLine(),
        for (var i = 1; i < 10; i++) rec(1, 'body/k$i', Op.set, i).encode(),
      ];
      lines[4] = '{"turn":1,"path":\n';
      final offset = utf8.encode(lines.take(4).join()).length;
      final dir = writeSession(root, bytesOf(lines));
      final before = journalOf(dir).readAsBytesSync();

      expect(
        () => materialize(dir),
        throwsA(corruption(5, offset, 'invalid record')),
      );
      await expectLater(
        SessionWriter.open(dir),
        throwsA(corruption(5, offset, 'invalid record')),
      );
      expect(journalOf(dir).readAsBytesSync(), before);
    });

    test('unappliable interior record stops open', () async {
      final lines = [
        originLine(),
        rec(1, 'body/a', Op.set, 1).encode(),
        rec(1, 'body/missing', Op.del).encode(),
        rec(1, 'body/b', Op.set, 2).encode(),
      ];
      final offset = utf8.encode(lines.take(2).join()).length;
      final dir = writeSession(root, bytesOf(lines));
      final before = journalOf(dir).readAsBytesSync();

      expect(
        () => materialize(dir),
        throwsA(corruption(3, offset, 'path not found')),
      );
      await expectLater(
        SessionWriter.open(dir),
        throwsA(corruption(3, offset, 'path not found')),
      );
      expect(journalOf(dir).readAsBytesSync(), before);
    });

    test('committed record that skips a turn stops open', () async {
      final lines = [originLine(), rec(2, 'body/a', Op.set, 1).encode()];
      final dir = writeSession(root, bytesOf(lines));
      expect(
        () => materialize(dir),
        throwsA(corruption(2, utf8.encode(lines.first).length, 'invalid turn')),
      );
    });
  });
}
