/// Recovery of job and call nodes that nobody owns (design D11, D12).
///
/// Two callers share it. [JobRecovery.resume] runs at attach, before any call
/// is admitted: it settles or orphans every launch record, then finalizes
/// every job and call node that still reads live. [JobRecovery.reconcile]
/// runs after a committed rewind, level-triggered: it does the same for the
/// nodes and records the runtime does not own.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../results/descriptor.dart';
import '../results/composer.dart';
import '../results/live_result.dart' show checkSpoolName;
import '../results/result_store.dart';
import '../session/mutations.dart';
import '../session/path.dart';
import '../session/record.dart';
import '../session/writer.dart';
import 'supervisor.dart';

const Set<String> _terminal = {'settled', 'failed', 'cancelled'};
const int _maxRetries = 16;

/// How [JobRecovery.clearLaunch] ended.
enum ClearOutcome {
  /// The launch record was removed.
  cleared,

  /// The record was already gone; nothing was appended.
  done,

  /// The job node still reads live with this launch; the record stays.
  unsettled,

  /// The job is gone or superseded and its output mapping is not recorded yet.
  unmapped,
}

/// What attach found and finalized (design D12).
final class ResumeReport {
  /// Creates a report.
  const ResumeReport({
    this.jobs = 0,
    this.calls = 0,
    this.orphans = 0,
    this.leftovers = 0,
    this.discarded = 0,
  });

  /// The report of a session with nothing to finalize.
  static const ResumeReport none = ResumeReport();

  /// Job nodes finalized.
  final int jobs;

  /// Call nodes finalized.
  final int calls;

  /// Launch records whose output mapping moved to `meta/orphans`.
  final int orphans;

  /// Content-addressed files that no reference or orphan record names. They
  /// are left in place.
  final int leftovers;

  /// Agent `result` spools deleted because their handoff intent was never
  /// committed (design D11).
  final int discarded;

  /// The number of nodes finalized, calls and jobs together.
  int get finalized => jobs + calls;

  /// The warning for the user, empty when nothing was finalized.
  String get warning => [
    if (finalized != 0 || orphans != 0)
      'processes of the previous engine may still run: no process id is '
          'stored to check',
    if (discarded != 0)
      '$discarded agent results discarded before their handoff',
  ].join('; ');

  @override
  String toString() =>
      'finalized $finalized nodes ($jobs jobs, $calls calls), $orphans '
      'launch records moved to meta/orphans, $leftovers unreferenced '
      'result files${warning.isEmpty ? '' : '; $warning'}';
}

final class _Counts {
  int jobs = 0;
  int calls = 0;
  int orphans = 0;
  int discarded = 0;
}

/// Finishes the work of owners that are gone.
final class JobRecovery {
  /// Creates recovery over [writer] and [store].
  ///
  /// [hooks] pause or fail recovery at the same boundaries the supervisor's
  /// handoff has, so a test can end an attach exactly there.
  JobRecovery(this.writer, this.store, {this.hooks = const JobHooks()});

  /// The session writer.
  final SessionWriter writer;

  /// The result store.
  final ResultStore store;

  /// The test seams.
  final JobHooks hooks;

  /// The engine's shared sequence, supplied by runtime or seeded on demand.
  MutationSequence? mutationSequence;

  /// Attach finalization: launch records first, then job nodes, then calls.
  ///
  /// Every step is decided from the tree and the disk alone, so a crash in
  /// the middle leaves a state the next attach handles the same way. A
  /// storage failure ends the walk and is rethrown.
  Future<ResumeReport> resume() async {
    final counts = await _walk(reason: 'interrupted');
    await _finishOwnedMutationOrphans();
    return ResumeReport(
      jobs: counts.jobs,
      calls: counts.calls,
      orphans: counts.orphans,
      leftovers: _leftovers(),
      discarded: counts.discarded,
    );
  }

  /// One level-triggered pass for the nodes the runtime does not own.
  ///
  /// [liveLaunches] are the launch tokens of the runtime's jobs and
  /// [liveCalls] the keys of its calls; they are left to their owners.
  /// Recovered nodes read `cancelled` with reason `rewound`.
  Future<void> reconcile({
    Set<String> liveLaunches = const {},
    Set<String> liveCalls = const {},
  }) async {
    await _walk(
      reason: 'rewound',
      liveLaunches: liveLaunches,
      liveCalls: liveCalls,
    );
  }

