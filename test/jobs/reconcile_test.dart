import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/job_support.dart';
import '../support/session_support.dart';

const Duration _grace = Duration(seconds: 6);

Future<void> _turns(JobHarness h, int to) async {
  for (var turn = h.writer.currentTurn + 1; turn <= to; turn++) {
    await h.writer.apply(rec(turn, 'body/marker', Op.set, turn));
  }
}

/// Starts `sleep 30` and returns the handle and the started process.
Future<(JobHandle, ShellProcess Function())> _sleeper(JobHarness h) async {
  ShellProcess? started;
  final handle = h.supervisor.start(
    h.request(
      'sleep 30',
      launch: h.recordingLauncher('sleep 30', (s) => started = s),
    ),
  );
  await waitFor(
    () => h.node(handle.id)?['state'] == 'running',
    what: 'the job to run',
  );
  return (handle, () => started!);
}

void main() {
  final skip = skipWithoutShell();

  test(
    'rewind before start kills the process and records the orphan',
    () async {
      final h = await JobHarness.create();
      await _turns(h, 3);
      final (handle, process) = await _sleeper(h);

      await h.writer.rewind(2);
      await process().process.exitCode.timeout(
        _grace,
        onTimeout: () => fail('the process outlived the rewind'),
      );
      final result = await handle.result;

      expect(result.stale, isTrue);
      expect(h.node(handle.id), isNull);
      final orphan = h.at('meta/orphans/${handle.id}')! as Map<String, Object?>;
      expect(orphan['cmd'], 'sleep 30');
      expect(orphan['rewoundTo'], 2);
      expect(orphan['cleanup'], isA<String>());
      expect(h.at('meta/handoffs/${handle.launch}'), isNull);
      expect(h.supervisor.liveCount, 0);
    },
    skip: skip,
  );

  test('restored running node without runtime is cancelled rewound', () async {
    final h = await JobHarness.create();
    await _turns(h, 3);
    final go = File(h.marker('go'));
    final handle = h.supervisor.start(
      h.request("while [ ! -e '${go.path}' ]; do sleep 0.05; done"),
    );
    await waitFor(
      () => h.node(handle.id)?['state'] == 'running',
      what: 'the job to run',
    );
    await _turns(h, 5);
    go.writeAsStringSync('');
    expect((await handle.result).state, 'settled');
    expect(h.node(handle.id)!['state'], 'settled');

    await h.writer.rewind(4);
    await h.supervisor.reconciled();

    final node = h.node(handle.id)!;
    expect(node['state'], 'cancelled');
    expect(node['reason'], 'rewound');
    expect(h.states(handle.id), [
      'pending',
      'running',
      'settled',
      'cancelled',
    ], reason: 'no running record and no process after the rewind');
    expect(h.supervisor.liveCount, 0);
    expect(h.at('meta/handoffs/${handle.launch}'), isNull);
  }, skip: skip);

  test('rewind after start leaves the job running to its settle', () async {
    final h = await JobHarness.create();
    await _turns(h, 3);
    final go = File(h.marker('go'));
    final handle = h.supervisor.start(
      h.request("echo done; while [ ! -e '${go.path}' ]; do sleep 0.05; done"),
    );
    await waitFor(
      () => h.node(handle.id)?['state'] == 'running',
      what: 'the job to run',
    );
    await _turns(h, 5);
    final before = h.node(handle.id)!;

    await h.writer.rewind(4);
    await h.supervisor.reconciled();
    expect(h.node(handle.id), before, reason: 'the node is unchanged');
    expect(h.supervisor.liveCount, 1);

    go.writeAsStringSync('');
    final result = await handle.result;
    expect(result.state, 'settled');
    expect(result.stale, isFalse);
    final node = h.node(handle.id)!;
    expect(node['state'], 'settled');
    expect(node['exit'], 0);
    expect(h.stream(node, 'stdout'), 'done\n');
  }, skip: skip);

  test('exit after removal returns stale and appends nothing', () async {
    // No reconciler: the guarded record itself must refuse the exit.
    final h = await JobHarness.create(reconcile: false);
    await _turns(h, 3);
    final go = File(h.marker('go'));
    final handle = h.supervisor.start(
      h.request("echo done; while [ ! -e '${go.path}' ]; do sleep 0.05; done"),
    );
    await waitFor(
      () => h.node(handle.id)?['state'] == 'running',
      what: 'the job to run',
    );
    await h.writer.rewind(2);
    expect(h.node(handle.id), isNull);
    final rewindAt = h.records().length;

    go.writeAsStringSync('');
    final result = await handle.result;

    expect(result.stale, isTrue);
    expect(h.node(handle.id), isNull, reason: 'no node is recreated');
    expect(
      h.records().skip(rewindAt).where((r) => r.path == 'jobs/${handle.id}'),
      isEmpty,
      reason: 'nothing was appended for the job',
    );
  }, skip: skip);

  test(
    'concurrent exit and cancel record exactly one terminal state',
    () async {
      for (final delay in [0, 15, 40, 90, 150, 250]) {
        final h = await JobHarness.create();
        final handle = h.supervisor.start(h.request('sleep 0.2; echo end'));
        await waitFor(
          () => h.node(handle.id)?['state'] == 'running',
          what: 'the job to run',
        );
        // The command ends by itself about 200 ms after it started.
        final cancel = Future<CancelOutcome>.delayed(
          Duration(milliseconds: delay),
          () => h.supervisor.cancelJob(handle.id),
        );
        final result = await handle.result;
        final outcome = await cancel;

        final terminal = [
          for (final r in h.records())
            if (r.path == 'jobs/${handle.id}' &&
                r.value is Map &&
                const {
                  'settled',
                  'failed',
                  'cancelled',
                }.contains((r.value! as Map)['state']))
              (r.value! as Map)['state'],
        ];
        expect(terminal, hasLength(1), reason: 'delay $delay: $terminal');
        expect(h.node(handle.id)!['state'], result.state, reason: '$delay');
        if (result.state == 'settled') {
          expect(
            outcome,
            anyOf(isA<JobAlreadyExited>(), isA<JobNotLive>()),
            reason: 'delay $delay',
          );
        }
      }
    },
    skip: skip,
  );

  test(
    'stale update for a live process terminates it and records the orphan',
    () async {
      final pause = Pause();
      // No reconciler: the refused `running` record must do it.
      final h = await JobHarness.create(
        hooks: JobHooks(beforeRunning: pause.call),
        reconcile: false,
      );
      await _turns(h, 3);
      ShellProcess? started;
      final handle = h.supervisor.start(
        h.request(
          'sleep 30',
          launch: h.recordingLauncher('sleep 30', (s) => started = s),
        ),
      );
      await pause.reached.future;
      expect(started, isNotNull, reason: 'the process is alive');
      await h.writer.rewind(2);
      expect(h.node(handle.id), isNull);

      pause.release.complete();
      await started!.process.exitCode.timeout(
        _grace,
        onTimeout: () => fail('the stale update left the process running'),
      );
      final result = await handle.result;

      expect(result.stale, isTrue);
      expect(h.states(handle.id), ['pending'], reason: 'never running');
      final orphan = h.at('meta/orphans/${handle.id}')! as Map<String, Object?>;
      expect(orphan['cmd'], 'sleep 30');
      expect(orphan['cleanup'], isA<String>());
      expect(h.at('meta/handoffs/${handle.launch}'), isNull);
    },
    skip: skip,
  );
}
