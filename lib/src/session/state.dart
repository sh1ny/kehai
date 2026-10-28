/// The shared fold used by both the live writer and materialization.
library;

import 'errors.dart';
import 'path.dart';
import 'record.dart';
import 'tree.dart';

/// The journal format version written to `meta/format`.
const int sessionFormatVersion = 1;

/// The state of a session folded from its journal records.
///
/// The state is split in two. The meta fold holds every record whose path
/// starts with `meta` and is never rewound. The timeline holds the live
/// records of every other root subtree, kept with the [origin] record so a
/// later `rewind` can rebuild those subtrees by replay.
///
/// The live writer and read-only materialization both drive this class, so
/// they cannot diverge: [validate] checks a record without mutating and
/// [commit] applies it.
final class SessionState {
  SessionState._(this.origin, this._meta, this._body) : _turn = origin.turn;

  /// Creates the state from the journal's first record, [origin].
  ///
  /// Throws a [SessionError] with reason `invalid origin` unless [origin] is
  /// a `set` at the empty path whose value is a map of known root subtrees.
  factory SessionState.fromOrigin(JournalRecord origin) {
    SessionError invalid(String detail) => SessionError(
      'invalid origin',
      detail,
      op: origin.op.wire,
      path: origin.path,
    );
    if (origin.path.isNotEmpty || origin.op != Op.set) {
      throw invalid('the first record must be a set at the empty path');
    }
    validateRecordShape(origin, isOrigin: true);
    final initial = origin.value;
    if (initial is! Map<Object?, Object?>) {
      throw invalid('the origin value must be a map');
    }
    for (final key in initial.keys) {
      if (!SessionPath.roots.contains(key)) {
        throw invalid('unknown root subtree "$key" in the origin value');
      }
    }
    if (initial.containsKey('meta') &&
        initial['meta'] is! Map<Object?, Object?>) {
      throw invalid('meta must be a map');
    }
    return SessionState._(
      origin,
      SessionTree.fromJson({
        for (final MapEntry(:key, :value) in initial.entries)
          if (key == 'meta') key: value,
      }),
      SessionTree.fromJson({
        for (final MapEntry(:key, :value) in initial.entries)
          if (key != 'meta') key: value,
      }),
    );
  }

  /// The origin record this state was seeded from.
  final JournalRecord origin;

  final SessionTree _meta;
  final SessionTree _body;
  final List<JournalRecord> _timeline = [];
  int _turn;

  /// The current turn: the turn of the last committed record.
  int get currentTurn => _turn;

  /// The live non-`meta` records after the origin, in journal order.
  List<JournalRecord> get timeline => List.unmodifiable(_timeline);

  /// Returns a copy of the whole tree: the meta fold and the other subtrees.
  SessionTree combined() =>
      SessionTree.fromJson({..._body.toJson(), ..._meta.toJson()});

  /// Checks that [record] can be committed next, without changing the state.
  ///
  /// Throws a [SessionError] when the record targets the empty path
  /// (`invalid origin`), is a `rewind` (`unsupported op`), has a turn other
  /// than the current turn or the next one (`invalid turn`), or cannot be
  /// applied to the tree (`path not found`, `not a map`, `invalid path`,
  /// `invalid record`).
  void validate(JournalRecord record) {
    final JournalRecord(:turn, :path, :op) = record;
    if (path.isEmpty && op != Op.rewind) {
      throw SessionError(
        'invalid origin',
        'only the first record may target the empty path',
        op: op.wire,
        path: path,
      );
    }
    validateRecordShape(record, isOrigin: false);
    if (op == Op.rewind) {
      throw SessionError(
        'unsupported op',
        'rewind is not supported yet',
        op: op.wire,
        path: path,
      );
    }
    if (turn != _turn && turn != _turn + 1) {
      throw SessionError(
        'invalid turn',
        'expected turn $_turn or ${_turn + 1}, got $turn',
        op: op.wire,
        path: path,
      );
    }
    _target(path).copy().apply(record);
  }

  /// Applies [record], which must already have passed [validate].
  void commit(JournalRecord record) {
    _target(record.path).apply(record);
    if (!_isMeta(record.path)) _timeline.add(record);
    _turn = record.turn;
  }

  SessionTree _target(String path) => _isMeta(path) ? _meta : _body;

  bool _isMeta(String path) => SessionPath.parse(path).root == 'meta';
}
