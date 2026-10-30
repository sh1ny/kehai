/// Launching processes for the tools (design D7).
///
/// Every process the shell tool, the hooks and the direct-exec path start goes
/// through [startProcess]: stdin is closed at once, the environment is exactly
/// the one given, and on POSIX the process leads its own session through
/// `setsid` so its whole group can be terminated. A hook gets its call as
/// `input` on stdin first.
library;

import 'dart:async';
import 'dart:io';

import 'detect.dart';

/// A started shell command.
final class ShellProcess {
  /// Wraps the started [process].
  const ShellProcess(this.process, {required this.groupKnown});

  /// The process, with stdin already closed.
  final Process process;

  /// Whether the process leads its own process group (pid = pgid), so group
  /// termination is reliable. False means termination is `uncertain`.
  final bool groupKnown;
}

/// Starts [executable] with [arguments] in [workingDirectory], with exactly
/// [environment], and closes its stdin.
///
/// With [setsid] the command is launched as `setsid <executable> ...`. Kehai's
/// child is not a group leader, so `setsid` execs in place: the process keeps
/// its pid, which is then also its process-group id.
///
/// With [input] the bytes are written to stdin before it is closed. The write
/// never blocks the caller or throws: a process that exits without reading it
/// is not an error.
///
/// Throws a [ProcessException] when the process cannot start.
Future<Process> startProcess(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required Map<String, String> environment,
  String? setsid,
  List<int>? input,
}) async {
  if (setsid != null) {
    _requireRunnable(executable, arguments, workingDirectory, environment);
  }
  final process = await Process.start(
    setsid ?? executable,
    setsid == null ? arguments : [executable, ...arguments],
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: false,
  );
  unawaited(_feed(process, input));
  return process;
}

/// Under `setsid` a program that cannot run is an exit 127 of `setsid`, not a
/// launch failure. This looks for [executable] the way `exec` would, in the
/// child's own `PATH`, and throws the [ProcessException] a direct launch would
/// have thrown: errno 2 when it is missing, 13 when it is not executable.
///
/// The program can still vanish between this check and the `exec`; that race
/// is accepted, and then it shows as exit 127.
void _requireRunnable(
  String executable,
  List<String> arguments,
  String workingDirectory,
  Map<String, String> environment,
) {
  var denied = false;
  bool runnable(String candidate) {
    final stat = FileStat.statSync(candidate);
    if (stat.type == FileSystemEntityType.directory) {
      denied = true;
      return false;
    }
    if (stat.type != FileSystemEntityType.file) return false;
    if (stat.mode & 0x49 == 0) {
      denied = true;
      return false;
    }
    return true;
  }

  // `exec` runs after the working directory changed, so a relative path and
  // an empty or relative `PATH` entry are relative to it.
  String inCwd(String path) =>
      path.startsWith('/') ? path : '$workingDirectory/$path';
  final candidates = executable.contains('/')
      ? [inCwd(executable)]
      : [
          for (final dir
              in (environmentValue(environment, 'PATH') ?? '/usr/bin:/bin')
                  .split(':'))
            '${inCwd(dir.isEmpty ? '.' : dir)}/$executable',
        ];
  if (candidates.any(runnable)) return;
  throw denied
      ? ProcessException(executable, arguments, 'Permission denied', 13)
      : ProcessException(executable, arguments, 'No such file or directory', 2);
}

Future<void> _feed(Process process, List<int>? input) async {
  try {
    if (input != null) process.stdin.add(input);
    await process.stdin.close();
  } on Object {
    // The process closed its stdin or died; nothing is lost by it.
  }
}

/// The arguments that make [shell] run [command]: `-c <command>` for bash,
/// `-NoProfile -NonInteractive -Command <command>` for PowerShell.
List<String> shellArguments(ShellInfo shell, String command) => shell.isPosix
    ? ['-c', command]
    : ['-NoProfile', '-NonInteractive', '-Command', command];

/// Starts [command] through [shell] in [workingDirectory], with exactly
/// [environment] (build it with `shellEnvironment`).
Future<ShellProcess> startShell(
  ShellInfo shell,
  String command, {
  required String workingDirectory,
  required Map<String, String> environment,
}) async {
  final setsid = shell.isPosix && !Platform.isWindows ? shell.setsid : null;
  final process = await startProcess(
    shell.executable,
    shellArguments(shell, command),
    workingDirectory: workingDirectory,
    environment: environment,
    setsid: setsid,
  );
  return ShellProcess(process, groupKnown: setsid != null);
}
