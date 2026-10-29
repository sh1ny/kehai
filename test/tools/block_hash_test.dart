import 'dart:io';
import 'dart:typed_data';

import 'package:kehai/src/tools/block_hash.dart';
import 'package:test/test.dart';

import '../support/anchor_support.dart';

List<int> _mixedFile() {
  final out = <int>[0xEF, 0xBB, 0xBF];
  void line(List<int> text, String end) => out
    ..addAll(text)
    ..addAll(end.codeUnits);
  List<int> run(int n, [int seed = 0]) => [
    for (var i = 0; i < n; i++) (i * 7 + seed) % 3 == 0 ? 0x09 : 0x20,
  ];
  // The CR of line 1 is byte 65535 and its LF byte 65536.
  line(List.filled(65532, 0x78), '\r\n');
  // Interior and trailing runs longer than 64 KiB.
  line([0x61, ...run(70000), 0x62, ...run(3), 0x63], '\n');
  line([0x64, ...run(66000, 1)], '\r\n');
  line(run(70000, 2), '\r');
  line([...run(5), 0x65, ...run(70000, 1), 0x66, ...run(90000)], '\n');
  for (var i = 0; i < 35; i++) {
    final pad = i.isEven ? ' \t ' : '';
    line(
      'row $i $pad'
              'x'
          .codeUnits,
      ['\r\n', '\n', '\r'][i % 3],
    );
    if (i % 5 == 0) line(run(i + 1), '\n');
  }
  line('last without newline  '.codeUnits, '');
  return out;
}

void main() {
  test('streamed hash equals whole-block hash for mixed runs across chunk '
      'sizes', () {
    final bytes = _mixedFile();
    final want = definitionHashes(bytes);
    expect(want, hasLength(3));
    for (final size in [1, 7, 65536]) {
      expect(blockHashes(chunked(bytes, size)), want, reason: 'chunk $size');
    }
    // A BOM-less variant and an empty input.
    final plain = bytes.sublist(3);
    expect(blockHashes(chunked(plain, 7)), definitionHashes(plain));
    expect(blockHashes([Uint8List(0)]), isEmpty);
    // Only the BOM is not a line; a partial BOM is content.
    expect(
      blockHashes([
        Uint8List.fromList([0xEF, 0xBB, 0xBF]),
      ]),
      isEmpty,
    );
    final partial = [0xEF, 0xBB, 0x41, 0x0a];
    expect(blockHashes(chunked(partial, 1)), definitionHashes(partial));
  });

  test('recorded vector block 17 changes only its own hash', () {
    final block = (anchorReference()['block40']! as Map)
        .cast<String, Object?>();
    final original = File('test/fixtures/anchors/vector40.txt')
        .readAsBytesSync();
    final changed = File('test/fixtures/anchors/vector40.changed.txt')
        .readAsBytesSync();
    expect(block['changedLine'], 20);

    for (final size in [1, 7, 65536]) {
      expect(
        blockHashes(chunked(original, size)),
        block['original'],
        reason: 'original, chunk $size',
      );
      expect(
        blockHashes(chunked(changed, size)),
        block['changed'],
        reason: 'changed, chunk $size',
      );
    }
    final was = (block['original']! as List).cast<String>();
    final now = (block['changed']! as List).cast<String>();
    expect(now[1], isNot(was[1]));
    expect([now[0], now[2]], [was[0], was[2]]);
  });
}
