import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../loop/sensorium.dart';
import '../session/path.dart';
import '../session/tree.dart';
import '../tools/mutation_runs.dart';
import 'vcs_collector.dart';

const _metadataByteLimit = 4 * 1024;
const _displayRowLimit = 12;
const _baselineStepLimit = 256;
const _terminalJobStates = {'settled', 'failed', 'cancelled'};

/// Collects VCS observations and attributes their changed paths to recorded
/// mutation effects, other processes, or work outside the recorded interval.
final class WorkspacePerception {
  /// Creates a workspace observer using the requested [backend] and deadline.
  WorkspacePerception({
    required String root,
    required WorkspaceObserver observer,
    required MutationRuns mutations,
    this.backend = 'auto',
    this.deadline = const Duration(milliseconds: 300),
  }) : _root = root,
       _observer = observer,
       _mutations = mutations;

  final String _root;
  final WorkspaceObserver _observer;
  final MutationRuns _mutations;

  /// Preferred backend used for each bounded observation.
  final String backend;

  /// Maximum duration allowed for an observation.
  final Duration deadline;

  /// Freezes the admitted baseline and attribution facts before collection.
  WorkspacePerceptionCapture capture({
    required SessionTree tree,
    required SensoriumSource source,
  }) {
    final lookup = _findAdmitted(tree, source.turn);
    final admitted = lookup.admitted;
    final baseline = admitted?.baseline;
    final lost = lookup.lost || (admitted?.lost ?? false);
    final currentJobsLive = _jobsLive(tree);
    final attribution = _freezeAttribution(
      tree,
      source,
      baseline,
      admitted?.observedTurn,
      currentJobsLive: currentJobsLive,
    );
    return WorkspacePerceptionCapture._(
      this,
      source,
      _FrozenWorkspace(
        admitted: admitted,
        baseline: baseline,
        baselineLost: lost,
        previous: admitted == null
            ? null
            : _previousCollection(admitted, source),
        currentJobsLive: currentJobsLive,
        attribution: attribution,
      ),
    );
  }

  Future<WorkspacePerceptionFrame> _collect(
    SensoriumSource source,
    _FrozenWorkspace frozen,
  ) async {
    final input = (
      effects: Map<String, String>.unmodifiable(frozen.attribution.effects),
      sequence: _mutations.sequence,
      jobsLive: frozen.currentJobsLive,
    );
    late final VcsCollection collection;
    try {
      collection = await _observer.collect(
        root: _root,
        backend: backend,
        deadline: deadline,
        previous: frozen.previous,
        turn: source.turn,
        time: source.time,
        attribution: input,
      );
    } on Object {
      collection = const VcsCollection(
        observation: SensoriumUnavailable(SensoriumReason.failed),
        reason: 'failed',
        captureCompleted: false,
      );
    }
    return _frame(source, frozen, collection);
  }

  WorkspacePerceptionFrame _frame(
    SensoriumSource source,
    _FrozenWorkspace frozen,
    VcsCollection collection,
  ) {
    final currentVcs = switch (collection.observation) {
      SensoriumAvailable<SensoriumVcs>(:final value) => value,
      _ => null,
    };
    final currentBaseline = collection.baseline;
    if (backend == 'none') {
      return _failedFrame(
        source,
        frozen,
        collection,
        SensoriumReason.disabled,
        disabled: true,
      );
    }
    if (!collection.captureCompleted ||
        currentVcs == null ||
        currentBaseline == null ||
        !_validBaseline(currentBaseline)) {
      return _failedFrame(
        source,
        frozen,
        collection,
        _failureReason(collection),
        disabled: false,
      );
    }

    final baseline = currentBaseline;
    final lost =
        frozen.baselineLost ||
        collection.baselineLost ||
        (frozen.baseline != null &&
            frozen.baseline!.backend != baseline.backend);
    final notices = <SensoriumNotice>{};
    if (collection.deadlineExpired) notices.add(SensoriumNotice.vcsTimeout);
    if (lost) notices.add(SensoriumNotice.baselineReset);

    final previousBaseline = frozen.baseline;
    SensoriumReason? changesUnavailable;
    final Map<String, Object?> changeValue;
    if (lost) {
      changesUnavailable = SensoriumReason.baselineLost;
      changeValue = _unavailableChanges(SensoriumReason.baselineLost);
    } else if (previousBaseline == null) {
      changesUnavailable = SensoriumReason.noBaseline;
      changeValue = _unavailableChanges(SensoriumReason.noBaseline);
    } else {
      final rawRows = <SensoriumChange>[
        for (final delta in collection.changes)
          SensoriumChange(
            delta.path,
            added: delta.added,
            removed: delta.removed,
            binary: delta.binary,
            by: _classify(delta, frozen.attribution, collection.verification),
          ),
      ];
      if (rawRows.any((row) => row.by == SensoriumChangeBy.user)) {
        notices.add(SensoriumNotice.userEdits);
      }
      final totalPaths = rawRows.length;
      var rowsWereClipped = false;
      final rows = <Object?>[];
      for (final row in rawRows.take(_displayRowLimit)) {
        final path = _clipJsonString(row.path, 64);
        if (path != row.path) rowsWereClipped = true;
        rows.add({
          'path': path,
          'added': row.added,
          'removed': row.removed,
          'by': row.by.name,
          'binary': row.binary,
        });
      }
      changeValue = {
        'state': 'available',
        'sinceTurn': previousBaseline.turn,
        'rows': rows,
        'totalPaths': totalPaths,
        'partial': rowsWereClipped || collection.deltaPartial,
      };
    }

    final value = _vcsValue(currentVcs, changeValue);
    final metadata = <String, Object?>{
      'state': 'available',
      'observed': {
        'turn': baseline.turn,
        'time': baseline.time.toIso8601String(),
      },
      'value': value,
      'baseline': _baselineJson(baseline),
    };
    _fitFreshMetadata(metadata);
    final boundedValue = metadata['value']! as Map<String, Object?>;
    final vcs = _decodeVcs(boundedValue);
    final decodedChanges = _decodeChanges(
      boundedValue['changes']! as Map<String, Object?>,
    );
    final SensoriumObservation<SensoriumChanges> finalChanges =
        changesUnavailable == null
        ? SensoriumAvailable(decodedChanges)
        : SensoriumUnavailable(changesUnavailable);

    return WorkspacePerceptionFrame(
      source: source,
      vcs: SensoriumAvailable(vcs),
      changes: finalChanges,
      notices: notices,
      metadata: metadata,
      baselineSequence: baseline.seq,
    );
  }

