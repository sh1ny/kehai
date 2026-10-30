/// A result written while its producer is still running.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'descriptor.dart';
import 'result_store.dart';

final RegExp _spoolName = RegExp(r'^\.spool-[A-Za-z0-9_-]+$');

/// Checks that [name] is a spool file name, so it cannot leave `results/`.
void checkSpoolName(String name) {
  if (!_spoolName.hasMatch(name)) {
    throw ResultError('invalid spool name "$name"');
  }
}

/// Counts bytes and lines and hashes what it is fed, in the way
/// [ResultStore.storeResult] does.
final class _Tally {
  _Tally() {
    _hash = sha256.startChunkedConversion(_Capture((d) => _digest = d));
  }

  late final ByteConversionSink _hash;
  late Digest _digest;
  int bytes = 0;
  int _lines = 0;
  int _lastByte = -1;

  void add(List<int> chunk) {
    _hash.add(chunk);
    bytes += chunk.length;
    for (final b in chunk) {
      if (b == 0x0a) _lines++;
    }
    if (chunk.isNotEmpty) _lastByte = chunk.last;
  }

  ResultDescriptor finish() {
    _hash.close();
    final digest = _digest.toString();
    return ResultDescriptor(
      handle: 'r/${digest.substring(0, 12)}',
      sha256: digest,
      bytes: bytes,
      lines: bytes > 0 && _lastByte != 0x0a ? _lines + 1 : _lines,
    );
  }
}

final class _Capture implements Sink<Digest> {
  _Capture(this._onDigest);

  final void Function(Digest) _onDigest;

  @override
  void add(Digest data) => _onDigest(data);

  @override
  void close() {}
}

/// Hashes the existing spool [file] and returns its descriptor.
Future<ResultDescriptor> describeSpool(File file) async {
  if (!file.existsSync()) {
    throw ResultError('spool missing: ${p.basename(file.path)}');
  }
  final tally = _Tally();
  await for (final chunk in file.openRead()) {
    tally.add(chunk);
  }
  return tally.finish();
}

/// One spool file `results/.spool-<launch>-<stream>` being written.
///
/// Every [write] is awaited, so the producer is never ahead of the disk by
/// more than the chunk in hand. The bytes are hashed and counted as they go.
final class LiveResult {
  /// Wraps the open [_file] for the spool [spoolName] of [_store].
  LiveResult(this._store, this.spoolName, this._file);

  final ResultStore _store;
  final RandomAccessFile _file;
  final _Tally _tally = _Tally();
  ResultDescriptor? _sealed;
  bool _closed = false;

  /// The spool file name under `results/`.
  final String spoolName;

  /// The bytes accepted so far.
  int get bytesAccepted => _tally.bytes;

  /// Writes [chunk] and completes once it is on its way to the disk.
  ///
  /// Throws a [StateError] after [seal]. A failed disk write rethrows its
  /// error, and the chunk is not counted.
  Future<void> write(List<int> chunk) async {
    if (_sealed != null) throw StateError('spool $spoolName is sealed');
    await _file.writeFrom(chunk);
    _tally.add(chunk);
  }

  /// Stores the accepted prefix of the spool as its own result.
  ///
  /// The spool is flushed first and left untouched; further writes continue.
  /// A failed flush is a [ResultStorageFailed], as a failed store is.
  Future<ResultWrite> snapshot() async {
    final accepted = _tally.bytes;
    final dir = p.join(_store.sessionDir.path, resultsDirName);
    if (_sealed == null) {
      try {
        await _file.flush();
      } on Object catch (e) {
        return ResultStorageFailed(accepted, p.join(dir, spoolName), e);
      }
    }
    var source = File(p.join(dir, spoolName));
    final sealed = _sealed;
    if (sealed != null && !source.existsSync()) {
      // Sealed and published: the bytes live under their content address.
      source = File(p.join(dir, sealed.sha256));
    }
    return _store.storeResult(source.openRead(0, accepted));
  }

  /// Flushes and closes the spool and returns its descriptor.
  ///
  /// The file keeps its spool name; [ResultStore.publish] renames it. Sealing
  /// again returns the same descriptor. A failed flush still closes the spool,
  /// so the handle never outlives it; the flush error is rethrown.
  Future<ResultDescriptor> seal() async {
    final sealed = _sealed;
    if (sealed != null) return sealed;
    try {
      await _file.flush();
    } finally {
      if (!_closed) {
        _closed = true;
        await _file.close();
      }
    }
    return _sealed = _tally.finish();
  }
}
