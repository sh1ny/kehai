import 'dart:async';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/answerer_support.dart';
import '../support/fake_provider.dart';
import '../support/session_support.dart';

/// A tool that signals [started] and then waits for its call to be cancelled.
final class _Blocking implements Tool {
  _Blocking(this.started);

  final Completer<void> started;

  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    started.complete();
    await context.cancel.whenCancelled;
    return const ToolOutcome(summary: 'stopped', status: ResultStatus.error);
  }
}

ToolCall _call(String id, String name, String args) =>
    ToolCall(callId: id, name: name, argumentsJson: args);

const _toolUse = Completed(StopReason.toolUse);

final class _Rig {
  _Rig(this.writer, this.runtime, this.provider, this.driver, this.ws);

  final SessionWriter writer;
  final ToolRuntime runtime;
  final FakeProvider provider;
  final ExchangeDriver driver;
  final Directory ws;

  Map<String, Object?> map(String path) =>
      writer.tree.get(SessionPath.parse(path))! as Map<String, Object?>;

  Map<String, Object?> callNode(String callId) =>
      map('body/calls/${callKey(callId)}');

  /// Submits [text] and returns the running exchange.
  Future<ExchangeResult> start(String text) async {
    final outcome = await driver.submit(
      id: 'r1',
      text: text,
      turn: writer.currentTurn,
    );
    return (outcome as SubmitAdmitted).done;
  }
}

Future<_Rig> _rig(
  FakeProvider provider, {
  Map<String, Tool> tools = const {},
  Answerer? answerer,
  DriverSeams seams = const DriverSeams(),
}) async {
  final root = await tempDir();
  final ws = Directory(p.join(root.path, 'ws'))..createSync();
  final writer = await createWriter(Directory(p.join(root.path, 's')));
  final runtime = await ToolRuntime.attach(
    writer,
    ResultStore(writer.sessionDir),
    workspace: ws,
    tools: tools,
    gate: const AllowAllStage(),
    answerer: answerer,
  );
  addTearDown(runtime.close);
  final driver = ExchangeDriver(
    writer: writer,
    runtime: runtime,
    provider: provider,
    model: 'gpt-5.5',
    clock: () => DateTime(2026, 10, 30, 9, 5),
    seams: seams,
  );
  addTearDown(driver.close);
  return _Rig(writer, runtime, provider, driver, ws);
}

void main() {
  group('Interrupt', () {
    test(
      'interrupt mid-stream records cancelled step with partial text',
      () async {
        // The stream ends without a Failed event: the token alone decides.
        final provider = FakeProvider((request, cancel, call) async* {
          yield const TextDelta('par');
          yield const TextDelta('tial');
          await cancel!.whenCancelled;
        });
        final rig = await _rig(provider);
        final streamed = Completer<void>();
        rig.driver.deltas.listen((d) {
          if (d.delta == 'tial' && !streamed.isCompleted) streamed.complete();
        });
        final done = rig.start('talk');
        await streamed.future;

        expect(await rig.driver.interrupt(), isTrue);
        final result = await done.timeout(const Duration(seconds: 10));

        expect(result.state, 'cancelled');
        expect(result.reason, 'user');
        expect(
          rig.map('body/steps/s-00000001'),
          containsPair('state', 'cancelled'),
        );
        expect(
          rig.map('body/steps/s-00000001'),
          containsPair('reason', 'user'),
        );
        expect(
          rig.map('body/steps/s-00000001'),
          containsPair('partial', 'partial'),
        );
        expect(
          rig.map('body/exchanges/x-00000001'),
          containsPair('state', 'cancelled'),
        );
        expect(
          rig.map('body/exchanges/x-00000001'),
          containsPair('reason', 'user'),
        );
        expect(rig.writer.tree.get(SessionPath.parse('body/calls')), isNull);
        expect(provider.requests, hasLength(1));
      },
    );

    test(
      'interrupt cancels running bash and withdraws the open prompt',
      () async {
        final started = Completer<void>();
        final answerer = RecordingAnswerer();
        final provider = FakeProvider.steps([
          [
            _call('b1', 'bash', '{"command":"sleep 30"}'),
            _call('q1', 'ask', '{"question":"pick","choices":["a","b"]}'),
            _toolUse,
          ],
          [const TextDelta('never')],
        ]);
        final rig = await _rig(
          provider,
          tools: {'bash': _Blocking(started)},
          answerer: answerer,
        );
        final done = rig.start('run and ask');
        await started.future;
        final prompt = await answerer.item(0);

        expect(await rig.driver.interrupt(), isTrue);
        final result = await done.timeout(const Duration(seconds: 10));

        expect(result.state, 'cancelled');
        expect(rig.callNode('b1'), containsPair('status', 'cancelled'));
        expect(rig.callNode('b1'), containsPair('reason', 'user'));
        expect(rig.callNode('q1'), containsPair('status', 'cancelled'));
        expect(rig.callNode('q1'), containsPair('reason', 'user'));
        expect(answerer.withdrawn, [prompt.key]);
        expect(
          provider.requests,
          hasLength(1),
          reason: 'no further step starts',
        );
        expect(rig.map('body/steps'), hasLength(1));
        expect(
          rig.map('body/exchanges/x-00000001'),
          containsPair('state', 'cancelled'),
        );
      },
    );

    test('interrupt during the step commit cancels both writes before any '
        'effect', () async {
      final reached = Completer<void>();
      final release = Completer<void>();
      final provider = FakeProvider.steps([
        [
          _call('w1', 'write', '{"path":"a.txt","content":"A"}'),
          _call('w2', 'write', '{"path":"b.txt","content":"B"}'),
          _toolUse,
        ],
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
      final done = rig.start('write two files');
      await reached.future;

      expect(await rig.driver.interrupt(), isTrue);
      release.complete();
      final result = await done.timeout(const Duration(seconds: 10));

      expect(result.state, 'cancelled');
      expect(result.reason, 'user');
      for (final id in ['w1', 'w2']) {
        expect(rig.callNode(id), containsPair('status', 'cancelled'));
        expect(rig.callNode(id), containsPair('reason', 'user'));
        expect(rig.callNode(id)['result'], isA<Map<String, Object?>>());
      }
      expect(File(p.join(rig.ws.path, 'a.txt')).existsSync(), isFalse);
      expect(File(p.join(rig.ws.path, 'b.txt')).existsSync(), isFalse);
      expect(
        rig.map('body/steps/s-00000001'),
        containsPair('state', 'completed'),
      );
      expect(provider.requests, hasLength(1));
    });

    test('interrupt during a text-only step commit ends cancelled', () async {
      final reached = Completer<void>();
      final release = Completer<void>();
      final provider = FakeProvider.steps([
        [const TextDelta('All done.'), const Completed(StopReason.endTurn)],
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
      final done = rig.start('say something');
      await reached.future;

      expect(await rig.driver.interrupt(), isTrue);
      release.complete();
      final result = await done.timeout(const Duration(seconds: 10));

      expect(result.state, 'cancelled');
      expect(result.reason, 'user');
      // The step had arrived whole, so it stays committed.
      expect(
        rig.map('body/steps/s-00000001'),
        containsPair('state', 'completed'),
      );
    });

    test(
      'idle interrupt records nothing and replies no exchange running',
      () async {
        final rig = await _rig(FakeProvider.steps(const []));
        final before = rig.writer.committedLength;

        expect(await rig.driver.interrupt(), isFalse);

        expect(rig.writer.committedLength, before);
        expect(rig.driver.busy, isFalse);
      },
    );
  });
}
