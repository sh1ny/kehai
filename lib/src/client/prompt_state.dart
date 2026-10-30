/// The prompts the engine has opened and the client has not closed.
library;

import 'dart:collection';

/// An open prompt as the `prompt` event carries it.
final class OpenPrompt {
  /// Creates a prompt.
  const OpenPrompt({
    required this.key,
    required this.kind,
    required this.tool,
    required this.input,
  });

  /// Reads a `prompt` event's `item`, or null when it is malformed.
  static OpenPrompt? fromJson(Object? json) {
    if (json is! Map<String, Object?>) return null;
    final key = json['key'];
    final kind = json['kind'];
    final tool = json['tool'];
    final input = json['input'];
    if (key is! String || kind is! String || tool is! String) return null;
    return OpenPrompt(
      key: key,
      kind: kind,
      tool: tool,
      input: input is Map<String, Object?> ? input : const {},
    );
  }

  /// The call key; answers are sent by it.
  final String key;

  /// `permission` or `question`.
  final String kind;

  /// The tool the call belongs to.
  final String tool;

  /// The call's arguments.
  final Map<String, Object?> input;
}

/// The active prompt and the ones waiting behind it.
///
/// An arrival never replaces the active prompt. At most one answer is in
/// flight, for the active key.
final class PromptState {
  final Queue<OpenPrompt> _pending = Queue();
  OpenPrompt? _active;
  String? _inFlight;

  /// The prompt input answers, or null.
  OpenPrompt? get active => _active;

  /// The key of the answer sent and not yet accepted or refused, or null.
  String? get inFlight => _inFlight;

  /// Opens [prompt]; returns whether it became the active one.
  bool offer(OpenPrompt prompt) {
    if (_active?.key == prompt.key ||
        _pending.any((p) => p.key == prompt.key)) {
      return false;
    }
    if (_active == null) {
      _active = prompt;
      return true;
    }
    _pending.add(prompt);
    return false;
  }

  /// Marks an answer for the active prompt as sent.
  void markSent() => _inFlight = _active?.key;

  /// Marks the answer in flight as refused; the prompt stays active.
  void refused() => _inFlight = null;

  /// Closes the prompt [key]; returns whether the active prompt changed.
  bool remove(String key) {
    if (_inFlight == key) _inFlight = null;
    if (_active?.key == key) {
      _active = _pending.isEmpty ? null : _pending.removeFirst();
      return true;
    }
    _pending.removeWhere((p) => p.key == key);
    return false;
  }
}
