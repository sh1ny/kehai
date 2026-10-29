/// The single-writer engine: validate, append, flush, then publish.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'errors.dart';
import 'fork.dart';
import 'journal.dart';
import 'ownership.dart';
import '../results/descriptor.dart';
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

/// What a [SessionWriter.applyGuarded] build step decides.
sealed class GuardedDecision {
  const GuardedDecision();
}

/// The build step wants [record] appended.
final class GuardedAppend extends GuardedDecision {
  /// Creates the decision to append [record].
  const GuardedAppend(this.record);

  /// The record to validate and append.
  final JournalRecord record;
}

/// The build step refuses; nothing is appended.
final class GuardedRefusal extends GuardedDecision {
  /// Creates a refusal with a stable [reason], such as `stale`.
  const GuardedRefusal(this.reason);

  /// The stable text naming why the guard failed.
  final String reason;
}

/// How a [SessionWriter.applyGuarded] call ended.
sealed class GuardedOutcome {
  const GuardedOutcome();
}

/// The built record was appended.
final class Applied extends GuardedOutcome {
  /// Creates the outcome for the committed [update].
  const Applied(this.update);

  /// The committed record.
  final CommittedUpdate update;
}

/// A guard refused and nothing was appended.
final class Refused extends GuardedOutcome {
  /// Creates a refusal with [reason] and, for `descriptors missing`, the
  /// [handles] that have no descriptor.
  const Refused(this.reason, [this.handles = const []]);

  /// The reason the build step gave, or `descriptors missing`.
  final String reason;

  /// The result handles lacking a descriptor, sorted; empty otherwise.
  final List<String> handles;

  @override
  String toString() =>
      handles.isEmpty ? reason : '$reason: ${handles.join(', ')}';
}

