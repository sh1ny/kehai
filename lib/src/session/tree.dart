/// The mutable JSON tree that journal records are applied to.
library;

import 'dart:convert';

import 'errors.dart';
import 'path.dart';
import 'record.dart';

/// A mutable JSON object tree updated by journal records.
///
/// Values are deep-copied on the way in and on the way out, so callers never
/// alias internal state. Every failing [apply] leaves the tree unchanged.
/// The tree implements `set`, `merge` and `del`; `rewind` is handled by the
/// timeline logic above this class.
final class SessionTree {
  /// Creates an empty tree.
  SessionTree() : _root = {};

  /// Creates a tree holding a deep copy of [root].
  ///
  /// Throws a [SessionError] when [root] is not plain JSON.
  factory SessionTree.fromJson(Map<Object?, Object?> root) {
    if (!isJson(root)) {
      throw const SessionError('invalid record', 'value is not plain JSON');
    }
    return SessionTree._(_copyMap(root));
  }

  SessionTree._(this._root);

  Map<String, Object?> _root;

  /// Returns a deep copy of the value at [path], or `null` when absent.
  ///
  /// Use [contains] to tell an absent path from a stored `null`. The empty
  /// path returns the whole tree.
  Object? get(SessionPath path) {
    final value = _lookup(path);
    return value == null ? null : _copy(value.$1);
  }

  /// Whether a node exists at [path]. The empty path always exists.
  bool contains(SessionPath path) => _lookup(path) != null;

  /// Applies [record] to the tree.
  ///
  /// The record is validated with [validateRecordShape] first. With [isOrigin]
  /// the record replaces the whole tree, and its value must be a map. Throws a
  /// [SessionError] naming the operation and path when the record is
  /// malformed (`invalid path`, `invalid record`), `del` targets an absent
  /// path (`path not found`), a `set` or `merge` crosses or targets a
  /// non-map (`not a map`), or the operation is `rewind` (`unsupported op`).
  void apply(JournalRecord record, {bool isOrigin = false}) {
    validateRecordShape(record, isOrigin: isOrigin);
    final JournalRecord(:path, :op, :value) = record;
    try {
      final target = SessionPath.parse(path);
      switch (op) {
        case Op.set:
          _set(target, value);
        case Op.merge:
          _merge(target, value);
        case Op.del:
          _del(target);
        case Op.rewind:
          throw const SessionError(
            'unsupported op',
            'rewind is applied by the timeline, not the tree',
          );
      }
    } on SessionError catch (e) {
      throw e.at(op.wire, path);
    }
  }

  /// Returns a deep copy of the tree as a JSON object.
  Map<String, Object?> toJson() => _copyMap(_root);

  /// Returns the canonical serialization: sorted keys, no whitespace.
  String canonical() => jsonEncode(_sorted(_root));

  /// Returns an independent deep copy of this tree.
  SessionTree copy() => SessionTree._(_copyMap(_root));

  void _set(SessionPath target, Object? value) {
    if (target.isEmpty) {
      if (value is! Map<Object?, Object?>) {
        throw const SessionError('not a map', 'the origin value must be a map');
      }
      _root = _copyMap(value);
      return;
    }
    final parent = _parentForWrite(target);
    parent[target.segments.last] = _copy(value);
  }

  void _merge(SessionPath target, Object? value) {
    if (value is! Map<Object?, Object?>) {
      throw const SessionError('not a map', 'merge value must be a map');
    }
    final parent = _parentForWrite(target);
    final key = target.segments.last;
    switch (parent[key]) {
      case null when !parent.containsKey(key):
        parent[key] = _copyMap(value);
      case final Map<String, Object?> existing:
        existing.addAll(_copyMap(value));
      case _:
        throw const SessionError('not a map', 'merge target holds a non-map');
    }
  }

  void _del(SessionPath target) {
    final parent = _lookup(
      SessionPath.parse(
        target.segments.take(target.segments.length - 1).join('/'),
      ),
    );
    final key = target.segments.last;
    if (parent == null ||
        parent.$1 is! Map<String, Object?> ||
        !(parent.$1! as Map<String, Object?>).containsKey(key)) {
      throw const SessionError('path not found', 'nothing to delete');
    }
    (parent.$1! as Map<String, Object?>).remove(key);
  }

  /// Returns the map that will hold the last segment of [target], creating
  /// missing intermediate maps. Validates the whole walk before creating.
  Map<String, Object?> _parentForWrite(SessionPath target) {
    final intermediates = target.segments.take(target.segments.length - 1);
    var current = _root;
    var missing = false;
    for (final segment in intermediates) {
      if (missing) break;
      switch (current[segment]) {
        case final Map<String, Object?> next:
          current = next;
        case null when !current.containsKey(segment):
          missing = true;
        case _:
          throw SessionError(
            'not a map',
            'intermediate segment "$segment" holds a non-map',
          );
      }
    }
    if (!missing) return current;
    current = _root;
    for (final segment in intermediates) {
      current = current.putIfAbsent(
        segment,
        () => <String, Object?>{},
      ) as Map<String, Object?>;
    }
    return current;
  }

  /// Returns the node at [path] boxed in a record, or `null` when absent.
  (Object?,)? _lookup(SessionPath path) {
    Object? current = _root;
    for (final segment in path.segments) {
      if (current is Map<String, Object?> && current.containsKey(segment)) {
        current = current[segment];
      } else {
        return null;
      }
    }
    return (current,);
  }
}

Object? _copy(Object? value) => switch (value) {
  final List<Object?> list => [for (final e in list) _copy(e)],
  final Map<Object?, Object?> map => _copyMap(map),
  _ => value,
};

Map<String, Object?> _copyMap(Map<Object?, Object?> map) => {
  for (final MapEntry(:key, :value) in map.entries)
    key! as String: _copy(value),
};

Object? _sorted(Object? value) => switch (value) {
  final List<Object?> list => [for (final e in list) _sorted(e)],
  final Map<Object?, Object?> map => {
    for (final key in map.keys.cast<String>().toList()..sort())
      key: _sorted(map[key]),
  },
  _ => value,
};
