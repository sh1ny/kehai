import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show Digest, sha256;
import 'package:path/path.dart' as p;

import '../session/mutations.dart' show MutationSequence;
import '../loop/sensorium.dart';
import '../shell/direct_exec.dart' show resolveProgram;
import '../shell/launch.dart' show startProcess;
import '../shell/process_tree.dart' show terminateProcessTree;
import 'project_root.dart' show projectRoot;

part 'vcs_collector_engine.dart';
part 'vcs_collector_git.dart';
part 'vcs_collector_jj.dart';

/// The bounded latest effects and shared capture authority for attribution.
typedef VcsAttributionInput = ({
  Map<String, String> effects,
  MutationSequence sequence,
  bool jobsLive,
});

/// A bounded content hash and file-stat sample.
typedef VcsFileSample = ({String sha256, int size, int modifiedMicros});

/// The before and after samples used to verify one effect.
typedef VcsVerification = ({VcsFileSample? before, VcsFileSample? after});

/// Reads and hashes at most [maxBytes] from an absolute workspace path.
typedef VcsFileReader = Future<VcsFileSample?> Function(
  String absolute,
  int maxBytes,
);

/// The small seam shared by request collection and status previews.
abstract interface class WorkspaceObserver {
  Future<VcsCollection> collect({
    required String root,
    String backend = 'auto',
    Duration deadline = const Duration(milliseconds: 300),
    VcsCollection? previous,
    int turn = 0,
    DateTime? time,
    VcsAttributionInput? attribution,
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
    this.verification = const {},
    this.captureCompleted = false,
    this.deadlineExpired = false,
  });

  final SensoriumObservation<SensoriumVcs> observation;
  final VcsBaseline? baseline;
  final List<VcsDelta> changes;
  final String? reason;
  final bool baselineLost;

  /// The per-path samples captured before and after the VCS command plan.
  final Map<String, VcsVerification> verification;

  /// Whether the complete VCS command plan finished.
  final bool captureCompleted;

  /// Whether the overall collection deadline expired.
  final bool deadlineExpired;
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
    this.pathIsUtf8 = true,
  });

  final String path;
  final int added;
  final int removed;
  final bool binary;

  /// Whether the original path bytes were valid UTF-8.
  final bool pathIsUtf8;
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
  /// The monotonic elapsed time shared by deadline waits and budget checks.
  Duration get elapsed;

  Future<void> wait(Duration duration);
}

/// Collects bounded jj or git observations for one engine.
final class VcsCollector implements WorkspaceObserver {
  VcsCollector({
    VcsProcessRunner? processRunner,
    VcsDeadlineScheduler? deadlineScheduler,
    VcsFileReader? readFile,
    Map<String, String>? environment,
  }) : _engine = _VcsCollectorEngine(
         processRunner: processRunner,
         deadlineScheduler: deadlineScheduler,
         readFile: readFile,
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
    VcsAttributionInput? attribution,
  }) => _engine.collect(
    root: root,
    backend: backend,
    deadline: deadline,
    previous: previous,
    turn: turn,
    time: time,
    attribution: attribution,
  );

  /// Closes this engine's collection and quarantined-index lifecycle.
  Future<void> close() => _engine.close();
}
