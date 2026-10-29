/// Runs a real two-turn tool round trip through the ChatGPT adapter.
///
/// ```sh
/// dart run tool/provider_smoke.dart [--model <id>]
/// ```
///
/// Uses the stored `kehai login openai` credentials (and the same
/// `KEHAI_HOME` and loopback overrides as the CLI). Turn 1 asks the model to
/// call an `echo` tool and must end with a tool call and `Completed(tool_use)`.
/// Turn 2 sends the call and its output back by `call_id` and must end with
/// text and `Completed(end_turn)`. Prints the normalized events, never a
/// token, and exits non-zero naming any other outcome.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:kehai/kehai.dart';
import 'package:kehai/src/cli/settings.dart';

const _echo = ToolSpec(
  name: 'echo',
  description: 'Returns the given text unchanged.',
  parametersJsonSchema: {
    'type': 'object',
    'properties': {
      'text': {'type': 'string', 'description': 'The text to echo.'},
    },
    'required': ['text'],
    'additionalProperties': false,
  },
);

const _instructions =
    'You are a smoke test. When asked, call the echo tool exactly once. '
    'After you receive its output, answer with one short sentence that '
    'quotes it.';

const _prompt = 'Call the echo tool with the text "kehai smoke".';

Future<void> main(List<String> args) async {
  exitCode = await _run(args);
}

Future<int> _run(List<String> args) async {
  final model = switch (args) {
    [] => null,
    ['--model', final id] => id,
    _ => null,
  };
  if (args.isNotEmpty && model == null) {
    stderr.writeln('usage: dart run tool/provider_smoke.dart [--model <id>]');
    return 64;
  }

  final KehaiSettings settings;
  try {
    settings = KehaiSettings.fromEnvironment(Platform.environment);
  } on SettingsError catch (e) {
    stderr.writeln('smoke: ${e.message}');
    return 64;
  }
  final store = CredentialStore(
    home: settings.home,
    backend: settings.createBackend(),
  );
  final adapter = ChatGptAdapter(
    refresher: Refresher(store: store, issuer: settings.issuer),
    apiBase: settings.apiBase,
  );

  try {
    final chosen = model ?? await _firstModel(adapter);
    if (chosen == null) return _fail('no models available');
    stdout.writeln('model: $chosen');
    final session = 'kehai-smoke-${Random.secure().nextInt(1 << 32)}';
    final user = const UserMessage(_prompt);

    stdout.writeln('turn 1');
    final first = await _turn(adapter, chosen, session, [user]);
    final call = first.calls.length == 1 ? first.calls.single : null;
    if (first.stop != StopReason.toolUse || call == null) {
      return _fail(
        'turn 1 ended with ${first.outcome}, '
        '${first.calls.length} tool calls; expected one echo call and '
        'Completed(tool_use)',
      );
    }
    if (call.name != 'echo') {
      return _fail('turn 1 called "${call.name}", expected "echo"');
    }
    final output = _echoOutput(call.argumentsJson);

    stdout.writeln('turn 2');
    final second = await _turn(adapter, chosen, session, [
      user,
      ...first.reasoning,
      ToolCallItem(
        callId: call.callId,
        name: call.name,
        argumentsJson: call.argumentsJson,
      ),
      ToolOutputItem(callId: call.callId, output: output),
    ]);
    if (second.stop != StopReason.endTurn || second.text.isEmpty) {
      return _fail(
        'turn 2 ended with ${second.outcome} and '
        '${second.text.isEmpty ? 'no' : 'some'} text; expected text and '
        'Completed(end_turn)',
      );
    }
    stdout.writeln('smoke: passed');
    return 0;
  } on ProviderFailure catch (failure) {
    return _fail('failed: ${failure.kind.wire}: ${failure.message}');
  }
}

Future<String?> _firstModel(ChatGptAdapter adapter) async {
  final models = await adapter.listModels();
  return models.isEmpty ? null : models.first.id;
}

String _echoOutput(String argumentsJson) {
  try {
    final decoded = jsonDecode(argumentsJson);
    if (decoded case {'text': final String text}) return text;
  } on FormatException {
    // Falls through: the raw arguments are echoed.
  }
  return argumentsJson;
}

int _fail(String reason) {
  stderr.writeln('smoke: $reason');
  return 1;
}

final class _TurnResult {
  final List<ToolCall> calls = [];
  final List<ConversationItem> reasoning = [];
  final StringBuffer _text = StringBuffer();
  StopReason? stop;
  String outcome = 'no Completed event';

  String get text => _text.toString();
}

Future<_TurnResult> _turn(
  ChatGptAdapter adapter,
  String model,
  String session,
  List<ConversationItem> items,
) async {
  final result = _TurnResult();
  final request = ModelRequest(
    model: model,
    instructions: _instructions,
    items: items,
    tools: const [_echo],
    sessionId: session,
  );
  await for (final event in adapter.stream(request)) {
    switch (event) {
      case TextDelta(:final text):
        result._text.write(text);
        stdout.writeln('  TextDelta ${jsonEncode(text)}');
      case ReasoningSummaryDelta(:final text):
        stdout.writeln('  ReasoningSummaryDelta ${jsonEncode(text)}');
      case ToolCall():
        result.calls.add(event);
        stdout.writeln(
          '  ToolCall ${event.name} call_id=${event.callId} '
          'arguments=${event.argumentsJson}',
        );
      case OpaqueItem(:final json):
        result.reasoning.add(OpaqueReasoningItem(json));
        stdout.writeln('  OpaqueItem type=${json['type']}');
      case Usage():
        stdout.writeln(
          '  Usage input=${event.input} cached=${event.cachedInput} '
          'output=${event.output} reasoning=${event.reasoning}',
        );
      case Completed(:final stop):
        result
          ..stop = stop
          ..outcome = 'Completed(${stop.wire})';
        stdout.writeln('  ${result.outcome}');
      case Failed(:final failure):
        result.outcome = 'Failed(${failure.kind.wire})';
        stdout.writeln('  ${result.outcome}: ${failure.message}');
    }
  }
  return result;
}
