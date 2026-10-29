/// Running an autoapproved command without a shell (design D7).
///
/// A command the built-in proof or a user rule approved is run as its
/// tokenized argv: no shell, so no `BASH_ENV`, startup file or imported
/// function runs. Its program resolves only through absolute `PATH` entries
/// outside the workspace; when none does, the call goes to the prompt.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../permissions/workspace_paths.dart';
import '../tools/child_env.dart';
import 'detect.dart';
import 'launch.dart';

/// The suffixes a Windows program may carry; scripts are never run directly.
const List<String> _windowsSuffixes = ['.exe', '.com'];

/// The absolute path of [program], or null when it does not resolve.
///
/// Only absolute `PATH` entries of [environment] count, and only those whose
/// real path lies outside [workspaceRoot], so a `.` entry or a workspace
/// directory cannot shadow a program. A candidate whose real path is inside
/// the workspace (a link into it) is skipped too. A [program] that contains a
/// path separator is never resolved. [windows] defaults to the host platform.
String? resolveProgram(
  String program, {
  required String workspaceRoot,
  required Map<String, String> environment,
  bool? windows,
}) {
  final onWindows = windows ?? Platform.isWindows;
  final context = onWindows ? p.windows : p.posix;
  if (program.isEmpty || program.contains('/') || program.contains(r'\')) {
    return null;
  }
  final root = realPath(workspaceRoot);
  if (root == null) return null;
  final names = onWindows
      ? [
          if (_windowsSuffixes.contains(
            context.extension(program).toLowerCase(),
          ))
            program
          else
            for (final suffix in _windowsSuffixes) '$program$suffix',
        ]
      : [program];
  for (final dir in absolutePathEntries(environment, windows: onWindows)) {
    final realDir = realPath(dir);
    if (realDir == null || isInside(root, realDir)) continue;
    for (final name in names) {
      final candidate = context.join(dir, name);
      if (!_isExecutable(candidate, onWindows)) continue;
      final real = realPath(candidate);
      if (real == null || isInside(root, real)) continue;
      return candidate;
    }
  }
  return null;
}

bool _isExecutable(String path, bool windows) {
  final stat = FileStat.statSync(path);
  if (stat.type != FileSystemEntityType.file) return false;
  // 0x49 is the execute bit for owner, group and others.
  return windows || stat.mode & 0x49 != 0;
}

/// A command could not run directly: its program does not resolve.
final class DirectExecRefused implements Exception {
  /// Creates the refusal.
  const DirectExecRefused(this.message);

  /// Why the command was refused.
  final String message;

  @override
  String toString() => 'DirectExecRefused: $message';
}

/// The outcome of [runDirect].
final class DirectResult {
  /// Creates the result.
  const DirectResult(this.exitCode, this.stdout, this.stderr);

  /// The exit code.
  final int exitCode;

  /// Standard output, decoded as UTF-8.
  final String stdout;

  /// Standard error, decoded as UTF-8.
  final String stderr;
}

/// Starts [argv] directly, with no shell, in [cwd].
///
/// [argv] is the proven argv or a user rule's tokenized command. Its program
/// resolves through [resolveProgram] against [environment]'s `PATH`; the
/// child's environment is `directEnvironment` of [environment], with
/// [passthrough] exceptions, and `rg` gets `--no-config`. Stdin is closed.
///
/// Throws [DirectExecRefused] when the program does not resolve.
Future<Process> startDirect(
  List<String> argv, {
  required String cwd,
  required String workspaceRoot,
  required Map<String, String> environment,
  Iterable<String> passthrough = const [],
  String? setsid,
}) async {
  final program = resolveProgram(
    argv.first,
    workspaceRoot: workspaceRoot,
    environment: environment,
  );
  if (program == null) {
    throw DirectExecRefused(
      '${argv.first} does not resolve through an absolute PATH entry outside '
      'the workspace',
    );
  }
  return startProcess(
    program,
    [if (argv.first == 'rg') '--no-config', ...argv.skip(1)],
    workingDirectory: cwd,
    environment: directEnvironment(environment, passthrough: passthrough),
    setsid: Platform.isWindows ? null : setsid,
  );
}

/// Runs [argv] as [startDirect] does and collects its whole output.
Future<DirectResult> runDirect(
  List<String> argv, {
  required String cwd,
  required String workspaceRoot,
  required Map<String, String> environment,
  Iterable<String> passthrough = const [],
  String? setsid,
}) async {
  final process = await startDirect(
    argv,
    cwd: cwd,
    workspaceRoot: workspaceRoot,
    environment: environment,
    passthrough: passthrough,
    setsid: setsid,
  );
  final out = utf8.decodeStream(process.stdout);
  final err = utf8.decodeStream(process.stderr);
  final code = await process.exitCode;
  return DirectResult(code, await out, await err);
}
