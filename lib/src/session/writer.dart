/// The single-writer engine: validate, append, flush, then publish.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import 'errors.dart';
import 'journal.dart';
import 'record.dart';
import 'state.dart';
import 'tree.dart';

/// The most operations that may be pending, including the one in progress.
const int maxPendingOperations = 64;

/// The most undelivered updates a subscriber may hold before it is cut off.
const int subscriberBufferSize = 1024;

/// The lifecycle of a [SessionWriter].
///
/// A writer starts `ready`, becomes `broken` after a failed write or flush
/// and `closed` after [SessionWriter.close].
enum WriterState {
  /// The writer accepts operations.
  ready,

  /// A storage failure occurred; the session must be reopened.
  broken,

  /// The writer released the journal.
  closed,
}

/// A record that was durably appended and published.
final class CommittedUpdate {
  /// Creates an update for [record] at byte [offset] on 1-based [line].
  const CommittedUpdate(this.record, this.offset, this.line);

  /// The appended record.
  final JournalRecord record;

  /// The byte offset of the start of the record's line.
  final int offset;

  /// The 1-based line number of the record.
  final int line;
}

/// A failed write or flush of the journal.
final class StorageError implements Exception {
  /// Creates an error described by [message] with an optional [cause].
  const StorageError(this.message, [this.cause]);

  /// The explanation of what failed.
  final String message;

  /// The underlying error, if any.
  final Object? cause;

  @override
  String toString() =>
      'StorageError: $message${cause == null ? '' : ': $cause'}';
}

/// The error that ends a subscriber's stream when it fell behind.
final class ResyncRequired implements Exception {
  /// Creates the error with the offset of the last update it received.
  const ResyncRequired(this.lastOffset);

  /// The byte offset of the last update queued for the subscriber, which is
  /// the last one it receives before this error.
  final int lastOffset;

  @override
  String toString() =>
      'ResyncRequired: resync required after offset $lastOffset';
}

/// The file operations the writer needs, so tests can inject failures.
abstract interface class JournalIo {
  /// Writes all of [bytes] at the end of the journal.
  Future<void> writeFrom(List<int> bytes);

  /// Forces written bytes to stable storage.
  Future<void> flush();

  /// Releases the file.
  Future<void> close();
}

/// Wraps the real journal file operations, for example to inject faults.
typedef JournalIoDecorator = JournalIo Function(JournalIo inner);

/// The production [JournalIo] over a [RandomAccessFile] in append mode.
final class FileJournalIo implements JournalIo {
  /// Creates the file layer over [file].
  FileJournalIo(this._file);

  final RandomAccessFile _file;

  @override
  Future<void> writeFrom(List<int> bytes) => _file.writeFrom(bytes);

  @override
  Future<void> flush() => _file.flush();

  @override
  Future<void> close() => _file.close();
}

/// Appends records to one session journal.
///
/// Operations go through one queue handled by a single loop, so each record is
/// validated against the tree left by the one before it and bytes never
/// interleave. A record is validated, written, flushed to stable storage and
/// only then folded into the tree, published to subscribers and acknowledged.
/// After a failed write or flush the writer is `broken` and refuses
/// operations until the session is reopened.
final class SessionWriter {
  SessionWriter._(
    this.sessionDir,
    this._state,
    this._io,
    this._length,
    this._lines,
    this.tornTail,
  );

