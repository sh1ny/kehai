// Measures how long a trivial hook takes to start and exit: `bash -c true` and
// `pwsh -NoProfile -Command exit`, N runs each (default 50, argv[0]).
//
// Prints the rows of docs/measurements/hook-startup.md:
// `| platform | shell | runs | p50 ms | p95 ms |`. On Windows `bash` is Git
// Bash, found the way the engine finds it. A shell that is not installed gets
// an `unavailable` row. Each run is wall time from spawn to exit, with the
// host environment, as a hook is started.
//
//     dart run tool/measure_hook_startup.dart [runs]
import 'dart:io';

import 'package:kehai/src/shell/detect.dart';

Future<void> main(List<String> args) async {
  final runs = args.isEmpty ? 50 : int.parse(args.first);
  final platform = Platform.isWindows ? 'Windows' : 'Linux';
  final detected = detectShell().shell;
  final bash = detected != null && detected.isPosix ? detected : null;
  final pwsh = findOnPath(
    [Platform.isWindows ? 'pwsh.exe' : 'pwsh'],
    Platform.environment,
    windows: Platform.isWindows,
  );

  await _measure(platform, bash?.name ?? 'bash', bash?.executable, const [
    '-c',
    'true',
  ], runs);
  await _measure(platform, 'pwsh', pwsh, const [
    '-NoProfile',
    '-Command',
    'exit',
  ], runs);
}

Future<void> _measure(
  String platform,
  String shell,
  String? executable,
  List<String> arguments,
  int runs,
) async {
  if (executable == null) {
    stdout.writeln('| $platform | $shell | unavailable | - | - |');
    return;
  }
  final millis = <double>[];
  for (var i = 0; i < runs; i++) {
    final clock = Stopwatch()..start();
    final result = await Process.run(executable, arguments);
    clock.stop();
    if (result.exitCode != 0) {
      stderr.writeln('$shell exited ${result.exitCode}: ${result.stderr}');
      exit(1);
    }
    millis.add(clock.elapsedMicroseconds / 1000);
  }
  millis.sort();
  // Nearest rank: the smallest value with at least p of the runs at or below.
  double rank(double p) => millis[(p * millis.length).ceil() - 1];
  stdout.writeln(
    '| $platform | $shell | $runs | ${rank(0.5).toStringAsFixed(0)} | '
    '${rank(0.95).toStringAsFixed(0)} |',
  );
  stderr.writeln(
    '$platform $shell: min ${millis.first.toStringAsFixed(0)} '
    'max ${millis.last.toStringAsFixed(0)} ms',
  );
}