  WorkspacePerceptionFrame _failedFrame(
    SensoriumSource source,
    _FrozenWorkspace frozen,
    VcsCollection collection,
    SensoriumReason failure, {
    required bool disabled,
  }) {
    final stored = frozen.admitted;
    final notices = <SensoriumNotice>{};
    final baselineLost =
        frozen.baselineLost ||
        collection.baselineLost ||
        failure == SensoriumReason.baselineLost;
    if (!disabled &&
        (failure == SensoriumReason.timedOut || collection.deadlineExpired)) {
      notices.add(SensoriumNotice.vcsTimeout);
    } else if (!disabled && _isFailureNotice(failure)) {
      notices.add(SensoriumNotice.vcsFailed);
    }
    if (baselineLost) notices.add(SensoriumNotice.baselineReset);

    final previousVcs = stored == null ? null : _decodeStoredVcs(stored.value);
    final hasStaleValue = previousVcs != null && stored?.observedTime != null;
    final preserveObserved = hasStaleValue || frozen.baseline != null;
    final reason = disabled
        ? SensoriumReason.disabled
        : baselineLost
        ? SensoriumReason.baselineLost
        : failure;
    final changesReason = disabled
        ? SensoriumReason.disabled
        : baselineLost
        ? SensoriumReason.baselineLost
        : frozen.baseline == null
        ? SensoriumReason.noBaseline
        : failure;
    final metadata = <String, Object?>{
      'state': hasStaleValue && !disabled ? 'stale' : 'unavailable',
      'reason': _reasonLabel(reason),
      'observed': preserveObserved
          ? stored!.raw['observed']
          : {'turn': source.turn, 'time': source.time.toIso8601String()},
      if (hasStaleValue) 'value': stored!.value,
      if (stored?.raw['baseline'] case final Map<String, Object?> baseline)
        'baseline': baseline,
    };
    if (_encodedLength(metadata) > _metadataByteLimit) {
      if (disabled) metadata.remove('value');
      if (_encodedLength(metadata) > _metadataByteLimit) {
        metadata.remove('reason');
      }
    }
    late final SensoriumObservation<SensoriumVcs> observation;
    if (hasStaleValue && !disabled) {
      final age = source.time.difference(stored!.observedTime!);
      observation = SensoriumStale<SensoriumVcs>(
        previousVcs,
        age: age.isNegative ? Duration.zero : age,
        reason: reason,
      );
    } else {
      observation = SensoriumUnavailable<SensoriumVcs>(reason);
    }
    return WorkspacePerceptionFrame(
      source: source,
      vcs: observation,
      changes: SensoriumUnavailable(changesReason),
      notices: notices,
      metadata: metadata,
      baselineSequence: stored?.baseline?.seq,
    );
  }

  _Lookup _findAdmitted(SessionTree tree, int turn) {
    final stepsPath = SessionPath.parse('body/steps');
    final keys = <(int, String)>[];
    for (final key in tree.childKeys(stepsPath)) {
      final stepTurn = _stepTurn(key);
      if (stepTurn != null && stepTurn <= turn) keys.add((stepTurn, key));
    }
    keys.sort((left, right) => right.$1.compareTo(left.$1));
    final count = keys.length < _baselineStepLimit
        ? keys.length
        : _baselineStepLimit;
    for (var index = 0; index < count; index++) {
      final key = keys[index].$2;
      final raw = tree.get(SessionPath.parse('body/steps/$key/sensorium/vcs'));
      if (raw is! Map<String, Object?> || raw['state'] is! String) continue;
      return _Lookup(
        _parseStored(raw),
        lost: raw['reason'] == _reasonLabel(SensoriumReason.baselineLost),
      );
    }
    return _Lookup(null, lost: keys.length >= _baselineStepLimit);
  }

