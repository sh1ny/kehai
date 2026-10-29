/// The ChatGPT plan adapter (design D7, D8, D10).
///
/// [ChatGptAdapter] streams one model turn from the Responses API of the
/// ChatGPT plan backend as normalized [ProviderEvent]s, and lists the models
/// the plan offers. Credentials come from a `Refresher` on every request, and
/// every failure message is composed locally by `FailureText` (design D12).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../auth/auth_failure.dart';
import '../auth/failure_text.dart';
import '../auth/openai_constants.dart';
import '../auth/refresher.dart';
import 'chatgpt_errors.dart';
import 'chatgpt_request.dart';
import 'estimate.dart';
import 'provider.dart';
import 'sse.dart';

/// A [ModelProvider] over the ChatGPT plan Responses API.
///
/// A request is never resent after its body may have reached the backend. The
/// one exception is a `401` before any stream, which refreshes the token once
/// and repeats the request.
final class ChatGptAdapter implements ModelProvider {
  /// Creates an adapter that takes credentials from [refresher].
  ///
  /// [apiBase] defaults to the production base. [silenceDeadline] is how long
  /// the backend may stay silent once the request is sent, and
  /// [connectTimeout] bounds opening a connection and a models request; both
  /// are injectable so tests run fast.
  ChatGptAdapter({
    required this.refresher,
    this.apiBase = openAiApiBase,
    this.silenceDeadline = openAiSilenceDeadline,
    this.connectTimeout = openAiRequestTimeout,
  });

  /// The credential source.
  final Refresher refresher;

  /// The API base URL, without a trailing slash.
  final String apiBase;

  /// The response-silence deadline.
  final Duration silenceDeadline;

  /// The connect timeout, also the overall timeout of a models request.
  final Duration connectTimeout;

  @override
  String get id => 'openai';

  @override
  Stream<ProviderEvent> stream(ModelRequest request, {CancelToken? cancel}) =>
      _Turn(this, request, cancel).stream;

  @override
  TokenEstimate estimate(ModelRequest request) =>
      estimateTokens(buildChatGptBody(request));

  @override
  Future<List<ModelInfo>> listModels() async {
    var credentials = await _credentials();
    for (var attempt = 0; ; attempt++) {
      final text = FailureText(
        secrets: [credentials.accessToken, credentials.idToken],
      );
      final reply = await _getModels(credentials, text);
      if (reply.status == 401 && attempt == 0) {
        credentials = await _refreshAfter(credentials);
        continue;
      }
      return _decodeModels(reply, text);
    }
  }

  Future<Credentials> _credentials() async {
    final Credentials credentials;
    try {
      credentials = await refresher.credentials();
    } on AuthFailure catch (failure) {
      throw fromAuthFailure(failure);
    }
    return _requirePlanUsage(credentials);
  }

  Future<Credentials> _refreshAfter(Credentials stale) async {
    final Credentials credentials;
    try {
      credentials = await refresher.refreshAfterUnauthorized(stale.accessToken);
    } on AuthFailure catch (failure) {
      throw fromAuthFailure(failure);
    }
    return _requirePlanUsage(credentials);
  }

  Credentials _requirePlanUsage(Credentials credentials) {
    if (credentials.registration.planUsageEnabled) return credentials;
    throw localFailure(
      FailureText(),
      FailureKind.notPermitted,
      detail:
          'ChatGPT plan usage is not enabled. Run kehai login openai '
          '--enable-plan-usage.',
    );
  }

  Future<_ModelsReply> _getModels(
    Credentials credentials,
    FailureText text,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = connectTimeout
      ..autoUncompress = false;
    var sent = false;
    try {
      return await (() async {
        final request = await client.getUrl(Uri.parse('$apiBase/models'));
        sent = true;
        request.followRedirects = false;
        request.headers
          ..set('authorization', 'Bearer ${credentials.accessToken}')
          ..set('accept', 'application/json')
          ..set('accept-encoding', 'identity')
          ..set('user-agent', 'kehai/$kehaiVersion');
        final response = await request.close();
        final status = response.statusCode;
        final cap = status == 200
            ? openAiMaxModelsBodyBytes
            : openAiMaxErrorBodyBytes;
        final body = BytesBuilder(copy: false);
        await for (final chunk in response) {
          body.add(chunk);
          if (body.length > cap) {
            return _ModelsReply(status, const [], overflow: true);
          }
        }
        return _ModelsReply(
          status,
          body.takeBytes(),
          retryAfter: parseRetryAfter(response.headers.value('retry-after')),
        );
      })().timeout(connectTimeout);
    } on Object {
      throw localFailure(
        text,
        FailureKind.network,
        detail: sent
            ? 'The models request did not complete.'
            : 'The connection could not be opened.',
        sent: sent,
      );
    } finally {
      client.close(force: true);
    }
  }

