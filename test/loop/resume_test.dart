import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_provider.dart';
import '../support/killed_exchange_support.dart';
import '../support/loop_support.dart';
import '../support/session_support.dart';

const Timeout _engineTimeout = Timeout(Duration(minutes: 3));

Future<ExchangeDriver> _driverFor(
  SessionWriter writer,
  FakeProvider provider,
) async {
  final ws = Directory(p.join(writer.sessionDir.parent.path, 'ws'))
    ..createSync(recursive: true);
  final runtime = await ToolRuntime.attach(
    writer,
    ResultStore(writer.sessionDir),
    workspace: ws,
    gate: const AllowAllStage(),
  );
  addTearDown(runtime.close);
  final driver = ExchangeDriver(
    writer: writer,
    runtime: runtime,
    provider: provider,
    model: 'gpt-5.5',
  );
  addTearDown(driver.close);
  return driver;
}

Map<String, Object?> _node(SessionWriter writer, String path) =>
    writer.tree.get(SessionPath.parse(path))! as Map<String, Object?>;

void main() {
  test(
    'killed engine mid-step is finalized cancelled interrupted on reopen',
    () async {
      final root = await tempDir();
      final workspace = Directory(p.join(root.path, 'ws'))..createSync();
      final engine = await startKilledExchange(
        sessions: Directory(p.join(root.path, 'sessions')),
        workspace: workspace,
      );
      await engine.kill();
      final writer = await SessionWriter.open(engine.dir);
      addTearDown(writer.close);
      expect(
        _node(writer, 'body/steps/s-00000001'),
        containsPair('state', 'running'),
      );
      expect(
        _node(writer, 'body/exchanges/x-00000001'),
        containsPair('state', 'running'),
      );
      final provider = FakeProvider.steps(const []);
      final driver = await _driverFor(writer, provider);

      final finalized = await driver.finalizeUnfinished();

      expect(finalized, 1);
      for (final path in [
        'body/steps/s-00000001',
        'body/exchanges/x-00000001',
      ]) {
        expect(_node(writer, path), containsPair('state', 'cancelled'));
        expect(_node(writer, path), containsPair('reason', 'interrupted'));
      }
      expect(
        _node(writer, 'meta/requests/r9'),
        containsPair('state', 'interrupted'),
      );
      expect(provider.requests, isEmpty, reason: 'no request is repeated');
      expect(driver.busy, isFalse);
    },
    timeout: _engineTimeout,
  );

  test('reopening a clean session records nothing', () async {
    final root = await tempDir();
    final first = await SessionWriter.create(Directory(p.join(root.path, 's')));
    await seedExchange(first, 1, 'earlier');
    await seedStep(first, 1, exchange: 1);
    await seedExchange(first, 2, 'stopped', state: 'stopped');
    await first.close();
    final writer = await SessionWriter.open(first.sessionDir);
    addTearDown(writer.close);
    final driver = await _driverFor(writer, FakeProvider.steps(const []));
    final before = writer.committedLength;

    expect(await driver.finalizeUnfinished(), 0);

    expect(writer.committedLength, before);
  });
}
