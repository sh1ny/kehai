import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kehai/kehai.dart';
import 'package:kehai/src/cli/cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/session_support.dart';
import '../rpc/process_test.dart' as rpc;
import '../support/fake_openai.dart';
import '../support/login_support.dart';

void main() {
  test('context-compaction: Different child model and later config edit', () async {
    final home = await tempDir();
    final file = File(p.join(home.path, 'config.json'));
    file.writeAsStringSync(
      jsonEncode({
        'providers': {
          'openai': {
            'routes': {
              'chatgpt-account': {
                'models': {
                  'modelA': {
                    'compaction': {'threshold': 100000},
                  },
                  'modelB': {
                    'compaction': {'threshold': 80000},
                  },
                },
              },
            },
          },
        },
      }),
    );
    final captured = UserConfig.load(home.path);
    file.writeAsStringSync('{"providers":{}}');
    final args = await _command(captured, model: 'modelB');
    expect(
      args,
      contains('--compaction-policy'),
      reason: 'real child launch seam must carry captured provider policy',
    );
    final payload = args[args.indexOf('--compaction-policy') + 1];
    final snapshot = jsonDecode(utf8.decode(base64Decode(payload))) as Map;
    expect(snapshot.keys, unorderedEquals(['providers']));
    expect(
      snapshot['providers']['openai']['routes']['chatgpt-account']['models']['modelB']['compaction']['threshold'],
      80000,
    );
    expect(
      snapshot['providers']['openai']['routes']['chatgpt-account']['models']['modelA']['compaction']['threshold'],
      100000,
    );
    expect(args, containsAllInOrder(['--model', 'modelB', '--effort', 'high']));
    await _assertChildUsesSnapshot(args);
  });

  test('context-compaction: Invalid launch payload', () async {
    for (final payload in [
      'not base64!',
      base64Encode(utf8.encode('{"secret":"not-allowed"}')),
      base64Encode(utf8.encode('{"providers":[]}')),
      base64Encode(utf8.encode('{"providers":{"openai":{"unknown":1}}}')),
      base64Encode(
        utf8.encode(
          '{"providers":{"openai":{"compaction":{"threshold":999}}}}',
        ),
      ),
      base64Encode(utf8.encode(' ' * 8193)),
      'A' * 12000,
    ]) {
      final err = StringBuffer();
      final result = await runCli(
        [
          'rpc',
          '--child',
          '--parent',
          'unused',
          '--job',
          'j1',
          '--role',
          'reviewer',
          '--role-digest',
          'digest',
          '--model',
          'modelB',
          '--compaction-policy',
          payload,
        ],
        err: err,
        out: StringBuffer(),
        interrupts: const Stream.empty(),
      );
      expect(
        result,
        exitFailure,
        reason: 'invalid captured policy is a typed configuration error',
      );
      expect(err.toString(), contains('compaction-policy'));
      expect(err.toString(), isNot(contains('Could not find an option')));
      expect(err.toString(), isNot(contains('not-allowed')));
    }
  });

  test(
    'child launch rejects oversized captured policy before engine builder',
    () async {
      final config = UserConfig(
        providers: {
          'openai': ProviderConfig(
            routes: {
              'chatgpt-account': RouteConfig(
                models: {
                  '界' * 3000: const RouteModelConfig(contextWindow: 200000),
                },
              ),
            },
          ),
        },
      );
      var built = false;
      await expectLater(
        _command(config, onBuild: () => built = true),
        throwsA(isA<ConfigError>()),
      );
      expect(built, isFalse);
    },
  );

  test(
    'child launch bounds complete native argv including executable and quoting',
    () async {
      await expectLater(
        _command(const UserConfig(), executable: 'x' * 32768),
        throwsA(isA<ConfigError>()),
      );
      await expectLater(
        _command(const UserConfig(), extra: ['--parent', '界' * 32768]),
        throwsA(isA<ConfigError>()),
      );
      await expectLater(
        _command(const UserConfig(), extra: ['\\"' * 12000]),
        throwsA(isA<ConfigError>()),
      );
    },
  );

  test('missing child snapshot fails closed before startup', () async {
    var starts = 0;
    final err = StringBuffer();
    final code = await runCli(
      [
        'rpc',
        '--child',
        '--parent',
        'unused',
        '--job',
        'j1',
        '--role',
        'reviewer',
        '--role-digest',
        'digest',
      ],
      err: err,
      out: StringBuffer(),
      rpcRunner:
          ({
            required settings,
            required workspace,
            required input,
            required output,
            bool resume = false,
            String? sessionId,
            String? modelFlag,
            String? effortFlag,
            child,
          }) async {
            starts++;
            return 0;
          },
    );
    expect(code, exitFailure);
    expect(starts, 0);
    expect(err.toString(), contains('compaction-policy'));
  });
}

