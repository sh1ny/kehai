/// Atomic replacement of a file's content (design D5).
///
/// The new bytes go to a temporary file in the target's directory, are
/// flushed, and the temporary file is renamed over the target. A failure at
/// any step leaves the target as it was and deletes the temporary file.
library;

import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../auth/credential_error.dart' show CredentialStoreError;
import '../auth/posix_ffi.dart' show PosixLibc;

/// Renames [from] over [to].
typedef RenameFile = Future<void> Function(String from, String to);

/// Test seams of the tools that write files.
final class FileWriteSeams {
  /// Creates seams; every callback is optional.
  const FileWriteSeams({this.rename, this.beforeRename});

  /// Replaces the rename, so a test can fail or count it.
  final RenameFile? rename;

  /// Runs once the temporary file is written and before the target is checked
  /// for changes and renamed over.
  final Future<void> Function()? beforeRename;
}

/// A write that did not happen; the target is unchanged and no temporary
/// file remains.
final class WriteFailure implements Exception {
  /// Creates the failure with the one-line [message].
  const WriteFailure(this.message);

  /// What went wrong.
  final String message;

  @override
  String toString() => message;
}

/// The message of the failure when the target changed under an edit.
const String changedDuringEdit =
    'file changed during edit; read the file again';

/// The prefix of the temporary files next to [target].
String temporaryPrefix(String target) => '.${p.basename(target)}.kehai-';

/// Replaces the content of [target] with [bytes] atomically.
///
/// The target keeps its permission bits on POSIX. When [unchangedSince] is
/// given, the target's size and modification time are compared with it just
/// before the rename, and a difference fails with [changedDuringEdit]. That
/// narrows, but does not close, the window against other writers.
///
/// Throws [WriteFailure].
Future<void> writeAtomically(
  String target,
  List<int> bytes, {
  FileStat? unchangedSince,
  FileWriteSeams seams = const FileWriteSeams(),
}) async {
  final random = Random.secure();
  final suffix = List.generate(
    8,
    (_) => random.nextInt(16).toRadixString(16),
  ).join();
  final temporary = File(
    p.join(p.dirname(target), '${temporaryPrefix(target)}$suffix'),
  );
  try {
    final RandomAccessFile out;
    try {
      out = await temporary.open(mode: FileMode.writeOnly);
    } on FileSystemException catch (e) {
      throw WriteFailure('cannot create ${temporary.path}: ${e.message}');
    }
    try {
      await out.writeFrom(bytes);
      await out.flush();
    } on FileSystemException catch (e) {
      throw WriteFailure('write failed: ${e.message}');
    } finally {
      await out.close();
    }
    final existing = await FileStat.stat(target);
    if (existing.type == FileSystemEntityType.file && !Platform.isWindows) {
      try {
        PosixLibc.instance.chmod(temporary.path, existing.mode & 0xFFF);
      } on CredentialStoreError catch (e) {
        throw WriteFailure('cannot keep permissions: ${e.message}');
      }
    }
    await seams.beforeRename?.call();
    if (unchangedSince != null) {
      final now = await FileStat.stat(target);
      if (now.type != FileSystemEntityType.file ||
          now.size != unchangedSince.size ||
          now.modified != unchangedSince.modified) {
        throw const WriteFailure(changedDuringEdit);
      }
    }
    try {
      await (seams.rename ?? _rename)(temporary.path, target);
    } on Object catch (e) {
      final reason = e is FileSystemException ? e.message : '$e';
      throw WriteFailure('rename failed: $reason');
    }
  } on Object {
    try {
      if (temporary.existsSync()) temporary.deleteSync();
    } on FileSystemException {
      // Nothing more can be done; the target itself is unchanged.
    }
    rethrow;
  }
}

Future<void> _rename(String from, String to) async {
  await File(from).rename(to);
}
