import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/session_support.dart';

void main() {
  late Directory root;
  setUp(() async => root = await tempDir());

  group('origin record', () {
    test('new session starts with one origin record', () async {
      final writer = await createWriter(root);
      final lines = journalOf(writer.sessionDir).readAsLinesSync();
      expect(lines, hasLength(1));

      final origin = JournalRecord.parse(lines.single);
      expect(origin.path, '');
      expect(origin.op, Op.set);
      expect(origin.turn, 0);
      final id = p.basename(writer.sessionDir.path);
      expect(id, matches(RegExp(r'^\d{8}T\d{6}Z-[0-9a-f]{8}$')));
      expect(origin.value, {
        'meta': {
          'format': 1,
          'session': id,
          'lineage': {'parent': null},
        },
      });
      expect(journalOf(writer.sessionDir).readAsBytesSync().last, 0x0A);
    });

    test('missing or repeated origin is rejected', () async {
      final second = rec(0, '', Op.set, {'meta': <String, Object?>{}}).encode();
      final cases = <(List<String>, int)>[
        ([rec(1, 'body/x', Op.set, 1).encode()], 1),
        ([originLine(), second], 2),
      ];
      for (final (lines, line) in cases) {
        final dir = writeSession(root, bytesOf(lines));
        final offset = utf8.encode(lines.take(line - 1).join()).length;
        final matcher = isA<JournalCorruption>()
            .having((e) => e.line, 'line', line)
            .having((e) => e.offset, 'offset', offset)
            .having((e) => e.reason, 'reason', 'invalid origin');
        expect(() => materialize(dir), throwsA(matcher));
        await expectLater(SessionWriter.open(dir), throwsA(matcher));
        dir.deleteSync(recursive: true);
      }
    });

    test('a live root set after the origin is rejected', () async {
      final writer = await createWriter(root);
      final length = journalOf(writer.sessionDir).lengthSync();
      await expectLater(
        writer.apply(rec(0, '', Op.set, {'body': <String, Object?>{}})),
        throwsA(
          isA<SessionError>().having(
            (e) => e.reason,
            'reason',
            'invalid origin',
          ),
        ),
      );
      expect(journalOf(writer.sessionDir).lengthSync(), length);
    });
  });
}
