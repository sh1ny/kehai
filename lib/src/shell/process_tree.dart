import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../auth/posix_ffi.dart';

/// Sends a signal to a process group and returns zero or an errno.
typedef ProcessGroupSignal = int Function(int pgid, int signal);

/// Sends [signal] to the process group led by [pgid].
int signalProcessGroup(int pgid, int signal) =>
    PosixLibc.instance.kill(-pgid, signal);

String _taskkill() {
  final root =
      Platform.environment['SystemRoot'] ?? Platform.environment['windir'];
  if (root == null) return 'taskkill';
  final path = p.join(root, 'System32', 'taskkill.exe');
  return File(path).existsSync() ? path : 'taskkill';
}

Future<bool> _within(Future<int> future, Duration limit) {
  final result = Completer<bool>();
  final timer = Timer(limit, () {
    if (!result.isCompleted) result.complete(false);
  });
  void ended() {
    timer.cancel();
    if (!result.isCompleted) result.complete(true);
  }

  future.then<void>((_) => ended(), onError: (Object _) => ended());
  return result.future;
}

/// Waits until the process group [pgid] is absent or [limit] expires.
Future<bool> waitForProcessGroup(
  int pgid,
  Duration limit, {
  ProcessGroupSignal signal = signalProcessGroup,
  Duration poll = const Duration(milliseconds: 25),
}) async {
  final clock = Stopwatch()..start();
  while (true) {
    if (signal(pgid, 0) == 3) return true;
    if (clock.elapsed >= limit) return false;
    await Future<void>.delayed(poll);
  }
}

/// Terminates a process tree and reports whether its descendants are gone.
///
/// Callers with a request deadline must issue this operation without awaiting
/// it. Windows cannot verify descendants after taskkill, so its result remains
/// uncertain even when taskkill succeeds.
Future<({String cleanup, bool forced})> terminateProcessTree(
  Process process, {
  required bool groupKnown,
  bool? windows,
  ProcessGroupSignal signal = signalProcessGroup,
  Duration grace = const Duration(seconds: 2),
  Duration probe = const Duration(seconds: 1),
  Duration poll = const Duration(milliseconds: 25),
}) async {
  if (windows ?? Platform.isWindows) {
    try {
      await Process.run(_taskkill(), ['/PID', '${process.pid}', '/T', '/F']);
    } on ProcessException {
      process.kill();
    }
    return (cleanup: 'uncertain: descendants not verifiable', forced: false);
  }
  if (!groupKnown) {
    process.kill();
    final forced = !await _within(process.exitCode, grace);
    if (forced) process.kill(ProcessSignal.sigkill);
    return (cleanup: 'uncertain: process group not known', forced: forced);
  }
  const esrch = 3;
  final pgid = process.pid;
  final clock = Stopwatch()..start();
  while (signal(pgid, 15) == esrch) {
    if (await _within(process.exitCode, poll)) {
      return (cleanup: 'confirmed', forced: false);
    }
    if (clock.elapsed >= grace) {
      process.kill(ProcessSignal.sigkill);
      return (
        cleanup: 'uncertain: process group not established',
        forced: true,
      );
    }
  }
  if (await waitForProcessGroup(pgid, grace, signal: signal, poll: poll)) {
    return (cleanup: 'confirmed', forced: false);
  }
  signal(pgid, 9);
  return (
    cleanup: await waitForProcessGroup(pgid, probe, signal: signal, poll: poll)
        ? 'confirmed'
        : 'uncertain: group still present',
    forced: true,
  );
}
