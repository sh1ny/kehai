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
  SessionState._(this.origin, this._meta, this._body)
    : _base = _body.copy(),
      _turn = origin.turn;

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
    final meta = initial['meta'];
    if (meta is! Map<Object?, Object?>) {
      throw invalid('the origin value must hold a meta map');
    }
    if (meta['format'] is! int) {
      throw invalid('meta/format must be an integer');
    }
    final session = meta['session'];
    if (session is! String || session.isEmpty) {
      throw invalid('meta/session must be a non-empty string');
    }
    switch (meta['lineage']) {
      case {'parent': null} && Map(length: 1):
      case {'parent': String(), 'parentTurn': int()} && Map(length: 2):
        break;
      default:
        throw invalid(
          'meta/lineage must be {parent: null} or '
          '{parent: <session id>, parentTurn: <int>}',
        );
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
  final SessionTree _base;
  SessionTree _body;
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
  /// Throws a [SessionError] when a non-`rewind` record targets the empty path
  /// (`invalid origin`), has a turn other
  /// than the current turn or the next one (`invalid turn`), or cannot be
  /// applied to the tree (`path not found`, `not a map`, `invalid path`,
  /// `invalid record`).
  ///
  /// A `rewind` must carry the current turn and an integer target from the
  /// origin turn up to, but excluding, the current turn; otherwise it fails
  /// with `invalid turn` or `invalid rewind target`.
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
      _validateRewind(record);
      return;
    }
    if (turn != _turn && turn != _turn + 1) {
      throw SessionError(
        'invalid turn',
        'expected turn $_turn or ${_turn + 1}, got $turn',
        op: op.wire,
        path: path,
      );
    }
    _target(path).check(record);
  }

  /// Applies [record], which must already have passed [validate].
  ///
  /// A `rewind` cuts the timeline after the last record whose turn is at most
  /// the target and rebuilds the non-`meta` subtrees by replaying what is
  /// left from the origin. `meta` is untouched.
  void commit(JournalRecord record) {
    if (record.op == Op.rewind) {
      _rewind(record.value! as int);
      return;
    }
    _target(record.path).apply(record);
    if (!_isMeta(record.path)) _timeline.add(record);
    _turn = record.turn;
  }

  void _validateRewind(JournalRecord record) {
    final JournalRecord(:turn, :path, :op, :value) = record;
    if (turn != _turn) {
      throw SessionError(
        'invalid turn',
        'a rewind must carry the current turn $_turn, got $turn',
        op: op.wire,
        path: path,
      );
    }
    final last = _turn - 1;
    if (value is! int || value < origin.turn || value > last) {
      final range = last < origin.turn
          ? 'there is no earlier turn to rewind to'
          : 'the target must be an integer from ${origin.turn} to $last';
      throw SessionError(
        'invalid rewind target',
        '$range (got ${value is int ? value : 'a non-integer'})',
        op: op.wire,
        path: path,
      );
    }
  }

  /// Returns the non-`meta` subtrees as they stood at the end of turn [turn].
  ///
  /// This is a pure replay of the timeline prefix over the origin's tree, the
  /// same one a rewind to [turn] performs, and changes nothing. Throws a
  /// [SessionError] with reason `invalid fork turn` unless [turn] is an
  /// integer from the origin turn up to and including the current turn.
  SessionTree bodyAtTurn(Object? turn) {
    if (turn is! int || turn < origin.turn || turn > _turn) {
      throw SessionError(
        'invalid fork turn',
        'the target must be an integer from ${origin.turn} to $_turn '
            '(got ${turn is int ? turn : 'a non-integer'})',
        op: 'fork',
      );
    }
    return _replay(_keepCount(turn));
  }

  void _rewind(int target) {
    final keep = _keepCount(target);
    _timeline.removeRange(keep, _timeline.length);
    _body = _replay(keep);
    _turn = target;
  }

  /// The length of the timeline prefix holding records of turn <= [target].
  int _keepCount(int target) {
    var keep = _timeline.length;
    while (keep > 0 && _timeline[keep - 1].turn > target) {
      keep--;
    }
    return keep;
  }

  SessionTree _replay(int count) {
    final tree = _base.copy();
    for (final record in _timeline.take(count)) {
      tree.apply(record);
    }
    return tree;
  }

  SessionTree _target(String path) => _isMeta(path) ? _meta : _body;

  bool _isMeta(String path) => SessionPath.parse(path).root == 'meta';
}
