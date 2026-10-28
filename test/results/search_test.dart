import 'dart:convert';
import 'dart:io';

import 'package:kehai/src/results/descriptor.dart';
import 'package:kehai/src/results/search.dart';
import 'package:test/test.dart';

import '../support/results_support.dart';

Matcher _resultError(Object message) =>
    throwsA(isA<ResultError>().having((e) => e.message, 'message', message));

void main() {
  late Directory dir;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('kehai_search_');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  test(
    'pathological pattern times out and huge line states its prefix',
    () async {
      final bad = storeLines(dir, ['${'a' * 60}b'], name: 'bad.bin');
      final watch = Stopwatch()..start();

      await expectLater(
        ResultSearcher().searchResult(bad.file, bad.descriptor, r'(a+)+$'),
        _resultError('search timed out after 5s; narrow the pattern'),
      );

      expect(watch.elapsed, greaterThanOrEqualTo(const Duration(seconds: 5)));
      expect(watch.elapsed, lessThan(const Duration(seconds: 15)));

      final huge = storeBytes(dir, [
        ...utf8.encode('FAIL'),
        ...List.filled(99996, 0x78),
        0x0a,
        ...utf8.encode('FAIL two\n'),
      ], name: 'huge.bin');

      final out = await ResultSearcher().searchResult(
        huge.file,
        huge.descriptor,
        'FAIL',
      );

      expect(out, contains('line 1 searched first 65536 of 100000 bytes'));
      expect(out, contains('\n2: FAIL two'));
      expect(out, contains('\n1: FAIL'));
      expect(out.length, lessThan(10000));
    },
  );

  group('match cap', () {
    Future<String> searchLines(int count) {
      final stored = storeLines(dir, [
        for (var i = 0; i < count; i++) 'hit $i',
      ], name: 'cap$count.bin');
      return ResultSearcher().searchResult(
        stored.file,
        stored.descriptor,
        'hit',
      );
    }

    int shown(String out) =>
        RegExp(r'^\d+: hit', multiLine: true).allMatches(out).length;

    test('200 matches render 200 lines and no more line', () async {
      final out = await searchLines(200);
      expect(shown(out), 200);
      expect(out, isNot(contains('more')));
    });

    test('201 matches render 200 lines and "+1 more"', () async {
      final out = await searchLines(201);
      expect(shown(out), 200);
      expect(out, contains('\n… +1 more'));
    });

    test('250 matches render 200 lines and "+50 more"', () async {
      final out = await searchLines(250);
      expect(shown(out), 200);
      expect(out, contains('\n… +50 more'));
    });
  });

  test('search burst over the limit is rejected and slots are freed', () async {
    final bad = storeLines(dir, ['${'a' * 60}b'], name: 'bad.bin');
    final ok = storeLines(dir, ['one', 'two FAIL'], name: 'ok.bin');
    final searcher = ResultSearcher(timeout: const Duration(seconds: 1));

    final running = [
      for (var i = 0; i < 4; i++)
        searcher.searchResult(bad.file, bad.descriptor, r'(a+)+$'),
    ];
    final settled = [
      for (final f in running)
        expectLater(
          f,
          _resultError('search timed out after 1s; narrow the pattern'),
        ),
    ];

    final watch = Stopwatch()..start();
    await expectLater(
      searcher.searchResult(bad.file, bad.descriptor, r'(a+)+$'),
      _resultError('search busy'),
    );
    expect(watch.elapsed, lessThan(const Duration(milliseconds: 500)));
    expect(searcher.workersSpawned, 4);

    await Future.wait(settled);

    final out = await searcher.searchResult(ok.file, ok.descriptor, 'FAIL');
    expect(out.split('\n').last, '2: two FAIL');
    expect(searcher.workersSpawned, 5);
  });
}
