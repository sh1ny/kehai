/// Child prompts relayed through the parent's RPC server (subagents spec:
/// *Child prompts relayed*; engine-rpc spec: *Prompts reach the client*).
///
/// The parent is an in-memory RPC server over a scripted provider; the child
/// is the real `kehai rpc --child` process against the loopback fake provider.
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_openai.dart';
import '../support/fake_provider.dart';
import '../support/job_support.dart';
import '../support/login_support.dart';
import '../support/rpc_support.dart';

const String _implementer = 'specwright-implementer';
const Duration _slow = Duration(seconds: 90);

/// The child engine command: `kehai rpc` from this checkout's sources.
({String executable, List<String> arguments}) _sourceEngine(
  List<String> rpcArgs,
) {
  final root = Directory.current.path;
  return (
    executable: Platform.resolvedExecutable,
    arguments: [
      '--packages=${p.join(root, '.dart_tool', 'package_config.json')}',
      p.join(root, 'bin', 'kehai.dart'),
      'rpc',
      ...rpcArgs,
    ],
  );
}

List<ScriptStep> _toolCallTurn(String callId, String name, Object arguments) =>
    [
      SseEvent.json('response.created', {
        'response': {'id': 'resp_1'},
      }),
      SseEvent.json('response.output_item.done', {
        'item': {
          'type': 'function_call',
          'call_id': callId,
          'name': name,
          'arguments': jsonEncode(arguments),
        },
      }),
      SseEvent.json('response.completed', {
        'response': {'id': 'resp_1'},
      }),
    ];

ToolCall _agentCall(String id, {bool background = false}) => ToolCall(
  callId: id,
  name: 'agent',
  argumentsJson: jsonEncode({
    'role': _implementer,
    'prompt': 'make the directory',
    'background': background,
  }),
);

const _toolUse = Completed(StopReason.toolUse);

/// A parent over a scripted provider, its child fake and the child's home.
final class _Rig {
  _Rig(this.rig, this.fake, this.workspace);

  final RpcRig rig;
  final FakeOpenAi fake;
  final Directory workspace;

  /// The directory the child's `bash` call creates.
  Directory get made => Directory(p.join(workspace.path, 'relay-made'));

  /// The next `prompt` event at or after [from].
  Future<Map<String, Object?>> prompt({int from = 0}) =>
      rig.next((e) => e['type'] == 'prompt', from: from, timeout: _slow);

  Future<void> jobEnded({int count = 1}) => waitFor(
    () => rig.runtime.jobs.liveCount == 0,
    limit: _slow,
    what: 'the agent job to end',
  );
}

/// Builds the parent: [steps] are its provider's responses.
Future<_Rig> _start(
  List<List<ProviderEvent>> steps, {
  FakeProvider? provider,
  List<List<ScriptStep>> childTurns = const [],
}) async {
  final home = TestHome();
  final fake = await FakeOpenAi.start();
  home.store.replace(loggedInRecord());
  Directory(home.path).createSync(recursive: true);
  File(p.join(home.path, 'config.json'))
      .writeAsStringSync(jsonEncode({'model': 'gpt-fake'}));
  for (final turn in childTurns) {
    fake.responsesScripts.add(ResponsesScript.sse(turn));
  }
  final rig = await rpcRig(
    provider ?? FakeProvider.steps(steps),
    model: 'gpt-fake',
    tools: {
      'agent': AgentTool(
        engine: _sourceEngine,
        extraEnvironment: {
          'KEHAI_HOME': home.path,
          'KEHAI_OPENAI_ISSUER': fake.issuer,
          'KEHAI_OPENAI_API_BASE': fake.apiBase,
        },
      ),
    },
  );
  final workspace = rig.runtime.workspace;
  Directory(p.join(workspace.path, '.git')).createSync();
  File(p.join(workspace.path, '.claude', 'agents', '$_implementer.md'))
    ..createSync(recursive: true)
    ..writeAsStringSync(
      '---\nname: $_implementer\ndescription: Implements\n'
      'tools: Read, Bash\n---\nImplement.\n',
    );
  return _Rig(rig, fake, workspace);
}

List<ScriptStep> _mkdirTurn() =>
    _toolCallTurn('call_mk', 'bash', {'command': 'mkdir relay-made'});

