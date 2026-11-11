/// Journal-derived native capability evidence and calibration admission.
library;

import 'dart:convert';

import '../config/user_config.dart';
import '../session/path.dart';
import '../session/tree.dart';

/// Fixed scalar reasons safe for status and model-visible recovery notices.
const Set<String> compactionNoticeReasons = {
  'no compaction item at threshold',
  'estimated input at threshold without compaction',
  'context_management rejected',
  'calibration usage unavailable',
  'calibration allowance consumed',
  'retained-content calibration cap exceeded',
  'submission safety ceiling exceeded',
  'serialized request exceeds 1 MiB',
};

/// The surviving evidence for one request lineage and effective policy.
final class CompactionState {
  /// Creates the initial, unverified state.
  CompactionState();

  /// The observed capability, not a documented route guarantee.
  String state = 'unverified';

  /// The fixed reason for the latest conclusive observation.
  String reason = 'no conclusive observation';

  /// Whether an admission already consumed the selected boundary's allowance.
  bool calibrationConsumed = false;

  /// The scalar representation persisted with a step.
  Map<String, Object?> toJson() => {'state': state, 'reason': reason};

  /// Folds surviving admissions and observations, without persistent caches.
  static CompactionState fold(
    SessionTree tree,
    Map<String, Object?> lineage,
    EffectiveCompactionPolicy policy,
    String? boundary,
  ) {
    final result = CompactionState();
    for (final step in _steps(tree)) {
      if (jsonEncode(step['lineage']) != jsonEncode(lineage)) continue;
      if (boundary != null &&
          step['boundary'] == boundary &&
          step['calibration'] == true) {
        result.calibrationConsumed = true;
      }
      final recorded = step['policy'];
      if (recorded is! Map<String, Object?> ||
          recorded['strategy'] != policy.strategy.wireName ||
          recorded['threshold'] != policy.threshold) {
        continue;
      }
      final evidence = step['capability'];
      if (evidence
          case {'state': final String state, 'reason': final String reason}
          when (state == 'unsupported' &&
                  compactionNoticeReasons.contains(reason)) ||
              (state == 'observed-supported' &&
                  reason == 'compaction item observed')) {
        result.state = state;
        result.reason = reason;
      }
    }
    return result;
  }
}

/// Derives the latest fixed stop reason for the current request lineage.
String? compactionStopReason(SessionTree tree, Map<String, Object?> lineage) {
  String? reason;
  for (final step in _steps(tree)) {
    if (jsonEncode(step['lineage']) != jsonEncode(lineage)) continue;
    final stop = step['nativeStop'];
    if (stop is String && compactionNoticeReasons.contains(stop)) reason = stop;
  }
  return reason;
}

/// Derives one bounded, sanitized notice after an explicit recovery.
String? compactionRecoveryNotice(
  SessionTree tree,
  Map<String, Object?> lineage,
) {
  final reason = compactionStopReason(tree, lineage);
  return reason == null
      ? null
      : 'Previous native compaction stop: $reason. '
            'The owner explicitly continued; do not assume native compaction succeeded.';
}

Iterable<Map<String, Object?>> _steps(SessionTree tree) sync* {
  final nodes = tree.get(SessionPath.parse('body/steps'));
  if (nodes is! Map<String, Object?>) return;
  final keys = nodes.keys.toList()..sort();
  for (final key in keys) {
    final step = nodes[key];
    if (step is Map<String, Object?>) yield step;
  }
}
