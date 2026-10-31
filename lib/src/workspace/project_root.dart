/// The project root of a workspace (workspace-context spec).
library;

import 'package:path/path.dart' as p;

import '../permissions/workspace_paths.dart';

import 'dart:io';

/// The real path of the nearest ancestor of [workspace], [workspace]
/// included, that holds `.git` or `.jj`; the real path of [workspace] when
/// none does.
String projectRoot(String workspace) {
  final start = realPath(workspace) ?? p.normalize(p.absolute(workspace));
  var dir = start;
  while (true) {
    if (_hasMarker(dir)) return dir;
    final parent = p.dirname(dir);
    if (parent == dir) return start;
    dir = parent;
  }
}

bool _hasMarker(String dir) => const ['.git', '.jj'].any(
  (m) =>
      FileSystemEntity.typeSync(p.join(dir, m), followLinks: false) !=
      FileSystemEntityType.notFound,
);