/// Reads the node at a path of the queue-head tree, or `null` when absent.
///
/// The returned node is a copy, so the caller may keep it.
typedef GuardedRead = Object? Function(String path);

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
    final id = newSessionId();
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
  Future<CommittedUpdate> apply(JournalRecord record) {
    final snapshot = _snapshot(record);
    return _enqueue<CommittedUpdate>(
      op: snapshot.op,
      path: snapshot.path,
      decide: () => snapshot,
      finish: (update) => update!,
    );
  }

  /// Appends the record that [build] decides on, or refuses.
  ///
  /// [build] runs inside the serialized decision, against the queue head: it
  /// sees every operation queued before this one, including a rewind. It
  /// returns a [GuardedAppend] or a [GuardedRefusal], which completes the
  /// call as a [Refused] and appends nothing; the ownership, launch, intent
  /// and cleanup guards of the callers live in [build]. Whatever [build]
  /// appends, every result handle its value references (an object with a
  /// `handle` of the form `r/<12 hex>`) must have its descriptor under
  /// `results/` at the queue head, else the call is refused with
  /// `descriptors missing` and the sorted handles. Errors thrown by [build]
  /// or by validation fail the call like [apply].
  Future<GuardedOutcome> applyGuarded(
    GuardedDecision Function(GuardedRead read) build,
  ) {
    Refused? refusal;
    return _enqueue<GuardedOutcome>(
      op: Op.set,
      path: '',
      decide: () {
        final decision = build(_state.get);
        switch (decision) {
          case GuardedRefusal(:final reason):
            refusal = Refused(reason);
            return null;
          case GuardedAppend(:final record):
            final frozen = _snapshot(record);
            final missing = <String>{};
            _collectHandles(frozen.value, missing);
            missing.removeWhere((handle) {
              final node = _state.get('results/${handle.substring(2)}');
              return node is Map<String, Object?> && node['handle'] == handle;
            });
            if (missing.isEmpty) return frozen;
            refusal = Refused('descriptors missing', missing.toList()..sort());
            return null;
        }
      },
      finish: (update) => refusal ?? Applied(update!),
    );
  }

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

  /// Creates a new session from the state at the end of turn [atTurn].
  ///
  /// The fork runs at the head of the queue from the acknowledged in-memory
  /// state, so it never sees a record whose flush has not completed. Every
  /// subtree except `meta` takes its end-of-turn value; `meta` is the current
  /// one except `meta/session` (the new id), `meta/lineage` (this session and
  /// [atTurn]) and `meta/requests` (empty). The result files the forked tree
  /// references are copied and verified first, and the child directory
  /// appears under the parent's directory only once complete. The parent
  /// journal is never written. The child has no owner; open it with
  /// [SessionWriter.open].
  ///
  /// A `broken` writer may still fork, since only acknowledged state is read
  /// and only the child is written. Fails with a [SessionError] with reason
  /// `invalid fork turn` when [atTurn] is outside the origin turn to the
  /// current turn, and with reason `fork failed` naming the handle when a
  /// result file cannot be copied; then nothing is left behind.
  Future<ForkResult> fork(int atTurn) {
    ForkResult? result;
    return _enqueue<ForkResult>(
      op: Op.set,
      path: '',
      allowBroken: true,
      decide: () => null,
      action: () async {
        final body = _state.bodyAtTurn(atTurn);
        final whole = _state.combined().toJson();
        final parentMeta = whole['meta'];
        final parentMetaMap = parentMeta is Map<String, Object?>
            ? parentMeta
            : const <String, Object?>{};
        final meta = {
          ...parentMetaMap,
          'session': newSessionId(),
          'lineage': {'parent': parentMetaMap['session'], 'parentTurn': atTurn},
          'requests': <String, Object?>{},
        };
        final origin = JournalRecord(
          turn: atTurn,
          path: '',
          op: Op.set,
          value: {...body.toJson(), 'meta': meta},
        );
        result = await writeFork(
          sessionDir,
          meta['session']! as String,
          origin,
        );
      },
      finish: (_) => result!,
    );
  }

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
      _settle(id, {'state': 'completed', 'outcome': _freeze(outcome)});

  /// Marks admitted request [id] as `failed`, with an optional [reason] and
  /// [outcome].
  ///
  /// Fails with a [SessionError] when the request is unknown or not
  /// `admitted`.
  Future<CommittedUpdate> fail(String id, {String? reason, Object? outcome}) =>
      _settle(id, {
        'state': 'failed',
        'reason': ?reason,
        'outcome': ?_freeze(outcome),
      });

  /// Records [descriptor] at `results/<id>` as one serialized operation.
  ///
  /// Completes with `null` and appends nothing when the node already holds an
  /// equal descriptor, so storing the same bytes again is idempotent. Fails
  /// with a [SessionError] with reason `handle collision` when the node holds
  /// a descriptor with a different `sha256`, or when the handle is not
  /// `r/` plus the first 12 hex digits of the hash. A malformed descriptor
  /// (see [ResultDescriptor.validate]) fails with reason
  /// `invalid result descriptor`.
  Future<CommittedUpdate?> recordResult(ResultDescriptor descriptor) {
    try {
      descriptor.validate();
    } on ResultError catch (e) {
      return Future.error(
        SessionError('invalid result descriptor', e.message, op: 'set'),
      );
    }
    final id = descriptor.handle.startsWith('r/')
        ? descriptor.handle.substring(2)
        : descriptor.handle;
    final path = 'results/$id';
    return _enqueue<CommittedUpdate?>(
      op: Op.set,
      path: path,
      decide: () {
        final valid =
            id.length == 12 &&
            descriptor.handle == 'r/$id' &&
            descriptor.sha256.startsWith(id);
        final node = valid ? _state.get(path) : null;
        final recorded = node is Map<String, Object?> ? node : null;
        if (!valid ||
            recorded != null && recorded['sha256'] != descriptor.sha256) {
          throw SessionError(
            'handle collision',
            'handle ${descriptor.handle} does not match the hash '
                '${descriptor.sha256} or holds a different result',
            op: 'set',
            path: path,
          );
        }
        if (recorded != null && _sameFacts(recorded, descriptor)) return null;
        return JournalRecord(
          turn: currentTurn,
          path: path,
          op: Op.set,
          value: descriptor.toJson(),
        );
      },
      finish: (update) => update,
    );
  }

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
    final requests = _state.get(_requestsPath);
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
    final node = _state.get(path);
    return node is Map<String, Object?> ? node : null;
  }

  Future<T> _enqueue<T>({
    required Op op,
    required String path,
    required JournalRecord? Function() decide,
    required T Function(CommittedUpdate? update) finish,
    Future<void> Function()? action,
    bool allowBroken = false,
  }) {
    if (_closing || _writerState == WriterState.closed) {
      return Future.error(_refusal('writer closed', op, path));
    }
    if (_writerState == WriterState.broken && !allowBroken) {
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
        action: action,
        allowBroken: allowBroken,
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
    final usable =
        _writerState == WriterState.ready ||
        pending.allowBroken && _writerState == WriterState.broken;
    if (!usable) {
      pending.onError(_refusal('writer broken', pending.op, pending.path));
      return;
    }
    final action = pending.action;
    if (action != null) {
      try {
        await action();
      } on Object catch (e) {
        pending.onError(e);
        return;
      }
      pending.onDone(null);
      return;
    }
    final JournalRecord? record;
    try {
      final decided = pending.decide();
      record = decided == null ? null : _snapshot(decided);
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

/// The containers already frozen by [_freeze], so they are never copied again.
final Expando<bool> _frozen = Expando<bool>('frozen record value');

/// Returns [record] with a deeply unmodifiable copy of its value.
///
/// The writer validates, encodes, retains and publishes only the returned
/// record, so a caller mutating the value it passed in can change none of
/// them. A record whose value is already frozen is returned as it is.
JournalRecord _snapshot(JournalRecord record) {
  final value = _freeze(record.value);
  return identical(value, record.value)
      ? record
      : JournalRecord(
          turn: record.turn,
          path: record.path,
          op: record.op,
          value: value,
        );
}

/// Returns a deeply unmodifiable copy of [value], or [value] when it is
/// a scalar or was frozen before.
///
/// Values that are not plain JSON are copied as far as maps and lists go and
/// left for validation to reject.
Object? _freeze(Object? value) {
  switch (value) {
    case final Map<Object?, Object?> map:
      if (_frozen[map] ?? false) return map;
      final copy = <Object?, Object?>{
        for (final MapEntry(:key, :value) in map.entries) key: _freeze(value),
      };
      final frozen = copy.keys.every((key) => key is String)
          ? Map<String, Object?>.unmodifiable(copy.cast<String, Object?>())
          : Map<Object?, Object?>.unmodifiable(copy);
      _frozen[frozen] = true;
      return frozen;
    case final List<Object?> list:
      if (_frozen[list] ?? false) return list;
      final frozen = List<Object?>.unmodifiable(list.map(_freeze));
      _frozen[frozen] = true;
      return frozen;
    default:
      return value;
  }
}

final RegExp _resultHandle = RegExp(r'^r/[0-9a-f]{12}$');

/// Adds to [out] the handle of every result reference in [value].
///
/// A reference is an object `{handle, complete}` (ADR 0010). A bare `handle`
/// field, such as a `read_more` call's input, names a result without
/// installing a reference to it, so it is not checked.
void _collectHandles(Object? value, Set<String> out) {
  switch (value) {
    case final Map<Object?, Object?> map:
      final handle = map['handle'];
      if (handle is String &&
          map['complete'] is bool &&
          _resultHandle.hasMatch(handle)) {
        out.add(handle);
      }
      for (final child in map.values) {
        _collectHandles(child, out);
      }
    case final List<Object?> list:
      for (final child in list) {
        _collectHandles(child, out);
      }
  }
}

/// Whether [node] holds exactly the facts of [descriptor].
bool _sameFacts(Map<String, Object?> node, ResultDescriptor descriptor) {
  final json = descriptor.toJson();
  return node.length == json.length &&
      json.entries.every((e) => node[e.key] == e.value);
}

/// One queued operation. [decide] runs at the head of the queue and returns
/// the record to append, or `null` when nothing is to be written.
final class _Pending {
  _Pending(
    this.op,
    this.path,
    this.decide,
    this.onDone,
    this.onError, {
    this.action,
    this.allowBroken = false,
  });

  final Op op;
  final String path;
  final JournalRecord? Function() decide;
  final void Function(CommittedUpdate? update) onDone;
  final void Function(Object error) onError;

  /// An operation that writes no journal record, run instead of [decide].
  final Future<void> Function()? action;

  /// Whether the operation may run on a `broken` writer.
  final bool allowBroken;
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
