// Opens the session directory in argv[0] for writing and holds it.
//
// Modes (argv[1], default `hold`):
//   hold        opens at once.
//   open-on-go  prints `READY`, opens when a line arrives on stdin.
//   gate        creates the ownership gate, prints `GATE <pid>` and stops
//               before writing its content, so the test can kill it there.
//
// Prints `HELD <pid>` (with `TAKEOVER <message>` before it after a takeover)
// or `REFUSED <message>`, then runs until a `close` line arrives on stdin or
// it is killed.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/src/session/ownership.dart';
import 'package:kehai/src/session/writer.dart';

Future<void> main(List<String> args) async {
  // Keep the isolate alive while waiting on a future nothing completes.
  Timer.periodic(const Duration(hours: 1), (_) {});
  final dir = Directory(args[0]);
  final mode = args.length > 1 ? args[1] : 'hold';
  final lines = stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .asBroadcastStream();

  if (mode == 'open-on-go') {
    stdout.writeln('READY');
    await stdout.flush();
    await lines.first;
  }

  final hooks = mode == 'gate'
      ? OwnershipHooks(
          pause: (point) async {
            if (point != 'gate-created') return;
            stdout.writeln('GATE $pid');
            await stdout.flush();
            await Completer<void>().future;
          },
        )
      : null;

  try {
    final writer = await SessionWriter.open(dir, hooks: hooks);
    if (writer.takeover case final takeover?) {
      stdout.writeln('TAKEOVER ${takeover.message}');
    }
    stdout.writeln('HELD $pid');
    await stdout.flush();
    await lines.firstWhere((line) => line == 'close');
    await writer.close();
  } on Object catch (e) {
    stdout.writeln('REFUSED ${e.toString().replaceAll('\n', ' ')}');
    await stdout.flush();
    // Stay alive so the test controls when the process ends.
    await lines.firstWhere((line) => line == 'close', orElse: () => '');
  }
}
