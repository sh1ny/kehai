import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kehai/kehai.dart';
import 'package:kehai/src/tools/block_hash.dart';
import 'package:kehai/src/tools/xxhash32.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/anchor_support.dart';
import '../support/session_support.dart';
import '../support/tool_support.dart';

const int _kib = 1024;
const int _mib = 1024 * 1024;

Future<(ToolOutcome, RecordingOutput)> _read(
  Directory workspace,
  Map<String, Object?> input, {
  ReadSeams seams = const ReadSeams(),
  bool keep = true,
}) async {
  final output = RecordingOutput(keep: keep);
  final outcome = await ReadTool(seams: seams)
      .run(toolContext(workspace, output), input);
  return (outcome, output);
}

String _lines(int n) => n == 1 ? '1 line' : '$n lines';

void main() {
  late Directory ws;
  setUp(() async => ws = await tempDir());

  File put(String name, List<int> bytes) =>
      File(p.join(ws.path, name))..writeAsBytesSync(bytes);

  test('40-line file anchors lines 1, 17 and 33', () async {
    final bytes = File('test/fixtures/anchors/vector40.txt').readAsBytesSync();
    put('v.txt', bytes);
    final hashes = (anchorReference()['block40']! as Map)['original']! as List;

    final (outcome, output) = await _read(ws, {'path': 'v.txt'});

    expect(outcome.status, ResultStatus.ok);
    expect(outcome.complete, isTrue);
    expect(outcome.summary, 'v.txt: 40 lines, LF');
    final source = utf8.decode(bytes).split('\n')..removeLast();
    final want = [
      for (var i = 0; i < 40; i++)
        i % 16 == 0
            ? '${i + 1}#${hashes[i ~/ 16]}:${source[i]}'
            : '${i + 1}:${source[i]}',
    ];
    expect(output.lines, want);
    expect(output.lines, hasLength(40));
    expect(output.lines[0], startsWith('1#${hashes[0]}:'));
    expect(output.lines[16], startsWith('17#${hashes[1]}:'));
    expect(output.lines[32], startsWith('33#${hashes[2]}:'));
  });

  test('BOM, CRLF and a missing final newline are not shown', () async {
    put('c.txt', [0xEF, 0xBB, 0xBF, ...utf8.encode('a \r\nb\rc\nd')]);

    final (outcome, output) = await _read(ws, {'path': 'c.txt'});

    final hash = definitionHashes(
      File(p.join(ws.path, 'c.txt')).readAsBytesSync(),
    );
    expect(output.text, '1#${hash.single}:a \n2:b\n3:c\n4:d\n');
    // One ending of each kind: the tie goes to LF.
    expect(outcome.summary, 'c.txt: 4 lines, LF');
  });

  test('empty file reads 0 lines ok', () async {
    put('empty.txt', const []);

    final (outcome, output) = await _read(ws, {'path': 'empty.txt'});

    expect(outcome.status, ResultStatus.ok);
    expect(outcome.summary, contains('0 lines'));
    expect(output.total, 0);
  });

  test('missing, directory and NUL-in-8-KiB paths give their errors', () async {
    Directory(p.join(ws.path, 'dir')).createSync();
    final inside = Uint8List(10 * _kib)..fillRange(0, 10 * _kib, 0x61);
    inside[8 * _kib - 1] = 0;
    put('nul.bin', inside);
    final outside = Uint8List(10 * _kib)..fillRange(0, 10 * _kib, 0x61);
    outside[8 * _kib] = 0;
    put('late-nul.txt', outside);

    final missing = await _read(ws, {'path': 'nope.txt'});
    final dir = await _read(ws, {'path': 'dir'});
    final nul = await _read(ws, {'path': 'nul.bin'});
    final late = await _read(ws, {'path': 'late-nul.txt'});

    expect(missing.$1.status, ResultStatus.error);
    expect(missing.$1.summary, 'no such file nope.txt');
    expect(dir.$1.status, ResultStatus.error);
    expect(dir.$1.summary, 'dir is a directory; use ls');
    expect(nul.$1.status, ResultStatus.error);
    expect(nul.$1.summary, 'binary file nul.bin (${10 * _kib} bytes)');
    for (final r in [missing, dir, nul]) {
      expect(r.$2.total, 0, reason: 'no body for ${r.$1.summary}');
    }
    expect(late.$1.status, ResultStatus.ok, reason: 'NUL past 8 KiB is text');
  });

  test('offset 20 limit 10 renders lines 17–32 of 100', () async {
    put(
      'h.txt',
      utf8.encode([for (var i = 1; i <= 100; i++) 'row $i\n'].join()),
    );

    final (outcome, output) = await _read(ws, {
      'path': 'h.txt',
      'offset': 20,
      'limit': 10,
    });

    expect(outcome.status, ResultStatus.ok);
    expect(outcome.summary, contains('lines 17–32 of 100'));
    expect(output.lines, hasLength(16));
    expect(output.lines.first, matches(RegExp(r'^17#[0-9A-F]{4}:row 17$')));
    expect(output.lines.last, '32:row 32');

    // The window ends on the block that holds its last line.
    final (_, one) = await _read(ws, {
      'path': 'h.txt',
      'offset': 16,
      'limit': 2,
    });
    expect(one.lines.first, startsWith('1#'));
    expect(one.lines.last, '32:row 32');
    final (_, tail) = await _read(ws, {'path': 'h.txt', 'offset': 99});
    expect(tail.lines.first, matches(RegExp(r'^97#[0-9A-F]{4}:row 97$')));
    expect(tail.lines.last, '100:row 100');
  });

  test('offset past end and 70 MiB without limit are refused', () async {
    put(
      'h.txt',
      utf8.encode([for (var i = 1; i <= 100; i++) 'row $i\n'].join()),
    );
    final big = Uint8List(_mib);
    for (var i = 0; i < big.length; i++) {
      big[i] = i % 64 == 63 ? 0x0a : 0x61;
    }
    writeRepeated(File(p.join(ws.path, 'big.txt')), big, 70);

    final beyond = await _read(ws, {'path': 'h.txt', 'offset': 101});
    final huge = await _read(ws, {'path': 'big.txt'});
    final window = await _read(ws, {
      'path': 'big.txt',
      'limit': 20,
    }, keep: false);

    expect(beyond.$1.status, ResultStatus.error);
    expect(beyond.$1.summary, 'offset 101 beyond last line 100');
    expect(beyond.$2.total, 0);
    expect(huge.$1.status, ResultStatus.error);
    expect(huge.$1.summary, 'file is 70.0 MiB; read it with offset and limit');
    expect(huge.$2.total, 0);
    expect(window.$1.status, ResultStatus.ok);
    expect(window.$1.summary, contains('lines 1–32 of ${70 * _mib ~/ 64}'));
  });

  test(
    'size or mtime change between passes fails file changed during read',
    () async {
      final file = put(
        'v.txt',
        File('test/fixtures/anchors/vector40.txt').readAsBytesSync(),
      );

      final grown = await _read(
        ws,
        {'path': 'v.txt'},
        seams: ReadSeams(
          afterHashPass: (block) async {
            if (block == 1) {
              file.writeAsStringSync('more\n', mode: FileMode.append);
            }
          },
        ),
      );
      expect(grown.$1.status, ResultStatus.error);
      expect(grown.$1.summary, 'file changed during read; read it again');

      final touched = put(
        'w.txt',
        File('test/fixtures/anchors/vector40.txt').readAsBytesSync(),
      );
      final touchedRead = await _read(
        ws,
        {'path': 'w.txt'},
        seams: ReadSeams(
          afterHashPass: (block) async {
            if (block == 0) {
              touched.setLastModifiedSync(
                touched.lastModifiedSync().add(const Duration(hours: 1)),
              );
            }
          },
        ),
      );
      expect(touchedRead.$1.status, ResultStatus.error);
      expect(touchedRead.$1.summary, 'file changed during read; read it again');

      // A change after the last render pass is caught by the final check.
      final late = put(
        'x.txt',
        File('test/fixtures/anchors/vector40.txt').readAsBytesSync(),
      );
      final lateRead = await _read(
        ws,
        {'path': 'x.txt'},
        seams: ReadSeams(
          afterHashPass: (block) async {
            if (block == 2) {
              late.writeAsStringSync('tail\n', mode: FileMode.append);
            }
          },
        ),
      );
      expect(lateRead.$1.summary, 'file changed during read; read it again');
    },
  );

  group('working set', () {
    test(
      '[slow] 2 GiB single line reads whole with working set under 1 MiB',
      tags: 'slow',
      () async {
        final file = File(p.join(ws.path, 'one-line.txt'));
        final unit = Uint8List(_mib)..fillRange(0, _mib, 0x61);
        const mibs = 2048;
        writeRepeated(file, unit, mibs);
        final expected = XxHash32();
        for (var i = 0; i < mibs; i++) {
          expected.add(unit, 0, unit.length);
        }
        final anchor = anchorHex(expected.digest());
        final stats = ReadStats();
        final output = RecordingOutput(keep: false)
          ..onChunk = (chunk) {
            // Everything after the prefix is the line itself.
            if (!{0x61, 0x31, 0x0a}.contains(chunk.first)) fail('bad chunk');
          };

        final started = Stopwatch()..start();
        final outcome = await ReadTool(seams: stats.seams)
            .run(toolContext(ws, output), {'path': 'one-line.txt', 'limit': 1});
        final elapsed = started.elapsed;
        printOnFailure('2 GiB read took $elapsed');

        expect(outcome.status, ResultStatus.ok);
        expect(outcome.summary, 'one-line.txt: ${_lines(1)}, no line ending');
        final prefix = '1#$anchor:';
        expect(output.total, prefix.length + mibs * _mib + 1);
        expect(
          utf8.decode(output.head.take(prefix.length + 3).toList()),
          '${prefix}aaa',
        );
        expect(output.last, 0x0a);
        expect(stats.maxRequest, lessThanOrEqualTo(64 * _kib));
        expect(
          stats.maxRequest + output.maxChunk,
          lessThan(_mib),
          reason: 'read buffer plus write buffer',
        );
        // Two passes over the line: hash, then render.
        expect(stats.bytes, 2 * mibs * _mib);
        file.deleteSync();
      },
      timeout: const Timeout(Duration(minutes: 20)),
    );

    test(
      '[slow] 64 MiB of newlines reads with working set under 1 MiB at any '
      'limit',
      tags: 'slow',
      () async {
        const lines = 64 * _mib;
        final file = File(p.join(ws.path, 'newlines.txt'));
        writeRepeated(file, Uint8List(_mib)..fillRange(0, _mib, 0x0a), 64);
        final emptyBlock = anchorHex(xxHash32(List.filled(15, 0x0a)));

        for (final limit in <int?>[null, 100000000]) {
          final stats = ReadStats();
          final output = RecordingOutput(keep: false)..countNewlines = true;

          final started = Stopwatch()..start();
          final outcome = await ReadTool(seams: stats.seams).run(
            toolContext(ws, output),
            {'path': 'newlines.txt', 'limit': ?limit},
          );
          printOnFailure(
            '64 MiB of newlines, limit $limit: ${started.elapsed}',
          );

          expect(outcome.status, ResultStatus.ok, reason: '$limit');
          expect(outcome.summary, 'newlines.txt: $lines lines, LF');
          expect(output.newlines, lines, reason: 'one rendered line per line');
          expect(output.hashes, lines ~/ 16, reason: 'an anchor on every 16th');
          expect(
            utf8.decode(output.head.take(26).toList()),
            '1#$emptyBlock:\n2:\n3:\n4:\n5:\n6:\n7:\n',
          );
          expect(stats.maxRequest, lessThanOrEqualTo(64 * _kib));
          expect(stats.maxRequest + output.maxChunk, lessThan(_mib));
        }
        file.deleteSync();
      },
      timeout: const Timeout(Duration(minutes: 20)),
    );
  });
}
