/// Read-only materialization of a session from its journal.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'journal.dart';
import 'tree.dart';

/// The tree of a session as read from disk.
final class Materialization {
  /// Creates a materialization result.
  const Materialization({
    required this.tree,
    required this.observed,
    required this.trailingBytes,
    required this.recordCount,
    required this.currentTurn,
  });

  /// The tree of the complete records on disk.
  final SessionTree tree;

  /// Whether a writer owns the session, so the result is not acknowledged.
  ///
  /// A record may be on disk before its flush completes, so observed state
  /// can contain records the writer later fails to acknowledge.
  final bool observed;

  /// The number of uncommitted bytes after the last newline, ignored here.
  final int trailingBytes;

  /// The number of committed records.
  final int recordCount;

  /// The turn of the last committed record.
  final int currentTurn;
}

/// Materializes the session in [sessionDir] without taking any lock.
///
/// Stops at the last newline, reports trailing bytes and never modifies the
/// journal. The result is `observed` when `session.owner` exists. Throws a
/// [JournalCorruption] when a committed line is invalid or unappliable.
Materialization materialize(Directory sessionDir) {
  final scan = scanJournal(File(p.join(sessionDir.path, journalFileName)));
  return Materialization(
    tree: scan.state.combined(),
    observed: File(p.join(sessionDir.path, ownerFileName)).existsSync(),
    trailingBytes: scan.trailingBytes,
    recordCount: scan.recordCount,
    currentTurn: scan.state.currentTurn,
  );
}
