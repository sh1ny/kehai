/// The job supervisor (design D8, D9, D10): every process the engine starts.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../auth/posix_ffi.dart';
import '../results/descriptor.dart';
import '../results/live_result.dart';
import '../results/result_store.dart';
import '../session/path.dart';
import '../session/record.dart';
import '../session/writer.dart';
import '../shell/detect.dart';
import '../shell/launch.dart';
import 'recovery.dart';

/// The most jobs that may be live (`pending` or `running`) at once.
const int maxLiveJobs = 16;

/// The text a call settles with when a 17th job would start.
const String tooManyJobsMessage =
    'too many live jobs ($maxLiveJobs); cancel one with job';

/// The default job deadline.
const Duration defaultJobDeadline = Duration(seconds: 3600);

/// The longest job deadline.
const Duration maxJobDeadline = Duration(seconds: 86400);

/// The three result streams of a job, in the order they are published.
const List<String> jobStreams = ['stdout', 'stderr', 'output'];

/// The kind of process a job runs.
enum JobKind {
  /// A `bash` tool command.
  shell('shell'),

  /// A hook.
  hook('hook');

  const JobKind(this.wire);

  /// The name stored in the job node.
  final String wire;
}

/// Starts the process of a job, or throws a `ProcessException`.
typedef JobLauncher = Future<ShellProcess> Function();

/// What to run as one job.
final class JobRequest {
  /// Creates a request that starts its process with [launch].
  const JobRequest({
    required this.kind,
    required this.cmd,
    required this.cwd,
    required this.launch,
    this.shell,
    this.call,
    this.deadline = defaultJobDeadline,
  });

  /// A request that runs [command] through [shell].
  ///
  /// [environment] is the complete child environment (`shellEnvironment`).
  factory JobRequest.shell(
    ShellInfo shell,
    String command, {
    required String cwd,
    required Map<String, String> environment,
    JobKind kind = JobKind.shell,
    String? call,
    Duration deadline = defaultJobDeadline,
  }) => JobRequest(
    kind: kind,
    cmd: command,
    cwd: cwd,
    shell: shell.name,
    call: call,
    deadline: deadline,
    launch: () => startShell(
      shell,
      command,
      workingDirectory: cwd,
      environment: environment,
    ),
  );

  /// Whether this is a shell command or a hook.
  final JobKind kind;

  /// The command text recorded in the node.
  final String cmd;

  /// The working directory recorded in the node.
  final String cwd;

  /// The shell's name, or `null` for a job started without a shell.
  final String? shell;

  /// The key of the owning call, if any.
  final String? call;

  /// How long the job may run, from its launch.
  final Duration deadline;

  /// Starts the process.
  final JobLauncher launch;
}

/// One stream of a finished job.
final class JobStream {
  /// Creates the stream facts.
  const JobStream(this.descriptor, {required this.complete});

  /// The stored bytes.
  final ResultDescriptor descriptor;

  /// Whether the stream reached its end and the job ended by itself.
  final bool complete;
}

/// How a job ended, after its output was handed off.
final class JobResult {
  /// Creates a result.
  const JobResult({
    required this.id,
    required this.launch,
    required this.state,
    this.exit,
    this.reason,
    this.cleanup,
    this.signal,
    this.streams = const {},
    this.stale = false,
  });

  /// The job id.
  final String id;

  /// The launch token.
  final String launch;

  /// `settled`, `failed` or `cancelled`.
  final String state;

  /// The exit code, when the process left one.
  final int? exit;

  /// `user`, `deadline`, `rewound`, `shutdown`, or the launch failure.
  final String? reason;

  /// `confirmed`, or `uncertain: <reason>`; absent when nothing was killed.
  final String? cleanup;

  /// `term`, or `kill` when the process had to be force-killed.
  final String? signal;

  /// The published streams by name; empty for a failed launch or when [stale].
  final Map<String, JobStream> streams;

  /// Whether the node was gone or superseded, so nothing was recorded for it
  /// and the output was listed under `meta/orphans`.
  final bool stale;
}

/// A started job.
final class JobHandle {
  /// Creates a handle.
  const JobHandle(this.id, this.launch, this.exited, this.result);

  /// The job id.
  final String id;

  /// The launch token.
  final String launch;

  /// Completes with the exit code once the direct process ended, or `null`
  /// when it never started or did not end.
  final Future<int?> exited;

  /// Completes when the job is settled and its handoff is cleared.
  final Future<JobResult> result;
}

/// The 17th live job was refused; nothing started.
final class TooManyLiveJobs implements Exception {
  /// Creates the error.
  const TooManyLiveJobs();

  /// The text the call settles `failed` with.
  String get message => tooManyJobsMessage;

  @override
  String toString() => message;
}

/// What [JobSupervisor.cancelJob] found.
sealed class CancelOutcome {
  const CancelOutcome();
}

