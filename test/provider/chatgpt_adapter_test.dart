import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/src/auth/credential_store.dart';
import 'package:kehai/src/auth/dpapi_backend.dart';
import 'package:kehai/src/auth/failure_text.dart';
import 'package:kehai/src/auth/openai_constants.dart';
import 'package:kehai/src/auth/posix_file_backend.dart';
import 'package:kehai/src/auth/refresher.dart';
import 'package:kehai/src/provider/chatgpt_adapter.dart';
import 'package:kehai/src/provider/chatgpt_request.dart';
import 'package:kehai/src/provider/provider.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_openai.dart';

const _hostId = 'urn:uuid:11111111-2222-3333-4444-555555555555';
const _day = Duration(days: 1);

CredentialRegistration _registration({bool planUsage = true}) =>
    CredentialRegistration(
      issuer: 'https://auth.openai.com',
      clientId: 'client-xyz',
      subject: 'user-123',
      email: 'user-123@example.com',
      plan: 'plus',
      planUsageEnabled: planUsage,
    );

CredentialRecord _record({bool planUsage = true, bool tokens = true}) {
  final now = DateTime.now().toUtc();
  return CredentialRecord(
    hostId: _hostId,
    generation: 7,
    registration: _registration(planUsage: planUsage),
    tokens: tokens
        ? CredentialTokens(
            idToken: 'old-id-token',
            accessToken: 'old-access',
            refreshToken: 'old-refresh',
            expiresAt: now.add(const Duration(minutes: 30)),
            scopes: const ['openid', 'offline_access', openAiPlanUsageScope],
            savedAt: now.subtract(_day),
            lastRefresh: now.subtract(const Duration(hours: 1)),
          )
        : null,
  );
}

ModelRequest _request({
  List<ConversationItem> items = const [UserMessage('hello')],
  List<ToolSpec> tools = const [],
  String? effort,
}) => ModelRequest(
  model: 'gpt-fake',
  instructions: 'be brief',
  items: items,
  tools: tools,
  sessionId: 'session-1',
  reasoningEffort: effort,
);

String _show(ProviderEvent event) => switch (event) {
  TextDelta(:final text) => 'text:$text',
  ReasoningSummaryDelta(:final text) => 'summary:$text',
  ToolCall(:final callId, :final name, :final argumentsJson) =>
    'call:$callId:$name:$argumentsJson',
  OpaqueItem() => 'opaque',
  Usage(:final input, :final cachedInput, :final output, :final reasoning) =>
    'usage:$input/$cachedInput/$output/$reasoning',
  Completed(:final stop) => 'completed:${stop.wire}',
  Failed(:final failure) => 'failed:${failure.kind.wire}',
};

List<String> _shown(List<ProviderEvent> events) => events.map(_show).toList();

ProviderFailure _failure(List<ProviderEvent> events) =>
    (events.last as Failed).failure;

ScriptStep _fn(String callId, String name, String args) =>
    SseEvent.json('response.output_item.done', {
      'item': {
        'type': 'function_call',
        'call_id': callId,
        'name': name,
        'arguments': args,
      },
    });

ScriptStep _completed([Map<String, Object?>? usage]) =>
    SseEvent.json('response.completed', {
      'response': {'id': 'resp_1', 'usage': ?usage},
    });

/// A server that sends one event and then holds the connection open, so a test
/// can see the client close it.
final class _HoldingServer {
  _HoldingServer._(this._server);

  static Future<_HoldingServer> start() async {
    final server = _HoldingServer._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    server._server.listen(server._handle);
    addTearDown(server.close);
    return server;
  }

  final HttpServer _server;
  final List<Socket> _sockets = [];
  final Completer<void> closed = Completer<void>();
  int requests = 0;

  String get apiBase => 'http://127.0.0.1:${_server.port}/v1';

