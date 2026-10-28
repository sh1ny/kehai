/// Reading, validating and repairing the journal file.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'errors.dart';
import 'record.dart';
import 'state.dart';

/// The journal file name inside a session directory.
const String journalFileName = 'journal.jsonl';

/// The owner file name inside a session directory.
const String ownerFileName = 'session.owner';

/// The directory name for recovered bytes inside a session directory.
const String recoveryDirName = 'recovery';

/// The file a migration writes before it renames anything.
const String migratingFileName = 'journal.jsonl.migrating';

/// The command that migrates an outdated session.
const String migrationCommand = 'dart run tool/migrate_journal.dart';

/// A committed journal line that cannot be read or applied.
final class JournalCorruption implements Exception {
  /// Creates an error for the 1-based [line] starting at byte [offset].
  const JournalCorruption(this.line, this.offset, this.reason, this.detail);

  /// The 1-based line number.
  final int line;

  /// The 0-based byte offset of the start of the line.
  final int offset;

  /// The stable reason, such as `invalid record` or `path not found`.
  final String reason;

  /// The explanation of what was wrong.
  final String detail;

  @override
  String toString() =>
      'JournalCorruption: line $line at offset $offset: $reason: $detail';
}

/// Bytes after the last newline that were found and set aside.
final class TornTail {
  /// Creates a report of [bytes] torn bytes, saved to [recoveryPath] if any.
  const TornTail(this.bytes, {this.recoveryPath});

  /// The number of torn bytes.
  final int bytes;

  /// The recovery file that holds the bytes.
  final String? recoveryPath;
}

/// The result of reading a journal up to its last newline.
final class JournalScan {
  /// Creates a scan result.
  const JournalScan(
    this.state,
    this.recordCount,
    this.committedLength,
    this.trailingBytes,
  );

  /// The state folded from every committed record.
  final SessionState state;

  /// The number of committed lines.
  final int recordCount;

  /// The byte length up to and including the last newline.
  final int committedLength;

  /// The number of bytes after the last newline, which are uncommitted.
  final int trailingBytes;
}

/// Reads [journal] up to its last newline and folds every line.
///
/// A final line without a newline is uncommitted and only counted in
/// [JournalScan.trailingBytes]. The file is never modified. Throws a
/// [JournalCorruption] naming the line, offset and reason for a committed
/// line that is not a valid record or cannot be applied, and for a missing or
/// repeated origin (`invalid origin`).
///
/// Before any line is applied, throws a [SessionError] when the session was
/// left in the middle of a migration (`incomplete migration; rerun
/// migrate_journal`). It also throws when `meta/format` in the origin is not
/// the current [sessionFormatVersion]: `format 0 requires migration` for an
/// older format, `format 9 is newer than this kehai` for a newer one.
JournalScan scanJournal(File journal) {
  final sessionDir = journal.parent;
  if (!journal.existsSync() &&
      File(p.join(sessionDir.path, migratingFileName)).existsSync()) {
    throw SessionError(
      'incomplete migration; rerun migrate_journal',
      'run $migrationCommand --session ${sessionDir.path}',
    );
  }
  final bytes = journal.readAsBytesSync();
  final committed = bytes.lastIndexOf(0x0A) + 1;
  if (committed > 0) _requireCurrentFormat(bytes, sessionDir);
  SessionState? state;
  var start = 0;
  var line = 0;
  while (start < committed) {
    line++;
    final end = bytes.indexOf(0x0A, start);
    try {
      final JournalRecord record;
      try {
        record = JournalRecord.parse(utf8.decode(bytes.sublist(start, end)));
      } on FormatException catch (e) {
        throw SessionError('invalid record', 'not valid UTF-8: ${e.message}');
      }
      if (state == null) {
        state = SessionState.fromOrigin(record);
      } else {
        state
          ..validate(record)
          ..commit(record);
      }
    } on SessionError catch (e) {
      throw JournalCorruption(line, start, e.reason, e.message);
    }
    start = end + 1;
  }
  if (state == null) {
    throw const JournalCorruption(
      1,
      0,
      'invalid origin',
      'the journal has no origin record',
    );
  }
  return JournalScan(state, line, committed, bytes.length - committed);
}

/// Returns the `meta/format` of the origin [record], or `null` when absent.
int? originFormat(JournalRecord record) {
  if (record.path.isNotEmpty) return null;
  if (record.value case {'meta': {'format': final int format}}) return format;
  return null;
}

void _requireCurrentFormat(List<int> bytes, Directory sessionDir) {
  final JournalRecord origin;
  try {
    origin = JournalRecord.parse(
      utf8.decode(bytes.sublist(0, bytes.indexOf(0x0A))),
    );
  } on Exception {
    return; // The fold reports the invalid origin with its line and offset.
  }
  final format = originFormat(origin);
  if (format == null || format == sessionFormatVersion) return;
  if (format > sessionFormatVersion) {
    throw SessionError(
      'format $format is newer than this kehai',
      'this kehai reads format $sessionFormatVersion',
    );
  }
  throw SessionError(
    'format $format requires migration',
    'run $migrationCommand --session ${sessionDir.path}',
  );
}

/// Copies the torn tail described by [scan] to a recovery file and truncates
/// [journal] to its last newline.
///
/// The recovery file is `recovery/torn-<offset>-<utc>.bin` inside
/// [sessionDir] and is flushed before the journal is changed.
TornTail recoverTornTail(
  Directory sessionDir,
  File journal,
  JournalScan scan, {
  DateTime? now,
}) {
  final torn = saveTornBytes(
    sessionDir,
    journal,
    scan.committedLength,
    now: now,
  );
  final raf = journal.openSync(mode: FileMode.append);
  try {
    raf.truncateSync(scan.committedLength);
    raf.flushSync();
  } finally {
    raf.closeSync();
  }
  return torn;
}

/// Copies the bytes of [journal] after [committedLength] to
/// `recovery/torn-<offset>-<utc>.bin` inside [sessionDir] and flushes them,
/// leaving [journal] untouched.
TornTail saveTornBytes(
  Directory sessionDir,
  File journal,
  int committedLength, {
  DateTime? now,
}) {
  final bytes = journal.readAsBytesSync().sublist(committedLength);
  final dir = Directory(p.join(sessionDir.path, recoveryDirName))
    ..createSync(recursive: true);
  final stamp = compactUtc(now ?? DateTime.now());
  final recovery = File(p.join(dir.path, 'torn-$committedLength-$stamp.bin'));
  final out = recovery.openSync(mode: FileMode.writeOnly);
  try {
    out.writeFromSync(bytes);
    out.flushSync();
  } finally {
    out.closeSync();
  }
  return TornTail(bytes.length, recoveryPath: recovery.path);
}

/// Formats [time] in UTC as `yyyyMMddTHHmmssZ`.
String compactUtc(DateTime time) {
  final t = time.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}'
      'T${two(t.hour)}${two(t.minute)}${two(t.second)}Z';
}
