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
import '../results/result_store.dart';
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

  /// The number of nodes finalized, calls and jobs together.
  int get finalized => jobs + calls;

  /// The warning for the user, empty when nothing was finalized.
  String get warning => finalized == 0 && orphans == 0
      ? ''
      : 'processes of the previous engine may still run: no process id is '
            'stored to check';

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

  /// Attach finalization: launch records first, then job nodes, then calls.
  ///
  /// Every step is decided from the tree and the disk alone, so a crash in
  /// the middle leaves a state the next attach handles the same way. A
  /// storage failure ends the walk and is rethrown.
  Future<ResumeReport> resume() async {
    final counts = await _walk(reason: 'interrupted');
    return ResumeReport(
      jobs: counts.jobs,
      calls: counts.calls,
      orphans: counts.orphans,
      leftovers: _leftovers(),
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
      if (_terminal.contains(node['status'])) continue;
      if (liveCalls.contains(entry.key)) continue;
      if (await _finalizeCall(entry.key, node, reason)) counts.calls++;
    }
    return counts;
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
      await _transfer(launch, id, record);
      counts.orphans++;
      return;
    }
    if (_terminal.contains(node['state'])) {
      await clearLaunch(launch);
      return;
    }
    if (await _finish(launch, id, record, node, reason)) counts.jobs++;
  }

  // -- the orphan transfer ---------------------------------------------

  /// Records the stream mapping of a job whose node is gone or superseded
  /// under `meta/orphans/<id>/outputs/<launch>`, then clears the launch
  /// record. A mapping already recorded stays as it is.
  Future<void> _transfer(
    String launch,
    String id,
    Map<String, Object?> record,
  ) async {
    final path = 'meta/orphans/$id/outputs/$launch';
    if (_at(path) == null) {
      final mapping = await _mappingOf(record);
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
  Future<Map<String, Object?>> _mappingOf(Map<String, Object?> record) async {
    final intent = record['streams'];
    final spools = record['spools'];
    final mapping = <String, Object?>{};
    for (final stream in jobStreams) {
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
  ) async {
    var intent = record;
    if (record['streams'] is! Map<String, Object?>) {
      final adopted = await _adoptIntent(launch, id, record, reason);
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
    for (final stream in jobStreams) {
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
  ) async {
    final spools = record['spools'];
    final streams = <String, Object?>{};
    for (final stream in jobStreams) {
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
    final outcome = {'state': 'cancelled', 'ended': _now(), 'reason': reason};
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
