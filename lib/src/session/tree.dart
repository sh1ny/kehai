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
          throw _rewindUnsupported;
      }
    } on SessionError catch (e) {
      throw e.at(op.wire, path);
    }
  }

  /// Checks that [record] would [apply] cleanly, without changing the tree.
  ///
  /// Throws exactly the [SessionError] that [apply] would, but walks only the
  /// target's path, so validating a record costs nothing per unrelated node.
  void check(JournalRecord record, {bool isOrigin = false}) {
    validateRecordShape(record, isOrigin: isOrigin);
    final JournalRecord(:path, :op, :value) = record;
    try {
      final target = SessionPath.parse(path);
      switch (op) {
        case Op.set:
          if (target.isEmpty) {
            if (value is! Map<Object?, Object?>) throw _originNotMap;
            return;
          }
          _existingParent(target);
        case Op.merge:
          if (value is! Map<Object?, Object?>) throw _mergeNotMap;
          final parent = _existingParent(target);
          final key = target.segments.last;
          if (parent != null &&
              parent.containsKey(key) &&
              parent[key] is! Map<String, Object?>) {
            throw _mergeTargetNotMap;
          }
        case Op.del:
          _deleteParent(target);
        case Op.rewind:
          throw _rewindUnsupported;
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
      if (value is! Map<Object?, Object?>) throw _originNotMap;
      _root = _copyMap(value);
      return;
    }
    final parent = _parentForWrite(target);
    parent[target.segments.last] = _copy(value);
  }

  void _merge(SessionPath target, Object? value) {
    if (value is! Map<Object?, Object?>) throw _mergeNotMap;
    final parent = _parentForWrite(target);
    final key = target.segments.last;
    switch (parent[key]) {
      case null when !parent.containsKey(key):
        parent[key] = _copyMap(value);
      case final Map<String, Object?> existing:
        existing.addAll(_copyMap(value));
      case _:
        throw _mergeTargetNotMap;
    }
  }

  void _del(SessionPath target) {
    _deleteParent(target).remove(target.segments.last);
  }

  /// Returns the map holding the last segment of [target], which must exist.
  Map<String, Object?> _deleteParent(SessionPath target) {
    final parent = _lookup(
      SessionPath.parse(
        target.segments.take(target.segments.length - 1).join('/'),
      ),
    );
    final key = target.segments.last;
    if (parent case (final Map<String, Object?> map,)
        when map.containsKey(key)) {
      return map;
    }
    throw const SessionError('path not found', 'nothing to delete');
  }

  /// Returns the existing map that holds the last segment of [target], or
  /// `null` when an intermediate map is missing. Throws `not a map` when an
  /// intermediate segment holds a non-map. Changes nothing.
  Map<String, Object?>? _existingParent(SessionPath target) {
    final intermediates = target.segments.take(target.segments.length - 1);
    var current = _root;
    for (final segment in intermediates) {
      switch (current[segment]) {
        case final Map<String, Object?> next:
          current = next;
        case null when !current.containsKey(segment):
          return null;
        case _:
          throw SessionError(
            'not a map',
            'intermediate segment "$segment" holds a non-map',
          );
      }
    }
    return current;
  }

  /// Returns the map that will hold the last segment of [target], creating
  /// missing intermediate maps. Validates the whole walk before creating.
  Map<String, Object?> _parentForWrite(SessionPath target) {
    final existing = _existingParent(target);
    if (existing != null) return existing;
    final intermediates = target.segments.take(target.segments.length - 1);
    var current = _root;
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

const _originNotMap = SessionError(
  'not a map',
  'the origin value must be a map',
);
const _mergeNotMap = SessionError('not a map', 'merge value must be a map');
const _mergeTargetNotMap = SessionError(
  'not a map',
  'merge target holds a non-map',
);
const _rewindUnsupported = SessionError(
  'unsupported op',
  'rewind is applied by the timeline, not the tree',
);

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