  /// Creates a new session in a fresh directory under [root].
  ///
  /// The directory is named `<yyyyMMddTHHmmssZ>-<8 hex>` and its journal
  /// starts with one origin record at turn 0. [decorate] wraps the file layer.
  static Future<SessionWriter> create(
    Directory root, {
    JournalIoDecorator? decorate,
  }) async {
    final random = Random.secure();
    final suffix = List.generate(
      8,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    final id = '${compactUtc(DateTime.now())}-$suffix';
    final dir = Directory(p.join(root.path, id))..createSync(recursive: true);
    final origin = JournalRecord(
      turn: 0,
      path: '',
      op: Op.set,
      value: {
        'meta': {
          'format': sessionFormatVersion,
          'session': id,
          'lineage': {'parent': null},
        },
      },
    );
    final state = SessionState.fromOrigin(origin);
    final io = await _openIo(dir, decorate);
    final bytes = utf8.encode(origin.encode());
    try {
      await io.writeFrom(bytes);
      await io.flush();
    } on Object catch (e) {
      await _closeQuietly(io);
      throw StorageError('could not write the origin record', e);
    }
    _writeOwner(dir);
    return SessionWriter._(dir, state, io, bytes.length, 1, null);
  }

  /// Opens the existing session in [sessionDir] for writing.
  ///
  /// Torn bytes after the last newline are copied to a recovery file and cut
  /// from the journal; see [tornTail]. Throws a [JournalCorruption] without
  /// modifying the journal when a committed line is invalid.
  static Future<SessionWriter> open(
    Directory sessionDir, {
    JournalIoDecorator? decorate,
  }) async {
    final journal = File(p.join(sessionDir.path, journalFileName));
    final scan = scanJournal(journal);
    final torn = scan.trailingBytes > 0
        ? recoverTornTail(sessionDir, journal, scan)
        : null;
    final io = await _openIo(sessionDir, decorate);
    _writeOwner(sessionDir);
    return SessionWriter._(
      sessionDir,
      scan.state,
      io,
      scan.committedLength,
      scan.recordCount,
      torn,
    );
  }

  /// The session directory.
  final Directory sessionDir;

  /// The torn tail found and set aside when opening, or `null`.
  final TornTail? tornTail;

  final SessionState _state;
  final JournalIo _io;
  int _length;
  int _lines;

  WriterState _writerState = WriterState.ready;
  bool _closing = false;
  Future<void>? _closeFuture;

  final Queue<_Pending> _queue = Queue();
  int _pending = 0;
  bool _running = false;
  Future<void>? _drained;

  final List<_Subscriber> _subscribers = [];

  /// The current turn of the acknowledged state.
  int get currentTurn => _state.currentTurn;

  /// A copy of the acknowledged tree, including `meta`.
  ///
  /// This is the state a fork would take: it holds only records whose flush
  /// completed.
  SessionTree get tree => _state.combined();

  /// The lifecycle state of the writer.
  WriterState get state => _writerState;

  /// Validates, appends and publishes [record].
  ///
  /// The future completes with the committed update after the record was
  /// flushed. It fails with a [SessionError] when the record is invalid, or a
  /// [StorageError] when the write or flush failed, which also breaks the
  /// writer. When [maxPendingOperations] operations are already pending this
  /// throws a [SessionError] with reason `writer busy` synchronously and
  /// queues nothing.
  Future<CommittedUpdate> apply(JournalRecord record) {
    if (_closing || _writerState == WriterState.closed) {
      return Future.error(_refusal('writer closed', record));
    }
    if (_writerState == WriterState.broken) {
      return Future.error(_refusal('writer broken', record));
    }
    if (_pending >= maxPendingOperations) {
      throw SessionError(
        'writer busy',
        'at most $maxPendingOperations operations may be pending',
        op: record.op.wire,
        path: record.path,
      );
    }
    _pending++;
    final pending = _Pending(record);
    _queue.add(pending);
    if (!_running) {
      _running = true;
      _drained = _run();
    }
    return pending.completer.future;
  }

  /// Like [apply], for a request that names its operation by wire name.
  ///
  /// An [op] outside the vocabulary fails with reason `unsupported op`
  /// naming the op and [path] before anything is written.
  Future<CommittedUpdate> applyWire({
    required int turn,
    required String path,
    required String op,
    Object? value,
  }) {
    final parsed = Op.fromWire(op);
    if (parsed == null) {
      return Future.error(
        SessionError('unsupported op', 'unknown operation', op: op, path: path),
      );
    }
    return apply(
      JournalRecord(turn: turn, path: path, op: parsed, value: value),
    );
  }

  /// Returns a stream of updates committed from now on.
  ///
  /// The subscriber buffers at most [subscriberBufferSize] undelivered
  /// updates. When it falls further behind its stream receives a
  /// [ResyncRequired] error and ends, while the writer and other subscribers
  /// carry on.
  Stream<CommittedUpdate> subscribe() {
    final subscriber = _Subscriber();
    if (_writerState == WriterState.closed) {
      unawaited(subscriber.controller.close());
    } else {
      _subscribers.add(subscriber);
      subscriber.controller.onCancel = () => _subscribers.remove(subscriber);
    }
    return subscriber.controller.stream.map((update) {
      subscriber.undelivered--;
      return update;
    });
  }

  /// Finishes pending operations, then releases the journal and owner file.
  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    await _drained;
    _writerState = WriterState.closed;
    await _closeQuietly(_io);
    for (final subscriber in _subscribers.toList()) {
      unawaited(subscriber.controller.close());
    }
    _subscribers.clear();
    _deleteOwner(sessionDir);
  }

