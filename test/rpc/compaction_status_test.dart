import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/client_support.dart';
import '../support/fake_provider.dart';
import '../support/rpc_support.dart';
import '../support/session_support.dart';

UserConfig _config({bool off = false, int threshold = 100000}) => UserConfig(
  providers: {
    'fake': ProviderConfig(
      routes: {
        'chatgpt-account': RouteConfig(
          models: {
            'modelA': RouteModelConfig(
              compaction: CompactionSettings(
                strategy: off
                    ? CompactionStrategy.off
                    : CompactionStrategy.providerNative,
                threshold: threshold,
              ),
              contextWindow: 200000,
            ),
          },
        ),
      },
    ),
  },
);

const _opaque = {
  'type': 'compaction',
  'id': 'cmp-status',
  'encrypted_content': 'CIPHERTEXT-NEVER-IN-STATUS',
};

void main() {
  test('context-compaction: Reconnect after observed compaction', () async {
    final workspace = await tempDir();
    final first = await rpcRig(
      FakeProvider.steps([
        [
          const CompactionItem(_opaque, outputIndex: 0),
          const Usage(input: 120000, output: 6000),
          const Completed(StopReason.endTurn),
        ],
      ]),
      workspace: workspace,
      config: _config(),
      model: 'modelA',
    );
    await first.nextOfType('snapshot');
    first.send({'type': 'submit', 'id': 'r1', 'text': 'compact', 'turn': 0});
    await first.requestSettled('r1');
    final session = first.writer.sessionDir;
    await first.finish();
    // Finish owns the server, not the writer/runtime; close before reopen.
    await first.driver.close();
    await first.runtime.close();
    await first.writer.close();

    final resumed = await rpcRig(
      FakeProvider.steps([]),
      resumeSession: session,
      workspace: workspace,
      config: _config(),
      model: 'modelA',
      backendWindow: 500000,
    );
    final snapshot = await resumed.nextOfType('snapshot');
    expect(
      snapshot['compaction'],
      isA<Map<String, Object?>>(),
      reason:
          'real RPC materialization must reconstruct scalar compaction status',
    );
    final status = snapshot['compaction']! as Map<String, Object?>;
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
    expect(status['boundary'], endsWith(':cmp-status'));
    expect(status['window'], 200000);
    expect(status['windowSource'], 'user-configured estimate');
    expect(status['backendWindow'], 500000);
    expect(status['used'], isNull);
    expect(status['budgetQuality'], 'unknown compacted usage');
    expect(status['retained'], isA<int>());
    expect(status['calibration'], 'available');
    expect(
      status.values.every(
        (value) =>
            value == null || value is String || value is num || value is bool,
      ),
      isTrue,
    );
    expect(jsonEncode(status), isNot(contains('CIPHERTEXT')));
    // The authoritative tree keeps opaque data, just like encrypted reasoning.
    expect(
      jsonEncode(snapshot['tree']),
      contains('CIPHERTEXT-NEVER-IN-STATUS'),
    );
    await _render(snapshot, [
      'observed-supported',
      'cmp-status',
      'unknown compacted usage',
      'user-configured estimate',
      '500000',
      'calibration: available',
    ]);

    await resumed.finish();
    await resumed.driver.close();
    await resumed.runtime.close();
    await resumed.writer.close();
    // A changed current model/policy must not reuse the historical model's status.
    final changed = await rpcRig(
      FakeProvider.steps([]),
      resumeSession: session,
      workspace: workspace,
      config: _config(threshold: 80000),
      model: 'modelB',
    );
    final changedStatus =
        (await changed.nextOfType('snapshot'))['compaction']! as Map;
    expect(changedStatus['model'], 'modelB');
    expect(changedStatus['capability'], 'disabled');
    expect(changedStatus['continuity'], 'incompatible continuity');
    expect(changedStatus['boundary'], endsWith(':cmp-status'));
  });

  test('context-compaction: Recovery after unsupported route', () async {
    final workspace = await tempDir();
    final failed = await rpcRig(
      FakeProvider.steps([
        [
          Failed(
            ProviderFailure(
              kind: ProviderFailureKind.invalidRequest,
              message: 'RAW SERVER SECRET context_management invalid',
              code: 'unsupported_parameter',
              param: 'context_management',
            ),
          ),
        ],
      ]),
      workspace: workspace,
      config: _config(),
      model: 'modelA',
    );
    await failed.nextOfType('snapshot');
    failed.send({'type': 'submit', 'id': 'bad', 'text': 'try', 'turn': 0});
    await failed.requestSettled('bad');
    final session = failed.writer.sessionDir;
    await failed.finish();
    await failed.driver.close();
    await failed.runtime.close();
    await failed.writer.close();

    final provider = FakeProvider.steps([
      textStep(['continued']),
    ]);
    final recovered = await rpcRig(
      provider,
      resumeSession: session,
      workspace: workspace,
      config: _config(off: true),
      model: 'modelA',
    );
    final snapshot = await recovered.nextOfType('snapshot');
    expect(snapshot['compaction'], isA<Map<String, Object?>>());
    final status = snapshot['compaction']! as Map<String, Object?>;
    expect(status['strategy'], 'off');
    expect(status['capability'], 'disabled');
    expect(status['previousNativeStop'], 'context_management rejected');
    expect(
      status['recoveryNotice'],
      contains('do not assume native compaction succeeded'),
    );
    expect(jsonEncode(status), isNot(contains('RAW SERVER SECRET')));
    await _render(snapshot, [
      'off',
      'disabled',
      'context_management rejected',
      'explicitly continued',
    ]);
    recovered.send({
      'type': 'submit',
      'id': 'recover',
      'text': 'continue',
      'turn': recovered.writer.currentTurn,
    });
    await recovered.requestSettled('recover');
    expect(provider.requests, hasLength(1));
    expect(provider.requests.single.nativeCompaction, isNull);
    final notices = provider.requests.single.items
        .whereType<UserMessage>()
        .map((item) => item.text)
        .where((text) => text.startsWith('Previous native compaction stop:'));
    expect(notices.single, status['recoveryNotice']);
    expect(notices.single, isNot(contains('RAW SERVER SECRET')));
  });

  test(
    'current workspace instructions qualify capability on reconnect',
    () async {
      final workspace = await tempDir();
      Directory(p.join(workspace.path, '.git')).createSync();
      final instructions = File(p.join(workspace.path, 'AGENTS.md'))
        ..writeAsStringSync('original instructions');
      final first = await rpcRig(
        FakeProvider.steps([
          [
            const CompactionItem(_opaque, outputIndex: 0),
            const Completed(StopReason.endTurn),
          ],
        ]),
        workspace: workspace,
        config: _config(),
        model: 'modelA',
      );
      await first.nextOfType('snapshot');
      first.send({'type': 'submit', 'id': 'one', 'text': 'hello', 'turn': 0});
      await first.requestSettled('one');
      final session = first.writer.sessionDir;
      await first.finish();
      await first.driver.close();
      await first.runtime.close();
      await first.writer.close();
      instructions.writeAsStringSync('changed instructions');
      final reopened = await rpcRig(
        FakeProvider.steps([]),
        resumeSession: session,
        workspace: workspace,
        config: _config(),
        model: 'modelA',
      );
      final status = (await reopened.nextOfType('snapshot'))['compaction'];
      expect(status, isA<Map<String, Object?>>());
      expect((status! as Map)['capability'], 'unverified');
      expect((status as Map)['continuity'], 'incompatible continuity');
    },
  );

  test('live completed boundaries, calibration consumption and rewind refresh status', () async {
    final provider = FakeProvider.steps([
      [
        const CompactionItem(_opaque, outputIndex: 0),
        const Completed(StopReason.endTurn),
      ],
      textStep(['calibration without usage']),
    ]);
    final rig = await rpcRig(provider, config: _config(), model: 'modelA');
    final initial = await rig.nextOfType('snapshot');
    expect(
      (initial['compaction']! as Map)['budgetQuality'],
      'estimated full request',
    );
    expect(
      provider.requests,
      isEmpty,
      reason: 'materialization makes no paid probe',
    );
    rig.send({'type': 'submit', 'id': 'first', 'text': 'compact', 'turn': 0});
    await rig.requestSettled('first');
    final observed = await rig.nextOfType('compaction_status');
    expect(
      (observed['compaction']! as Map)['capability'],
      'observed-supported',
    );
    expect(jsonEncode(observed), isNot(contains('CIPHERTEXT')));
    final client = clientRig();
    await client.start();
    await client.emit(observed);
    expect(client.out.text, contains('observed-supported'));
    expect(
      client.out.text,
      endsWith('> '),
      reason: 'live status must leave an idle input prompt',
    );

    final from = rig.events.length;
    rig.send({
      'type': 'submit',
      'id': 'calibrate',
      'text': 'continue',
      'turn': rig.writer.currentTurn,
    });
    await rig.requestSettled('calibrate');
    final consumed = await rig.nextOfType('compaction_status', from: from);
    expect((consumed['compaction']! as Map)['calibration'], 'consumed');
    expect(
      (consumed['compaction']! as Map)['previousNativeStop'],
      'calibration usage unavailable',
    );
    final beforeRewind = rig.events.length;
    await rig.writer.rewind(0);
    final rewound = await rig.nextOfType('snapshot', from: beforeRewind);
    final status = rewound['compaction']! as Map;
    expect(status['boundary'], isNull);
    expect(status['capability'], 'unverified');
    expect(status['budgetQuality'], 'estimated full request');
  });

  test(
    'ChatGPT status separates raw metadata, legacy hint and unknown capacity',
    () async {
      final provider = FakeProvider(
        (request, cancel, call) => const Stream.empty(),
        id: 'openai',
      );
      final rig = await rpcRig(
        provider,
        model: 'gpt-6.1-sol',
        backendWindow: 500000,
        config: const UserConfig(contextWindows: {'gpt-6.1-sol': 500000}),
      );
      final snapshot = await rig.nextOfType('snapshot');
      final status = snapshot['compaction']! as Map;
      expect(status['window'], isNull);
      expect(status['windowSource'], 'unknown');
      expect(status['backendWindow'], 500000);
      expect(status['legacyWindowHint'], 500000);
      expect(
        status['migrationNotice'],
        contains(
          'providers.openai.routes.chatgpt-account.models.gpt-6.1-sol.contextWindow',
        ),
      );
      expect(status['threshold'], 100000);
      expect(status['thresholdSource'], 'built-in');
      expect(status['budgetQuality'], 'estimated full request');
      expect(status['used'], isA<int>());
      expect(provider.requests, isEmpty);
      await _render(snapshot, [
        'capacity: ? (unknown)',
        'backend metadata: 500000',
        'legacy hint: 500000',
        'Migrate it to',
        'estimated full request',
      ]);
    },
  );
}

Future<void> _render(
  Map<String, Object?> snapshot,
  List<String> expected,
) async {
  final client = clientRig();
  await client.start();
  await client.emit({'type': 'resync'});
  await client.emit({...snapshot, 'offset': 11});
  for (final text in expected) {
    expect(
      client.out.text,
      contains(text),
      reason: 'line client must render reconstructed scalar status',
    );
  }
  expect(client.out.text, isNot(contains('CIPHERTEXT')));
  expect(client.out.text, isNot(contains('RAW SERVER SECRET')));
}
