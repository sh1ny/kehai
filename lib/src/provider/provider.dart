/// The normalized model provider interface (design D10).
///
/// A [ModelProvider] turns a [ModelRequest] into a stream of [ProviderEvent]s
/// that ends with exactly one [Completed] or [Failed]. Nothing above this
/// interface sees a backend wire format.
library;

import 'dart:async';

import '../auth/failure_text.dart';

/// The failure kinds of a provider failure.
///
/// This reuses [FailureKind]; the provider kinds are `reauthRequired`,
/// `usageLimit`, `rateLimited`, `notPermitted`, `contextOverflow`,
/// `invalidRequest`, `server`, `network`, `idleTimeout`, `cancelled`,
/// `incomplete` and `protocol`.
typedef ProviderFailureKind = FailureKind;

/// A model backend that streams normalized turn events.
abstract interface class ModelProvider {
  /// The stable provider identifier, such as `openai`.
  String get id;

  /// Sends [request] and streams the turn's events.
  ///
  /// The stream always ends with one [Completed] or one [Failed]. Calling
  /// [CancelToken.cancel] on [cancel] ends it with a `cancelled` [Failed].
  Stream<ProviderEvent> stream(ModelRequest request, {CancelToken? cancel});

  /// Lists the models this provider offers.
  Future<List<ModelInfo>> listModels();

  /// Estimates the input size of [request] without sending it.
  TokenEstimate estimate(ModelRequest request);
}

/// A model offered by a provider.
final class ModelInfo {
  /// Creates a model with its [id] slug and display [name].
  const ModelInfo({required this.id, required this.name, this.contextWindow});

  /// The model slug sent in requests.
  final String id;

  /// The display name.
  final String name;

  /// The context window in tokens the backend reports, or null when unknown.
  final int? contextWindow;
}

/// An approximate input size in tokens.
final class TokenEstimate {
  /// Creates an estimate of [tokens]; it is never exact.
  const TokenEstimate(this.tokens);

  /// The estimated number of input tokens.
  final int tokens;

  /// Whether the count is exact; always `false`.
  bool get exact => false;
}

/// A tool the model may call.
final class ToolSpec {
  /// Creates a tool with its [name], [description] and parameter schema.
  const ToolSpec({
    required this.name,
    required this.description,
    required this.parametersJsonSchema,
  });

  /// The tool name.
  final String name;

  /// What the tool does, shown to the model.
  final String description;

  /// The JSON Schema of the tool's arguments.
  final Map<String, Object?> parametersJsonSchema;
}

/// One item of the conversation sent to the model.
///
/// There is deliberately no system item: instructions travel separately in
/// [ModelRequest.instructions] (design D7).
sealed class ConversationItem {
  const ConversationItem();
}

/// A message from the user.
final class UserMessage extends ConversationItem {
  /// Creates a user message with [text].
  const UserMessage(this.text);

  /// The message text.
  final String text;
}

/// A message from the assistant.
final class AssistantMessage extends ConversationItem {
  /// Creates an assistant message with [text].
  const AssistantMessage(this.text);

  /// The message text.
  final String text;
}

/// A tool call the assistant made earlier.
final class ToolCallItem extends ConversationItem {
  /// Creates a tool call item.
  const ToolCallItem({
    required this.callId,
    required this.name,
    required this.argumentsJson,
  });

  /// The call identifier that pairs the call with its output.
  final String callId;

  /// The tool name.
  final String name;

  /// The arguments as a JSON string.
  final String argumentsJson;
}

/// The output of a tool call.
final class ToolOutputItem extends ConversationItem {
  /// Creates a tool output for [callId].
  const ToolOutputItem({required this.callId, required this.output});

  /// The identifier of the call this answers.
  final String callId;

  /// The output text.
  final String output;
}

/// An opaque reasoning item forwarded verbatim to keep reasoning continuity.
final class OpaqueReasoningItem extends ConversationItem {
  /// Creates an opaque item holding the raw [json].
  const OpaqueReasoningItem(this.json);

  /// The raw item exactly as the backend produced it.
  final Map<String, Object?> json;
}

/// A request for one model turn.
final class ModelRequest {
  /// Creates a request.
  const ModelRequest({
    required this.model,
    required this.instructions,
    required this.items,
    required this.tools,
    required this.sessionId,
    this.reasoningEffort,
  });

  /// The model slug.
  final String model;

  /// The system instructions.
  final String instructions;

  /// The conversation so far.
  final List<ConversationItem> items;

  /// The tools the model may call.
  final List<ToolSpec> tools;

  /// The reasoning effort, or `null` for the model default.
  final String? reasoningEffort;

  /// The session identifier used for cache affinity.
  final String sessionId;
}

/// An event of a normalized turn stream.
sealed class ProviderEvent {
  const ProviderEvent();
}

/// A fragment of assistant text.
final class TextDelta extends ProviderEvent {
  /// Creates a delta carrying [text].
  const TextDelta(this.text, {this.outputIndex});

  /// The text fragment.
  final String text;

