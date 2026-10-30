/// Builds each model request from the session tree (design D3, D4, D7).
library;

import 'dart:io';

import '../provider/provider.dart';
import '../results/composer.dart';
import '../results/handles.dart';
import '../session/path.dart';
import '../session/tree.dart';
import 'instructions.dart';
import 'sensorium.dart';

const Set<String> _terminal = {'settled', 'failed', 'cancelled'};

/// A request built from the tree, with the numbers behind its budget line.
final class BuiltRequest {
  /// Creates a built request.
  const BuiltRequest({
    required this.request,
    required this.used,
    required this.window,
    required this.block,
    required this.blockText,
  });

  /// The request to send; its last item is the sensorium block.
  final ModelRequest request;

  /// The context in use, estimated, including the block.
  final int used;

  /// The model's context window, or null when unknown.
  final int? window;

  /// The estimate of the sensorium block of this request.
  final int block;

  /// The sensorium block text.
  final String blockText;

  /// Whether the context in use exceeds a known window.
  bool get overflow => window != null && used > window!;
}

/// Builds requests for one session and model.
final class RequestBuilder {
  /// Creates a builder.
  ///
  /// [estimateRequest] sizes a whole request when no completed step has
  /// reported usage yet. [clock] gives the time shown in the block.
  RequestBuilder({
    required this.sessionDir,
    required this.model,
    required this.workspaceName,
    required this.tools,
    required this.estimateRequest,
    this.window,
    this.estimate = estimateItem,
    this.clock = DateTime.now,
  });

  /// The session directory holding the result files.
  final Directory sessionDir;

  /// The model slug.
  final String model;

  /// The workspace's directory name, shown as `cwd`.
  final String workspaceName;

  /// The tools the model may call.
  final List<ToolSpec> tools;

  /// The context window in tokens, or null when unknown.
  final int? window;

  /// Estimates one item.
  final ItemEstimator estimate;

  /// Estimates a whole request.
  final int Function(ModelRequest request) estimateRequest;

  /// The clock for `HH:MM`.
  final DateTime Function() clock;

  /// Builds the request for the step at journal [turn] from [tree].
  Future<BuiltRequest> build(SessionTree tree, {required int turn}) async {
    final (items, baseline) = await _conversation(tree);
    final session = tree.get(SessionPath.parse('meta/session'));

    ModelRequest requestWith(String block) => ModelRequest(
      model: model,
      instructions: builtInInstructions,
      items: [for (final b in items) b.item, UserMessage(block)],
      tools: tools,
      sessionId: session is String ? session : '',
    );

    String render(int used) => sensoriumBlock(
      turn: turn,
      now: clock(),
      workspaceName: workspaceName,
      used: used,
      window: window,
      model: model,
    );

    int blockTokens(String block) => estimate(UserMessage(block));

    final provisional = render(0);
    final provisionalTokens = blockTokens(provisional);
    final base = baseline == null
        ? estimateRequest(requestWith(provisional))
        : baseline.tokens -
              baseline.block +
              uncoveredTokens(items, baseline, estimate) +
              provisionalTokens;
    // The block holds the number it reports, so its own size can differ a
    // little from the provisional one; the count is adjusted once for that.
    final used = base - provisionalTokens + blockTokens(render(base));
    final finalBlock = render(used);
    return BuiltRequest(
      request: requestWith(finalBlock),
      used: used,
      window: window,
      block: blockTokens(finalBlock),
      blockText: finalBlock,
    );
  }

