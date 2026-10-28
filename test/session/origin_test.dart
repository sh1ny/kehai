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

    test('an origin without complete valid meta is rejected', () async {
      Map<String, Object?> meta(void Function(Map<String, Object?>) edit) {
        final m = <String, Object?>{
          'format': 1,
          'session': 's1',
          'lineage': <String, Object?>{'parent': null},
        };
        edit(m);
        return m;
      }

      final origins = <String, Object?>{
        'empty origin': <String, Object?>{},
        'no meta': <String, Object?>{'body': <String, Object?>{}},
        'meta not a map': <String, Object?>{'meta': 1},
        'empty meta': <String, Object?>{'meta': <String, Object?>{}},
        'no format': {'meta': meta((m) => m.remove('format'))},
        'format not an int': {'meta': meta((m) => m['format'] = '1')},
        'no session': {'meta': meta((m) => m.remove('session'))},
        'session not a string': {'meta': meta((m) => m['session'] = 7)},
        'empty session': {'meta': meta((m) => m['session'] = '')},
        'no lineage': {'meta': meta((m) => m.remove('lineage'))},
        'lineage not a map': {'meta': meta((m) => m['lineage'] = 'x')},
        'lineage empty': {'meta': meta((m) => m['lineage'] = {})},
        'parent missing': {
          'meta': meta((m) => m['lineage'] = {'parentTurn': 1}),
        },
        'parent not a string': {
          'meta': meta((m) => m['lineage'] = {'parent': 3, 'parentTurn': 1}),
        },
        'parent without turn': {
          'meta': meta((m) => m['lineage'] = {'parent': 'p'}),
        },
        'parentTurn not an int': {
          'meta': meta(
            (m) => m['lineage'] = {'parent': 'p', 'parentTurn': 'x'},
          ),
        },
        'null parent with turn': {
          'meta': meta((m) => m['lineage'] = {'parent': null, 'parentTurn': 1}),
        },
        'extra lineage key': {
          'meta': meta(
            (m) =>
                m['lineage'] = {'parent': 'p', 'parentTurn': 1, 'extra': true},
          ),
        },
      };
      for (final MapEntry(:key, :value) in origins.entries) {
        final line = rec(0, '', Op.set, value).encode();
        final dir = writeSession(root, bytesOf([line]));
        final matcher = isA<JournalCorruption>()
            .having((e) => e.line, '$key line', 1)
            .having((e) => e.offset, '$key offset', 0)
            .having((e) => e.reason, '$key reason', 'invalid origin');
        expect(() => materialize(dir), throwsA(matcher), reason: key);
        await expectLater(
          SessionWriter.open(dir),
          throwsA(matcher),
          reason: key,
        );
        dir.deleteSync(recursive: true);
      }
    });

    test('a fork lineage origin is accepted', () async {
      final line = rec(3, '', Op.set, {
        'meta': {
          'format': 1,
          'session': 's2',
          'lineage': {'parent': 's1', 'parentTurn': 3},
        },
      }).encode();
      final dir = writeSession(root, bytesOf([line]));
      expect(materialize(dir).tree.toJson()['meta'], isNotNull);
      await (await SessionWriter.open(dir)).close();
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
