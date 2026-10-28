import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

void main() {
  group('JournalRecord.encode', () {
    test('appended record has exactly four fields', () {
      const record = JournalRecord(
        turn: 1,
        path: 'body/t1/user',
        op: Op.set,
        value: {'text': 'hi'},
      );

      expect(
        record.encode(),
        '{"turn":1,"path":"body/t1/user","op":"set","value":{"text":"hi"}}\n',
      );
    });

    test('key order is turn, path, op, value with one trailing newline', () {
      const record = JournalRecord(
        turn: 0,
        path: 'meta',
        op: Op.del,
        value: null,
      );
      final line = record.encode();

      expect(line, '{"turn":0,"path":"meta","op":"del","value":null}\n');
      expect(line.indexOf('\n'), line.length - 1);
    });
  });

  group('JournalRecord.parse', () {
    test('round-trips an encoded record', () {
      const record = JournalRecord(
        turn: 7,
        path: 'body/a',
        op: Op.merge,
        value: {
          'y': [1, 2],
        },
      );
      final parsed = JournalRecord.parse(record.encode());

      expect(parsed.turn, 7);
      expect(parsed.path, 'body/a');
      expect(parsed.op, Op.merge);
      expect(parsed.value, {
        'y': [1, 2],
      });
    });

    test('accepts a null value and every operation', () {
      for (final op in Op.values) {
        final line = '{"turn":1,"path":"","op":"${op.wire}","value":null}';
        expect(JournalRecord.parse(line).op, op);
      }
    });

    test('rejects malformed records with reason invalid record', () {
      const bad = [
        'not json',
        '[]',
        '{"turn":1,"path":"a","op":"set"}',
        '{"turn":1,"path":"a","op":"set","value":1,"extra":2}',
        '{"turn":-1,"path":"a","op":"set","value":1}',
        '{"turn":1.5,"path":"a","op":"set","value":1}',
        '{"turn":"1","path":"a","op":"set","value":1}',
        '{"turn":1,"path":2,"op":"set","value":1}',
        '{"turn":1,"path":"a","op":"upsert","value":1}',
        '{"turn":1,"path":"a","op":3,"value":1}',
        '{"turn":1,"path":"a","op":"set","valu":1}',
      ];
      for (final line in bad) {
        expect(
          () => JournalRecord.parse(line),
          throwsA(
            isA<SessionError>().having(
              (e) => e.reason,
              'reason',
              'invalid record',
            ),
          ),
          reason: line,
        );
        expect(JournalRecord.tryParse(line), isNull, reason: line);
      }
    });
  });
}
