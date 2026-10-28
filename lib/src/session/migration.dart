/// Explicit journal migration between format versions.
///
/// A session whose `meta/format` is not current cannot be opened. The
/// migration command rewrites its journal to the current format by applying
/// registered per-record transformations. It keeps the original under
/// `journal.v<n>.jsonl`, writes the new journal through
/// `journal.jsonl.migrating` and executes no recorded effect.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'errors.dart';
import 'journal.dart';
import 'ownership.dart';
import 'record.dart';
import 'state.dart';

/// A pure transformation of one journal record into zero or more records.
typedef RecordMigration = List<JournalRecord> Function(JournalRecord record);

/// The registered `n -> n+1` record transformations.
final class MigrationRegistry {
  /// Creates an empty registry.
  MigrationRegistry();

  final Map<int, RecordMigration> _steps = {};

  /// Registers [step], which migrates records from format [from] to
  /// `from + 1`.
  void register(int from, RecordMigration step) => _steps[from] = step;

  /// Whether every step from format [from] up to format [to] is registered.
  bool hasPath(int from, int to) {
    for (var n = from; n < to; n++) {
      if (!_steps.containsKey(n)) return false;
    }
    return from < to;
  }

  /// Migrates [records] from format [from] to format [to].
  ///
  /// The first output record is the origin, with `meta/format` set to [to].
  List<JournalRecord> migrate(List<JournalRecord> records, int from, int to) {
    var current = records;
    for (var n = from; n < to; n++) {
      final step = _steps[n]!;
      current = [for (final record in current) ...step(record)];
    }
    if (current.isEmpty) {
      throw const SessionError(
        'invalid migrated record',
        'the migration dropped the origin record',
      );
    }
    final origin = current.first;
    final value = origin.value;
    if (origin.path.isNotEmpty || value is! Map<Object?, Object?>) {
      throw const SessionError(
        'invalid migrated record',
        'the first migrated record must be a set at the empty path with a map',
      );
    }
    final meta = value['meta'];
    return [
      JournalRecord(
        turn: origin.turn,
        path: '',
        op: origin.op,
        value: {
          ...value,
          'meta': {if (meta is Map<Object?, Object?>) ...meta, 'format': to},
        },
      ),
      ...current.skip(1),
    ];
  }
}

/// The registry of the shipped migrations. Format 1 is current, so it is empty.
final MigrationRegistry productionMigrations = MigrationRegistry();

/// What one migration run did, or with `check` would do.
final class MigrationReport {
  /// Creates a report.
  const MigrationReport({
    required this.fromFormat,
    required this.toFormat,
    required this.oldRecords,
    required this.newRecords,
    this.torn,
    this.resumed = false,
    this.checkOnly = false,
  });

  /// The format of the original journal.
  final int fromFormat;

  /// The format of the new journal.
  final int toFormat;

  /// The number of complete records in the original journal.
  final int oldRecords;

  /// The number of records in the new journal.
  final int newRecords;

  /// The torn tail of the original, or `null` when it ended on a newline.
  ///
  /// The recovery path is `null` in a check run, which saves nothing.
  final TornTail? torn;

  /// Whether this run completed an interrupted migration.
  final bool resumed;

  /// Whether this was a check run that changed no file.
  final bool checkOnly;

  /// Whether the session was already at the target format.
  bool get unchanged => fromFormat == toFormat && !resumed;
}

final _backupName = RegExp(r'^journal\.v(\d+)\.jsonl$');

/// Migrates the session in [dir] to format [to], the current format by default.
///
/// The session is claimed through [Ownership.claim] and released in all
/// cases. Torn bytes after the last newline are saved to `recovery/` without
/// changing the original; only complete records are migrated. With [check]
/// nothing is written. A session left with a backup and `journal.jsonl.migrating`
/// but no journal is completed. [hooks] and [now] are test seams.
///
/// Throws a [SessionError] with reason `no migration from <n> to <m>` when
/// the registry has no path, `format <n> is newer than this kehai` for a
/// newer session, and a [JournalCorruption] for an invalid committed line.
Future<MigrationReport> migrateSession(
  Directory dir, {
  required MigrationRegistry registry,
  int? to,
  bool check = false,
  OwnershipHooks? hooks,
  DateTime? now,
}) async {
  final target = to ?? sessionFormatVersion;
  if (target > sessionFormatVersion) {
    throw SessionError(
      'format $target is newer than this kehai',
      'this kehai writes format $sessionFormatVersion',
    );
  }
  if (!dir.existsSync()) {
    throw SessionError('session not found', '${dir.path} does not exist');
  }
  final ownership = await Ownership.claim(dir, hooks: hooks);
  try {
    return _migrate(dir, registry, target, check, now);
  } finally {
    await ownership.release();
  }
}

