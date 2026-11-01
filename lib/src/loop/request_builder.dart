/// Builds each model request from the session tree (design D3, D4, D7).
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../provider/provider.dart';
import '../results/composer.dart';
import '../results/handles.dart';
import '../session/path.dart';
import '../session/tree.dart';
import 'instructions.dart';
import 'sensorium.dart';

const Set<String> _terminal = {'settled', 'failed', 'cancelled'};

/// The user note sent after every cancelled exchange (D3), so the model does
/// not take its unanswered prompt as still pending. Its bytes never change.
const String interruptedNote =
    'The previous request was interrupted before it finished. '
    'Do not continue it unless asked.';

/// What a request's instructions were made of (design D16): the built-in
/// version, the captured context key and the digest of the role section.
///
/// A step's reported usage describes the context in use only for a request
/// with the same identity.
final class InstructionsIdentity {
  /// Creates an identity; [context] and [role] are null when absent.
  const InstructionsIdentity(this.version, this.context, this.role);

  /// Reads the `instructions` field of a step: the record map, or the plain
  /// version string of a step written before contexts existed.
  factory InstructionsIdentity.fromRecorded(Object? recorded) =>
      switch (recorded) {
        String version => InstructionsIdentity(version, null, null),
        {'version': final String version} && final Map<String, Object?> map =>
          InstructionsIdentity(
            version,
            map['context'] is String ? map['context']! as String : null,
            map['role'] is String ? map['role']! as String : null,
          ),
        _ => const InstructionsIdentity('', null, null),
      };

  /// The built-in instructions version.
  final String version;

  /// The context key, or null for an exchange without one.
  final String? context;

  /// The role digest, or null outside a child engine.
  final String? role;

  /// The record a step stores.
  Map<String, Object?> toJson() => {
    'version': version,
    'context': context,
    'role': role,
  };

  @override
  bool operator ==(Object other) =>
      other is InstructionsIdentity &&
      other.version == version &&
      other.context == context &&
      other.role == role;

  @override
  int get hashCode => Object.hash(version, context, role);
}

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
    this.roleInstructions,
  });

  /// The role section of a child engine's instructions, or null.
  final String? roleInstructions;

  /// The digest recorded for [roleInstructions], or null.
  String? get roleDigest => switch (roleInstructions) {
    final text? =>
      sha256.convert(utf8.encode(text)).toString().substring(0, 16),
    null => null,
  };

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
    final contextKey = _currentContext(tree);
    // A child's role is read from the tree: the text captured at its start
    // wins over the constructor's hook, whatever the role file says now.
    final captured = _capturedRole(tree, contextKey);
    final identity = InstructionsIdentity(
      instructionsVersion,
      contextKey,
      captured?.digest ?? roleDigest,
    );
    final (items, baseline) = await _conversation(tree, identity);
    final session = tree.get(SessionPath.parse('meta/session'));
    final instructions = composeInstructions(
      role: captured?.text ?? roleInstructions,
      context: _contextText(tree, contextKey),
    );

    ModelRequest requestWith(String block) => ModelRequest(
      model: model,
      instructions: instructions,
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

  /// The context key of the last exchange, which the step being built
  /// belongs to, or null when it records none.
  String? _currentContext(SessionTree tree) {
    final last = _children(tree, 'body/exchanges').lastOrNull?.value;
    final key = last?['context'];
    return key is String ? key : null;
  }

  /// The role captured with context [key] (design D4), or null.
  ({String text, String digest})? _capturedRole(SessionTree tree, String? key) {
    if (key == null) return null;
    final stored = tree.get(SessionPath.parse('body/contexts/$key'));
    final role = stored is Map<String, Object?> ? stored['role'] : null;
    if (role is Map<String, Object?> &&
        role['text'] is String &&
        role['digest'] is String) {
      return (text: role['text']! as String, digest: role['digest']! as String);
    }
    return null;
  }

  /// The stored text of context [key]; empty when none is stored.
  String _contextText(SessionTree tree, String? key) {
    if (key == null) return '';
    final stored = tree.get(SessionPath.parse('body/contexts/$key'));
    final text = stored is Map<String, Object?> ? stored['text'] : null;
    return text is String ? text : '';
  }

  Future<(List<BuiltItem>, UsageBaseline?)> _conversation(
    SessionTree tree,
    InstructionsIdentity identity,
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
        final measured = _baselineOf(step, turn);
        if (measured != null) {
          // Usage counts the instructions it was sent with, so it is the
          // baseline only for a request with the same identity (D16).
          baseline =
              InstructionsIdentity.fromRecorded(step['instructions']) ==
                  identity
              ? measured
              : null;
        }
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
      if (exchange['state'] == 'cancelled') {
        final last = exchange['last'] ?? first;
        items.add(
          BuiltItem(
            const UserMessage(interruptedNote),
            last is int ? last : _turnOf(exchangeKey),
            ItemRole.note,
          ),
        );
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
          // A whole delivery passed its capacity check when it settled.
          notrunc: node['notrunc'] == true,
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
