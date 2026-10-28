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
import 'ownership.dart';
import 'path.dart';
import 'record.dart';
import 'requests.dart';
import 'state.dart';
import 'tree.dart';

const String _requestsPath = 'meta/requests';

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
    this._ownership,
  );

  /// Creates a new session in a fresh directory under [root].
  ///
  /// The directory is named `<yyyyMMddTHHmmssZ>-<8 hex>` and its journal
  /// starts with one origin record at turn 0. [decorate] wraps the file layer.
  static Future<SessionWriter> create(
    Directory root, {
    JournalIoDecorator? decorate,
    OwnershipHooks? hooks,
  }) async {
    final random = Random.secure();
    final suffix = List.generate(
      8,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
    final id = '${compactUtc(DateTime.now())}-$suffix';
    final dir = Directory(p.join(root.path, id))..createSync(recursive: true);
    final ownership = await Ownership.claim(dir, hooks: hooks);
    try {
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
      return SessionWriter._(dir, state, io, bytes.length, 1, null, ownership);
    } on Object {
      await _releaseQuietly(ownership);
      rethrow;
    }
  }

  /// Opens the existing session in [sessionDir] for writing.
  ///
  /// Ownership is claimed first, before the journal is touched. Torn bytes
  /// after the last newline are then copied to a recovery file and cut from
  /// the journal; see [tornTail]. Every request still `admitted` is then
  /// recorded as `interrupted` with reason `effect-uncertain`, counted by
  /// [interruptedRequests], before the writer is returned. A storage failure
  /// there fails the open with a [StorageError] and releases the session. Throws a [SessionError] with reason
  /// `session locked` when another writer holds the session, and a
  /// [JournalCorruption] without modifying the journal when a committed line
  /// is invalid. A takeover of a dead process's session is reported by
  /// [takeover].
  static Future<SessionWriter> open(
    Directory sessionDir, {
    JournalIoDecorator? decorate,
    OwnershipHooks? hooks,
  }) async {
    final ownership = await Ownership.claim(sessionDir, hooks: hooks);
    try {
      final journal = File(p.join(sessionDir.path, journalFileName));
      final scan = scanJournal(journal);
      final torn = scan.trailingBytes > 0
          ? recoverTornTail(sessionDir, journal, scan)
          : null;
      final io = await _openIo(sessionDir, decorate);
      final writer = SessionWriter._(
        sessionDir,
        scan.state,
        io,
        scan.committedLength,
        scan.recordCount,
        torn,
        ownership,
      );
      try {
        await writer._finalizeRequests();
      } on Object {
        await writer.close();
        rethrow;
      }
      return writer;
    } on Object {
      await _releaseQuietly(ownership);
      rethrow;
    }
  }

  /// The session directory.
  final Directory sessionDir;

  /// The torn tail found and set aside when opening, or `null`.
  final TornTail? tornTail;

  /// The takeover performed when opening, or `null` for a clean claim.
  Takeover? get takeover => _ownership.takeover;

  final Ownership _ownership;
  final SessionState _state;
  final JournalIo _io;
  int _length;
  int _lines;
  int _interrupted = 0;

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
  Future<CommittedUpdate> apply(JournalRecord record) =>
      _enqueue<CommittedUpdate>(
        op: record.op,
        path: record.path,
        decide: () => record,
        finish: (update) => update!,
      );

  /// Rewinds the non-`meta` subtrees to the end of turn [turn].
  ///
  /// Appends one `rewind` record carrying the current turn. Fails with a
  /// [SessionError] with reason `invalid rewind target` when [turn] is not an
  /// allowed target, and appends nothing.
  Future<CommittedUpdate> rewind(int turn) => _enqueue<CommittedUpdate>(
    op: Op.rewind,
    path: '',
    decide: () =>
        JournalRecord(turn: currentTurn, path: '', op: Op.rewind, value: turn),
    finish: (update) => update!,
  );

  /// Admits request [id] with [fingerprint] as one serialized operation.
  ///
  /// The lookup, the fingerprint comparison and the append run together at
  /// the head of the queue. The result tells whether this call newly admitted
  /// the request, which is then the only caller allowed to execute it. A known
  /// id with the same fingerprint returns the recorded node and appends
  /// nothing. A different fingerprint throws a [RequestCollision]. An [id]
  /// that is not a single valid path segment fails with `invalid path`.
  Future<Admission> admit(String id, String fingerprint) {
    Admission? known;
    return _enqueue<Admission>(
      op: Op.set,
      path: '$_requestsPath/$id',
      decide: () {
        final path = _requestPath(id);
        final node = _requestNode(path);
        if (node == null) {
          return JournalRecord(
            turn: currentTurn,
            path: path,
            op: Op.set,
            value: {
              'fingerprint': fingerprint,
              'state': 'admitted',
              'turn': currentTurn,
            },
          );
        }
        if (node['fingerprint'] != fingerprint) throw RequestCollision(id);
        known = Admission.existing(node);
        return null;
      },
      finish: (_) => known ?? const Admission.newlyAdmitted(),
    );
  }

  /// Records the [outcome] of admitted request [id] and marks it `completed`.
  ///
  /// Fails with a [SessionError] when the request is unknown or not
  /// `admitted`.
  Future<CommittedUpdate> complete(String id, Object? outcome) =>
      _settle(id, {'state': 'completed', 'outcome': outcome});

  /// Marks admitted request [id] as `failed`, with an optional [reason] and
  /// [outcome].
  ///
  /// Fails with a [SessionError] when the request is unknown or not
  /// `admitted`.
  Future<CommittedUpdate> fail(String id, {String? reason, Object? outcome}) =>
      _settle(id, {'state': 'failed', 'reason': ?reason, 'outcome': ?outcome});

  /// The number of requests recorded as interrupted when this writer opened.
  int get interruptedRequests => _interrupted;

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
    await _ownership.release();
  }

  Future<CommittedUpdate> _settle(String id, Map<String, Object?> change) {
    return _enqueue<CommittedUpdate>(
      op: Op.merge,
      path: '$_requestsPath/$id',
      decide: () {
        final path = _requestPath(id);
        final node = _requestNode(path);
        if (node == null) {
          throw SessionError(
            'unknown request',
            'request "$id" was never admitted',
            op: 'merge',
            path: path,
          );
        }
        if (node['state'] != 'admitted') {
          throw SessionError(
            'request not admitted',
            'request "$id" is already ${node['state']}',
            op: 'merge',
            path: path,
          );
        }
        return JournalRecord(
          turn: currentTurn,
          path: path,
          op: Op.merge,
          value: change,
        );
      },
      finish: (update) => update!,
    );
  }

  Future<void> _finalizeRequests() async {
    final requests = _state.combined().get(SessionPath.parse(_requestsPath));
    if (requests is! Map<String, Object?>) return;
    final ids = [
      for (final MapEntry(:key, :value) in requests.entries)
        if (value is Map<String, Object?> && value['state'] == 'admitted') key,
    ]..sort();
    for (final id in ids) {
      await _settle(id, {'state': 'interrupted', 'reason': 'effect-uncertain'});
      _interrupted++;
    }
  }

  String _requestPath(String id) {
    final path = '$_requestsPath/$id';
    if (id.contains('/')) {
      throw SessionError(
        'invalid path',
        'request id "$id" must be a single path segment',
        op: 'set',
        path: path,
      );
    }
    SessionPath.parse(path);
    return path;
  }

  Map<String, Object?>? _requestNode(String path) {
    final node = _state.combined().get(SessionPath.parse(path));
    return node is Map<String, Object?> ? node : null;
  }

  Future<T> _enqueue<T>({
    required Op op,
    required String path,
    required JournalRecord? Function() decide,
    required T Function(CommittedUpdate? update) finish,
  }) {
    if (_closing || _writerState == WriterState.closed) {
      return Future.error(_refusal('writer closed', op, path));
    }
    if (_writerState == WriterState.broken) {
      return Future.error(_refusal('writer broken', op, path));
    }
    if (_pending >= maxPendingOperations) {
      throw SessionError(
        'writer busy',
        'at most $maxPendingOperations operations may be pending',
        op: op.wire,
        path: path,
      );
    }
    _pending++;
    final completer = Completer<T>();
    _queue.add(
      _Pending(
        op,
        path,
        decide,
        (update) => completer.complete(finish(update)),
        completer.completeError,
      ),
    );
    if (!_running) {
      _running = true;
      _drained = _run();
    }
    return completer.future;
  }

  SessionError _refusal(String reason, Op op, String path) => SessionError(
    reason,
    'the session must be reopened',
    op: op.wire,
    path: path,
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
    if (_writerState != WriterState.ready) {
      pending.onError(_refusal('writer broken', pending.op, pending.path));
      return;
    }
    final JournalRecord? record;
    try {
      record = pending.decide();
      if (record != null) _state.validate(record);
    } on SessionError catch (e) {
      pending.onError(e);
      return;
    } on RequestCollision catch (e) {
      pending.onError(e);
      return;
    }
    if (record == null) {
      pending.onDone(null);
      return;
    }
    final bytes = utf8.encode(record.encode());
    try {
      await _io.writeFrom(bytes);
      await _io.flush();
    } on Object catch (e) {
      _writerState = WriterState.broken;
      pending.onError(StorageError('could not append the record', e));
      return;
    }
    final update = CommittedUpdate(record, _length, _lines + 1);
    _length += bytes.length;
    _lines++;
    _state.commit(record);
    _publish(update);
    pending.onDone(update);
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

/// One queued operation. [decide] runs at the head of the queue and returns
/// the record to append, or `null` when nothing is to be written.
final class _Pending {
  _Pending(this.op, this.path, this.decide, this.onDone, this.onError);

  final Op op;
  final String path;
  final JournalRecord? Function() decide;
  final void Function(CommittedUpdate? update) onDone;
  final void Function(Object error) onError;
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

Future<void> _releaseQuietly(Ownership ownership) async {
  try {
    await ownership.release();
  } on Object {
    // The original failure is the one worth reporting.
  }
}
