import 'dart:convert';
import 'dart:typed_data';

import 'package:kehai/src/tools/block_hash.dart';
import 'package:kehai/src/tools/xxhash32.dart';
import 'package:test/test.dart';

import '../support/anchor_support.dart';

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  test('xxHash32 matches published vectors; whitespace and CRLF variants '
      'hash equal', () {
    final vectors = (anchorReference()['xxhash32']! as List)
        .cast<Map<String, Object?>>();
    expect(vectors, hasLength(4));
    for (final v in vectors) {
      final input = _bytes(v['input']! as String);
      final hex = v['hex']! as String;
      final want = int.parse(hex, radix: 16);
      expect(xxHash32(input), want, reason: 'one-shot "${v['input']}"');
      for (final size in [1, 3, 7, 16, 17, 65536]) {
        final state = XxHash32();
        for (final chunk in chunked(input, size)) {
          state.add(chunk, 0, chunk.length);
        }
        expect(state.digest(), want, reason: '"${v['input']}" in $size');
        // Taking the digest does not disturb the state.
        expect(state.digest(), want);
      }
      final bytewise = XxHash32();
      for (final b in input) {
        bytewise.addByte(b);
      }
      expect(bytewise.digest(), want, reason: 'addByte "${v['input']}"');
      expect(anchorHex(want), hex.substring(4));
    }

    // copyFrom is a value copy: the original keeps its own input.
    final head = _bytes('Nobody ins');
    final tail = _bytes('pects the spammish repetition');
    final a = XxHash32()..add(head, 0, head.length);
    final b = XxHash32()..copyFrom(a);
    b.add(tail, 0, tail.length);
    expect(b.digest(), 0xE2293B2F);
    expect(a.digest(), xxHash32(head));

    // Whitespace-only and line-ending variants of one block hash equal.
    final lf = _bytes('alpha beta\n\tgamma\nz');
    final variants = [
      _bytes('alpha beta  \t\n\tgamma \r\nz  '),
      _bytes('alpha beta\r\n\tgamma\rz\t'),
      Uint8List.fromList([0xEF, 0xBB, 0xBF, ...lf]),
    ];
    final base = blockHashes([lf]);
    expect(base, [anchorHex(xxHash32(lf))]);
    for (final v in variants) {
      expect(blockHashes([v]), base, reason: '$v');
    }
    // Interior whitespace is content.
    expect(blockHashes([_bytes('alpha  beta\n\tgamma\nz')]), isNot(base));
  });
}
