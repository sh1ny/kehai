import 'dart:async';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_provider.dart';
import '../support/session_support.dart';

final class _Rig {
  _Rig(this.writer, this.provider, this.driver, this.waits);

  final SessionWriter writer;
  final FakeProvider provider;
  final ExchangeDriver driver;

  /// The delays the driver asked the fake clock to wait, in order.
  final List<Duration> waits;

  Map<String, Object?> map(String path) =>
      writer.tree.get(SessionPath.parse(path))! as Map<String, Object?>;

  Map<String, Object?> step(int turn) =>
      map('body/steps/s-${turn.toString().padLeft(8, '0')}');

  Future<SubmitAdmitted> submit(String text) async =>
      await driver.submit(id: 'r1', text: text, turn: writer.currentTurn)
          as SubmitAdmitted;

  Future<ExchangeResult> run(String text) async => (await submit(text)).done;
}

/// A rig whose retry waits return at once, or never with [hang].
Future<_Rig> _rig(FakeProvider provider, {bool hang = false}) async {
  final root = await tempDir();
  final ws = Directory(p.join(root.path, 'ws'))..createSync();
  final writer = await createWriter(Directory(p.join(root.path, 's')));
  final runtime = await ToolRuntime.attach(
    writer,
    ResultStore(writer.sessionDir),
    workspace: ws,
    gate: const AllowAllStage(),
  );
  addTearDown(runtime.close);
  final waits = <Duration>[];
  final driver = ExchangeDriver(
    writer: writer,
    runtime: runtime,
    provider: provider,
    model: 'gpt-5.5',
    clock: () => DateTime(2026, 10, 30, 9, 5),
    seams: DriverSeams(
      sleep: (delay) {
        waits.add(delay);
        return hang ? Completer<void>().future : Future<void>.value();
      },
    ),
  );
  addTearDown(driver.close);
  return _Rig(writer, provider, driver, waits);
}

Failed _fail(
  ProviderFailureKind kind, {
  bool sent = false,
  int? status,
  Duration? retryAfter,
}) => Failed(
  ProviderFailure(
    kind: kind,
    message: 'it failed',
    status: status,
    sent: sent,
    retryAfter: retryAfter,
  ),
);

const _endTurn = Completed(StopReason.endTurn);

void main() {
  group('Bounded retry', () {
    test('rate_limited with Retry-After 3 retries once and records 2 '
        'attempts', () async {
      final provider = FakeProvider.steps([
        [
          _fail(
            ProviderFailureKind.rateLimited,
            status: 429,
            retryAfter: const Duration(seconds: 3),
          ),
        ],
        [const TextDelta('ok'), _endTurn],
      ]);
      final rig = await _rig(provider);

      final result = await rig.run('hello');

      expect(result.state, 'done');
      expect(rig.waits, [const Duration(seconds: 3)]);
      expect(provider.requests, hasLength(2));
      expect(rig.step(1), containsPair('state', 'completed'));
      expect(rig.step(1), containsPair('attempts', 2));
    });

    test('five unsent network failures end failed after 5 attempts', () async {
      final provider = FakeProvider.steps([
        for (var i = 0; i < 5; i++) [_fail(ProviderFailureKind.network)],
      ]);
      final rig = await _rig(provider);

      final result = await rig.run('hello');

      const reason = 'model request failed after 5 attempts: it failed';
      expect(result.state, 'failed');
      expect(result.reason, reason);
      expect(rig.waits, [
        const Duration(seconds: 1),
        const Duration(seconds: 2),
        const Duration(seconds: 4),
        const Duration(seconds: 8),
      ]);
      expect(provider.requests, hasLength(5));
      expect(rig.step(1), containsPair('state', 'failed'));
      expect(rig.step(1), containsPair('attempts', 5));
      expect(rig.step(1), containsPair('reason', reason));
      expect(
        rig.map('body/exchanges/x-00000001'),
        containsPair('reason', reason),
      );
    });

    test('server 500 and sent network failures are not repeated', () async {
      for (final failure in [
        _fail(ProviderFailureKind.server, status: 500, sent: true),
        _fail(ProviderFailureKind.network, sent: true),
      ]) {
        final provider = FakeProvider.steps([
          [failure],
        ]);
        final rig = await _rig(provider);

        final result = await rig.run('hello');

        expect(result.state, 'failed');
        expect(result.reason, 'model request failed: it failed');
        expect(provider.requests, hasLength(1));
        expect(rig.waits, isEmpty);
        expect(rig.step(1), containsPair('attempts', 1));
      }
    });

    test('Retry-After 600 is not retried and names the wait', () async {
      final provider = FakeProvider.steps([
        [
          _fail(
            ProviderFailureKind.rateLimited,
            status: 429,
            retryAfter: const Duration(seconds: 600),
          ),
        ],
      ]);
      final rig = await _rig(provider);

      final result = await rig.run('hello');

      expect(result.state, 'failed');
      expect(result.reason, contains('the server asked to wait 600 s'));
      expect(provider.requests, hasLength(1));
      expect(rig.waits, isEmpty);
    });

    test('interrupt during a retry wait ends the step cancelled with the '
        'attempts sent', () async {
      final provider = FakeProvider.steps([
        [_fail(ProviderFailureKind.network)],
      ]);
      final rig = await _rig(provider, hang: true);
      final done = (await rig.submit('hello')).done;
      while (rig.waits.isEmpty) {
        await Future<void>.delayed(Duration.zero);
      }

      expect(await rig.driver.interrupt(), isTrue);
      final result = await done.timeout(const Duration(seconds: 10));

      expect(result.state, 'cancelled');
      expect(provider.requests, hasLength(1));
      expect(rig.step(1), containsPair('state', 'cancelled'));
      expect(rig.step(1), containsPair('attempts', 1));
    });
  });
}
