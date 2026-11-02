import 'dart:convert';
import 'dart:io';

import 'package:kehai/src/auth/credential_store.dart';
import 'package:kehai/src/auth/failure_text.dart';
import 'package:kehai/src/auth/openai_constants.dart';
import 'package:kehai/src/auth/refresher.dart';
import 'package:kehai/src/provider/chatgpt_adapter.dart';
import 'package:kehai/src/provider/chatgpt_request.dart';
import 'package:kehai/src/config/user_config.dart';
import 'package:kehai/src/provider/provider.dart';
import 'package:test/test.dart';

const _request = ModelRequest(
  model: 'gpt-fake',
  instructions: 'brief',
  items: [UserMessage('hi')],
  tools: [],
  sessionId: 'compaction-test',
);

Map<String, Object?> _compact(String id, [String encrypted = 'secret']) => {
  'type': 'compaction',
  'id': id,
  'encrypted_content': encrypted,
  'extra': {
    'preserve': [1, true, null],
  },
};
Map<String, Object?> _item(Object item, [int? index]) => {
  'type': 'response.output_item.done',
  'item': item,
  'output_index': ?index,
};
const _completed = {
  'type': 'response.completed',
  'response': {'output': <Object?>[]},
};
Map<String, Object?> _message(String id, String text) => {
  'type': 'message',
  'id': id,
  'role': 'assistant',
  'content': [
    {'type': 'output_text', 'text': text},
  ],
};