  Future<(List<BuiltItem>, UsageBaseline?)> _conversation(
    SessionTree tree,
  ) async {
    final exchanges = _children(tree, 'body/exchanges');
    final steps = _children(tree, 'body/steps');
    final calls = Map.fromEntries(_children(tree, 'body/calls'));
    final items = <BuiltItem>[];
    UsageBaseline? baseline;

    for (final MapEntry(key: exchangeKey, value: exchange) in exchanges) {
      final first = exchange['first'];
      items.add(
        BuiltItem(
          UserMessage('${exchange['prompt']}'),
          first is int ? first : _turnOf(exchangeKey),
          ItemRole.prompt,
        ),
      );
      for (final MapEntry(key: stepKey, value: step) in steps) {
        if (step['exchange'] != exchangeKey || step['state'] != 'completed') {
          continue;
        }
        final turn = _turnOf(stepKey);
        baseline = _baselineOf(step, turn) ?? baseline;
        final output = step['output'];
        if (output is! List<Object?>) continue;
        for (final entry in output) {
          if (entry is! Map<String, Object?>) continue;
          switch (entry['type']) {
            case 'text':
              items.add(
                BuiltItem(
                  AssistantMessage('${entry['text']}'),
                  turn,
                  ItemRole.response,
                ),
              );
            case 'reasoning':
              final item = entry['item'];
              if (item is Map<String, Object?>) {
                items.add(
                  BuiltItem(OpaqueReasoningItem(item), turn, ItemRole.response),
                );
              }
            case 'call':
              final node = _callNode(calls, '${entry['call']}');
              if (node == null) continue; // unpaired: omitted whole (D3)
              final callId = '${entry['callId']}';
              items
                ..add(
                  BuiltItem(
                    ToolCallItem(
                      callId: callId,
                      name: '${entry['name']}',
                      argumentsJson: '${entry['arguments']}',
                    ),
                    turn,
                    ItemRole.response,
                  ),
                )
                ..add(
                  BuiltItem(
                    ToolOutputItem(
                      callId: callId,
                      output: await _modelText(tree, node),
                    ),
                    turn,
                    ItemRole.output,
                  ),
                );
          }
        }
      }
    }
    return (items, baseline);
  }

  UsageBaseline? _baselineOf(Map<String, Object?> step, int turn) {
    final usage = step['usage'];
    if (usage is! Map<String, Object?>) return null;
    final input = usage['input'];
    final output = usage['output'];
    if (input is! int || output is! int) return null;
    final context = step['context'];
    final block = context is Map<String, Object?> ? context['block'] : null;
    return UsageBaseline(
      turn: turn,
      tokens: input + output,
      block: block is int ? block : 0,
    );
  }

  /// The call node when it exists and is terminal, else null.
  Map<String, Object?>? _callNode(
    Map<String, Map<String, Object?>> calls,
    String key,
  ) {
    final node = calls[key];
    return node != null && _terminal.contains(node['status']) ? node : null;
  }

  /// The model text of a terminal call node (design D4).
  Future<String> _modelText(SessionTree tree, Map<String, Object?> node) async {
    final tool = '${node['tool']}';
    final diag = _diagLines(node);
    final model = node['model'];
    if (model is Map<String, Object?>) {
      try {
        final resolved = resolveHandle(tree, sessionDir, '${model['handle']}');
        return resolved.file.readAsStringSync();
      } on Object {
        // Fall through to recomposition.
      }
    }
    final result = node['result'];
    if (result is Map<String, Object?>) {
      try {
        final ResolvedResult(:descriptor, :file) = resolveHandle(
          tree,
          sessionDir,
          '${result['handle']}',
        );
        final envelope = ResultStatus.values.asNameMap()['${node['envelope']}'];
        final text = await composeResult(
          tool,
          envelope ?? ResultStatus.error,
          '${node['summary']}',
          descriptor,
          file,
          policy: ResultPolicy.forTool(tool),
        );
        return text + diag;
      } on Object catch (e) {
        return '[$tool error] result unavailable: $e$diag';
      }
    }
    final reason = '${node['reason'] ?? ''}';
    final error = reason.startsWith('storage: ')
        ? reason.substring('storage: '.length)
        : reason;
    final accepted = node['accepted'];
    return composeStorageFailure(tool, error, accepted is int ? accepted : 0) +
        diag;
  }

  String _diagLines(Map<String, Object?> node) {
    final diag = node['diag'];
    if (diag is! List<Object?>) return '';
    return [
      for (final entry in diag)
        if (entry is Map<String, Object?>)
          '\n[diag ${entry['source']}] ${entry['text']}',
    ].join();
  }
}

/// The map children of the node at [path], sorted by key.
List<MapEntry<String, Map<String, Object?>>> _children(
  SessionTree tree,
  String path,
) {
  final node = tree.get(SessionPath.parse(path));
  if (node is! Map<String, Object?>) return const [];
  return [
    for (final key in node.keys.toList()..sort())
      if (node[key] case final Map<String, Object?> child) MapEntry(key, child),
  ];
}

/// The journal turn in a node key such as `s-00000007`.
int _turnOf(String key) => int.tryParse(key.substring(2)) ?? 0;
