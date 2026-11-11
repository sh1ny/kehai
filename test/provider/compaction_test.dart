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
import 'package:kehai/kehai.dart'
    show
        SessionWriter,
        ResultStore,
        ToolRuntime,
        AllowAllStage,
        ExchangeDriver,
        SubmitAdmitted,
        SessionPath;

import '../support/session_support.dart';

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

const _readTools = [
  ToolSpec(
    name: 'read',
    description: 'read',
    parametersJsonSchema: {'type': 'object'},
  ),
];

void main() {
  test('model-provider: Tools re-established after a replayed boundary', () {
    final compact = _compact('selected');
    for (final policy in [
      null,
      const NativeCompactionPolicy(threshold: 100000),
    ]) {
      for (final tools in [<ToolSpec>[], _readTools]) {
        for (final suffix in [
          <ConversationItem>[],
          <ConversationItem>[
            const ToolCallItem(
              callId: 'call',
              name: 'read',
              argumentsJson: '{}',
            ),
            const ToolOutputItem(callId: 'call', output: 'verbatim result'),
            const UserMessage('continue'),
          ],
        ]) {
          final body = buildChatGptBody(
            ModelRequest(
              model: _request.model,
              instructions: _request.instructions,
              items: [OpaqueCompactionItem(compact), ...suffix],
              tools: tools,
              sessionId: _request.sessionId,
              nativeCompaction: policy,
            ),
          );
          final input = body['input'] as List;
          expect(input.first, compact);
          expect(
            input.whereType<Map<String, Object?>>().where(
              (i) => i['type'] == 'additional_tools',
            ),
            hasLength(tools.isEmpty ? 0 : 1),
          );
          if (tools.isNotEmpty) {
            expect(input[1], {
              'type': 'additional_tools',
              'role': 'developer',
              'tools': [
                {
                  'type': 'function',
                  'name': 'read',
                  'description': 'read',
                  'parameters': {'type': 'object'},
                  'strict': false,
                },
              ],
            });
          }
          final retained = input.skip(tools.isEmpty ? 1 : 2).toList();
          final uncompacted = buildChatGptBody(
            ModelRequest(
              model: _request.model,
              instructions: _request.instructions,
              items: suffix,
              tools: tools,
              sessionId: _request.sessionId,
            ),
          );
          final plain = uncompacted['input'] as List;
          if (tools.isNotEmpty) {
            expect((plain.first as Map)['type'], 'additional_tools');
          }
          expect(retained, plain.skip(tools.isEmpty ? 0 : 1).toList());
          expect(body['instructions'], _request.instructions);
          expect(body['tool_choice'], 'auto');
          expect(body, isNot(contains('tools')));
        }
      }
    }
  });

  late Directory tmp;
  late HttpServer server;
  late ChatGptAdapter adapter;
  var script = <Map<String, Object?>>[];
  var requests = 0;
  Map<String, Object?>? rejection;
  var rejectionStatus = HttpStatus.forbidden;
  final bodies = <Map<String, Object?>>[];
  var resetToolsAtCompaction = false;
  final registeredTools = <Set<String>>[];

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
    rejection = null;
    rejectionStatus = HttpStatus.forbidden;
    bodies.clear();
    resetToolsAtCompaction = false;
    registeredTools.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      requests++;
      bodies.add(
        jsonDecode(await utf8.decoder.bind(request).join())
            as Map<String, Object?>,
      );
      if (rejection != null) {
        request.response.statusCode = rejectionStatus;
        request.response.write(jsonEncode({'error': rejection}));
        await request.response.close();
        return;
      }
      if (resetToolsAtCompaction) {
        // Synthetic backend semantics: a boundary supersedes prior tool state.
        final names = <String>{};
        for (final item in bodies.last['input'] as List) {
          final value = item as Map;
          if (value['type'] == 'compaction') names.clear();
          if (value['type'] == 'additional_tools') {
            names.addAll([
              for (final tool in value['tools'] as List)
                (tool as Map)['name'] as String,
            ]);
          }
        }
        registeredTools.add(names);
        final text = names.contains('read') ? 'TOOLS_READY' : 'NO_TOOLS';
        request.response.write(
          'data: ${jsonEncode(_item(_message('registration', text), 0))}\n\n',
        );
        request.response.write('data: ${jsonEncode(_completed)}\n\n');
        await request.response.close();
        return;
      }
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

  test('offline backend resets tool registration at compaction', () async {
    resetToolsAtCompaction = true;
    for (final compacted in [false, true]) {
      final events = await adapter
          .stream(
            ModelRequest(
              model: _request.model,
              instructions: _request.instructions,
              items: [
                if (compacted) OpaqueCompactionItem(_compact('replayed')),
                const ToolCallItem(
                  callId: 'settled',
                  name: 'read',
                  argumentsJson: '{}',
                ),
                const ToolOutputItem(
                  callId: 'settled',
                  output: 'stored result',
                ),
                const UserMessage('use read again'),
              ],
              tools: _readTools,
              sessionId: _request.sessionId,
            ),
          )
          .toList();
      expect(events.last, isA<Completed>());
      expect(
        events.whereType<TextDelta>().map((e) => e.text).join(),
        'TOOLS_READY',
      );
      expect(registeredTools.last, {'read'});
    }
    expect(requests, 2);
  });

  test('403 param-only rejection durably disables native attempts', () async {
    rejection = {
      'code': 'forbidden',
      'param': 'context_management',
      'message': 'Request denied',
    };
    final dir = await tempDir();
    var writer = await SessionWriter.create(dir);
    addTearDown(() => writer.close());

    Future<void> attempt(String id) async {
      final runtime = await ToolRuntime.attach(
        writer,
        ResultStore(writer.sessionDir),
        workspace: writer.sessionDir,
        gate: const AllowAllStage(),
        config: const UserConfig(
          providers: {
            'openai': ProviderConfig(
              compaction: CompactionSettings(
                strategy: CompactionStrategy.providerNative,
              ),
            ),
          },
        ),
      );
      final driver = ExchangeDriver(
        writer: writer,
        runtime: runtime,
        provider: adapter,
        model: 'gpt-5.5',
      );
      try {
        final submitted = await driver.submit(
          id: id,
          text: 'go',
          turn: writer.currentTurn,
        ) as SubmitAdmitted;
        final result = await submitted.done;
        expect(result.state, 'stopped');
        expect(result.reason, contains('context_management rejected'));
      } finally {
        await driver.close();
        await runtime.close();
      }
    }

    await attempt('first');
    expect(requests, 1);
    expect(bodies.single, contains('context_management'));
    await writer.close();
    writer = await SessionWriter.open(writer.sessionDir);
    final steps = writer.tree.get(SessionPath.parse('body/steps')) as Map;
    final first = steps.values.single as Map;
    expect(first['capability'], {
      'state': 'unsupported',
      'reason': 'context_management rejected',
    });
    await attempt('after-reopen');
    expect(
      requests,
      1,
      reason: 'Unsupported evidence must prevent another send',
    );
  });

  test(
    'persists message-only native rejection without raw error text',
    () async {
      rejectionStatus = HttpStatus.badRequest;
      rejection = {
        'code': null,
        'param': null,
        'message': "Unknown parameter: 'context_management'. SECRET raw text",
      };
      var writer = await SessionWriter.create(await tempDir());
      addTearDown(() => writer.close());

      Future<void> attempt(String id) async {
        final runtime = await ToolRuntime.attach(
          writer,
          ResultStore(writer.sessionDir),
          workspace: writer.sessionDir,
          gate: const AllowAllStage(),
          config: const UserConfig(
            providers: {
              'openai': ProviderConfig(
                compaction: CompactionSettings(
                  strategy: CompactionStrategy.providerNative,
                ),
              ),
            },
          ),
        );
        final driver = ExchangeDriver(
          writer: writer,
          runtime: runtime,
          provider: adapter,
          model: 'gpt-5.5',
        );
        try {
          final submitted = await driver.submit(
            id: id,
            text: 'go',
            turn: writer.currentTurn,
          ) as SubmitAdmitted;
          final result = await submitted.done;
          expect(result.state, 'stopped');
          expect(result.reason, contains('context_management rejected'));
        } finally {
          await driver.close();
          await runtime.close();
        }
      }

      await attempt('first');
      expect(requests, 1);
      expect(bodies.single, contains('context_management'));
      await attempt('second');
      expect(requests, 1);
      await writer.close();
      writer = await SessionWriter.open(writer.sessionDir);
      final steps = writer.tree.get(SessionPath.parse('body/steps')) as Map;
      final first = steps.values.first as Map;
      expect(first['capability'], {
        'state': 'unsupported',
        'reason': 'context_management rejected',
      });
      expect(jsonEncode(steps), isNot(contains('SECRET')));
      expect(jsonEncode(steps), isNot(contains('Unknown parameter')));
      await attempt('after-reopen');
      expect(requests, 1);
    },
  );

  test('classifies message-only context management rejection', () async {
    rejectionStatus = HttpStatus.badRequest;
    for (final message in [
      "Unknown parameter: 'context_management'. SECRET",
      'context_management is not supported. SECRET',
    ]) {
      rejection = {'code': null, 'param': null, 'message': message};
      final failure = (await run()).whereType<Failed>().single.failure;
      expect(failure.kind, FailureKind.invalidRequest);
      expect(failure.param, 'context_management');
      expect(failure.message, isNot(contains('SECRET')));
      expect(failure.message, isNot(contains('Unknown parameter')));
    }
    for (final error in [
      {'message': 'context_management is supported'},
      {'message': 'Unknown parameter: reasoning_effort. context_management'},
      {'message': 'Do not reject context_management'},
      {
        'code': 'other_error',
        'message': "Unknown parameter: 'context_management'.",
      },
      {
        'param': 'reasoning_effort',
        'message': "Unknown parameter: 'context_management'.",
      },
    ]) {
      rejection = error;
      final failure = (await run()).whereType<Failed>().single.failure;
      expect(failure.param, isNot('context_management'), reason: '$error');
    }
    rejectionStatus = HttpStatus.internalServerError;
    rejection = {'message': "Unknown parameter: 'context_management'."};
    final serverFailure = (await run()).whereType<Failed>().single.failure;
    expect(serverFailure.kind, FailureKind.server);
    expect(serverFailure.param, isNull);
    rejection = null;
    script = [
      {
        'type': 'response.failed',
        'response': {
          'error': {
            'code': 'subscription_sharing_unsupported_capability',
            'param': 'context_management',
            'message': 'SECRET',
          },
        },
      },
    ];
    final eventFailure = (await run()).whereType<Failed>().single.failure;
    expect(eventFailure.kind, FailureKind.invalidRequest);
    expect(eventFailure.param, 'context_management');
    expect(eventFailure.message, isNot(contains('SECRET')));
    script = [
      {
        'type': 'error',
        'error': {'message': "Unknown parameter: 'context_management'. SECRET"},
      },
    ];
    final statusless = (await run()).whereType<Failed>().single.failure;
    expect(statusless.kind, FailureKind.server);
    expect(statusless.param, isNull);
    expect(statusless.message, isNot(contains('SECRET')));
  });

  test('rejects conflicting text ownership at compaction positions', () async {
    const text = {
      'type': 'response.output_text.delta',
      'item_id': 'message',
      'output_index': 0,
      'delta': 'before cut',
    };
    final scenarios = [
      [text, _item(_compact('boundary'), 0), _completed],
      [_item(_compact('boundary'), 0), text, _completed],
      [
        text,
        {...text, 'item_id': 'other-message'},
        _item(_compact('boundary'), 1),
        _completed,
      ],
      [
        text,
        _item(_message('other-message', 'conflicting message'), 0),
        _item(_compact('boundary'), 1),
        _completed,
      ],
      [
        _item(_compact('boundary'), 0),
        {
          'type': 'response.output_text.delta',
          'item_id': 'boundary',
          'delta': 'not message content',
        },
        _completed,
      ],
      [
        {
          'type': 'response.output_text.delta',
          'output_index': 0,
          'delta': 'anonymous indexed text',
        },
        _item(_compact('boundary'), 0),
        _completed,
      ],
      [
        text,
        _item({'type': 'reasoning', 'id': 'message'}, 0),
        _item(_compact('boundary'), 1),
        _completed,
      ],
    ];
    for (final events in scenarios) {
      requests = 0;
      script = events;
      final result = await run();
      protocol(result);
      expect(result.whereType<CompactionItem>(), isEmpty);
      expect(result.whereType<Completed>(), isEmpty);
    }
  });

  test('rejects unresolved output positions across compaction', () async {
    final scenarios = [
      [
        _item(_message('missing-index', 'before cut')),
        _item(_compact('boundary'), 1),
        _completed,
      ],
      [
        {
          'type': 'response.output_text.delta',
          'item_id': 'unknown',
          'delta': 'live text',
        },
        _item(_compact('boundary'), 1),
        _completed,
      ],
      [
        {'type': 'response.output_text.delta', 'delta': 'live text'},
        _item(_message('missing-index', 'live text')),
        _item(_compact('boundary'), 1),
        _completed,
      ],
      [
        _item({'type': 'reasoning', 'id': 'r'}),
        _item(_compact('boundary'), 1),
        _completed,
      ],
    ];
    for (final events in scenarios) {
      requests = 0;
      script = events;
      final result = await run();
      protocol(result);
      expect(result.whereType<CompactionItem>(), isEmpty);
      if (events.first['type'] == 'response.output_text.delta') {
        expect(result.whereType<TextDelta>().single.text, 'live text');
      }
    }

    script = [
      {
        'type': 'response.output_text.delta',
        'item_id': 'known',
        'output_index': 0,
        'delta': 'before cut',
      },
      _item(_message('known', 'before cut')),
      _item(_compact('boundary'), 1),
      _completed,
    ];
    final resolved = await run();
    expect(resolved.last, isA<Completed>());
    expect(resolved.whereType<CompactionItem>(), hasLength(1));
    expect(resolved.whereType<TextDelta>().single.outputIndex, 0);

    script = [
      {
        'type': 'response.output_text.delta',
        'item_id': 'known',
        'delta': 'before ',
      },
      {
        'type': 'response.output_text.delta',
        'item_id': 'known',
        'output_index': 0,
        'delta': 'cut',
      },
      _item(_message('known', 'before cut')),
      _item(_compact('boundary'), 1),
      _completed,
    ];
    final positioned = await run();
    expect(positioned.last, isA<Completed>());
    final firstDelta = positioned.whereType<TextDelta>().first;
    final position = positioned.whereType<TextDeltaPosition>().single;
    expect(identical(position.delta, firstDelta), isTrue);
    expect(position.outputIndex, 0);

    for (final indexedDone in [true, false]) {
      script = [
        {'type': 'response.output_text.delta', 'delta': 'first'},
        _item(_message('late-index', 'first')),
        if (indexedDone)
          _item(_message('late-index', 'first'), 0)
        else
          {
            'type': 'response.output_text.delta',
            'item_id': 'late-index',
            'output_index': 0,
            'delta': ' second',
          },
        _item(_compact('boundary'), 1),
        _completed,
      ];
      final latePosition = await run();
      expect(latePosition.last, isA<Completed>());
      final first = latePosition.whereType<TextDelta>().first;
      final update = latePosition.whereType<TextDeltaPosition>().single;
      expect(identical(update.delta, first), isTrue);
      expect(update.outputIndex, 0);
    }

    script = [
      {'type': 'response.output_text.delta', 'delta': 'first'},
      _item(_message('m0', 'first')),
      _item(_message('m1', 'second'), 1),
      _completed,
    ];
    final uncompacted = await run();
    expect(uncompacted.last, isA<Completed>());
    expect(uncompacted.whereType<TextDeltaPosition>(), isEmpty);
    expect(
      uncompacted.whereType<TextDelta>().map((event) => event.text).join(),
      'firstsecond',
    );
  });

  test('unresolved compaction output remains inactive after reopen', () async {
    for (final withDelta in [false, true]) {
      var writer = await SessionWriter.create(await tempDir());
      addTearDown(() => writer.close());
      script = [
        if (withDelta)
          {
            'type': 'response.output_text.delta',
            'item_id': 'unmatched',
            'delta': 'pre-cut-text',
          }
        else
          _item(_message('missing-index', 'pre-cut-text')),
        _item(_compact('secret-boundary'), 1),
        _completed,
      ];

      Future<String> submit(String id) async {
        final runtime = await ToolRuntime.attach(
          writer,
          ResultStore(writer.sessionDir),
          workspace: writer.sessionDir,
          gate: const AllowAllStage(),
        );
        final driver = ExchangeDriver(
          writer: writer,
          runtime: runtime,
          provider: adapter,
          model: 'gpt-5.5',
        );
        try {
          final admitted = await driver.submit(
            id: id,
            text: id,
            turn: writer.currentTurn,
          ) as SubmitAdmitted;
          return (await admitted.done).state;
        } finally {
          await driver.close();
          await runtime.close();
        }
      }

      expect(await submit('original'), 'failed');
      await writer.close();
      writer = await SessionWriter.open(writer.sessionDir);
      final stored =
          writer.tree.get(SessionPath.parse('body/steps/s-00000001')) as Map;
      expect(stored['state'], 'failed');
      expect((stored['failure'] as Map)['kind'], 'protocol');
      expect(stored['output'], isNull);
      if (withDelta) expect(stored['partial'], 'pre-cut-text');
      script = [_completed];
      expect(await submit('next'), 'done');
      final input = jsonEncode(bodies.last['input']);
      expect(input, contains('original'));
      expect(input, contains('next'));
      expect(input, isNot(contains('pre-cut-text')));
      expect(input, isNot(contains('secret-boundary')));
      expect(input, isNot(contains('"type":"compaction"')));
    }
  });

  test(
    'late anonymous text fails without corrupting persisted reconstruction',
    () async {
      var writer = await SessionWriter.create(await tempDir());
      addTearDown(() => writer.close());
      script = [
        _item(_message('m0', 'secret-late-text'), 0),
        {'type': 'response.output_text.delta', 'delta': 'secret-late-text'},
        _item(_compact('secret-boundary'), 1),
        _completed,
      ];

      Future<void> submit(String id, String expectedState) async {
        final runtime = await ToolRuntime.attach(
          writer,
          ResultStore(writer.sessionDir),
          workspace: writer.sessionDir,
          gate: const AllowAllStage(),
        );
        final driver = ExchangeDriver(
          writer: writer,
          runtime: runtime,
          provider: adapter,
          model: 'gpt-5.5',
        );
        try {
          final admitted = await driver.submit(
            id: id,
            text: id,
            turn: writer.currentTurn,
          ) as SubmitAdmitted;
          expect((await admitted.done).state, expectedState);
        } finally {
          await driver.close();
          await runtime.close();
        }
      }

      await submit('original-user-text', 'failed');
      expect(requests, 1);
      await writer.close();
      writer = await SessionWriter.open(writer.sessionDir);
      final stored =
          writer.tree.get(SessionPath.parse('body/steps/s-00000001')) as Map;
      expect(stored['state'], 'failed');
      final failure = stored['failure'] as Map;
      expect(failure['kind'], 'protocol');
      expect(failure['message'], isNot(contains('secret')));
      expect(stored['output'], isNull);
      expect(stored['partial'], isNull);
      script = [_completed];
      await submit('next-user-text', 'done');
      expect(requests, 2);
      final reconstructed = jsonEncode(bodies.last['input']);
      expect(reconstructed, contains('original-user-text'));
      expect(reconstructed, contains('next-user-text'));
      expect(reconstructed, isNot(contains('secret-late-text')));
      expect(reconstructed, isNot(contains('secret-boundary')));
      expect(reconstructed, isNot(contains('"type":"compaction"')));
    },
  );

  for (final identity in ['item-id', 'done-id-only', 'null-id']) {
    test(
      'SSE unindexed text is pre-cut on persisted rebuild ($identity)',
      () async {
        final writer = await SessionWriter.create(await tempDir());
        addTearDown(writer.close);
        final runtime = await ToolRuntime.attach(
          writer,
          ResultStore(writer.sessionDir),
          workspace: writer.sessionDir,
          gate: const AllowAllStage(),
        );
        addTearDown(runtime.close);
        final driver = ExchangeDriver(
          writer: writer,
          runtime: runtime,
          provider: adapter,
          model: 'gpt-5.5',
        );
        addTearDown(driver.close);
        final live = <String>[];
        final subscription = driver.deltas.listen((delta) {
          if (delta.kind == 'text') live.add(delta.delta);
        });
        addTearDown(subscription.cancel);
        final message = _message('m', 'before cut');
        if (identity == 'null-id') message['id'] = null;
        script = [
          {
            'type': 'response.output_text.delta',
            'delta': 'before ',
            if (identity == 'item-id') 'item_id': 'm',
          },
          {
            'type': 'response.output_text.delta',
            'delta': 'cut',
            if (identity == 'item-id') 'item_id': 'm',
          },
          _item(message, 0),
          _item(_compact('boundary'), 1),
          _completed,
        ];
        final first = await driver.submit(
          id: 'first',
          text: 'go',
          turn: writer.currentTurn,
        ) as SubmitAdmitted;
        expect((await first.done).state, 'done');
        expect(live, ['before ', 'cut']);
        script = [
          {
            'type': 'response.completed',
            'response': {
              'output': <Object?>[],
              'usage': {'input_tokens': 1000, 'output_tokens': 1},
            },
          },
        ];
        final second = await driver.submit(
          id: 'second',
          text: 'next',
          turn: writer.currentTurn,
        ) as SubmitAdmitted;
        final secondResult = await second.done;
        expect(secondResult.state, 'done', reason: secondResult.reason);
        expect(
          jsonEncode(bodies[1]['input']),
          isNot(contains('before cut')),
          reason:
              'Text at output index 0 must be omitted before cut at index 1',
        );
        final stored =
            writer.tree.get(SessionPath.parse('body/steps/s-00000001')) as Map;
        expect(stored['output'], [
          {'type': 'text', 'text': 'before cut'},
          {'type': 'compaction', 'item': _compact('boundary')},
        ]);
        expect(live, ['before ', 'cut']);
      },
    );
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
    expect(input.first, compact);
    expect((input[1] as Map)['type'], 'additional_tools');
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
