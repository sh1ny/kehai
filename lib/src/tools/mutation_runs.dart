import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../session/mutations.dart';

/// Computes the SHA-256 digest used to validate a linked tool call's arguments.
String mutationArgumentsDigest(String argumentsJson) =>
    sha256.convert(utf8.encode(argumentsJson)).toString();

String _mutationCallKey(String callId) =>
    'c-${sha256.convert(utf8.encode(callId)).toString().substring(0, 12)}';

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
  final Map<String, MutationIntervalCall> _indexedCalls = {};
  final Map<int, Set<String>> _attemptsByQuiescedTurn = {};
  final List<int> _quiescedTurns = [];

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

  /// The retained linked mutation calls quiesced in [firstTurn] through
  /// [lastTurn], both inclusive.
  Iterable<MutationIntervalCall> quiescedBetween(
    int firstTurn,
    int lastTurn,
  ) sync* {
    if (lastTurn < firstTurn) return;
    var low = 0;
    var high = _quiescedTurns.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (_quiescedTurns[middle] < firstTurn) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    for (var index = low; index < _quiescedTurns.length; index++) {
      final turn = _quiescedTurns[index];
      if (turn > lastTurn) return;
      for (final attempt in _attemptsByQuiescedTurn[turn]!) {
        yield _indexedCalls[attempt]!;
      }
    }
  }

  /// Validates the frozen finish and its exact surviving call-output link.
  MutationIntervalCall? finishedCall(
    MutationRun run, {
    required Object? callNode,
    required Object? stepNode,
  }) {
    final target = run._target;
    final stepTurn = run.stepTurn;
    final callId = run.callId;
    final tool = run.tool;
    final argumentsHash = run.argumentsHash;
    if (!isActive(run) ||
        target == null ||
        stepTurn == null ||
        callId == null ||
        tool == null ||
        argumentsHash == null ||
        callNode is! Map<String, Object?>) {
      return null;
    }
    final quiescedTurn = callNode['quiescedTurn'];
    if (callNode['attempt'] != run.attempt ||
        callNode['callId'] != callId ||
        callNode['tool'] != tool ||
        callNode['target'] != target.target ||
        callNode['quiesced'] != true ||
        quiescedTurn is! int ||
        quiescedTurn < 0) {
      return null;
    }
    final arguments = _mutationLinkedArguments(
      stepNode,
      callKey: run.callKey,
      callId: callId,
      tool: tool,
      argumentsHash: argumentsHash,
    );
    if (arguments == null || !_argumentsMatch(arguments, callNode['input'])) {
      return null;
    }
    return MutationIntervalCall(
      callKey: run.callKey,
      attempt: run.attempt,
      target: target.target,
      callId: callId,
      tool: tool,
      argumentsHash: argumentsHash,
      stepTurn: stepTurn,
      quiescedTurn: quiescedTurn,
    );
  }

  /// Reserves a slot, or returns null when all [maxUnfinishedMutationRuns]
  /// slots are occupied.
  MutationRun? reserve({
    required String callKey,
    required String attempt,
    required String callPath,
    String? callId,
    String? tool,
    String? argumentsJson,
    int? stepTurn,
  }) {
    if (stepTurn != null &&
        (stepTurn < 0 ||
            callId == null ||
            callKey != _mutationCallKey(callId) ||
            (tool != 'edit' && tool != 'write') ||
            argumentsJson == null)) {
      throw ArgumentError(
        'Linked mutation origins require complete call data.',
      );
    }
    if (_runs.length >= maxUnfinishedMutationRuns) return null;
    if (_runs.containsKey(attempt)) {
      throw StateError('Mutation attempt is already registered.');
    }
    final run = MutationRun._(
      callKey: callKey,
      attempt: attempt,
      callPath: callPath,
      session: _session,
      callId: callId,
      tool: tool,
      argumentsHash: argumentsJson == null
          ? null
          : mutationArgumentsDigest(argumentsJson),
      stepTurn: stepTurn,
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
  ///
  /// [finishedCall] was validated from the same committed tree read and is
  /// indexed before the live registry entry is removed.
  void retire(
    MutationRun run, {
    required bool currentCallOpen,
    MutationIntervalCall? finishedCall,
  }) {
    if (!isActive(run) || run._target == null) {
      throw StateError('Only an active targeted mutation can be retired.');
    }
    _removeIndexedAttempt(run.attempt);
    if (finishedCall != null &&
        finishedCall.attempt == run.attempt &&
        finishedCall.callKey == run.callKey &&
        finishedCall.target == run._target!.target) {
      _indexCall(finishedCall);
    }
    _runs.remove(run.attempt);
    if (currentCallOpen) {
      _treeOpenCallKeys.add(run.callKey);
    } else {
      _treeOpenCallKeys.remove(run.callKey);
    }
  }

  /// Rebuilds tree-derived open calls and the quiescence index after resume or
  /// rewind.
  void rebuildOpenCallKeys(Map<String, Object?> tree) {
    _treeOpenCallKeys = openMutationCallKeys(tree);
    _indexedCalls.clear();
    _attemptsByQuiescedTurn.clear();
    _quiescedTurns.clear();

    final body = tree['body'];
    if (body is! Map<String, Object?>) return;
    final calls = body['calls'];
    final steps = body['steps'];
    if (calls is! Map<String, Object?> || steps is! Map<String, Object?>) {
      return;
    }
    final orderedSteps = <(int, Map<String, Object?>)>[];
    for (final MapEntry(:key, :value) in steps.entries) {
      final turn = _stepTurn(key);
      if (turn != null && value is Map<String, Object?>) {
        orderedSteps.add((turn, value));
      }
    }
    orderedSteps.sort((left, right) => left.$1.compareTo(right.$1));

    final links = <String, List<_StepCallLink>>{};
    for (final (turn, step) in orderedSteps) {
      final output = step['output'];
      if (output is! List<Object?>) continue;
      for (final entry in output) {
        if (entry is! Map<String, Object?> ||
            entry['type'] != 'call' ||
            entry['call'] is! String ||
            entry['callId'] is! String ||
            entry['name'] is! String ||
            entry['arguments'] is! String) {
          continue;
        }
        final key = entry['call']! as String;
        final callId = entry['callId']! as String;
        if (key != _mutationCallKey(callId)) continue;
        links
            .putIfAbsent(key, () => [])
            .add(
              _StepCallLink(
                turn: turn,
                callId: callId,
                tool: entry['name']! as String,
                argumentsJson: entry['arguments']! as String,
              ),
            );
      }
    }

    for (final MapEntry(:key, :value) in calls.entries) {
      if (value is! Map<String, Object?> ||
          (value['tool'] != 'edit' && value['tool'] != 'write') ||
          value['quiesced'] != true ||
          value['quiescedTurn'] is! int ||
          value['attempt'] is! String ||
          value['target'] is! String ||
          value['callId'] is! String) {
        continue;
      }
      final tool = value['tool']! as String;
      final callId = value['callId']! as String;
      _StepCallLink? link;
      for (final candidate in links[key] ?? const <_StepCallLink>[]) {
        if (candidate.callId == callId &&
            candidate.tool == tool &&
            _argumentsMatch(candidate.argumentsJson, value['input'])) {
          link = candidate;
          break;
        }
      }
      if (link == null) continue;
      final quiescedTurn = value['quiescedTurn']! as int;
      if (quiescedTurn < 0) continue;
      _indexCall(
        MutationIntervalCall(
          callKey: key,
          attempt: value['attempt']! as String,
          target: value['target']! as String,
          callId: callId,
          tool: tool,
          argumentsHash: mutationArgumentsDigest(link.argumentsJson),
          stepTurn: link.turn,
          quiescedTurn: quiescedTurn,
        ),
      );
    }
  }

  void _indexCall(MutationIntervalCall call) {
    _removeIndexedAttempt(call.attempt);
    var attempts = _attemptsByQuiescedTurn[call.quiescedTurn];
    if (attempts == null) {
      attempts = {};
      _attemptsByQuiescedTurn[call.quiescedTurn] = attempts;
      var low = 0;
      var high = _quiescedTurns.length;
      while (low < high) {
        final middle = (low + high) >> 1;
        if (_quiescedTurns[middle] < call.quiescedTurn) {
          low = middle + 1;
        } else {
          high = middle;
        }
      }
      _quiescedTurns.insert(low, call.quiescedTurn);
    }
    attempts.add(call.attempt);
    _indexedCalls[call.attempt] = call;
  }

  void _removeIndexedAttempt(String attempt) {
    final previous = _indexedCalls.remove(attempt);
    if (previous == null) return;
    final attempts = _attemptsByQuiescedTurn[previous.quiescedTurn]!;
    attempts.remove(attempt);
    if (attempts.isEmpty) {
      _attemptsByQuiescedTurn.remove(previous.quiescedTurn);
      _quiescedTurns.remove(previous.quiescedTurn);
    }
  }
}

/// One derived linked mutation call indexed by its durable quiescence turn.
final class MutationIntervalCall {
  /// Creates a frozen linked mutation call record.
  const MutationIntervalCall({
    required this.callKey,
    required this.attempt,
    required this.target,
    required this.callId,
    required this.tool,
    required this.argumentsHash,
    required this.stepTurn,
    required this.quiescedTurn,
  });

  /// Durable call key shared by the call node and step output.
  final String callKey;

  /// Attempt identifier whose finish produced this record.
  final String attempt;

  /// Published mutation target.
  final String target;

  /// Original call identifier from the model output.
  final String callId;

  /// Mutation tool name.
  final String tool;

  /// Digest of the exact linked arguments string.
  final String argumentsHash;

  /// Existing step turn containing the linked call output.
  final int stepTurn;

  /// Writer turn at which the call became quiescent.
  final int quiescedTurn;
}

final class _StepCallLink {
  const _StepCallLink({
    required this.turn,
    required this.callId,
    required this.tool,
    required this.argumentsJson,
  });

  final int turn;
  final String callId;
  final String tool;
  final String argumentsJson;
}

/// Whether [stepNode] carries the exact linked tool output entry.
bool mutationOutputLinkMatches(
  Object? stepNode, {
  required String callKey,
  required String callId,
  required String tool,
  required String argumentsHash,
}) =>
    _mutationLinkedArguments(
      stepNode,
      callKey: callKey,
      callId: callId,
      tool: tool,
      argumentsHash: argumentsHash,
    ) !=
    null;

String? _mutationLinkedArguments(
  Object? stepNode, {
  required String callKey,
  required String callId,
  required String tool,
  required String argumentsHash,
}) {
  if (stepNode is! Map<String, Object?> ||
      stepNode['output'] is! List<Object?>) {
    return null;
  }
  final output = stepNode['output']! as List<Object?>;
  for (final entry in output) {
    if (entry is Map<String, Object?> &&
        entry['type'] == 'call' &&
        entry['call'] == callKey &&
        entry['callId'] == callId &&
        entry['name'] == tool &&
        entry['arguments'] is String) {
      final arguments = entry['arguments']! as String;
      if (mutationArgumentsDigest(arguments) == argumentsHash) {
        return arguments;
      }
    }
  }
  return null;
}

int? _stepTurn(String key) {
  if (!RegExp(r'^s-\d{8,}$').hasMatch(key)) return null;
  return int.tryParse(key.substring(2));
}

bool _argumentsMatch(String argumentsJson, Object? input) {
  try {
    return _jsonEqual(jsonDecode(argumentsJson), input);
  } on FormatException {
    return input == argumentsJson;
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

/// One reserved mutation attempt held until it is safely released or retired.
final class MutationRun {
  MutationRun._({
    required this.callKey,
    required this.attempt,
    required this.callPath,
    required this.session,
    required this.callId,
    required this.tool,
    required this.argumentsHash,
    required this.stepTurn,
  });

  /// The call key within the session tree.
  final String callKey;

  /// The original attempt identifier, also used as the run id.
  final String attempt;

  /// The complete session path of the call node.
  final String callPath;

  /// The owning session id.
  final String session;

  /// The provider call id, tool, and argument digest when a link was supplied.
  final String? callId;
  final String? tool;
  final String? argumentsHash;

  /// The validated step holding the call-output link, if linked.
  final int? stepTurn;

  MutationTarget? _target;
}