void main() {
  late Directory tmp;
  late HttpServer server;
  late ChatGptAdapter adapter;
  var script = <Map<String, Object?>>[];
  var requests = 0;

  setUp(() async {
    // Keep all credential fixture writes inside the checkout.
    tmp = Directory('.dart_tool').createTempSync('compaction-test-');
    if (!Platform.isWindows) Process.runSync('chmod', ['700', tmp.path]);
    final now = DateTime.now().toUtc();
    final store = CredentialStore(home: '${tmp.path}/home')
      ..replace(
        CredentialRecord(
          hostId: 'urn:uuid:11111111-2222-3333-4444-555555555555',
          generation: 1,
          registration: const CredentialRegistration(
            issuer: 'https://auth.openai.com',
            clientId: 'client',
            subject: 'user',
            email: 'test@example.com',
            plan: 'plus',
            planUsageEnabled: true,
          ),
          tokens: CredentialTokens(
            idToken: 'id',
            accessToken: 'access',
            refreshToken: 'refresh',
            expiresAt: now.add(const Duration(hours: 1)),
            scopes: const ['openid', 'offline_access', openAiPlanUsageScope],
            savedAt: now,
            lastRefresh: now,
          ),
        ),
      );
    script = [];
    requests = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      await request.drain<void>();
      // Deliberately no Content-Type, as in the observed route response.
      for (final event in script) {
        request.response.write('data: ${jsonEncode(event)}\n\n');
      }
      await request.response.close();
    });
    adapter = ChatGptAdapter(
      refresher: Refresher(store: store),
      apiBase: 'http://127.0.0.1:${server.port}/v1',
    );
  });
  tearDown(() async {
    await server.close(force: true);
    tmp.deleteSync(recursive: true);
  });

  Future<List<ProviderEvent>> run() => adapter.stream(_request).toList();
  List<CompactionItem> compactions(List<ProviderEvent> events) =>
      events.whereType<CompactionItem>().toList();
  void protocol(List<ProviderEvent> events) {
    expect(events.last, isA<Failed>());
    final failure = (events.last as Failed).failure;
    expect(failure.kind, FailureKind.protocol);
    expect(failure.message, isNot(contains('secret')));
    expect(events.whereType<ToolCall>(), isEmpty);
    expect(events.whereType<Completed>(), isEmpty);
    expect(requests, 1);
  }

  test('model-provider: Compacted token-sharing body', () {
    final compact = _compact('boundary');
    final body = buildChatGptBody(
      ModelRequest(
        model: _request.model,
        instructions: _request.instructions,
        items: [OpaqueCompactionItem(compact), const UserMessage('suffix')],
        tools: const [
          ToolSpec(
            name: 'read',
            description: 'read',
            parametersJsonSchema: {'type': 'object'},
          ),
        ],
        sessionId: _request.sessionId,
        nativeCompaction: const NativeCompactionPolicy(threshold: 100000),
      ),
    );
    expect(body['context_management'], [
      {'type': 'compaction', 'compact_threshold': 100000},
    ]);
    expect(body.keys, everyElement(isIn(chatGptBodyKeys)));
    final input = body['input'] as List<Object?>;
    expect((input.first as Map)['type'], 'additional_tools');
    expect(input[1], compact);
    expect(input, hasLength(3));
    expect(body['instructions'], 'brief');
    expect(body['store'], false);
    expect(body['stream'], true);
    expect(body['include'], ['reasoning.encrypted_content']);
    for (final forbidden in [
      'tools',
      'previous_response_id',
      'background',
      'conversation',
      'max_output_tokens',
      'max_tool_calls',
      'metadata',
      'moderation',
      'multi_agent',
      'prompt',
      'prompt_cache_retention',
      'safety_identifier',
      'temperature',
      'top_logprobs',
      'top_p',
      'truncation',
      'user',
    ]) {
      expect(body.containsKey(forbidden), false, reason: forbidden);
    }
    expect(buildChatGptBody(_request), isNot(contains('context_management')));
    expect(
      encodeChatGptBody(
        buildChatGptBody(
          ModelRequest(
            model: 'fake',
            instructions: '',
            items: [
              OpaqueCompactionItem(
                _compact('large', 'x' * openAiMaxRequestBodyBytes),
              ),
            ],
            tools: [],
            sessionId: 's',
          ),
        ),
      ),
      isNull,
    );
  });

  test('model-provider: Generic metadata is not route capacity', () {
    const model = ModelInfo(
      id: 'gpt-6.1-sol',
      name: 'GPT',
      contextWindow: 500000,
    );
    const config = UserConfig();
    final capacity = config.resolveCapacity(
      'openai',
      'chatgpt-account',
      model.id,
      backendContextWindow: model.contextWindow,
    );
    expect(capacity.backendContextWindow, 500000);
    expect(capacity.contextWindow, isNull);
    expect(capacity.source, 'unknown');
  });

  test('model-provider: Headerless completion with empty output', () async {
    script = [
      _item(_compact('last'), 2),
      _item(_message('message', 'READY'), 1),
      _item(_compact('first'), 0),
      _completed,
    ];
    final events = await run();
    expect(compactions(events), hasLength(2));
    expect(compactions(events).map((e) => e.outputIndex), [0, 2]);
    expect(compactions(events).map((e) => e.json), [
      _compact('first'),
      _compact('last'),
    ]);
    expect(events.whereType<TextDelta>().map((e) => e.text), ['READY']);
    expect(events, [
      isA<CompactionItem>(),
      isA<TextDelta>(),
      isA<CompactionItem>(),
      isA<Usage>(),
      isA<Completed>(),
    ]);
    expect(events.last, isA<Completed>());
  });

  test('model-provider: Compaction before interrupted stream', () async {
    for (final terminal in [
      <Map<String, Object?>>[],
      [
        {'type': 'response.incomplete', 'response': <String, Object?>{}},
      ],
      [
        {'type': 'response.failed', 'response': <String, Object?>{}},
      ],
    ]) {
      script = [
        _item(_compact('candidate'), 0),
        _item({
          'type': 'function_call',
          'call_id': 'call',
          'name': 'tool',
          'arguments': '{}',
        }, 1),
        ...terminal,
      ];
      final events = await run();
      expect(events.last, isA<Failed>());
      expect(events.whereType<ToolCall>(), isEmpty);
      expect(events.whereType<Completed>(), isEmpty);
    }
  });

  test('model-provider: Duplicate or conflicting item', () async {
    script = [
      _item(_compact('same'), 0),
      _item(_compact('same'), 0),
      _completed,
    ];
    expect(compactions(await run()), hasLength(1));
    for (final conflict in [
      _item(_compact('same', 'secret-conflict'), 0),
      _item(_compact('other'), 0),
      _item(_compact('same'), 1),
      _item(_message('same', 'text'), 0),
      _item(_message('other', 'text'), 0),
    ]) {
      requests = 0;
      script = [_item(_compact('same'), 0), conflict, _completed];
      protocol(await run());
    }
  });

  test(
    'malformed or unindexed compaction is a sanitized protocol failure',
    () async {
      for (final event in [
        _item({'type': 'compaction', 'encrypted_content': 'secret'}, 0),
        _item({'type': 'compaction', 'id': 'c'}, 0),
        _item({
          'type': 'compaction',
          'id': '',
          'encrypted_content': 'secret',
        }, 0),
        _item({'type': 'compaction', 'id': 'c', 'encrypted_content': 4}, 0),
        _item(_compact('c')),
        {..._item(_compact('c')), 'output_index': -1},
      ]) {
        requests = 0;
        script = [event, _completed];
        protocol(await run());
      }
    },
  );

  test('message done fallback and delta/done semantic deduplication', () async {
    script = [
      {'type': 'response.output_text.delta', 'output_index': 0, 'delta': 'hel'},
      {'type': 'response.output_text.delta', 'output_index': 0, 'delta': 'lo'},
      _item(_message('m0', 'hello'), 0),
      _item(_message('m0', 'hello'), 0),
      _item(_message('m1', ' fallback'), 1),
      _item(_message('m1', ' fallback'), 1),
      _completed,
    ];
    final events = await run();
    expect(
      events.whereType<TextDelta>().map((e) => e.text).join(),
      'hello fallback',
    );
    expect(events.last, isA<Completed>());
  });

  test(
    'unidentified deltas suppress only their following done message',
    () async {
      for (final indexed in [true, false]) {
        script = [
          {'type': 'response.output_text.delta', 'delta': 'hello'},
          _item(_message('m0', 'hello'), indexed ? 0 : null),
          _item(_message('m1', ' fallback'), indexed ? 1 : null),
          _completed,
        ];
        final events = await run();
        expect(
          events.whereType<TextDelta>().map((e) => e.text).join(),
          'hello fallback',
        );
      }
    },
  );

  test(
    'encrypted output and identical copies all consume aggregate cap',
    () async {
      final compact = _item(_compact('c', 'x' * (1024 * 1024)), 0);
      script = [compact, compact, compact, compact, _completed];
      final events = await run();
      protocol(events);
      expect((events.last as Failed).failure.code, 'response_output_limit');
    },
  );
}