void main() {
  group('Child prompt relay', () {
    test(
      'a child permission prompt reaches the client with its agent and allow '
      'runs it',
      () async {
        final r = await _start(
          [
            [_agentCall('a1'), _toolUse],
            textStep(['implemented']),
          ],
          childTurns: [_mkdirTurn(), sseTextTurn('made it')],
        );
        await r.rig.nextOfType('snapshot');
        r.rig.send({'type': 'submit', 'id': 'r1', 'text': 'go', 'turn': 0});

        final event = await r.prompt();

        final item = event['item']! as Map<String, Object?>;
        expect(item['kind'], 'permission');
        expect(item['tool'], 'bash');
        expect((item['input']! as Map)['command'], 'mkdir relay-made');
        final agent = item['agent']! as Map<String, Object?>;
        expect(agent['role'], _implementer);
        final jobId = agent['job']! as String;
        expect(item['key'], startsWith('$jobId.'));
        expect(r.made.existsSync(), isFalse, reason: 'not run before allow');

        r.rig.send({'type': 'answer', 'key': item['key'], 'text': 'allow'});

        final reply = await r.rig.answerTo('answer');
        expect(reply['type'], 'reply');
        await r.rig.requestSettled('r1');
        expect(r.made.existsSync(), isTrue);
        expect(r.rig.ofType('withdraw'), isEmpty);
        final progress = await r.rig.next(
          (e) => e['type'] == 'stream' && e['kind'] == 'agent',
        );
        expect(
          progress['delta'],
          allOf(
            startsWith('$_implementer · bash'),
            contains('mkdir relay-made'),
            endsWith('→ ok'),
          ),
        );
      },
      skip: skipWithoutShell(),
    );

    test('interrupting a foreground child withdraws its prompt', () async {
      final r = await _start(
        [
          [_agentCall('a1'), _toolUse],
        ],
        childTurns: [_mkdirTurn(), sseTextTurn('made it')],
      );
      await r.rig.nextOfType('snapshot');
      r.rig.send({'type': 'submit', 'id': 'r1', 'text': 'go', 'turn': 0});
      final key =
          ((await r.prompt())['item']! as Map<String, Object?>)['key']!
              as String;

      r.rig.send({'type': 'interrupt'});

      final withdraw = await r.rig.next(
        (e) => e['type'] == 'withdraw',
        timeout: _slow,
      );
      expect(withdraw['key'], key);
      await r.jobEnded();
      r.rig.send({'type': 'answer', 'key': key, 'text': 'allow'});
      final late = await r.rig.answerTo('answer');
      expect(late['type'], 'error');
      expect(late['message'], 'question withdrawn');
      expect(r.made.existsSync(), isFalse, reason: 'the child got no answer');
      expect(r.fake.responsesRequests, hasLength(1));
    }, skip: skipWithoutShell());

    test(
      "a background child's prompt stays answerable across an interrupt",
      () async {
        final release = Completer<void>();
        final r = await _start(
          const [],
          provider: FakeProvider((request, cancel, call) async* {
            if (call == 0) {
              yield _agentCall('a1', background: true);
              yield _toolUse;
              return;
            }
            // The second step keeps the parent's exchange running.
            await Future.any([release.future, ?cancel?.whenCancelled]);
            yield const Completed(StopReason.endTurn);
          }),
          childTurns: [_mkdirTurn(), sseTextTurn('made it')],
        );
        await r.rig.nextOfType('snapshot');
        r.rig.send({'type': 'submit', 'id': 'r1', 'text': 'go', 'turn': 0});
        final item = (await r.prompt())['item']! as Map<String, Object?>;
        final key = item['key']! as String;

        r.rig.send({'type': 'interrupt'});
        final reply = await r.rig.answerTo('interrupt');
        expect(reply['running'], isTrue);
        await r.rig.requestSettled('r1');
        await Future<void>.delayed(const Duration(milliseconds: 300));

        expect(r.rig.runtime.jobs.liveCount, 1, reason: 'the job keeps going');
        expect(r.rig.ofType('withdraw'), isEmpty);

        r.rig.send({'type': 'answer', 'key': key, 'text': 'allow'});
        final answered = await r.rig.answerTo('answer');
        expect(answered['type'], 'reply');
        await r.jobEnded();
        expect(r.made.existsSync(), isTrue);
        release.complete();
      },
      skip: skipWithoutShell(),
    );

    test(
      'a relayed prompt names its agent with a session-unique key',
      () async {
        final r = await _start(
          [
            [
              _agentCall('a1', background: true),
              _agentCall('a2', background: true),
              _toolUse,
            ],
            textStep(['started two']),
          ],
          // Both children run the same script, so their own call keys match.
          childTurns: [
            _toolCallTurn('call_same', 'bash', {'command': 'mkdir one-dir'}),
            _toolCallTurn('call_same', 'bash', {'command': 'mkdir one-dir'}),
            sseTextTurn('done'),
            sseTextTurn('done'),
          ],
        );
        await r.rig.nextOfType('snapshot');
        r.rig.send({'type': 'submit', 'id': 'r1', 'text': 'go', 'turn': 0});

        final first = await r.prompt();
        final second = await r.rig.next(
          (e) =>
              e['type'] == 'prompt' &&
              (e['item']! as Map)['key'] != (first['item']! as Map)['key'],
          timeout: _slow,
        );

        final items = [
          first['item']! as Map<String, Object?>,
          second['item']! as Map<String, Object?>,
        ];
        final keys = {for (final i in items) i['key']! as String};
        expect(keys, hasLength(2));
        final jobs = {
          for (final i in items) (i['agent']! as Map<String, Object?>)['job'],
        };
        expect(jobs, hasLength(2));
        for (final i in items) {
          final agent = i['agent']! as Map<String, Object?>;
          expect(agent['role'], _implementer);
          expect(i['key'], startsWith('${agent['job']}.'));
        }
        final tree = r.rig.writer.tree.get(SessionPath.parse('jobs'));
        expect(tree, isA<Map<String, Object?>>());
        expect((tree! as Map<String, Object?>).keys.toSet(), jobs);
        for (final i in items) {
          r.rig.send({'type': 'answer', 'key': i['key'], 'text': 'deny'});
        }
        await r.jobEnded();
      },
      skip: skipWithoutShell(),
    );
  });
}
