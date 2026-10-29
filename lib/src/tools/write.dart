/// The `write` tool: a whole file, written atomically (design D5).
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../permissions/workspace_paths.dart';
import 'atomic_write.dart';
import 'block_hash.dart';
import 'file_access.dart';
import 'tool.dart';

/// Writes a whole file, creating missing directories.
final class WriteTool implements Tool {
  /// Creates the tool.
  const WriteTool({this.seams = const FileWriteSeams()});

  /// The test seams.
  final FileWriteSeams seams;

  @override
  Future<ToolOutcome> run(ToolContext context, Map<String, Object?> input) {
    final path = input['path']! as String;
    final absolute = absolutePath(context.workspace, path);
    final denied = credentialDenial(context, absolute);
    if (denied != null) return Future.value(denied);
    // Write through a link instead of replacing it.
    final target = realPath(absolute) ?? absolute;
    return PathLocks.run(
      target,
      () => _write(path, target, input['content']! as String),
    );
  }

  Future<ToolOutcome> _write(String path, String target, String content) async {
    final existed = FileSystemEntity.typeSync(target);
    if (existed == FileSystemEntityType.directory) {
      return failure('$path is a directory');
    }
    final bytes = Uint8List.fromList(utf8.encode(content));
    try {
      Directory(File(target).parent.path).createSync(recursive: true);
    } on FileSystemException catch (e) {
      return failure('cannot create the directory of $path: ${e.message}');
    }
    try {
      await writeAtomically(target, bytes, seams: seams);
    } on WriteFailure catch (e) {
      return failure('could not write $path: ${e.message}');
    }
    final counter = BlockHasher(hashing: false, stopAtBlock: false)
      ..feed(bytes, 0, bytes.length)
      ..finishInput();
    final lines = counter.totalLines;
    final verb = existed == FileSystemEntityType.notFound
        ? 'created'
        : 'replaced';
    return ToolOutcome(
      summary:
          '$verb $path (${bytes.length} bytes, '
          '$lines ${lines == 1 ? 'line' : 'lines'})',
    );
  }
}
