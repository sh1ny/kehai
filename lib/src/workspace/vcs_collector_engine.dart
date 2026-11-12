part of 'vcs_collector.dart';

const int _vcsOutputLimit = 4 * 1024 * 1024;
const int _vcsEntryLimit = 10000;
const int _vcsCleanupLimit = 16;
const int _vcsCommandLimit = 3;
const Duration _vcsCleanupWait = Duration(seconds: 10);

final class _CollectorFailure implements Exception {
  const _CollectorFailure(this.reason, this.message);

  final SensoriumReason reason;
  final String message;
}

final class _CollectionStopped implements Exception {
  const _CollectionStopped();
}

final class _CapturedBytes {
  const _CapturedBytes(this.bytes, this.truncated);

  final Uint8List bytes;
  final bool truncated;
}

final class _TimerVcsDeadlineScheduler implements VcsDeadlineScheduler {
  const _TimerVcsDeadlineScheduler();

  @override
  Future<void> wait(Duration duration) => Future<void>.delayed(duration);
}

final class _NativeVcsProcessRunner implements VcsProcessRunner {
  const _NativeVcsProcessRunner();

  @override
  Future<VcsProcess> start({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    required Map<String, String> environment,
  }) async {
    final setsid = Platform.isWindows
        ? null
        : resolveProgram(
            'setsid',
            workspaceRoot: workingDirectory,
            environment: environment,
          );
    final process = await startProcess(
      executable,
      arguments,
      workingDirectory: workingDirectory,
      environment: environment,
      setsid: setsid,
    );
    return _NativeVcsProcess(process, groupKnown: setsid != null);
  }
}

final class _NativeVcsProcess implements VcsProcess {
  _NativeVcsProcess(this._process, {required this.groupKnown});

  final Process _process;
  final bool groupKnown;
  Future<VcsTerminationResult>? _termination;

  late final Future<VcsProcessResult> _result = _collectResult();

  @override
  Future<VcsProcessResult> get result => _result;

  @override
  Future<VcsTerminationResult> terminate() => _termination ??= _terminateTree();

  Future<VcsTerminationResult> _terminateTree() async {
    final outcome = await terminateProcessTree(
      _process,
      groupKnown: groupKnown,
      windows: Platform.isWindows,
    );
    return outcome.cleanup == 'confirmed'
        ? VcsTerminationResult.confirmed
        : VcsTerminationResult.unverified;
  }

  Future<VcsProcessResult> _collectResult() async {
    final stdoutFuture = _capture(_process.stdout, _vcsOutputLimit, terminate);
    final stderrFuture = _capture(_process.stderr, 2048);
    final results = await Future.wait<Object>([
      stdoutFuture.then<Object>((value) => value),
      stderrFuture.then<Object>((value) => value),
      _process.exitCode.then<Object>((value) => value),
    ]);
    final stdout = results[0] as _CapturedBytes;
    final stderr = results[1] as _CapturedBytes;
    return VcsProcessResult(
      exitCode: results[2] as int,
      stdout: stdout.bytes,
      stderr: stderr.bytes,
      stdoutTruncated: stdout.truncated,
      stderrTruncated: stderr.truncated,
    );
  }

  Future<_CapturedBytes> _capture(
    Stream<List<int>> stream,
    int limit, [
    Future<VcsTerminationResult> Function()? onLimit,
  ]) async {
    final output = BytesBuilder(copy: false);
    final complete = Completer<void>();
    var retained = 0;
    var truncated = false;
    stream.listen(
      (chunk) {
        final remaining = limit - retained;
        if (remaining <= 0) {
          if (!truncated) {
            truncated = true;
            if (onLimit != null) {
              unawaited(onLimit().then<void>((_) {}, onError: (Object _) {}));
            }
          }
          return;
        }
        if (chunk.length <= remaining) {
          output.add(chunk);
          retained += chunk.length;
          return;
        }
        output.add(chunk.sublist(0, remaining));
        retained = limit;
        truncated = true;
        if (onLimit != null) {
          unawaited(onLimit().then<void>((_) {}, onError: (Object _) {}));
        }
      },
      onError: (Object error) {
        if (!complete.isCompleted) complete.completeError(error);
      },
      onDone: () {
        if (!complete.isCompleted) complete.complete();
      },
      cancelOnError: false,
    );
    await complete.future;
    return _CapturedBytes(output.takeBytes(), truncated);
  }
}

