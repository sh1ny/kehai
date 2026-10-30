import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/session_support.dart';

Future<(int, String)> _run(
  ShellInfo shell,
  String command, {
  bool noSetsid = false,
}) async {
  final cwd = (await tempDir()).path;
  final started = await startShell(
    noSetsid
        ? ShellInfo(kind: shell.kind, executable: shell.executable)
        : shell,
    command,
    workingDirectory: cwd,
    environment: Platform.environment,
  );
  final out = utf8.decodeStream(started.process.stdout);
  await started.process.stderr.drain<void>();
  final code = await started.process.exitCode;
  expect(
    started.groupKnown,
    !noSetsid && shell.setsid != null,
    reason: 'groupKnown',
  );
  return (code, (await out));
}

void main() {
  final shell = detectShell().shell;
  final posix = shell != null && shell.isPosix;
  final skip = posix ? false : 'no POSIX shell on this host';

  test('shell arguments follow the shell kind', () {
    const bash = ShellInfo(kind: ShellKind.bash, executable: '/bin/bash');
    const git = ShellInfo(kind: ShellKind.gitBash, executable: r'C:\b.exe');
    const pwsh = ShellInfo(kind: ShellKind.pwsh, executable: r'C:\pwsh.exe');
    const ps = ShellInfo(
      kind: ShellKind.powershell,
      executable: r'C:\powershell.exe',
    );
    expect(shellArguments(bash, 'ls -l'), ['-c', 'ls -l']);
    expect(shellArguments(git, 'ls'), ['-c', 'ls']);
    for (final s in [pwsh, ps]) {
      expect(shellArguments(s, 'Get-Date'), [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        'Get-Date',
      ]);
    }
  });

  test('stdin is closed: a reading command sees end of file', () async {
    final (code, out) = await _run(shell!, 'cat; echo done');
    expect(code, 0);
    expect(out.trim(), 'done');
  }, skip: skip);

  test('a shell with setsid leads its own process group', () async {
    final (code, out) = await _run(shell!, r'ps -o pgid= -p $$; echo $$');
    expect(code, 0);
    final lines = out.trim().split(RegExp(r'\s+'));
    expect(lines[0], lines[1], reason: 'pgid equals pid');
  }, skip: !posix || shell.setsid == null ? 'needs bash and setsid' : false);

  test('without setsid the launch is direct and the group uncertain', () async {
    final (code, out) = await _run(shell!, 'echo hi', noSetsid: true);
    expect(code, 0);
    expect(out.trim(), 'hi');
  }, skip: skip);
}