  /// Removes the launch record [launch] under the cleanup guard.
  ///
  /// Legal exactly when its job is terminal with this launch, or gone or
  /// superseded with the output mapping already under `meta/orphans`. A
  /// record that is already gone completes as [ClearOutcome.done] and
  /// appends nothing, so a repeated clear is harmless.
  Future<ClearOutcome> clearLaunch(String launch) async {
    final path = 'meta/handoffs/$launch';
    final outcome = await writer.applyGuarded((read) {
      final record = read(path);
      if (record is! Map<String, Object?>) return const GuardedRefusal('done');
      final id = record['job'];
      final node = id is String ? read('jobs/$id') : null;
      final mine = node is Map<String, Object?> && node['launch'] == launch;
      if (mine && !_terminal.contains(node['state'])) {
        return const GuardedRefusal('unsettled');
      }
      if (!mine && read('meta/orphans/$id/outputs/$launch') == null) {
        return const GuardedRefusal('unmapped');
      }
      return GuardedAppend(_record(path, Op.del));
    });
    return switch (outcome) {
      Applied() => ClearOutcome.cleared,
      Refused(reason: 'unsettled') => ClearOutcome.unsettled,
      Refused(reason: 'unmapped') => ClearOutcome.unmapped,
      Refused() => ClearOutcome.done,
    };
  }

  // -- the walk --------------------------------------------------------

  Future<_Counts> _walk({
    required String reason,
    Set<String> liveLaunches = const {},
    Set<String> liveCalls = const {},
  }) async {
    final counts = _Counts();
    _validateCommittedCalls(liveCalls);
    for (final launch in _keys('meta/handoffs')) {
      if (liveLaunches.contains(launch)) continue;
      await _launchRecord(launch, reason, counts);
    }
    final jobs = _map('jobs');
    for (final entry in jobs.entries) {
      final node = entry.value;
      if (node is! Map<String, Object?>) continue;
      if (_terminal.contains(node['state'])) continue;
      if (liveLaunches.contains(node['launch'])) continue;
      if (await _finalizeJobNode(entry.key, node, reason)) counts.jobs++;
    }
    final calls = _map('body/calls');
    for (final entry in calls.entries) {
      final node = entry.value;
      if (node is! Map<String, Object?>) continue;
      if (liveCalls.contains(entry.key)) continue;
      if (_terminal.contains(node['status'])) {
        if (_needsMutationFinish(node)) {
          // The lifecycle was already final; quiescence is bookkeeping only.
          await _finishMutationCall(entry.key, node);
        }
        continue;
      }
      if (await _finalizeCall(entry.key, node, reason)) {
        counts.calls++;
        await _finishMutationCall(entry.key, node);
      }
    }
    counts.calls += await _recoverMissingCalls(liveCalls);
    return counts;
  }

  bool _needsMutationFinish(Map<String, Object?> node) =>
      (node['tool'] == 'edit' || node['tool'] == 'write') &&
      node['target'] is String &&
      node['attempt'] is String &&
      node['quiesced'] != true;

  Future<void> _finishMutationCall(
    String key,
    Map<String, Object?> node,
  ) async {
    final tool = node['tool'];
    final attempt = node['attempt'];
    final target = node['target'];
    if ((tool != 'edit' && tool != 'write') ||
        attempt is! String ||
        target is! String) {
      return;
    }
    final session = _at('meta/session');
    if (session is! String) {
      throw StateError('Invalid session id during mutation recovery.');
    }
    await writer.finishMutation(
      (
        runId: attempt,
        callPath: 'body/calls/$key',
        target: target,
        temporary: mutationTemporary(node),
        session: session,
      ),
      sequence: _mutationSequenceForFinish(),
      retire: (_) {},
    );
  }

