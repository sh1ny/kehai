import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_provider.dart';
import '../support/session_support.dart';

typedef _Body = Future<ToolOutcome> Function(ToolContext context);

/// A tool whose behavior the test supplies.
final class _Tool implements Tool {
  const _Tool(this.body);

  /// A tool that settles `ok` at once.
  const _Tool.ok() : body = _ok;

  final _Body body;

  @override
  Future<ToolOutcome> run(ToolContext context, Map<String, Object?> input) =>
      body(context);
}

Future<ToolOutcome> _ok(ToolContext context) async =>
    const ToolOutcome(summary: 'ok');

/// A stage that denies every call.
final class _Deny implements CallStage {
  const _Deny();

  @override
  Future<StageOutcome> check(StageCall call, CancelToken cancel) async =>
      const StageOutcome.deny('denied by the user');
}

ToolCall _call(
  String id,
  String name, [
  String args = '{"path":"a.txt"}',
  int? index,
]) => ToolCall(callId: id, name: name, argumentsJson: args, outputIndex: index);

const _toolUse = Completed(StopReason.toolUse);
const _endTurn = Completed(StopReason.endTurn);

final class _Rig {
  _Rig(this.writer, this.io, this.runtime, this.provider, this.driver, this.ws);

  final SessionWriter writer;
  final HookedIo io;
  final ToolRuntime runtime;
  final FakeProvider provider;
  final ExchangeDriver driver;
  final Directory ws;

  Object? at(String path) => writer.tree.get(SessionPath.parse(path));

  Map<String, Object?> map(String path) => at(path)! as Map<String, Object?>;

  Map<String, Object?> exchange(int turn) =>
      map('body/exchanges/x-${turn.toString().padLeft(8, '0')}');

  Map<String, Object?> step(int turn) =>
      map('body/steps/s-${turn.toString().padLeft(8, '0')}');

  Map<String, Object?> callNode(String callId) =>
      map('body/calls/${callKey(callId)}');

  /// Submits [text] and waits for the exchange to end.
  Future<ExchangeResult> run(String text, {String id = 'r1'}) async {
    final outcome = await driver.submit(
      id: id,
      text: text,
      turn: writer.currentTurn,
    );
    return (outcome as SubmitAdmitted).done;
  }
}

Future<_Rig> _rig(
  FakeProvider provider, {
  Map<String, Tool> tools = const {},
  CallStage? gate,
  int? window,
  DriverSeams seams = const DriverSeams(),
  bool skipFlush = false,
}) async {
  final root = await tempDir();
  final ws = Directory(p.join(root.path, 'ws'))..createSync();
  Directory(p.join(ws.path, 'lib')).createSync();
  File(p.join(ws.path, 'lib', 'a.dart')).writeAsStringSync('a');
  final (writer, io) = await createHooked(Directory(p.join(root.path, 's')));
  io.skipFlush = skipFlush;
  final runtime = await ToolRuntime.attach(
    writer,
    ResultStore(writer.sessionDir),
    workspace: ws,
    tools: tools,
    gate: gate ?? const AllowAllStage(),
  );
  addTearDown(runtime.close);
  final driver = ExchangeDriver(
    writer: writer,
    runtime: runtime,
    provider: provider,
    model: 'gpt-5.5',
    contextWindow: window,
    clock: () => DateTime(2026, 10, 30, 9, 5),
    seams: seams,
  );
  return _Rig(writer, io, runtime, provider, driver, ws);
}

/// The order of the items of a request, as short strings.
List<String> _items(ModelRequest request) => [
  for (final item in request.items)
    switch (item) {
      UserMessage(:final text) when text.startsWith('<sensorium>') => 'block',
      UserMessage(:final text) => 'user:$text',
      AssistantMessage(:final text) => 'assistant:$text',
      ToolCallItem(:final callId) => 'call:$callId',
      ToolOutputItem(:final callId) => 'output:$callId',
      OpaqueReasoningItem(:final json) => 'reasoning:${json['id']}',
    },
];

ProviderFailure _failure(
  ProviderFailureKind kind, {
  String? code,
  bool sent = true,
}) => ProviderFailure(kind: kind, message: 'it failed', code: code, sent: sent);

