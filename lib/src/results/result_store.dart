/// Content-addressed storage of whole tool results.
library;

import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'descriptor.dart';

/// The session subdirectory that holds result bytes files.
const String resultsDirName = 'results';

/// Test seams around the file operations of [ResultStore].
final class ResultStoreHooks {
  /// Creates hooks; every callback is optional.
  const ResultStoreHooks({
    this.beforeWrite,
    this.afterWrite,
    this.beforeFlush,
    this.beforeRename,
  });

  /// Runs before chunk number `index` is written; may throw to inject a fault.
  final Future<void> Function(int index, List<int> chunk)? beforeWrite;

  /// Runs after chunk number `index` was written.
  final void Function(int index)? afterWrite;

  /// Runs before the temporary file is flushed; may throw.
  final Future<void> Function()? beforeFlush;

  /// Runs before the temporary file is renamed; may throw.
  final Future<void> Function()? beforeRename;
}

/// The outcome of [ResultStore.storeResult].
sealed class ResultWrite {
  const ResultWrite();
}

/// The producer's stream ended normally.
final class ResultComplete extends ResultWrite {
  /// Creates the outcome for the stored [descriptor].
  const ResultComplete(this.descriptor);

  /// The facts about the stored bytes.
  final ResultDescriptor descriptor;
}

/// The producer's stream errored; the accepted prefix was stored.
final class ResultProducerFailed extends ResultWrite {
  /// Creates the outcome for the stored prefix [descriptor] and [error].
  const ResultProducerFailed(this.descriptor, this.error);

  /// The facts about the stored prefix.
  final ResultDescriptor descriptor;

  /// The error the producer's stream emitted.
  final Object error;
}

/// A disk write, flush or rename failed; nothing was stored.
final class ResultStorageFailed extends ResultWrite {
  /// Creates the outcome.
  const ResultStorageFailed(this.bytesAccepted, this.tempPath, this.error);

  /// The bytes written before the failure.
  final int bytesAccepted;

  /// The kept, unreferenced temporary file.
  final String tempPath;

  /// The underlying failure.
  final Object error;

  /// The text shown to the caller.
  String get message =>
      'result storage failed after $bytesAccepted bytes were accepted; '
      'the unreferenced temporary file is $tempPath: $error';
}

/// Stores result bytes of one session.
///
/// Chunks are written to `results/.tmp-<random>` one at a time. The store
/// awaits each write before the producer is asked for the next chunk, hashes
/// and counts as it goes, then flushes, closes and renames the file to
/// `results/<sha256>`. Chunks are never split or altered.
final class ResultStore {
  /// Creates a store writing under `<sessionDir>/results`.
  ResultStore(this.sessionDir, {this.hooks = const ResultStoreHooks()});

  /// The session directory.
  final Directory sessionDir;

  /// The injected test seams.
  final ResultStoreHooks hooks;

  /// Stores [source] whole and returns the outcome.
  ///
  /// When the stream errors, every chunk received so far is already on disk,
  /// so the prefix is finalized and returned as a [ResultProducerFailed]. When
  /// a write, flush or rename fails, the producer subscription is cancelled
  /// and a [ResultStorageFailed] is returned; the temporary file is kept. When
  /// the final name already exists with the same size the temporary file is
  /// deleted; an existing file of another size is replaced.
  Future<ResultWrite> storeResult(Stream<List<int>> source) async {
    final dir = Directory(p.join(sessionDir.path, resultsDirName))
      ..createSync(recursive: true);
    final tempPath = p.join(dir.path, '.tmp-${_randomSuffix()}');
    var accepted = 0;
    var lines = 0;
    var lastByte = -1;
    final sink = _DigestSink();
    final hash = sha256.startChunkedConversion(sink);
    RandomAccessFile? file;
    Object? storageError;
    Object? producerError;
    try {
      file = await File(tempPath).open(mode: FileMode.writeOnly);
      var index = 0;
      try {
        await for (final chunk in source) {
          try {
            await hooks.beforeWrite?.call(index, chunk);
            await file.writeFrom(chunk);
          } on Object catch (e) {
            storageError = e;
            break;
          }
          hash.add(chunk);
          accepted += chunk.length;
          for (final b in chunk) {
            if (b == 0x0a) lines++;
          }
          if (chunk.isNotEmpty) lastByte = chunk.last;
          hooks.afterWrite?.call(index);
          index++;
        }
      } on Object catch (e) {
        producerError = e;
      }
      if (storageError == null) {
        try {
          await hooks.beforeFlush?.call();
          await file.flush();
          await file.close();
          file = null;
        } on Object catch (e) {
          storageError = e;
        }
      }
    } on Object catch (e) {
      storageError = e;
    }
    if (storageError != null) {
      await _closeQuietly(file);
      return ResultStorageFailed(accepted, tempPath, storageError);
    }
    hash.close();
    if (accepted > 0 && lastByte != 0x0a) lines++;
    final digest = sink.value.toString();
    final descriptor = ResultDescriptor(
      handle: 'r/${digest.substring(0, 12)}',
      sha256: digest,
      bytes: accepted,
      lines: lines,
    );
    try {
      await hooks.beforeRename?.call();
      final target = File(p.join(dir.path, digest));
      if (target.existsSync() && target.lengthSync() == accepted) {
        await File(tempPath).delete();
      } else {
        if (target.existsSync()) await target.delete();
        await File(tempPath).rename(target.path);
      }
    } on Object catch (e) {
      return ResultStorageFailed(accepted, tempPath, e);
    }
    return producerError == null
        ? ResultComplete(descriptor)
        : ResultProducerFailed(descriptor, producerError);
  }
}

String _randomSuffix() {
  final random = Random.secure();
  return List.generate(16, (_) => random.nextInt(16).toRadixString(16)).join();
}

Future<void> _closeQuietly(RandomAccessFile? file) async {
  try {
    await file?.close();
  } on Object {
    // The storage failure being reported is the one worth keeping.
  }
}

final class _DigestSink implements Sink<Digest> {
  late final Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
