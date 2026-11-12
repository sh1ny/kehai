import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/fake_provider.dart';
import '../support/rpc_support.dart';
import '../support/session_support.dart';

const _secret = 'PRIVATE-SCRATCH-NOT-A-DIAGNOSTIC';
const _opaque = {
  'type': 'compaction',
  'id': 'sensorium-native',
  'encrypted_content': 'CIPHERTEXT-NOT-A-DIAGNOSTIC',
};

UserConfig _config({int ceiling = 1500, String model = 'modelA'}) => UserConfig(
  // A direct legacy-config seam, not the strict startup JSON parser.
  sensorium: SensoriumSettings(maxTokens: ceiling),
  providers: {
    'fake': ProviderConfig(
      routes: {
        'chatgpt-account': RouteConfig(
          models: {
            model: RouteModelConfig(
              contextWindow: 200000,
              compaction: CompactionSettings(
                strategy: CompactionStrategy.providerNative,
                threshold: 100000,
              ),
            ),
          },
        ),
      },
    ),
  },
);

ToolCall _set(String id, String value) => ToolCall(
  callId: id,
  name: 'scratch_set',
  argumentsJson: jsonEncode({'key': 'goal', 'value': value}),
  outputIndex: 0,
);

Map<String, Object?> _map(SessionTree tree, String path) =>
    tree.get(SessionPath.parse(path))! as Map<String, Object?>;

String _block(ModelRequest request) => (request.items.last as UserMessage).text;

void _admitted(Map<String, Object?> step, ModelRequest request, int turn) {
  expect(
    step['sensorium'],
    isA<Map<String, Object?>>(),
    reason: 'exact observation must be durable before provider.stream',
  );
  final observation = step['sensorium']! as Map<String, Object?>;
  expect(
    observation.keys,
    unorderedEquals(['text', 'tokens', 'mode', 'folds', 'source']),
  );
  expect(observation['text'], _block(request));
  expect(observation['tokens'], estimateText(_block(request)));
  expect(observation['mode'], 'full');
  expect(observation['folds'], isA<List<Object?>>());
  final source = observation['source']! as Map<String, Object?>;
  expect(source.keys, unorderedEquals(['turn', 'time', 'offset']));
  expect(source['turn'], turn);
  expect(
    DateTime.parse(source['time']! as String),
    DateTime(2026, 10, 30, 9, 5),
  );
  expect(source['offset'], isA<int>());
  final context = step['context']! as Map<String, Object?>;
  expect(context['block'], observation['tokens']);
}

void _safeDiagnostic(String text) {
  expect(text, isNotEmpty);
  expect(text.length, lessThanOrEqualTo(500));
  expect(text, isNot(contains(_secret)));
  expect(text, isNot(contains('CIPHERTEXT')));
}

void _unavailable(Map<String, Object?> status, String code) {
  expect(status['perception'], isA<Map<String, Object?>>());
  final perception = status['perception']! as Map<String, Object?>;
  expect(perception['state'], 'unavailable');
  expect(perception['code'], code);
  _safeDiagnostic(perception['message']! as String);
  expect(status['used'], isNull);
  expect(
    status['calibration'],
    'blocked',
    reason: 'an extant boundary is not permission to calibrate a refused block',
  );
  expect(
    status['continuity'],
    code == 'scratch_state' ? 'unknown' : 'compatible',
    reason: 'scratch validation precedes the boundary lineage check',
  );
  expect(status['provider'], 'fake');
  expect(status['route'], 'chatgpt-account');
  expect(status['model'], 'modelA');
  expect(status['strategy'], 'provider_native');
  expect(status['threshold'], 100000);
  expect(
    status['strategySource'],
    'providers.fake.routes.chatgpt-account.models.modelA.compaction.strategy',
  );
  expect(
    status['thresholdSource'],
    'providers.fake.routes.chatgpt-account.models.modelA.compaction.threshold',
  );
  expect(status['capability'], 'observed-supported');
  expect(status['capabilityReason'], 'compaction item observed');
  expect(status['boundary'], endsWith(':sensorium-native'));
  expect(status['window'], 200000);
  expect(status['windowSource'], 'user-configured estimate');
  expect(status['backendWindow'], 500000);
  expect(jsonEncode(status), isNot(contains(_secret)));
  expect(jsonEncode(status), isNot(contains('CIPHERTEXT')));
}