  VcsCollection _previousCollection(
    _StoredPerception stored,
    SensoriumSource source,
  ) {
    final vcs = _decodeStoredVcs(stored.value);
    final SensoriumObservation<SensoriumVcs> observation;
    if (vcs == null) {
      observation = SensoriumUnavailable(
        stored.reason ?? SensoriumReason.notCollected,
      );
    } else if (stored.state == 'stale') {
      final observed = stored.observedTime ?? source.time;
      final age = source.time.difference(observed);
      observation = SensoriumStale(
        vcs,
        age: age.isNegative ? Duration.zero : age,
        reason: stored.reason ?? SensoriumReason.failed,
      );
    } else {
      observation = SensoriumAvailable(vcs);
    }
    final previousRows = <VcsDelta>[];
    final rawChanges = stored.value?['changes'];
    if (rawChanges case {'rows': final List<Object?> rows}) {
      for (final row in rows) {
        if (row case {
          'path': final String path,
          'added': final int added,
          'removed': final int removed,
          'binary': final bool binary,
        }) {
          previousRows.add(
            VcsDelta(
              path: path,
              added: added,
              removed: removed,
              binary: binary,
            ),
          );
        }
      }
    }
    return VcsCollection(
      observation: observation,
      baseline: stored.baseline,
      changes: List.unmodifiable(previousRows),
      reason: stored.reason == null ? null : _reasonLabel(stored.reason!),
      baselineLost: stored.lost,
      captureCompleted: stored.baseline != null,
    );
  }

  _Attribution _freezeAttribution(
    SessionTree tree,
    SensoriumSource source,
    VcsBaseline? baseline,
    int? baselineTurn, {
    required bool currentJobsLive,
  }) {
    final targets = <String>{};
    final pathFacts = <String, _MutationPathFacts>{};
    var processActivity = currentJobsLive || (baseline?.jobsLive ?? false);

    void observeMutation(_CallFacts call) {
      final target = call.target;
      if (target == null || target.isEmpty) {
        processActivity = true;
        return;
      }
      targets.add(target);
      final facts = pathFacts.putIfAbsent(target, _MutationPathFacts.new);
      facts.hasMutation = true;
      final effect = call.effect;
      if (effect is Map<String, Object?>) {
        final hash = effect['sha256'];
        final seq = effect['seq'];
        if (hash is! String || hash.isEmpty || seq is! int || seq < 0) {
          facts.missingEffectSequence = true;
          return;
        }
        final current = facts.latestEffect;
        if (current == null || seq > current.sequence) {
          facts.latestEffect = _Effect(hash, seq);
        }
      } else {
        final boundary = call.targetAfterSeq;
        facts.unresolvedBoundaries.add(
          boundary is int && boundary >= 0 ? boundary : null,
        );
      }
    }

    final seenMutationCalls = <String>{};
    if (baseline != null && baselineTurn != null) {
      final stepKeys = tree.childKeys(SessionPath.parse('body/steps'));
      for (final key in stepKeys) {
        final stepTurn = _stepTurn(key);
        if (stepTurn == null ||
            stepTurn < baselineTurn ||
            stepTurn >= source.turn) {
          continue;
        }
        final output = tree.get(SessionPath.parse('body/steps/$key/output'));
        if (output is! List<Object?>) continue;
        for (final item in output) {
          final linked = _linkedCall(tree, item);
          if (linked == null) continue;
          if (linked.tool == 'bash' || linked.tool == 'agent') {
            processActivity = true;
          }
          if (linked.hooks) processActivity = true;
          if ((linked.tool == 'edit' || linked.tool == 'write') &&
              seenMutationCalls.add(linked.callKey)) {
            observeMutation(linked);
          }
        }
      }

      for (final linked in _mutations.quiescedBetween(
        baselineTurn,
        source.turn,
      )) {
        if (linked.stepTurn >= source.turn ||
            seenMutationCalls.contains(linked.callKey)) {
          continue;
        }
        final stepOutput = tree.get(
          SessionPath.parse(
            'body/steps/s-${linked.stepTurn.toString().padLeft(8, '0')}/output',
          ),
        );
        if (!_indexedLinkIsPresent(stepOutput, linked)) continue;
        final call = _indexedCall(tree, linked);
        if (call == null || !seenMutationCalls.add(linked.callKey)) continue;
        observeMutation(call);
      }
    }

    final liveByCall = <String, String>{};
    for (final target in _mutations.liveTargets) {
      final key = target.callPath.startsWith('body/calls/')
          ? target.callPath.substring('body/calls/'.length)
          : '';
      if (key.isNotEmpty) liveByCall[key] = target.target;
      targets.add(target.target);
      pathFacts.putIfAbsent(target.target, _MutationPathFacts.new).open = true;
    }
    final activeKeys = _mutations.activeCallKeys;
    for (final key in _mutations.openCallKeys) {
      final target =
          liveByCall[key] ?? _stringAt(tree, 'body/calls/$key/target');
      if (target == null || target.isEmpty) {
        if (activeKeys.contains(key)) processActivity = true;
        continue;
      }
      targets.add(target);
      pathFacts.putIfAbsent(target, _MutationPathFacts.new).open = true;
    }
    for (final key in activeKeys) {
      final target =
          liveByCall[key] ?? _stringAt(tree, 'body/calls/$key/target');
      if (target == null || target.isEmpty) {
        // An unfinished edit/write with no durable or published target may
        // still mutate an arbitrary path while collection is in flight.
        processActivity = true;
      } else {
        targets.add(target);
        pathFacts.putIfAbsent(target, _MutationPathFacts.new).open = true;
      }
    }

    final session = _stringAt(tree, 'meta/session');
    final orphaned = tree.get(SessionPath.parse('meta/orphanedMutations'));
    var maskAll = false;
    final vcsMeta = tree.get(SessionPath.parse('meta/vcs'));
    if (vcsMeta is Map<String, Object?>) {
      if (vcsMeta['foreignOverflow'] == true) maskAll = true;
      final floor = vcsMeta['attributionFloor'];
      if (floor != null &&
          (floor is! int ||
              floor < 0 ||
              baseline == null ||
              floor > baseline.seq)) {
        maskAll = true;
      }
    }
    if (orphaned is Map<String, Object?>) {
      for (final value in orphaned.values) {
        if (value is! Map<String, Object?>) {
          maskAll = true;
          continue;
        }
        final target = value['target'];
        final owner = value['session'];
        if (target is! String || target.isEmpty || owner is! String) {
          maskAll = true;
          continue;
        }
        // Retained finished ancestor records share the inherited sequence horizon.
        final foreign = value['foreign'] == true || session == null;
        final finished = value['finishedSeq'];
        final applies =
            foreign ||
            finished == null ||
            finished is! int ||
            baseline == null ||
            finished > baseline.seq;
        if (applies) {
          targets.add(target);
          pathFacts.putIfAbsent(target, _MutationPathFacts.new).orphan = true;
        }
      }
    } else if (orphaned != null) {
      maskAll = true;
    }

    final effects = <String, String>{};
    if (!maskAll) {
      for (final MapEntry(:key, :value) in pathFacts.entries) {
        final effect = value.latestEffect;
        if (effect == null ||
            value.missingEffectSequence ||
            value.open ||
            value.orphan ||
            value.unresolvedBoundaries.any(
              (boundary) => boundary == null || effect.sequence <= boundary,
            )) {
          continue;
        }
        effects[key] = effect.hash;
      }
    }
    return _Attribution(
      targets: Set.unmodifiable(targets),
      pathFacts: Map.unmodifiable(pathFacts),
      effects: Map.unmodifiable(effects),
      processActivity: processActivity,
      maskAll: maskAll,
    );
  }

