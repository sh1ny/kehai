import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:kehai/src/tools/child_env.dart';
import 'package:kehai/src/tools/glob_match.dart' show GlobMatcher;
import 'package:kehai/src/tools/search.dart' show SearchLineRewriter;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/session_support.dart';
import '../support/tool_support.dart';

const String _configPath = 'HOME/config.json';

final RegExp _version = RegExp(r'^\d+\.\d+\.\d+');

Future<(ToolOutcome, RecordingOutput)> _run(
  Tool tool,
  Directory ws,
  Map<String, Object?> input, {
  CancelToken? cancel,
}) async {
  final output = RecordingOutput();
  final outcome = await tool.run(
    toolContext(ws, output, cancel: cancel),
    input,
  );
  return (outcome, output);
}

void main() {
  late Directory ws;
  late RgFound rg;
  setUpAll(() async {
    final found = await resolveRg(
      configPath: _configPath,
      workspaceRoot: Directory.systemTemp.path,
    );
    expect(found, isA<RgFound>(), reason: 'rg must be on PATH to run tests');
    rg = found as RgFound;
  });
  setUp(() async => ws = await tempDir());

  File put(String name, String text) => File(p.join(ws.path, name))
    ..createSync(recursive: true)
    ..writeAsStringSync(text);

  Tool grep() => GrepTool(Future.value(rg));
  Tool find() => FindTool(Future.value(rg));

  group('resolution', () {
    test('rg resolves from rgPath or PATH and passes --version', () async {
      expect(rg.version, matches(_version));
      expect(p.isAbsolute(rg.path), isTrue);

      final explicit = await resolveRg(
        rgPath: rg.path,
        configPath: _configPath,
        workspaceRoot: ws.path,
        environment: {'PATH': ''},
      );
      expect(explicit, isA<RgFound>());
      expect((explicit as RgFound).path, rg.path);
      expect(explicit.version, rg.version);

      final viaPath = await resolveRg(
        configPath: _configPath,
        workspaceRoot: ws.path,
        environment: {'PATH': p.dirname(rg.path)},
      );
      expect(viaPath, isA<RgFound>());
      expect((viaPath as RgFound).version, rg.version);

      // A file that is not rg fails --version and is not accepted.
      final fake = put('not-rg.txt', 'hello');
      final bad = await resolveRg(
        rgPath: fake.path,
        configPath: _configPath,
        workspaceRoot: ws.path,
      );
      expect(bad, isA<RgMissing>());
    });

    group('discovery never runs a repository program', () {
      /// A copy of the real rg at `dir/rg`, so it runs and reports a version.
      File copyRg(Directory dir) {
        dir.createSync(recursive: true);
        return File(rg.path)
            .copySync(p.join(dir.path, Platform.isWindows ? 'rg.exe' : 'rg'));
      }

      test('a relative PATH entry is skipped', () async {
        final inside = Directory(p.join(ws.path, 'bin'));
        copyRg(inside);
        final before = Directory.current;
        Directory.current = ws.path;
        try {
          for (final entry in ['.', 'bin', '']) {
            final found = await resolveRg(
              configPath: _configPath,
              workspaceRoot: ws.path,
              environment: {'PATH': entry},
            );
            expect(found, isA<RgMissing>(), reason: 'entry "$entry"');
          }
          copyRg(ws);
          final dot = await resolveRg(
            configPath: _configPath,
            workspaceRoot: ws.path,
            environment: {'PATH': '.'},
          );
          expect(dot, isA<RgMissing>());
        } finally {
          Directory.current = before;
        }
      });

      test('a workspace rg that shadows an outside one is skipped', () async {
        final inside = copyRg(Directory(p.join(ws.path, 'shadow')));
        final outsideDir = await tempDir();
        final outside = copyRg(outsideDir);
        final separator = Platform.isWindows ? ';' : ':';

        final found = await resolveRg(
          configPath: _configPath,
          workspaceRoot: ws.path,
          environment: {
            'PATH': [p.dirname(inside.path), outsideDir.path].join(separator),
          },
        );
        expect(found, isA<RgFound>());
        expect((found as RgFound).path, outside.path);

        final onlyInside = await resolveRg(
          configPath: _configPath,
          workspaceRoot: ws.path,
          environment: {'PATH': p.dirname(inside.path)},
        );
        expect(onlyInside, isA<RgMissing>());
      });

      test('a workspace rg is never executed during discovery', () async {
        final marker = p.join(ws.path, 'ran');
        final dir = Directory(p.join(ws.path, 'evil'))..createSync();
        final script = File(p.join(dir.path, 'rg'))
          ..writeAsStringSync(
            '#!/bin/sh\ntouch "$marker"\necho "ripgrep 1.0.0"\n',
          );
        Process.runSync('chmod', ['755', script.path]);

        final found = await resolveRg(
          configPath: _configPath,
          workspaceRoot: ws.path,
          environment: {'PATH': dir.path},
        );

        expect(found, isA<RgMissing>());
        expect(File(marker).existsSync(), isFalse);
      }, skip: Platform.isWindows ? 'needs a POSIX script' : false);

      // Feedback round 4: a bare configured name is looked up like the
      // default, never by the OS, which would search the workspace too.
      test('a bare configured rgPath resolves outside the workspace', () async {
        final inside = copyRg(Directory(p.join(ws.path, 'bin')));
        final outsideDir = await tempDir();
        final outside = copyRg(outsideDir);

        final shadowed = await resolveRg(
          rgPath: 'rg',
          configPath: _configPath,
          workspaceRoot: ws.path,
          environment: {'PATH': p.dirname(inside.path)},
        );
        expect(shadowed, isA<RgMissing>());

        final found = await resolveRg(
          rgPath: 'rg',
          configPath: _configPath,
          workspaceRoot: ws.path,
          environment: {'PATH': outsideDir.path},
        );
        expect(found, isA<RgFound>());
        expect((found as RgFound).path, outside.path);
      });

      test('a configured rgPath inside the workspace still works', () async {
        final inside = copyRg(Directory(p.join(ws.path, 'mine')));

        final found = await resolveRg(
          rgPath: inside.path,
          configPath: _configPath,
          workspaceRoot: ws.path,
          environment: {'PATH': ''},
        );

        expect(found, isA<RgFound>());
        expect((found as RgFound).path, inside.path);
      });

      test('a relative rgPath resolves against the workspace root', () async {
        final inside = copyRg(Directory(p.join(ws.path, 'tools')));
        final relative = p.join('tools', p.basename(inside.path));
        File(p.join(ws.path, 'sub', 'a.txt'))
          ..createSync(recursive: true)
          ..writeAsStringSync('needle\n');

        final found = await resolveRg(
          rgPath: relative,
          configPath: _configPath,
          workspaceRoot: ws.path,
          environment: {'PATH': ''},
        );

        expect(found, isA<RgFound>());
        expect((found as RgFound).path, inside.path);
        // A search from a subdirectory runs the same executable.
        final (outcome, output) = await _run(
          GrepTool(Future.value(found)),
          ws,
          {'pattern': 'needle', 'path': 'sub'},
        );
        expect(outcome.status, ResultStatus.ok, reason: outcome.summary);
        expect(output.lines, ['sub/a.txt:1: needle']);
      });
    });

    test(
      'missing rg fails with the install hint naming the config path',
      () async {
        final empty = Directory(p.join(ws.path, 'empty'))..createSync();
        final missing = [
          await resolveRg(
            configPath: _configPath,
            workspaceRoot: ws.path,
            environment: {'PATH': empty.path},
          ),
          await resolveRg(
            rgPath: p.join(ws.path, 'no-such-rg'),
            configPath: _configPath,
            workspaceRoot: ws.path,
          ),
        ];
        put('a.txt', 'needle\n');
        for (final resolution in missing) {
          expect(resolution, isA<RgMissing>());
          for (final tool in [
            GrepTool(Future.value(resolution)),
            FindTool(Future.value(resolution)),
          ]) {
            final (outcome, output) = await _run(tool, ws, {
              'pattern': 'needle',
              'glob': '*.txt',
            });
            expect(outcome.status, ResultStatus.error);
            expect(
              outcome.summary,
              'rg not found; install ripgrep or set rgPath in $_configPath',
            );
            expect(output.total, 0);
          }
        }
      },
    );

    test('attach resolves rg once; a missing rg only fails the call', () async {
      final home = Directory(p.join(ws.path, 'khome'))..createSync();
      final work = Directory(p.join(ws.path, 'work'))..createSync();
      File(p.join(work.path, 'a.txt')).writeAsStringSync('needle\n');
      Future<ToolRuntime> attach(UserConfig config) async {
        final writer = await createWriter(ws);
        final runtime = await ToolRuntime.attach(
          writer,
          ResultStore(writer.sessionDir),
          workspace: work,
          kehaiHome: home,
          config: config,
          yolo: true,
        );
        addTearDown(runtime.close);
        return runtime;
      }

      Future<String> grepVia(ToolRuntime runtime, String id) async =>
          (await runtime.run(
            ToolCall(
              callId: id,
              name: 'grep',
              argumentsJson: jsonEncode({'pattern': 'needle'}),
            ),
          )).output;

      final good = await grepVia(await attach(const UserConfig()), 'g1');
      expect(good, contains('a.txt:1: needle'));
      expect(good, contains('rg ${rg.version}'));

      final bad = await grepVia(
        await attach(UserConfig(rgPath: p.join(ws.path, 'no-such-rg'))),
        'g2',
      );
      expect(
        bad,
        contains(
          'rg not found; install ripgrep or set rgPath in '
          '${p.join(home.path, 'config.json')}',
        ),
      );
    });

    test('a child never inherits RIPGREP_CONFIG_PATH', () {
      final env = childEnvironment({
        'PATH': '/bin',
        'RIPGREP_CONFIG_PATH': '/x',
        'ripgrep_config_path': '/y',
        'HOME': '/h',
      });
      expect(env, {'PATH': '/bin', 'HOME': '/h'});
    });
  });

  group('rewriter', () {
    test('rewrites path\\0line:text across any chunk boundary', () {
      final input = utf8.encode(
        'a.dart\x003:  x: y\nsub${Platform.isWindows ? r'\' : '/'}b.dart\x0012:z\n'
        './c.dart\x001:é\n',
      );
      const want = 'a.dart:3:   x: y\nsub/b.dart:12: z\nc.dart:1: é\n';
      for (var cut = 0; cut <= input.length; cut++) {
        final rewriter = SearchLineRewriter(grep: true);
        final out = [
          ...rewriter.add(input.sublist(0, cut)),
          ...rewriter.add(input.sublist(cut)),
          ...rewriter.finish(),
        ];
        expect(utf8.decode(out), want, reason: 'cut at $cut');
        expect(rewriter.lines, 3);
        expect(rewriter.files, 3);
      }
    });

    test('edge lines keep their rewrite across any chunk boundary', () {
      // No NUL, empty lines, a bare NUL, a number without a colon, a colon
      // without a number, a 20-digit number (the longest a line number can
      // be), and an unterminated last line.
      final input = utf8.encode(
        'bare\n\nx.dart\x00\nx.dart\x00123\nx.dart\x00:t\n'
        'x.dart\x0012:\nx.dart\x0012345678901234567890:z\n'
        'x.dart\x007:last',
      );
      const want =
          'bare\nx.dart: \nx.dart: 123\nx.dart: :t\nx.dart:12: \n'
          'x.dart:12345678901234567890: z\nx.dart:7: last\n';
      for (var cut = 0; cut <= input.length; cut++) {
        final rewriter = SearchLineRewriter(grep: true);
        final out = [
          ...rewriter.add(input.sublist(0, cut)),
          ...rewriter.add(input.sublist(cut)),
          ...rewriter.finish(),
        ];
        expect(utf8.decode(out), want, reason: 'cut at $cut');
        expect(rewriter.lines, 7);
        expect(rewriter.files, 2);
      }
    });

    test('a filter drops a line and its text across any chunk boundary', () {
      final input = utf8.encode(
        'a.dart\x001:keep\nb.txt\x002:drop\nc.dart\x003:k\n',
      );
      for (var cut = 0; cut <= input.length; cut++) {
        final rewriter = SearchLineRewriter(
          grep: true,
          filter: GlobMatcher('*.dart'),
        );
        final out = [
          ...rewriter.add(input.sublist(0, cut)),
          ...rewriter.add(input.sublist(cut)),
          ...rewriter.finish(),
        ];
        expect(utf8.decode(out), 'a.dart:1: keep\nc.dart:3: k\n');
        expect(rewriter.lines, 2);
      }
    });

    test('one very long line is streamed with bounded retention', () {
      const size = 16 * 1024 * 1024;
      const piece = 64 * 1024;
      final rewriter = SearchLineRewriter(grep: true, prefix: 'src');
      final body = List<int>.filled(piece, 0x78);
      var emitted = 0;
      var peak = 0;
      final head = rewriter.add(utf8.encode('long.txt\x0042:'));
      expect(utf8.decode(head), 'src/long.txt:42: ');
      for (var sent = 0; sent < size; sent += piece) {
        emitted += rewriter.add(body).length;
        peak = peak > rewriter.retainedBytes ? peak : rewriter.retainedBytes;
      }
      final tail = rewriter.add(const [0x0a]);
      expect(emitted, size);
      expect(tail, const [0x0a]);
      expect(peak, lessThan(64), reason: 'only a header is ever retained');
      expect(rewriter.lines, 1);

      // A header split across chunks is held only until its NUL arrives.
      final split = SearchLineRewriter(grep: true);
      expect(split.add(utf8.encode('some/path')), isEmpty);
      expect(split.retainedBytes, 9);
      expect(utf8.decode(split.add(utf8.encode('\x005:x'))), 'some/path:5: x');
      expect(split.retainedBytes, 0);
    });

    test('prefixes the root and passes bare paths for find', () {
      final grepR = SearchLineRewriter(grep: true, prefix: 'lib');
      expect(
        utf8.decode([
          ...grepR.add(utf8.encode('a.dart\x001:t\n')),
          ...grepR.finish(),
        ]),
        'lib/a.dart:1: t\n',
      );
      final findR = SearchLineRewriter(grep: false, prefix: 'test');
      expect(
        utf8.decode([
          ...findR.add(utf8.encode('a_test.dart\nb_test.dart')),
          ...findR.finish(),
        ]),
        'test/a_test.dart\ntest/b_test.dart\n',
      );
    });
  });

  group('grep', () {
    test('grep renders path:line: text from --null output', () async {
      put(
        'lib/src/session/writer.dart',
        'library;\n\n// x\nfinal class SessionWriter {\n  int a = 1;\n}\n',
      );
      put('lib/src/other.dart', 'class Other {}\n');
      put('README.md', 'SessionWriter docs\n');

      final (outcome, output) = await _run(grep(), ws, {
        'pattern': 'class SessionWriter',
        'path': 'lib',
      });
      expect(outcome.status, ResultStatus.ok);
      expect(outcome.complete, isTrue);
      expect(output.lines, [
        'lib/src/session/writer.dart:4: final class SessionWriter {',
      ]);
      expect(outcome.summary, '1 match in 1 file (rg ${rg.version})');

      // An approved directory outside the workspace is still rendered
      // relative to the workspace root.
      final sibling = Directory(
        p.join(p.dirname(ws.path), '${p.basename(ws.path)}-sibling'),
      )..createSync();
      addTearDown(() => sibling.deleteSync(recursive: true));
      File(p.join(sibling.path, 'o.txt')).writeAsStringSync('needle\n');
      final up = '../${p.basename(sibling.path)}';
      final (_, outsideGrep) = await _run(grep(), ws, {
        'pattern': 'needle',
        'path': up,
      });
      expect(outsideGrep.lines, ['$up/o.txt:1: needle']);
      final (_, outsideFind) = await _run(find(), ws, {
        'glob': '*.txt',
        'path': up,
      });
      expect(outsideFind.lines, ['$up/o.txt']);

      // No path searches the workspace root.
      final (whole, wholeOut) = await _run(grep(), ws, {'pattern': 'Session'});
      expect(whole.summary, '2 matches in 2 files (rg ${rg.version})');
      expect(wholeOut.lines.toSet(), {
        'lib/src/session/writer.dart:4: final class SessionWriter {',
        'README.md:1: SessionWriter docs',
      });

      // Flags and glob.
      final (flags, flagsOut) = await _run(grep(), ws, {
        'pattern': 'SESSIONWRITER',
        'ignore_case': true,
        'glob': '*.md',
      });
      expect(flagsOut.lines, ['README.md:1: SessionWriter docs']);
      expect(flags.status, ResultStatus.ok);

      put('lit.txt', 'a.b\naxb\n');
      final (_, regexOut) = await _run(grep(), ws, {
        'pattern': 'a.b',
        'glob': 'lit.txt',
      });
      expect(regexOut.lines, ['lit.txt:1: a.b', 'lit.txt:2: axb']);
      final (_, literalOut) = await _run(grep(), ws, {
        'pattern': 'a.b',
        'literal': true,
        'glob': 'lit.txt',
      });
      expect(literalOut.lines, ['lit.txt:1: a.b']);

      // A file as the search path.
      final (_, fileOut) = await _run(grep(), ws, {
        'pattern': 'Session',
        'path': 'README.md',
      });
      expect(fileOut.lines, ['README.md:1: SessionWriter docs']);

      // A glob never overrides ignore files, and a glob that drops every
      // line the search found gives no matches.
      put('.ignore', 'skipped.md\n');
      put('skipped.md', 'SessionWriter skipped\n');
      final (_, globbed) = await _run(grep(), ws, {
        'pattern': 'SessionWriter',
        'glob': '*.md',
      });
      expect(globbed.lines, ['README.md:1: SessionWriter docs']);
      final (dropped, droppedOut) = await _run(grep(), ws, {
        'pattern': 'SessionWriter',
        'glob': '*.nothing',
      });
      expect(dropped.status, ResultStatus.ok);
      expect(dropped.summary, 'no matches');
      expect(droppedOut.total, 0);
    });

    test('rg exit 1 is ok and exit 2 is error with stderr', () async {
      put('a.txt', 'hello\n');

      final (none, noneOut) = await _run(grep(), ws, {'pattern': 'absent'});
      expect(none.status, ResultStatus.ok);
      expect(none.complete, isTrue);
      expect(none.summary, 'no matches');
      expect(noneOut.total, 0);

      final (bad, _) = await _run(grep(), ws, {'pattern': '('});
      expect(bad.status, ResultStatus.error);
      expect(bad.summary, contains('regex parse error'));
      expect(bad.summary, contains('unclosed group'));
      expect(bad.summary, isNot(contains('\n')));
    });

    test('missing search path is an error', () async {
      final unusable = GrepTool(
        Future.value(RgFound(p.join(ws.path, 'never-started'), '0')),
      );
      final (outcome, output) = await _run(unusable, ws, {
        'pattern': 'x',
        'path': 'nope',
      });
      expect(outcome.status, ResultStatus.error);
      expect(outcome.summary, 'no such directory nope');
      expect(output.total, 0);
    });

    test('a cancelled call stops without searching', () async {
      final token = CancelToken()..cancel();
      put('a.txt', 'hello\n');
      final (outcome, output) = await _run(grep(), ws, {
        'pattern': 'hello',
      }, cancel: token);
      expect(outcome.status, ResultStatus.error);
      expect(outcome.complete, isFalse);
      expect(outcome.summary, startsWith('cancelled'));
      expect(output.total, 0);
    });
  });

  group('find', () {
    test('find lists test files through rg --files', () async {
      put('test/session/journal_test.dart', '');
      put('test/a_test.dart', '');
      put('test/helper.dart', '');
      put('lib/x_test.dart', '');

      final (outcome, output) = await _run(find(), ws, {
        'glob': '**/*_test.dart',
        'path': 'test',
      });
      expect(outcome.status, ResultStatus.ok);
      expect(output.lines.toSet(), {
        'test/session/journal_test.dart',
        'test/a_test.dart',
      });
      expect(outcome.summary, startsWith('2 files'));

      // A glob never overrides ignore files or hidden rules.
      put('.ignore', 'ignored_test.dart\n');
      put('test/ignored_test.dart', '');
      put('test/.hid_test.dart', '');
      Future<Set<String>> listed(Map<String, Object?> extra) async {
        final (o, out) = await _run(find(), ws, {
          'glob': '**/*_test.dart',
          'path': 'test',
          ...extra,
        });
        expect(o.status, ResultStatus.ok);
        return out.lines.toSet();
      }

      expect(await listed({}), output.lines.toSet());
      expect(await listed({'hidden': true}), {
        ...output.lines,
        'test/.hid_test.dart',
      });
      expect(await listed({'no_ignore': true}), {
        ...output.lines,
        'test/ignored_test.dart',
      });
    });

    test('missing search path is an error', () async {
      final unusable = FindTool(
        Future.value(RgFound(p.join(ws.path, 'never-started'), '0')),
      );
      final (outcome, output) = await _run(unusable, ws, {
        'glob': '*',
        'path': 'nope',
      });
      expect(outcome.status, ResultStatus.error);
      expect(outcome.summary, 'no such directory nope');
      expect(output.total, 0);
    });
  });

  group('ls', () {
    test('ls sorts entries with / and @ suffixes', () async {
      put('lib/kehai.dart', '');
      put('lib/src/a.dart', '');
      put('lib/.hidden', '');
      put('lib/Zeta.txt', '');
      var linked = true;
      try {
        Link(p.join(ws.path, 'lib', 'link')).createSync('kehai.dart');
      } on FileSystemException {
        linked = false; // Windows without symbolic link rights
      }

      final (outcome, output) = await _run(const LsTool(), ws, {'path': 'lib'});
      expect(outcome.status, ResultStatus.ok);
      expect(output.lines, [
        '.hidden',
        'Zeta.txt',
        'kehai.dart',
        if (linked) 'link@',
        'src/',
      ]);
      expect(outcome.summary, contains('${linked ? 5 : 4} entries'));

      final (_, nested) = await _run(const LsTool(), ws, {});
      expect(nested.lines, ['lib/']);
    });

    test('ls on a file is an error', () async {
      put('a.txt', 'x');
      final (file, fileOut) = await _run(const LsTool(), ws, {'path': 'a.txt'});
      expect(file.status, ResultStatus.error);
      expect(file.summary, 'a.txt is not a directory');
      final (missing, _) = await _run(const LsTool(), ws, {'path': 'nope'});
      expect(missing.status, ResultStatus.error);
      expect(missing.summary, 'no such directory nope');
      expect(fileOut.total, 0);
    });
  });
}
