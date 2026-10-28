import 'dart:io';

import 'package:kehai/src/results/descriptor.dart';
import 'package:kehai/src/results/reader.dart';
import 'package:kehai/src/results/search.dart';
import 'package:test/test.dart';

import '../support/results_support.dart';

void main() {
  late Directory dir;
  late StoredResult stored;
  late ResultSearcher searcher;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('kehai_reader_');
    stored = storeLines(dir, [
      for (var i = 1; i <= 2310; i++)
        (i == 17 || i == 1203 || i == 2200) ? 'FAIL case $i' : 'line $i',
    ]);
    searcher = ResultSearcher();
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test('page and search a stored result', () async {
    final page = await readMore(
      stored.file,
      stored.descriptor,
      from: 401,
      lines: 100,
    );
    final lines = page.split('\n');
    expect(lines.first, startsWith('[read_more ok]'));
    expect(lines.sublist(1, 101), [for (var i = 401; i <= 500; i++) 'line $i']);
    expect(lines, hasLength(102));
    expect(
      lines.last,
      '[truncated: showing lines 401–500 of 2,310; handle r/7f3a9c1b2d4e; '
      'read_more(r/7f3a9c1b2d4e, from=501)]',
    );

    final found = await searcher.searchResult(
      stored.file,
      stored.descriptor,
      'FAIL',
    );
    final hits = found.split('\n').skip(1).toList();
    expect(hits, [
      '17: FAIL case 17',
      '1203: FAIL case 1203',
      '2200: FAIL case 2200',
    ]);
    expect(found, isNot(contains('more')));
  });

  test('out-of-range page and invalid pattern fail', () async {
    await expectLater(
      readMore(stored.file, stored.descriptor, from: 2311),
      throwsA(
        isA<ResultError>().having(
          (e) => e.message,
          'message',
          'from 2311 beyond last line 2310',
        ),
      ),
    );

    await expectLater(
      searcher.searchResult(stored.file, stored.descriptor, '(unclosed'),
      throwsA(
        isA<ResultError>().having(
          (e) => e.message,
          'message',
          startsWith('invalid pattern: '),
        ),
      ),
    );
    expect(searcher.workersSpawned, 0);
  });
}
