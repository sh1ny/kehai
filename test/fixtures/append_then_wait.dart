// Creates a session under the directory in argv[0], appends one record, prints
// `ACKED <sessionDir> <pid>` once the append is acknowledged, then waits until
// it is killed. Used by the crash test.
import 'dart:async';
import 'dart:io';

import 'package:kehai/kehai.dart';

Future<void> main(List<String> args) async {
  final writer = await SessionWriter.create(Directory(args.single));
  await writer.apply(
    const JournalRecord(
      turn: 1,
      path: 'body/crash',
      op: Op.set,
      value: 'acked',
    ),
  );
  stdout.writeln('ACKED ${writer.sessionDir.path} $pid');
  await stdout.flush();
  // Keep the isolate alive until the parent kills the process.
  Timer.periodic(const Duration(hours: 1), (_) {});
  await Completer<void>().future;
}