/// The job was cancelled, or ended first; [result] says how it ended.
final class JobCancelled extends CancelOutcome {
  /// Creates the outcome.
  const JobCancelled(this.result);

  /// How the job ended.
  final JobResult result;
}

/// The process had already exited and is being handed off.
final class JobAlreadyExited extends CancelOutcome {
  /// Creates the outcome for [id].
  const JobAlreadyExited(this.id);

  /// The job id.
  final String id;

  /// The text the cancel answers with.
  String get message => 'job $id already exited';
}

/// The supervisor holds no runtime entry for the id.
final class JobNotLive extends CancelOutcome {
  /// Creates the outcome for [id].
  const JobNotLive(this.id);

  /// The job id.
  final String id;
}

/// Pause points that make launch and handoff races deterministic.
final class JobHooks {
  /// Creates hooks; every callback is optional and gets the job id.
  const JobHooks({
    this.afterReservation,
    this.afterPending,
    this.afterStart,
    this.beforeRunning,
    this.beforeIntent,
    this.afterIntent,
    this.afterStreamPublish,
    this.afterSpoolWrite,
    this.afterPublish,
    this.afterRegister,
    this.beforeClear,
    this.beforeOrphan,
    this.afterOrphan,
  });

  /// After the reservation, before the launch record.
  final Future<void> Function(String id)? afterReservation;

  /// After the `pending` node committed, before the spools exist.
  final Future<void> Function(String id)? afterPending;

  /// After the process started.
  final Future<void> Function(String id)? afterStart;

  /// Before the `running` record.
  final Future<void> Function(String id)? beforeRunning;

  /// After the streams were sealed, before the intent is recorded.
  final Future<void> Function(String id)? beforeIntent;

  /// After the handoff intent committed.
  final Future<void> Function(String id)? afterIntent;

  /// After a chunk was written to a spool (`stdout`, `stderr` or `output`),
  /// inside that spool's write order; gets the job id, the stream and the
  /// chunk.
  final Future<void> Function(String id, String stream, List<int> chunk)?
  afterSpoolWrite;

  /// After one stream's spool was renamed; gets the job id and the stream.
  final Future<void> Function(String id, String stream)? afterStreamPublish;

  /// After the spools were renamed.
  final Future<void> Function(String id)? afterPublish;

  /// After the descriptors were registered.
  final Future<void> Function(String id)? afterRegister;

  /// After the job settled, before the intent is removed.
  final Future<void> Function(String id)? beforeClear;

  /// Recovery only: before a launch record's output mapping moves to
  /// `meta/orphans`.
  final Future<void> Function(String id)? beforeOrphan;

  /// Recovery only: after the output mapping committed, before the launch
  /// record is cleared.
  final Future<void> Function(String id)? afterOrphan;
}

/// The durations of the termination and drain sequences.
final class JobTimings {
  /// Creates timings; the defaults are the ones the design fixes.
  const JobTimings({
    this.grace = const Duration(seconds: 2),
    this.drain = const Duration(seconds: 2),
    this.probe = const Duration(seconds: 1),
    this.poll = const Duration(milliseconds: 25),
    this.closeSettle = const Duration(milliseconds: 250),
  });

  /// SIGTERM to SIGKILL.
  final Duration grace;

  /// How long a pipe may stay open after the process exit.
  final Duration drain;

  /// How long the probe waits for the group to vanish after SIGKILL.
  final Duration probe;

  /// How often the group is probed.
  final Duration poll;

  /// How long pipes get to end after the termination finished.
  final Duration closeSettle;
}

/// Sends [signal] to process group [pgid]; returns 0 or an `errno`.
typedef GroupSignal = int Function(int pgid, int signal);

const int _sigterm = 15;
const int _sigkill = 9;
const int _esrch = 3;
const int _maxHandoffRetries = 16;
const Set<String> _terminalStates = {'settled', 'failed', 'cancelled'};

int _libcSignal(int pgid, int signal) => PosixLibc.instance.kill(-pgid, signal);

enum _Phase { launching, running, handoff }

/// Runs file operations of one spool one at a time.
final class _Gate {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() operation) {
    final done = Completer<T>();
    final previous = _tail;
    _tail = done.future.then<void>((_) {}, onError: (Object _) {});
    previous.then<void>((_) async {
      try {
        done.complete(await operation());
      } on Object catch (e, s) {
        done.completeError(e, s);
      }
    });
    return done.future;
  }
}

/// One output pipe of a running job.
final class _Pipe {
  StreamSubscription<List<int>>? sub;
  final Completer<void> done = Completer<void>();
  Future<void> writing = Future<void>.value();
  bool forced = false;

  void finish() {
    writing.then<void>((_) {
      if (!done.isCompleted) done.complete();
    });
  }
}

