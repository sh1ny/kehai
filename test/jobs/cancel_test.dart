import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/job_support.dart';

void main() {
  final skip = skipWithoutShell();
  final unix = skipUnlessUnix();

  test('deadline_s 2 cancels with reason deadline and keeps output', () async {
    final h = await JobHarness.create();
    final clock = Stopwatch()..start();
    final handle = h.supervisor.start(
      h.request('echo before; sleep 30', deadline: const Duration(seconds: 2)),
    );
    final result = await handle.result;
    clock.stop();

    expect(clock.elapsed.inMilliseconds, inInclusiveRange(1900, 6000));
    expect(result.state, 'cancelled');
    expect(result.reason, 'deadline');
    final node = h.node(handle.id)!;
    expect(node['state'], 'cancelled');
    expect(node['reason'], 'deadline');
    expect(node['signal'], 'term');
    expect(h.stream(node, 'stdout'), 'before\n');
    expect(h.stream(node, 'output'), 'before\n');
    for (final name in jobStreams) {
      expect(h.complete(node, name), isFalse, reason: name);
    }
    if (Platform.isWindows) {
      expect(node['cleanup'], startsWith('uncertain'));
    } else {
      expect(node['cleanup'], 'confirmed');
    }
  }, skip: skip);

  test('[unix] SIGTERM-trapping job is killed after the 2 s grace', () async {
    final h = await JobHarness.create();
    final ready = h.marker('ready');
    final handle = h.supervisor.start(
      h.request("trap '' TERM; echo up > '$ready'; while :; do sleep 1; done"),
    );
    await waitFor(
      () => File(ready).existsSync(),
      what: 'the trap to be installed',
    );

    final clock = Stopwatch()..start();
    final outcome = await h.supervisor.cancelJob(handle.id);
    clock.stop();

    expect(outcome, isA<JobCancelled>());
    expect(
      clock.elapsed.inMilliseconds,
      inInclusiveRange(1900, 5000),
      reason: 'survived SIGTERM until the grace ended',
    );
    final node = h.node(handle.id)!;
    expect(node['state'], 'cancelled');
    expect(node['reason'], 'user');
    expect(node['signal'], 'kill', reason: 'records the forced kill');
    expect(node['cleanup'], 'confirmed');
  }, skip: unix);

  test(
    '[unix] cancel kills the shell and both children with cleanup confirmed',
    () async {
      final h = await JobHarness.create();
      final a = h.marker('a.pid');
      final b = h.marker('b.pid');
      final s = h.marker('s.pid');
      int? shellPid;
      final command =
          "sleep 60 & echo \$! > '$a'; sleep 61 & echo \$! > '$b'; "
          "echo \$\$ > '$s'; wait";
      final handle = h.supervisor.start(
        h.request(
          command,
          launch: h.recordingLauncher(
            command,
            (started) => shellPid = started.process.pid,
            groupKnown: true,
          ),
        ),
      );
      final children = [await readPid(a), await readPid(b), await readPid(s)];
      expect(children, everyElement(isPositive));
      for (final pid in children) {
        expect(processAlive(pid), isTrue);
      }

      final outcome = await h.supervisor.cancelJob(handle.id);

      expect(outcome, isA<JobCancelled>());
      final node = h.node(handle.id)!;
      expect(node['state'], 'cancelled');
      expect(node['reason'], 'user');
      expect(node['cleanup'], 'confirmed');
      expect(shellPid, isNotNull);
      for (final pid in [...children, shellPid!]) {
        expect(processAlive(pid), isFalse, reason: 'pid $pid is gone');
      }
    },
    skip: unix,
  );

  test(
    '[windows] tree kill records cleanup uncertain; surviving probe does too',
    () async {
      final h = await JobHarness.create();
      final handle = h.supervisor.start(h.request('sleep 30'));
      await waitFor(
        () => h.node(handle.id)?['state'] == 'running',
        what: 'the job to run',
      );

      await h.supervisor.cancelJob(handle.id);

      final node = h.node(handle.id)!;
      expect(node['state'], 'cancelled');
      expect(node['cleanup'], 'uncertain: descendants not verifiable');
    },
    skip: Platform.isWindows && posixShell() != null
        ? false
        : 'Windows with Git Bash only',
  );

  test(
    'surviving probe records cleanup uncertain: group still present',
    () async {
      // A group that never goes away; SIGKILL really ends the process tree.
      int signalGroup(int pgid, int signal) {
        if (signal == 9) {
          if (Platform.isWindows) {
            Process.runSync('taskkill', ['/PID', '$pgid', '/T', '/F']);
          } else {
            Process.killPid(pgid, ProcessSignal.sigkill);
          }
        }
        return 0;
      }

      final h = await JobHarness.create(
        groupSignal: signalGroup,
        windows: false,
        timings: const JobTimings(
          grace: Duration(milliseconds: 200),
          probe: Duration(milliseconds: 300),
        ),
      );
      final handle = h.supervisor.start(
        h.request(
          'exec sleep 30',
          launch: h.recordingLauncher(
            'exec sleep 30',
            (_) {},
            groupKnown: true,
          ),
        ),
      );
      await waitFor(
        () => h.node(handle.id)?['state'] == 'running',
        what: 'the job to run',
      );

      await h.supervisor.cancelJob(handle.id);

      final node = h.node(handle.id)!;
      expect(node['state'], 'cancelled');
      expect(node['signal'], 'kill');
      expect(node['cleanup'], 'uncertain: group still present');
    },
    skip: skip,
  );
}