final class _VcsCollectorEngine {
  _VcsCollectorEngine({
    VcsProcessRunner? processRunner,
    VcsDeadlineScheduler? deadlineScheduler,
    Map<String, String>? environment,
  }) : _processRunner = processRunner ?? const _NativeVcsProcessRunner(),
       _deadlineScheduler =
           deadlineScheduler ?? const _TimerVcsDeadlineScheduler(),
       _environment = Map.unmodifiable(environment ?? Platform.environment);

  final VcsProcessRunner _processRunner;
  final VcsDeadlineScheduler _deadlineScheduler;
  final Map<String, String> _environment;
  final _CollectionMutex _mutex = _CollectionMutex();
  final Set<_CollectionRun> _runs = {};
  final Set<_CleanupLease> _leases = {};
  final Set<Directory> _temporaryDirectories = {};
  bool _firstCollection = true;
  bool _closed = false;
  int _indexSequence = 0;
  int _baselineSequence = 0;

  Future<VcsCollection> collect({
    required String root,
    required String backend,
    required Duration deadline,
    required VcsCollection? previous,
    required int turn,
    required DateTime? time,
  }) async {
    final observedAt = time ?? DateTime.now();
    if (_closed) {
      return _failedCollection(
        previous,
        SensoriumReason.failed,
        'collector closed',
        observedAt,
      );
    }

    var effectiveDeadline = deadline;
    if (_firstCollection) {
      _firstCollection = false;
      const coldStart = Duration(milliseconds: 3000);
      if (effectiveDeadline < coldStart) effectiveDeadline = coldStart;
    }

    final run = _CollectionRun(this, previous, observedAt);
    _runs.add(run);
    final timer = Future<void>.sync(
      () => _deadlineScheduler.wait(effectiveDeadline),
    );
    unawaited(
      timer.then<void>(
        (_) => run.stop(
          _failedCollection(
            previous,
            SensoriumReason.timedOut,
            'timeout',
            observedAt,
          ),
        ),
        onError: (Object _) => run.stop(
          _failedCollection(
            previous,
            SensoriumReason.timedOut,
            'timeout',
            observedAt,
          ),
        ),
      ),
    );

    final work =
        _collectSerialized(
          run,
          root: root,
          backend: backend,
          previous: previous,
          turn: turn,
          time: observedAt,
        ).then<VcsCollection>(
          (result) {
            run.finish();
            return result;
          },
          onError: (Object error, StackTrace _) {
            final result = _failureFromError(previous, error, observedAt);
            run.stop(result);
            return result;
          },
        );
    return Future.any([work, run.returned.future]);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    final now = DateTime.now();
    for (final run in List<_CollectionRun>.of(_runs)) {
      run.stop(
        _failedCollection(
          run.previous,
          SensoriumReason.failed,
          'collector closed',
          now,
        ),
      );
    }

    final cleanup = [
      for (final lease in _leases)
        if (lease.cleanupWait case final Future<void> wait) wait,
    ];
    if (cleanup.isNotEmpty) await Future.wait(cleanup);
    while (_leases.isNotEmpty) {
      _leases.first.releaseAtEngineClose();
    }
    while (_temporaryDirectories.isNotEmpty) {
      final directory = _temporaryDirectories.first;
      _temporaryDirectories.remove(directory);
      try {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      } on FileSystemException {
        // Shutdown cleanup is best-effort; no later capture reuses this path.
      }
    }
  }

  Future<VcsCollection> _collectSerialized(
    _CollectionRun run, {
    required String root,
    required String backend,
    required VcsCollection? previous,
    required int turn,
    required DateTime time,
  }) async {
    final lock = await _mutex.acquire();
    run.attachLock(lock);
    run.checkActive();
    try {
      return await _collectLocked(
        run,
        root: root,
        backend: backend,
        previous: previous,
        turn: turn,
        time: time,
      );
    } finally {
      lock.release();
    }
  }

  Future<VcsCollection> _collectLocked(
    _CollectionRun run, {
    required String root,
    required String backend,
    required VcsCollection? previous,
    required int turn,
    required DateTime time,
  }) async {
    if (backend == 'none') {
      return _unavailable(SensoriumReason.disabled, 'disabled');
    }
    if (backend != 'auto' && backend != 'git' && backend != 'jj') {
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: invalid backend',
      );
    }