  /// The backend's output index of the item this belongs to, if it sent one.
  final int? outputIndex;
}

/// A fragment of a reasoning summary.
final class ReasoningSummaryDelta extends ProviderEvent {
  /// Creates a delta carrying [text].
  const ReasoningSummaryDelta(this.text, {this.outputIndex});

  /// The summary fragment.
  final String text;

  /// The backend's output index of the item this belongs to, if it sent one.
  final int? outputIndex;
}

/// A complete tool call.
final class ToolCall extends ProviderEvent {
  /// Creates a tool call event.
  const ToolCall({
    required this.callId,
    required this.name,
    required this.argumentsJson,
    this.outputIndex,
  });

  /// The call identifier.
  final String callId;

  /// The tool name.
  final String name;

  /// The complete arguments as a JSON string.
  final String argumentsJson;

  /// The backend's output index of the item this belongs to, if it sent one.
  final int? outputIndex;
}

/// An opaque output item to store and send back verbatim.
final class OpaqueItem extends ProviderEvent {
  /// Creates an event holding the raw [json].
  const OpaqueItem(this.json, {this.outputIndex});

  /// The raw item.
  final Map<String, Object?> json;

  /// The backend's output index of the item this belongs to, if it sent one.
  final int? outputIndex;
}

/// Token usage for the turn; `null` means unknown.
final class Usage extends ProviderEvent {
  /// Creates a usage event.
  const Usage({this.input, this.cachedInput, this.output, this.reasoning});

  /// Input tokens.
  final int? input;

  /// Input tokens served from cache.
  final int? cachedInput;

  /// Output tokens.
  final int? output;

  /// Reasoning tokens.
  final int? reasoning;
}

/// Why a successful turn stopped.
enum StopReason {
  /// The model finished its answer.
  endTurn('end_turn'),

  /// The model wants its tool calls run.
  toolUse('tool_use');

  const StopReason(this.wire);

  /// The stable snake_case name.
  final String wire;
}

/// The only success event; it ends the stream.
final class Completed extends ProviderEvent {
  /// Creates a completion with its [stop] reason.
  const Completed(this.stop);

  /// Why the turn stopped.
  final StopReason stop;
}

/// The failure event; it ends the stream.
final class Failed extends ProviderEvent {
  /// Creates a failure event.
  const Failed(this.failure);

  /// The failure.
  final ProviderFailure failure;
}

/// A sanitized provider failure.
///
/// The [message] is composed from fixed templates by [FailureText] and holds
/// no server text.
final class ProviderFailure implements Exception {
  /// Creates a failure; [message] is cut to [maxFailureMessageLength].
  ProviderFailure({
    required this.kind,
    required String message,
    this.status,
    this.code,
    this.param,
    this.retryAfter,
    this.sent = false,
    this.rotationUncertain = false,
  }) : message = message.length > maxFailureMessageLength
           ? message.substring(0, maxFailureMessageLength)
           : message;

  /// The failure kind.
  final ProviderFailureKind kind;

  /// The HTTP status, if any.
  final int? status;

  /// The validated server code, if any.
  final String? code;

  /// The validated server parameter, if any.
  final String? param;

  /// How long the server asked the caller to wait, if it said.
  final Duration? retryAfter;

  /// Whether the request body may have reached the backend.
  final bool sent;

  /// Whether a token refresh may have rotated the refresh token unseen.
  final bool rotationUncertain;

  /// The sanitized message, at most [maxFailureMessageLength] characters.
  final String message;

  @override
  String toString() => 'ProviderFailure(${kind.wire}): $message';
}

/// A one-shot cancellation signal.
final class CancelToken {
  final Completer<void> _completer = Completer<void>();
  final Set<_CancelListener> _listeners = {};

  /// Whether [cancel] was called.
  bool get isCancelled => _completer.isCompleted;

  /// A future that completes when [cancel] is called.
  ///
  /// A callback attached here stays reachable until the token is cancelled;
  /// an operation that may end first uses [listen] instead.
  Future<void> get whenCancelled => _completer.future;

  /// The number of callbacks attached with [listen] and not yet detached.
  int get listenerCount => _listeners.length;

  /// Calls [onCancel] in a microtask once [cancel] is called, or at once
  /// (also in a microtask) when the token is already cancelled.
  ///
  /// Returns a function that detaches [onCancel], so a token reused across
  /// operations does not keep finished ones alive.
  void Function() listen(void Function() onCancel) {
    if (isCancelled) {
      scheduleMicrotask(onCancel);
      return () {};
    }
    final listener = _CancelListener(onCancel);
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// Cancels; later calls do nothing.
  void cancel() {
    if (_completer.isCompleted) return;
    _completer.complete();
    final listeners = _listeners.toList();
    _listeners.clear();
    for (final listener in listeners) {
      scheduleMicrotask(listener.onCancel);
    }
  }
}

/// One [CancelToken.listen] registration, compared by identity.
final class _CancelListener {
  _CancelListener(this.onCancel);

  final void Function() onCancel;
}
