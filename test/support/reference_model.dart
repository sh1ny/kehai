import 'dart:convert';

/// A deliberately naive model of a session tree, independent of the engine.
///
/// It shares no code with the engine. Where the engine keeps a timeline and
/// rebuilds the non-`meta` subtrees by replay from the origin on a rewind,
/// this model keeps a deep-copied snapshot of those subtrees per turn and
/// rewinds by picking one. `meta` is held apart and is never rewound.
///
/// The model assumes valid input and throws a [StateError] on an operation
/// the engine would reject, so a generator can ask it what is valid with
/// [canWrite], [isMap] and [exists] before choosing an operation.
final class ReferenceModel {
  /// Creates a model from an origin [tree] (the whole session tree) at [turn].
  ReferenceModel.fromOrigin(Map<String, Object?> tree, int turn)
    : originTurn = turn,
      turn = turn,
      _meta = {'meta': _deepCopy(tree['meta'])},
      _body = {
        for (final entry in tree.entries)
          if (entry.key != 'meta') entry.key: _deepCopy(entry.value),
      };

  /// Builds a model from a journal's decoded lines: the origin line followed
  /// by every later record, each `{turn, path, op, value}`.
  factory ReferenceModel.replay(List<Map<String, Object?>> records) {
    final origin = records.first;
    final model = ReferenceModel.fromOrigin(
      (origin['value']! as Map<Object?, Object?>).cast<String, Object?>(),
      origin['turn']! as int,
    );
    for (final record in records.skip(1)) {
      model.apply(
        record['turn']! as int,
        record['path']! as String,
        record['op']! as String,
        record['value'],
      );
    }
    return model;
  }

  /// The turn of the origin record.
  final int originTurn;

  /// The current turn: the turn of the last record applied.
  int turn;

  final Map<String, Object?> _meta;
  Map<String, Object?> _body;
  final Map<int, Map<String, Object?>> _snapshots = {};

  /// Applies one record by wire [op] name.
  ///
  /// A record may carry the current turn or the next one. The first record of
  /// a new turn snapshots the non-`meta` subtrees as they stood at the end of
  /// the turn that just closed. A `rewind` restores the snapshot of its target.
  void apply(int recordTurn, String path, String op, Object? value) {
    if (op == 'rewind') {
      final target = value! as int;
      if (target < originTurn || target >= turn) {
        throw StateError('rewind target $target outside $originTurn..$turn');
      }
      _body = _deepCopy(_snapshots[target]!) as Map<String, Object?>;
      _snapshots.removeWhere((key, _) => key > target);
      turn = target;
      return;
    }
    if (recordTurn != turn && recordTurn != turn + 1) {
      throw StateError('record turn $recordTurn at turn $turn');
    }
    final closing = recordTurn == turn + 1 ? _deepCopy(_body) : null;
    final segments = path.split('/');
    final root = segments.first == 'meta' ? _meta : _body;
    switch (op) {
      case 'set':
        _write(root, segments, (parent, key) => parent[key] = _deepCopy(value));
      case 'merge':
        _write(root, segments, (parent, key) {
          final existing = parent[key];
          if (!parent.containsKey(key)) {
            parent[key] = _deepCopy(value);
          } else if (existing is Map<String, Object?>) {
            existing.addAll(_deepCopy(value)! as Map<String, Object?>);
          } else {
            throw StateError('merge into a non-map at $path');
          }
        });
      case 'del':
        final parent = _walk(root, segments.take(segments.length - 1));
        if (parent is! Map<String, Object?> ||
            !parent.containsKey(segments.last)) {
          throw StateError('nothing to delete at $path');
        }
        parent.remove(segments.last);
      default:
        throw StateError('unknown op $op');
    }
    if (closing != null) {
      _snapshots[turn] = closing as Map<String, Object?>;
      turn = recordTurn;
    }
  }

  /// Whether a node exists at [path].
  bool exists(String path) => _lookup(path) != null;

  /// Whether the node at [path] exists and is a map.
  bool isMap(String path) => _lookup(path)?.$1 is Map<String, Object?>;

  /// Whether a `set` or `merge` can write [path]: every intermediate segment
  /// is a map or absent.
  bool canWrite(String path) {
    final segments = path.split('/');
    Object? current = segments.first == 'meta' ? _meta : _body;
    for (final segment in segments.take(segments.length - 1)) {
      if (current is! Map<String, Object?> || !current.containsKey(segment)) {
        return current is Map<String, Object?>;
      }
      current = current[segment];
    }
    return current is Map<String, Object?>;
  }

