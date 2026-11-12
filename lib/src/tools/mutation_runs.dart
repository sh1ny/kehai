import '../session/mutations.dart';

/// The maximum number of unfinished edit and write runs per engine.
const int maxUnfinishedMutationRuns = 16;

/// Tracks mutation futures, resolved targets, and the shared sequence.
///
/// A run occupies a slot until an untargeted attempt is released or its
/// durable finish retires it at the writer queue head. Rebuilding open call
/// keys replaces only the tree-derived portion; live targets remain
/// authoritative until their finish records are durable.
final class MutationRuns {
  /// Creates the engine registry for [session] with its shared [sequence].
  MutationRuns({required this.sequence, required String session})
    : _session = session;

  /// The sequence shared with recovery and baseline admission.
  final MutationSequence sequence;

  final String _session;
  final Map<String, MutationRun> _runs = {};
  Set<String> _treeOpenCallKeys = {};

  /// The number of reserved runs, including detached futures.
  int get length => _runs.length;

  /// The call keys of every reserved mutation run.
  Set<String> get activeCallKeys =>
      Set.unmodifiable({for (final run in _runs.values) run.callKey});

  /// The call keys open in the current tree or in an unfinished live run.
  Set<String> get openCallKeys => Set.unmodifiable({
    ..._treeOpenCallKeys,
    for (final run in _runs.values)
      if (run._target != null) run.callKey,
  });

  /// The resolved targets of registered runs that have not durably finished.
  Iterable<MutationTarget> get liveTargets sync* {
    for (final run in _runs.values) {
      final target = run._target;
      if (target != null) yield target;
    }
  }

  /// Reserves a slot, or returns null when all [maxUnfinishedMutationRuns]
  /// slots are occupied.
  MutationRun? reserve({
    required String callKey,
    required String attempt,
    required String callPath,
  }) {
    if (_runs.length >= maxUnfinishedMutationRuns) return null;
    if (_runs.containsKey(attempt)) {
      throw StateError('Mutation attempt is already registered.');
    }
    final run = MutationRun._(
      callKey: callKey,
      attempt: attempt,
      callPath: callPath,
      session: _session,
    );
    _runs[attempt] = run;
    return run;
  }

  /// Publishes [target] inside the accepted guarded target append decision.
  bool publish(MutationRun run, String target) {
    if (!isActive(run)) return false;
    final resolved = (
      runId: run.attempt,
      callPath: run.callPath,
      target: target,
      session: run.session,
    );
    final current = run._target;
    if (current != null && current != resolved) {
      throw StateError('Mutation target changed during one run.');
    }
    run._target = resolved;
    return true;
  }

  /// Whether [run] still occupies a registry slot.
  bool isActive(MutationRun run) => identical(_runs[run.attempt], run);

  /// The published target of [run], or null until its target append is accepted.
  MutationTarget? targetOf(MutationRun run) =>
      isActive(run) ? run._target : null;

  /// Releases a run that never published a target.
  void releaseUntargeted(MutationRun run) {
    if (!isActive(run)) return;
    if (run._target != null) {
      throw StateError('A targeted mutation must finish durably.');
    }
    _runs.remove(run.attempt);
  }

  /// Retires [run] after durable finish, preserving a replacement open call.
  void retire(MutationRun run, {required bool currentCallOpen}) {
    if (!isActive(run) || run._target == null) {
      throw StateError('Only an active targeted mutation can be retired.');
    }
    _runs.remove(run.attempt);
    if (currentCallOpen) {
      _treeOpenCallKeys.add(run.callKey);
    } else {
      _treeOpenCallKeys.remove(run.callKey);
    }
  }

  /// Rebuilds tree-derived open calls after resume or rewind.
  void rebuildOpenCallKeys(Map<String, Object?> tree) {
    _treeOpenCallKeys = openMutationCallKeys(tree);
  }
}

/// One reserved mutation attempt held until it is safely released or retired.
final class MutationRun {
  MutationRun._({
    required this.callKey,
    required this.attempt,
    required this.callPath,
    required this.session,
  });

  /// The call key within the session tree.
  final String callKey;

  /// The original attempt identifier, also used as the run id.
  final String attempt;

  /// The complete session path of the call node.
  final String callPath;

  /// The owning session id.
  final String session;

  MutationTarget? _target;
}