  Future<void> _finishOwnedMutationOrphans() async {
    final session = _at('meta/session');
    if (session is! String) {
      throw StateError('Invalid session id during mutation recovery.');
    }
    final raw = _at('meta/orphanedMutations');
    if (raw == null) return;
    if (raw is! Map<String, Object?>) {
      throw StateError('Invalid orphaned mutation map during recovery.');
    }
    final ids = raw.keys.toList()..sort();
    for (final id in ids) {
      final record = raw[id];
      if (record is! Map<String, Object?>) {
        throw StateError('Invalid orphaned mutation record during recovery.');
      }
      final temporary = mutationTemporary(record);
      if (record['foreign'] == true ||
          record['session'] != session ||
          record['finishedSeq'] is int) {
        continue;
      }
      final target = record['target'];
      if (target is! String) {
        throw StateError('Invalid orphaned mutation target during recovery.');
      }
      await writer.finishMutation(
        (
          runId: id,
          callPath: _mutationCallPath(id),
          target: target,
          temporary: temporary,
          session: session,
        ),
        sequence: _mutationSequenceForFinish(),
        retire: (_) {},
      );
    }
  }

  String _mutationCallPath(String attempt) {
    for (final entry in _map('body/calls').entries) {
      final node = entry.value;
      if (node is Map<String, Object?> &&
          (node['tool'] == 'edit' || node['tool'] == 'write') &&
          node['attempt'] == attempt) {
        return 'body/calls/${entry.key}';
      }
    }
    return 'meta/session';
  }

  MutationSequence _mutationSequenceForFinish() {
    final existing = mutationSequence;
    if (existing != null) return existing;
    final high = _map('meta/vcs')['seqHigh'];
    if (high != null && (high is! int || high < 0)) {
      throw StateError('Invalid mutation sequence counter during recovery.');
    }
    final seeded = MutationSequence(high is int ? high : 0);
    mutationSequence = seeded;
    return seeded;
  }

  Iterable<
    ({String step, Map<String, Object?> source, Map<String, Object?> call})
  >
  _committedCalls() sync* {
    for (final entry in _map('body/steps').entries) {
      final source = entry.value;
      if (source is! Map<String, Object?> || source['state'] != 'completed') {
        continue;
      }
      final output = source['output'];
      if (output is! List<Object?>) continue;
      for (final call in output) {
        if (call is Map<String, Object?> && call['type'] == 'call') {
          yield (step: entry.key, source: source, call: call);
        }
      }
    }
  }