void main() {
  group('Exchanges and steps', () {
    test('prompt answered after one ls round records two steps on consecutive '
        'turns', () async {
      final provider = FakeProvider.steps([
        [
          _call('c1', 'ls', '{"path":"lib"}'),
          const Usage(input: 100, output: 10),
          _toolUse,
        ],
        [const TextDelta('Done.'), _endTurn],
      ]);
      final rig = await _rig(provider);

      final result = await rig.run('list lib');

      expect(result.state, 'done');
      expect(rig.step(1)['state'], 'completed');
      expect(rig.step(2)['state'], 'completed');
      expect(rig.step(1)['exchange'], 'x-00000001');
      expect(rig.step(1)['usage'], {'input': 100, 'output': 10});
      expect(rig.step(1)['stop'], 'tool_use');
      expect(rig.step(1)['model'], 'gpt-5.5');
      expect(rig.step(1)['instructions'], instructionsVersion);
      expect(rig.step(1)['attempts'], 1);
      expect(rig.step(1)['context'], containsPair('estimated', true));
      expect(rig.callNode('c1')['status'], 'settled');
      expect(rig.exchange(1), containsPair('state', 'done'));
      expect(rig.exchange(1), containsPair('first', 1));
      expect(rig.exchange(1), containsPair('last', 2));
      expect(rig.map('meta/requests/r1'), containsPair('state', 'completed'));
      expect(rig.map('meta/requests/r1')['outcome'], {
        'exchange': 'x-00000001',
        'state': 'done',
      });
      expect(_items(provider.requests[0]), ['user:list lib', 'block']);
      expect(_items(provider.requests[1]), [
        'user:list lib',
        'call:c1',
        'output:c1',
        'block',
      ]);
      expect(
        jsonEncode(rig.writer.tree.toJson()),
        isNot(contains('<sensorium')),
      );
    });

    test(
      'second prompt while running is refused busy and records nothing',
      () async {
        final reached = Completer<void>();
        final release = Completer<void>();
        final provider = FakeProvider.steps([
          [const TextDelta('hi'), _endTurn],
        ]);
        final rig = await _rig(
          provider,
          seams: DriverSeams(
            beforeStepCommit: (turn) async {
              reached.complete();
              await release.future;
            },
          ),
        );

        final first = await rig.driver.submit(
          id: 'r1',
          text: 'one',
          turn: rig.writer.currentTurn,
        );
        await reached.future;
        final second = await rig.driver.submit(
          id: 'r2',
          text: 'two',
          turn: rig.writer.currentTurn,
        );

        expect(second, isA<SubmitBusy>());
        expect(rig.at('meta/requests/r2'), isNull);
        expect(rig.map('body/exchanges'), hasLength(1));
        expect(rig.driver.busy, isTrue);
        release.complete();
        final result = await (first as SubmitAdmitted).done;
        expect(result.state, 'done');
        expect(provider.requests, hasLength(1));
        expect(rig.driver.busy, isFalse);
      },
    );

    test(
      'a repeated, colliding or stale submit is answered without running',
      () async {
        final provider = FakeProvider.steps([
          [const TextDelta('hi'), _endTurn],
        ]);
        final rig = await _rig(provider);
        await rig.run('one');
        final turn = rig.writer.currentTurn;

        final repeated = await rig.driver.submit(
          id: 'r1',
          text: 'one',
          turn: 0,
        );
        final collided = await rig.driver.submit(
          id: 'r1',
          text: 'two',
          turn: 0,
        );
        final stale = await rig.driver.submit(
          id: 'r2',
          text: 'x',
          turn: turn - 1,
        );

        expect((repeated as SubmitDuplicate).state, 'completed');
        expect(collided, isA<SubmitCollision>());
        expect((stale as SubmitStale).turn, turn);
        expect(rig.at('meta/requests/r2'), isNull);
        expect(provider.requests, hasLength(1));
      },
    );

    test('the context window prefers the configuration, then the backend', () {
      const infos = [
        ModelInfo(id: 'm', name: 'M', contextWindow: 272000),
        ModelInfo(id: 'n', name: 'N'),
      ];
      const config = UserConfig(contextWindows: {'m': 100000});

      expect(resolveContextWindow(config, 'm', infos), 100000);
      expect(resolveContextWindow(const UserConfig(), 'm', infos), 272000);
      expect(resolveContextWindow(const UserConfig(), 'n', infos), isNull);
      expect(resolveContextWindow(const UserConfig(), 'zz', infos), isNull);
    });
  });

  group('Conversation recorded in the tree', () {
    test(
      'step output commits text, reasoning and calls in output-index order',
      () async {
        final provider = FakeProvider.steps([
          [
            _call('b', 'ls', '{"path":"lib"}', 3),
            const ReasoningSummaryDelta('thinking', outputIndex: 1),
            const OpaqueItem({
              'id': 'rs1',
              'type': 'reasoning',
            }, outputIndex: 1),
            const TextDelta('Read', outputIndex: 0),
            _call('a', 'ls', '{"path":"."}', 2),
            const TextDelta('ing.', outputIndex: 0),
            const TextDelta(' tail'),
            _toolUse,
          ],
          [const TextDelta('ok'), _endTurn],
        ]);
        final rig = await _rig(provider);
        final events = <(int, String, String)>[];
        rig.driver.deltas.listen((d) => events.add((d.turn, d.kind, d.delta)));

        await rig.run('go');

        expect(rig.step(1)['output'], [
          {'type': 'text', 'text': 'Reading.'},
          {
            'type': 'reasoning',
            'item': {'id': 'rs1', 'type': 'reasoning'},
          },
          {
            'type': 'call',
            'call': callKey('a'),
            'callId': 'a',
            'name': 'ls',
            'arguments': '{"path":"."}',
          },
          {
            'type': 'call',
            'call': callKey('b'),
            'callId': 'b',
            'name': 'ls',
            'arguments': '{"path":"lib"}',
          },
          {'type': 'text', 'text': ' tail'},
        ]);
        expect(_items(provider.requests[1]), [
          'user:go',
          'assistant:Reading.',
          'reasoning:rs1',
          'call:a',
          'output:a',
          'call:b',
          'output:b',
          'assistant: tail',
          'block',
        ]);
        expect(events, [
          (1, 'reasoning', 'thinking'),
          (1, 'text', 'Read'),
          (1, 'text', 'ing.'),
          (1, 'text', ' tail'),
          (2, 'text', 'ok'),
        ]);
      },
    );
  });

  group('Tool calls of a step', () {
    test('three read calls overlap and the next step waits for all', () async {
      var started = 0;
      var running = 0;
      var peak = 0;
      final allStarted = Completer<void>();
      final releaseThird = Completer<void>();
      final provider = FakeProvider.steps([
        [
          _call('r1', 'read'),
          _call('r2', 'read'),
          _call('r3', 'read'),
          _toolUse,
        ],
        [const TextDelta('done'), _endTurn],
      ]);
      final rig = await _rig(
        provider,
        tools: {
          'read': _Tool((context) async {
            started++;
            running++;
            if (running > peak) peak = running;
            if (started == 3) allStarted.complete();
            await allStarted.future;
            if (context.callId == 'r3') await releaseThird.future;
            running--;
            return const ToolOutcome(summary: 'read ok');
          }),
        },
      );

      final done = rig.run('read three');
      await allStarted.future;
      for (var i = 0; i < 20; i++) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(provider.requests, hasLength(1));
      releaseThird.complete();
      await done;

      expect(peak, 3);
      expect(provider.requests, hasLength(2));
      expect(_items(provider.requests[1]), [
        'user:read three',
        'call:r1',
        'output:r1',
        'call:r2',
        'output:r2',
        'call:r3',
        'output:r3',
        'block',
      ]);
    });

    test('128 calls under slowed flushes all get terminal nodes and no writer '
        'busy', () async {
      final provider = FakeProvider.steps([
        [for (var i = 0; i < 128; i++) _call('k$i', 'read'), _toolUse],
        [const TextDelta('done'), _endTurn],
      ]);
      final rig = await _rig(
        provider,
        tools: {'read': const _Tool.ok()},
        skipFlush: true,
      );
      rig.io.beforeFlush = () =>
          Future<void>.delayed(const Duration(milliseconds: 1));

      final result = await rig.run('many');

      expect(result.state, 'done');
      final nodes = [for (var i = 0; i < 128; i++) rig.callNode('k$i')];
      expect(
        nodes.map((n) => n['status']),
        everyElement(isIn(['settled', 'failed'])),
      );
      expect(nodes.where((n) => n['status'] == 'settled'), hasLength(40));
      final busy = nodes.where((n) => n['reason'] == 'tool busy');
      expect(busy, hasLength(88));
      expect(busy.map((n) => n['status']), everyElement('failed'));
      final items = provider.requests[1].items;
      expect(items.whereType<ToolCallItem>(), hasLength(128));
      expect(items.whereType<ToolOutputItem>(), hasLength(128));
    });

    test(
      'denied bash call sends its envelope and the exchange continues',
      () async {
        final provider = FakeProvider.steps([
          [_call('c1', 'bash', '{"command":"rm -rf build"}'), _toolUse],
          [const TextDelta('understood'), _endTurn],
        ]);
        final rig = await _rig(provider, gate: const _Deny());

        final result = await rig.run('clean up');

        expect(result.state, 'done');
        expect(rig.callNode('c1')['status'], 'settled');
        expect(rig.callNode('c1')['envelope'], 'denied');
        final output = provider.requests[1].items
            .whereType<ToolOutputItem>()
            .single;
        expect(output.output, startsWith('[bash denied]'));
        expect(output.output, contains('denied by the user'));
      },
    );
  });

  group('Context overflow', () {
    test('estimate over a known window stops before sending', () async {
      final provider = FakeProvider.steps(const [], estimator: (_) => 280000);
      final rig = await _rig(provider, window: 272000);

      final result = await rig.run('big');

      expect(provider.requests, isEmpty);
      expect(result.state, 'stopped');
      const message =
          'context overflow: ~280k of 272k tokens; '
          'rewind or start a new session';
      expect(result.reason, message);
      expect(rig.exchange(1), containsPair('state', 'stopped'));
      expect(rig.exchange(1), containsPair('reason', message));
      expect(rig.step(1)['state'], 'failed');
      expect(rig.map('meta/requests/r1'), containsPair('state', 'completed'));
    });

    test(
      'provider context_overflow stops the exchange without retry',
      () async {
        final provider = FakeProvider.steps([
          [Failed(_failure(ProviderFailureKind.contextOverflow))],
        ]);
        final rig = await _rig(provider);

        final result = await rig.run('big');

        expect(provider.requests, hasLength(1));
        expect(result.state, 'stopped');
        expect(result.reason, startsWith('context overflow'));
        expect(rig.step(1)['state'], 'failed');
        expect(rig.step(1)['attempts'], 1);
        expect(
          rig.step(1)['failure'],
          containsPair('kind', 'context_overflow'),
        );
      },
    );
  });

  group('Step output limit', () {
    test(
      'response_output_limit fails the step with its partial text',
      () async {
        final provider = FakeProvider.steps([
          [
            for (var i = 0; i < 1000; i++) const TextDelta('abcdefgh'),
            Failed(
              _failure(
                ProviderFailureKind.protocol,
                code: 'response_output_limit',
              ),
            ),
          ],
        ]);
        final rig = await _rig(provider);

        final result = await rig.run('write forever');

        expect(result.state, 'failed');
        expect(result.reason, 'step output limit (4 MiB)');
        expect(rig.step(1)['state'], 'failed');
        expect(rig.step(1)['reason'], 'step output limit (4 MiB)');
        expect(rig.step(1)['partial'], 'abcdefgh' * 1000);
        expect(rig.step(1).containsKey('output'), isFalse);
        expect(rig.exchange(1), containsPair('state', 'failed'));
        expect(provider.requests, hasLength(1));
      },
    );

    test('held calls over 4 MiB fail the step and none runs', () async {
      final ran = <String>[];
      final provider = FakeProvider.steps([
        [
          // The adapter discards held calls; the driver must not run one even
          // if a call event arrived before the failure.
          _call('held', 'read'),
          Failed(
            _failure(
              ProviderFailureKind.protocol,
              code: 'response_output_limit',
            ),
          ),
        ],
      ]);
      final rig = await _rig(
        provider,
        tools: {
          'read': _Tool((context) async {
            ran.add(context.callId);
            return const ToolOutcome(summary: 'ok');
          }),
        },
      );

      final result = await rig.run('five big calls');

      expect(result.state, 'failed');
      expect(rig.step(1)['reason'], 'step output limit (4 MiB)');
      expect(ran, isEmpty);
      expect(rig.at('body/calls'), isNull);
    });

    test('3 MiB reply completes whole', () async {
      const chunk = 64 * 1024;
      final piece = 'x' * chunk;
      final provider = FakeProvider.steps([
        [for (var i = 0; i < 48; i++) TextDelta(piece), _endTurn],
      ]);
      final rig = await _rig(provider, skipFlush: true);

      final result = await rig.run('long answer');

      expect(result.state, 'done');
      final output = rig.step(1)['output']! as List<Object?>;
      final text = (output.single! as Map<String, Object?>)['text']! as String;
      expect(text.length, 3 * 1024 * 1024);
      expect(rig.step(1)['state'], 'completed');
    });
  });

  group('Step limit', () {
    test(
      '200th step\'s calls settle then the exchange stops at step limit',
      () async {
        final provider = FakeProvider(
          (request, cancel, call) =>
              Stream.fromIterable([_call('s$call', 'read'), _toolUse]),
        );
        final rig = await _rig(
          provider,
          tools: {'read': const _Tool.ok()},
          skipFlush: true,
        );

        final result = await rig.run('loop forever');

        expect(result.state, 'stopped');
        expect(result.reason, 'step limit (200)');
        expect(provider.requests, hasLength(200));
        expect(rig.map('body/steps'), hasLength(200));
        expect(rig.callNode('s199')['status'], 'settled');
        expect(rig.exchange(1), containsPair('reason', 'step limit (200)'));
      },
      timeout: const Timeout(Duration(minutes: 3)),
    );

    test('three-step exchange records no step limit', () async {
      final provider = FakeProvider.steps([
        [_call('a', 'read'), _toolUse],
        [_call('b', 'read'), _toolUse],
        [const TextDelta('done'), _endTurn],
      ]);
      final rig = await _rig(provider, tools: {'read': const _Tool.ok()});

      final result = await rig.run('three steps');

      expect(result.state, 'done');
      expect(result.reason, isNull);
      expect(rig.exchange(1).containsKey('reason'), isFalse);
      expect(rig.map('body/steps'), hasLength(3));
    });
  });
}