    final start = p.normalize(p.absolute(root));
    final repository = p.normalize(p.absolute(projectRoot(start)));
    final jjExists = _hasMarker(repository, '.jj');
    final gitExists = _hasMarker(repository, '.git');
    if (!jjExists && !gitExists) {
      return _unavailable(SensoriumReason.noRepository, 'no repository');
    }

    final selected = backend == 'auto' ? (jjExists ? 'jj' : 'git') : backend;
    if (selected == 'jj' && !jjExists || selected == 'git' && !gitExists) {
      return _unavailable(SensoriumReason.noRepository, 'no repository');
    }
    run.checkActive();

    final executable = resolveProgram(
      selected,
      workspaceRoot: repository,
      environment: _environment,
    );
    if (executable == null) {
      final reason = selected == 'jj'
          ? SensoriumReason.jjNotFound
          : SensoriumReason.gitNotFound;
      return _failedCollection(previous, reason, '$selected not found', time);
    }

    return switch (selected) {
      'jj' => _collectJj(
        run,
        executable: executable,
        repository: repository,
        previous: previous,
        turn: turn,
        time: time,
      ),
      'git' => _collectGit(
        run,
        executable: executable,
        workspace: start,
        repository: repository,
        previous: previous,
        turn: turn,
        time: time,
      ),
      _ => throw StateError('Unreachable backend selection.'),
    };
  }

  VcsCollection _unavailable(SensoriumReason reason, String message) =>
      VcsCollection(observation: SensoriumUnavailable(reason), reason: message);

  VcsCollection _failedCollection(
    VcsCollection? previous,
    SensoriumReason reason,
    String message,
    DateTime now,
  ) {
    final value = switch (previous?.observation) {
      SensoriumAvailable<SensoriumVcs>(:final value) => value,
      SensoriumStale<SensoriumVcs>(:final value) => value,
      _ => null,
    };
    if (value == null) {
      return VcsCollection(
        observation: SensoriumUnavailable(reason),
        baseline: previous?.baseline,
        reason: message,
        baselineLost: previous?.baselineLost ?? false,
      );
    }
    final baselineTime = previous?.baseline?.time;
    final age = baselineTime == null
        ? switch (previous?.observation) {
            SensoriumStale<SensoriumVcs>(:final age) => age,
            _ => Duration.zero,
          }
        : now.difference(baselineTime);
    return VcsCollection(
      observation: SensoriumStale(
        value,
        age: age.isNegative ? Duration.zero : age,
        reason: reason,
      ),
      baseline: previous?.baseline,
      reason: message,
      baselineLost: previous?.baselineLost ?? false,
    );
  }

  VcsCollection _failureFromError(
    VcsCollection? previous,
    Object error,
    DateTime now,
  ) {
    if (error case _CollectorFailure(:final reason, :final message)) {
      return _failedCollection(previous, reason, message, now);
    }
    if (error is _CollectionStopped) {
      return _failedCollection(
        previous,
        SensoriumReason.timedOut,
        'timeout',
        now,
      );
    }
    return _failedCollection(
      previous,
      SensoriumReason.failed,
      'failed: collector error',
      now,
    );
  }

  Map<String, String> _gitEnvironment({String? privateIndex}) =>
      Map.unmodifiable({
        ..._environment,
        'GIT_OPTIONAL_LOCKS': '0',
        'GIT_TERMINAL_PROMPT': '0',
        'GIT_PAGER': 'cat',
        if (privateIndex != null) 'GIT_INDEX_FILE': privateIndex,
      });

  Map<String, String> _jjEnvironment() => Map.unmodifiable(_environment);

  Future<VcsProcessResult> _startCommand(
    _CollectionRun run, {
    required String executable,
    required String workingDirectory,
    required List<String> arguments,
    required Map<String, String> environment,
    required String tool,
  }) async {
    run.checkActive();
    run.reserveSlot();
    final permit = await run._commandLimiter.acquire(run._stoppedSignal.future);
    if (permit == null) throw const _CollectionStopped();
    var releasePermit = true;
    try {
      run.checkActive();
      final tracked = _TrackedCommand(
        run,
        () => _processRunner.start(
          executable: executable,
          arguments: List.unmodifiable(arguments),
          workingDirectory: workingDirectory,
          environment: environment,
        ),
      );
      run.addCommand(tracked);
      unawaited(
        run._stoppedSignal.future.then<void>(
          (_) => _releasePermitOnTermination(tracked, permit),
        ),
      );

      VcsProcess process;
      try {
        process = await tracked.launch();
      } on Object catch (error) {
        run.removeCommand(tracked);
        if (run.isStopped) throw const _CollectionStopped();
        throw _commandStartFailure(tool, error);
      }
      if (run.isStopped) {
        releasePermit = false;
        _releasePermitOnExitOrTermination(tracked, process, permit);
        unawaited(tracked.terminate());
        throw const _CollectionStopped();
      }

      try {
        final result = _boundProcessResult(await process.result);
        if (run.isStopped) throw const _CollectionStopped();
        if (process is _NativeVcsProcess && result._stdoutTruncated) {
          run.retainForCleanup(tracked);
        } else {
          run.removeCommand(tracked);
        }
        return result;
      } on _CollectionStopped {
        rethrow;
      } on Object catch (error) {
        releasePermit = false;
        _releasePermitOnExitOrTermination(tracked, process, permit);
        if (run.isStopped) throw const _CollectionStopped();
        throw _commandStartFailure(tool, error);
      }
    } finally {
      if (releasePermit) permit.release();
    }
  }

  _CollectorFailure _commandStartFailure(String tool, Object error) {
    if (error is ProcessException && error.errorCode == 2) {
      return _CollectorFailure(
        tool == 'jj' ? SensoriumReason.jjNotFound : SensoriumReason.gitNotFound,
        '$tool not found',
      );
    }
    return _CollectorFailure(
      SensoriumReason.failed,
      _boundedReason(
        '$tool failed',
        error is ProcessException ? error.message : '',
      ),
    );
  }

  Directory _newTemporaryDirectory(String repository) {
    final directory = Directory.systemTemp.createTempSync('kehai-vcs-');
    final path = p.canonicalize(directory.path);
    final root = p.canonicalize(repository);
    if (p.equals(root, path) || p.isWithin(root, path)) {
      try {
        directory.deleteSync(recursive: true);
      } on FileSystemException {
        // The repository remains untouched; the failure below is fail-closed.
      }
      throw const _CollectorFailure(
        SensoriumReason.failed,
        'failed: temporary directory is inside repository',
      );
    }
    _temporaryDirectories.add(directory);
    return directory;
  }

  Future<String> _privateIndex(
    _CollectionRun run, {
    required String repository,
    required String sourcePath,
  }) async {
    run.checkActive();
    final lease = run.lease;
    if (lease == null)
      throw StateError('A process slot must precede the index.');
    final directory = _newTemporaryDirectory(repository);
    lease.directory = directory;
    final destination = p.join(directory.path, 'index');
    run.privateIndex = destination;
    final source = File(sourcePath);
    final exists = await run.trackIo(source.exists());
    run.checkActive();
    if (exists) {
      await run.trackIo(source.copy(destination));
      run.checkActive();
    }
    return destination;
  }

  VcsBaseline _baseline(String backend, String id, int turn, DateTime time) =>
      VcsBaseline(
        backend: backend,
        id: id,
        turn: turn,
        time: time,
        seq: ++_baselineSequence,
        jobsLive: false,
      );

  bool _hasMarker(String directory, String marker) =>
      FileSystemEntity.typeSync(
        p.join(directory, marker),
        followLinks: false,
      ) !=
      FileSystemEntityType.notFound;

  void _reserve(_CollectionRun run) {
    if (_leases.length >= _vcsCleanupLimit) {
      throw const _CollectorFailure(
        SensoriumReason.cleanupPending,
        'cleanup pending',
      );
    }
    final lease = _CleanupLease(this, run);
    _leases.add(lease);
    run.lease = lease;
  }

  void _releaseLease(_CleanupLease lease) {
    if (!_leases.remove(lease)) return;
    final directory = lease.directory;
    if (directory != null) {
      try {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      } on FileSystemException {
        // A private index is disposable and can be retried at engine close.
      }
      if (!directory.existsSync()) _temporaryDirectories.remove(directory);
    }
  }

  void _forgetRun(_CollectionRun run) => _runs.remove(run);

  Future<VcsProcessResult> command(
    _CollectionRun run, {
    required String executable,
    required String cwd,
    required List<String> arguments,
    required Map<String, String> environment,
    required String tool,
  }) => _startCommand(
    run,
    executable: executable,
    workingDirectory: cwd,
    arguments: arguments,
    environment: environment,
    tool: tool,
  );

  Map<String, String> gitEnvironment({String? privateIndex}) =>
      _gitEnvironment(privateIndex: privateIndex);

  Map<String, String> jjEnvironment() => _jjEnvironment();

  Directory newTemporaryDirectory(String repository) =>
      _newTemporaryDirectory(repository);

  Future<String> privateIndex(
    _CollectionRun run, {
    required String repository,
    required String sourcePath,
  }) => _privateIndex(run, repository: repository, sourcePath: sourcePath);

  VcsBaseline baseline(String backend, String id, int turn, DateTime time) =>
      _baseline(backend, id, turn, time);
}