/// The runtime entry of one job: its reservation, process and timers.
final class _Job {
  _Job(this.id, this.launch, this.request)
    : spools = {for (final s in jobStreams) s: '.spool-$launch-$s'} {
    done.future.ignore();
  }

  final String id;
  final String launch;
  final JobRequest request;
  final Map<String, String> spools;

  final Completer<JobResult> done = Completer<JobResult>();
  final Completer<int?> exited = Completer<int?>();
  final Completer<void> terminationStarted = Completer<void>();
  final Map<String, LiveResult> live = {};
  final Map<String, _Gate> gates = {for (final s in jobStreams) s: _Gate()};
  final Map<String, _Pipe> pipes = {};

  _Phase phase = _Phase.launching;
  bool slotHeld = true;
  bool nodeCommitted = false;
  bool cancelRequested = false;
  String? cancelReason;
  bool forcedKill = false;
  ShellProcess? proc;
  int? exitCode;
  Future<String>? termination;
  Timer? deadlineTimer;

  String get path => 'jobs/$id';
  String get launchPath => 'meta/handoffs/$launch';
}

/// Owns every job process of one runtime (design D8, D9, D10).
///
/// [start] reserves an admission slot synchronously and then drives the job
/// through launch, run and handoff on its own. Every tree update is a guarded
/// append; an update that comes back stale terminates the process tree and
/// lists the job under `meta/orphans`. The tree never holds a pid.
final class JobSupervisor {
  /// Creates a supervisor writing through [writer] and [store].
  ///
  /// [groupSignal] and [windows] replace the libc `kill` and the platform
  /// check, so tests can exercise a termination path on any host.
  ///
  /// With [reconcile] (the default) the supervisor subscribes to the writer
  /// and runs one reconciliation pass after every committed rewind and after
  /// every `ResyncRequired` (design D11).
  JobSupervisor(
    this.writer,
    this.store, {
    this.hooks = const JobHooks(),
    this.timings = const JobTimings(),
    GroupSignal? groupSignal,
    bool? windows,
    bool reconcile = true,
  }) : _signal = groupSignal ?? _libcSignal,
       _windows = windows ?? Platform.isWindows,
       recovery = JobRecovery(writer, store, hooks: hooks) {
    if (reconcile) _subscribe();
  }

  /// Settles or orphans what no owner is left for; used at attach and by the
  /// reconciler.
  final JobRecovery recovery;

  /// The keys of the calls the runtime owns; their nodes are left to it.
  Set<String> Function() liveCallKeys = () => const {};

  /// Runs at the end of every reconciliation pass; the runtime cancels its
  /// calls whose nodes a rewind removed.
  void Function() afterReconcile = () {};

  /// The session writer.
  final SessionWriter writer;

  /// The result store.
  final ResultStore store;

  /// The test seams.
  final JobHooks hooks;

  /// The termination and drain durations.
  final JobTimings timings;

  final GroupSignal _signal;
  final bool _windows;
  final Map<String, _Job> _jobs = {};
  bool _closed = false;
  StreamSubscription<CommittedUpdate>? _watch;
  bool _resync = false;
  bool _again = false;
  Future<void>? _passes;

  /// The jobs holding an admission slot: `pending`, `running` or draining.
  int get liveCount => _jobs.values.where((j) => j.slotHeld).length;

  /// Reserves a slot and starts [request] as a new job.
  ///
  /// The bound is checked and the reservation inserted before anything is
  /// awaited. Throws [TooManyLiveJobs] when [maxLiveJobs] jobs are live; then
  /// nothing starts and nothing is recorded. The returned handle completes
  /// [JobHandle.result] with the job's end; a storage failure completes it
  /// with that error.
  JobHandle start(JobRequest request) {
    if (_closed) throw StateError('the job supervisor is closed');
    final deadline = request.deadline;
    if (deadline <= Duration.zero || deadline > maxJobDeadline) {
      throw ArgumentError.value(deadline, 'deadline', 'must be 1 s to 24 h');
    }
    if (liveCount >= maxLiveJobs) throw const TooManyLiveJobs();
    var id = 'j-${_hex(4)}';
    while (_jobs.containsKey(id)) {
      id = 'j-${_hex(4)}';
    }
    final job = _Job(id, _hex(8), request);
    _jobs[id] = job;
    unawaited(_run(job));
    return JobHandle(id, job.launch, job.exited.future, job.done.future);
  }

  /// Cancels job [id] as `reason` (`user` unless told otherwise).
  ///
  /// Records the `signal` intent, terminates the process tree and completes
  /// with the job's end. A job whose process already exited is
  /// [JobAlreadyExited]; an id without a runtime entry is [JobNotLive].
  Future<CancelOutcome> cancelJob(String id, {String reason = 'user'}) async {
    final job = _jobs[id];
    if (job == null) return JobNotLive(id);
    if (job.phase == _Phase.handoff) return JobAlreadyExited(id);
    await _cancel(job, reason);
    return JobCancelled(await job.done.future);
  }

