import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/fake_provider.dart';
import '../support/loop_support.dart';
import '../support/session_support.dart';

Map<String, Object?> opaque(String id) => {
  'type': 'compaction',
  'id': id,
  'encrypted_content': 'cipher-$id',
};
Map<String, Object?> cut(String id) => {
  'type': 'compaction',
  'item': opaque(id),
};
String digest(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();
Map<String, Object?> lineage({String model = 'gpt-5.5'}) => {
  'provider': 'openai',
  'route': 'chatgpt-account',
  'model': model,
  'instructions': digest(composeInstructions()),
  'tools': digest([]),
};
RequestBuilder builder(SessionWriter w, {String model = 'gpt-5.5'}) =>
    RequestBuilder(
      sessionDir: w.sessionDir,
      model: model,
      workspaceName: 'test',
      tools: const [],
      estimateRequest: (r) => r.items.fold(0, (n, i) => n + estimateItem(i)),
    );
Future<void> step(
  SessionWriter w,
  int turn,
  List<Map<String, Object?>> output, {
  String model = 'gpt-5.5',
  String? boundary,
  Map<String, Object?>? usage,
}) async {
  await seedStep(w, turn, exchange: 1, output: output, usage: usage);
  await w.apply(
    rec(turn, 'body/steps/s-${pad8(turn)}', Op.merge, {
      'lineage': lineage(model: model),
      'boundary': boundary,
    }),
  );
}

Future<(SessionWriter, ResultStore)> fixture() async {
  final w = await createWriter(await tempDir());
  await seedExchange(w, 1, 'old prompt');
  return (w, ResultStore(w.sessionDir));
}

List<ConversationItem> content(BuiltRequest b) =>
    b.request.items.take(b.request.items.length - 1).toList();

void main() {
  test('agent-loop: Compaction committed with completion', () async {
    final w = await createWriter(await tempDir());
    final runtime = await ToolRuntime.attach(
      w,
      ResultStore(w.sessionDir),
      workspace: w.sessionDir,
      gate: const AllowAllStage(),
    );
    addTearDown(runtime.close);
    final provider = FakeProvider.steps([
      [
        CompactionItem(opaque('A'), outputIndex: 0),
        const TextDelta('after', outputIndex: 1),
        const Completed(StopReason.endTurn),
      ],
    ]);
    final driver = ExchangeDriver(
      writer: w,
      runtime: runtime,
      provider: provider,
      model: 'gpt-5.5',
    );
    final admitted = await driver.submit(
      id: 'r',
      text: 'go',
      turn: w.currentTurn,
    ) as SubmitAdmitted;
    expect((await admitted.done).state, 'done');
    final stored =
        w.tree.get(SessionPath.parse('body/steps/s-00000001')) as Map;
    expect(stored['output'], [cut('A'), textEntry('after')]);
    expect(stored['lineage'], isA<Map<String, Object?>>());
    expect(stored['policy'], isA<Map<String, Object?>>());
  });

  test('agent-loop: Crash before completion commit', () async {
    final (w, io) = await createHooked(await tempDir());
    final runtime = await ToolRuntime.attach(
      w,
      ResultStore(w.sessionDir),
      workspace: w.sessionDir,
      gate: const AllowAllStage(),
    );
    addTearDown(runtime.close);
    var reachedCompletion = false;
    io.onWrite = (bytes) async {
      if (utf8.decode(bytes).contains('"state":"completed"')) {
        reachedCompletion = true;
        throw StateError('death before durable completion');
      }
    };
    final provider = FakeProvider.steps([
      [
        CompactionItem(opaque('candidate'), outputIndex: 0),
        const Completed(StopReason.endTurn),
      ],
    ]);
    final driver = ExchangeDriver(
      writer: w,
      runtime: runtime,
      provider: provider,
      model: 'gpt-5.5',
    );
    final admitted = await driver.submit(
      id: 'r',
      text: 'go',
      turn: w.currentTurn,
    ) as SubmitAdmitted;
    await expectLater(admitted.done, throwsA(isA<StorageError>()));
    expect(reachedCompletion, isTrue);
    await runtime.close();
    final dir = w.sessionDir;
    await w.close();
    final reopened = await SessionWriter.open(dir);
    addTearDown(reopened.close);
    final recovered = await ToolRuntime.attach(
      reopened,
      ResultStore(dir),
      workspace: dir,
      gate: const AllowAllStage(),
    );
    addTearDown(recovered.close);
    await ExchangeDriver(
      writer: reopened,
      runtime: recovered,
      provider: provider,
      model: 'gpt-5.5',
    ).finalizeUnfinished();
    final b = await builder(reopened).build(reopened.tree, turn: 2);
    expect(content(b).whereType<OpaqueCompactionItem>(), isEmpty);
    final stored =
        reopened.tree.get(SessionPath.parse('body/steps/s-00000001')) as Map;
    expect(stored['state'], 'cancelled');
  });

  test('context-compaction: Two compaction items', () async {
    final (w, _) = await fixture();
    await step(w, 1, [
      cut('A'),
      textEntry('READY'),
      cut('B'),
      textEntry('tail'),
    ]);
    final b = await builder(w).build(w.tree, turn: 2);
    expect(content(b).map((i) => i.runtimeType), [
      OpaqueCompactionItem,
      AssistantMessage,
    ]);
    expect((content(b).first as OpaqueCompactionItem).json, opaque('B'));
    expect(b.used, isNull);
    expect(b.blockText, contains('budget: ?/? ctx'));
  });

  test('agent-loop: Boundary in a tool step', () async {
    final (w, store) = await fixture();
    const envelope = '[bash ok] exact\r\n✓\n[truncated: r/aaaaaaaaaaaa]\n';
    await step(w, 1, [
      callEntry('pre', 'bash'),
      cut('A'),
      callEntry('post', 'bash'),
    ]);
    await seedCall(w, store, callId: 'pre', modelText: envelope);
    await seedCall(w, store, callId: 'post', modelText: 'post result');
    final items = content(await builder(w).build(w.tree, turn: 2));
    expect(items.first, isA<OpaqueCompactionItem>());
    expect(items.whereType<ToolCallItem>().single.callId, 'post');
    expect(items.whereType<ToolOutputItem>().single.output, 'post result');
    final note = items.whereType<UserMessage>().single.text;
    expect(note, contains('pre'));
    expect(note, contains('bash'));
    expect(note.endsWith(envelope), isTrue);
  });

  test('agent-loop: Normal settlement across the cut', () async {
    final w = await createWriter(await tempDir());
    var effects = 0;
    final runtime = await ToolRuntime.attach(
      w,
      ResultStore(w.sessionDir),
      workspace: w.sessionDir,
      gate: const AllowAllStage(),
      tools: {'ls': _CountTool(() => effects++)},
    );
    addTearDown(runtime.close);
    final provider = FakeProvider.steps([
      [
        const ToolCall(
          callId: 'pre',
          name: 'ls',
          argumentsJson: '{}',
          outputIndex: 0,
        ),
        CompactionItem(opaque('A'), outputIndex: 1),
        const ToolCall(
          callId: 'post',
          name: 'ls',
          argumentsJson: '{}',
          outputIndex: 2,
        ),
        const Completed(StopReason.toolUse),
      ],
      [const TextDelta('done'), const Completed(StopReason.endTurn)],
    ]);
    final driver = ExchangeDriver(
      writer: w,
      runtime: runtime,
      provider: provider,
      model: 'gpt-5.5',
    );
    final admitted = await driver.submit(
      id: 'r',
      text: 'go',
      turn: w.currentTurn,
    ) as SubmitAdmitted;
    expect((await admitted.done).state, 'done');
    expect(effects, 2);
    final items = provider.requests[1].items;
    expect(items.first, isA<OpaqueCompactionItem>());
    expect(items.whereType<ToolCallItem>().single.callId, 'post');
    expect(
      items.whereType<ToolOutputItem>().single.output,
      contains('[ls ok]'),
    );
    expect(items.whereType<UserMessage>().first.text, contains('pre'));
    expect(items.whereType<UserMessage>().first.text, contains('[ls ok]'));
  });

  for (final name in [
    'agent-loop: Incompatible boundary',
    'context-compaction: Changed model or instructions',
    'context-compaction: Mixed lineage history',
  ]) {
    test(name, () async {
      final (w, _) = await fixture();
      await step(w, 1, [cut('older')]);
      await step(w, 2, [cut('newer')], model: 'different');
      await expectLater(
        builder(w).build(w.tree, turn: 3),
        throwsA(
          predicate(
            (e) =>
                '$e'.contains('incompatible continuity') &&
                '$e'.contains('rewind'),
          ),
        ),
      );
    });
  }

  test('context-compaction: Rewind across boundary', () async {
    final (w, _) = await fixture();
    await step(w, 1, [cut('A')]);
    await step(w, 2, [cut('B')]);
    await w.rewind(1);
    final b = await builder(w).build(w.tree, turn: 2);
    expect(content(b).first, isA<OpaqueCompactionItem>());
    expect((content(b).first as OpaqueCompactionItem).json, opaque('A'));
    await w.rewind(0);
    expect(content(await builder(w).build(w.tree, turn: 1)), isEmpty);
  });

  test('context-compaction: Replay and fork after compaction', () async {
    final (w, store) = await fixture();
    await w.apply(rec(1, 'scratch', Op.set, {'text': 'verbatim\r\n✓'}));
    await w.apply(
      rec(1, 'meta/test-correlation', Op.set, {
        'request': 'r',
        'child': 'c',
        'outcome': 'done',
      }),
    );
    await seedCall(w, store, callId: 'old', modelText: 'stored handle');
    final before = jsonEncode(w.tree.get(SessionPath.parse('body/calls')));
    await step(w, 2, [cut('A')]);
    final expected = content(await builder(w).build(w.tree, turn: 3));
    final call =
        w.tree.get(SessionPath.parse('body/calls/${callKey('old')}')) as Map;
    final handle = (call['model'] as Map)['handle'] as String;
    final fork = await w.fork(2);
    final child = await SessionWriter.open(fork.childDir);
    addTearDown(child.close);
    final dir = w.sessionDir;
    await w.close();
    final replayed = await SessionWriter.open(dir);
    addTearDown(replayed.close);
    for (final session in [child, replayed]) {
      expect(
        jsonEncode(session.tree.get(SessionPath.parse('body/calls'))),
        before,
      );
      expect(session.tree.get(SessionPath.parse('scratch')), {
        'text': 'verbatim\r\n✓',
      });
      expect(session.tree.get(SessionPath.parse('meta/test-correlation')), {
        'request': 'r',
        'child': 'c',
        'outcome': 'done',
      });
      expect(
        resolveHandle(
          session.tree,
          session.sessionDir,
          handle,
        ).file.readAsStringSync(),
        'stored handle',
      );
      final projected = content(
        await builder(session).build(session.tree, turn: 3),
      );
      expect(
        (projected.single as OpaqueCompactionItem).json,
        (expected.single as OpaqueCompactionItem).json,
      );
    }
  });

  test('boundary-aware baseline excludes old usage and resumes only on the same boundary', () async {
    final (w, _) = await fixture();
    await step(w, 1, [cut('A')], usage: {'input': 120000, 'output': 6000});
    expect((await builder(w).build(w.tree, turn: 2)).used, isNull);
    await step(
      w,
      2,
      [textEntry('small')],
      boundary: 's-00000001:0:A',
      usage: {'input': 1186, 'output': 8},
    );
    final compatible = await builder(w).build(w.tree, turn: 3);
    expect(compatible.used, lessThan(2000));
    await step(
      w,
      3,
      [cut('B')],
      boundary: 's-00000001:0:A',
      usage: {'input': 1186, 'output': 8},
    );
    expect((await builder(w).build(w.tree, turn: 4)).used, isNull);
  });

  test('agent-loop: Death before any runtime admission', () async {
    final (w, store) = await fixture();
    await step(w, 1, [
      callEntry('pre', 'bash'),
      cut('A'),
      callEntry('post', 'bash'),
    ]);
    final runtime = await ToolRuntime.attach(
      w,
      store,
      workspace: w.sessionDir,
      gate: const AllowAllStage(),
    );
    addTearDown(runtime.close);
    expect(runtime.resumed.calls, 2);
    for (final id in ['pre', 'post']) {
      final node =
          w.tree.get(SessionPath.parse('body/calls/${callKey(id)}')) as Map;
      expect(node['status'], 'cancelled');
      expect(node['reason'], 'interrupted_before_admission');
      expect(node['sourceStep'], 's-00000001');
      expect(node['sourceModel'], 'gpt-5.5');
      expect(node['callId'], id);
      expect(node['input'], <String, Object?>{});
      expect(node['model'], isA<Map<String, Object?>>());
    }
    final items = content(await builder(w).build(w.tree, turn: 2));
    expect(
      items.whereType<ToolOutputItem>().single.output,
      contains('execution not recorded; not replayed'),
    );
    expect(
      items.whereType<UserMessage>().single.text,
      contains('execution not recorded; not replayed'),
    );
    expect((await JobRecovery(w, store).resume()).calls, 0);
  });

  test('agent-loop: Partial admission and repeated reopen', () async {
    final (w, store) = await fixture();
    await step(w, 1, [
      callEntry('done', 'bash'),
      callEntry('pending', 'bash'),
      cut('A'),
      callEntry('missing', 'bash'),
    ]);
    await seedCall(w, store, callId: 'done', modelText: 'original effect');
    await seedCall(w, store, callId: 'pending', status: 'running');
    final original = jsonEncode(
      w.tree.get(SessionPath.parse('body/calls/${callKey('done')}')),
    );
    var interrupted = false;
    final dir = w.sessionDir;
    await w.close();
    late HookedIo io;
    final reopened = await SessionWriter.open(
      dir,
      decorate: (inner) => io = HookedIo(inner),
    );
    addTearDown(reopened.close);
    io.onWrite = (bytes) async {
      if (utf8.decode(bytes).contains('interrupted_before_admission')) {
        interrupted = true;
        throw StateError('simulated recovery death');
      }
    };
    await expectLater(
      JobRecovery(reopened, store).resume(),
      throwsA(isA<StorageError>()),
    );
    expect(interrupted, isTrue);
    await reopened.close();
    final again = await SessionWriter.open(dir);
    addTearDown(again.close);
    await JobRecovery(again, store).resume();
    expect(
      jsonEncode(
        again.tree.get(SessionPath.parse('body/calls/${callKey('done')}')),
      ),
      original,
    );
    final before = jsonEncode(again.tree.get(SessionPath.parse('body/calls')));
    expect((await JobRecovery(again, store).resume()).calls, 0);
    expect(jsonEncode(again.tree.get(SessionPath.parse('body/calls'))), before);
    expect((again.tree.get(SessionPath.parse('body/calls')) as Map).length, 3);
  });

  test('agent-loop: Rewind after recovery', () async {
    final (w, store) = await fixture();
    await step(w, 1, [
      callEntry('pre', 'bash'),
      cut('A'),
      callEntry('post', 'bash'),
    ]);
    await seedStep(w, 2, exchange: 1, state: 'running');
    final runtime = await ToolRuntime.attach(
      w,
      store,
      workspace: w.sessionDir,
      gate: const AllowAllStage(),
    );
    addTearDown(runtime.close);
    expect(
      w.tree.get(SessionPath.parse('body/calls')),
      isA<Map<String, Object?>>(),
    );
    expect((w.tree.get(SessionPath.parse('body/calls')) as Map).length, 2);
    await w.rewind(1);
    await runtime.jobs.reconciled();
    expect((w.tree.get(SessionPath.parse('body/calls')) as Map).length, 2);
    await w.rewind(0);
    await runtime.jobs.reconciled();
    expect(
      w.tree.get(SessionPath.parse('body/calls/${callKey('pre')}')),
      isNull,
    );
  });

  test(
    'recovery refuses conflicting metadata without replacing an outcome',
    () async {
      final (w, store) = await fixture();
      await step(w, 1, [callEntry('conflict', 'bash')]);
      await seedCall(
        w,
        store,
        callId: 'conflict',
        tool: 'read',
        modelText: 'retain me',
      );
      final before = jsonEncode(w.tree.get(SessionPath.parse('body/calls')));
      await expectLater(
        JobRecovery(w, store).resume(),
        throwsA(predicate((e) => '$e'.contains('conflicting committed call'))),
      );
      expect(jsonEncode(w.tree.get(SessionPath.parse('body/calls'))), before);
    },
  );

  test('recovery skips registered live positions and builder requires terminal coverage', () async {
    final (w, store) = await fixture();
    await step(w, 1, [callEntry('live', 'bash'), cut('A')]);
    await JobRecovery(w, store).reconcile(liveCalls: {callKey('live')});
    expect(
      w.tree.get(SessionPath.parse('body/calls/${callKey('live')}')),
      isNull,
    );
    await expectLater(builder(w).build(w.tree, turn: 2), throwsStateError);
  });

  test(
    'unknown output variants fail visibly even before the selected cut',
    () async {
      final (w, _) = await fixture();
      await step(w, 1, [
        {'type': 'future-opaque'},
      ]);
      await step(w, 2, [cut('A')]);
      await expectLater(
        builder(w).build(w.tree, turn: 3),
        throwsA(predicate((e) => '$e'.contains('unknown committed output'))),
      );
    },
  );

  test(
    'opaque suffix must match lineage even without a newer boundary',
    () async {
      final (w, _) = await fixture();
      await step(w, 1, [cut('A')]);
      await step(w, 2, [
        {
          'type': 'reasoning',
          'item': {
            'type': 'reasoning',
            'id': 'r',
            'encrypted_content': 'secret',
          },
        },
      ], model: 'other');
      await expectLater(
        builder(w).build(w.tree, turn: 3),
        throwsA(predicate((e) => '$e'.contains('incompatible continuity'))),
      );
    },
  );

  test('all lineage dimensions reject incompatible continuity; policy alone does not', () async {
    for (final field in [
      'provider',
      'route',
      'model',
      'instructions',
      'tools',
    ]) {
      final (w, _) = await fixture();
      await step(w, 1, [cut('A')]);
      await w.apply(
        rec(1, 'body/steps/s-00000001', Op.merge, {
          'lineage': {...lineage(), field: 'other'},
        }),
      );
      await expectLater(
        builder(w).build(w.tree, turn: 2),
        throwsStateError,
        reason: field,
      );
    }
    final (w, _) = await fixture();
    await step(w, 1, [cut('A')]);
    await w.apply(
      rec(1, 'body/steps/s-00000001', Op.merge, {
        'policy': {'strategy': 'off', 'threshold': 2000},
      }),
    );
    expect(
      content(await builder(w).build(w.tree, turn: 2)).first,
      isA<OpaqueCompactionItem>(),
    );
  });

  test(
    'incompatible admission records current lineage and policy without sending',
    () async {
      final (w, store) = await fixture();
      await step(w, 1, [cut('A')], model: 'other');
      final runtime = await ToolRuntime.attach(
        w,
        store,
        workspace: w.sessionDir,
        gate: const AllowAllStage(),
      );
      addTearDown(runtime.close);
      final provider = FakeProvider.steps([]);
      final driver = ExchangeDriver(
        writer: w,
        runtime: runtime,
        provider: provider,
        model: 'gpt-5.5',
      );
      final admitted = await driver.submit(
        id: 'next',
        text: 'continue',
        turn: w.currentTurn,
      ) as SubmitAdmitted;
      expect((await admitted.done).state, 'stopped');
      expect(provider.requests, isEmpty);
      final steps = w.tree.get(SessionPath.parse('body/steps')) as Map;
      final failed =
          steps.values.where((s) => (s as Map)['state'] == 'failed').single
              as Map;
      expect(failed['policy'], isA<Map<String, Object?>>());
      expect((failed['lineage'] as Map)['model'], 'gpt-5.5');
    },
  );

  test('recovery refuses conflicting source model metadata', () async {
    final (w, store) = await fixture();
    await step(w, 1, [callEntry('conflict-model', 'bash')]);
    await seedCall(
      w,
      store,
      callId: 'conflict-model',
      modelText: 'retain me',
      extra: {'sourceStep': 's-00000001', 'sourceModel': 'other'},
    );
    await expectLater(
      JobRecovery(w, store).resume(),
      throwsA(predicate((e) => '$e'.contains('conflicting committed call'))),
    );
  });
}

final class _CountTool implements Tool {
  _CountTool(this.effect);
  final void Function() effect;
  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    effect();
    return const ToolOutcome(summary: 'settled once');
  }
}
