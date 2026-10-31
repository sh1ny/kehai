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

    test('a long run of backslashes renders in linear time', () {
      final text = r'\u{' * 200000;
      final watch = Stopwatch()..start();
      final lines = exactLines(text);
      watch.stop();

      expect(lines.single, r'\u{5C}u{' * 200000);
      expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });
}