  /// Terminates the live shell job started for call [call] and returns the
  /// output it stored, or `null` when the call has no live job or the job left
  /// no output (a cancelled call answers with what its job printed).
  Future<ResultDescriptor?> cancelCallJob(
    String call, {
    String reason = 'user',
  }) async {
    final job = _jobs.values
        .where((j) => j.request.call == call && j.request.kind == JobKind.shell)
        .firstOrNull;
    if (job == null) return null;
    try {
      final outcome = await cancelJob(job.id, reason: reason);
      final result = switch (outcome) {
        JobCancelled(:final result) => result,
        JobAlreadyExited() => await job.done.future,
        JobNotLive() => null,
      };
      return result?.streams['output']?.descriptor;
    } on Object {
      return null;
    }
  }

  /// Stores the output so far of stream [stream] of live job [id] as its own
  /// result and returns the outcome, or `null` when the job is not live.
  Future<ResultWrite?> snapshot(String id, String stream) async {
    final job = _jobs[id];
    final live = job?.live[stream];
    if (job == null || live == null) return null;
    return job.gates[stream]!.run(live.snapshot);
  }

  /// Completes with the end of live job [id], or is `null` when the job is
  /// not live. A storage failure completes it with that error.
  Future<JobResult>? whenDone(String id) => _jobs[id]?.done.future;

  /// Cancels every live job as `shutdown` and waits for their handoffs.
  Future<void> close() async {
    _closed = true;
    await _watch?.cancel();
    _watch = null;
    final jobs = _jobs.values.toList();
    for (final job in jobs) {
      unawaited(_cancel(job, 'shutdown'));
    }
    await Future.wait([
      for (final job in jobs)
        job.done.future.then<void>((_) {}, onError: (Object _) {}),
    ]);
    await _passes;
  }

  // -- the reconciler (design D11) -------------------------------------

  /// Completes once no reconciliation pass is requested or running.
  ///
  /// A pass is requested when the writer delivers a committed rewind, so this
  /// first lets pending deliveries arrive.
  Future<void> reconciled() async {
    await Future<void>.delayed(Duration.zero);
    for (var running = _passes; running != null; running = _passes) {
      await running;
    }
  }

  void _subscribe() {
    _watch = writer.subscribe().listen(
      (update) {
        if (update.record.op == Op.rewind) _requestPass();
      },
      onError: (Object error) {
        if (error is ResyncRequired) _resync = true;
      },
      onDone: () {
        _watch = null;
        if (_closed || writer.state != WriterState.ready) return;
        _subscribe();
        if (_resync) {
          _resync = false;
          _requestPass();
        }
      },
    );
  }

  /// Asks for a pass; passes are serialized, so a request during a pass
  /// reruns it afterwards.
  void _requestPass() {
    if (_closed) return;
    _again = true;
    _passes ??= _runPasses();
  }

  Future<void> _runPasses() async {
    try {
      while (_again && !_closed) {
        _again = false;
        try {
          await _reconcile();
        } on Object {
          // A broken journal fails every other operation too; the pass has
          // nowhere to report it.
        }
      }
    } finally {
      _passes = null;
    }
  }

  /// One level-triggered pass over the tree and the runtime map.
  Future<void> _reconcile() async {
    final tree = writer.tree;
    final kills = <Future<void>>[];
    for (final job in _jobs.values.toList()) {
      if (!job.nodeCommitted || job.phase == _Phase.handoff) continue;
      final node = tree.get(SessionPath.parse(job.path));
      if (node is Map<String, Object?> && node['launch'] == job.launch) {
        continue;
      }
      // The node is gone or superseded: end the process as cancellation does.
      // A reservation whose process has not started yet is left alone: its
      // `running` record comes back stale, which terminates the process the
      // moment it exists and lists it under `meta/orphans` (design D8).
      if (job.proc == null) continue;
      job.cancelRequested = true;
      job.cancelReason ??= 'rewound';
      kills.add(_killRewound(job));
    }
    await Future.wait(kills);
    await recovery.reconcile(
      liveLaunches: {for (final job in _jobs.values) job.launch},
      liveCalls: liveCallKeys(),
    );
    afterReconcile();
  }

  Future<void> _killRewound(_Job job) async {
    final cleanup = await _startTermination(job);
    await _append(
      (read) => GuardedAppend(
        _record('meta/orphans/${job.id}', Op.merge, {
          'cmd': job.request.cmd,
          'rewoundTo': writer.currentTurn,
          'cleanup': cleanup,
        }),
      ),
    );
  }