  SensoriumChangeBy _classify(
    VcsDelta delta,
    _Attribution attribution,
    Map<String, VcsVerification> verification,
  ) {
    if (!delta.pathIsUtf8) return SensoriumChangeBy.unknown;
    final path = delta.path;
    if (attribution.targets.any(
      (target) => target != path && target.toLowerCase() == path.toLowerCase(),
    )) {
      return SensoriumChangeBy.unknown;
    }
    if (attribution.maskAll) return SensoriumChangeBy.unknown;
    final facts = attribution.pathFacts[path];
    if (facts?.open == true || facts?.orphan == true) {
      return SensoriumChangeBy.unknown;
    }
    if (facts != null && _provesAgent(facts, verification[path])) {
      return SensoriumChangeBy.agent;
    }
    if (attribution.processActivity || facts?.hasMutation == true) {
      return SensoriumChangeBy.unknown;
    }
    return SensoriumChangeBy.user;
  }

  bool _provesAgent(_MutationPathFacts facts, VcsVerification? verification) {
    final effect = facts.latestEffect;
    if (effect == null || facts.missingEffectSequence || verification == null) {
      return false;
    }
    for (final boundary in facts.unresolvedBoundaries) {
      if (boundary == null || effect.sequence <= boundary) return false;
    }
    final before = verification.before;
    final after = verification.after;
    return before != null &&
        after != null &&
        before.sha256 == effect.hash &&
        after.sha256 == effect.hash &&
        before.size == after.size &&
        before.modifiedMicros == after.modifiedMicros;
  }

  _CallFacts? _linkedCall(SessionTree tree, Object? item) {
    if (item is! Map<String, Object?> ||
        item['type'] != 'call' ||
        item['call'] is! String ||
        item['callId'] is! String ||
        item['name'] is! String ||
        item['arguments'] is! String) {
      return null;
    }
    final key = item['call']! as String;
    final callId = item['callId']! as String;
    final tool = item['name']! as String;
    final arguments = item['arguments']! as String;
    if (key != _callKey(callId)) return null;
    final path = 'body/calls/$key';
    if (_stringAt(tree, '$path/callId') != callId ||
        _stringAt(tree, '$path/tool') != tool ||
        !_argumentsMatch(
          arguments,
          tree.get(SessionPath.parse('$path/input')),
        )) {
      return null;
    }
    return _CallFacts(
      callKey: key,
      tool: tool,
      target: _stringAt(tree, '$path/target'),
      targetAfterSeq: tree.get(SessionPath.parse('$path/targetAfterSeq')),
      effect: tree.get(SessionPath.parse('$path/effect')),
      hooks: _hasHooks(tree, '$path/hooks'),
    );
  }