MigrationReport _migrate(
  Directory dir,
  MigrationRegistry registry,
  int target,
  bool check,
  DateTime? now,
) {
  final journal = File(p.join(dir.path, journalFileName));
  final migrating = File(p.join(dir.path, migratingFileName));

  var resumed = false;
  File source = journal;
  File? backup;
  if (!journal.existsSync()) {
    final backups = _backups(dir);
    if (!migrating.existsSync() || backups.isEmpty) {
      throw SessionError('journal not found', '${journal.path} does not exist');
    }
    resumed = true;
    backup = backups.entries.reduce((a, b) => a.key > b.key ? a : b).value;
    source = backup;
  }

  final read = _readSource(source);
  final from = read.format;
  if (from > sessionFormatVersion) {
    throw SessionError(
      'format $from is newer than this kehai',
      'this kehai reads format $sessionFormatVersion',
    );
  }
  if (from == target && !resumed) {
    return MigrationReport(
      fromFormat: from,
      toFormat: target,
      oldRecords: read.records.length,
      newRecords: read.records.length,
      checkOnly: check,
    );
  }
  if (!registry.hasPath(from, target)) {
    throw SessionError(
      'no migration from $from to $target',
      'no registered path in ${dir.path}',
    );
  }
  if (resumed && !_backupName.hasMatch(p.basename(source.path))) {
    throw SessionError('invalid backup', source.path);
  }
  backup ??= File(p.join(dir.path, 'journal.v$from.jsonl'));
  if (!resumed && backup.existsSync()) {
    throw SessionError('backup exists', '${backup.path} already exists');
  }

  final migrated = registry.migrate(read.records, from, target);
  if (target == sessionFormatVersion) _validate(migrated);
  final bytes = utf8.encode(migrated.map((r) => r.encode()).join());

  TornTail? torn;
  if (read.trailing > 0) {
    if (check) {
      torn = TornTail(read.trailing);
    } else {
      torn =
          _existingRecovery(dir, read) ??
          saveTornBytes(dir, source, read.committed, now: now);
    }
  }

  if (!check) {
    final out = migrating.openSync(mode: FileMode.write);
    try {
      out.writeFromSync(bytes);
      out.flushSync();
    } finally {
      out.closeSync();
    }
    if (!resumed) journal.renameSync(backup.path);
    migrating.renameSync(journal.path);
  }
  return MigrationReport(
    fromFormat: from,
    toFormat: target,
    oldRecords: read.records.length,
    newRecords: migrated.length,
    torn: torn,
    resumed: resumed,
    checkOnly: check,
  );
}

/// Checks the migrated [records] with the current-format rules.
void _validate(List<JournalRecord> records) {
  var index = 0;
  try {
    final state = SessionState.fromOrigin(records.first);
    for (final record in records.skip(1)) {
      index++;
      state
        ..validate(record)
        ..commit(record);
    }
  } on SessionError catch (e) {
    throw SessionError(
      'invalid migrated record',
      'record ${index + 1}: ${e.message}',
    );
  }
}

/// The recovery file a previous, interrupted run saved for the same tail.
TornTail? _existingRecovery(Directory dir, _Source read) {
  final recovery = Directory(p.join(dir.path, recoveryDirName));
  if (!recovery.existsSync()) return null;
  final prefix = 'torn-${read.committed}-';
  for (final entity in recovery.listSync()) {
    if (entity is File &&
        p.basename(entity.path).startsWith(prefix) &&
        entity.lengthSync() == read.trailing) {
      return TornTail(read.trailing, recoveryPath: entity.path);
    }
  }
  return null;
}

Map<int, File> _backups(Directory dir) {
  final found = <int, File>{};
  for (final entity in dir.listSync()) {
    if (entity is! File) continue;
    final match = _backupName.firstMatch(p.basename(entity.path));
    if (match != null) found[int.parse(match.group(1)!)] = entity;
  }
  return found;
}

