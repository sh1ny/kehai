import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../loop/sensorium.dart';
import '../shell/direct_exec.dart' show resolveProgram;
import '../shell/launch.dart' show startProcess;
import '../shell/process_tree.dart' show terminateProcessTree;
import 'project_root.dart' show projectRoot;

part 'vcs_collector_engine.dart';
part 'vcs_collector_git.dart';
part 'vcs_collector_jj.dart';

/// The small seam shared by request collection and status previews.
abstract interface class WorkspaceObserver {
  Future<VcsCollection> collect({
    required String root,
    String backend = 'auto',
    Duration deadline = const Duration(milliseconds: 300),
    VcsCollection? previous,
    int turn = 0,
    DateTime? time,
  });
}

/// One bounded result from a workspace observation.
final class VcsCollection {
  const VcsCollection({
    required this.observation,
    this.baseline,
    this.changes = const [],
    this.reason,
    this.baselineLost = false,
  });

  final SensoriumObservation<SensoriumVcs> observation;
  final VcsBaseline? baseline;
  final List<VcsDelta> changes;
  final String? reason;
  final bool baselineLost;
}

/// A content-addressed VCS capture attached to an admitted observation.
final class VcsBaseline {
  const VcsBaseline({
    required this.backend,
    required this.id,
    required this.turn,
    required this.time,
    required this.seq,
    required this.jobsLive,
  });

  final String backend;
  final String id;
  final int turn;
  final DateTime time;
  final int seq;
  final bool jobsLive;
}

/// One file's bounded line-count delta from the previous baseline.
final class VcsDelta {
  const VcsDelta({
    required this.path,
    required this.added,
    required this.removed,
    required this.binary,
  });

  final String path;
  final int added;
  final int removed;
  final bool binary;
}

/// A process started by the collector's injected runner.
abstract interface class VcsProcessRunner {
  Future<VcsProcess> start({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    required Map<String, String> environment,
  });
}

/// The collected output of one bounded process invocation.
abstract interface class VcsProcess {
  Future<VcsProcessResult> get result;

  Future<VcsTerminationResult> terminate();
}

/// A process result with raw bytes so NUL-delimited VCS paths stay intact.
final class VcsProcessResult {
  const VcsProcessResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
    this._stdoutTruncated = false,
    this._stderrTruncated = false,
  });

  final int exitCode;
  final List<int> stdout;
  final List<int> stderr;
  final bool _stdoutTruncated;
  final bool _stderrTruncated;
}

enum VcsTerminationResult { confirmed, unverified }

/// An injectable deadline wait used by deterministic collector tests.
abstract interface class VcsDeadlineScheduler {
  Future<void> wait(Duration duration);
}

/// Collects bounded jj or git observations for one engine.
final class VcsCollector implements WorkspaceObserver {
  VcsCollector({
    VcsProcessRunner? processRunner,
    VcsDeadlineScheduler? deadlineScheduler,
    Map<String, String>? environment,
  }) : _engine = _VcsCollectorEngine(
         processRunner: processRunner,
         deadlineScheduler: deadlineScheduler,
         environment: environment,
       );

  final _VcsCollectorEngine _engine;

  @override
  Future<VcsCollection> collect({
    required String root,
    String backend = 'auto',
    Duration deadline = const Duration(milliseconds: 300),
    VcsCollection? previous,
    int turn = 0,
    DateTime? time,
  }) => _engine.collect(
    root: root,
    backend: backend,
    deadline: deadline,
    previous: previous,
    turn: turn,
    time: time,
  );

  /// Closes this engine's collection and quarantined-index lifecycle.
  Future<void> close() => _engine.close();
}