final class _CollectionRun {
  _CollectionRun(this.engine, this.previous, this.time);

  final _VcsCollectorEngine engine;
  final VcsCollection? previous;
  final DateTime time;
  final Completer<VcsCollection> returned = Completer<VcsCollection>();
  final _CommandLimiter _commandLimiter = _CommandLimiter();
  final Set<_TrackedCommand> _commands = {};
  final Set<_TrackedCommand> _cleanupCommands = {};
  final Set<Future<void>> _io = {};
  _LockLease? _lock;
  _CleanupLease? lease;
  String? privateIndex;
  bool _stopped = false;
  final Completer<void> _stoppedSignal = Completer<void>();
  bool _finished = false;

  bool get isStopped => _stopped || _finished;

  void checkActive() {
    if (isStopped) throw const _CollectionStopped();
  }

  void attachLock(_LockLease lock) {
    _lock = lock;
    if (_stopped) lock.release();
  }

  void releaseLock() {
    _lock?.release();
    _lock = null;
  }

  void reserveSlot() {
    checkActive();
    if (lease != null) return;
    engine._reserve(this);
  }

  void addCommand(_TrackedCommand command) => _commands.add(command);

  void removeCommand(_TrackedCommand command) => _commands.remove(command);

  void retainForCleanup(_TrackedCommand command) {
    _commands.remove(command);
    _cleanupCommands.add(command);
    unawaited(command.terminate());
  }