  bool _indexedLinkIsPresent(Object? output, MutationIntervalCall link) {
    if (output is! List<Object?>) return false;
    return mutationOutputLinkMatches(
      {'output': output},
      callKey: link.callKey,
      callId: link.callId,
      tool: link.tool,
      argumentsHash: link.argumentsHash,
    );
  }

  _CallFacts? _indexedCall(SessionTree tree, MutationIntervalCall link) {
    final path = 'body/calls/${link.callKey}';
    final callId = _stringAt(tree, '$path/callId');
    final tool = _stringAt(tree, '$path/tool');
    final attempt = _stringAt(tree, '$path/attempt');
    final target = _stringAt(tree, '$path/target');
    final quiesced = tree.get(SessionPath.parse('$path/quiesced'));
    final quiescedTurn = tree.get(SessionPath.parse('$path/quiescedTurn'));
    if (callId != link.callId ||
        tool != link.tool ||
        attempt != link.attempt ||
        target != link.target ||
        quiesced != true ||
        quiescedTurn != link.quiescedTurn) {
      return null;
    }
    final output = tree.get(
      SessionPath.parse(
        'body/steps/s-${link.stepTurn.toString().padLeft(8, '0')}/output',
      ),
    );
    final arguments = _linkedArguments(output, link);
    if (arguments == null ||
        !_argumentsMatch(
          arguments,
          tree.get(SessionPath.parse('$path/input')),
        )) {
      return null;
    }
    return _CallFacts(
      callKey: link.callKey,
      tool: link.tool,
      target: target,
      targetAfterSeq: tree.get(SessionPath.parse('$path/targetAfterSeq')),
      effect: tree.get(SessionPath.parse('$path/effect')),
      hooks: _hasHooks(tree, '$path/hooks'),
    );
  }

  String? _linkedArguments(Object? output, MutationIntervalCall link) {
    if (output is! List<Object?>) return null;
    for (final item in output) {
      if (item is Map<String, Object?> &&
          item['type'] == 'call' &&
          item['call'] == link.callKey &&
          item['callId'] == link.callId &&
          item['name'] == link.tool &&
          item['arguments'] is String &&
          mutationArgumentsDigest(item['arguments']! as String) ==
              link.argumentsHash) {
        return item['arguments']! as String;
      }
    }
    return null;
  }
}

/// The synchronous policy boundary passed to the request builder.
final class WorkspacePerceptionCapture {
  const WorkspacePerceptionCapture._(this._owner, this.source, this._frozen);

  final WorkspacePerception _owner;

  /// Writer source whose snapshot is frozen by this capture.
  final SensoriumSource source;
  final _FrozenWorkspace _frozen;

  /// Awaits one bounded observation using only the facts frozen at capture.
  Future<WorkspacePerceptionFrame> collect() =>
      _owner._collect(source, _frozen);
}

/// Typed observation plus the exact bounded metadata admitted on its step.
final class WorkspacePerceptionFrame {
  /// Creates a typed frame and freezes its bounded persisted metadata.
  WorkspacePerceptionFrame({
    required this.source,
    required this.vcs,
    required this.changes,
    required Set<SensoriumNotice> notices,
    required Map<String, Object?> metadata,
    required this.baselineSequence,
  }) : notices = Set.unmodifiable(notices),
       metadata = _immutableMetadata(metadata);

  /// Writer turn and time used to collect this frame.
  final SensoriumSource source;

  /// Current typed VCS observation.
  final SensoriumObservation<SensoriumVcs> vcs;

  /// Changes since the admitted baseline, when available.
  final SensoriumObservation<SensoriumChanges> changes;

  /// Notices for this observation; never carried forward from an older frame.
  final Set<SensoriumNotice> notices;

  /// Bounded persisted metadata written on the source step.
  final Map<String, Object?> metadata;

  /// Sequence watermark captured with the VCS baseline, if available.
  final int? baselineSequence;
}

final class _FrozenWorkspace {
  const _FrozenWorkspace({
    required this.admitted,
    required this.baseline,
    required this.baselineLost,
    required this.previous,
    required this.currentJobsLive,
    required this.attribution,
  });

  final _StoredPerception? admitted;
  final VcsBaseline? baseline;
  final bool baselineLost;
  final VcsCollection? previous;
  final bool currentJobsLive;
  final _Attribution attribution;
}

final class _Lookup {
  const _Lookup(this.admitted, {required this.lost});

  final _StoredPerception? admitted;
  final bool lost;
}

final class _StoredPerception {
  const _StoredPerception({
    required this.raw,
    required this.state,
    required this.reason,
    required this.observedTurn,
    required this.observedTime,
    required this.value,
    required this.baseline,
    required this.lost,
  });

  final Map<String, Object?> raw;
  final String state;
  final SensoriumReason? reason;
  final int? observedTurn;
  final DateTime? observedTime;
  final Map<String, Object?>? value;
  final VcsBaseline? baseline;
  final bool lost;
}

final class _Attribution {
  const _Attribution({
    required this.targets,
    required this.pathFacts,
    required this.effects,
    required this.processActivity,
    required this.maskAll,
  });

  final Set<String> targets;
  final Map<String, _MutationPathFacts> pathFacts;
  final Map<String, String> effects;
  final bool processActivity;
  final bool maskAll;
}

