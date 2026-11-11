import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:kehai/kehai.dart';
import 'package:kehai/src/provider/chatgpt_request.dart';
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
  test(
    'tools survive settled-call compaction reconstruction and reopen',
    () async {
      var w = await createWriter(await tempDir());
      addTearDown(() => w.close());
      var effects = 0;
      Future<ToolRuntime> attach() => ToolRuntime.attach(
        w,
        ResultStore(w.sessionDir),
        workspace: w.sessionDir,
        gate: const AllowAllStage(),
        tools: {'ls': _CountTool(() => effects++)},
      );
      var runtime = await attach();
      final provider = FakeProvider.steps([
        [
          CompactionItem(opaque('selected'), outputIndex: 0),
          const ToolCall(
            callId: 'settled',
            name: 'ls',
            argumentsJson: '{}',
            outputIndex: 1,
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
      try {
        final submitted = await driver.submit(
          id: 'first',
          text: 'go',
          turn: w.currentTurn,
        ) as SubmitAdmitted;
        expect((await submitted.done).state, 'done');
      } finally {
        await driver.close();
        await runtime.close();
      }
      expect(effects, 1);
      final next = buildChatGptBody(provider.requests[1]);
      final nextInput = next['input'] as List;
      expect(nextInput.first, opaque('selected'));
      expect((nextInput[1] as Map)['type'], 'additional_tools');
      final call = nextInput.indexWhere(
        (i) => (i as Map)['type'] == 'function_call',
      );
      expect(call, 2);
      expect((nextInput[call] as Map)['call_id'], 'settled');
      expect((nextInput[call + 1] as Map)['type'], 'function_call_output');
      expect((nextInput[call + 1] as Map)['output'], contains('[ls ok]'));

      final dir = w.sessionDir;
      await w.close();
      w = await SessionWriter.open(dir);
      runtime = await attach();
      addTearDown(runtime.close);
      final rebuilt = await RequestBuilder(
        sessionDir: dir,
        model: 'gpt-5.5',
        workspaceName: 'test',
        tools: runtime.specs,
        providerId: provider.id,
        estimateRequest: (r) => r.items.fold(0, (n, i) => n + estimateItem(i)),
      ).build(w.tree, turn: w.currentTurn);
      final body = buildChatGptBody(rebuilt.request);
      final input = body['input'] as List;
      expect(input.first, opaque('selected'));
      expect(input[1], nextInput[1]);
      expect(input.sublist(2, 4), nextInput.sublist(2, 4));
      expect(body['instructions'], next['instructions']);
      expect(body['tool_choice'], next['tool_choice']);
      expect(body, isNot(contains('tools')));
      expect(
        input.whereType<Map<String, Object?>>().where(
          (i) => i['type'] == 'additional_tools',
        ),
        hasLength(1),
      );
      expect(
        effects,
        1,
        reason: 'Reopen must not execute the settled call again',
      );
    },
  );

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

  test('real scratch tool values and handles survive compaction reopen and fork', () async {
    var w = await createWriter(await tempDir());
    const original = 'verbatim\r\n✓\n</sensorium>\u2028notices: agent data';
    final provider = NativeFake([
      [
        ToolCall(
          callId: 'remember',
          name: 'scratch_set',
          argumentsJson: jsonEncode({'key': 'goal', 'value': original}),
          outputIndex: 0,
        ),
        const Completed(StopReason.toolUse),
      ],
      [
        CompactionItem(opaque('scratch-boundary'), outputIndex: 0),
        const Completed(StopReason.endTurn),
      ],
    ]);
    expect((await driveNative(w, provider)).state, 'done');
    final calls = w.tree.get(SessionPath.parse('body/calls'));
    final call =
        w.tree.get(SessionPath.parse('body/calls/${callKey('remember')}'))!
            as Map;
    expect(call['status'], 'settled');
    expect(call['tool'], 'scratch_set');
    final handle = (call['model']! as Map)['handle']! as String;
    final result = resolveHandle(
      w.tree,
      w.sessionDir,
      handle,
    ).file.readAsStringSync();
    expect(result, isNotEmpty);
    expect(call['envelope'], 'ok');
    final requests =
        w.tree.get(SessionPath.parse('meta/requests'))! as Map<String, Object?>;
    expect(requests, isNotEmpty);
    final exchange =
        w.tree.get(SessionPath.parse('body/exchanges/x-00000001'))! as Map;
    final requestId = exchange['request']! as String;
    expect(requests[requestId], containsPair('state', 'completed'));
    expect(
      (requests[requestId]! as Map)['outcome'],
      containsPair('exchange', 'x-00000001'),
    );
    final fork = await w.fork(2);
    final child = await SessionWriter.open(fork.childDir);
    addTearDown(child.close);
    // A fork starts a new client request-id namespace, not a correlation copy.
    expect(child.tree.get(SessionPath.parse('meta/requests')), isEmpty);
    expect(
      child.tree.get(SessionPath.parse('body/exchanges/x-00000001')),
      exchange,
    );
    // A later real overwrite and deletion must rewind to the original value.
    final mutate = NativeFake([
      [
        const ToolCall(
          callId: 'overwrite',
          name: 'scratch_set',
          argumentsJson: '{"key":"goal","value":"later value"}',
          outputIndex: 0,
        ),
        const Usage(input: 1000, output: 10),
        const Completed(StopReason.toolUse),
      ],
      [
        const ToolCall(
          callId: 'delete',
          name: 'scratch_del',
          argumentsJson: '{"key":"goal"}',
          outputIndex: 0,
        ),
        const Usage(input: 1100, output: 10),
        const Completed(StopReason.toolUse),
      ],
      [
        const Usage(input: 1200, output: 10),
        const Completed(StopReason.endTurn),
      ],
    ]);
    expect((await driveNative(w, mutate)).state, 'done');
    expect(w.tree.get(SessionPath.parse('scratch/goal')), isNull);
    final dir = w.sessionDir;
    await w.close();
    w = await SessionWriter.open(dir);
    addTearDown(w.close);
    expect(w.tree.get(SessionPath.parse('scratch/goal')), isNull);
    for (final request in requests.entries) {
      expect(
        w.tree.get(SessionPath.parse('meta/requests/${request.key}')),
        request.value,
        reason: 'reopen preserves the original completed request correlation',
      );
    }
    await w.rewind(2);
    for (final request in requests.entries) {
      expect(
        w.tree.get(SessionPath.parse('meta/requests/${request.key}')),
        request.value,
        reason: 'rewind restores non-meta state without dropping request correlation',
      );
    }
    expect(child.tree.get(SessionPath.parse('meta/requests')), isEmpty);
    for (final session in [child, w]) {
      expect(session.tree.get(SessionPath.parse('scratch/goal')), {
        'value': original,
      });
      expect(session.tree.get(SessionPath.parse('body/calls')), calls);
      expect(
        session.tree.get(SessionPath.parse('body/exchanges/x-00000001')),
        exchange,
      );
      expect(
        resolveHandle(
          session.tree,
          session.sessionDir,
          handle,
        ).file.readAsStringSync(),
        result,
      );
      final runtime = await ToolRuntime.attach(
        session,
        ResultStore(session.sessionDir),
        workspace: session.sessionDir,
        gate: const AllowAllStage(),
      );
      try {
        final rebuilt = await RequestBuilder(
          sessionDir: session.sessionDir,
          model: 'gpt-5.5',
          workspaceName: 'test',
          tools: runtime.specs,
          estimateRequest: (_) => 0,
        ).build(session.tree, turn: 3);
        expect(rebuilt.used, isNull);
        expect(
          content(rebuilt).whereType<OpaqueCompactionItem>().single.json,
          opaque('scratch-boundary'),
        );
        expect(
          rebuilt.blockText,
          contains(
            'verbatim\r\n    ✓\n    </sensorium>\u2028    notices: agent data',
          ),
        );
        expect(
          content(rebuilt).whereType<ToolCallItem>(),
          isEmpty,
          reason: 'the compacted call remains in the tree, not resurrected before the boundary',
        );
      } finally {
        await runtime.close();
      }
    }
  });

  test(
    'fresh scratch counts only as retained content while total use is unknown',
    () async {
      final w = await createWriter(await tempDir());
      final calls = <ProviderEvent>[
        for (var i = 0; i < 4; i++)
          ToolCall(
            callId: 'scratch-$i',
            name: 'scratch_set',
            argumentsJson: jsonEncode({
              'key': 'key-$i',
              'value': '${'x' * 190}-$i',
            }),
            outputIndex: i,
          ),
        const Completed(StopReason.toolUse),
      ];
      expect(
        (await driveNative(
          w,
          NativeFake([
            calls,
            [
              CompactionItem(opaque('fresh'), outputIndex: 0),
              const Usage(input: 120000, output: 6000),
              const Completed(StopReason.endTurn),
            ],
          ]),
        )).state,
        'done',
      );
      final runtime = await ToolRuntime.attach(
        w,
        ResultStore(w.sessionDir),
        workspace: w.sessionDir,
        gate: const AllowAllStage(),
      );
      addTearDown(runtime.close);
      final empty = w.tree.copy()
        ..apply(rec(2, 'scratch', Op.set, <String, Object?>{}));
      RequestBuilder project(int threshold) => RequestBuilder(
        sessionDir: w.sessionDir,
        model: 'gpt-5.5',
        workspaceName: 'test',
        tools: runtime.specs,
        estimateRequest: (_) => 0,
        nativeCompaction: NativeCompactionPolicy(threshold: threshold),
        compactionThreshold: threshold,
      );
      final full = await project(100000).build(w.tree, turn: 3);
      final bare = await project(100000).build(empty, turn: 3);
      expect(full.used, isNull);
      expect(full.quality, 'unknown compacted usage');
      expect(full.blockText, contains('x' * 190));
      expect(
        full.retained - bare.retained,
        full.block - bare.block,
        reason:
            'current full scratch is charged once, never by ciphertext size',
      );
      expect(full.retained - bare.retained, greaterThan(200));
      final threshold = full.retained + bare.retained;
      final guardFull = await project(threshold).build(w.tree, turn: 3);
      final guardBare = await project(threshold).build(empty, turn: 3);
      expect(guardBare.retained * 2, lessThan(threshold));
      expect(guardFull.retained * 2, greaterThan(threshold));
      await runtime.close();
      final blocked = NativeFake([], estimate: 0);
      final result = await driveNative(
        w,
        blocked,
        config: nativeConfig(threshold: threshold),
      );
      expect(result.state, 'stopped');
      expect(
        result.reason,
        contains('retained-content calibration cap exceeded'),
      );
      expect(blocked.requests, isEmpty);
      expect((lastStep(w)['context']! as Map)['used'], isNull);
      expect(lastStep(w)['calibration'], isNot(true));
    },
  );

  test(
    'scratch roster upgrade refuses old opaque continuity without fallback',
    () async {
      for (final dimension in ['tools', 'instructions', 'both']) {
        final (w, _) = await fixture();
        final runtime = await ToolRuntime.attach(
          w,
          ResultStore(w.sessionDir),
          workspace: w.sessionDir,
          gate: const AllowAllStage(),
        );
        addTearDown(runtime.close);
        final current = RequestBuilder(
          sessionDir: w.sessionDir,
          model: 'gpt-5.5',
          workspaceName: 'test',
          tools: runtime.specs,
          estimateRequest: (_) => 0,
        );
        final beforeScratch = RequestBuilder(
          sessionDir: w.sessionDir,
          model: 'gpt-5.5',
          workspaceName: 'test',
          tools: runtime.specs
              .where((tool) => !tool.name.startsWith('scratch_'))
              .toList(),
          estimateRequest: (_) => 0,
        );
        final compatible = current.requestLineage(w.tree);
        final old = <String, Object?>{
          ...compatible,
          if (dimension != 'instructions')
            'tools': beforeScratch.requestLineage(w.tree)['tools'],
          if (dimension != 'tools')
            'instructions': digest('pre-scratch built-in guidance'),
        };
        await step(w, 1, [cut('compatible-older')]);
        await w.apply(
          rec(1, 'body/steps/s-00000001', Op.merge, {'lineage': compatible}),
        );
        await step(w, 2, [cut('incompatible-latest')]);
        await w.apply(
          rec(2, 'body/steps/s-00000002', Op.merge, {'lineage': old}),
        );
        final before = journalOf(w.sessionDir).readAsBytesSync();
        await expectLater(
          current.build(w.tree, turn: 3),
          throwsA(
            predicate(
              (error) =>
                  '$error'.contains('incompatible continuity') &&
                  '$error'.contains('rewind') &&
                  '$error'.contains('new session'),
            ),
          ),
        );
        expect(journalOf(w.sessionDir).readAsBytesSync(), before);
        await runtime.close();
        final provider = NativeFake([]);
        final refused = await driveNative(w, provider);
        expect(refused.state, 'stopped');
        expect(refused.reason, contains('incompatible continuity'));
        expect(
          provider.requests,
          isEmpty,
          reason: 'no ciphertext forwarding or older-prefix fallback',
        );
      }
    },
  );

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

  group5Tests();
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

// Native policy exercised through the real driver with no network adapter.
final class NativeFake implements ModelProvider {
  NativeFake(
    List<List<ProviderEvent>> scripts, {
    int estimate = 5000,
    this.onSend,
  }) : fake = FakeProvider.steps(scripts, estimator: (_) => estimate);
  final void Function()? onSend;
  final FakeProvider fake;
  List<ModelRequest> get requests => fake.requests;
  @override
  String get id => 'openai';
  @override
  TokenEstimate estimate(ModelRequest request) => fake.estimate(request);
  @override
  Future<List<ModelInfo>> listModels() => fake.listModels();
  @override
  Stream<ProviderEvent> stream(ModelRequest request, {CancelToken? cancel}) {
    onSend?.call();
    return fake.stream(request, cancel: cancel);
  }
}

UserConfig nativeConfig({int threshold = 100000, bool off = false}) =>
    UserConfig(
      providers: {
        'openai': ProviderConfig(
          compaction: CompactionSettings(
            strategy: off
                ? CompactionStrategy.off
                : CompactionStrategy.providerNative,
            threshold: threshold,
          ),
        ),
      },
    );

int _nativeRequestId = 0;

Future<ExchangeResult> driveNative(
  SessionWriter w,
  NativeFake provider, {
  UserConfig config = const UserConfig(),
  String text = 'go',
}) async {
  final runtime = await ToolRuntime.attach(
    w,
    ResultStore(w.sessionDir),
    workspace: w.sessionDir,
    gate: const AllowAllStage(),
    config: config,
  );
  try {
    final driver = ExchangeDriver(
      writer: w,
      runtime: runtime,
      provider: provider,
      model: 'gpt-5.5',
    );
    final admitted = await driver.submit(
      id: 'native-${_nativeRequestId++}',
      text: text,
      turn: w.currentTurn,
    ) as SubmitAdmitted;
    return await admitted.done;
  } finally {
    await runtime.close();
  }
}

Map<String, Object?> lastStep(SessionWriter w) =>
    (w.tree.get(SessionPath.parse('body/steps')) as Map).values.last
        as Map<String, Object?>;

void group5Tests() {
  const done = Completed(StopReason.endTurn);
  for (final (label, usage) in [
    ('empty', const Usage()),
    ('output only', const Usage(output: 8)),
    ('input only below threshold', const Usage(input: 1186)),
  ]) {
    test(
      'context-compaction: Calibration $label usage stops without a baseline',
      () async {
        final w = await createWriter(await tempDir());
        await driveNative(
          w,
          NativeFake([
            [CompactionItem(opaque('A'), outputIndex: 0), done],
          ]),
        );
        final p = NativeFake([
          [usage, done],
        ]);
        final result = await driveNative(w, p);
        expect(result.state, 'stopped');
        expect(result.reason, contains('calibration usage unavailable'));
        expect(lastStep(w)['nativeStop'], 'calibration usage unavailable');
        expect(lastStep(w)['state'], 'completed');
        expect(lastStep(w)['calibration'], isTrue);
        expect(lastStep(w)['capability'], {
          'state': 'observed-supported',
          'reason': 'compaction item observed',
        });
        expect(p.requests, hasLength(1));
        final dir = w.sessionDir;
        await w.close();
        final reopened = await SessionWriter.open(dir);
        addTearDown(reopened.close);
        final blocked = NativeFake([
          [done],
        ]);
        expect(
          (await driveNative(reopened, blocked)).reason,
          contains('calibration allowance consumed'),
        );
        expect(blocked.requests, isEmpty);
      },
    );
  }
  test('context-compaction: Calibration input alone proves missing compaction at threshold', () async {
    final w = await createWriter(await tempDir());
    await driveNative(
      w,
      NativeFake([
        [CompactionItem(opaque('A'), outputIndex: 0), done],
      ]),
    );
    final result = await driveNative(
      w,
      NativeFake([
        [const Usage(input: 100000), done],
      ]),
    );
    expect(result.state, 'stopped');
    expect(result.reason, contains('no compaction item at threshold'));
    expect(lastStep(w)['calibration'], isTrue);
    expect(lastStep(w)['capability'], {
      'state': 'unsupported',
      'reason': 'no compaction item at threshold',
    });
  });
  for (final (label, usage) in [
    ('empty', const Usage()),
    ('output only', const Usage(output: 8)),
  ]) {
    test(
      'context-compaction: Ordinary $label usage qualifies estimated input',
      () async {
        final w = await createWriter(await tempDir());
        final result = await driveNative(
          w,
          NativeFake([
            [usage, done],
          ], estimate: 100000),
        );
        expect(result.state, 'stopped');
        expect(
          result.reason,
          contains('estimated input at threshold without compaction'),
        );
        expect(
          lastStep(w)['nativeStop'],
          'estimated input at threshold without compaction',
        );
        expect(lastStep(w)['capability'], {
          'state': 'unsupported',
          'reason': 'estimated input at threshold without compaction',
        });
      },
    );
  }
  test('context-compaction: Unrelated capability rejections do not mark native unsupported', () async {
    for (final kind in [
      ProviderFailureKind.invalidRequest,
      ProviderFailureKind.notPermitted,
    ]) {
      final w = await createWriter(await tempDir());
      final result = await driveNative(
        w,
        NativeFake([
          [
            Failed(
              ProviderFailure(
                kind: kind,
                code: 'unsupported_capability',
                message: 'unsupported capability: reasoning_effort',
                sent: false,
              ),
            ),
          ],
        ]),
      );
      expect(result.state, 'failed');
      expect(lastStep(w)['nativeStop'], isNull);
      expect(lastStep(w)['capability'], {
        'state': 'unverified',
        'reason': 'no conclusive observation',
      });
    }
  });
  test('context-compaction: Observed support', () async {
    final w = await createWriter(await tempDir());
    final p = NativeFake([
      [CompactionItem(opaque('A'), outputIndex: 0), done],
    ]);
    await driveNative(w, p);
    expect(lastStep(w)['capability'], {
      'state': 'observed-supported',
      'reason': 'compaction item observed',
    });
    expect(p.requests.single.nativeCompaction?.threshold, 100000);
  });

  for (final name in [
    'context-compaction: Threshold request silently ignored',
    'agent-loop: Compaction missing at safety threshold',
  ]) {
    test(name, () async {
      final w = await createWriter(await tempDir());
      final p = NativeFake([
        [const Usage(input: 100000, output: 6), done],
      ]);
      final result = await driveNative(w, p);
      expect(result.state, 'stopped');
      expect(result.reason, contains('no compaction item at threshold'));
      expect(lastStep(w)['state'], 'completed');
      expect(lastStep(w)['capability'], {
        'state': 'unsupported',
        'reason': 'no compaction item at threshold',
      });
      expect(p.requests, hasLength(1));
    });
  }
  test('context-compaction: Field rejected', () async {
    final w = await createWriter(await tempDir());
    final p = NativeFake([
      [
        Failed(
          ProviderFailure(
            kind: ProviderFailureKind.invalidRequest,
            message: 'unsupported context_management SECRET cipher',
            sent: false,
          ),
        ),
      ],
    ]);
    final result = await driveNative(w, p);
    expect(result.reason, contains('context_management rejected'));
    expect(lastStep(w)['capability'], {
      'state': 'unsupported',
      'reason': 'context_management rejected',
    });
    expect(jsonEncode(lastStep(w)), isNot(contains('SECRET')));
    expect(p.requests, hasLength(1));
  });
  test('context-compaction: Below threshold or inconclusive', () async {
    for (final script in <List<ProviderEvent>>[
      [const Usage(input: 99999, output: 10000), done],
      [
        const Usage(input: 110000, output: 1),
        Failed(
          ProviderFailure(
            kind: ProviderFailureKind.protocol,
            message: 'stream interrupted',
          ),
        ),
      ],
      [
        Failed(
          ProviderFailure(
            kind: ProviderFailureKind.invalidRequest,
            message: 'unrelated rejection',
          ),
        ),
      ],
    ]) {
      final w = await createWriter(await tempDir());
      await driveNative(w, NativeFake([script]));
      expect(lastStep(w)['capability'], {
        'state': 'unverified',
        'reason': 'no conclusive observation',
      });
    }
  });
  test('context-compaction: Estimate-based missing compaction', () async {
    final w = await createWriter(await tempDir());
    final result = await driveNative(
      w,
      NativeFake([
        [done],
      ], estimate: 100000),
    );
    expect(result.state, 'stopped');
    expect(
      result.reason,
      contains('estimated input at threshold without compaction'),
    );
    expect((lastStep(w)['capability'] as Map)['state'], 'unsupported');
  });
  test('context-compaction: Unsupported policy stays explicit', () async {
    final w = await createWriter(await tempDir());
    await driveNative(
      w,
      NativeFake([
        [const Usage(input: 100000, output: 0), done],
      ]),
    );
    final blocked = NativeFake([
      [done],
    ]);
    final result = await driveNative(w, blocked);
    expect(blocked.requests, isEmpty);
    expect(result.reason, contains('explicitly select off'));
    final recovered = NativeFake([
      [done],
    ]);
    await driveNative(w, recovered, config: nativeConfig(off: true));
    expect(recovered.requests.single.nativeCompaction, isNull);
    final notices = recovered.requests.single.items
        .whereType<UserMessage>()
        .map((i) => i.text)
        .join('\n');
    expect(notices, contains('no compaction item at threshold'));
    expect(notices, isNot(contains('SECRET')));
  });
  test(
    'context-compaction: Successful calibration despite old large usage',
    () async {
      final w = await createWriter(await tempDir());
      await driveNative(
        w,
        NativeFake([
          [
            const Usage(input: 120000, output: 6000),
            CompactionItem(opaque('A'), outputIndex: 0),
            done,
          ],
        ]),
      );
      final calibrate = NativeFake([
        [const Usage(input: 1186, output: 8), done],
      ]);
      expect((await driveNative(w, calibrate)).state, 'done');
      expect(lastStep(w)['calibration'], isTrue);
      final context = lastStep(w)['context'] as Map;
      expect(context['used'], isNull);
      expect(context['retained'], lessThanOrEqualTo(50000));
      final ordinary = NativeFake([
        [const Usage(input: 1300, output: 8), done],
      ]);
      expect((await driveNative(w, ordinary)).state, 'done');
      expect(lastStep(w)['calibration'], isNot(true));
      expect((lastStep(w)['context'] as Map)['used'], lessThan(10000));
    },
  );
  test('context-compaction: Ordinary or suffix admission refuses', () async {
    for (final estimate in [125001, 300000]) {
      final w = await createWriter(await tempDir());
      final p = NativeFake([
        [done],
      ], estimate: estimate);
      expect(
        (await driveNative(w, p)).reason,
        contains('submission safety ceiling'),
      );
      expect(p.requests, isEmpty);
    }
    for (final size in [160000, 1100000]) {
      final w = await createWriter(await tempDir());
      await driveNative(
        w,
        NativeFake([
          [CompactionItem(opaque('A'), outputIndex: 0), done],
        ]),
      );
      final p = NativeFake([
        [done],
      ]);
      final result = await driveNative(w, p, text: 'x' * size);
      expect(result.state, 'stopped');
      expect(
        result.reason,
        contains(size > 1000000 ? '1 MiB' : 'retained-content'),
      );
      expect(p.requests, isEmpty);
    }
  });
  test('context-compaction: Calibration has no usage or dies', () async {
    for (final script in <List<ProviderEvent>>[
      [done],
      [
        Failed(
          ProviderFailure(kind: ProviderFailureKind.protocol, message: 'death'),
        ),
      ],
    ]) {
      final w = await createWriter(await tempDir());
      await driveNative(
        w,
        NativeFake([
          [CompactionItem(opaque('A'), outputIndex: 0), done],
        ]),
      );
      final result = await driveNative(w, NativeFake([script]));
      expect(lastStep(w)['calibration'], isTrue);
      if (script.first is Completed) {
        expect(result.reason, contains('calibration usage unavailable'));
        expect(
          (lastStep(w)['capability'] as Map)['state'],
          'observed-supported',
        );
      }
      final dir = w.sessionDir;
      await w.close();
      final reopened = await SessionWriter.open(dir);
      addTearDown(reopened.close);
      final p = NativeFake([
        [done],
      ]);
      final blocked = await driveNative(
        reopened,
        p,
        config: nativeConfig(threshold: 110000),
      );
      expect(p.requests, isEmpty);
      expect(blocked.reason, contains('calibration allowance consumed'));
    }
  });
  test('context-compaction: Resume and policy change', () async {
    final w = await createWriter(await tempDir());
    await driveNative(
      w,
      NativeFake([
        [const Usage(input: 100000, output: 0), done],
      ]),
    );
    final dir = w.sessionDir;
    await w.close();
    final reopened = await SessionWriter.open(dir);
    addTearDown(reopened.close);
    final blocked = NativeFake([
      [done],
    ]);
    expect((await driveNative(reopened, blocked)).state, 'stopped');
    expect(blocked.requests, isEmpty);
    await driveNative(
      reopened,
      NativeFake([
        [done],
      ]),
      config: nativeConfig(threshold: 110000),
    );
    expect((lastStep(reopened)['capability'] as Map)['state'], 'unverified');
    final returned = NativeFake([
      [done],
    ]);
    expect((await driveNative(reopened, returned)).state, 'stopped');
    expect(returned.requests, isEmpty);
  });
  test('context-compaction: Rewind removes evidence', () async {
    final w = await createWriter(await tempDir());
    await driveNative(
      w,
      NativeFake([
        [CompactionItem(opaque('A'), outputIndex: 0), done],
      ]),
    );
    final keep = w.currentTurn;
    await driveNative(
      w,
      NativeFake([
        [const Usage(input: 100000, output: 0), done],
      ]),
    );
    expect(lastStep(w)['capability'], {
      'state': 'unsupported',
      'reason': 'no compaction item at threshold',
    });
    await w.rewind(keep);
    final p = NativeFake([
      [CompactionItem(opaque('B'), outputIndex: 0), done],
    ]);
    expect((await driveNative(w, p)).state, 'done');
    expect((lastStep(w)['capability'] as Map)['state'], 'observed-supported');
  });
  test(
    'calibration is durably consumed before send and never retried',
    () async {
      final w = await createWriter(await tempDir());
      await driveNative(
        w,
        NativeFake([
          [CompactionItem(opaque('A'), outputIndex: 0), done],
        ]),
      );
      var sent = 0;
      final p = NativeFake(
        [
          [
            Failed(
              ProviderFailure(
                kind: ProviderFailureKind.server,
                message: 'not started',
                sent: false,
              ),
            ),
          ],
        ],
        onSend: () {
          sent++;
          expect(lastStep(w)['calibration'], isTrue);
          expect(lastStep(w)['state'], 'running');
        },
      );
      await driveNative(w, p);
      expect(sent, 1);
      final blocked = NativeFake([
        [done],
      ]);
      expect(
        (await driveNative(w, blocked)).reason,
        contains('calibration allowance consumed'),
      );
      expect(blocked.requests, isEmpty);
    },
  );
  test(
    'huge post-cut tool outputs and pre-cut result notes refuse calibration',
    () async {
      for (final preCut in [false, true]) {
        final w = await createWriter(await tempDir());
        await driveNative(
          w,
          NativeFake([
            [CompactionItem(opaque('A'), outputIndex: 0), done],
          ]),
        );
        await w.apply(
          rec(w.currentTurn, 'body/steps/s-00000001', Op.merge, {
            'output': preCut
                ? [callEntry('large', 'bash'), cut('A')]
                : [cut('A'), callEntry('large', 'bash')],
          }),
        );
        await seedCall(
          w,
          ResultStore(w.sessionDir),
          callId: 'large',
          modelText: 'x' * 160000,
        );
        final p = NativeFake([
          [done],
        ]);
        final result = await driveNative(w, p);
        expect(
          result.reason,
          contains('retained-content calibration cap exceeded'),
        );
        expect(p.requests, isEmpty);
      }
    },
  );
  test(
    'calibration respects a qualified window smaller than half threshold',
    () async {
      final w = await createWriter(await tempDir());
      await driveNative(
        w,
        NativeFake([
          [CompactionItem(opaque('A'), outputIndex: 0), done],
        ]),
      );
      final p = NativeFake([
        [done],
      ]);
      const config = UserConfig(
        providers: {
          'openai': ProviderConfig(
            routes: {
              'chatgpt-account': RouteConfig(
                models: {'gpt-5.5': RouteModelConfig(contextWindow: 4000)},
              ),
            },
          ),
        },
      );
      expect(
        (await driveNative(w, p, config: config)).reason,
        contains('context overflow'),
      );
      expect(p.requests, isEmpty);
      expect(lastStep(w)['calibration'], isNot(true));
    },
  );
  test(
    'off recovery refuses an oversized retained suffix with unknown usage',
    () async {
      final w = await createWriter(await tempDir());
      await driveNative(
        w,
        NativeFake([
          [CompactionItem(opaque('A'), outputIndex: 0), done],
        ]),
      );
      final p = NativeFake([
        [done],
      ]);
      const config = UserConfig(
        providers: {
          'openai': ProviderConfig(
            compaction: CompactionSettings(strategy: CompactionStrategy.off),
            routes: {
              'chatgpt-account': RouteConfig(
                models: {'gpt-5.5': RouteModelConfig(contextWindow: 4000)},
              ),
            },
          ),
        },
      );
      final result = await driveNative(
        w,
        p,
        config: config,
        text: 'oversized suffix ' * 4000,
      );
      expect(result.state, 'stopped');
      expect(result.reason, contains('context overflow'));
      expect(p.requests, isEmpty);
      final step = lastStep(w);
      expect(step['boundary'], isNotNull);
      expect(step['policy'], containsPair('strategy', 'off'));
      final context = step['context'] as Map;
      expect(context['used'], isNull);
      expect(context['retained'], greaterThan(context['window'] as int));
      expect(context['calibration'], isFalse);
      expect(step['nativeStop'], isNull);
      expect(step['calibration'], isNot(true));
    },
  );
  test(
    'death before calibration completion preserves the admitted allowance',
    () async {
      final (w, io) = await createHooked(await tempDir());
      await driveNative(
        w,
        NativeFake([
          [CompactionItem(opaque('A'), outputIndex: 0), done],
        ]),
      );
      io.onWrite = (bytes) async {
        if (utf8.decode(bytes).contains('"state":"completed"')) {
          throw StateError('death before calibration completion');
        }
      };
      await expectLater(
        driveNative(
          w,
          NativeFake([
            [done],
          ]),
        ),
        throwsA(isA<StorageError>()),
      );
      final dir = w.sessionDir;
      await w.close();
      final reopened = await SessionWriter.open(dir);
      addTearDown(reopened.close);
      // The allowance is an admission fact even though completion never committed.
      expect(lastStep(reopened)['calibration'], isTrue);
      expect(lastStep(reopened)['state'], 'running');
      final runtime = await ToolRuntime.attach(
        reopened,
        ResultStore(dir),
        workspace: dir,
        gate: const AllowAllStage(),
      );
      try {
        await ExchangeDriver(
          writer: reopened,
          runtime: runtime,
          provider: NativeFake([
            [done],
          ]),
          model: 'gpt-5.5',
        ).finalizeUnfinished();
      } finally {
        await runtime.close();
      }
      final p = NativeFake([
        [done],
      ]);
      final result = await driveNative(reopened, p);
      expect(result.reason, contains('calibration allowance consumed'));
      expect(p.requests, isEmpty);
    },
  );
}
