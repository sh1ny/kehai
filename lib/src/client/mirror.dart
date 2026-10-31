/// The client's copy of the session tree, rebuilt from every `snapshot` and
/// kept by `update` events (design D1, D11).
library;

import '../session/path.dart';
import '../session/record.dart';
import '../session/tree.dart';

/// The tree the engine last sent, plus the updates since.
final class TreeMirror {
  SessionTree _tree = SessionTree();
  int _offset = 0;
  int _turn = 0;
  bool _valid = false;

  /// Whether a snapshot was taken and no `resync` has invalidated it.
  bool get isValid => _valid;

  /// The last journal turn seen, for `submit`.
  int get turn => _turn;

  /// The value at [path], or null.
  Object? get(String path) => _tree.get(SessionPath.parse(path));

  /// The whole tree as JSON.
  Map<String, Object?> toJson() => _tree.toJson();

  /// Replaces the tree with a `snapshot`.
  void applySnapshot(int offset, int turn, Map<String, Object?> tree) {
    _tree = SessionTree.fromJson(tree);
    _offset = offset;
    _turn = turn;
    _valid = true;
  }

  /// Drops the tree until the next snapshot (the engine sent `resync`).
  void invalidate() => _valid = false;

  /// Applies an `update` and returns whether it changed the tree.
  ///
  /// An update before a valid snapshot, or below the snapshot's offset, is
  /// already part of it and is skipped. A `rewind` is skipped too: the engine
  /// follows it with `resync` and a snapshot.
  bool applyUpdate(int offset, JournalRecord record) {
    if (!_valid || offset < _offset) return false;
    if (record.turn > _turn) _turn = record.turn;
    if (record.op == Op.rewind) return false;
    _tree.apply(record);
    return true;
  }
}
