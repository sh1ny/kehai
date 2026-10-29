import 'dart:convert';

import 'package:kehai/src/provider/estimate.dart';
import 'package:test/test.dart';

void main() {
  group('estimateTokens', () {
    test('estimate is at least utf8 bytes over three', () {
      final body = {'input': 'héllo 日本語 ' * 40, 'n': 1};
      final bytes = utf8.encode(jsonEncode(body)).length;
      final estimate = estimateTokens(body);
      expect(estimate.tokens, greaterThanOrEqualTo(bytes ~/ 3));
      expect(estimate.tokens, (bytes / 3).ceil());
      expect(estimate.exact, isFalse);
    });

    test('raw bytes count as-is, rounded up', () {
      expect(estimateTokens(List<int>.filled(10, 65)).tokens, 4);
      expect(estimateTokens(List<int>.filled(9, 65)).tokens, 3);
      expect(estimateTokens(const <int>[]).tokens, 0);
    });

    test('multi-byte characters count by bytes not characters', () {
      // "日" is 3 UTF-8 bytes; the JSON string adds two quote bytes.
      expect(estimateTokens('日日日').tokens, ((9 + 2) / 3).ceil());
    });
  });
}
