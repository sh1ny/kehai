/// Pre-ship review fixes (change core-tools): each test drives the real
/// runtime with the real `bash` and `job` tools and the real supervisor.
library;

import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/bash_support.dart';
import '../support/job_support.dart';

void main() {
  final skip = skipBash();

  test(
    'F1: a cancelled bash call answers with the output the job printed',
    () async {
      final h = await BashHarness.create();
      final running = h.call('bash', {
        'command': r"printf 'one\ntwo\nthree\n'; sleep 30",
      });
      await waitFor(
        () =>
            h.jobNodes.length == 1 &&
            h.jobNodes.values.single['state'] == 'running',
        what: 'the foreground job to start',
      );
      // Wait until the three lines reached the job's spool.
      final id = h.jobNodes.keys.single;
      final clock = Stopwatch()..start();
      while (true) {
        final snap = await h.runtime.jobs.snapshot(id, 'output');
        if (snap is ResultComplete && snap.descriptor.lines >= 3) break;
        if (clock.elapsed > const Duration(seconds: 20)) fail('no output');
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(await h.runtime.cancelTurn(), 1);

      final node = h.lastCall;
      expect(node['status'], 'cancelled');
      expect(node['envelope'], 'error');
      expect(node['summary'], 'cancelled: user');
      expect((node['result']! as Map)['complete'], isFalse);
      expect(h.resultOf(node), 'one\ntwo\nthree\n');
      final text = await running;
      expect(text, contains('three'));
    },
    skip: skip,
  );

  test(
    'F2: a launch failure settles the call failed with the OS error',
    () async {
      final probe = await BashHarness.create();
      final real = probe.runtime.shell.shell!;
      final h = await BashHarness.create(
        shell: ShellDetection.found(
          ShellInfo(
            kind: real.kind,
            executable: '${probe.workspace.path}/no-such-shell',
          ),
        ),
      );

      final text = await h.call('bash', {'command': 'echo hi'});

      final node = h.lastCall;
      expect(node['status'], 'failed');
      expect(node['envelope'], 'error');
      final job = h.jobNodes.values.single;
      expect(job['state'], 'failed');
      expect(node['reason'], job['reason']);
      expect(node['reason'], isNotEmpty);
      expect(node['summary'], contains(job['reason']! as String));
      expect(text, contains('failed to start'));
    },
    skip: skip,
  );

  test(
    'F2: the 17th live job settles the call failed and starts nothing',
    () async {
      final h = await BashHarness.create();
      final shell = h.runtime.shell.shell!;
      for (var i = 0; i < maxLiveJobs; i++) {
        h.runtime.jobs.start(
          JobRequest.shell(
            shell,
            'sleep 30',
            cwd: h.workspace.path,
            environment: Platform.environment,
          ),
        );
      }
      expect(h.runtime.jobs.liveCount, maxLiveJobs);

      final text = await h.call('bash', {'command': 'echo refused'});

      final node = h.lastCall;
      expect(node['status'], 'failed');
      expect(node['envelope'], 'error');
      expect(node['summary'], 'too many live jobs (16); cancel one with job');
      expect(node['reason'], node['summary']);
      expect(text, contains('too many live jobs (16)'));
      expect(h.runtime.jobs.liveCount, maxLiveJobs);
      expect(h.jobNodes.length, maxLiveJobs);
    },
    skip: skip,
    timeout: const Timeout(Duration(seconds: 90)),
  );

  test('F3: job cancel reports the cleanup outcome and the reason', () async {
    final h = await BashHarness.create();
    final id = jobIdIn(
      await h.call('bash', {'command': 'echo up; sleep 30', 'timeout_s': 1}),
    );

    final text = await h.call('job', {'id': id, 'action': 'cancel'});

    final cleanup = h.job(id)['cleanup']! as String;
    expect(cleanup, anyOf('confirmed', startsWith('uncertain: ')));
    if (Platform.isWindows) {
      expect(cleanup, 'uncertain: descendants not verifiable');
    }
    final summary = h.lastCall['summary']! as String;
    expect(summary, startsWith('job $id cancelled (user)'));
    expect(summary, contains('cleanup $cleanup'));
    expect(text, contains('cleanup $cleanup'));
    expect(h.resultOf(h.lastCall), contains('cleanup: $cleanup'));
  }, skip: skip);

  test(
    'F3: a bash call ended by its deadline reports uncertain cleanup',
    () async {
      final h = await BashHarness.create();

      await h.call('bash', {'command': 'sleep 30', 'deadline_s': 1});

      final job = h.jobNodes.values.single;
      expect(job['reason'], 'deadline');
      final cleanup = job['cleanup']! as String;
      final summary = h.lastCall['summary']! as String;
      expect(h.lastCall['envelope'], 'timeout');
      if (cleanup.startsWith('uncertain')) {
        expect(summary, contains('cleanup $cleanup'));
      }
    },
    skip: skip,
  );

  test('F4: job output composes with the bash cut, head and tail', () async {
    final h = await BashHarness.create();
    await h.call('bash', {'command': 'seq 1 30000'});
    final id = h.jobNodes.keys.single;

    final text = await h.call('job', {'id': id, 'action': 'output'});

    expect(text, contains('\n1\n'));
    expect(text, contains('\n30000'), reason: 'the tail is visible');
    expect(text, contains('read_more'));
    expect(text.length, lessThan('30000'.length * 30000 ~/ 3));
  }, skip: skip);
}
