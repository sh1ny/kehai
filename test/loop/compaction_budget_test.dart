import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
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
    expect(budget(b), contains('budget: ~41k/200k ctx (~21%)'));
    expect(budget(b), contains('model gpt-5.5'));
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
        allOf(contains('budget: ?/~160k ctx'), contains('model gpt-5.5')),
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
  test('reuses calibrated usage after context metadata changes', () async {
    final w = await createWriter(await tempDir());
    Directory(p.join(w.sessionDir.path, '.git')).createSync();
    final agents = File(p.join(w.sessionDir.path, 'AGENTS.md'))
      ..writeAsStringSync('Be kind.\n');

    final first = NativeFake([
      [
        CompactionItem(opaque('A'), outputIndex: 0),
        const Completed(StopReason.endTurn),
      ],
    ]);
    expect((await driveNative(w, first)).state, 'done');
    final calibration = NativeFake([
      [
        const Usage(input: 1186, output: 8),
        const Completed(StopReason.endTurn),
      ],
    ]);
    expect((await driveNative(w, calibration)).state, 'done');
    final calibratedStep = lastStep(w);
    final oldIdentity = calibratedStep['instructions'] as Map;
    final oldKey = oldIdentity['context'] as String;
    final oldLineage = calibratedStep['lineage'];
    final oldBoundary = calibratedStep['boundary'];
    expect(calibratedStep['calibration'], isTrue);
    expect(oldBoundary, isNotNull);

    agents.writeAsStringSync('Be kind.\n\n');
    final ordinary = NativeFake([
      [const Completed(StopReason.endTurn)],
    ]);
    expect((await driveNative(w, ordinary)).state, 'done');
    expect(ordinary.requests, hasLength(1));
    final nextStep = lastStep(w);
    final newKey = (nextStep['instructions'] as Map)['context'] as String;
    final contexts =
        w.tree.get(SessionPath.parse('body/contexts')) as Map<String, Object?>;
    final before = contexts[oldKey] as Map;
    final after = contexts[newKey] as Map;
    expect(newKey, isNot(oldKey));
    expect(before['files'], [
      {'path': 'AGENTS.md', 'bytes': 9, 'truncated': false},
    ]);
    expect(after['files'], [
      {'path': 'AGENTS.md', 'bytes': 10, 'truncated': false},
    ]);
    expect(after['text'], before['text']);
    expect(
      ordinary.requests.single.instructions,
      calibration.requests.single.instructions,
    );
    expect(nextStep['lineage'], oldLineage);
    expect(nextStep['boundary'], oldBoundary);
    expect(nextStep['calibration'], isNot(true));
    final context = nextStep['context'] as Map;
    expect(context['used'], lessThan(10000));
    expect(context['quality'], 'estimated from compatible usage');

    agents.writeAsStringSync('Be bold.\n');
    final changed = NativeFake([
      [const Completed(StopReason.endTurn)],
    ]);
    final rejected = await driveNative(w, changed);
    expect(rejected.state, 'stopped');
    expect(rejected.reason, contains('incompatible continuity'));
    expect(changed.requests, isEmpty);
  });

  test('usage lineage supersedes identity only when compatible', () async {
    for (final (hasLineage, sameIdentity, compatible) in [
      (false, true, true),
      (false, false, false),
      (true, false, true),
      (true, true, false),
    ]) {
      final w = await createWriter(await tempDir());
      for (final key in ['k1', 'k2']) {
        await w.apply(rec(1, 'body/contexts/$key', Op.set, {'text': 'rules'}));
      }
      await seedExchange(w, 1, 'first', context: 'k1');
      await seedStep(
        w,
        1,
        exchange: 1,
        output: [textEntry('answer')],
        usage: {'input': 1000, 'output': 100},
        instructions: {
          'version': instructionsVersion,
          'context': 'k1',
          'role': null,
        },
      );
      final builder = RequestBuilder(
        sessionDir: w.sessionDir,
        model: 'gpt-5.5',
        workspaceName: 'test',
        tools: const [],
        estimateRequest: (_) => 1000000,
      );
      if (hasLineage) {
        final lineage = builder.requestLineage(w.tree, contextKey: 'k1');
        await w.apply(
          rec(1, 'body/steps/s-00000001', Op.merge, {
            'lineage': sameIdentity ? {...lineage, 'model': 'other'} : lineage,
          }),
        );
      }
      await seedExchange(w, 2, 'second', context: sameIdentity ? 'k1' : 'k2');
      final built = await builder.build(w.tree, turn: 2);
      expect(
        built.quality,
        compatible
            ? 'estimated from compatible usage'
            : 'estimated full request',
        reason: 'lineage=$hasLineage sameIdentity=$sameIdentity',
      );
      expect(built.used, compatible ? lessThan(5000) : greaterThan(900000));
    }
  });
}
