import 'package:kehai/src/tools/glob_match.dart';
import 'package:test/test.dart';

void _check(
  String glob, {
  List<String> yes = const [],
  List<String> no = const [],
}) {
  final m = GlobMatcher(glob);
  for (final path in yes) {
    expect(m.matches(path), isTrue, reason: '$glob should match $path');
  }
  for (final path in no) {
    expect(m.matches(path), isFalse, reason: '$glob should not match $path');
  }
}

void main() {
  group('GlobMatcher', () {
    test('a glob without a slash matches the basename at any depth', () {
      _check(
        '*.dart',
        yes: ['a.dart', 'lib/a.dart', 'a/b/c.dart'],
        no: ['a.dart.txt', 'dart', 'a.dart/b.txt'],
      );
      _check('test', yes: ['test', 'x/test'], no: ['tests', 'test/a']);
    });

    test('a glob with a slash is anchored to the search root', () {
      _check(
        'lib/*.dart',
        yes: ['lib/a.dart'],
        no: ['x/lib/a.dart', 'lib/s/a.dart'],
      );
      _check('/a.txt', yes: ['a.txt'], no: ['x/a.txt']);
    });

    test('* does not cross a slash and ? matches one character', () {
      _check('a/*', yes: ['a/b'], no: ['a/b/c', 'a']);
      _check(
        'file?.txt',
        yes: ['file1.txt', 'x/fileZ.txt'],
        no: ['file.txt', 'file12.txt'],
      );
    });

    test('** spans any number of segments', () {
      _check(
        '**/*_test.dart',
        yes: ['a_test.dart', 't/a_test.dart', 't/s/a_test.dart'],
        no: ['a.dart', 't/a_test.dart.bak'],
      );
      _check('src/**', yes: ['src/a', 'src/a/b'], no: ['src', 'x/src/a']);
      _check('a/**/b', yes: ['a/b', 'a/x/b', 'a/x/y/b'], no: ['a/xb', 'b']);
      _check('**', yes: ['a', 'a/b/c']);
    });

    test('braces alternate', () {
      _check('*.{ts,tsx}', yes: ['a.ts', 'x/a.tsx'], no: ['a.js', 'a.t']);
      _check(
        '{lib,test}/*.dart',
        yes: ['lib/a.dart', 'test/b.dart'],
        no: ['bin/a.dart'],
      );
      _check('a{b,c{d,e}}f', yes: ['abf', 'acdf', 'acef'], no: ['acf']);
    });

    test('character classes with ranges and negation', () {
      _check('[ab].txt', yes: ['a.txt', 'b.txt'], no: ['c.txt', 'ab.txt']);
      _check('[!ab].txt', yes: ['c.txt'], no: ['a.txt']);
      _check('[^ab].txt', yes: ['c.txt'], no: ['b.txt']);
      _check('[a-c]x', yes: ['bx'], no: ['dx']);
    });

    test('matching is case-sensitive and specials are literal', () {
      _check('*.DART', yes: ['a.DART'], no: ['a.dart']);
      _check('a+b(1).txt', yes: ['a+b(1).txt'], no: ['aab(1).txt']);
      _check(r'\*.txt', yes: ['*.txt'], no: ['a.txt']);
    });
  });
}