  Future<void> _run(_Job job) async {
    try {
      job.done.complete(await _drive(job));
    } on Object catch (e, s) {
      _killQuietly(job);
      job.done.completeError(e, s);
    } finally {
      job.slotHeld = false;
      job.deadlineTimer?.cancel();
      _jobs.remove(job.id);
      if (!job.exited.isCompleted) job.exited.complete(job.exitCode);
    }
  }

  Future<JobResult> _drive(_Job job) async {
    await _hook(hooks.afterReservation, job);

    // Admission: the launch record, then the node, then the spools.
    final launched = await _append(
      (read) => read(job.launchPath) != null
          ? const GuardedRefusal('exists')
          : GuardedAppend(
              _record(job.launchPath, Op.set, {
                'job': job.id,
                'session': read('meta/session'),
                'spools': job.spools,
              }),
            ),
    );
    if (launched is! Applied) throw StateError('launch ${job.launch} exists');
    final request = job.request;
    final pending = await _append((read) {
      if (read(job.path) != null) return const GuardedRefusal('exists');
      return GuardedAppend(
        _record(job.path, Op.set, {
          'kind': request.kind.wire,
          'cmd': request.cmd,
          'cwd': request.cwd,
          'shell': request.shell,
          'call': ?request.call,
          'launch': job.launch,
          'state': 'pending',
          'spool': job.spools,
        }),
      );
    });
    if (pending is! Applied) throw StateError('job ${job.id} exists');
    // Owned from here on: a node that is gone after this is a rewind's doing.
    job.nodeCommitted = true;
    await _hook(hooks.afterPending, job);
    for (final stream in jobStreams) {
      job.live[stream] = await store.begin(job.spools[stream]!);
    }

    // Launch: a cancellation so far means no process is started at all.
    ShellProcess? started;
    if (!job.cancelRequested) {
      try {
        started = await request.launch();
      } on ProcessException catch (e) {
        return _failLaunch(job, '${e.message} (os error ${e.errorCode})');
      }
      job.proc = started;
      job.deadlineTimer = Timer(
        request.deadline,
        () => unawaited(_cancel(job, 'deadline')),
      );
      _attachPipes(job);
      if (job.cancelRequested) _startTermination(job);
    }
    await _hook(hooks.afterStart, job);
    if (started != null && !job.cancelRequested) {
      await _hook(hooks.beforeRunning, job);
    }
    if (started != null && !job.cancelRequested) {
      final running = await _guardedMerge(job, {
        'state': 'running',
        'started': _now(),
      });
      if (running is Refused) {
        // Stale is never ignored: the node is gone, so end the process.
        job.cancelRequested = true;
        job.cancelReason ??= 'rewound';
        _startTermination(job);
      }
    }
    job.phase = _Phase.running;

    int? code;
    if (started != null) {
      code = await _awaitExit(job);
      job.exitCode = code;
      if (code != null) job.deadlineTimer?.cancel();
      if (!job.exited.isCompleted) job.exited.complete(code);
      await _drain(job);
    }
    return _handoff(job, code);
  }

  // -- cancellation and termination ------------------------------------

  Future<void> _cancel(_Job job, String reason) async {
    if (job.phase == _Phase.handoff) return;
    job.cancelRequested = true;
    job.cancelReason ??= reason;
    if (job.nodeCommitted) {
      try {
        await _guardedMerge(job, {'signal': 'term'});
      } on Object {
        // The journal is unusable; the process is terminated all the same.
      }
    }
    if (job.proc != null) _startTermination(job);
  }

  Future<String> _startTermination(_Job job) {
    final existing = job.termination;
    if (existing != null) return existing;
    final termination = job.termination = _terminate(job);
    job.terminationStarted.complete();
    return termination;
  }

  /// Terminates the process tree of [job] and returns its `cleanup` text.
  Future<String> _terminate(_Job job) async {
    final started = job.proc!;
    final process = started.process;
    if (_windows) {
      try {
        await Process.run('taskkill', ['/PID', '${process.pid}', '/T', '/F']);
      } on ProcessException {
        process.kill();
      }
      return 'uncertain: descendants not verifiable';
    }
    if (!started.groupKnown) {
      process.kill();
      if (!await _within(process.exitCode, timings.grace)) {
        job.forcedKill = true;
        process.kill(ProcessSignal.sigkill);
      }
      return 'uncertain: process group not known';
    }
    final pgid = process.pid;
    if (_signal(pgid, _sigterm) == _esrch) return 'confirmed';
    if (await _groupGone(pgid, timings.grace)) return 'confirmed';
    job.forcedKill = true;
    _signal(pgid, _sigkill);
    return await _groupGone(pgid, timings.probe)
        ? 'confirmed'
        : 'uncertain: group still present';
  }