Future<void> _assertChildUsesSnapshot(List<String> capturedArgs) async {
  final home = TestHome();
  home.store.replace(loggedInRecord());
  File(p.join(home.path, 'config.json')).writeAsStringSync(
    jsonEncode({
      'effort': 'low',
      'providers': {
        'openai': {
          'compaction': {'threshold': 77777},
        },
      },
    }),
  );
  final workspace = await tempDir();
  Directory(p.join(workspace.path, '.git')).createSync();
  final roles = Directory(p.join(workspace.path, '.claude', 'agents'))
    ..createSync(recursive: true);
  const roleText =
      '---\nname: reviewer\ndescription: Review\ntools: Read\n---\nReview.\n';
  File(p.join(roles.path, 'reviewer.md')).writeAsStringSync(roleText);
  final parent = await createWriter(await tempDir());
  final parentDir = parent.sessionDir;
  await parent.close();
  final fake = await FakeOpenAi.start();
  fake.defaultModels = {
    'models': [
      {
        'slug': 'modelB',
        'display_name': 'B',
        'visibility': 'list',
        'supported_in_api': true,
      },
    ],
  };
  fake.responsesScripts.add(
    ResponsesScript.sse([
      SseEvent.json('response.created', {
        'response': {'id': 'resp_child'},
      }),
      SseEvent.json('response.output_item.done', {
        'output_index': 0,
        'item': {
          'type': 'compaction',
          'id': 'cmp-child',
          'encrypted_content': 'opaque-child',
        },
      }),
      SseEvent.json('response.completed', {
        'response': {
          'id': 'resp_child',
          'usage': {'input_tokens': 120000, 'output_tokens': 6000},
        },
      }),
    ]),
  );
  final engine = await rpc.startEngine(
    [
      ...capturedArgs,
      '--parent',
      parentDir.path,
      '--job',
      'j1',
      '--role',
      'reviewer',
      '--role-digest',
      sha256.convert(utf8.encode(roleText)).toString(),
    ],
    home: home,
    workspace: workspace,
    fake: fake,
  );
  try {
    final hello = await engine.nextLine();
    expect(hello['type'], 'hello');
    final snapshot = await engine.nextLine();
    expect(snapshot['type'], 'snapshot');
    expect((snapshot['compaction']! as Map)['threshold'], 80000);
    engine.send({
      'type': 'submit',
      'id': 'child',
      'text': 'review',
      'turn': snapshot['turn'],
    });
    await engine.lineWhere((event) {
      final record = event['record'];
      return record is Map &&
          record['path'] == 'meta/requests/child' &&
          record['value'] is Map &&
          (record['value'] as Map)['state'] == 'completed';
    });
    await engine.process.stdin.close();
    expect(await engine.exitCode(), 0, reason: await engine.stderrText);
    final body = fake.responsesRequests.single.json!;
    expect(body['model'], 'modelB');
    expect(
      (body['context_management']! as List).single['compact_threshold'],
      80000,
    );
    final childDir = Directory(
      p.join(parentDir.path, 'agents', hello['session']! as String),
    );
    final child = await SessionWriter.open(childDir);
    try {
      final steps = child.tree.get(SessionPath.parse('body/steps'))! as Map;
      final step = steps.values.single as Map;
      expect(step['model'], 'modelB');
      expect(step['effort'], 'high');
      expect((step['policy'] as Map)['threshold'], 80000);
      expect((step['capability'] as Map)['state'], 'observed-supported');
    } finally {
      await child.close();
    }
    final reopenedParent = await SessionWriter.open(parentDir);
    try {
      expect(reopenedParent.tree.get(SessionPath.parse('body/steps')), isNull);
    } finally {
      await reopenedParent.close();
    }
  } finally {
    engine.process.kill();
    await engine.process.exitCode;
    await engine.lines.cancel();
    await engine.stderrText;
  }
}

Future<List<String>> _command(
  UserConfig config, {
  String model = 'modelB',
  String executable = 'not-started',
  List<String> extra = const [],
  void Function()? onBuild,
}) async {
  final root = await tempDir();
  final writer = await createWriter(root);
  final capture = _Capture(model, executable, extra, onBuild);
  final runtime = await ToolRuntime.attach(
    writer,
    ResultStore(writer.sessionDir),
    workspace: root,
    config: config,
    model: 'modelA',
    effort: 'high',
    tools: {'read': capture},
    gate: const AllowAllStage(),
  );
  try {
    await runtime.run(
      const ToolCall(
        callId: 'capture',
        name: 'read',
        argumentsJson: '{"path":"unused"}',
      ),
    );
    if (capture.error case final error?) {
      Error.throwWithStackTrace(error, capture.stack!);
    }
    return capture.arguments!;
  } finally {
    await runtime.close();
  }
}

final class _Capture implements Tool {
  _Capture(this.model, this.executable, this.extra, this.onBuild);
  final String model;
  final String executable;
  final List<String> extra;
  final void Function()? onBuild;
  List<String>? arguments;
  Object? error;
  StackTrace? stack;
  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    try {
      final command = AgentTool(
        engine: (args) {
          onBuild?.call();
          return (executable: executable, arguments: args);
        },
      ).buildChildCommand(context, ['--child', '--model', model, ...extra]);
      arguments = command.arguments;
    } catch (e, s) {
      error = e;
      stack = s;
    }
    return const ToolOutcome(summary: 'captured launch');
  }
}
