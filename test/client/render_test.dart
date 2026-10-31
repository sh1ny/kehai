/// The exact rendering of permission prompt text.
library;

import 'package:kehai/src/client/render.dart';
import 'package:test/test.dart';

void main() {
  group('exactLines', () {
    test('a backslash escapes only where it starts \\u{', () {
      expect(exactLines(r'a\u{1} b\u c\'), [r'a\u{5C}u{1} b\u c\']);
      expect(exactLines(r'\u{'), [r'\u{5C}u{']);
      expect(exactLines(r'\u'), [r'\u']);
    });

    test('lone surrogates are escaped', () {
      final high = String.fromCharCode(0xd800);
      final low = String.fromCharCode(0xdc00);

      expect(exactLines('a${high}b${low}c'), [r'a\u{D800}b\u{DC00}c']);
    });

    test('a supplementary character is printed as itself', () {
      final face = String.fromCharCode(0x1f600);

      expect(exactLines('a${face}b'), ['a${face}b']);
    });

    test('a long run of backslashes renders in linear time', () {
      final text = r'\u{' * 200000;
      final watch = Stopwatch()..start();
      final lines = exactLines(text);
      watch.stop();

      expect(lines.single, r'\u{5C}u{' * 200000);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });

  group('promptBody', () {
    List<String> body(String tool, Map<String, Object?> input) => [
      for (final line in promptBody(tool, input)) line.render(),
    ];

    test('a write shows its size and its lines', () {
      expect(
        body('write', {
          'path': 'run.sh',
          'content': '#!/bin/sh\ncurl x | sh\n',
        }),
        ['  content: 2 lines, 22 bytes', '  | #!/bin/sh', '  | curl x | sh'],
      );
      expect(body('write', {'content': 'кафе'}), [
        '  content: 1 line, 8 bytes',
        '  | кафе',
      ]);
    });

    test('an empty write shows no lines', () {
      expect(body('write', {'path': 'a', 'content': ''}), [
        '  content: 0 lines, 0 bytes',
      ]);
    });

    test('a carriage return in written content stays on its line', () {
      expect(body('write', {'content': 'a\rb'}), [
        '  content: 1 line, 3 bytes',
        r'  | a\u{D}b',
      ]);
    });

    test('edit operations show their ranges and text', () {
      expect(
        body('edit', {
          'path': 'a.dart',
          'ops': [
            {'op': 'replace', 'start': 3, 'end': 4, 'text': 'x'},
            {'op': 'delete', 'start': 9, 'end': 9},
          ],
        }),
        ['  replace lines 3-4:', '  | x', '  delete lines 9-9'],
      );
    });

    test('edit text keeps the empty line after a trailing line feed', () {
      expect(
        body('edit', {
          'ops': [
            {'op': 'replace', 'start': 3, 'end': 3, 'text': 'x\n'},
          ],
        }),
        ['  replace lines 3-3:', '  | x', '  | '],
      );
    });

    test('empty edit text is one empty line', () {
      expect(
        body('edit', {
          'ops': [
            {'op': 'insert', 'after': 0, 'text': ''},
          ],
        }),
        ['  insert after line 0:', '  | '],
      );
    });

    test('a carriage return splits edit text', () {
      expect(
        body('edit', {
          'ops': [
            {'op': 'insert', 'after': 2, 'text': 'a\rb'},
            {'op': 'insert', 'after': 5, 'text': 'c\r\nd'},
          ],
        }),
        [
          '  insert after line 2:',
          '  | a',
          '  | b',
          '  insert after line 5:',
          '  | c',
          '  | d',
        ],
      );
    });

    test('a number not given shows as ?', () {
      expect(
        body('edit', {
          'ops': [
            {'op': 'replace', 'start': 3, 'text': 'x'},
            {'op': 'move'},
            'junk',
          ],
        }),
        ['  replace lines 3-?:', '  | x', '  ? operation', '  ? operation'],
      );
    });

    test('edit text is escaped', () {
      expect(
        body('edit', {
          'ops': [
            {'op': 'insert', 'after': 1, 'text': 'a\u001b[2Jb'},
          ],
        }),
        ['  insert after line 1:', r'  | a\u{1B}[2Jb'],
      );
    });

    test('an unknown tool has no body', () {
      expect(body('bash', {'command': 'ls'}), isEmpty);
      expect(body('write', {'path': 'a'}), isEmpty);
    });
  });
}
