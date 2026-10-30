/// The request-only sensorium block and the context accounting behind its
/// budget line (design D7).
library;

import 'dart:convert';

import '../provider/provider.dart';

/// Estimates the tokens of one conversation item.
typedef ItemEstimator = int Function(ConversationItem item);

/// The estimate of [text]: its UTF-8 bytes over three, rounded up.
int estimateText(String text) => (utf8.encode(text).length + 2) ~/ 3;

/// The default [ItemEstimator]; it errs high, like the provider's estimate.
int estimateItem(ConversationItem item) => switch (item) {
  UserMessage(:final text) ||
  AssistantMessage(:final text) => estimateText(text),
  ToolCallItem(:final name, :final argumentsJson) =>
    estimateText(name) + estimateText(argumentsJson),
  ToolOutputItem(:final output) => estimateText(output),
  OpaqueReasoningItem(:final json) => estimateText(jsonEncode(json)),
};

/// Renders a token count as `41k` below a million and `1.2M` above.
String formatTokens(int tokens) {
  if (tokens >= 999500) {
    final millions = (tokens / 100000).round() / 10;
    return '${millions.toStringAsFixed(1)}M';
  }
  return '${(tokens / 1000).round()}k';
}

/// Builds the two-line sensorium block for one request.
///
/// [now] is the local time shown as `HH:MM`. With no [window] the budget line
/// shows `?` and no percentage.
String sensoriumBlock({
  required int turn,
  required DateTime now,
  required String workspaceName,
  required int used,
  required int? window,
  required String model,
}) {
  String two(int n) => n.toString().padLeft(2, '0');
  final percent = window == null ? '' : ' (${(used * 100 / window).round()}%)';
  return '<sensorium>\n'
      'turn: $turn · full · ${two(now.hour)}:${two(now.minute)} · '
      'cwd $workspaceName\n'
      'budget: ${formatTokens(used)}/${window == null ? '?' : formatTokens(window)}'
      ' ctx$percent · model $model\n'
      '</sensorium>';
}

/// What a built conversation item is, for context accounting.
enum ItemRole {
  /// The user's prompt that opened an exchange.
  prompt,

  /// Text, reasoning or a call of a step's response.
  response,

  /// A tool output answering a call of a step.
  output,
}

/// A conversation item with its provenance.
///
/// [turn] is the journal turn of the step it belongs to, or of the exchange's
/// first turn for a [ItemRole.prompt].
final class BuiltItem {
  /// Creates an item with its provenance.
  const BuiltItem(this.item, this.turn, this.role);

  /// The item as sent to the model.
  final ConversationItem item;

  /// The journal turn it belongs to.
  final int turn;

  /// What kind of item it is.
  final ItemRole role;
}

/// The baseline of context accounting: the last completed step that reported
/// usage.
final class UsageBaseline {
  /// Creates a baseline.
  const UsageBaseline({
    required this.turn,
    required this.tokens,
    required this.block,
  });

  /// The step's journal turn.
  final int turn;

  /// Its reported input plus output tokens.
  final int tokens;

  /// The estimate of the sensorium block that request carried.
  final int block;
}

/// The estimate of the items a baseline does not cover, chosen by provenance.
///
/// Prompts and response items of steps up to the baseline are inside its
/// reported input or output. Outputs answering earlier steps are inside its
/// input; outputs answering the baseline step itself are not, wherever the
/// request places them.
int uncoveredTokens(
  List<BuiltItem> items,
  UsageBaseline baseline,
  ItemEstimator estimate,
) {
  var sum = 0;
  for (final BuiltItem(:item, :turn, :role) in items) {
    final covered = switch (role) {
      ItemRole.prompt || ItemRole.response => turn <= baseline.turn,
      ItemRole.output => turn < baseline.turn,
    };
    if (!covered) sum += estimate(item);
  }
  return sum;
}