  Future<bool> _groupGone(int pgid, Duration limit) async {
    final clock = Stopwatch()..start();
    while (true) {
      if (_signal(pgid, 0) == _esrch) return true;
      if (clock.elapsed >= limit) return false;
      await Future<void>.delayed(timings.poll);
    }
  }

  void _killQuietly(_Job job) {
    final started = job.proc;
    if (started == null || job.exitCode != null) return;
    try {
      if (!_windows && started.groupKnown) {
        _signal(started.process.pid, _sigkill);
      } else {
        started.process.kill(ProcessSignal.sigkill);
      }
    } on Object {
      // Nothing more can be done for a process that cannot be signalled.
    }
  }

  // -- output pipes and the bounded drain ------------------------------

  void _attachPipes(_Job job) {
    final process = job.proc!.process;
    job.pipes['stdout'] = _listen(job, 'stdout', process.stdout);
    job.pipes['stderr'] = _listen(job, 'stderr', process.stderr);
  }

  _Pipe _listen(_Job job, String name, Stream<List<int>> stream) {
    final pipe = _Pipe();
    pipe.sub = stream.listen(
      (chunk) {
        // One read at a time: the pipe stays paused until the chunk is
        // written to both of its spools.
        pipe.sub!.pause();
        pipe.writing = _writeChunk(job, pipe, name, chunk).then<void>((_) {
          if (!pipe.done.isCompleted && !pipe.forced) pipe.sub!.resume();
        });
      },
      onDone: pipe.finish,
      onError: (Object _) => pipe.finish(),
    );
    return pipe;
  }

  Future<void> _spoolWrite(_Job job, String stream, List<int> chunk) async {
    await job.live[stream]!.write(chunk);
    await hooks.afterSpoolWrite?.call(job.id, stream, chunk);
  }

  Future<void> _writeChunk(
    _Job job,
    _Pipe pipe,
    String name,
    List<int> chunk,
  ) async {
    try {
      // Both writes are queued now, before anything is awaited: the combined
      // output takes its place in arrival order whatever the per-stream write
      // costs. The pipe stays paused until both are done.
      final own = job.gates[name]!.run(() => _spoolWrite(job, name, chunk));
      final combined = job.gates['output']!.run(
        () => _spoolWrite(job, 'output', chunk),
      );
      await Future.wait([own, combined]);
    } on Object catch (e) {
      // The disk refused the bytes: stop the producer and end the job.
      if (!pipe.done.isCompleted) pipe.done.complete();
      unawaited(pipe.sub?.cancel());
      unawaited(_cancel(job, 'storage: $e'));
    }
  }

  Future<int?> _awaitExit(_Job job) async {
    final exit = job.proc!.process.exitCode;
    final first = await Future.any<int?>([
      exit,
      job.terminationStarted.future.then<int?>((_) => null),
    ]);
    if (first != null) return first;
    final second = await Future.any<int?>([
      exit,
      job.termination!.then<int?>((_) => null),
    ]);
    if (second != null) return second;
    // The termination ended and the process did not: allow the probe time.
    return Future.any<int?>([
      exit,
      Future<int?>.delayed(timings.probe, () => null),
    ]);
  }

  bool _pipesOpen(_Job job) =>
      job.pipes.values.any((pipe) => !pipe.done.isCompleted);

  Future<void> _pipesEnded(_Job job) =>
      Future.wait([for (final pipe in job.pipes.values) pipe.done.future]);

  /// Waits for the output pipes after the process exit, never without bound:
  /// 2 s, then the group termination with 2 s more, then the readers are
  /// closed by force.
  Future<void> _drain(_Job job) async {
    if (await _within(_pipesEnded(job), timings.drain)) return;
    final termination = _startTermination(job);
    await Future.any<Object?>([_pipesEnded(job), termination]);
    if (!_pipesOpen(job)) return;
    if (await _within(_pipesEnded(job), timings.closeSettle)) return;
    for (final pipe in job.pipes.values) {
      if (pipe.done.isCompleted) continue;
      pipe.forced = true;
      try {
        await pipe.sub?.cancel().timeout(const Duration(seconds: 1));
      } on Object {
        // A reader that cannot be cancelled is abandoned all the same.
      }
      await pipe.writing;
      if (!pipe.done.isCompleted) pipe.done.complete();
    }
  }

  // -- handoff ---------------------------------------------------------