final class _MutationPathFacts {
  bool hasMutation = false;
  bool open = false;
  bool orphan = false;
  bool missingEffectSequence = false;
  _Effect? latestEffect;
  final List<int?> unresolvedBoundaries = [];
}

final class _Effect {
  const _Effect(this.hash, this.sequence);

  final String hash;
  final int sequence;
}

final class _CallFacts {
  const _CallFacts({
    required this.callKey,
    required this.tool,
    required this.target,
    required this.targetAfterSeq,
    required this.effect,
    required this.hooks,
  });

  final String callKey;
  final String tool;
  final String? target;
  final Object? targetAfterSeq;
  final Object? effect;
  final bool hooks;
}

_StoredPerception? _parseStored(Map<String, Object?> raw) {
  final state = raw['state'];
  if (state is! String) return null;
  final observed = raw['observed'];
  final observedMap = observed is Map<String, Object?> ? observed : null;
  final observedTurn = observedMap?['turn'];
  final observedTime = observedMap?['time'];
  final turn = observedTurn is int && observedTurn >= 0 ? observedTurn : null;
  final time = observedTime is String ? DateTime.tryParse(observedTime) : null;
  final value = raw['value'];
  final valueMap = value is Map<String, Object?> ? value : null;
  final baselineRaw = raw['baseline'];
  VcsBaseline? baseline;
  if (baselineRaw is Map<String, Object?> && turn != null && time != null) {
    final backend = baselineRaw['backend'];
    final id = baselineRaw['id'];
    final seq = baselineRaw['seq'];
    final jobsLive = baselineRaw['jobsLive'];
    if (backend is String &&
        id is String &&
        seq is int &&
        seq >= 0 &&
        jobsLive is bool) {
      baseline = VcsBaseline(
        backend: backend,
        id: id,
        turn: turn,
        time: time,
        seq: seq,
        jobsLive: jobsLive,
      );
    }
  }
  final reason = _parseReason(raw['reason']);
  final lost =
      reason == SensoriumReason.baselineLost ||
      ((state == 'available' || state == 'stale') && baseline == null);
  return _StoredPerception(
    raw: raw,
    state: state,
    reason: reason,
    observedTurn: turn,
    observedTime: time,
    value: valueMap,
    baseline: baseline,
    lost: lost,
  );
}

SensoriumVcs? _decodeStoredVcs(Map<String, Object?>? value) {
  if (value == null) return null;
  final branch = value['branch'];
  final paths = value['paths'];
  if (branch is! String || paths is! List<Object?>) return null;
  return SensoriumVcs(
    branch: branch,
    paths: List<String>.unmodifiable(paths.whereType<String>()),
    backend: value['backend'] is String ? value['backend']! as String : 'git',
    change: value['change'] is String ? value['change']! as String : null,
    description: value['description'] is String
        ? value['description']! as String
        : null,
    parent: value['parent'] is String ? value['parent']! as String : null,
    operation: value['operation'] is String
        ? value['operation']! as String
        : null,
    modified: value['modified'] is int ? value['modified']! as int : 0,
    added: value['added'] is int ? value['added']! as int : 0,
    deleted: value['deleted'] is int ? value['deleted']! as int : 0,
    conflicts: List<String>.unmodifiable(
      (value['conflicts'] is List<Object?>
              ? value['conflicts']! as List<Object?>
              : const [])
          .whereType<String>(),
    ),
    partial: value['partial'] == true,
    totalPaths: value['totalPaths'] is int ? value['totalPaths']! as int : null,
    conflictCount: value['conflictCount'] is int
        ? value['conflictCount']! as int
        : null,
  );
}

Map<String, Object?> _vcsValue(SensoriumVcs vcs, Map<String, Object?> changes) {
  var partial = vcs.partial;
  final paths = <String>[];
  var pathCount = 0;
  for (final path in vcs.paths) {
    pathCount++;
    if (paths.length == _displayRowLimit) continue;
    final clipped = _clipJsonString(path, 64);
    if (clipped != path) partial = true;
    paths.add(clipped);
  }
  final conflicts = <String>[];
  var conflictTotal = 0;
  for (final path in vcs.conflicts) {
    conflictTotal++;
    if (conflicts.length == _displayRowLimit) continue;
    final clipped = _clipJsonString(path, 64);
    if (clipped != path) partial = true;
    conflicts.add(clipped);
  }
  final totalPaths = vcs.totalPaths ?? pathCount;
  final conflictCount = vcs.conflictCount ?? conflictTotal;
  if (totalPaths > paths.length || conflictCount > conflicts.length) {
    partial = true;
  }
  return {
    'backend': _clipJsonString(vcs.backend, 64),
    'branch': _clipJsonString(vcs.branch, 128),
    if (vcs.change != null) 'change': _clipJsonString(vcs.change!, 128),
    if (vcs.description != null)
      'description': _clipJsonString(vcs.description!, 160),
    if (vcs.parent != null) 'parent': _clipJsonString(vcs.parent!, 96),
    if (vcs.operation != null) 'operation': _clipJsonString(vcs.operation!, 96),
    'modified': vcs.modified,
    'added': vcs.added,
    'deleted': vcs.deleted,
    'conflicts': conflicts,
    'conflictCount': conflictCount,
    'paths': paths,
    'totalPaths': totalPaths,
    'partial': partial,
    'changes': changes,
  };
}

