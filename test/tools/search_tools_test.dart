import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:kehai/src/tools/child_env.dart';
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
    final found = await resolveRg(configPath: _configPath);
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
        environment: {'PATH': ''},
      );
      expect(explicit, isA<RgFound>());
      expect((explicit as RgFound).path, rg.path);
      expect(explicit.version, rg.version);

      final viaPath = await resolveRg(
        configPath: _configPath,
        environment: {'PATH': p.dirname(rg.path)},
      );
      expect(viaPath, isA<RgFound>());
      expect((viaPath as RgFound).version, rg.version);

      // A file that is not rg fails --version and is not accepted.
      final fake = put('not-rg.txt', 'hello');
      final bad = await resolveRg(rgPath: fake.path, configPath: _configPath);
      expect(bad, isA<RgMissing>());
    });

    test(
      'missing rg fails with the install hint naming the config path',
      () async {
        final empty = Directory(p.join(ws.path, 'empty'))..createSync();
        final missing = [
          await resolveRg(
            configPath: _configPath,
            environment: {'PATH': empty.path},
          ),
          await resolveRg(
            rgPath: p.join(ws.path, 'no-such-rg'),
            configPath: _configPath,
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