  Future<JobResult> _handoff(_Job job, int? code) async {
    job.phase = _Phase.handoff;
    job.deadlineTimer?.cancel();
    final cleanup = await _cleanupText(job, code);
    final cancelled = job.cancelRequested;

    final sealed = <String, ResultDescriptor>{};
    for (final stream in jobStreams) {
      await job.pipes[stream]?.writing;
      sealed[stream] = await job.gates[stream]!.run(job.live[stream]!.seal);
    }
    bool forced(String stream) => stream == 'output'
        ? job.pipes.values.any((p) => p.forced)
        : job.pipes[stream]?.forced ?? false;
    final complete = {for (final s in jobStreams) s: !cancelled && !forced(s)};
    final signal = job.forcedKill
        ? 'kill'
        : (cancelled || job.termination != null ? 'term' : null);
    final outcome = <String, Object?>{
      'state': cancelled ? 'cancelled' : 'settled',
      'ended': _now(),
      'exit': ?code,
      'reason': ?(cancelled ? job.cancelReason : null),
      'cleanup': ?cleanup,
      'signal': ?signal,
    };

    JobResult result({bool stale = false}) => JobResult(
      id: job.id,
      launch: job.launch,
      state: outcome['state']! as String,
      exit: code,
      reason: outcome['reason'] as String?,
      cleanup: cleanup,
      signal: signal,
      streams: stale
          ? const {}
          : {
              for (final s in jobStreams)
                s: JobStream(sealed[s]!, complete: complete[s]!),
            },
      stale: stale,
    );
    Map<String, Object?> mappingOf(String disposition) => {
      for (final s in jobStreams)
        s: {
          'spool': job.spools[s],
          'sha256': sealed[s]!.sha256,
          'bytes': sealed[s]!.bytes,
          'disposition': disposition,
        },
    };
    Future<JobResult> orphaned(String disposition) async {
      final mapping = mappingOf(disposition);
      await _recordOrphan(job, mapping, cleanup);
      job.slotHeld = false;
      await _clear(job, mapping: mapping, resettle: () async => false);
      return result(stale: true);
    }

    // 1. Intent.
    await _hook(hooks.beforeIntent, job);
    final streamsJson = {
      for (final s in jobStreams)
        s: {
          'spool': job.spools[s],
          'sha256': sealed[s]!.sha256,
          'bytes': sealed[s]!.bytes,
          'lines': sealed[s]!.lines,
          'complete': complete[s],
        },
    };
    final intent = await _append((read) {
      final record = read(job.launchPath);
      if (record is! Map<String, Object?> || record.containsKey('streams')) {
        return const GuardedRefusal('no launch record');
      }
      if (!_owns(read(job.path), job)) return const GuardedRefusal('stale');
      return GuardedAppend(
        _record(job.launchPath, Op.merge, {
          'session': read('meta/session'),
          'streams': streamsJson,
          'outcome': outcome,
        }),
      );
    });
    if (intent is Refused) return orphaned('spooled');
    await _hook(hooks.afterIntent, job);

    // 2. Publish.
    for (final s in jobStreams) {
      // Serialized with `snapshot`, which reads the spool or its published file.
      await job.gates[s]!.run(() => store.publish(job.spools[s]!, sealed[s]!));
      await hooks.afterStreamPublish?.call(job.id, s);
    }
    await _hook(hooks.afterPublish, job);

    // 3. Register, then 4. settle.
    final fields = {
      ...outcome,
      for (final s in jobStreams)
        s: {'handle': sealed[s]!.handle, 'complete': complete[s]},
    };
    Future<bool> settle() => _settle(job, fields, sealed.values);
    await _register(sealed.values);
    await _hook(hooks.afterRegister, job);
    if (!await settle()) return orphaned('published');
    job.slotHeld = false;

    // 5. Clear.
    await _hook(hooks.beforeClear, job);
    await _clear(
      job,
      mapping: mappingOf('published'),
      resettle: () async {
        await _register(sealed.values);
        return settle();
      },
    );
    return result();
  }

  Future<JobResult> _failLaunch(_Job job, String reason) async {
    for (final stream in jobStreams) {
      await job.gates[stream]!.run(job.live[stream]!.seal);
      final spool = File(
        p.join(store.sessionDir.path, resultsDirName, job.spools[stream]!),
      );
      if (spool.existsSync()) spool.deleteSync();
    }
    job.phase = _Phase.handoff;
    final fields = {'state': 'failed', 'reason': reason, 'ended': _now()};
    final mapping = <String, Object?>{
      for (final s in jobStreams)
        s: {'spool': job.spools[s], 'disposition': 'absent'},
    };
    Future<bool> settle() async => await _guardedMerge(job, fields) is Applied;
    final stale = !await settle();
    if (stale) await _recordOrphan(job, mapping, null);
    job.slotHeld = false;
    await _clear(
      job,
      mapping: mapping,
      resettle: stale ? () async => false : settle,
    );
    return JobResult(
      id: job.id,
      launch: job.launch,
      state: 'failed',
      reason: reason,
      stale: stale,
    );
  }