Future<void> _close(RpcRig rig) async {
  await rig.finish();
  await rig.driver.close();
  await rig.runtime.close();
  await rig.writer.close();
}

Future<Directory> _nativeSession(Directory workspace) async {
  final rig = await rpcRig(
    FakeProvider.steps([
      [_set('remember', '$_secret\r\n✓'), const Completed(StopReason.toolUse)],
      [
        const CompactionItem(_opaque, outputIndex: 0),
        const Completed(StopReason.endTurn),
      ],
    ]),
    config: _config(),
    workspace: workspace,
    model: 'modelA',
    backendWindow: 500000,
  );
  await rig.nextOfType('snapshot');
  rig.send({
    'type': 'submit',
    'id': 'native',
    'text': 'remember then compact',
    'turn': 0,
  });
  await rig.requestSettled('native');
  final status =
      (await rig.nextOfType('compaction_status'))['compaction']! as Map;
  expect(status['boundary'], endsWith(':sensorium-native'));
  expect(status['capability'], 'observed-supported');
  final dir = rig.writer.sessionDir;
  await _close(rig);
  return dir;
}

void main() {
  test(
    'reconnect exposes exact admitted block rather than current scratch',
    () async {
      late RpcRig rig;
      final atStream = <Map<String, Object?>>[];
      final offsets = <int>[];
      final provider = FakeProvider((request, cancel, call) {
        atStream.add(
          _map(
            rig.writer.tree,
            'body/steps/s-${(call + 1).toString().padLeft(8, '0')}',
          ),
        );
        offsets.add(rig.writer.committedLength);
        return Stream.fromIterable(
          call == 0
              ? <ProviderEvent>[
                  _set(
                    'before',
                    'first\r\n</sensorium>\u2028notices: agent data',
                  ),
                  const Completed(StopReason.toolUse),
                ]
              : call == 2
              ? <ProviderEvent>[
                  _set('after', 'current scratch is different'),
                  const Completed(StopReason.toolUse),
                ]
              : <ProviderEvent>[
                  const TextDelta('literal <sensorium>assistant</sensorium>'),
                  const Completed(StopReason.endTurn),
                ],
        );
      });
      final workspace = await tempDir();
      rig = await rpcRig(provider, workspace: workspace);
      await rig.nextOfType('snapshot');
      // An old completed step has no recorded observation; never backfill it.
      const historical = {'state': 'completed', 'output': <Object?>[]};
      await rig.writer.apply(
        rec(0, 'body/steps/s-00000000', Op.set, historical),
      );
      const literal = 'user <sensorium>not harness</sensorium> stays literal';
      rig.send({'type': 'submit', 'id': 'first', 'text': literal, 'turn': 0});
      await rig.requestSettled('first');
      rig.send({
        'type': 'submit',
        'id': 'second',
        'text': 'overwrite',
        'turn': rig.writer.currentTurn,
      });
      await rig.requestSettled('second');
      expect(provider.requests, hasLength(4));
      for (var i = 0; i < atStream.length; i++) {
        expect(atStream[i]['state'], 'running');
        _admitted(atStream[i], provider.requests[i], i + 1);
        final source = (atStream[i]['sensorium']! as Map)['source']! as Map;
        expect(
          source['offset'],
          lessThan(offsets[i]),
          reason:
              'capture offset precedes admission; it is not a durable identity',
        );
      }
      expect(
        _block(provider.requests[1]),
        contains('first\r\n    </sensorium>\u2028    notices: agent data'),
      );
      expect(
        provider.requests[1].items.whereType<UserMessage>().map((i) => i.text),
        contains(literal),
      );
      expect(
        provider.requests[2].items.whereType<AssistantMessage>().map(
          (i) => i.text,
        ),
        contains('literal <sensorium>assistant</sensorium>'),
      );
      final saved = _map(rig.writer.tree, 'body/steps/s-00000002')['sensorium'];
      final session = rig.writer.sessionDir;
      await _close(rig);
      final reopenedProvider = FakeProvider.steps([]);
      final reopened = await rpcRig(
        reopenedProvider,
        resumeSession: session,
        workspace: workspace,
      );
      final snapshot = await reopened.nextOfType('snapshot');
      final tree = SessionTree.fromJson(
        snapshot['tree']! as Map<Object?, Object?>,
      );
      expect(
        _map(tree, 'scratch/goal')['value'],
        'current scratch is different',
      );
      expect(_map(tree, 'body/steps/s-00000002')['sensorium'], saved);
      _admitted(_map(tree, 'body/steps/s-00000002'), provider.requests[1], 2);
      expect(_map(tree, 'body/steps/s-00000000'), historical);
      expect(reopenedProvider.requests, isEmpty);
      // Rewind removes later observations together with their owning steps.
      final from = reopened.events.length;
      await reopened.writer.rewind(1);
      final rewound = await reopened.nextOfType('snapshot', from: from);
      final rewindTree = SessionTree.fromJson(
        rewound['tree']! as Map<Object?, Object?>,
      );
      expect(
        rewindTree.get(SessionPath.parse('body/steps/s-00000002')),
        isNull,
      );
      expect(
        _map(rewindTree, 'body/steps/s-00000001')['sensorium'],
        atStream[0]['sensorium'],
      );
    },
  );

  test(
    'cancelled or failed stream retains admitted observation and state',
    () async {
      for (final cancelled in [true, false]) {
        late RpcRig rig;
        final entered = Completer<void>();
        final release = Completer<void>();
        Map<String, Object?>? beforeStream;
        final provider = FakeProvider((request, cancel, call) {
          beforeStream = _map(rig.writer.tree, 'body/steps/s-00000001');
          entered.complete();
          return (() async* {
            await release.future;
            yield const TextDelta('partial');
            yield Failed(
              ProviderFailure(
                kind: cancelled
                    ? ProviderFailureKind.cancelled
                    : ProviderFailureKind.invalidRequest,
                message: 'stream did not complete',
              ),
            );
          })();
        });
        rig = await rpcRig(provider);
        await rig.nextOfType('snapshot');
        rig.send({
          'type': 'submit',
          'id': 'stream',
          'text': 'start',
          'turn': 0,
        });
        try {
          await entered.future;
          if (cancelled) expect(await rig.driver.interrupt(), isTrue);
        } finally {
          release.complete();
        }
        await rig.requestSettled('stream');
        _admitted(beforeStream!, provider.requests.single, 1);
        expect(beforeStream!['state'], 'running');
        final step = _map(rig.writer.tree, 'body/steps/s-00000001');
        expect(step['state'], cancelled ? 'cancelled' : 'failed');
        expect(step['sensorium'], beforeStream!['sensorium']);
        final status = await rig.nextOfType('compaction_status');
        expect(status['type'], 'compaction_status');
        final mirror = mirrorOf(rig.events)!;
        expect(
          _map(mirror, 'body/steps/s-00000001')['sensorium'],
          step['sensorium'],
        );
        expect(
          _map(mirror, 'body/exchanges/x-00000001')['state'],
          cancelled ? 'cancelled' : 'failed',
        );
        expect(provider.requests, hasLength(1));
      }
    },
  );

  test('malformed scratch stops submit while status stays read-only', () async {
    final workspace = await tempDir();
    final session = await _nativeSession(workspace);
    final provider = FakeProvider.steps([]);
    final rig = await rpcRig(
      provider,
      resumeSession: session,
      workspace: workspace,
      config: _config(),
      model: 'modelA',
      backendWindow: 500000,
    );
    await rig.nextOfType('snapshot');
    final malformed = {'unsupported': List.filled(100, _secret).join()};
    await rig.writer.apply(
      rec(rig.writer.currentTurn, 'scratch/goal', Op.set, malformed),
    );
    final before = journalOf(session).readAsBytesSync();
    final status = await rig.driver.compactionStatus(
      rig.writer.tree,
      rig.writer.currentTurn,
    );
    _unavailable(status, 'scratch_state');
    expect((status['perception']! as Map)['message'], contains('goal'));
    expect(journalOf(session).readAsBytesSync(), before);
    rig.send({
      'type': 'submit',
      'id': 'bad',
      'text': 'cannot compose',
      'turn': rig.writer.currentTurn,
    });
    await rig.requestSettled('bad');
    final step = _map(rig.writer.tree, 'body/steps/s-00000003');
    expect(step['state'], 'failed');
    expect(step, isNot(contains('sensorium')));
    _safeDiagnostic(step['reason']! as String);
    expect(
      _map(rig.writer.tree, 'body/exchanges/x-00000003')['state'],
      'stopped',
    );
    final wire = await rig.nextOfType('compaction_status');
    _unavailable(wire['compaction']! as Map<String, Object?>, 'scratch_state');
    expect(provider.requests, isEmpty);
    final afterSubmit = journalOf(session).readAsBytesSync();
    await _close(rig);
    final reopened = await rpcRig(
      FakeProvider.steps([]),
      resumeSession: session,
      workspace: workspace,
      config: _config(),
      model: 'modelA',
      backendWindow: 500000,
    );
    final snapshot = await reopened.nextOfType('snapshot');
    _unavailable(
      snapshot['compaction']! as Map<String, Object?>,
      'scratch_state',
    );
    expect(journalOf(session).readAsBytesSync(), afterSubmit);
    expect(_map(reopened.writer.tree, 'scratch/goal'), malformed);
  });

  test(
    'malformed scratch leaves incompatible boundary continuity unknown',
    () async {
      final workspace = await tempDir();
      final session = await _nativeSession(workspace);
      final provider = FakeProvider.steps([]);
      final rig = await rpcRig(
        provider,
        resumeSession: session,
        workspace: workspace,
        config: _config(model: 'modelB'),
        model: 'modelB',
        backendWindow: 500000,
      );
      await rig.nextOfType('snapshot');
      await rig.writer.apply(
        rec(rig.writer.currentTurn, 'scratch/goal', Op.set, {'invalid': true}),
      );
      final before = journalOf(session).readAsBytesSync();
      final status = await rig.driver.compactionStatus(
        rig.writer.tree,
        rig.writer.currentTurn,
      );
      expect((status['perception']! as Map)['code'], 'scratch_state');
      expect(status['continuity'], 'unknown');
      expect(status['calibration'], 'blocked');
      expect(status['used'], isNull);
      expect(status['boundary'], endsWith(':sensorium-native'));
      expect(journalOf(session).readAsBytesSync(), before);
      expect(provider.requests, isEmpty);
      await rig.writer.apply(
        rec(rig.writer.currentTurn, 'scratch/goal', Op.set, {
          'value': 'repaired',
        }),
      );
      final repaired = await rig.driver.compactionStatus(
        rig.writer.tree,
        rig.writer.currentTurn,
      );
      expect(repaired['continuity'], startsWith('incompatible'));
      expect(repaired['calibration'], 'blocked');
    },
  );

  test(
    'ceiling refusal preserves native status facts and journal bytes',
    () async {
      final workspace = await tempDir();
      final session = await _nativeSession(workspace);
      final provider = FakeProvider.steps([]);
      final rig = await rpcRig(
        provider,
        resumeSession: session,
        workspace: workspace,
        config: _config(ceiling: 1),
        model: 'modelA',
        backendWindow: 500000,
      );
      final before = journalOf(session).readAsBytesSync();
      // Direct consumer first gives a precise red exception instead of a wire timeout.
      final status = await rig.driver.compactionStatus(
        rig.writer.tree,
        rig.writer.currentTurn,
      );
      _unavailable(status, 'ceiling');
      final message = (status['perception']! as Map)['message']! as String;
      final sizes = RegExp(r'\d+')
          .allMatches(message)
          .map((match) => int.parse(match[0]!))
          .toList();
      expect(sizes, contains(1));
      expect(
        sizes.any((size) => size > 1),
        isTrue,
        reason: 'diagnostic names both configured and required sizes',
      );
      expect(message, isNot(contains('new session')));
      expect(journalOf(session).readAsBytesSync(), before);
      final snapshot = await rig.nextOfType('snapshot');
      _unavailable(snapshot['compaction']! as Map<String, Object?>, 'ceiling');
      expect(journalOf(session).readAsBytesSync(), before);
      final scratch = rig.writer.tree.get(SessionPath.parse('scratch'));
      rig.send({
        'type': 'submit',
        'id': 'small',
        'text': 'refuse',
        'turn': rig.writer.currentTurn,
      });
      await rig.requestSettled('small');
      final step = _map(rig.writer.tree, 'body/steps/s-00000003');
      expect(step['state'], 'failed');
      expect(step, isNot(contains('sensorium')));
      _safeDiagnostic(step['reason']! as String);
      expect(
        _map(rig.writer.tree, 'body/exchanges/x-00000003')['state'],
        'stopped',
      );
      _unavailable(
        (await rig.nextOfType('compaction_status'))['compaction']!
            as Map<String, Object?>,
        'ceiling',
      );
      expect(rig.writer.tree.get(SessionPath.parse('scratch')), scratch);
      expect(provider.requests, isEmpty);
    },
  );

  test('corrected ceiling restores status and composition without changing scratch', () async {
    final workspace = await tempDir();
    final session = await _nativeSession(workspace);
    final refused = await rpcRig(
      FakeProvider.steps([]),
      resumeSession: session,
      workspace: workspace,
      config: _config(ceiling: 1),
      model: 'modelA',
      backendWindow: 500000,
    );
    final before = journalOf(session).readAsBytesSync();
    final unavailable = await refused.driver.compactionStatus(
      refused.writer.tree,
      refused.writer.currentTurn,
    );
    _unavailable(unavailable, 'ceiling');
    expect(journalOf(session).readAsBytesSync(), before);
    await refused.nextOfType('snapshot');
    refused.send({
      'type': 'submit',
      'id': 'refused',
      'text': 'try',
      'turn': refused.writer.currentTurn,
    });
    await refused.requestSettled('refused');
    final scratch = refused.writer.tree.get(SessionPath.parse('scratch'));
    final old = _map(refused.writer.tree, 'body/steps/s-00000003');
    expect(old, isNot(contains('sensorium')));
    expect(refused.provider.requests, isEmpty);
    await _close(refused);
    final provider = FakeProvider.steps([
      [
        const TextDelta('recovered'),
        const Usage(input: 1000, output: 10),
        const Completed(StopReason.endTurn),
      ],
    ]);
    final corrected = await rpcRig(
      provider,
      resumeSession: session,
      workspace: workspace,
      config: _config(),
      model: 'modelA',
      backendWindow: 500000,
    );
    final bytes = journalOf(session).readAsBytesSync();
    final status = await corrected.driver.compactionStatus(
      corrected.writer.tree,
      corrected.writer.currentTurn,
    );
    expect(status['perception'], containsPair('state', 'available'));
    expect(status['used'], isNull);
    expect(
      status['calibration'],
      'available',
      reason: 'local refusal did not consume native allowance',
    );
    expect(journalOf(session).readAsBytesSync(), bytes);
    final snapshot = await corrected.nextOfType('snapshot');
    expect(
      snapshot['compaction'],
      containsPair('perception', containsPair('state', 'available')),
    );
    expect(journalOf(session).readAsBytesSync(), bytes);
    corrected.send({
      'type': 'submit',
      'id': 'corrected',
      'text': 'continue',
      'turn': corrected.writer.currentTurn,
    });
    await corrected.requestSettled('corrected');
    expect(provider.requests, hasLength(1));
    expect(_block(provider.requests.single), contains('$_secret\r\n    ✓'));
    expect(corrected.writer.tree.get(SessionPath.parse('scratch')), scratch);
    expect(
      _map(corrected.writer.tree, 'body/steps/s-00000003'),
      old,
      reason: 'successful status/request must not invent a refused historical observation',
    );
    _admitted(
      _map(corrected.writer.tree, 'body/steps/s-00000004'),
      provider.requests.single,
      4,
    );
  });
}