final class _Source {
  const _Source(this.records, this.format, this.committed, this.trailing);

  final List<JournalRecord> records;
  final int format;
  final int committed;
  final int trailing;
}

/// Parses the complete lines of [file], checking only record shape.
_Source _readSource(File file) {
  final bytes = file.readAsBytesSync();
  final committed = bytes.lastIndexOf(0x0A) + 1;
  final records = <JournalRecord>[];
  var start = 0;
  while (start < committed) {
    final end = bytes.indexOf(0x0A, start);
    try {
      try {
        records.add(
          JournalRecord.parse(utf8.decode(bytes.sublist(start, end))),
        );
      } on FormatException catch (e) {
        throw SessionError('invalid record', 'not valid UTF-8: ${e.message}');
      }
    } on SessionError catch (e) {
      throw JournalCorruption(records.length + 1, start, e.reason, e.message);
    }
    start = end + 1;
  }
  final format = records.isEmpty ? null : originFormat(records.first);
  if (format == null) {
    throw const JournalCorruption(
      1,
      0,
      'invalid origin',
      'the origin record has no meta/format',
    );
  }
  return _Source(records, format, committed, bytes.length - committed);
}

const String _usage =
    'Usage: dart run tool/migrate_journal.dart --session <dir> '
    '[--to <n>] [--check]\n'
    '  --session <dir>  the session directory to migrate (required)\n'
    '  --to <n>         the target format (default: current, '
    '$sessionFormatVersion)\n'
    '  --check          report what would change and change no file';

/// Runs the migration command line with [args] and returns the exit code.
///
/// Writes the result to [out] and errors to [err], which default to the
/// process streams. Exit codes: 0 success, 64 usage error, 65 data error
/// (corruption, missing path, locked session), 74 input or output error.
Future<int> runMigrateJournal(
  List<String> args,
  MigrationRegistry registry, {
  StringSink? out,
  StringSink? err,
}) async {
  final stdoutSink = out ?? stdout;
  final stderrSink = err ?? stderr;
  String? session;
  int? to;
  var check = false;
  int usageError(String message) {
    stderrSink
      ..writeln(message)
      ..writeln(_usage);
    return 64;
  }

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    final (name, inline) = switch (arg.indexOf('=')) {
      final eq when eq > 0 && arg.startsWith('--') => (
        arg.substring(0, eq),
        arg.substring(eq + 1),
      ),
      _ => (arg, null),
    };
    String? value() => inline ?? (i + 1 < args.length ? args[++i] : null);
    switch (name) {
      case '--help' || '-h':
        stdoutSink.writeln(_usage);
        return 0;
      case '--check':
        check = true;
      case '--session':
        session = value();
        if (session == null) return usageError('--session needs a directory');
      case '--to':
        final text = value();
        to = text == null ? null : int.tryParse(text);
        if (to == null || to < 0) {
          return usageError('--to needs a non-negative integer');
        }
      default:
        return usageError('unknown argument: $arg');
    }
  }
  if (session == null) return usageError('missing required option --session');

  try {
    final report = await migrateSession(
      Directory(session),
      registry: registry,
      to: to,
      check: check,
    );
    _print(report, stdoutSink);
    return 0;
  } on SessionError catch (e) {
    stderrSink.writeln('error: ${e.message}');
    return 65;
  } on JournalCorruption catch (e) {
    stderrSink.writeln('error: $e');
    return 65;
  } on FileSystemException catch (e) {
    stderrSink.writeln('error: ${e.message}: ${e.path}');
    return 74;
  }
}

void _print(MigrationReport r, StringSink out) {
  if (r.unchanged) {
    out.writeln('already at format ${r.toFormat}; nothing to do');
    return;
  }
  final verb = r.checkOnly ? 'would migrate' : 'migrated';
  out
    ..writeln(
      r.resumed
          ? 'completed interrupted migration to format ${r.toFormat}'
          : '$verb format ${r.fromFormat} -> ${r.toFormat}',
    )
    ..writeln('records: ${r.oldRecords} -> ${r.newRecords}');
  if (r.torn case final torn?) {
    out.writeln(
      torn.recoveryPath == null
          ? 'torn tail: ${torn.bytes} bytes would be saved to recovery'
          : 'torn tail: ${torn.bytes} bytes saved to ${torn.recoveryPath}',
    );
  }
  if (r.checkOnly) out.writeln('check only: no file changed');
}
