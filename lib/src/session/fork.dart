/// Creating a child session from a parent's acknowledged state.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../results/descriptor.dart';
import '../results/result_store.dart';
import 'errors.dart';
import 'journal.dart';
import 'record.dart';

/// The outcome of a successful [SessionWriter.fork].
final class ForkResult {
  /// Creates a result for the child [childId] stored in [childDir].
  const ForkResult(this.childId, this.childDir, this.copiedResults);

  /// The id of the new session, also the name of its directory.
  final String childId;

  /// The new session directory, which has no owner until it is opened.
  final Directory childDir;

  /// The number of result files copied into the child.
  final int copiedResults;
}

/// Writes the child session [childId] next to [parentDir] and returns it.
///
/// [origin] is the child's single origin record; its tree is the whole child
/// state. Every descriptor under `results` in it has its bytes file copied
/// from the parent, verified against the descriptor's SHA-256, into a
/// `.fork-<childId>.tmp` directory that is renamed into place at the end.
/// Any failure removes the temporary directory and throws a [SessionError]
/// with reason `fork failed` naming the failing handle where there is one.
/// The parent is only read.
Future<ForkResult> writeFork(
  Directory parentDir,
  String childId,
  JournalRecord origin,
) async {
  final root = parentDir.parent.path;
  final temp = Directory(p.join(root, '.fork-$childId.tmp'));
  try {
    temp.createSync();
    final copied = await _copyResults(parentDir, temp, origin.value);
    final journal = File(p.join(temp.path, journalFileName));
    final out = await journal.open(mode: FileMode.writeOnly);
    try {
      await out.writeFrom(utf8.encode(origin.encode()));
      await out.flush();
    } finally {
      await out.close();
    }
    final child = await temp.rename(p.join(root, childId));
    return ForkResult(childId, child, copied);
  } on Object catch (e) {
    try {
      if (temp.existsSync()) temp.deleteSync(recursive: true);
    } on Object {
      // The failure being reported is the one worth keeping.
    }
    if (e is SessionError && e.reason == 'fork failed') rethrow;
    throw SessionError('fork failed', e is ResultError ? e.message : '$e');
  }
}

Future<int> _copyResults(Directory from, Directory to, Object? tree) async {
  final results = tree is Map<Object?, Object?> ? tree['results'] : null;
  if (results is! Map<Object?, Object?>) return 0;
  final target = Directory(p.join(to.path, resultsDirName))..createSync();
  var copied = 0;
  for (final MapEntry(:key, :value) in results.entries) {
    final ResultDescriptor descriptor;
    try {
      descriptor = ResultDescriptor.fromJson(
        (value as Map<Object?, Object?>).cast<String, Object?>(),
      );
    } on Object {
      throw SessionError('fork failed', 'invalid result descriptor r/$key');
    }
    final source = File(p.join(from.path, resultsDirName, descriptor.sha256));
    if (!source.existsSync() || source.lengthSync() != descriptor.bytes) {
      throw SessionError(
        'fork failed',
        'result bytes missing for ${descriptor.handle}',
      );
    }
    final destination = File(p.join(target.path, descriptor.sha256));
    final digest = await _copyHashing(source, destination);
    if (digest != descriptor.sha256) {
      throw SessionError(
        'fork failed',
        'result bytes corrupt for ${descriptor.handle}',
      );
    }
    copied++;
  }
  return copied;
}

/// Copies [source] to [destination] in chunks and returns the SHA-256.
Future<String> _copyHashing(File source, File destination) async {
  final sink = _DigestSink();
  final hash = sha256.startChunkedConversion(sink);
  final out = await destination.open(mode: FileMode.writeOnly);
  try {
    await for (final chunk in source.openRead()) {
      hash.add(chunk);
      await out.writeFrom(chunk);
    }
    await out.flush();
  } finally {
    await out.close();
  }
  hash.close();
  return sink.value.toString();
}

final class _DigestSink implements Sink<Digest> {
  late final Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
