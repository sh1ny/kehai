import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:kehai/src/tools/child_env.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/answerer_support.dart';
import '../support/fake_bin.dart';
import '../support/session_support.dart';

/// A directory holding real `pwd` and `env` programs, or null.
///
/// On POSIX that is `/usr/bin` or `/bin`; on Windows the `usr\bin` of the
/// detected Git for Windows.
String? _realBin(ShellInfo? shell) {
  if (!Platform.isWindows) {
    for (final dir in ['/usr/bin', '/bin']) {
      if (File(p.join(dir, 'pwd')).existsSync() &&
          File(p.join(dir, 'env')).existsSync()) {
        return dir;
      }
    }
    return null;
  }
  if (shell == null || shell.kind != ShellKind.gitBash) return null;
  final bin = p.join(p.dirname(p.dirname(shell.executable)), 'usr', 'bin');
  return File(p.join(bin, 'pwd.exe')).existsSync() &&
          File(p.join(bin, 'env.exe')).existsSync()
      ? bin
      : null;
}

/// [path] as Git Bash and POSIX shells read it: forward slashes.
String _posixPath(String path) => Platform.isWindows
    ? Uri.decodeComponent(p.toUri(path).path.substring(1))
    : path;

void main() {
  late Directory root;
  late Directory ws;
  late Directory outside;

  setUp(() async {
    root = await tempDir();
    ws = Directory(p.join(root.path, 'ws'))..createSync();
    File(p.join(ws.path, 'README.md')).writeAsStringSync('x');
    outside = fakeBin(Directory(p.join(root.path, 'bin')), ['cat', 'jj']);
  });

  Map<String, String> envWith(String path, [Map<String, String>? extra]) => {
    for (final e in Platform.environment.entries)
      if (e.key.toUpperCase() != 'PATH') e.key: e.value,
    'PATH': path,
    ...?extra,
  };

  group('BASH_ENV script does not run for autoapproved pwd', () {
    final shell = detectShell().shell;
    final real = _realBin(shell);
    final skip = real == null
        ? 'no pwd and env programs (Git for Windows usr/bin or /usr/bin)'
        : false;

    test('BASH_ENV script does not run for autoapproved pwd', () async {
      final marker = File(p.join(ws.path, 'pwned.txt'));
      final script = File(p.join(ws.path, 'evil.sh'))
        ..writeAsStringSync("echo pwned > '${_posixPath(marker.path)}'\n");
      final env = envWith(real!, {'BASH_ENV': _posixPath(script.path)});

      // Control: the same environment through a shell does run the script, so
      // the absence below proves the direct path, not a broken script.
      if (shell != null && shell.isPosix) {
        final control = await startShell(
          shell,
          'pwd',
          workingDirectory: ws.path,
          environment: env,
        );
        await control.process.stdout.drain<void>();
        await control.process.stderr.drain<void>();
        await control.process.exitCode;
        expect(marker.existsSync(), isTrue, reason: 'control must fire');
        marker.deleteSync();
      }

      final proven = proveReadOnly('pwd', workspaceRoot: ws.path)!;
      final result = await runDirect(
        proven.argv,
        cwd: proven.cwd,
        workspaceRoot: ws.path,
        environment: env,
        setsid: shell?.setsid,
      );

      expect(result.exitCode, 0);
      expect(result.stdout.trim(), isNotEmpty);
      if (!Platform.isWindows) {
        expect(result.stdout.trim(), p.canonicalize(proven.cwd));
      }
      expect(marker.existsSync(), isFalse);
    }, skip: skip);

    test('startup variables are stripped from the direct child', () async {
      final env = envWith(real!, {
        'BASH_ENV': '/x',
        'ENV': '/x',
        'SHELLOPTS': 'xtrace',
        'BASHOPTS': 'extglob',
        'RIPGREP_CONFIG_PATH': '/x',
        'BASH_FUNC_evil%%': '() { :; }',
        'OPENAI_API_KEY': 'sk-x',
        'GH_TOKEN': 'g',
      });

      final result = await runDirect(
        ['env'],
        cwd: ws.path,
        workspaceRoot: ws.path,
        environment: env,
        passthrough: const ['ENV_NOT_THERE'],
      );

      final names = {
        for (final line in const LineSplitter().convert(result.stdout))
          if (line.contains('=')) line.substring(0, line.indexOf('=')),
      };
      expect(names, contains('GH_TOKEN'));
      for (final gone in [
        'BASH_ENV',
        'ENV',
        'SHELLOPTS',
        'BASHOPTS',
        'RIPGREP_CONFIG_PATH',
        'BASH_FUNC_evil%%',
        'OPENAI_API_KEY',
      ]) {
        expect(names, isNot(contains(gone)), reason: gone);
      }
    }, skip: skip);
  });

  test('the environment table drops startup variables by name', () {
    final env = directEnvironment({
      'PATH': '/bin',
      'bash_env': '/x',
      'Env': '/x',
      'SHELLOPTS': 'a',
      'bashopts': 'b',
      'ripgrep_config_path': '/c',
      'BASH_FUNC_f%%': '() { :; }',
      'bash_func_g%%': '() { :; }',
      'BASH_VERSION': 'kept',
      'ENVIRONMENT': 'kept',
    });
    expect(env, {
      'PATH': '/bin',
      'BASH_VERSION': 'kept',
      'ENVIRONMENT': 'kept',
    });
  });

  group('workspace cat on PATH is skipped or the call is prompted', () {
    String listOf(Iterable<String> dirs) =>
        dirs.join(Platform.isWindows ? ';' : ':');

    test('workspace cat on PATH is skipped or the call is prompted', () async {
      final shadow = fakeBin(Directory(p.join(ws.path, 'tools')), ['cat']);
      final cat = Platform.isWindows ? 'cat.exe' : 'cat';

      // A workspace directory, then `.`, then an outside one: the outside
      // `cat` is the one that resolves.
      final skipped = resolveProgram(
        'cat',
        workspaceRoot: ws.path,
        environment: envWith(listOf([shadow.path, '.', 'tools', outside.path])),
      );
      expect(skipped, p.join(outside.path, cat));

      // Only workspace entries (or relative ones): nothing resolves.
      for (final path in [
        listOf([shadow.path]),
        listOf(['.', 'tools', '']),
        listOf([ws.path]),
      ]) {
        expect(
          resolveProgram(
            'cat',
            workspaceRoot: ws.path,
            environment: envWith(path),
          ),
          isNull,
          reason: path,
        );
      }

      // The call goes to the prompt instead of running directly.
      final answerer = RecordingAnswerer();
      final channel = PromptChannel(answerer);
      final home = Directory(p.join(root.path, 'home'))..createSync();
      PermissionGate gate(String path, {UserConfig? config}) => PermissionGate(
        workspace: ws,
        kehaiHome: home,
        prompts: channel,
        config: config ?? const UserConfig(),
        posixShell: true,
        environment: envWith(path),
      );
      StageCall call(String id, String command) => StageCall(
        tool: 'bash',
        callKey: callKey(id),
        callId: id,
        input: {'command': command},
      );

      final ok = await gate(outside.path)
          .check(call('a', 'cat README.md'), CancelToken());
      expect(ok.record, {'decision': 'allow', 'by': 'builtin', 'rule': 'cat'});

      final pending = gate(listOf([shadow.path, '.']))
          .check(call('b', 'cat README.md'), CancelToken());
      final item = await answerer.item(0);
      expect(item.tool, 'bash');
      channel.reply(item.key, 'deny');
      expect((await pending).denyReason, isNotNull);

      // A user rule does not bypass the resolution either.
      const jj = UserConfig(
        allow: [
          AllowRule('bash', ['jj', 'status']),
        ],
      );
      final viaRule = await gate(
        outside.path,
        config: jj,
      ).check(call('c', 'jj status'), CancelToken());
      expect(viaRule.record, containsPair('by', 'user'));
      final pendingRule = gate(
        listOf([shadow.path]),
        config: jj,
      ).check(call('d', 'jj status'), CancelToken());
      final ruleItem = await answerer.item(1);
      channel.reply(ruleItem.key, 'deny');
      expect((await pendingRule).denyReason, isNotNull);

      // Direct exec itself refuses an unresolvable program.
      await expectLater(
        runDirect(
          ['cat', 'README.md'],
          cwd: ws.path,
          workspaceRoot: ws.path,
          environment: envWith(shadow.path),
        ),
        throwsA(isA<DirectExecRefused>()),
      );
    });

    test('a program with a path separator never resolves', () {
      expect(
        resolveProgram(
          './cat',
          workspaceRoot: ws.path,
          environment: envWith(outside.path),
        ),
        isNull,
      );
    });

    test(
      'an outside symlink to a workspace program is skipped',
      () {
        final target = fakeBin(Directory(p.join(ws.path, 'real')), ['lsx']);
        final link = Link(p.join(outside.path, 'lsx'))
          ..createSync(p.join(target.path, 'lsx'));
        expect(link.existsSync(), isTrue);
        expect(
          resolveProgram(
            'lsx',
            workspaceRoot: ws.path,
            environment: envWith(outside.path),
          ),
          isNull,
        );
      },
      skip: Platform.isWindows ? 'symlinks need privileges on Windows' : false,
    );
  });
}