  Future<T> trackIo<T>(Future<T> operation) {
    final settled = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _io.add(settled);
    settled.then<void>((_) => _io.remove(settled));
    return operation;
  }

  void finish() {
    if (_stopped || _finished) return;
    _finished = true;
    releaseLock();
    final currentLease = lease;
    if (currentLease != null) {
      if (_cleanupCommands.isEmpty) {
        engine._releaseLease(currentLease);
      } else {
        currentLease.quarantine(
          List<_TrackedCommand>.of(_cleanupCommands),
          List<Future<void>>.of(_io),
        );
      }
    }
    engine._forgetRun(this);
  }

  void stop(VcsCollection result) {
    if (_stopped || _finished) return;
    _stopped = true;
    if (!_stoppedSignal.isCompleted) _stoppedSignal.complete();
    releaseLock();
    engine._forgetRun(this);
    final currentLease = lease;
    if (currentLease != null) {
      currentLease.quarantine([
        ..._commands,
        ..._cleanupCommands,
      ], List<Future<void>>.of(_io));
    }
    if (!returned.isCompleted) returned.complete(result);
  }
}

final class _TrackedCommand {
  _TrackedCommand(this.run, this._start);

  final _CollectionRun run;
  final Future<VcsProcess> Function() _start;
  Future<VcsProcess>? _launch;
  Future<VcsTerminationResult>? _termination;
  VcsTerminationResult? _terminationResult;

  bool get isConfirmed => _terminationResult == VcsTerminationResult.confirmed;

  Future<VcsProcess> launch() => _launch ??= Future<VcsProcess>.sync(_start);

  Future<VcsTerminationResult> terminate() => _termination ??= launch()
      .then(
        (process) => process.terminate(),
        onError: (Object _) => VcsTerminationResult.confirmed,
      )
      .then(
        (result) {
          _terminationResult = result;
          return result;
        },
        onError: (Object _) {
          _terminationResult = VcsTerminationResult.unverified;
          return VcsTerminationResult.unverified;
        },
      );
}

