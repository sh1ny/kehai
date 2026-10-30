import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// An engine process running `test/fixtures/killed_exchange.dart`, parked in
/// the middle of the first step of request `r9`.
final class KilledExchange {
  KilledExchange._(this.process, this.dir);

  /// The `dart run` process.
  final Process process;

  /// The session directory.
  final Directory dir;

  bool _killed = false;

  /// Kills the engine without any chance to clean up.
  Future<void> kill() async {
    if (_killed) return;
    _killed = true;
    if (Platform.isWindows) {
      // The tree of the `dart run` process holds the fixture.
      Process.runSync('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
    } else {
      process.kill(ProcessSignal.sigkill);
    }
    await process.exitCode;
  }
}

/// Starts the fixture for [workspace] with its session under [sessions] and
/// returns once the exchange is mid-step. The process is killed when the test
/// ends.
Future<KilledExchange> startKilledExchange({
  required Directory sessions,
  required Directory workspace,
}) async {
  final process = await Process.start(Platform.resolvedExecutable, [
    'run',
    'test/fixtures/killed_exchange.dart',
    sessions.path,
    workspace.path,
  ]);
  unawaited(process.stderr.drain<void>());
  final lines = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter());
  KilledExchange? run;
  addTearDown(() async {
    if (run != null) {
      await run.kill();
    } else if (Platform.isWindows) {
      Process.runSync('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
    } else {
      process.kill(ProcessSignal.sigkill);
    }
  });
  final line = await lines
      .firstWhere((l) => l.startsWith('READY '))
      .timeout(
        const Duration(seconds: 90),
        onTimeout: () => fail('the killed-exchange fixture never got ready'),
      );
  return run = KilledExchange._(
    process,
    Directory(line.split(' ').skip(2).join(' ')),
  );
}
