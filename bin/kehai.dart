import 'dart:io';

import 'package:kehai/src/cli/cli.dart';

Future<void> main(List<String> args) async {
  exitCode = await runCli(args);
}