  Future<void> _handle(HttpRequest request) async {
    requests++;
    await request.drain<void>();
    final socket = await request.response.detachSocket(writeHeaders: false);
    _sockets.add(socket);
    const payload =
        'event: response.output_text.delta\n'
        'data: {"type":"response.output_text.delta","delta":"hi"}\n\n';
    socket
      ..add(
        utf8.encode(
          'HTTP/1.1 200 OK\r\ncontent-type: text/event-stream\r\n'
          'transfer-encoding: chunked\r\n\r\n',
        ),
      )
      ..add(utf8.encode('${payload.length.toRadixString(16)}\r\n$payload\r\n'));
    await socket.flush();
    void done() {
      if (!closed.isCompleted) closed.complete();
    }

    socket.listen((_) {}, onDone: done, onError: (Object _) => done());
  }

  Future<void> close() async {
    for (final socket in _sockets) {
      socket.destroy();
    }
    await _server.close(force: true);
  }
}

void main() {
  late Directory tmp;
  late CredentialStore store;
  late FakeOpenAi fake;
  late Refresher refresher;
  late ChatGptAdapter adapter;

  ChatGptAdapter makeAdapter({
    String? apiBase,
    Duration silence = const Duration(seconds: 5),
    Duration connect = const Duration(seconds: 5),
  }) => ChatGptAdapter(
    refresher: refresher,
    apiBase: apiBase ?? fake.apiBase,
    silenceDeadline: silence,
    connectTimeout: connect,
  );

  Future<List<ProviderEvent>> run(
    ModelRequest request, {
    CancelToken? cancel,
  }) => adapter
      .stream(request, cancel: cancel)
      .toList()
      .timeout(const Duration(seconds: 20));

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('kehai_adapter_');
    if (!Platform.isWindows) Process.runSync('chmod', ['700', tmp.path]);
    store = CredentialStore(home: p.join(tmp.path, 'home'))..replace(_record());
    fake = await FakeOpenAi.start();
    refresher = Refresher(store: store, issuer: fake.issuer);
    adapter = makeAdapter();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('normalized stream', () {
    test('text deltas then usage then completed end_turn', () async {
      fake.responsesScripts.add(
        ResponsesScript.sse([
          SseEvent.json('response.output_text.delta', {'delta': 'he'}),
          SseEvent.json('response.output_text.delta', {'delta': 'llo'}),
          SseEvent.json('response.reasoning_summary_text.delta', {
            'delta': 'thinking',
          }),
          SseComment(),
          SseEvent.json('response.unknown_future_event', {'x': 1}),
          _completed({'input_tokens': 10, 'output_tokens': 5}),
        ]),
      );

      final events = await run(_request());

      expect(_shown(events), [
        'text:he',
        'text:llo',
        'summary:thinking',
        'usage:10/null/5/null',
        'completed:end_turn',
      ]);
    });

    test('early close ends with protocol failure', () async {
      fake.responsesScripts.add(
        ResponsesScript.sse([
          SseEvent.json('response.output_text.delta', {'delta': 'hi'}),
        ]),
      );

      final events = await run(_request());

      expect(_shown(events), ['text:hi', 'failed:protocol']);
      expect(_failure(events).sent, isTrue);
    });

    test('events after the terminal event are dropped', () async {
      fake.responsesScripts.add(
        ResponsesScript.sse([
          _completed(),
          SseEvent.json('response.output_text.delta', {'delta': 'late'}),
          _fn('c1', 'late', '{}'),
        ]),
      );

      final events = await run(_request());

      expect(_shown(events), [
        'usage:null/null/null/null',
        'completed:end_turn',
      ]);
    });
  });

  group('tool calls', () {
    test(
      'two function calls emit two complete tool calls and tool_use',
      () async {
        fake.responsesScripts.add(
          ResponsesScript.sse([
            _fn('call_a', 'read', '{"path":"a"}'),
            SseEvent.json('response.output_text.delta', {'delta': 'x'}),
            _fn('call_b', 'grep', '{"q":"b"}'),
            _fn('call_a', 'read', '{"path":"dup"}'),
            _completed({'input_tokens': 3, 'output_tokens': 4}),
          ]),
        );

        final events = await run(_request());

        expect(_shown(events), [
          'text:x',
          'call:call_a:read:{"path":"a"}',
          'call:call_b:grep:{"q":"b"}',
          'usage:3/null/4/null',
          'completed:tool_use',
        ]);
      },
    );

    test('tool call and output are sent paired by call id', () async {
      fake.responsesScripts.add(ResponsesScript.sse(sseTextTurn('done')));
      const tool = ToolSpec(
        name: 'read',
        description: 'reads',
        parametersJsonSchema: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
          },
        },
      );

      await run(
        _request(
          tools: const [tool],
          items: const [
            UserMessage('go'),
            AssistantMessage('calling'),
            ToolCallItem(
              callId: 'call_a',
              name: 'read',
              argumentsJson: '{"path":"a"}',
            ),
            ToolOutputItem(callId: 'call_a', output: 'contents'),
          ],
        ),
      );

      final body = fake.responsesRequests.single.json!;
      expectAdditionalToolsOnly(body);
      final input = (body['input'] as List<Object?>)
          .cast<Map<String, Object?>>();
      expect(input.first['tools'], [
        {
          'type': 'function',
          'name': 'read',
          'description': 'reads',
          'parameters': tool.parametersJsonSchema,
          'strict': false,
        },
      ]);
      expect(input.skip(1).toList(), [
        {
          'type': 'message',
          'role': 'user',
          'content': [
            {'type': 'input_text', 'text': 'go'},
          ],
        },
        {
          'type': 'message',
          'role': 'assistant',
          'content': [
            {'type': 'output_text', 'text': 'calling'},
          ],
        },
        {
          'type': 'function_call',
          'call_id': 'call_a',
          'name': 'read',
          'arguments': '{"path":"a"}',
        },
        {
          'type': 'function_call_output',
          'call_id': 'call_a',
          'output': 'contents',
        },
      ]);
    });

    test('finished function call then drop emits no tool call and fails '
        'network', () async {
      fake.responsesScripts.add(
        ResponsesScript.sse([_fn('call_a', 'read', '{}'), const Drop()]),
      );

      final events = await run(_request());

      expect(_shown(events), ['failed:network']);
      expect(_failure(events).sent, isTrue);
    });

    test('malformed arguments pass through unchanged', () async {
      fake.responsesScripts.add(
        ResponsesScript.sse([_fn('call_a', 'read', '{"a":'), _completed()]),
      );

      final events = await run(_request());

      expect(_shown(events).first, 'call:call_a:read:{"a":');
      expect(_shown(events).last, 'completed:tool_use');
    });

    test('more than 128 held calls fail protocol', () async {
      fake.responsesScripts.add(
        ResponsesScript.sse([
          for (var i = 0; i < 129; i++) _fn('call_$i', 'read', '{}'),
          _completed(),
        ]),
      );

      final events = await run(_request());

      expect(_shown(events), ['failed:protocol']);
      expect(
        _failure(events).message,
        matches(RegExp('too many tool calls', caseSensitive: false)),
      );
    });
  });

  group('incomplete', () {
    test('incomplete after text yields usage then failed incomplete with '
        'reason', () async {
      fake.responsesScripts.add(
        ResponsesScript.sse([
          SseEvent.json('response.output_text.delta', {'delta': 'cut'}),
          SseEvent.json('response.incomplete', {
            'response': {
              'incomplete_details': {'reason': 'max_output_tokens'},
              'usage': {'input_tokens': 8, 'output_tokens': 2},
            },
          }),
        ]),
      );

      final events = await run(_request());

      expect(_shown(events), [
        'text:cut',
        'usage:8/null/2/null',
        'failed:incomplete',
      ]);
      expect(_failure(events).code, 'max_output_tokens');
    });

    test('incomplete after function call emits no tool call', () async {
      fake.responsesScripts.add(
        ResponsesScript.sse([
          _fn('call_a', 'read', '{}'),
          SseEvent.json('response.incomplete', {
            'response': {
              'incomplete_details': {'reason': 'content_filter'},
            },
          }),
        ]),
      );

      final events = await run(_request());

      expect(_shown(events), [
        'usage:null/null/null/null',
        'failed:incomplete',
      ]);
      expect(_failure(events).code, 'content_filter');
    });
  });

  group('reasoning', () {
    final item = <String, Object?>{
      'type': 'reasoning',
      'id': 'rs_1',
      'encrypted_content': 'abc==',
      'summary': <Object?>[],
    };

    test('reasoning item is forwarded byte-identical', () async {
      fake.responsesScripts
        ..add(
          ResponsesScript.sse([
            SseEvent.json('response.output_item.done', {'item': item}),
            _completed(),
          ]),
        )
        ..add(ResponsesScript.sse(sseTextTurn('ok')));

      final first = await run(_request());
      final opaque = first.whereType<OpaqueItem>().single;
      expect(jsonEncode(opaque.json), jsonEncode(item));

      await run(
        _request(
          items: [const UserMessage('hello'), OpaqueReasoningItem(opaque.json)],
        ),
      );

      expect(
        fake.responsesRequests.last.body,
        contains(',${jsonEncode(item)}'),
      );
    });

    test('no reasoning item emits no opaque event', () async {
      fake.responsesScripts.add(ResponsesScript.sse(sseTextTurn('plain')));
      final events = await run(_request());
      expect(events.whereType<OpaqueItem>(), isEmpty);
    });
  });

  group('usage', () {
    test('usage maps input cached output and reasoning', () async {
      fake.responsesScripts.add(
        ResponsesScript.sse([
          _completed({
            'input_tokens': 100,
            'input_tokens_details': {'cached_tokens': 40},
            'output_tokens': 20,
            'output_tokens_details': {'reasoning_tokens': 7},
          }),
        ]),
      );
      final events = await run(_request());
      expect(_shown(events)[0], 'usage:100/40/20/7');
    });

    test('missing usage yields unknown counts', () async {
      fake.responsesScripts.add(ResponsesScript.sse([_completed()]));
      final events = await run(_request());
      expect(_shown(events), [
        'usage:null/null/null/null',
        'completed:end_turn',
      ]);
    });
  });

  group('typed failures', () {
    test('context_length_exceeded maps to context_overflow', () async {
      fake.responsesScripts.add(
        ResponsesScript.errorCode(400, 'context_length_exceeded'),
      );
      final events = await run(_request());
      expect(_shown(events), ['failed:context_overflow']);
      expect(_failure(events).code, 'context_length_exceeded');
    });

    test('sharing usage limit codes map to usage_limit in http and event form '
        'without retry-after', () async {
      for (final code in openAiUsageLimitCodes) {
        fake.responsesScripts
          ..add(
            ResponsesScript.errorCode(
              429,
              code,
              headers: {'retry-after': '30'},
            ),
          )
          ..add(
            ResponsesScript.sse([
              SseEvent.json('response.failed', {
                'response': {
                  'error': {'code': code, 'message': 'x'},
                },
              }),
            ]),
          )
          ..add(
            ResponsesScript.sse([
              SseEvent.json('error', {'code': code, 'message': 'x'}),
            ]),
          );
        for (var i = 0; i < 3; i++) {
          final events = await run(_request());
          expect(_shown(events), ['failed:usage_limit'], reason: '$code $i');
          expect(_failure(events).retryAfter, isNull);
          expect(_failure(events).code, code);
        }
      }
    });

    test('403 and eligibility codes map to not_permitted', () async {
      final scripts = [
        ResponsesScript.error(403, '{"detail":"nope"}'),
        for (final code in openAiNotPermittedCodes)
          ResponsesScript.errorCode(403, code),
      ];
      for (final script in scripts) {
        fake.responsesScripts.add(script);
        final events = await run(_request());
        expect(_shown(events), ['failed:not_permitted']);
        expect(_failure(events).status, 403);
      }
      expect(fake.responsesRequests, hasLength(scripts.length));
    });

    test(
      '503 and unavailable codes map to server and keep credentials',
      () async {
        final scripts = [
          ResponsesScript.errorCode(503, 'anything'),
          for (final code in openAiUnavailableCodes)
            ResponsesScript.errorCode(503, code),
          ResponsesScript.errorCode(502, 'bad_gateway'),
        ];
        for (final script in scripts) {
          fake.responsesScripts.add(script);
          final events = await run(_request());
          expect(_shown(events), ['failed:server']);
        }
        expect(store.load()!.tokens!.accessToken, 'old-access');
        expect(fake.tokenRequests, isEmpty);
      },
    );

    test('unsupported_capability maps to invalid_request with param', () async {
      fake.responsesScripts.add(
        ResponsesScript.errorCode(
          400,
          openAiUnsupportedCapabilityCode,
          param: 'input[0]',
        ),
      );
      final events = await run(_request());
      expect(_shown(events), ['failed:invalid_request']);
      expect(_failure(events).param, 'input[0]');
      expect(_failure(events).message, contains('input[0]'));
    });

    test('plain 429 maps to rate_limited with retry-after', () async {
      fake.responsesScripts.add(
        ResponsesScript.errorCode(
          429,
          'rate_limit_exceeded',
          headers: {'retry-after': '7'},
        ),
      );
      final events = await run(_request());
      expect(_shown(events), ['failed:rate_limited']);
      expect(_failure(events).retryAfter, const Duration(seconds: 7));
    });

    test('html and detail bodies are excluded from the failure', () async {
      fake.responsesScripts
        ..add(
          const ResponsesScript.error(
            500,
            '<html>SECRET-HTML</html>',
            contentType: 'text/html',
          ),
        )
        ..add(const ResponsesScript.error(400, '{"detail":"SECRET-DETAIL"}'))
        ..add(
          ResponsesScript.error(
            500,
            jsonEncode({
              'error': {'code': 'Bad Code!', 'message': 'SECRET-MESSAGE'},
            }),
          ),
        );

      final html = await run(_request());
      final detail = await run(_request());
      final odd = await run(_request());

      expect(_shown(html), ['failed:server']);
      expect(_shown(detail), ['failed:invalid_request']);
      expect(_shown(odd), ['failed:server']);
      for (final events in [html, detail, odd]) {
        expect(_failure(events).message, isNot(contains('SECRET')));
        expect(
          _failure(events).message.length,
          lessThanOrEqualTo(maxFailureMessageLength),
        );
      }
      expect(_failure(html).code, isNull);
      expect(_failure(detail).code, isNull);
      expect(_failure(odd).code, unrecognizedCode);
    });
  });

  group('no automatic resend', () {
    test('mid-stream drop fails network sent and sends nothing more', () async {
      fake.responsesScripts.add(
        ResponsesScript.sse([
          SseEvent.json('response.output_text.delta', {'delta': 'a'}),
          const Drop(),
        ]),
      );

      final events = await run(_request());
      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(_shown(events), ['text:a', 'failed:network']);
      expect(_failure(events).sent, isTrue);
      expect(fake.responsesRequests, hasLength(1));
    });

    test('dropped connection before headers fails network sent', () async {
      fake.responsesScripts.add(const ResponsesScript.dropBeforeHeaders());
      final events = await run(_request());
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(_shown(events), ['failed:network']);
      expect(_failure(events).sent, isTrue);
      expect(fake.responsesRequests, hasLength(1));
    });

    test(
      'refused connection fails network not sent and does not retry',
      () async {
        final probe = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final port = probe.port;
        await probe.close(force: true);
        adapter = makeAdapter(apiBase: 'http://127.0.0.1:$port/v1');

        final events = await run(_request());

        expect(_shown(events), ['failed:network']);
        expect(_failure(events).sent, isFalse);
        expect(fake.responsesRequests, isEmpty);
      },
    );
  });

  group('cancellation and idle deadline', () {
    test('cancel token aborts and ends with cancelled', () async {
      final server = await _HoldingServer.start();
      adapter = makeAdapter(apiBase: server.apiBase);
      final cancel = CancelToken();
      final events = <ProviderEvent>[];
      final done = Completer<void>();

      adapter.stream(_request(), cancel: cancel).listen((event) {
        events.add(event);
        if (event is TextDelta) cancel.cancel();
      }, onDone: done.complete);
      await done.future.timeout(const Duration(seconds: 10));
      await server.closed.future.timeout(const Duration(seconds: 10));

      expect(_shown(events), ['text:hi', 'failed:cancelled']);
      expect(_failure(events).sent, isTrue);
    });

    test('an already cancelled token sends nothing', () async {
      final cancel = CancelToken()..cancel();
      final events = await run(_request(), cancel: cancel);
      expect(_shown(events), ['failed:cancelled']);
      expect(fake.responsesRequests, isEmpty);
    });

    test('subscription cancel closes the connection', () async {
      final server = await _HoldingServer.start();
      adapter = makeAdapter(apiBase: server.apiBase);
      final events = <ProviderEvent>[];
      final first = Completer<void>();

      final subscription = adapter.stream(_request()).listen((event) {
        events.add(event);
        if (!first.isCompleted) first.complete();
      });
      await first.future.timeout(const Duration(seconds: 10));
      await subscription.cancel();
      await server.closed.future.timeout(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(_shown(events), ['text:hi']);
    });

    test('stalled backend ends with idle_timeout', () async {
      adapter = makeAdapter(silence: const Duration(milliseconds: 300));
      fake.responsesScripts.add(
        ResponsesScript.sse([
          SseEvent.json('response.output_text.delta', {'delta': 'a'}),
          const Delay(Duration(minutes: 1)),
        ]),
      );

      final events = await run(_request());

      expect(_shown(events), ['text:a', 'failed:idle_timeout']);
      expect(_failure(events).sent, isTrue);
    });

    test(
      'body read but no headers ends idle_timeout sent with one request',
      () async {
        adapter = makeAdapter(silence: const Duration(milliseconds: 300));
        fake.responsesScripts.add(
          const ResponsesScript.sse(
            [],
            stallBeforeHeaders: Duration(minutes: 1),
          ),
        );

        final events = await run(_request());

        expect(_shown(events), ['failed:idle_timeout']);
        expect(_failure(events).sent, isTrue);
        expect(fake.responsesRequests, hasLength(1));
      },
    );

    test(
      'sse headers without events ends idle_timeout with one request',
      () async {
        adapter = makeAdapter(silence: const Duration(milliseconds: 300));
        fake.responsesScripts.add(
          const ResponsesScript.sse([Delay(Duration(minutes: 1))]),
        );

        final events = await run(_request());

        expect(_shown(events), ['failed:idle_timeout']);
        expect(_failure(events).sent, isTrue);
        expect(fake.responsesRequests, hasLength(1));
      },
    );

    test('comments keep the deadline from firing', () async {
      adapter = makeAdapter(silence: const Duration(milliseconds: 400));
      fake.responsesScripts.add(
        ResponsesScript.sse([
          const Delay(Duration(milliseconds: 250)),
          SseComment(),
          const Delay(Duration(milliseconds: 250)),
          SseComment(),
          const Delay(Duration(milliseconds: 250)),
          ...sseTextTurn('ok'),
        ]),
      );
      final events = await run(_request());
      expect(_shown(events).last, 'completed:end_turn');
    });

    test(
      'subscriber paused beyond the deadline resumes and completes',
      () async {
        adapter = makeAdapter(silence: const Duration(milliseconds: 300));
        fake.responsesScripts.add(
          ResponsesScript.sse([
            SseEvent.json('response.output_text.delta', {'delta': 'a'}),
            const Delay(Duration(milliseconds: 200)),
            SseEvent.json('response.output_text.delta', {'delta': 'b'}),
            _completed(),
          ]),
        );
        final events = <ProviderEvent>[];
        final done = Completer<void>();
        late StreamSubscription<ProviderEvent> subscription;
        subscription = adapter.stream(_request()).listen((event) {
          events.add(event);
          if (event is TextDelta && event.text == 'a') {
            subscription.pause();
            Future<void>.delayed(
              const Duration(milliseconds: 1000),
              subscription.resume,
            );
          }
        }, onDone: done.complete);

        await done.future.timeout(const Duration(seconds: 10));

        expect(_shown(events), [
          'text:a',
          'text:b',
          'usage:null/null/null/null',
          'completed:end_turn',
        ]);
      },
    );
  });

  group('bounded input', () {
    test('2 MiB of deltas completes normally', () async {
      final chunk = 'x' * (64 * 1024);
      fake.responsesScripts.add(
        ResponsesScript.sse([
          for (var i = 0; i < 32; i++)
            SseEvent.json('response.output_text.delta', {'delta': chunk}),
          _completed(),
        ]),
      );

      final events = await run(_request());

      final text = events.whereType<TextDelta>().map((e) => e.text).join();
      expect(text.length, 2 * 1024 * 1024);
      expect(events.last, isA<Completed>());
    });

    test('an event over 8 MiB fails protocol', () async {
      fake.responsesScripts.add(
        ResponsesScript.sse([SseEvent.raw(data: 'x' * (8 * 1024 * 1024 + 1))]),
      );
      final events = await run(_request());
      expect(_shown(events), ['failed:protocol']);
      expect(_failure(events).message, contains('8 MiB'));
    });
  });

  group('plan backend', () {
    test('request targets v1 responses with bearer and sse accept', () async {
      fake.responsesScripts.add(ResponsesScript.sse(sseTextTurn('ok')));

      await run(_request());

      final sent = fake.responsesRequests.single;
      expect(sent.method, 'POST');
      expect(sent.path, '/v1/responses');
      expect(sent.headers['authorization'], 'Bearer old-access');
      expect(sent.headers['content-type'], startsWith('application/json'));
      expect(sent.headers['accept'], 'text/event-stream');
      expect(sent.headers['user-agent'], 'kehai/$kehaiVersion');
    });

    test('no token set without a disabled registration fails reauth_required '
        'without a request', () async {
      store.replace(_record(tokens: false));
      final tokenless = await run(_request());

      final bare = CredentialStore(home: p.join(tmp.path, 'empty'));
      refresher = Refresher(store: bare, issuer: fake.issuer);
      adapter = makeAdapter();
      final empty = await run(_request());

      expect(_shown(tokenless), ['failed:reauth_required']);
      expect(_shown(empty), ['failed:reauth_required']);
      expect(fake.responsesRequests, isEmpty);
    });

    test('a store failure after a rotating refresh fails reauth_required '
        'without a request', () async {
      void failRename() => throw const FileSystemException(
        'No space left on device',
        'auth.tmp',
        OSError('No space left on device', 28),
      );
      var armed = false;
      final failing = CredentialStore(
        home: p.join(tmp.path, 'disk'),
        backend: Platform.isWindows
            ? DpapiBackend(beforeRename: () => armed ? failRename() : null)
            : PosixFileBackend(beforeRename: () => armed ? failRename() : null),
      );
      final now = DateTime.now().toUtc();
      failing.replace(
        CredentialRecord(
          hostId: _hostId,
          generation: 7,
          registration: _registration(),
          tokens: CredentialTokens(
            idToken: 'old-id-token',
            accessToken: 'old-access',
            refreshToken: 'old-refresh',
            expiresAt: now.add(const Duration(minutes: 1)),
            scopes: const ['openid', 'offline_access', openAiPlanUsageScope],
            savedAt: now,
            lastRefresh: now,
          ),
        ),
      );
      armed = true;
      refresher = Refresher(store: failing, issuer: fake.issuer);
      adapter = makeAdapter();

      final events = await run(_request());

      expect(_shown(events), ['failed:reauth_required']);
      expect(fake.responsesRequests, isEmpty);
    });

    test(
      'disabled registration fails not_permitted without a request',
      () async {
        store.replace(_record(planUsage: false, tokens: false));
        final events = await run(_request());
        expect(_shown(events), ['failed:not_permitted']);
        expect(_failure(events).sent, isFalse);
        expect(fake.responsesRequests, isEmpty);
      },
    );

    test('plan usage disabled fails not_permitted without a request', () async {
      store.replace(_record(planUsage: false, tokens: false));
      final events = await run(_request());
      expect(_shown(events), ['failed:not_permitted']);
      expect(_failure(events).message, contains('--enable-plan-usage'));
      expect(fake.responsesRequests, isEmpty);
    });

    test('body over 1 MiB fails context_overflow without a request', () async {
      final events = await run(
        _request(items: [UserMessage('y' * (1024 * 1024 + 1))]),
      );
      expect(_shown(events), ['failed:context_overflow']);
      expect(_failure(events).sent, isFalse);
      expect(fake.responsesRequests, isEmpty);
    });

    test('body follows token-sharing rules with allowlisted keys', () async {
      fake.responsesScripts
        ..add(ResponsesScript.sse(sseTextTurn('a')))
        ..add(ResponsesScript.sse(sseTextTurn('b')));

      await run(_request(effort: 'high'));
      await run(_request());

      final withEffort = fake.responsesRequests[0].json!;
      final without = fake.responsesRequests[1].json!;
      expect(chatGptBodyKeys, containsAll(withEffort.keys));
      expect(withEffort, {
        'model': 'gpt-fake',
        'instructions': 'be brief',
        'input': [
          {
            'type': 'message',
            'role': 'user',
            'content': [
              {'type': 'input_text', 'text': 'hello'},
            ],
          },
        ],
        'tool_choice': 'auto',
        'parallel_tool_calls': true,
        'reasoning': {'effort': 'high', 'summary': 'auto'},
        'include': ['reasoning.encrypted_content'],
        'store': false,
        'stream': true,
        'prompt_cache_key': 'session-1',
      });
      expect(without['reasoning'], {'summary': 'auto'});
      expect(withEffort.containsKey('previous_response_id'), isFalse);
      expectAdditionalToolsOnly(withEffort, expectTools: false);
    });
  });

  group('credentials per request', () {
    test('logout during a stream lets it finish', () async {
      fake.responsesScripts.add(
        ResponsesScript.sse([
          SseEvent.json('response.output_text.delta', {'delta': 'a'}),
          const Delay(Duration(milliseconds: 300)),
          ...sseTextTurn('b'),
        ]),
      );
      final events = <ProviderEvent>[];
      final done = Completer<void>();
      adapter.stream(_request()).listen((event) {
        events.add(event);
        if (events.length == 1) store.replace(_record(tokens: false));
      }, onDone: done.complete);

      await done.future.timeout(const Duration(seconds: 10));
      final next = await run(_request());

      expect(_shown(events).first, 'text:a');
      expect(_shown(events).last, 'completed:end_turn');
      expect(_shown(next), ['failed:reauth_required']);
      expect(fake.responsesRequests, hasLength(1));
    });

    test('401 refreshes and repeats once', () async {
      fake.responsesScripts
        ..add(ResponsesScript.errorCode(401, openAiInvalidUserCode))
        ..add(ResponsesScript.sse(sseTextTurn('ok')));

      final events = await run(_request());

      expect(_shown(events).last, 'completed:end_turn');
      expect(fake.tokenRequests, hasLength(1));
      expect(fake.responsesRequests, hasLength(2));
      expect(fake.responsesRequests.map((r) => r.headers['authorization']), [
        'Bearer old-access',
        'Bearer access-1',
      ]);
    });

    test('second 401 is reauth_required and keeps tokens', () async {
      fake.responsesScripts
        ..add(ResponsesScript.errorCode(401, openAiInvalidUserCode))
        ..add(ResponsesScript.errorCode(401, openAiInvalidUserCode))
        ..add(ResponsesScript.sse(sseTextTurn('never')));

      final events = await run(_request());

      expect(_shown(events), ['failed:reauth_required']);
      expect(_failure(events).status, 401);
      expect(fake.responsesRequests, hasLength(2));
      expect(fake.tokenRequests, hasLength(1));
      expect(store.load()!.tokens, isNotNull);
    });
  });
}
