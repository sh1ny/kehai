/// Session-local scratch tools using only the runtime's call-bound capability.
library;

import '../results/composer.dart';
import '../session/scratch.dart';
import 'tool.dart';

/// Validates the single journal-segment key before hooks or permissions run.
List<String> scratchKeyRules(Map<String, Object?> input) =>
    validScratchKey(input['key']! as String)
    ? const []
    : const ['key: expected 1–128 characters from A-Z a-z 0-9 _ . : -'];

/// Creates or overwrites one verbatim session-local scratch value.
final class ScratchSetTool implements Tool {
  /// Creates the tool.
  const ScratchSetTool();

  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    final capability = context.scratch;
    if (capability == null) return _unavailable;
    return _answer(
      context,
      await capability.set(input['key']! as String, input['value']! as String),
    );
  }
}

/// Deletes one session-local scratch entry, with an explicit absent no-op.
final class ScratchDelTool implements Tool {
  /// Creates the tool.
  const ScratchDelTool();

  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    final capability = context.scratch;
    if (capability == null) return _unavailable;
    return _answer(context, await capability.delete(input['key']! as String));
  }
}

const _unavailable = ToolOutcome(
  status: ResultStatus.error,
  summary: 'scratch capability unavailable',
);

Future<ToolOutcome> _answer(
  ToolContext context,
  ScratchMutation decision,
) async {
  await context.output.writeText(decision.message);
  return ToolOutcome(
    status: decision.accepted ? ResultStatus.ok : ResultStatus.error,
    summary: decision.accepted ? 'scratch updated' : 'scratch refused',
  );
}
