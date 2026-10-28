/// Migrates a session journal to the current format.
///
/// ```sh
/// dart run tool/migrate_journal.dart --session <dir> [--to <n>] [--check]
/// ```
library;

import 'dart:io';

import 'package:kehai/src/session/migration.dart';

Future<void> main(List<String> args) async {
  exitCode = await runMigrateJournal(args, productionMigrations);
}