Map<String, Object?> _baselineJson(VcsBaseline baseline) => {
  'backend': baseline.backend,
  'id': baseline.id,
  'seq': baseline.seq,
  'jobsLive': baseline.jobsLive,
};

bool _validBaseline(VcsBaseline baseline) =>
    baseline.backend.isNotEmpty &&
    baseline.id.isNotEmpty &&
    baseline.turn >= 0 &&
    baseline.seq >= 0;

Map<String, Object?> _unavailableChanges(SensoriumReason reason) => {
  'state': 'unavailable',
  'reason': _reasonLabel(reason),
  'rows': <Object?>[],
  'totalPaths': 0,
  'partial': false,
};

SensoriumVcs _decodeVcs(Map<String, Object?> value) => _decodeStoredVcs(value)!;

SensoriumChanges _decodeChanges(Map<String, Object?> value) {
  final rowsRaw = value['rows'];
  final rows = <SensoriumChange>[];
  if (rowsRaw is List<Object?>) {
    for (final row in rowsRaw) {
      if (row is! Map<String, Object?> || row['path'] is! String) continue;
      final by = switch (row['by']) {
        'agent' => SensoriumChangeBy.agent,
        'user' => SensoriumChangeBy.user,
        _ => SensoriumChangeBy.unknown,
      };
      rows.add(
        SensoriumChange(
          row['path']! as String,
          added: row['added'] is int ? row['added']! as int : 0,
          removed: row['removed'] is int ? row['removed']! as int : 0,
          by: by,
          binary: row['binary'] == true,
        ),
      );
    }
  }
  return SensoriumChanges(
    sinceTurn: value['sinceTurn'] is int ? value['sinceTurn']! as int : 0,
    rows: List.unmodifiable(rows),
    totalPaths: value['totalPaths'] is int ? value['totalPaths']! as int : null,
    partial: value['partial'] == true,
  );
}

void _fitFreshMetadata(Map<String, Object?> metadata) {
  while (_encodedLength(metadata) > _metadataByteLimit) {
    final value = metadata['value']! as Map<String, Object?>;
    final changes = value['changes']! as Map<String, Object?>;
    final rows = changes['rows']! as List<Object?>;
    final paths = value['paths']! as List<Object?>;
    final conflicts = value['conflicts']! as List<Object?>;
    if (rows.isNotEmpty) {
      rows.removeLast();
      changes['partial'] = true;
      continue;
    }
    if (paths.isNotEmpty) {
      paths.removeLast();
      value['partial'] = true;
      continue;
    }
    if (conflicts.isNotEmpty) {
      conflicts.removeLast();
      value['partial'] = true;
      continue;
    }
    final shrink = _longestMetadataString(value);
    if (shrink == null) {
      throw StateError('Workspace perception metadata exceeds 4 KiB.');
    }
    final current = shrink.$1;
    final nextLimit = (_jsonStringBodyBytes(current) ~/ 2).clamp(0, 96).toInt();
    final next = _clipJsonString(current, nextLimit);
    if (next == current) {
      throw StateError('Workspace perception metadata exceeds 4 KiB.');
    }
    shrink.$2(next);
    value['partial'] = true;
  }
}

(String, void Function(String))? _longestMetadataString(
  Map<String, Object?> value,
) {
  String? longest;
  void Function(String)? replace;
  void consider(String? text, void Function(String) setter) {
    if (text == null) return;
    if (longest == null ||
        _jsonStringBodyBytes(text) > _jsonStringBodyBytes(longest!)) {
      longest = text;
      replace = setter;
    }
  }

  for (final key in [
    'branch',
    'change',
    'description',
    'parent',
    'operation',
  ]) {
    final text = value[key];
    if (text is String) {
      consider(text, (next) => value[key] = next);
    }
  }
  for (final key in ['paths', 'conflicts']) {
    final items = value[key];
    if (items is! List<Object?>) continue;
    for (var index = 0; index < items.length; index++) {
      final text = items[index];
      if (text is String) {
        final slot = index;
        consider(text, (next) => items[slot] = next);
      }
    }
  }
  final changes = value['changes'];
  if (changes is Map<String, Object?> && changes['rows'] is List<Object?>) {
    final rows = changes['rows']! as List<Object?>;
    for (var index = 0; index < rows.length; index++) {
      final row = rows[index];
      if (row is Map<String, Object?> && row['path'] is String) {
        final slot = index;
        consider(row['path']! as String, (next) => row['path'] = next);
      }
    }
  }
  if (longest == null || replace == null) return null;
  return (longest!, replace!);
}

int _encodedLength(Object? value) => utf8.encode(jsonEncode(value)).length;

String _clipJsonString(String value, int maxBodyBytes) {
  if (_jsonStringBodyBytes(value) <= maxBodyBytes) return value;
  if (maxBodyBytes <= 3) return maxBodyBytes == 3 ? '…' : '';
  final output = StringBuffer();
  var used = 0;
  for (final rune in value.runes) {
    final bytes = _escapedRuneBytes(rune);
    if (used + bytes + 3 > maxBodyBytes) break;
    output.writeCharCode(rune);
    used += bytes;
  }
  return '$output…';
}

