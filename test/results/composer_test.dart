import 'dart:convert';
import 'dart:io';

import 'package:kehai/src/results/composer.dart';
import 'package:kehai/src/results/descriptor.dart';
import 'package:kehai/src/results/line_scanner.dart';
import 'package:test/test.dart';

import '../support/results_support.dart';

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('kehai_composer_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('composer', () {
    test('read over the line cap gets the exact truncation line', () async {
      final r = storeLines(dir, [for (var i = 1; i <= 2310; i++) 'line $i']);

      final out = await composeResult(
        'read',
        ResultStatus.ok,
        'big.txt',
        r.descriptor,
        r.file,
        policy: ResultPolicy.read,
      );

      final lines = out.split('\n');
      expect(lines.first, '[read ok] big.txt');
      expect(lines.sublist(1, 401), [for (var i = 1; i <= 400; i++) 'line $i']);
      expect(lines, hasLength(402));
      expect(
        lines.last,
        '[truncated: showing lines 1–400 of 2,310; handle r/7f3a9c1b2d4e; '
        'read_more(r/7f3a9c1b2d4e, from=401)]',
      );
    });

    test('fitting result has no truncation line', () async {
      final r = storeLines(dir, [for (var i = 1; i <= 12; i++) 'line $i']);

      final out = await composeResult(
        'read',
        ResultStatus.ok,
        'small.txt',
        r.descriptor,
        r.file,
        policy: ResultPolicy.read,
      );

      final lines = out.split('\n');
      expect(lines, hasLength(13));
      expect(lines.first, '[read ok] small.txt');
      expect(lines.last, 'line 12');
      expect(lines.where((l) => l.startsWith('[truncated:')), isEmpty);
    });

    group('first line over the budget', () {
      int cost(String line) => estimateTokens(utf8.encode(line).length + 1);

      for (final (name, policy, cap) in [
        ('head only', const ResultPolicy(maxTokens: 100), 100),
        (
          'head and tail',
          const ResultPolicy(maxTokens: 100, headTail: true),
          60,
        ),
      ]) {
        test('$name: the first line is clipped to the budget', () async {
          final r = storeLines(dir, ['x' * 1000, 'y', 'z']);

          final out = await composeResult(
            'bash',
            ResultStatus.ok,
            's',
            r.descriptor,
            r.file,
            policy: policy,
          );

          final first = out.split('\n')[1];
          expect(first, startsWith('x'));
          expect(
            first,
            matches(
              RegExp(r' \[line truncated: showing \d+ of 1,000 chars\]$'),
            ),
          );
          expect(cost(first), lessThanOrEqualTo(cap));
          expect(cost(first), greaterThan(cap - 2));
        });
      }

      test('a budget below the truncation marker fails explicitly', () async {
        final r = storeLines(dir, ['x' * 1000, 'y']);

        expect(
          composeResult(
            'bash',
            ResultStatus.ok,
            's',
            r.descriptor,
            r.file,
            policy: const ResultPolicy(maxTokens: 5),
          ),
          throwsA(isA<ComposeError>()),
        );
      });
    });

    group('token estimate is cumulative', () {
      Future<String> compose(String tool, StoredResult r) =>
          composeResult(tool, ResultStatus.ok, 's', r.descriptor, r.file);

      for (final tool in ['bash', 'other']) {
        test('$tool: 12,000 one-byte lines fit with no truncation', () async {
          final r = storeLines(dir, List.filled(12000, 'a'));
          expect(r.descriptor.bytes, 24000);
          expect(estimateTokens(r.descriptor.bytes), 8000);

          final lines = (await compose(tool, r)).split('\n');

          expect(lines, hasLength(12001));
          expect(lines.where((l) => l.startsWith('[')), ['[$tool ok] s']);
        });
      }

      test('fit without a trailing newline is shown whole', () async {
        final r = storeBytes(dir, [...utf8.encode('a\n' * 11999), 0x61, 0x61]);
        expect(r.descriptor.bytes, 24000);

        final lines = (await compose('bash', r)).split('\n');

        expect(lines, hasLength(12001));
        expect(lines.last, 'aa');
      });

      group('one byte over the boundary', () {
        late StoredResult over;
        setUp(() {
          over = storeBytes(dir, [...utf8.encode('a\n' * 12000), 0x62]);
          expect(estimateTokens(over.descriptor.bytes), 8001);
        });

        test('head only keeps exactly the lines within the estimate', () async {
          final lines = (await compose('other', over)).split('\n');

          expect(lines, hasLength(12002));
          expect(lines[12000], 'a');
          expect(
            lines.last,
            '[truncated: showing lines 1–12,000 of 12,001; '
            'handle r/7f3a9c1b2d4e; read_more(r/7f3a9c1b2d4e, from=12001)]',
          );
        });

        test(
          'head and tail split the estimate 60/40 by cumulative bytes',
          () async {
            final lines = (await compose('bash', over)).split('\n');

            // 7,200 head lines (4,800 tokens), one omitted, 4,800 tail lines.
            expect(lines[7200], 'a');
            expect(lines[7201], '[… 1 lines omitted …]');
            expect(lines[12001], 'b');
            expect(lines, hasLength(1 + 7200 + 1 + 4800 + 1));
            expect(
              lines.last,
              '[truncated: showing lines 1–7,200 and 7,202–12,001 of 12,001; '
              'handle r/7f3a9c1b2d4e; read_more(r/7f3a9c1b2d4e, from=7201)]',
            );
          },
        );
      });
    });

    test('bash log keeps 60% head and 40% tail', () async {
      final r = storeLines(dir, [for (var i = 1; i <= 10000; i++) 'line $i']);

      final out = await composeResult(
        'bash',
        ResultStatus.ok,
        'make test',
        r.descriptor,
        r.file,
        policy: const ResultPolicy(maxLines: 1000, headTail: true),
      );

      final lines = out.split('\n');
      expect(lines.first, '[bash ok] make test');
      expect(lines.sublist(1, 601), [for (var i = 1; i <= 600; i++) 'line $i']);
      expect(lines[601], '[… 9,000 lines omitted …]');
      expect(lines.sublist(602, 1002), [
        for (var i = 9601; i <= 10000; i++) 'line $i',
      ]);
      expect(lines, hasLength(1003));
      expect(
        lines.last,
        '[truncated: showing lines 1–600 and 9,601–10,000 of 10,000; '
        'handle r/7f3a9c1b2d4e; read_more(r/7f3a9c1b2d4e, from=601)]',
      );
    });

    test('default bash policy cuts by estimated tokens', () async {
      final body = 'x' * 40;
      final r = storeLines(dir, [for (var i = 1; i <= 5000; i++) '$body$i']);

      final out = await composeResult(
        'bash',
        ResultStatus.ok,
        'noisy',
        r.descriptor,
        r.file,
      );

      final lines = out.split('\n');
      expect(lines[1], '${body}1');
      expect(
        lines.any((l) => RegExp(r'^\[… [\d,]+ lines omitted …\]$').hasMatch(l)),
        isTrue,
      );
      expect(lines[lines.length - 2], '${body}5000');
      expect(lines.last, startsWith('[truncated: showing lines 1–'));
    });

    test('2 GiB newline-free line is cut with bounded memory', () async {
      const size = 2 * 1024 * 1024 * 1024;
      final file = File('${dir.path}${Platform.pathSeparator}huge.bin');
      try {
        // A short readable prefix, then a sparse (zero-filled) remainder.
        final raf = file.openSync(mode: FileMode.write);
        raf.writeFromSync(List.filled(8192, 0x61));
        raf.truncateSync(size);
        raf.closeSync();
      } on FileSystemException catch (e) {
        markTestSkipped('cannot create a 2 GiB temp file: ${e.message}');
        return;
      }
      final descriptor = ResultDescriptor(
        handle: testHandle,
        sha256: '0' * 64,
        bytes: size,
        lines: 1,
      );
      final stats = ScanStats();
      final watch = Stopwatch()..start();

      final out = await composeResult(
        'read',
        ResultStatus.ok,
        'huge.bin',
        descriptor,
        file,
        policy: ResultPolicy.read,
        stats: stats,
      );

      printOnFailure('2 GiB compose took ${watch.elapsed}');
      final lines = out.split('\n');
      expect(lines, hasLength(2));
      expect(
        lines.last,
        endsWith('[line truncated: showing 2,000 of 2,147,483,648 chars]'),
      );
      expect(lines.last, startsWith('a' * 2000));
      expect(out, isNot(contains('[truncated:')));
      expect(stats.maxRetainedBytes, lessThanOrEqualTo(2000 * 4 + 64 * 1024));
      expect(stats.bufferBytes, 64 * 1024);
    }, timeout: const Timeout(Duration(minutes: 10)));

    test('notrunc within capacity shows everything', () async {
      final long = 'y' * 5000;
      final r = storeLines(dir, [
        for (var i = 1; i <= 3000; i++) i == 1500 ? long : 'line $i',
      ]);

      final out = await composeResult(
        'read',
        ResultStatus.ok,
        'all.txt',
        r.descriptor,
        r.file,
        policy: ResultPolicy.read,
        notrunc: true,
        capacityTokens: 100000,
      );

      final lines = out.split('\n');
      expect(lines, hasLength(3001));
      expect(lines[1500], long);
      expect(lines.last, 'line 3000');
      expect(out, isNot(contains('[truncated:')));
      expect(out, isNot(contains('[line truncated:')));
    });

    test('notrunc over capacity fails explicitly', () async {
      final r = storeLines(dir, [for (var i = 1; i <= 3000; i++) 'line $i']);
      final estimate = (r.descriptor.bytes + 2) ~/ 3;

      await expectLater(
        composeResult(
          'read',
          ResultStatus.ok,
          'all.txt',
          r.descriptor,
          r.file,
          notrunc: true,
          capacityTokens: 1000,
        ),
        throwsA(
          isA<ComposeError>().having(
            (e) => e.message,
            'message',
            'notrunc result of $estimate tokens exceeds capacity 1000; '
                'use read_more',
          ),
        ),
      );
    });
  });

  group('line scanner', () {
    test('strips CR before LF across read boundaries, keeps bytes', () async {
      final bytes = [
        ...List.filled(65535, 0x61),
        0x0d,
        0x0a,
        ...utf8.encode('b\r\nlast'),
      ];
      final r = storeBytes(dir, bytes);

      final lines = await scanLines(r.file, retainBytes: 1 << 20).toList();

      expect(lines.map((l) => l.number), [1, 2, 3]);
      expect(lines[0].text, 'a' * 65535);
      expect(lines[0].totalBytes, 65535);
      expect(lines[1].text, 'b');
      expect(lines[2].text, 'last');
      expect(r.descriptor.lines, 3);
    });
  });

  group('review round 1', () {
    test(
      'a line-capped read stops reading after the last shown line',
      () async {
        final r = storeBytes(dir, [
          ...utf8.encode('short\n' * 400),
          ...List.filled(4 << 20, 0x61),
        ]);
        final stats = ScanStats();

        final out = await composeResult(
          'read',
          ResultStatus.ok,
          's',
          r.descriptor,
          r.file,
          policy: ResultPolicy.read,
          stats: stats,
        );

        expect(out.split('\n'), hasLength(402));
        expect(out, contains('showing lines 1–400 of 401'));
        expect(stats.bytesRead, lessThanOrEqualTo(2 * scanBufferBytes));
      },
    );

    test('clipLine clips decoded text whatever the total says', () {
      final text = '\u{FFFD}' * 3000;

      final clipped = clipLine(text, 0);

      expect(clipped.runes.length, lessThan(2100));
      expect(clipped, startsWith('\u{FFFD}' * 2000));
      expect(
        clipped,
        endsWith(' [line truncated: showing 2,000 of 3,000 chars]'),
      );
    });
  });

  group('review round 2', () {
    test('stray continuation bytes clipped on decode are marked', () async {
      final r = storeBytes(dir, [
        ...List.filled(3000, 0x80),
        ...utf8.encode('ERROR'),
      ]);

      final out = await composeResult(
        'read',
        ResultStatus.ok,
        's',
        r.descriptor,
        r.file,
        policy: ResultPolicy.read,
      );

      final line = out.split('\n')[1];
      expect(line, startsWith('\u{FFFD}' * 2000));
      expect(line, endsWith(' [line truncated: showing 2,000 of 3,005 chars]'));
    });
  });

  group('review round 3', () {
    for (final tool in ['other', 'bash']) {
      test('$tool: bytes that grow on decode are cut to the budget', () async {
        final r = storeBytes(dir, [
          for (var i = 0; i < 12000; i++) ...[0x80, 0x0a],
        ]);
        expect(estimateTokens(r.descriptor.bytes), 8000);

        final out = await composeResult(
          tool,
          ResultStatus.ok,
          's',
          r.descriptor,
          r.file,
        );

        final lines = out.split('\n');
        final body = lines.sublist(1, lines.length - 1);
        final rendered = body.fold(0, (n, l) => n + utf8.encode(l).length + 1);
        expect(estimateTokens(rendered), lessThanOrEqualTo(8000));
        expect(body, everyElement(anyOf('\u{FFFD}', startsWith('[…'))));
        expect(lines.last, startsWith('[truncated: showing lines 1–'));
      });
    }
  });
}
