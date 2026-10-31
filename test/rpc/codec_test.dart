import 'dart:convert';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/fake_provider.dart';
import '../support/rpc_support.dart';

void main() {
  group('NDJSON framing', () {
    test('one status line gets exactly one reply line', () async {
      final rig = await rpcRig(FakeProvider.steps(const []));
      await rig.nextOfType('snapshot');
      final before = rig.events.length;

      rig.sendRaw('{"type":"status","id":"r1"}');

      final reply = await rig.answerTo('r1', from: before);
      expect(reply['type'], 'reply');
      expect(reply['ok'], isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(
        rig.events.skip(before).where((e) => e['to'] == 'r1'),
        hasLength(1),
      );
    });

    test(
      '2 MiB line and unknown command error then status is answered',
      () async {
        final rig = await rpcRig(FakeProvider.steps(const []));
        await rig.nextOfType('snapshot');
        final before = rig.events.length;

        rig.sendRaw('x' * (2 * 1024 * 1024));
        rig.sendRaw('{"type":"sumbit"}');
        rig.sendRaw('{"type":"status","id":"r2"}');

        await rig.answerTo('r2', from: before);
        final replies = rig.events
            .skip(before)
            .where((e) => e['type'] == 'error' || e['type'] == 'reply')
            .toList();
        expect(replies.map((e) => e['type']), ['error', 'error', 'reply']);
        expect(replies[0]['message'], 'line too long (limit 1 MiB)');
        expect(replies[1]['message'], 'unknown command sumbit');
        expect(replies[2]['to'], 'r2');
      },
    );
  });

  group('Line reader', () {
    test(
      'a line split across chunks arrives whole and CRLF is trimmed',
      () async {
        final lines = await readLines(
          Stream.fromIterable([
            utf8.encode('{"a":'),
            utf8.encode('1}\r\n{"b"'),
            utf8.encode(':2}\n'),
          ]),
          limit: maxLineBytes,
        ).toList();
        expect(lines.map((e) => (e as InputLine).text), ['{"a":1}', '{"b":2}']);
      },
    );
  });
}