final class _CleanupLease {
  _CleanupLease(this.engine, this.run);

  final _VcsCollectorEngine engine;
  final _CollectionRun run;
  Directory? directory;
  bool _quarantined = false;
  bool _released = false;
  Future<void>? _cleanupWait;

  Future<void>? get cleanupWait => _cleanupWait;

  void quarantine(
    List<_TrackedCommand> commands,
    List<Future<void>> pendingIo,
  ) {
    if (_released || _quarantined) return;
    _quarantined = true;
    final completions = <Future<void>>[
      ...pendingIo,
      for (final command in commands)
        command.terminate().then<void>((result) {
          if (result != VcsTerminationResult.confirmed) _quarantined = true;
        }, onError: (Object _) => _quarantined = true),
    ];
    final work = Future.wait(completions);
    unawaited(
      work.then<void>((_) {
        if (commands.every((command) => command.isConfirmed)) {
          _release();
        }
      }, onError: (Object _) {}),
    );
    final bounded = Completer<void>();
    final timer = Timer(_vcsCleanupWait, () {
      if (!bounded.isCompleted) bounded.complete();
    });
    work.then<void>(
      (_) {
        timer.cancel();
        if (!bounded.isCompleted) bounded.complete();
      },
      onError: (Object _) {
        timer.cancel();
        if (!bounded.isCompleted) bounded.complete();
      },
    );
    _cleanupWait = bounded.future;
  }

  void releaseAtEngineClose() => _release();

  void _release() {
    if (_released) return;
    _released = true;
    engine._releaseLease(this);
  }
}

final class _CollectionMutex {
  Future<void> _tail = Future<void>.value();

  Future<_LockLease> acquire() async {
    final previous = _tail;
    final release = Completer<void>();
    _tail = release.future;
    await previous;
    return _LockLease(release);
  }
}

final class _LockLease {
  _LockLease(this._release);

  final Completer<void> _release;

  void release() {
    if (!_release.isCompleted) _release.complete();
  }
}

final class _CommandLimiter {
  final List<Completer<_CommandPermit?>> _waiters = [];
  int _active = 0;

  Future<_CommandPermit?> acquire(Future<void> stopped) async {
    if (_active < _vcsCommandLimit) {
      _active++;
      return _CommandPermit(this);
    }
    final waiter = Completer<_CommandPermit?>();
    _waiters.add(waiter);
    unawaited(
      stopped.then<void>((_) {
        if (waiter.isCompleted) return;
        _waiters.remove(waiter);
        waiter.complete(null);
      }),
    );
    return waiter.future;
  }

  void release() {
    while (_waiters.isNotEmpty) {
      final waiter = _waiters.removeAt(0);
      if (waiter.isCompleted) continue;
      waiter.complete(_CommandPermit(this));
      return;
    }
    _active--;
  }
}

final class _CommandPermit {
  _CommandPermit(this._limiter);

  final _CommandLimiter _limiter;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _limiter.release();
  }
}

void _releasePermitOnTermination(
  _TrackedCommand command,
  _CommandPermit permit,
) {
  unawaited(
    command.terminate().then<void>((result) {
      if (result == VcsTerminationResult.confirmed) permit.release();
    }, onError: (Object _) {}),
  );
}

void _releasePermitOnExitOrTermination(
  _TrackedCommand command,
  VcsProcess process,
  _CommandPermit permit,
) {
  unawaited(
    process.result.then<void>((_) => permit.release(), onError: (Object _) {}),
  );
  _releasePermitOnTermination(command, permit);
}

String _boundedReason(String prefix, String detail) {
  final output = StringBuffer(prefix);
  final available = 200 - prefix.length - 3;
  if (detail.isEmpty || available < 0) return prefix;
  output.write(': ');
  var written = 0;
  for (final rune in detail.runes) {
    final width = rune > 0xffff ? 2 : 1;
    if (written + width > available) {
      output.write('…');
      break;
    }
    if (rune == 10 || rune == 13 || rune == 0 || rune < 32) {
      output.write(' ');
    } else {
      output.writeCharCode(rune);
    }
    written += width;
  }
  return output.toString();
}