int _jsonStringBodyBytes(String value) {
  var bytes = 0;
  for (final rune in value.runes) {
    bytes += _escapedRuneBytes(rune);
  }
  return bytes;
}

int _escapedRuneBytes(int rune) {
  if (rune == 0x22 || rune == 0x5c) return 2;
  if (rune < 0x20 || rune == 0x2028 || rune == 0x2029) return 6;
  if (rune <= 0x7f) return 1;
  if (rune <= 0x7ff) return 2;
  if (rune <= 0xffff) return 3;
  return 4;
}

Map<String, Object?> _immutableMetadata(Map<String, Object?> value) =>
    _freezeJsonMap(value);

Map<String, Object?> _freezeJsonMap(Map<String, Object?> map) =>
    Map<String, Object?>.unmodifiable({
      for (final MapEntry(:key, :value) in map.entries)
        key: _freezeJsonValue(value),
    });

Object? _freezeJsonValue(Object? value) => switch (value) {
  Map<String, Object?> map => _freezeJsonMap(map),
  List<Object?> list => List<Object?>.unmodifiable(list.map(_freezeJsonValue)),
  _ => value,
};

SensoriumReason _failureReason(VcsCollection collection) {
  if (collection.deadlineExpired) return SensoriumReason.timedOut;
  // Repository stderr is diagnostic data, never an availability discriminator.
  return switch (collection.observation) {
    SensoriumUnavailable<SensoriumVcs>(:final reason) => reason,
    SensoriumStale<SensoriumVcs>(:final reason) => reason,
    _ => SensoriumReason.failed,
  };
}

bool _isFailureNotice(SensoriumReason reason) => switch (reason) {
  SensoriumReason.failed ||
  SensoriumReason.jjNotFound ||
  SensoriumReason.gitNotFound ||
  SensoriumReason.cleanupPending => true,
  _ => false,
};

String _reasonLabel(SensoriumReason reason) => switch (reason) {
  SensoriumReason.notCollected => 'not collected',
  SensoriumReason.failed => 'failed',
  SensoriumReason.timedOut => 'timeout',
  SensoriumReason.noRepository => 'no repository',
  SensoriumReason.disabled => 'disabled',
  SensoriumReason.jjNotFound => 'jj not found',
  SensoriumReason.gitNotFound => 'git not found',
  SensoriumReason.noBaseline => 'no baseline',
  SensoriumReason.baselineLost => 'baseline lost',
  SensoriumReason.cleanupPending => 'cleanup pending',
};

SensoriumReason? _parseReason(Object? raw) => switch (raw) {
  'not collected' || 'notCollected' => SensoriumReason.notCollected,
  'failed' => SensoriumReason.failed,
  'timeout' || 'timedOut' => SensoriumReason.timedOut,
  'no repository' || 'noRepository' => SensoriumReason.noRepository,
  'disabled' => SensoriumReason.disabled,
  'jj not found' || 'jjNotFound' => SensoriumReason.jjNotFound,
  'git not found' || 'gitNotFound' => SensoriumReason.gitNotFound,
  'no baseline' || 'noBaseline' => SensoriumReason.noBaseline,
  'baseline lost' || 'baselineLost' => SensoriumReason.baselineLost,
  'cleanup pending' || 'cleanupPending' => SensoriumReason.cleanupPending,
  _ => null,
};

String? _stringAt(SessionTree tree, String path) {
  final value = tree.get(SessionPath.parse(path));
  return value is String ? value : null;
}

bool _hasHooks(SessionTree tree, String path) {
  final hooks = tree.get(SessionPath.parse(path));
  return hooks is List<Object?> && hooks.isNotEmpty;
}

bool _jobsLive(SessionTree tree) {
  for (final key in tree.childKeys(SessionPath.parse('jobs'))) {
    final state = tree.get(SessionPath.parse('jobs/$key/state'));
    if (state is! String || !_terminalJobStates.contains(state)) return true;
  }
  return false;
}

int? _stepTurn(String key) {
  if (!RegExp(r'^s-\d{8,}$').hasMatch(key)) return null;
  return int.tryParse(key.substring(2));
}

String _callKey(String callId) =>
    'c-${sha256.convert(utf8.encode(callId)).toString().substring(0, 12)}';

bool _argumentsMatch(String raw, Object? input) {
  try {
    return _jsonEqual(jsonDecode(raw), input);
  } on FormatException {
    return input == raw;
  }
}

bool _jsonEqual(Object? left, Object? right) {
  if (left is List<Object?> && right is List<Object?>) {
    if (left.length != right.length) return false;
    for (var index = 0; index < left.length; index++) {
      if (!_jsonEqual(left[index], right[index])) return false;
    }
    return true;
  }
  if (left is Map<String, Object?> && right is Map<String, Object?>) {
    if (left.length != right.length) return false;
    for (final MapEntry(:key, :value) in left.entries) {
      if (!right.containsKey(key) || !_jsonEqual(value, right[key])) {
        return false;
      }
    }
    return true;
  }
  return left == right;
}