  SessionError _refusal(String reason, JournalRecord record) => SessionError(
    reason,
    'the session must be reopened',
    op: record.op.wire,
    path: record.path,
  );

  Future<void> _run() async {
    try {
      while (_queue.isNotEmpty) {
        final pending = _queue.removeFirst();
        try {
          await _process(pending);
        } finally {
          _pending--;
        }
      }
    } finally {
      _running = false;
    }
  }

  Future<void> _process(_Pending pending) async {
    final record = pending.record;
    if (_writerState != WriterState.ready) {
      pending.completer.completeError(_refusal('writer broken', record));
      return;
    }
    try {
      _state.validate(record);
    } on SessionError catch (e) {
      pending.completer.completeError(e);
      return;
    }
    final bytes = utf8.encode(record.encode());
    try {
      await _io.writeFrom(bytes);
      await _io.flush();
    } on Object catch (e) {
      _writerState = WriterState.broken;
      pending.completer.completeError(
        StorageError('could not append the record', e),
      );
      return;
    }
    final update = CommittedUpdate(record, _length, _lines + 1);
    _length += bytes.length;
    _lines++;
    _state.commit(record);
    _publish(update);
    pending.completer.complete(update);
  }

  void _publish(CommittedUpdate update) {
    for (final subscriber in _subscribers.toList()) {
      if (subscriber.undelivered >= subscriberBufferSize) {
        subscriber.controller.addError(ResyncRequired(subscriber.lastOffset));
        unawaited(subscriber.controller.close());
        _subscribers.remove(subscriber);
      } else {
        subscriber.undelivered++;
        subscriber.lastOffset = update.offset;
        subscriber.controller.add(update);
      }
    }
  }
}

final class _Pending {
  _Pending(this.record);

  final JournalRecord record;
  final Completer<CommittedUpdate> completer = Completer();
}

final class _Subscriber {
  final StreamController<CommittedUpdate> controller = StreamController();
  int undelivered = 0;
  int lastOffset = -1;
}

Future<JournalIo> _openIo(Directory dir, JournalIoDecorator? decorate) async {
  final file = await File(p.join(dir.path, journalFileName))
      .open(mode: FileMode.append);
  final io = FileJournalIo(file);
  return decorate == null ? io : decorate(io);
}

Future<void> _closeQuietly(JournalIo io) async {
  try {
    await io.close();
  } on Object {
    // Closing a broken file layer must not hide the original failure.
  }
}

// Ownership placeholder: group 5 replaces this with the gate/lock protocol.
// It records who writes the session so read-only materialization can report
// `observed`. Written as a temp file, flushed, then renamed into place.
void _writeOwner(Directory dir) {
  final random = Random.secure();
  final nonce = List.generate(
    16,
    (_) => random.nextInt(16).toRadixString(16),
  ).join();
  final temp = File(p.join(dir.path, '$ownerFileName.tmp'));
  final out = temp.openSync(mode: FileMode.write);
  try {
    out.writeStringSync(
      jsonEncode({
        'pid': pid,
        'nonce': nonce,
        'startedUtc': DateTime.now().toUtc().toIso8601String(),
      }),
    );
    out.flushSync();
  } finally {
    out.closeSync();
  }
  temp.renameSync(p.join(dir.path, ownerFileName));
}

void _deleteOwner(Directory dir) {
  final owner = File(p.join(dir.path, ownerFileName));
  if (owner.existsSync()) owner.deleteSync();
}