VcsProcessResult _boundProcessResult(VcsProcessResult result) {
  final stdoutTruncated =
      result._stdoutTruncated || result.stdout.length > _vcsOutputLimit;
  final stderrTruncated =
      result._stderrTruncated || result.stderr.length > 2048;
  final stdout = result.stdout.length > _vcsOutputLimit
      ? result.stdout.sublist(0, _vcsOutputLimit)
      : result.stdout;
  final stderr = result.stderr.length > 2048
      ? result.stderr.sublist(0, 2048)
      : result.stderr;
  if (!stdoutTruncated && !stderrTruncated) return result;
  return VcsProcessResult(
    exitCode: result.exitCode,
    stdout: stdout,
    stderr: stderr,
    stdoutTruncated: stdoutTruncated,
    stderrTruncated: stderrTruncated,
  );
}

String _processFailure(String tool, VcsProcessResult result) {
  final limit = result.stderr.length < 2048 ? result.stderr.length : 2048;
  final detail = _decodeBytes(result.stderr, 0, limit).trim();
  return _boundedReason('$tool failed', detail);
}

bool _looksLikeMissingBaseline(VcsProcessResult result) {
  final length = result.stderr.length < 2048 ? result.stderr.length : 2048;
  final message = _decodeBytes(result.stderr, 0, length).toLowerCase();
  return message.contains('bad object') ||
      message.contains('unknown revision') ||
      message.contains('revision not found') ||
      message.contains('not a valid object') ||
      message.contains('no such revision') ||
      message.contains('cannot resolve revision');
}

List<int> _byteView(List<int> bytes, int start, int end) => bytes is Uint8List
    ? Uint8List.sublistView(bytes, start, end)
    : bytes.sublist(start, end);

String _decodeBytes(List<int> bytes, int start, int end) {
  final output = StringBuffer();
  var segment = start;
  var index = start;
  while (index < end) {
    final width = _utf8WidthAt(bytes, index, end);
    if (width != 0) {
      index += width;
      continue;
    }
    if (segment < index) {
      output.write(utf8.decode(_byteView(bytes, segment, index)));
    }
    output
      ..write(r'\u{')
      ..write(bytes[index].toRadixString(16).toUpperCase())
      ..write('}');
    index++;
    segment = index;
  }
  if (segment < end) output.write(utf8.decode(_byteView(bytes, segment, end)));
  return output.toString();
}

int _utf8WidthAt(List<int> bytes, int index, int end) {
  final first = bytes[index];
  if (first <= 0x7f) return 1;
  if (first >= 0xc2 && first <= 0xdf) {
    if (index + 1 < end && _continuation(bytes[index + 1])) return 2;
    return 0;
  }
  if (first >= 0xe0 && first <= 0xef) {
    if (index + 2 >= end) return 0;
    final second = bytes[index + 1];
    final third = bytes[index + 2];
    final validSecond = switch (first) {
      0xe0 => second >= 0xa0 && second <= 0xbf,
      0xed => second >= 0x80 && second <= 0x9f,
      _ => _continuation(second),
    };
    return validSecond && _continuation(third) ? 3 : 0;
  }
  if (first >= 0xf0 && first <= 0xf4) {
    if (index + 3 >= end) return 0;
    final second = bytes[index + 1];
    final validSecond = switch (first) {
      0xf0 => second >= 0x90 && second <= 0xbf,
      0xf4 => second >= 0x80 && second <= 0x8f,
      _ => _continuation(second),
    };
    return validSecond &&
            _continuation(bytes[index + 2]) &&
            _continuation(bytes[index + 3])
        ? 4
        : 0;
  }
  return 0;
}

bool _continuation(int byte) => byte >= 0x80 && byte <= 0xbf;

String _repositoryPath(String path) => p.posix.joinAll(p.split(path));

String _clipUtf8(String value, int maxBytes) {
  final output = StringBuffer();
  var bytes = 0;
  var truncated = false;
  for (final rune in value.runes) {
    final width = rune <= 0x7f
        ? 1
        : rune <= 0x7ff
        ? 2
        : rune <= 0xffff
        ? 3
        : 4;
    if (bytes + width > maxBytes) {
      truncated = true;
      break;
    }
    output.writeCharCode(rune);
    bytes += width;
  }
  if (truncated) output.write('…');
  return output.toString();
}
