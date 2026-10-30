// A path whose `..` follows a symbolic link must name the same file to the
// permission gate and to the tools (pre-ship F1). POSIX applies `..` to the
// link's target; the tools must not collapse it lexically first.
@TestOn('!windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/job_support.dart' show skipWithoutShell;
import '../support/session_support.dart';
import '../support/tool_support.dart';

void main() {
  late Directory root;
  late Directory ws;
  late Directory outside;
  late Directory home;
  late SessionWriter writer;

  /// `ws/near -> ws/sub/deep` and `ws/far -> outside/deep`.
  ///
  /// `near/../../x` is `ws/x` to POSIX and `root/x` lexically; `far/../x` is
  /// `outside/x` to POSIX and `ws/x` lexically.
  setUp(() async {
    root = Directory((await tempDir()).resolveSymbolicLinksSync())
      ..createSync(recursive: true);
    ws = Directory(p.join(root.path, 'ws'))..createSync();
    outside = Directory(p.join(root.path, 'outside'))..createSync();
    home = Directory(p.join(ws.path, '.kehai-home'))..createSync();
    Directory(p.join(ws.path, 'sub', 'deep')).createSync(recursive: true);
    Directory(p.join(outside.path, 'deep')).createSync();
    Link(p.join(ws.path, 'near')).createSync(p.join(ws.path, 'sub', 'deep'));
    Link(p.join(ws.path, 'far')).createSync(p.join(outside.path, 'deep'));
    File(p.join(ws.path, 'x')).writeAsStringSync('INSIDE-MARK\n');
    File(p.join(outside.path, 'x')).writeAsStringSync('OUTSIDE-MARK\n');
    File(p.join(root.path, 'x')).writeAsStringSync('ROOT-MARK\n');
  });

  Future<ToolRuntime> attach({required bool gated}) async {
    writer = await createWriter(ws);
    final runtime = await ToolRuntime.attach(
      writer,
      ResultStore(writer.sessionDir),
      workspace: ws,
      kehaiHome: home,
      gate: gated ? null : const AllowAllStage(),
    );
    addTearDown(runtime.close);
    return runtime;
  }

  Future<String> call(ToolRuntime runtime, String tool, Object input) async {
    final item = await runtime.run(
      ToolCall(
        callId: 'c${tool.hashCode}${input.hashCode}',
        name: tool,
        argumentsJson: jsonEncode(input),
      ),
    );
    return item.output;
  }

  String jobCwd() {
    final jobs = writer.tree.get(SessionPath.parse('jobs'))! as Map;
    return (jobs.values.single as Map)['cwd']! as String;
  }

  test(
    'read follows a link then .. like the gate: inside, no prompt',
    () async {
      final runtime = await attach(gated: true);

      final out = await call(runtime, 'read', {'path': 'near/../../x'});

      expect(out, contains('INSIDE-MARK'));
      expect(out, isNot(contains('ROOT-MARK')));
    },
  );

  test(
    'read of a path leaving the workspace through a link is prompted',
    () async {
      final runtime = await attach(gated: true);

      // Lexically `far/../x` is `ws/x`, which the old code read unprompted.
      final out = await call(runtime, 'read', {'path': 'far/../x'});

      expect(out, startsWith('[read denied]'));
      expect(out, isNot(contains('INSIDE-MARK')));
      expect(out, isNot(contains('OUTSIDE-MARK')));
    },
  );

  test(
    'a link after a missing component and .. is not collapsed past',
    () async {
      File(p.join(outside.path, 'deep', 'secret'))
          .writeAsStringSync('SECRET-MARK\n');
      final runtime = await attach(gated: true);

      // Lexically `missing/../far/secret` is `ws/far/secret`, inside; POSIX
      // never reaches `far`, and opening it lexically follows `far` outside.
      final out = await call(runtime, 'read', {
        'path': 'missing/../far/secret',
      });

      expect(out, startsWith('[read denied]'));
      expect(out, isNot(contains('SECRET-MARK')));
      expect(realPath(p.join(ws.path, 'missing', '..', 'far', 'secret')), null);
    },
  );

  test(
    'write and edit through a link then .. are prompted, not applied',
    () async {
      final runtime = await attach(gated: true);

      final written = await call(runtime, 'write', {
        'path': 'far/../x',
        'content': 'CLOBBER',
      });
      final edited = await call(runtime, 'edit', {
        'path': 'far/../x',
        'anchors': ['1#AAAA'],
        'ops': [
          {'op': 'delete', 'start': 1, 'end': 1},
        ],
      });

      expect(written, startsWith('[write denied]'));
      expect(edited, startsWith('[edit denied]'));
      expect(File(p.join(ws.path, 'x')).readAsStringSync(), 'INSIDE-MARK\n');
      expect(
        File(p.join(outside.path, 'x')).readAsStringSync(),
        'OUTSIDE-MARK\n',
      );
    },
  );

  test(
    'with no gate the tools open the POSIX target, not the lexical one',
    () async {
      final runtime = await attach(gated: false);

      expect(
        await call(runtime, 'read', {'path': 'far/../x'}),
        contains('OUTSIDE-MARK'),
      );
      final edited = await call(runtime, 'edit', {
        'path': 'far/../x',
        'anchors': ['1#AAAA'],
        'ops': [
          {'op': 'delete', 'start': 1, 'end': 1},
        ],
      });
      // The file exists there, so the edit reaches the anchor check.
      expect(edited, isNot(contains('no such file')));
      await call(runtime, 'write', {'path': 'far/../w.txt', 'content': 'W'});
      expect(File(p.join(outside.path, 'w.txt')).readAsStringSync(), 'W');
      expect(File(p.join(ws.path, 'w.txt')).existsSync(), isFalse);

      // A file that does not exist yet resolves through its parent's real path.
      await call(runtime, 'write', {
        'path': 'far/../new/n.txt',
        'content': 'N',
      });
      expect(File(p.join(outside.path, 'new', 'n.txt')).existsSync(), isTrue);
      expect(File(p.join(ws.path, 'new', 'n.txt')).existsSync(), isFalse);
    },
  );

  // `cwd: near/..` is `ws/sub` to POSIX and the gate; the workspace root
  // lexically. The directory bash runs in must be the one the gate proved.
  test(
    'bash cwd follows a link then .. like the gate: builtin direct path',
    () async {
      final runtime = await attach(gated: true);

      final out = await call(runtime, 'bash', {
        'command': 'pwd',
        'cwd': 'near/..',
      });

      expect(out, contains(p.join(ws.path, 'sub')));
      expect(out, isNot(contains('${ws.path}\n')));
      expect(jobCwd(), p.join(ws.path, 'sub'));
    },
    skip: skipWithoutShell(),
  );

  test('bash cwd follows a link then .. like the gate: shell path', () async {
    final runtime = await attach(gated: false);

    final out = await call(runtime, 'bash', {
      'command': 'pwd && true',
      'cwd': 'near/..',
    });

    expect(out, contains(p.join(ws.path, 'sub')));
    expect(jobCwd(), p.join(ws.path, 'sub'));
  }, skip: skipWithoutShell());

  test('ls, grep and find resolve path the way the gate does', () async {
    final rg = await resolveRg(
      configPath: 'config.json',
      workspaceRoot: Directory.systemTemp.path,
    ) as RgFound;
    File(p.join(outside.path, 'only-outside.txt')).writeAsStringSync('o');

    final lsOut = RecordingOutput();
    await const LsTool().run(toolContext(ws, lsOut), {'path': 'far/..'});
    expect(lsOut.lines, contains('only-outside.txt'));

    final grepOut = RecordingOutput();
    await GrepTool(Future.value(rg))
        .run(toolContext(ws, grepOut), {'pattern': '-MARK', 'path': 'far/..'});
    expect(grepOut.lines.join('\n'), contains('OUTSIDE-MARK'));
    expect(grepOut.lines.join('\n'), isNot(contains('INSIDE-MARK')));

    final findOut = RecordingOutput();
    await FindTool(Future.value(rg))
        .run(toolContext(ws, findOut), {'glob': '*.txt', 'path': 'far/..'});
    expect(findOut.lines.join('\n'), contains('only-outside.txt'));
  });
}
