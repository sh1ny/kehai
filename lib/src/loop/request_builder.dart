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
import 'compaction_state.dart';
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
    required this.lineage,
    required this.boundary,
    required this.retained,
    required this.quality,
  });

  /// The provider, route, model and captured instruction/tool identity.
  final Map<String, Object?> lineage;

  /// The selected committed boundary identity, or null for full history.
  final String? boundary;

  /// The request to send; its last item is the sensorium block.
  final ModelRequest request;

  /// The estimated context in use, or null until compacted usage is known.
  final int? used;

  /// The estimated non-opaque instructions, tools, suffix, notes and sensorium.
  final int retained;

  /// The provenance of the total context estimate, or its unknown state.
  final String quality;

  /// The model's context window, or null when unknown.
  final int? window;

  /// The estimate of the sensorium block of this request.
  final int block;

  /// The sensorium block text.
  final String blockText;

  /// Whether the context in use exceeds a known window.
  bool get overflow => window != null && used != null && used! > window!;
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
    this.windowEstimated = false,
    this.estimate = estimateItem,
    this.clock = DateTime.now,
    this.roleInstructions,
    this.effort,
    this.providerId = 'openai',
    this.routeId = 'chatgpt-account',
    this.nativeCompaction,
  });

  /// The provider identity recorded at admission.
  final String providerId;

  /// The route identity recorded at admission.
  final String routeId;

  /// The resolved inline request policy.
  final NativeCompactionPolicy? nativeCompaction;

  /// The role section of a child engine's instructions, or null.
  final String? roleInstructions;

  /// The selected reasoning effort, or null for provider default.
  final String? effort;

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

  /// Whether the effective window is a user-configured estimate.
  final bool windowEstimated;

  /// Estimates one item.
  final ItemEstimator estimate;

  /// Estimates a whole request.
  final int Function(ModelRequest request) estimateRequest;

  /// The clock for `HH:MM`.
  final DateTime Function() clock;

  /// Derives admission lineage from captured inputs without projecting history.
  Map<String, Object?> requestLineage(SessionTree tree) {
    final context = _currentContext(tree);
    final captured = _capturedRole(tree, context);
    return _lineage(
      composeInstructions(
        role: captured?.text ?? roleInstructions,
        context: _contextText(tree, context),
      ),
    );
  }

  Map<String, Object?> _lineage(String instructions) => <String, Object?>{
    'provider': providerId,
    'route': routeId,
    'model': model,
    'instructions': _digest(instructions),
    'tools': _digest([
      for (final tool in tools)
        {
          'name': tool.name,
          'description': tool.description,
          'parameters': tool.parametersJsonSchema,
        },
    ]),
  };

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
    final session = tree.get(SessionPath.parse('meta/session'));
    final instructions = composeInstructions(
      role: captured?.text ?? roleInstructions,
      context: _contextText(tree, contextKey),
    );

    final lineage = _lineage(instructions);
    final (items, baseline, boundary) = await _conversation(
      tree,
      identity,
      lineage,
    );

    final notice = compactionRecoveryNotice(tree, lineage);
    if (notice != null) {
      items.add(BuiltItem(UserMessage(notice), turn, ItemRole.note));
    }

    ModelRequest requestWith(String block) => ModelRequest(
      model: model,
      reasoningEffort: effort,
      nativeCompaction: nativeCompaction,
      instructions: instructions,
      items: [for (final b in items) b.item, UserMessage(block)],
      tools: tools,
      sessionId: session is String ? session : '',
    );

    String render(int? used) => sensoriumBlock(
      turn: turn,
      now: clock(),
      workspaceName: workspaceName,
      used: used,
      window: window,
      model: model,
      usedEstimated: true,
      windowEstimated: windowEstimated,
    );

    int blockTokens(String block) => estimate(UserMessage(block));

    final provisional = render(0);
    final provisionalTokens = blockTokens(provisional);
    final int? base = boundary != null && baseline == null
        ? null
        : baseline == null
        ? estimateRequest(requestWith(provisional))
        : baseline.tokens -
              baseline.block +
              uncoveredTokens(items, baseline, estimate) +
              provisionalTokens;
    // The block holds the number it reports, so its own size can differ a
    // little from the provisional one; the count is adjusted once for that.
    final used = base == null
        ? null
        : base - provisionalTokens + blockTokens(render(base));
    final finalBlock = render(used);
    final request = requestWith(finalBlock);
    final nonOpaque = request.items
        .where(
          (item) =>
              item is! OpaqueCompactionItem && item is! OpaqueReasoningItem,
        )
        .toList();
    final nonOpaqueRequest = ModelRequest(
      model: model,
      instructions: instructions,
      items: nonOpaque,
      tools: tools,
      sessionId: request.sessionId,
      reasoningEffort: effort,
      nativeCompaction: nativeCompaction,
    );
    final providerRetained = estimateRequest(nonOpaqueRequest);
    final localRetained =
        estimateText(instructions) +
        estimateText(
          jsonEncode([
            for (final tool in tools)
              {
                'name': tool.name,
                'description': tool.description,
                'parameters': tool.parametersJsonSchema,
              },
          ]),
        ) +
        nonOpaque.fold<int>(0, (sum, item) => sum + estimate(item));
    return BuiltRequest(
      request: request,
      retained: providerRetained > localRetained
          ? providerRetained
          : localRetained,
      quality: used == null
          ? 'unknown compacted usage'
          : baseline == null
          ? 'estimated full request'
          : 'estimated from compatible usage',
      used: used,
      window: window,
      block: blockTokens(finalBlock),
      blockText: finalBlock,
      lineage: lineage,
      boundary: boundary,
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

  Future<(List<BuiltItem>, UsageBaseline?, String?)> _conversation(
    SessionTree tree,
    InstructionsIdentity identity,
    Map<String, Object?> lineage,
  ) async {
    final exchanges = _children(tree, 'body/exchanges');
    final steps = _children(tree, 'body/steps');
    final calls = Map.fromEntries(_children(tree, 'body/calls'));
    final byExchange =
        <Object?, List<MapEntry<String, Map<String, Object?>>>>{};
    for (final entry in steps) {
      (byExchange[entry.value['exchange']] ??= []).add(entry);
    }
    // Find the last cut using metadata only. Never compose discarded results.
    String? cutStep;
    var cutIndex = -1;
    String? boundary;
    for (final MapEntry(key: key, value: step) in steps) {
      if (step['state'] != 'completed') continue;
      final output = step['output'];
      if (output is! List<Object?>) continue;
      for (var i = 0; i < output.length; i++) {
        final entry = output[i];
        if (entry is! Map<String, Object?> ||
            !const {
              'text',
              'reasoning',
              'compaction',
              'call',
            }.contains(entry['type'])) {
          throw StateError('unknown committed output kind');
        }
        if (entry['type'] == 'call' &&
            _callNode(calls, '${entry['call']}') == null) {
          throw StateError(
            'committed call has no terminal outcome; reopen to recover',
          );
        }
        if (entry['type'] == 'compaction') {
          cutStep = key;
          cutIndex = i;
          final json = entry['item'];
          if (json is! Map<String, Object?> ||
              json['type'] != 'compaction' ||
              json['id'] is! String ||
              (json['id']! as String).isEmpty ||
              json['encrypted_content'] is! String ||
              (json['encrypted_content']! as String).isEmpty) {
            throw StateError('invalid committed compaction item');
          }
          boundary = '$key:$i:${json['id']}';
        }
      }
    }
    // Validate the selected boundary and all opaque suffix metadata before
    // composing any result. An older compatible cut is never a fallback.
    var inSuffix = cutStep == null;
    for (final MapEntry(key: key, value: step) in steps) {
      if (step['state'] != 'completed') continue;
      final output = step['output'];
      if (output is! List<Object?>) continue;
      if (key == cutStep) inSuffix = true;
      if (!inSuffix) continue;
      for (var i = key == cutStep ? cutIndex : 0; i < output.length; i++) {
        final entry = output[i] as Map<String, Object?>;
        if ((entry['type'] == 'compaction' || entry['type'] == 'reasoning') &&
            !_same(step['lineage'], lineage) &&
            (boundary != null || step['lineage'] != null)) {
          throw StateError(
            'incompatible continuity; rewind before boundary or start a new session',
          );
        }
      }
    }
    final items = <BuiltItem>[];
    UsageBaseline? baseline;
    var retaining = cutStep == null;
    for (final MapEntry(key: exchangeKey, value: exchange) in exchanges) {
      final first = exchange['first'];
      if (retaining) {
        items.add(
          BuiltItem(
            UserMessage('${exchange['prompt']}'),
            first is int ? first : _turnOf(exchangeKey),
            ItemRole.prompt,
          ),
        );
      }
      for (final MapEntry(key: stepKey, value: step)
          in byExchange[exchangeKey] ??
              const <MapEntry<String, Map<String, Object?>>>[]) {
        if (step['state'] != 'completed') continue;
        final turn = _turnOf(stepKey);
        final selected = stepKey == cutStep;
        final output = step['output'];
        if (output is! List<Object?>) continue;
        if (!retaining && !selected) continue;
        final measured = _baselineOf(step, turn);
        if (measured != null &&
            InstructionsIdentity.fromRecorded(step['instructions']) ==
                identity &&
            step['boundary'] == boundary &&
            (boundary == null
                ? step['lineage'] == null || _same(step['lineage'], lineage)
                : _same(step['lineage'], lineage))) {
          baseline = measured;
        }
        if (selected) retaining = true;
        final notes = <BuiltItem>[];
        for (var i = 0; i < output.length; i++) {
          final entry = output[i];
          if (entry is! Map<String, Object?>) {
            throw StateError('invalid output entry');
          }
          if (selected && i < cutIndex) {
            if (entry['type'] == 'call') {
              final node = _callNode(calls, '${entry['call']}')!;
              notes.add(
                BuiltItem(
                  UserMessage(
                    'Tool result after compaction for call ${entry['callId']} '
                    '(${entry['name']}):\n${await _modelText(tree, node)}',
                  ),
                  turn,
                  ItemRole.output,
                ),
              );
            }
            continue;
          }
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
            case 'compaction':
              final json = entry['item'];
              if (json is! Map<String, Object?>) {
                throw StateError('invalid opaque item');
              }
              items.add(
                BuiltItem(
                  entry['type'] == 'compaction'
                      ? OpaqueCompactionItem(json)
                      : OpaqueReasoningItem(json),
                  turn,
                  ItemRole.response,
                ),
              );
            case 'call':
              final node = _callNode(calls, '${entry['call']}')!;
              final callId = '${entry['callId']}';
              items.add(
                BuiltItem(
                  ToolCallItem(
                    callId: callId,
                    name: '${entry['name']}',
                    argumentsJson: '${entry['arguments']}',
                  ),
                  turn,
                  ItemRole.response,
                ),
              );
              items.add(
                BuiltItem(
                  ToolOutputItem(
                    callId: callId,
                    output: await _modelText(tree, node),
                  ),
                  turn,
                  ItemRole.output,
                ),
              );
            default:
              throw StateError(
                'unknown committed output kind: ${entry['type']}',
              );
          }
        }
        items.addAll(notes);
      }
      if (retaining && exchange['state'] == 'cancelled') {
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
    return (items, baseline, boundary);
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

// Canonical JSON makes schema key order irrelevant to lineage.
Object? _canonical(Object? value) => switch (value) {
  Map<String, Object?> map => {
    for (final k in map.keys.toList()..sort()) k: _canonical(map[k]),
  },
  List<Object?> list => [for (final v in list) _canonical(v)],
  _ => value,
};
String _digest(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(_canonical(value)))).toString();
bool _same(Object? a, Object? b) =>
    jsonEncode(_canonical(a)) == jsonEncode(_canonical(b));