  Object _input(Map<String, Object?> call) {
    final raw = call['arguments'];
    if (raw is! String) throw StateError('invalid committed call arguments');
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, Object?>) return decoded;
    } on FormatException {
      /* Retain invalid input without executing it. */
    }
    return raw;
  }

  void _checkCall(
    Map<String, Object?> call,
    Object? node,
    String step,
    Object? model,
  ) {
    if (call['call'] is! String ||
        call['callId'] is! String ||
        call['name'] is! String) {
      throw StateError('invalid committed call metadata');
    }
    if (node == null) return;
    if (node is! Map<String, Object?> ||
        node['callId'] != call['callId'] ||
        node['tool'] != call['name'] ||
        !_equalJson(node['input'], _input(call)) ||
        (node['sourceStep'] != null && node['sourceStep'] != step) ||
        (node['sourceModel'] != null && node['sourceModel'] != model) ||
        (node['arguments'] != null && node['arguments'] != call['arguments'])) {
      throw StateError('conflicting committed call metadata; recovery stopped');
    }
  }

  void _validateCommittedCalls(Set<String> liveCalls) {
    final seen = <String, String>{};
    for (final position in _committedCalls()) {
      final key = '${position.call['call']}';
      if (liveCalls.contains(key)) continue;
      if (seen.containsKey(key)) {
        throw StateError(
          'conflicting committed call positions; recovery stopped',
        );
      }
      seen[key] = position.step;
      _checkCall(
        position.call,
        _at('body/calls/$key'),
        position.step,
        position.source['model'],
      );
    }
  }

  Future<int> _recoverMissingCalls(Set<String> liveCalls) async {
    var count = 0;
    for (final position in _committedCalls().toList()) {
      final (:step, :source, :call) = position;
      final key = '${call['call']}';
      if (liveCalls.contains(key) || _at('body/calls/$key') != null) continue;
      const reason = 'interrupted_before_admission';
      const summary = 'cancelled: interrupted_before_admission';
      final write = await store.storeResult(
        Stream.value(utf8.encode('execution not recorded; not replayed')),
      );
      if (write is! ResultComplete) {
        throw StorageError('could not store missing-call cancellation', write);
      }
      final descriptor = write.descriptor;
      final envelope = await composeResult(
        '${call['name']}',
        ResultStatus.error,
        summary,
        descriptor,
        File(_resultPath(descriptor.sha256)),
      );
      final modelWrite = await store.storeResult(
        Stream.value(utf8.encode(envelope)),
      );
      if (modelWrite is! ResultComplete) {
        throw StorageError('could not store missing-call envelope', modelWrite);
      }
      for (var attempt = 0; attempt < _maxRetries; attempt++) {
        await writer.recordResult(descriptor);
        await writer.recordResult(modelWrite.descriptor);
        final outcome = await writer.applyGuarded((read) {
          // The source can disappear while immutable result bytes are stored.
          final current = read('body/steps/$step');
          if (!_equalJson(current, source)) {
            return const GuardedRefusal('source changed');
          }
          final existing = read('body/calls/$key');
          _checkCall(call, existing, step, source['model']);
          if (existing != null) return const GuardedRefusal('exists');
          return GuardedAppend(
            _record('body/calls/$key', Op.set, {
              'tool': call['name'],
              'version': 0,
              'callId': call['callId'],
              'attempt': 'recovery:$step:$key',
              'input': _input(call),
              'arguments': call['arguments'],
              'sourceStep': step,
              'sourceModel': source['model'],
              'status': 'cancelled',
              'envelope': 'error',
              'reason': reason,
              'summary': summary,
              'result': {'handle': descriptor.handle, 'complete': false},
              'model': {
                'handle': modelWrite.descriptor.handle,
                'complete': true,
              },
            }),
          );
        });
        if (outcome is Applied) {
          count++;
          break;
        }
        if (outcome is Refused && outcome.reason == 'descriptors missing') {
          if (attempt == _maxRetries - 1) {
            throw const StorageError(
              'could not register missing-call cancellation',
            );
          }
          continue;
        }
        break;
      }
    }
    return count;
  }

  Future<void> _launchRecord(
    String launch,
    String reason,
    _Counts counts,
  ) async {
    final record = _at('meta/handoffs/$launch');
    if (record is! Map<String, Object?>) return;
    final id = record['job'];
    if (id is! String) return;
    final node = _at('jobs/$id');
    final mine = node is Map<String, Object?> && node['launch'] == launch;
    if (!mine) {
      await _transfer(launch, id, record, counts);
      counts.orphans++;
      return;
    }
    if (_terminal.contains(node['state'])) {
      await clearLaunch(launch);
      return;
    }
    if (await _finish(launch, id, record, node, reason, counts)) counts.jobs++;
  }

  // -- the orphan transfer ---------------------------------------------

  /// Records the stream mapping of a job whose node is gone or superseded
  /// under `meta/orphans/<id>/outputs/<launch>`, then clears the launch
  /// record. A mapping already recorded stays as it is.
  Future<void> _transfer(
    String launch,
    String id,
    Map<String, Object?> record,
    _Counts counts,
  ) async {
    final path = 'meta/orphans/$id/outputs/$launch';
    if (_at(path) == null) {
      final mapping = await _mappingOf(record, counts);
      await _hook(hooks.beforeOrphan, id);
      await writer.applyGuarded(
        (read) => read(path) != null
            ? const GuardedRefusal('recorded')
            : GuardedAppend(_record(path, Op.set, mapping)),
      );
      await _hook(hooks.afterOrphan, id);
    }
    await clearLaunch(launch);
  }

  /// One entry per stream: spool name, hash when known, and disposition as
  /// found on disk.
  ///
  /// The streams are the intent's when it is committed, else the protocol
  /// streams of the launch record: an agent's `result` spool is never mapped
  /// before the intent, it is deleted and counted (design D11).
  Future<Map<String, Object?>> _mappingOf(
    Map<String, Object?> record,
    _Counts counts,
  ) async {
    final intent = record['streams'];
    final spools = record['spools'];
    final mapping = <String, Object?>{};
    if (intent is! Map<String, Object?> && _discardResult(record)) {
      counts.discarded++;
    }
    for (final stream in _streamsOf(record)) {
      final known = intent is Map<String, Object?> ? intent[stream] : null;
      final entry = known is Map<String, Object?> ? known : null;
      final name =
          (spools is Map<String, Object?> ? spools[stream] : null) ??
          entry?['spool'];
      if (name is! String) continue;
      var sha = entry?['sha256'];
      var bytes = entry?['bytes'];
      final spool = File(_resultPath(name));
      final spooled = spool.existsSync();
      if (spooled && (sha is! String || spool.lengthSync() != bytes)) {
        final adopted = await store.adopt(name);
        sha = adopted.sha256;
        bytes = adopted.bytes;
      }
      final String disposition;
      if (sha is String && _holds(File(_resultPath(sha)), bytes)) {
        disposition = 'published';
      } else {
        disposition = spooled ? 'spooled' : 'absent';
      }
      mapping[stream] = {
        'spool': name,
        'sha256': ?(sha is String ? sha : null),
        'bytes': ?(sha is String ? bytes : null),
        'disposition': disposition,
      };
    }
    return mapping;
  }

  // -- finishing a handoff ---------------------------------------------

  /// Finishes steps 2 to 5 of the handoff of a live job node with this
  /// launch. Returns whether the node was settled.
  Future<bool> _finish(
    String launch,
    String id,
    Map<String, Object?> record,
    Map<String, Object?> node,
    String reason,
    _Counts counts,
  ) async {
    var intent = record;
    if (record['streams'] is! Map<String, Object?>) {
      final adopted = await _adoptIntent(launch, id, record, reason, counts);
      if (adopted == null) return false;
      intent = adopted;
    }
    final foreign = intent['session'] != _at('meta/session');
    final streams = intent['streams']! as Map<String, Object?>;
    final outcome = foreign
        ? <String, Object?>{
            'state': 'cancelled',
            'ended': _now(),
            'reason': 'interrupted',
          }
        : <String, Object?>{...(intent['outcome'] as Map<String, Object?>)};

    // 2. Publish what is not yet published, 3. register.
    final present = <String, ResultDescriptor>{};
    final absent = <String>[];
    for (final stream in streams.keys) {
      final entry = streams[stream];
      final descriptor = entry is Map<String, Object?>
          ? await _publish(entry)
          : null;
      if (descriptor == null) {
        absent.add(stream);
      } else {
        present[stream] = descriptor;
        await _hookStream(id, stream);
      }
    }
    await _hook(hooks.afterPublish, id);
    for (final descriptor in present.values) {
      await writer.recordResult(descriptor);
    }
    await _hook(hooks.afterRegister, id);

    // 4. Settle, with every reference taking the intent's `complete`.
    final fields = <String, Object?>{
      ...outcome,
      for (final entry in present.entries)
        entry.key: {
          'handle': entry.value.handle,
          'complete':
              !foreign &&
              (streams[entry.key]! as Map<String, Object?>)['complete'] == true,
        },
      if (absent.isNotEmpty) 'absent': absent,
    };
    var settled = false;
    for (var attempt = 0; attempt < _maxRetries; attempt++) {
      final result = await writer.applyGuarded(
        (read) => _owns(read('jobs/$id'), launch)
            ? GuardedAppend(_record('jobs/$id', Op.merge, fields))
            : const GuardedRefusal('stale'),
      );
      if (result is Applied) {
        settled = true;
        break;
      }
      if (result case Refused(reason: 'descriptors missing', :final handles)) {
        for (final d in present.values.where(
          (d) => handles.contains(d.handle),
        )) {
          await writer.recordResult(d);
        }
        continue;
      }
      break;
    }
    if (!settled) return false;

    // 5. Clear.
    await clearLaunch(launch);
    return true;
  }

  /// Adopts the surviving spools of a launch record without an intent and
  /// merges the intent: outcome `cancelled` with [reason], every stream
  /// `complete: false`. Returns the record with its intent, or `null` when
  /// the job changed hands meanwhile.
  Future<Map<String, Object?>?> _adoptIntent(
    String launch,
    String id,
    Map<String, Object?> record,
    String reason,
    _Counts counts,
  ) async {
    final spools = record['spools'];
    final streams = <String, Object?>{};
    for (final stream in _streamsOf(record)) {
      final name = spools is Map<String, Object?> ? spools[stream] : null;
      if (name is! String) continue;
      if (File(_resultPath(name)).existsSync()) {
        final d = await store.adopt(name);
        streams[stream] = {
          'spool': name,
          'sha256': d.sha256,
          'bytes': d.bytes,
          'lines': d.lines,
          'complete': false,
        };
      } else {
        streams[stream] = {'spool': name, 'complete': false};
      }
    }
    // An agent's typed result is never adopted: it is recorded as an entry
    // without bytes, so the settled node lists it in `absent`, and its spool
    // is deleted and counted.
    final resultSpool = spools is Map<String, Object?>
        ? spools[resultStream]
        : null;
    if (resultSpool is String) {
      streams[resultStream] = {'spool': resultSpool, 'complete': false};
      if (_discardResult(record)) counts.discarded++;
    }
    final node = _at('jobs/$id');
    final agent = node is Map<String, Object?> && node['kind'] == 'agent'
        ? <String, Object?>{
            'role': node['cmd'],
            ...?(node['agent'] as Map<String, Object?>?),
            'status': 'cancelled',
          }
        : null;
    final outcome = {
      'state': 'cancelled',
      'ended': _now(),
      'reason': reason,
      'agent': ?agent,
    };
    final result = await writer.applyGuarded((read) {
      final current = read('meta/handoffs/$launch');
      if (current is! Map<String, Object?> || current['streams'] != null) {
        return const GuardedRefusal('intent exists');
      }
      if (!_owns(read('jobs/$id'), launch)) {
        return const GuardedRefusal('stale');
      }
      return GuardedAppend(
        _record('meta/handoffs/$launch', Op.merge, {
          'streams': streams,
          'outcome': outcome,
        }),
      );
    });
    if (result is! Applied) return null;
    await _hook(hooks.afterIntent, id);
    final merged = _at('meta/handoffs/$launch');
    return merged is Map<String, Object?> ? merged : null;
  }

  /// The streams of the launch [record]: those its intent names, else the
  /// protocol streams of its spools. An agent's `result` belongs to the
  /// second only once the intent names it.
  Iterable<String> _streamsOf(Map<String, Object?> record) {
    final intent = record['streams'];
    if (intent is Map<String, Object?>) return intent.keys;
    final spools = record['spools'];
    if (spools is! Map<String, Object?>) return jobStreams;
    return spools.keys.where((s) => s != resultStream);
  }

  /// Deletes the `result` spool of a launch [record] whose intent is not
  /// committed. Returns whether a file was deleted.
  bool _discardResult(Map<String, Object?> record) {
    final spools = record['spools'];
    final name = spools is Map<String, Object?> ? spools[resultStream] : null;
    if (name is! String) return false;
    checkSpoolName(name);
    final file = File(_resultPath(name));
    if (!file.existsSync()) return false;
    file.deleteSync();
    return true;
  }

  /// Publishes the stream of an intent [entry] and returns its descriptor,
  /// or `null` when the bytes are gone or are not the intent's.
  Future<ResultDescriptor?> _publish(Map<String, Object?> entry) async {
    final sha = entry['sha256'];
    final bytes = entry['bytes'];
    final lines = entry['lines'];
    final spool = entry['spool'];
    if (sha is! String || bytes is! int || lines is! int || spool is! String) {
      return null;
    }
    final ResultDescriptor descriptor;
    try {
      descriptor = ResultDescriptor(
        handle: 'r/${sha.substring(0, 12)}',
        sha256: sha,
        bytes: bytes,
        lines: lines,
      )..validate();
    } on Object {
      return null;
    }
    final file = File(_resultPath(spool));
    if (file.existsSync() && file.lengthSync() == bytes) {
      // Also when the final name exists: publish drops the duplicate spool.
      await store.publish(spool, descriptor);
      return descriptor;
    }
    return _holds(File(_resultPath(sha)), bytes) ? descriptor : null;
  }

  // -- nodes without a launch record -----------------------------------

  Future<bool> _finalizeJobNode(
    String id,
    Map<String, Object?> node,
    String reason,
  ) async {
    final launch = node['launch'];
    final failed = node['reason'] is String;
    final fields = <String, Object?>{
      'state': failed ? 'failed' : 'cancelled',
      'ended': _now(),
      if (!failed) 'reason': reason,
    };
    final result = await writer.applyGuarded(
      (read) => _owns(read('jobs/$id'), launch)
          ? GuardedAppend(_record('jobs/$id', Op.merge, fields))
          : const GuardedRefusal('stale'),
    );
    return result is Applied;
  }

  /// Gives a call nobody runs its stored interruption result and the
  /// terminal record.
  Future<bool> _finalizeCall(
    String key,
    Map<String, Object?> node,
    String reason,
  ) async {
    final path = 'body/calls/$key';
    final status = node['status'];
    final attempt = node['attempt'];
    final errored = node['reason'] is String;
    final lead = reason == 'interrupted'
        ? 'interrupted: the engine stopped while this call was $status; '
              'effects uncertain'
        : 'rewound: the session was rewound while this call was $status; '
              'effects uncertain';
    final text = StringBuffer(lead);
    for (final job in _map('jobs').values) {
      if (job is! Map<String, Object?> || job['call'] != key) continue;
      final output = job['output'];
      if (output is Map<String, Object?> && output['handle'] is String) {
        text.write('\noutput so far: ${output['handle']}');
      }
    }
    final write = await store.storeResult(
      Stream.value(utf8.encode(text.toString())),
    );
    if (write is! ResultComplete) {
      throw StorageError('could not store the interruption result', write);
    }
    final descriptor = write.descriptor;
    await writer.recordResult(descriptor);
    final fields = <String, Object?>{
      'status': errored ? 'failed' : 'cancelled',
      'envelope': 'error',
      'summary': errored ? 'failed: ${node['reason']}' : 'cancelled: $reason',
      'result': {'handle': descriptor.handle, 'complete': false},
      if (!errored) 'reason': reason,
    };
    for (var attempt0 = 0; attempt0 < _maxRetries; attempt0++) {
      final result = await writer.applyGuarded((read) {
        final current = read(path);
        if (current is! Map<String, Object?> ||
            current['attempt'] != attempt ||
            _terminal.contains(current['status'])) {
          return const GuardedRefusal('stale');
        }
        return GuardedAppend(_record(path, Op.merge, fields));
      });
      if (result is Applied) return true;
      if (result is Refused && result.reason == 'descriptors missing') {
        await writer.recordResult(descriptor);
        continue;
      }
      return false;
    }
    return false;
  }

  // -- leftovers and helpers -------------------------------------------

  /// Counts the content-addressed files under `results/` that no descriptor,
  /// launch record or orphan record names.
  int _leftovers() {
    final dir = Directory(p.join(store.sessionDir.path, resultsDirName));
    if (!dir.existsSync()) return 0;
    final named = <String>{};
    void collect(Object? value) {
      switch (value) {
        case final Map<Object?, Object?> map:
          final sha = map['sha256'];
          if (sha is String) named.add(sha);
          map.values.forEach(collect);
        case final List<Object?> list:
          list.forEach(collect);
      }
    }

    collect(_at('results'));
    collect(_at('meta/orphans'));
    collect(_at('meta/handoffs'));
    var count = 0;
    for (final file in dir.listSync()) {
      final name = p.basename(file.path);
      if (file is File && !name.startsWith('.') && !named.contains(name)) {
        count++;
      }
    }
    return count;
  }

  String _resultPath(String name) =>
      p.join(store.sessionDir.path, resultsDirName, name);

  bool _owns(Object? node, Object? launch) =>
      node is Map<String, Object?> &&
      node['launch'] == launch &&
      !_terminal.contains(node['state']);

  Object? _at(String path) => writer.tree.get(SessionPath.parse(path));

  Map<String, Object?> _map(String path) {
    final value = _at(path);
    return value is Map<String, Object?> ? value : const {};
  }

  List<String> _keys(String path) => _map(path).keys.toList();

  JournalRecord _record(String path, Op op, [Object? value]) =>
      JournalRecord(turn: writer.currentTurn, path: path, op: op, value: value);

  Future<void> _hook(Future<void> Function(String id)? hook, String id) =>
      hook == null ? Future<void>.value() : hook(id);

  Future<void> _hookStream(String id, String stream) {
    final hook = hooks.afterStreamPublish;
    return hook == null ? Future<void>.value() : hook(id, stream);
  }
}

bool _holds(File file, Object? bytes) {
  try {
    return file.existsSync() && file.lengthSync() == bytes;
  } on FileSystemException {
    return false;
  }
}

String _now() => DateTime.now().toUtc().toIso8601String();

Object? _orderedJson(Object? value) => switch (value) {
  Map<String, Object?> map => {
    for (final key in map.keys.toList()..sort()) key: _orderedJson(map[key]),
  },
  List<Object?> list => [for (final v in list) _orderedJson(v)],
  _ => value,
};
bool _equalJson(Object? a, Object? b) =>
    jsonEncode(_orderedJson(a)) == jsonEncode(_orderedJson(b));
