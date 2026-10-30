import 'dart:io';

import 'package:kehai/src/cli/cli.dart';

Future<void> main(List<String> args) async {
  final code = await runCli(args);
  // End the process explicitly. On Windows a cancelled read of standard input
  // (login's paste listener) can stay pending and keep the process alive.
  try {
    await stdout.flush();
    await stderr.flush();
  } on Object {
    // A closed output pipe cannot be flushed; exit anyway.
  }
  exit(code);
}
