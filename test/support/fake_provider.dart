import 'dart:convert';

import 'package:kehai/kehai.dart';

/// Answers one request with a stream of events; [call] is the 0-based number
/// of the request.
typedef FakeResponder = Stream<ProviderEvent> Function(
  ModelRequest request,
  CancelToken? cancel,
  int call,
);

/// A scripted [ModelProvider]: it records every request it gets.
final class FakeProvider implements ModelProvider {
  /// Creates a provider answering through [respond].
  FakeProvider(this.respond, {this.models = const [], this.estimator});

  /// Creates a provider that answers request `n` with `steps[n]`.
  ///
  /// Each list must end with a [Completed] or [Failed]; asking for more
  /// requests than there are scripts is a test error.
  factory FakeProvider.steps(
    List<List<ProviderEvent>> steps, {
    int Function(ModelRequest request)? estimator,
  }) => FakeProvider(
    (request, cancel, call) => Stream.fromIterable(steps[call]),
    estimator: estimator,
  );

  /// The responder.
  final FakeResponder respond;

  /// What [listModels] returns.
  final List<ModelInfo> models;

  /// Sizes a request for [estimate]; by default text bytes over three.
  final int Function(ModelRequest request)? estimator;

  /// Every request received, in order.
  final List<ModelRequest> requests = [];

  @override
  String get id => 'fake';

  @override
  Stream<ProviderEvent> stream(ModelRequest request, {CancelToken? cancel}) {
    requests.add(request);
    return respond(request, cancel, requests.length - 1);
  }

  @override
  Future<List<ModelInfo>> listModels() async => models;

  @override
  TokenEstimate estimate(ModelRequest request) {
    final custom = estimator;
    if (custom != null) return TokenEstimate(custom(request));
    final bytes =
        utf8.encode(request.instructions).length +
        request.items.fold<int>(0, (sum, item) => sum + _size(item));
    return TokenEstimate((bytes + 2) ~/ 3);
  }
}

int _size(ConversationItem item) => switch (item) {
  UserMessage(:final text) ||
  AssistantMessage(:final text) => utf8.encode(text).length,
  ToolCallItem(:final argumentsJson) => argumentsJson.length,
  ToolOutputItem(:final output) => utf8.encode(output).length,
  OpaqueReasoningItem(:final json) => jsonEncode(json).length,
};
