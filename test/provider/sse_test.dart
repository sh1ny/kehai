import 'dart:convert';

import 'package:kehai/src/auth/openai_constants.dart';
import 'package:kehai/src/provider/sse.dart';
import 'package:test/test.dart';

Stream<List<int>> _chunks(List<String> parts) =>
    Stream.fromIterable(parts.map(utf8.encode));

Future<List<SseEvent>> _parse(List<String> parts) =>
    parseSse(_chunks(parts)).toList();

void main() {
  group('framing', () {
    test('dispatches data and event on a blank line', () async {
      final events = await _parse(['event: a\ndata: x\n\ndata: y\n\n']);
      expect(events.map((e) => (e.event, e.data)), [('a', 'x'), (null, 'y')]);
    });

    test('joins multi-line data with LF and strips one space', () async {
      final events = await _parse([
        'data: one\ndata:  two\ndata:\ndata: 4\n\n',
      ]);
      expect(events.single.data, 'one\n two\n\n4');
    });

    test('surfaces comments and ignores unknown fields', () async {
      final events = await _parse([': ping\nid: 7\nretry: 1\ndata: x\n\n']);
      expect(events.length, 2);
      expect(events[0].isComment, isTrue);
      expect(events[1].data, 'x');
      expect(events[1].isComment, isFalse);
    });

    test('accepts CRLF, CR and LF line ends', () async {
      final events = await _parse(['data: a\r\n\r\ndata: b\r\rdata: c\n\n']);
      expect(events.map((e) => e.data), ['a', 'b', 'c']);
    });

    test('handles a CRLF split across chunks', () async {
      final events = await _parse(['data: a\r', '\n\r', '\ndata: b\n', '\n']);
      expect(events.map((e) => e.data), ['a', 'b']);
    });

    test('handles lines and multi-byte characters split across chunks', () {
      final bytes = utf8.encode('data: 日本\n\n');
      final stream = Stream.fromIterable([
        for (final b in bytes) [b],
      ]);
      expect(parseSse(stream).map((e) => e.data).toList(), completion(['日本']));
    });

    test('drops an unterminated trailing event', () async {
      expect(await _parse(['data: a\n\ndata: b\n']), hasLength(1));
    });

    test('does not dispatch an event without data', () async {
      expect(await _parse(['event: a\n\n']), isEmpty);
    });
  });

  group('bounds', () {
    test('event over 8 MiB fails protocol', () async {
      final line = 'data: ${'a' * 65536}\n';
      final lines = (openAiMaxSseEventBytes ~/ 65536) + 1;
      final stream = Stream.fromIterable([
        for (var i = 0; i < lines; i++) utf8.encode(line),
      ]);
      await expectLater(
        parseSse(stream).toList(),
        throwsA(
          isA<SseProtocolError>().having(
            (e) => e.message,
            'message',
            'SSE event exceeds 8 MiB',
          ),
        ),
      );
    });

    test('one line over 8 MiB fails before a newline arrives', () async {
      final stream = Stream.fromIterable([
        utf8.encode('data: '),
        for (var i = 0; i < 129; i++) List<int>.filled(65536, 97),
      ]);
      await expectLater(
        parseSse(stream).toList(),
        throwsA(isA<SseProtocolError>()),
      );
    });

    test('an event of exactly 8 MiB is accepted', () async {
      final body = 'a' * openAiMaxSseEventBytes;
      final events = await _parse(['data: $body\n\n']);
      expect(events.single.data.length, openAiMaxSseEventBytes);
    });

    test('events before the oversized one are delivered', () async {
      final seen = <String>[];
      final stream = Stream.fromIterable([
        utf8.encode('data: ok\n\n'),
        utf8.encode('data: ${'a' * (openAiMaxSseEventBytes + 1)}\n\n'),
      ]);
      await expectLater(
        parseSse(stream).forEach((e) => seen.add(e.data)),
        throwsA(isA<SseProtocolError>()),
      );
      expect(seen, ['ok']);
    });
  });

  group('backpressure', () {
    test('does not read ahead of a paused listener', () async {
      var pulled = 0;
      Stream<List<int>> source() async* {
        for (var i = 0; i < 100; i++) {
          pulled++;
          yield utf8.encode('data: $i\n\n');
        }
      }

      final sub = parseSse(source()).listen((_) {});
      sub.pause();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(pulled, lessThan(5));
      await sub.cancel();
    });
  });
}
