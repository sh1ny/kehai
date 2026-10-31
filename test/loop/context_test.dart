import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_provider.dart';
import '../support/loop_support.dart';
import '../support/session_support.dart';

const _endTurn = Completed(StopReason.endTurn);
const _toolUse = Completed(StopReason.toolUse);

final class _Rig {
  _Rig(this.writer, this.driver, this.ws, this.agents);

  final SessionWriter writer;
  final ExchangeDriver driver;
  final Directory ws;
  final File agents;

  Object? at(String path) => writer.tree.get(SessionPath.parse(path));

  Map<String, Object?> exchange(int turn) =>
      at('body/exchanges/x-${pad8(turn)}')! as Map<String, Object?>;

  Map<String, Object?> contexts() =>
      (at('body/contexts') ?? <String, Object?>{}) as Map<String, Object?>;

  Future<ExchangeResult> run(String text, String id) async {
    final outcome = await driver.submit(
      id: id,
      text: text,
      turn: writer.currentTurn,
    );
    return (outcome as SubmitAdmitted).done;
  }

  /// How many journal records set a context.
  int contextSets() => RegExp(
    r'"path":"body/contexts/[0-9a-f]+","op":"set"|'
    r'"op":"set","path":"body/contexts/[0-9a-f]+"',
  ).allMatches(journalOf(writer.sessionDir).readAsStringSync()).length;
}

Future<_Rig> _rig(
  FakeProvider provider, {
  String agents = 'Be kind.\n',
  int? window,
  Future<void> Function(SessionWriter writer)? prepare,
}) async {
  final root = await tempDir();
  final ws = Directory(p.join(root.path, 'ws'))..createSync();
  Directory(p.join(ws.path, '.git')).createSync();
  final file = File(p.join(ws.path, 'AGENTS.md'))..writeAsStringSync(agents);
  final home = Directory(p.join(root.path, 'home'))..createSync();
  final writer = await createWriter(Directory(p.join(root.path, 's')));
  await prepare?.call(writer);
  final runtime = await ToolRuntime.attach(
    writer,
    ResultStore(writer.sessionDir),
    workspace: ws,
    kehaiHome: home,
    gate: const AllowAllStage(),
  );
  addTearDown(runtime.close);
  final driver = ExchangeDriver(
    writer: writer,
    runtime: runtime,
    provider: provider,
    model: 'gpt-5.5',
    contextWindow: window,
    clock: () => DateTime(2026, 10, 30, 9, 5),
  );
  return _Rig(writer, driver, ws, file);
}

