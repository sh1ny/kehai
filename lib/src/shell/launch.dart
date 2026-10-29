/// Launching processes for the tools (design D7).
///
/// Every process the shell tool, the hooks and the direct-exec path start goes
/// through [startProcess]: stdin is closed at once, the environment is exactly
/// the one given, and on POSIX the process leads its own session through
/// `setsid` so its whole group can be terminated.
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
/// Throws a [ProcessException] when the process cannot start.
Future<Process> startProcess(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required Map<String, String> environment,
  String? setsid,
}) async {
  final process = await Process.start(
    setsid ?? executable,
    setsid == null ? arguments : [executable, ...arguments],
    workingDirectory: workingDirectory,
    environment: environment,
    includeParentEnvironment: false,
  );
  unawaited(process.stdin.close().then<void>((_) {}, onError: (Object _) {}));
  return process;
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