  Future<String?> _cleanupText(_Job job, int? code) async {
    var text = await job.termination;
    if (code == null && job.proc != null) {
      text = 'uncertain: process did not exit';
    }
    if (job.pipes.values.any((pipe) => pipe.forced)) {
      const held = 'uncertain: output pipe held by a surviving process';
      text = text == null || text == 'confirmed'
          ? held
          : '$held; ${text.replaceFirst('uncertain: ', '')}';
    }
    return text;
  }

  /// Merges the terminal [fields]; after a rewind dropped a descriptor, the
  /// listed ones are registered again and the same record retried. False
  /// means the job is stale.
  Future<bool> _settle(
    _Job job,
    Map<String, Object?> fields,
    Iterable<ResultDescriptor> descriptors,
  ) async {
    for (var attempt = 0; attempt < _maxHandoffRetries; attempt++) {
      switch (await _guardedMerge(job, fields)) {
        case Applied():
          return true;
        case Refused(reason: 'descriptors missing', :final handles):
          await _register(descriptors.where((d) => handles.contains(d.handle)));
        case Refused():
          return false;
      }
    }
    throw StateError('job ${job.id}: descriptors keep vanishing');
  }

  Future<void> _register(Iterable<ResultDescriptor> descriptors) async {
    for (final descriptor in descriptors) {
      await writer.recordResult(descriptor);
    }
  }

  /// Removes the launch record once its job is settled, or gone with its
  /// output mapping recorded; a job that reads non-terminal is settled again.
  Future<void> _clear(
    _Job job, {
    required Map<String, Object?> mapping,
    required Future<bool> Function() resettle,
  }) async {
    for (var attempt = 0; attempt < _maxHandoffRetries; attempt++) {
      final outcome = await _append((read) {
        if (read(job.launchPath) == null) return const GuardedRefusal('done');
        final node = read(job.path);
        final mine =
            node is Map<String, Object?> && node['launch'] == job.launch;
        if (mine && !_terminalStates.contains(node['state'])) {
          return const GuardedRefusal('unsettled');
        }
        if (!mine &&
            read('meta/orphans/${job.id}/outputs/${job.launch}') == null) {
          return const GuardedRefusal('unmapped');
        }
        return GuardedAppend(_record(job.launchPath, Op.del));
      });
      switch (outcome) {
        case Applied():
          return;
        case Refused(reason: 'done'):
          return;
        case Refused(reason: 'unsettled'):
          // A rewind undid the settle although the process really exited.
          if (!await resettle()) await _recordOrphan(job, mapping, null);
        case Refused(reason: 'unmapped'):
          await _recordOrphan(job, mapping, null);
        case Refused(:final reason):
          throw StateError('job ${job.id}: launch record not cleared: $reason');
      }
    }
    throw StateError('job ${job.id}: launch record not cleared');
  }

  /// The orphan transfer: the kill record, then the output mapping.
  Future<void> _recordOrphan(
    _Job job,
    Map<String, Object?> mapping,
    String? cleanup,
  ) async {
    await _append(
      (read) => GuardedAppend(
        _record('meta/orphans/${job.id}', Op.merge, {
          'cmd': job.request.cmd,
          'rewoundTo': writer.currentTurn,
          'cleanup': ?cleanup,
        }),
      ),
    );
    await _append(
      (read) => GuardedAppend(
        _record(
          'meta/orphans/${job.id}/outputs/${job.launch}',
          Op.set,
          mapping,
        ),
      ),
    );
  }

  // -- helpers ---------------------------------------------------------

  bool _owns(Object? node, _Job job) =>
      node is Map<String, Object?> &&
      node['launch'] == job.launch &&
      !_terminalStates.contains(node['state']);

  Future<GuardedOutcome> _guardedMerge(_Job job, Map<String, Object?> fields) =>
      _append(
        (read) => _owns(read(job.path), job)
            ? GuardedAppend(_record(job.path, Op.merge, fields))
            : const GuardedRefusal('stale'),
      );

  Future<GuardedOutcome> _append(
    GuardedDecision Function(GuardedRead read) build,
  ) => writer.applyGuarded(build);

  JournalRecord _record(String path, Op op, [Object? value]) =>
      JournalRecord(turn: writer.currentTurn, path: path, op: op, value: value);

  Future<void> _hook(Future<void> Function(String id)? hook, _Job job) =>
      hook == null ? Future<void>.value() : hook(job.id);
}

String _now() => DateTime.now().toUtc().toIso8601String();

final Random _random = Random.secure();

String _hex(int bytes) => List.generate(
  bytes,
  (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
).join();

/// Completes with true once [future] completes, or false after [limit].
Future<bool> _within(Future<Object?> future, Duration limit) {
  final result = Completer<bool>();
  final timer = Timer(limit, () {
    if (!result.isCompleted) result.complete(false);
  });
  void ended() {
    timer.cancel();
    if (!result.isCompleted) result.complete(true);
  }

  future.then<void>((_) => ended(), onError: (Object _) => ended());
  return result.future;
}