  List<ModelInfo> _decodeModels(_ModelsReply reply, FailureText text) {
    if (reply.overflow) {
      throw localFailure(
        text,
        FailureKind.protocol,
        detail: 'Models response exceeds 4 MiB.',
        sent: true,
      );
    }
    if (reply.status != 200) {
      throw mapBackendError(
        text,
        fields: text.parseErrorBody(reply.body),
        status: reply.status,
        retryAfter: reply.retryAfter,
      );
    }
    Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(reply.body, allowMalformed: true));
    } on FormatException {
      decoded = null;
    }
    if (decoded case {'models': final List<Object?> models}) {
      return [
        for (final model in models)
          if (model is Map<Object?, Object?> &&
              model['visibility'] == 'list' &&
              model['supported_in_api'] != false &&
              model['slug'] is String &&
              model['display_name'] is String)
            ModelInfo(
              id: model['slug']! as String,
              name: model['display_name']! as String,
            ),
      ];
    }
    throw localFailure(
      text,
      FailureKind.protocol,
      detail: 'The models response is not a model list.',
      sent: true,
    );
  }
}

final class _ModelsReply {
  const _ModelsReply(
    this.status,
    this.body, {
    this.overflow = false,
    this.retryAfter,
  });

  final int status;
  final List<int> body;
  final bool overflow;
  final Duration? retryAfter;
}

/// One streamed turn: owns the controller, the connection and the timer.
final class _Turn {
  _Turn(this._adapter, this._request, this._cancel) {
    _controller = StreamController<ProviderEvent>(
      onListen: _start,
      onPause: _onPause,
      onResume: _onResume,
      onCancel: _onCancel,
    );
  }

  final ChatGptAdapter _adapter;
  final ModelRequest _request;
  final CancelToken? _cancel;
  late final StreamController<ProviderEvent> _controller;

  FailureText _text = FailureText();
  bool _done = false;
  bool _paused = false;
  bool _watching = false;
  bool _sent = false;
  Timer? _silence;
  HttpClient? _client;
  StreamSubscription<SseEvent>? _sse;
  final List<ToolCall> _held = [];
  final Set<String> _heldIds = {};
  void Function()? _detachCancel;

  Stream<ProviderEvent> get stream => _controller.stream;

  void _start() {
    final cancel = _cancel;
    if (cancel != null) {
      _detachCancel = cancel.listen(
        () => _fail(localFailure(_text, FailureKind.cancelled, sent: _sent)),
      );
    }
    unawaited(_run());
  }

  /// The subscriber paused: stop reading the socket and the silence timer.
  void _onPause() {
    _paused = true;
    _silence?.cancel();
    _silence = null;
    _sse?.pause();
  }

  /// The subscriber resumed: read again and restart the timer in full.
  void _onResume() {
    _paused = false;
    _sse?.resume();
    _arm();
  }

  /// The subscriber went away: abort and emit nothing.
  Future<void> _onCancel() async {
    _done = true;
    _teardown();
  }

  void _arm() {
    _silence?.cancel();
    _silence = null;
    if (_done || _paused || !_watching) return;
    _silence = Timer(_adapter.silenceDeadline, () {
      _fail(localFailure(_text, FailureKind.idleTimeout, sent: true));
    });
  }

  void _teardown() {
    _detachCancel?.call();
    _detachCancel = null;
    _silence?.cancel();
    _silence = null;
    _sse?.cancel().ignore();
    _sse = null;
    _client?.close(force: true);
    _client = null;
  }

  void _emit(ProviderEvent event) {
    if (!_done) _controller.add(event);
  }

  void _fail(ProviderFailure failure) {
    if (_done) return;
    _done = true;
    _teardown();
    _controller.add(Failed(failure));
    unawaited(_controller.close());
  }

