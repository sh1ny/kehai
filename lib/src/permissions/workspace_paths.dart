/// Path resolution for the workspace check (design D13).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// The real path of [path]: absolute, with every symbolic link resolved.
///
/// The part of the path that does not exist yet is appended after the nearest
/// existing ancestor, so a file about to be created resolves too. Returns null
/// when an existing component cannot be resolved (a dangling link), which the
/// callers treat as unproven.
///
/// A `..` is applied to the resolved prefix, as POSIX does. Windows resolves
/// `..` lexically before it looks at the disk, so there the path is
/// normalized first.
String? realPath(String path) {
  var absolute = p.absolute(path);
  if (p.style == p.Style.windows) absolute = p.normalize(absolute);
  final segments = p.split(absolute);
  var current = segments.first;
  for (var i = 1; i < segments.length; i++) {
    final segment = segments[i];
    if (segment == '.') continue;
    if (segment == '..') {
      current = p.dirname(current);
      continue;
    }
    final candidate = p.join(current, segment);
    if (FileSystemEntity.typeSync(candidate, followLinks: false) ==
        FileSystemEntityType.notFound) {
      return p.normalize(p.joinAll([current, ...segments.skip(i)]));
    }
    try {
      current = _resolve(candidate);
    } on FileSystemException {
      return null;
    }
  }
  return current;
}

String _resolve(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  return switch (type) {
    FileSystemEntityType.directory => Directory(
      path,
    ).resolveSymbolicLinksSync(),
    _ => File(path).resolveSymbolicLinksSync(),
  };
}

/// Whether [path] is [root] or inside it; both are real paths.
///
/// Comparison ignores case on Windows.
bool isInside(String root, String path) =>
    p.equals(root, path) || p.isWithin(root, path);
