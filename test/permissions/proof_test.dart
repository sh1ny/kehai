import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/session_support.dart';

void main() {
  late Directory root;
  late Directory ws;

  setUp(() async {
    root = await tempDir();
    ws = Directory(p.join(root.path, 'ws'))..createSync();
    Directory(p.join(ws.path, 'lib')).createSync();
    Directory(p.join(ws.path, 'sub')).createSync();
    Directory(p.join(root.path, 'other')).createSync();
    File(p.join(ws.path, 'README.md')).writeAsStringSync('x');
  });

  ProvenCommand? prove(String command, {String? cwd}) =>
      proveReadOnly(command, workspaceRoot: ws.path, cwd: cwd);

  group('listed program with listed options', () {
    test(
      'listed program with listed options inside the workspace is proven',
      () {
        final rg = prove('rg -n TODO lib')!;
        expect(rg.argv, ['rg', '-n', 'TODO', 'lib']);
        expect(rg.program, 'rg');
        expect(p.equals(rg.cwd, realPath(ws.path)!), isTrue);

        final commands = [
          'pwd',
          'ls',
          'ls -la lib',
          'ls -a -l -1 -h -R -t -r -S',
          'cat README.md',
          'cat -n -A README.md lib/../README.md',
          'head README.md',
          'head -n 5 README.md',
          'head -n5 README.md',
          'head -c 10 README.md',
          'tail -n 3 README.md',
          'tail -c3 README.md',
          'wc -l -w -c -m README.md',
          'wc -lw README.md',
          "cat 'README.md'",
          'cat "README.md"',
          'rg -n -i -S -F -w -l -c -v TODO',
          'rg --hidden --no-ignore TODO lib',
          'rg --files lib',
          'rg -e TODO -e FIXME lib',
          'rg -eTODO lib',
          'rg -A 2 -B2 -C 3 -m 4 TODO',
          'rg -t dart TODO',
          'rg --type dart TODO',
          'rg --type=dart TODO',
          'rg -g x.dart TODO',
          'rg --glob=x.dart TODO',
          'rg -f README.md lib',
          'rg -fREADME.md lib',
          'rg --file README.md lib',
          'rg --file=README.md lib',
          "rg 'a b' lib",
          'rg   -n\tTODO   lib',
        ];
        for (final c in commands) {
          expect(prove(c), isNotNull, reason: c);
        }
      },
    );

    test('operands resolve from the effective cwd', () {
      expect(prove('cat README.md', cwd: '.'), isNotNull);
      expect(prove('cat ../README.md', cwd: 'sub'), isNotNull);
      expect(prove('cat README.md', cwd: 'sub'), isNotNull);
      final proven = prove('ls', cwd: 'lib')!;
      expect(p.equals(proven.cwd, realPath(p.join(ws.path, 'lib'))!), isTrue);
      expect(prove('cat ../../other/x', cwd: 'sub'), isNull);
    });

    test('attached quoting forms join into one word', () {
      expect(tokenizeSimple("cat 'a'\"b\"c"), ['cat', 'abc']);
      expect(tokenizeSimple("rg '' lib"), ['rg', '', 'lib']);
      expect(tokenizeSimple("rg 'a;b|c\$d' lib"), ['rg', 'a;b|c\$d', 'lib']);
      expect(tokenizeSimple('rg "a;b|c" lib'), ['rg', 'a;b|c', 'lib']);
    });
  });

  group('shape', () {
    test('separators, substitution, redirection, --pre and escapes are not '
        'proven', () {
      final unproven = [
        'cat README.md; rm -rf build',
        'cat README.md && ls',
        'cat README.md || ls',
        'cat README.md | wc -l',
        'cat README.md & ls',
        'cat \$(ls)',
        'cat `ls`',
        'cat \$HOME',
        'cat "\$HOME"',
        'cat "`ls`"',
        'cat "\\x"',
        'cat \\x',
        'ls > out.txt',
        'ls >> out.txt',
        'cat < README.md',
        '(ls)',
        'ls (',
        'ls )',
        'ls\nrm x',
        'ls\r',
        'cat ~/x',
        'cat ~',
        'cat *.md',
        'cat READ?E.md',
        'cat READ[M]E.md',
        'cat {a,b}',
        'cat }',
        "cat '*.md'",
        'FOO=1 cat README.md',
        'A_b=c ls',
        'rg --pre ./x foo',
        'rg --pre=./x foo',
        'rg --pre-glob "*.x" foo',
        'rg -z foo',
        'rg --search-zip foo',
        'rg -nz foo',
        'cat README.md #',
        'cat "unterminated',
        "cat 'unterminated",
        '',
        '   ',
        'rm README.md',
        'sed -n 1p README.md',
        'git status',
        'echo hi',
        'bash -c ls',
        './cat README.md',
        '/bin/cat README.md',
        'cat -',
      ];
      for (final c in unproven) {
        expect(prove(c), isNull, reason: c);
      }
    });

    test('each forbidden character outside single quotes fails', () {
      for (final ch in [
        ';',
        '&',
        '|',
        '<',
        '>',
        '(',
        ')',
        r'$',
        '`',
        '\n',
        '~',
        '*',
        '?',
        '[',
        '{',
        r'\',
      ]) {
        expect(tokenizeSimple('ls a${ch}b'), isNull, reason: 'x${ch}x');
      }
      for (final ch in [';', '&', '|', '<', '>', '(', ')', r'$', '`', '~']) {
        expect(tokenizeSimple("ls 'a${ch}b'"), ['ls', 'a${ch}b'], reason: ch);
      }
    });

    test('tokenizer accepts a plain command', () {
      expect(tokenizeSimple('jj status --no-pager'), [
        'jj',
        'status',
        '--no-pager',
      ]);
      expect(tokenizeSimple('jj status && jj git push'), isNull);
    });
  });

  group('options and paths', () {
    test(
      'option operands, unlisted options and outside cwd are not proven',
      () {
        final unproven = [
          'rg -f/etc/passwd x',
          'rg --file=../list x',
          'rg --file ../list x',
          'rg -f ../list x',
          'rg --unknown-flag x',
          'rg -Q x',
          'rg --hidden=1 x',
          'rg -e',
          'rg --glob',
          'rg',
          'rg --files ../other',
          'cat ../../.ssh/id_rsa',
          'cat ../README.md',
          'cat /etc/passwd',
          'cat /etc/passwd README.md',
          'ls ..',
          'ls -X',
          'ls --color',
          'ls -la -z',
          'cat -x README.md',
          'cat',
          'head -5 README.md',
          'head -n',
          'head -v README.md',
          'tail -f README.md',
          'tail -F README.md',
          'tail -n 3 -f README.md',
          'tail --follow README.md',
          'tail --retry README.md',
          'tail -f',
          'wc',
          'wc -L README.md',
          'wc --files0-from=x README.md',
          'pwd -P',
          'pwd lib',
          'pwd -L',
          'cat -- README.md',
          'ls -- lib',
        ];
        for (final c in unproven) {
          expect(prove(c), isNull, reason: c);
        }
        expect(prove('cat notes.txt', cwd: '../other'), isNull);
        expect(prove('pwd', cwd: '../other'), isNull);
        expect(prove('pwd', cwd: '../../'), isNull);
        expect(prove('pwd', cwd: p.join(root.path, 'other')), isNull);
        expect(prove('pwd', cwd: 'missing-dir'), isNull);
      },
    );

    test('an absolute operand inside the workspace is proven', () {
      final inside = p.join(ws.path, 'README.md');
      expect(prove("cat '$inside'"), isNotNull);
      expect(prove("rg -f '$inside' x"), isNotNull);
    });

    test('a symlink leaving the workspace is not proven', () {
      final target = Directory(p.join(root.path, 'other'));
      File(p.join(target.path, 'secret.txt')).writeAsStringSync('s');
      try {
        Link(p.join(ws.path, 'out')).createSync(target.path);
      } on FileSystemException {
        markTestSkipped('symbolic links need privileges here');
        return;
      }

      expect(prove('cat out/secret.txt'), isNull);
      expect(prove('ls out'), isNull);
      expect(prove('pwd', cwd: 'out'), isNull);
      expect(
        prove('cat out/../README.md'),
        Platform.isWindows ? isNotNull : isNull,
        reason: 'Windows resolves .. lexically, POSIX through the link',
      );
    });

    test('a dangling symlink is not proven', () {
      try {
        Link(p.join(ws.path, 'dangling'))
            .createSync(p.join(root.path, 'nowhere'));
      } on FileSystemException {
        markTestSkipped('symbolic links need privileges here');
        return;
      }

      expect(prove('cat dangling'), isNull);
    });

    test('paths compare case-insensitively on Windows only', () {
      final upper = ws.path.toUpperCase();
      final proven = proveReadOnly('cat README.md', workspaceRoot: upper);
      expect(proven != null, Platform.isWindows);
    });
  });
}