  void _finish() {
    if (_done) return;
    _done = true;
    _teardown();
    unawaited(_controller.close());
  }

  ProviderFailure _local(FailureKind kind, String detail, {bool sent = true}) =>
      localFailure(_text, kind, detail: detail, sent: sent);

  Future<void> _run() async {
    try {
      await _execute();
    } on Object {
      _fail(
        _local(FailureKind.protocol, 'The response could not be processed.'),
      );
    }
  }

  Future<void> _execute() async {
    if (_cancel?.isCancelled ?? false) {
      _fail(localFailure(_text, FailureKind.cancelled));
      return;
    }
    final body = encodeChatGptBody(buildChatGptBody(_request));
    if (body == null) {
      _fail(
        _local(
          FailureKind.contextOverflow,
          'The request body exceeds 1 MiB.',
          sent: false,
        ),
      );
      return;
    }
    Credentials credentials;
    try {
      credentials = await _adapter._credentials();
    } on ProviderFailure catch (failure) {
      _fail(failure);
      return;
    }
    if (_done) return;
    for (var attempt = 0; attempt < 2; attempt++) {
      _text = FailureText(
        secrets: [credentials.accessToken, credentials.idToken],
      );
      final response = await _post(credentials, body);
      if (response == null || _done) return;
      if (response.statusCode == 200) {
        _consume(response);
        return;
      }
      final errorBody = await _readCapped(response);
      if (_done) return;
      if (response.statusCode == 401 && attempt == 0) {
        _watching = false;
        _arm();
        _client?.close(force: true);
        _client = null;
        try {
          credentials = await _adapter._refreshAfter(credentials);
        } on ProviderFailure catch (failure) {
          _fail(failure);
          return;
        }
        if (_done) return;
        continue;
      }
      _fail(
        mapBackendError(
          _text,
          fields: _text.parseErrorBody(errorBody),
          status: response.statusCode,
          retryAfter: parseRetryAfter(response.headers.value('retry-after')),
        ),
      );
      return;
    }
  }

  /// Opens a connection, writes the body and waits for the response headers.
  ///
  /// Returns `null` after failing the turn.
  Future<HttpClientResponse?> _post(
    Credentials credentials,
    List<int> body,
  ) async {
    final client = HttpClient()
      ..connectionTimeout = _adapter.connectTimeout
      ..autoUncompress = false;
    _client = client;
    final HttpClientRequest request;
    try {
      request = await client
          .postUrl(Uri.parse('${_adapter.apiBase}/responses'))
          .timeout(_adapter.connectTimeout);
    } on Object {
      _fail(
        _local(
          FailureKind.network,
          'The connection could not be opened.',
          sent: false,
        ),
      );
      return null;
    }
    if (_done) return null;
    try {
      request
        ..followRedirects = false
        ..persistentConnection = false
        ..contentLength = body.length;
      request.headers
        ..set('authorization', 'Bearer ${credentials.accessToken}')
        ..set('content-type', 'application/json')
        ..set('accept', 'text/event-stream')
        ..set('accept-encoding', 'identity')
        ..set('user-agent', 'kehai/$kehaiVersion');
      request.add(body);
      _sent = true;
      _watching = true;
      _arm();
      final response = await request.close();
      if (_done) return null;
      _arm();
      return response;
    } on Object {
      _fail(_local(FailureKind.network, 'The connection was lost.'));
      return null;
    }
  }

  Future<List<int>> _readCapped(Stream<List<int>> source) async {
    final body = BytesBuilder(copy: false);
    try {
      await for (final chunk in source) {
        body.add(chunk);
        if (body.length >= openAiMaxErrorBodyBytes) break;
      }
    } on Object {
      // A broken error body still has a status to report.
    }
    final bytes = body.takeBytes();
    return bytes.length > openAiMaxErrorBodyBytes
        ? bytes.sublist(0, openAiMaxErrorBodyBytes)
        : bytes;
  }

  void _consume(HttpClientResponse response) {
    final subscription = parseSse(response).listen(
      _onSse,
      onError: _onSseError,
      onDone: () {
        if (_done) return;
        _fail(
          _local(
            FailureKind.protocol,
            'The stream ended before the response completed.',
          ),
        );
      },
      cancelOnError: true,
    );
    _sse = subscription;
    if (_paused) subscription.pause();
  }

