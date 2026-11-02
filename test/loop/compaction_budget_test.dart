import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/loop_support.dart';
import '../support/session_support.dart';
import 'compaction_test.dart' show NativeFake, driveNative, lastStep, opaque;

String budget(BuiltRequest b) => b.blockText.split('\n')[2];

void main() {
  test('turn-perception: Known window', () async {
    final w = await createWriter(await tempDir());
    await seedExchange(w, 1, 'hello');
    final b = await RequestBuilder(
      sessionDir: w.sessionDir,
      model: 'gpt-5.5',
      workspaceName: 'proj',
      tools: [],
      window: 200000,
      estimateRequest: (_) => 41200,
      estimate: (_) => 40,
    ).build(w.tree, turn: 14);
    expect(budget(b), 'budget: ~41k/200k ctx (~21%) · model gpt-5.5');
    expect(b.blockText.split('\n'), hasLength(4));
    expect(
      sensoriumBlock(
        turn: 14,
        now: DateTime(2026),
        workspaceName: 'proj',
        used: 41200,
        window: 200000,
        model: 'gpt-5.5',
      ),
      contains('budget: 41k/200k ctx (21%)'),
    );
  });
  test('turn-perception: Estimated window', () async {
    final w = await createWriter(await tempDir());
    final p = NativeFake([
      [const Completed(StopReason.endTurn)],
    ], estimate: 41000);
    await driveNative(
      w,
      p,
      config: const UserConfig(
        providers: {
          'openai': ProviderConfig(
            routes: {
              'chatgpt-account': RouteConfig(
                models: {'gpt-5.5': RouteModelConfig(contextWindow: 160000)},
              ),
            },
          ),
        },
      ),
    );
    expect(
      (p.requests.single.items.last as UserMessage).text,
      contains('budget: ~41k/~160k ctx (~26%)'),
    );
    final context = lastStep(w)['context'] as Map;
    expect(context['windowSource'], 'user-configured estimate');
    expect(context['window'], 160000);
  });
  test('turn-perception: Unqualified metadata', () async {
    final w = await createWriter(await tempDir());
    final runtime = await ToolRuntime.attach(
      w,
      ResultStore(w.sessionDir),
      workspace: w.sessionDir,
      gate: const AllowAllStage(),
      config: const UserConfig(contextWindows: {'gpt-5.5': 500000}),
    );
    addTearDown(runtime.close);
    final p = NativeFake([
      [const Completed(StopReason.endTurn)],
    ]);
    final driver = ExchangeDriver(
      writer: w,
      runtime: runtime,
      provider: p,
      model: 'gpt-5.5',
      contextWindow: 500000,
    );
    final admitted = await driver.submit(
      id: 'r',
      text: 'go',
      turn: w.currentTurn,
    ) as SubmitAdmitted;
    await admitted.done;
    expect(
      (p.requests.single.items.last as UserMessage).text,
      contains('budget: ~5k/? ctx'),
    );
    final context = lastStep(w)['context'] as Map;
    expect(context['window'], isNull);
    expect(context['backendWindow'], 500000);
    expect(context['windowSource'], 'unknown');
    expect(
      context['migrationNotice'],
      contains('providers.openai.routes.chatgpt-account'),
    );
  });
  for (final name in [
    'turn-perception: First request after compaction',
    'turn-perception: Unknown used context with configured window',
  ]) {
    test(name, () async {
      final w = await createWriter(await tempDir());
      const config = UserConfig(
        providers: {
          'openai': ProviderConfig(
            routes: {
              'chatgpt-account': RouteConfig(
                models: {'gpt-5.5': RouteModelConfig(contextWindow: 160000)},
              ),
            },
          ),
        },
      );
      await driveNative(
        w,
        NativeFake([
          [
            const Usage(input: 120000, output: 6000),
            CompactionItem(opaque('A'), outputIndex: 0),
            const Completed(StopReason.endTurn),
          ],
        ]),
        config: config,
      );
      final p = NativeFake([
        [
          const Usage(input: 1186, output: 8),
          const Completed(StopReason.endTurn),
        ],
      ]);
      await driveNative(w, p, config: config);
      expect(
        (p.requests.single.items.last as UserMessage).text,
        contains('budget: ?/~160k ctx · model'),
      );
      final context = lastStep(w)['context'] as Map;
      expect(context['used'], isNull); // Foundation already green in group 4.
      expect(context['quality'], 'unknown compacted usage');
      expect(context['retained'], isA<int>());
      expect(context['calibration'], isTrue);
    });
  }
  test('turn-perception: Usage after compaction', () async {
    final w = await createWriter(await tempDir());
    await driveNative(
      w,
      NativeFake([
        [
          CompactionItem(opaque('A'), outputIndex: 0),
          const Completed(StopReason.endTurn),
        ],
      ]),
    );
    await driveNative(
      w,
      NativeFake([
        [
          const Usage(input: 1186, output: 8),
          const Completed(StopReason.endTurn),
        ],
      ]),
    );
    final p = NativeFake([
      [const Completed(StopReason.endTurn)],
    ]);
    await driveNative(w, p);
    expect((lastStep(w)['context'] as Map)['used'], lessThan(10000));
    expect(
      (lastStep(w)['context'] as Map)['quality'],
      'estimated from compatible usage',
    );
    expect(
      (p.requests.single.items.last as UserMessage).text,
      contains('budget: ~1k/? ctx'),
    );
  });
}
