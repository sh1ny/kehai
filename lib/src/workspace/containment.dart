/// Containment of automatic reads (design D15).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../permissions/credentials.dart';
import '../permissions/workspace_paths.dart';

/// A file or directory the loaders skipped, and why.
class Problem {
  /// Creates a problem for [path] (relative to the project root).
  const Problem(this.path, this.reason);

  /// The path, relative to the project root, written with `/`.
  final String path;

  /// The cause.
  final String reason;

  @override
  String toString() => '$path: $reason';
}

/// The outcome of [readContained].
class ContainedRead {
  /// Creates an outcome.
  const ContainedRead({
    this.text,
    this.size = 0,
    this.truncated = false,
    this.problem,
  });

  /// The text read, or null when [problem] is set.
  final String? text;

  /// The file's full size in bytes.
  final int size;

  /// Whether [text] stops at the last whole line within the requested limit.
  final bool truncated;

  /// Why nothing was read, or null.
  final Problem? problem;
}

/// The path of [path] relative to [root], written with `/`.
String displayPath(String root, String path) =>
    p.split(p.relative(p.absolute(path), from: p.absolute(root))).join('/');

/// Reads [path] only when it resolves inside [root] (design D15).
///
/// The project root and the file are resolved first, links and junctions
/// included. The file is opened, at its resolved path, only when the resolved
/// path is inside the resolved root and is not a credential file of
/// [kehaiHome]. Otherwise nothing is read and the problem says
/// `credential file` or `outside the project root`.
///
/// With a [limit], a longer file is cut at the last whole line within it and
/// [ContainedRead.truncated] is set; [ContainedRead.size] is always the full
/// size.
ContainedRead readContained({
  required String root,
  required String path,
  required Directory kehaiHome,
  int? limit,
}) {
  final shown = displayPath(root, path);
  ContainedRead refuse(String reason) =>
      ContainedRead(problem: Problem(shown, reason));

  if (isCredentialTarget(path, kehaiHome)) return refuse('credential file');
  final realRoot = realPath(root);
  final real = realPath(path);
  if (realRoot == null || real == null) {
    return refuse('cannot be resolved');
  }
  if (!isInside(realRoot, real)) return refuse('outside the project root');

  Uint8List bytes;
  int size;
  try {
    final file = File(real).openSync();
    try {
      size = file.lengthSync();
      final count = limit == null || size <= limit ? size : limit;
      bytes = file.readSync(count);
    } finally {
      file.closeSync();
    }
  } on FileSystemException catch (e) {
    return refuse('cannot be read: ${e.osError?.message ?? e.message}');
  }
  final truncated = limit != null && size > limit;
  if (truncated) {
    final nl = bytes.lastIndexOf(10);
    bytes = Uint8List.sublistView(bytes, 0, nl + 1);
  }
  try {
    return ContainedRead(
      text: utf8.decode(bytes),
      size: size,
      truncated: truncated,
    );
  } on FormatException {
    return refuse('not valid UTF-8');
  }
}