  /// A deep copy of the node at [path], or `null` when absent or `null`.
  Object? valueAt(String path) => _deepCopy(_lookup(path)?.$1);

  /// Every existing path with at most [maxDepth] segments under [root].
  List<String> pathsUnder(String root, {int maxDepth = 3}) {
    final out = <String>[];
    void visit(String path, Object? node, int depth) {
      out.add(path);
      if (node is Map<String, Object?> && depth < maxDepth) {
        for (final key in node.keys.toList()..sort()) {
          visit('$path/$key', node[key], depth + 1);
        }
      }
    }

    final tree = root == 'meta' ? _meta : _body;
    if (tree.containsKey(root)) visit(root, tree[root], 1);
    return out;
  }

  /// The non-`meta` subtrees at the end of [atTurn], from `originTurn` up to
  /// and including the current turn.
  Map<String, Object?> bodyAtTurn(int atTurn) {
    if (atTurn < originTurn || atTurn > turn) {
      throw StateError('turn $atTurn outside $originTurn..$turn');
    }
    return _deepCopy(atTurn == turn ? _body : _snapshots[atTurn]!)!
        as Map<String, Object?>;
  }

  /// The origin tree of a fork taken at [atTurn] under the new id [childId].
  Map<String, Object?> forkTree(int atTurn, String childId) {
    final meta = _deepCopy(_meta['meta'])! as Map<String, Object?>;
    final parent = meta['session'];
    meta['session'] = childId;
    meta['lineage'] = {'parent': parent, 'parentTurn': atTurn};
    meta['requests'] = <String, Object?>{};
    return {...bodyAtTurn(atTurn), 'meta': meta};
  }

  /// Records every still `admitted` request as interrupted, in id order, as
  /// the engine does when it opens a session.
  int interruptAdmitted() {
    final requests = valueAt('meta/requests');
    if (requests is! Map<String, Object?>) return 0;
    final ids = [
      for (final entry in requests.entries)
        if (entry.value is Map<String, Object?> &&
            (entry.value! as Map<String, Object?>)['state'] == 'admitted')
          entry.key,
    ]..sort();
    for (final id in ids) {
      apply(turn, 'meta/requests/$id', 'merge', {
        'state': 'interrupted',
        'reason': 'effect-uncertain',
      });
    }
    return ids.length;
  }

  /// The whole tree: the non-`meta` subtrees and `meta`.
  Map<String, Object?> toJson() =>
      _deepCopy({..._body, ..._meta})! as Map<String, Object?>;

  /// The canonical serialization: sorted keys, no whitespace.
  String canonical() => canonicalJson(toJson());

  (Object?,)? _lookup(String path) {
    Object? current = path.startsWith('meta') ? _meta : _body;
    for (final segment in path.split('/')) {
      if (current is Map<String, Object?> && current.containsKey(segment)) {
        current = current[segment];
      } else {
        return null;
      }
    }
    return (current,);
  }

  static Object? _walk(Object? from, Iterable<String> segments) {
    var current = from;
    for (final segment in segments) {
      if (current is Map<String, Object?> && current.containsKey(segment)) {
        current = current[segment];
      } else {
        return null;
      }
    }
    return current;
  }

  static void _write(
    Map<String, Object?> root,
    List<String> segments,
    void Function(Map<String, Object?> parent, String key) action,
  ) {
    var current = root;
    for (final segment in segments.take(segments.length - 1)) {
      final next = current.putIfAbsent(segment, () => <String, Object?>{});
      if (next is! Map<String, Object?>) {
        throw StateError('intermediate "$segment" holds a non-map');
      }
      current = next;
    }
    action(current, segments.last);
  }
}

Object? _deepCopy(Object? value) {
  if (value is Map) {
    return {for (final e in value.entries) e.key as String: _deepCopy(e.value)};
  }
  if (value is List) return [for (final e in value) _deepCopy(e)];
  return value;
}

Object? _sortKeys(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _sortKeys(value[key])};
  }
  if (value is List) return [for (final e in value) _sortKeys(e)];
  return value;
}

/// The canonical serialization of [value]: sorted keys, no whitespace.
String canonicalJson(Object? value) => jsonEncode(_sortKeys(value));
