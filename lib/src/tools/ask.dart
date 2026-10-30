/// The `ask` tool and the answerer channel that permission prompts share.
library;

import 'dart:async';
import 'dart:convert';

import '../provider/provider.dart';
import '../results/composer.dart';
import 'tool.dart';

/// What a [PromptItem] asks for.
enum PromptKind {
  /// A question the model asked with the `ask` tool.
  question,

  /// A request to allow or deny a tool call.
  permission,
}

/// One question or permission prompt delivered to the answerer.
final class PromptItem {
  /// Creates an item for the call keyed [key].
  const PromptItem({
    required this.key,
    required this.kind,
    required this.tool,
    required this.input,
  });

  /// The call key; the answerer replies by it.
  final String key;

  /// Whether this is a question or a permission prompt.
  final PromptKind kind;

  /// The tool the call belongs to.
  final String tool;

  /// The validated arguments of the call.
  final Map<String, Object?> input;

  /// The item as `{key, kind, tool, input}`.
  Map<String, Object?> toJson() => {
    'key': key,
    'kind': kind.name,
    'tool': tool,
    'input': input,
  };
}

/// The user-facing end of the channel: where questions and prompts arrive.
///
/// The answerer replies through [PromptChannel.reply] by call key. This
/// change ships test answerers only; the terminal client wires one later.
abstract interface class Answerer {
  /// Shows [item] to the user.
  void prompt(PromptItem item);

  /// Tells the user the prompt for [key] is no longer open.
  void withdraw(String key);
}

/// The open prompts of one runtime and the one attached answerer.
///
/// Each item goes to at most one answerer. A reply that does not fit is
/// refused and the prompt stays open; a prompt ends when it is answered,
/// withdrawn by its call's cancel token, or [withdraw]n by the runtime.
final class PromptChannel {
  /// Creates a channel; without an [answerer] the session is headless.
  PromptChannel([this.answerer]);

  /// The attached answerer, or null when headless.
  final Answerer? answerer;

  final Map<String, _Open> _open = {};
  final Map<String, String> _closed = {};

  /// Whether an answerer is attached.
  bool get hasAnswerer => answerer != null;

  /// The keys of the prompts waiting for a reply.
  Iterable<String> get openKeys => List.unmodifiable(_open.keys);

  /// Delivers [item] to the answerer and waits for an accepted reply.
  ///
  /// A reply is accepted when it is one of [choices], or any text when
  /// [acceptText] is true. Returns the accepted reply, or null when the prompt
  /// was withdrawn first; [cancel] withdraws it. Throws a [StateError] when no
  /// answerer is attached or the key is already open.
  Future<String?> open(
    PromptItem item,
    CancelToken cancel, {
    List<String> choices = const [],
    bool acceptText = false,
  }) {
    final target = answerer;
    if (target == null) throw StateError('no answerer is attached');
    if (_open.containsKey(item.key)) {
      throw StateError('prompt ${item.key} is already open');
    }
    if (cancel.isCancelled) return Future.value();
    final open = _Open(choices, acceptText);
    open.detach = cancel.listen(() => withdraw(item.key));
    _open[item.key] = open;
    target.prompt(item);
    return open.reply.future;
  }

  /// Offers the reply [answer] for the prompt [key].
  ///
  /// Returns null when it was accepted and ended the prompt, or the refusal
  /// text; a refused prompt stays open.
  String? reply(String key, String answer) {
    final open = _open[key];
    if (open == null) {
      return switch (_closed[key]) {
        'withdrawn' => 'question withdrawn',
        'answered' => 'question already answered',
        _ => 'no open question $key',
      };
    }
    if (!open.acceptText && !open.choices.contains(answer)) {
      return 'answer must be one of: ${open.choices.join(', ')}';
    }
    _end(key, 'answered').reply.complete(answer);
    return null;
  }

  /// Withdraws the prompt [key], telling the answerer. No-op when not open.
  void withdraw(String key) {
    if (!_open.containsKey(key)) return;
    _end(key, 'withdrawn').reply.complete();
    answerer?.withdraw(key);
  }

  _Open _end(String key, String how) {
    final open = _open.remove(key)!;
    open.detach();
    _closed[key] = how;
    return open;
  }
}

final class _Open {
  _Open(this.choices, this.acceptText);

  final List<String> choices;
  final bool acceptText;
  final Completer<String?> reply = Completer<String?>();
  void Function() detach = () {};
}

/// The cross-field rules of the `ask` arguments that the schema cannot say.
///
/// Free text may be disallowed only when there are choices to pick from.
List<String> askRules(Map<String, Object?> input) {
  final choices = input['choices'];
  final none = choices is! List<Object?> || choices.isEmpty;
  if (none && input['allow_text'] == false) {
    return const ['allow_text: must be true when there are no choices'];
  }
  return const [];
}

/// The `ask` tool: asks the user through the answerer and returns the answer
/// as `{"choice":...}` or `{"text":...}`.
final class AskTool implements Tool {
  /// Creates the tool.
  const AskTool();

  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    final prompts = context.prompts;
    if (prompts == null || !prompts.hasAnswerer) {
      await context.output.writeText('no user attached');
      return const ToolOutcome(
        status: ResultStatus.error,
        summary: 'no user attached',
      );
    }
    final choices = [
      for (final c in (input['choices'] as List<Object?>? ?? const []))
        c! as String,
    ];
    final allowText = input['allow_text'] as bool? ?? choices.isEmpty;
    final answer = await prompts.open(
      PromptItem(
        key: context.callKey,
        kind: PromptKind.question,
        tool: 'ask',
        input: input,
      ),
      context.cancel,
      choices: choices,
      acceptText: allowText,
    );
    if (answer == null) {
      return const ToolOutcome(
        status: ResultStatus.error,
        summary: 'question withdrawn',
        complete: false,
      );
    }
    final json = choices.contains(answer)
        ? {'choice': answer}
        : {'text': answer};
    await context.output.writeText(jsonEncode(json));
    return const ToolOutcome(summary: 'answered');
  }
}