void main() {
  group('Context captured once per content', () {
    test(
      'two exchanges with unchanged files share one stored context',
      () async {
        final provider = FakeProvider.steps([
          [const TextDelta('one'), _endTurn],
          [const TextDelta('two'), _endTurn],
        ]);
        final rig = await _rig(provider);

        await rig.run('a', 'r1');
        await rig.run('b', 'r2');

        final key = rig.exchange(1)['context'];
        expect(key, isA<String>());
        expect(key, hasLength(16));
        expect(rig.exchange(2)['context'], key);
        expect(rig.contexts().keys, [key]);
        expect(rig.contextSets(), 1);
        final stored = rig.contexts()[key]! as Map<String, Object?>;
        expect(stored['text'], contains('Be kind.'));
        expect(stored['files'], [
          {'path': 'AGENTS.md', 'bytes': 9, 'truncated': false},
        ]);
        expect(stored['skills'], 0);
        expect(stored['problems'], isEmpty);
      },
    );

    test('an edit during exchange 1 gives exchange 2 a new key and keeps '
        'exchange 1\'s', () async {
      late _Rig rig;
      final provider = FakeProvider((request, cancel, call) {
        if (call == 0) rig.agents.writeAsStringSync('Be bold.\n');
        return Stream.fromIterable([const TextDelta('ok'), _endTurn]);
      });
      rig = await _rig(provider);

      await rig.run('a', 'r1');
      await rig.run('b', 'r2');

      final first = rig.exchange(1)['context']! as String;
      final second = rig.exchange(2)['context']! as String;
      expect(second, isNot(first));
      final contexts = rig.contexts();
      expect((contexts[first]! as Map)['text'], contains('Be kind.'));
      expect((contexts[second]! as Map)['text'], contains('Be bold.'));
    });

    test('rewind before exchange 2 keeps exchange 1\'s context and '
        'instructions', () async {
      final provider = FakeProvider.steps([
        [const TextDelta('one'), _endTurn],
        [const TextDelta('two'), _endTurn],
      ]);
      final rig = await _rig(provider);
      await rig.run('a', 'r1');
      await rig.run('b', 'r2');
      final key = rig.exchange(1)['context']! as String;
      final sent = provider.requests[0].instructions;

      await rig.writer.rewind(1);

      expect(rig.contexts().keys, [key]);
      final builder = RequestBuilder(
        sessionDir: rig.writer.sessionDir,
        model: 'gpt-5.5',
        workspaceName: 'ws',
        tools: const [],
        estimateRequest: (_) => 0,
      );
      final rebuilt = await builder.build(rig.writer.tree, turn: 1);
      expect(rebuilt.request.instructions, sent);
    });

    test('rewind before the first use removes the context and the next '
        'exchange stores it again', () async {
      final provider = FakeProvider.steps([
        [const TextDelta('one'), _endTurn],
        [const TextDelta('two'), _endTurn],
        [const TextDelta('three'), _endTurn],
      ]);
      final rig = await _rig(provider);
      await rig.run('a', 'r1');
      await rig.run('b', 'r2');
      final key = rig.exchange(1)['context']! as String;

      await rig.writer.rewind(0);

      expect(rig.contexts(), isEmpty);
      await rig.run('c', 'r3');
      expect(rig.contexts().keys, [key]);
      expect(rig.contextSets(), 2);
    });
  });

  group('Instructions built from the captured context', () {
    test(
      'requests with one context key carry byte-identical instructions',
      () async {
        final provider = FakeProvider.steps([
          [
            const ToolCall(callId: 'c1', name: 'ls', argumentsJson: '{}'),
            _toolUse,
          ],
          [
            const ToolCall(callId: 'c2', name: 'ls', argumentsJson: '{}'),
            _toolUse,
          ],
          [const TextDelta('done'), _endTurn],
          [const TextDelta('again'), _endTurn],
        ]);
        final rig = await _rig(provider);

        await rig.run('a', 'r1');
        await rig.run('b', 'r2');

        expect(provider.requests, hasLength(4));
        final first = provider.requests.first.instructions;
        expect(first, startsWith(builtInInstructions));
        expect(first, contains('# Project instructions'));
        expect(first, contains('Be kind.'));
        for (final request in provider.requests) {
          expect(request.instructions, first);
        }
      },
    );

    test('a step uses the context captured at its exchange start', () async {
      late _Rig rig;
      final provider = FakeProvider((request, cancel, call) {
        if (call == 0) rig.agents.writeAsStringSync('Be bold.\n');
        return Stream.fromIterable([
          if (call == 0)
            const ToolCall(callId: 'c1', name: 'ls', argumentsJson: '{}')
          else
            const TextDelta('ok'),
          call == 0 ? _toolUse : _endTurn,
        ]);
      });
      rig = await _rig(provider);

      await rig.run('a', 'r1');

      expect(provider.requests, hasLength(2));
      expect(provider.requests[1].instructions, contains('Be kind.'));
      expect(provider.requests[1].instructions, isNot(contains('Be bold.')));
    });

    test(
      'a pre-change session captures context for its next exchange',
      () async {
        final provider = FakeProvider.steps([
          [const TextDelta('fresh'), _endTurn],
        ]);
        final rig = await _rig(
          provider,
          prepare: (writer) async {
            await seedExchange(writer, 1, 'old prompt');
            await seedStep(writer, 1, exchange: 1, output: [textEntry('old')]);
          },
        );
        expect(rig.exchange(1).containsKey('context'), isFalse);

        await rig.run('new prompt', 'r9');

        expect(rig.exchange(2)['context'], isA<String>());
        expect(rig.contexts(), hasLength(1));
        final request = provider.requests.single;
        expect(request.instructions, contains('Be kind.'));
        expect(
          [
            for (final item in request.items.take(3))
              switch (item) {
                UserMessage(:final text) => 'user:$text',
                AssistantMessage(:final text) => 'assistant:$text',
                _ => 'other',
              },
          ],
          ['user:old prompt', 'assistant:old', 'user:new prompt'],
        );
      },
    );
  });

  group('Budget follows the instructions', () {
    test(
      'grown AGENTS.md stops the next exchange on overflow before sending',
      () async {
        final provider = FakeProvider.steps([
          [
            const TextDelta('small'),
            const Usage(input: 100, output: 10),
            _endTurn,
          ],
          [const TextDelta('never'), _endTurn],
        ]);
        final rig = await _rig(provider, window: 8000);
        final ok = await rig.run('a', 'r1');
        expect(ok.state, 'done');

        rig.agents.writeAsStringSync('${'x' * 79}\n' * 400);
        final result = await rig.run('b', 'r2');

        expect(result.state, 'stopped');
        expect(result.reason, contains('context overflow'));
        expect(provider.requests, hasLength(1));
      },
    );
  });
}