  void _onSseError(Object error) {
    if (error is SseProtocolError) {
      _fail(_local(FailureKind.protocol, error.message));
    } else {
      _fail(_local(FailureKind.network, 'The connection was lost.'));
    }
  }

  void _onSse(SseEvent event) {
    if (_done) return;
    _arm();
    final data = event.data.trim();
    if (event.isComment || data.isEmpty || data == '[DONE]') return;
    final Object? decoded;
    try {
      decoded = jsonDecode(data);
    } on FormatException {
      _fail(_local(FailureKind.protocol, 'An event was not valid JSON.'));
      return;
    }
    if (decoded is! Map<String, Object?>) return;
    final type = decoded['type'] is String ? decoded['type'] : event.event;
    switch (type) {
      case 'response.output_text.delta':
        if (decoded['delta'] case final String delta when delta.isNotEmpty) {
          _emit(TextDelta(delta));
        }
      case 'response.reasoning_summary_text.delta':
        if (decoded['delta'] case final String delta when delta.isNotEmpty) {
          _emit(ReasoningSummaryDelta(delta));
        }
      case 'response.output_item.done':
        _onItem(decoded['item']);
      case 'response.completed':
        _onCompleted(decoded['response']);
      case 'response.incomplete':
        _onIncomplete(decoded['response']);
      case 'response.failed':
        _onErrorEvent(decoded['response']);
      case 'error':
        _onErrorEvent(decoded);
    }
  }

  void _onItem(Object? item) {
    switch (item) {
      case {'type': 'reasoning'} when item is Map<String, Object?>:
        _emit(OpaqueItem(item));
      case {
        'type': 'function_call',
        'call_id': final String callId,
        'name': final String name,
      }:
        final arguments = (item as Map<String, Object?>)['arguments'];
        final argumentsJson = arguments is String ? arguments : '';
        if (argumentsJson.length > openAiMaxToolCallArgumentBytes) {
          _fail(_local(FailureKind.protocol, 'Tool call arguments too large.'));
        } else if (!_heldIds.add(callId)) {
          return;
        } else if (_held.length >= openAiMaxHeldToolCalls) {
          _fail(_local(FailureKind.protocol, 'Too many tool calls.'));
        } else {
          _held.add(
            ToolCall(callId: callId, name: name, argumentsJson: argumentsJson),
          );
        }
      case {'type': 'function_call'}:
        _fail(_local(FailureKind.protocol, 'A tool call was malformed.'));
    }
  }

  void _onCompleted(Object? response) {
    _held.forEach(_emit);
    _emit(_usage(response));
    _emit(Completed(_held.isEmpty ? StopReason.endTurn : StopReason.toolUse));
    _finish();
  }

  void _onIncomplete(Object? response) {
    _emit(_usage(response));
    final reason = switch (response) {
      {'incomplete_details': {'reason': final String reason}} => reason,
      _ => null,
    };
    final composed = _text.compose(FailureKind.incomplete, code: reason);
    _fail(
      ProviderFailure(
        kind: FailureKind.incomplete,
        message: composed.message,
        code: composed.code,
        sent: true,
      ),
    );
  }

  void _onErrorEvent(Object? holder) {
    final Object? error = switch (holder) {
      {'error': final Map<Object?, Object?> error} => error,
      _ => holder,
    };
    final fields = switch (error) {
      {'code': final String code, 'param': final String param} => ErrorFields(
        code: code,
        param: param,
      ),
      {'code': final String code} => ErrorFields(code: code),
      _ => const ErrorFields(),
    };
    _fail(mapBackendError(_text, fields: fields));
  }

  Usage _usage(Object? response) {
    int? count(Object? value) => value is num ? value.toInt() : null;
    final usage = switch (response) {
      {'usage': final Map<Object?, Object?> usage} => usage,
      _ => const <Object?, Object?>{},
    };
    Object? nested(String group, String key) => switch (usage[group]) {
      final Map<Object?, Object?> map => map[key],
      _ => null,
    };
    return Usage(
      input: count(usage['input_tokens']),
      cachedInput: count(nested('input_tokens_details', 'cached_tokens')),
      output: count(usage['output_tokens']),
      reasoning: count(nested('output_tokens_details', 'reasoning_tokens')),
    );
  }
}
