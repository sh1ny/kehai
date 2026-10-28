/// Resolution of result handles through the session tree.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../session/path.dart';
import '../session/tree.dart';
import 'descriptor.dart';
import 'result_store.dart';

/// A resolved handle: its descriptor and its bytes file.
typedef ResolvedResult = ({ResultDescriptor descriptor, File file});

final RegExp _handlePattern = RegExp(r'^r/[0-9a-f]{12}$');

/// Resolves [handle] through [tree] to its descriptor and bytes file.
///
/// Only the tree is consulted, so a descriptor removed by a rewind is
/// unknown. Throws a [ResultError] with `unknown handle` plus the handle when the
/// tree holds no descriptor for it, and with `result bytes missing for` plus the
/// handle when the file `results/<sha256>` in [sessionDir] is absent or
/// its size differs from the descriptor's. Nothing partial is returned.
ResolvedResult resolveHandle(
  SessionTree tree,
  Directory sessionDir,
  String handle,
) {
  if (!_handlePattern.hasMatch(handle)) {
    throw ResultError('unknown handle $handle');
  }
  final node = tree.get(
    SessionPath.parse('$resultsDirName/${handle.substring(2)}'),
  );
  final ResultDescriptor descriptor;
  try {
    if (node is! Map<String, Object?>) throw const ResultError('no node');
    descriptor = ResultDescriptor.fromJson(node);
    if (descriptor.handle != handle) throw const ResultError('wrong node');
  } on ResultError {
    throw ResultError('unknown handle $handle');
  }
  final file = File(p.join(sessionDir.path, resultsDirName, descriptor.sha256));
  if (!file.existsSync() || file.lengthSync() != descriptor.bytes) {
    throw ResultError('result bytes missing for $handle');
  }
  return (descriptor: descriptor, file: file);
}
