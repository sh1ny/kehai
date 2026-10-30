import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/job_support.dart';
import '../support/session_support.dart';

/// The spec's drain bound: 2 s, then 2 s more, plus the 1 s probe, with
/// scheduling slack.
const Duration _bound = Duration(milliseconds: 5500);

void _expectHeld(JobResult result, {required String reason}) {
  expect(result.cleanup, startsWith('uncertain'), reason: reason);
  expect(result.cleanup, contains('output pipe held'), reason: reason);
}

void main() {
  final unix = skipUnlessUnix();

  test('[unix] held pipe is force-closed within the bound on exit, cancel and rewind', () async {
    // Exit: the command ends by itself while a descendant keeps stdout.
    {
      final h = await JobHarness.create();
      final pids = h.marker('exit.pid');
      killHolderAtEnd(pids);
      final clock = Stopwatch()..start();
      final handle = h.supervisor.start(h.request(holdStdout(pids)));
      final result = await handle.result;
      clock.stop();

      expect(clock.elapsed, lessThan(_bound), reason: 'exit');
      expect(result.state, 'settled');
      expect(result.exit, 0);
      _expectHeld(result, reason: 'exit');
      final node = h.node(handle.id)!;
      expect(node['cleanup'], contains('output pipe held'));
      expect(h.stream(node, 'stdout'), 'printed\n');
      expect(h.stream(node, 'output'), 'printed\n');
      expect(h.complete(node, 'stdout'), isFalse);
      expect(h.complete(node, 'output'), isFalse);
      expect(h.complete(node, 'stderr'), isTrue);
      expect(h.supervisor.liveCount, 0, reason: 'the slot is free');
      expect(h.at('meta/handoffs/${handle.launch}'), isNull);
      final again = h.supervisor.start(h.request('echo next'));
      expect((await again.result).state, 'settled');
    }

    // Cancel: SIGTERM ends the shell, the escaped descendant stays.
    {
      final h = await JobHarness.create();
      final pids = h.marker('cancel.pid');
      killHolderAtEnd(pids);
      final handle = h.supervisor.start(
        h.request('${holdStdout(pids)}; sleep 30'),
      );
      await readPid(pids);
      final clock = Stopwatch()..start();
      final outcome = await h.supervisor.cancelJob(handle.id);
      clock.stop();

      expect(clock.elapsed, lessThan(_bound), reason: 'cancel');
      final result = (outcome as JobCancelled).result;
      expect(result.state, 'cancelled');
      _expectHeld(result, reason: 'cancel');
      final node = h.node(handle.id)!;
      expect(node['state'], 'cancelled');
      expect(node['reason'], 'user');
      expect(h.stream(node, 'stdout'), 'printed\n');
      expect(h.complete(node, 'stdout'), isFalse);
      expect(h.supervisor.liveCount, 0);
    }

    // Rewind: the node is gone when the command ends; the streams are
    // listed under meta/orphans.
    {
      final h = await JobHarness.create();
      final pids = h.marker('rewind.pid');
      final go = h.marker('rewind.go');
      killHolderAtEnd(pids);
      await h.writer.apply(rec(1, 'body/marker', Op.set, 1));
      await h.writer.apply(rec(2, 'body/marker', Op.set, 2));
      final handle = h.supervisor.start(
        h.request(
          "${holdStdout(pids)}; while [ ! -e '$go' ]; do sleep 0.05; done",
        ),
      );
      await readPid(pids);
      await waitFor(
        () => h.node(handle.id)?['state'] == 'running',
        what: 'the job to run',
      );
      await h.writer.rewind(1);
      expect(h.node(handle.id), isNull);

      final clock = Stopwatch()..start();
      File(go).writeAsStringSync('');
      final result = await handle.result;
      clock.stop();

      expect(clock.elapsed, lessThan(_bound), reason: 'rewind');
      expect(result.stale, isTrue);
      expect(h.node(handle.id), isNull, reason: 'no node is recreated');
      final orphan = h.at('meta/orphans/${handle.id}')! as Map<String, Object?>;
      final outputs =
          (orphan['outputs']! as Map<String, Object?>)[handle.launch]!
              as Map<String, Object?>;
      final stdout = outputs['stdout']! as Map<String, Object?>;
      expect(stdout['disposition'], 'spooled');
      expect(stdout['sha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
      final spool = File(
        p.join(h.dir.path, resultsDirName, stdout['spool']! as String),
      );
      expect(spool.readAsStringSync(), 'printed\n');
      expect(h.at('meta/handoffs/${handle.launch}'), isNull);
      expect(h.supervisor.liveCount, 0);
    }
  }, skip: unix);

  test(
    '[unix] hook with held pipe meets its deadline and frees its slot',
    () async {
      final h = await JobHarness.create();
      final pids = h.marker('hook.pid');
      killHolderAtEnd(pids);
      final clock = Stopwatch()..start();
      final handle = h.supervisor.start(
        h.request(
          '${holdStdout(pids)}; sleep 30',
          kind: JobKind.hook,
          deadline: const Duration(seconds: 2),
        ),
      );

      await handle.exited;
      final exitedAt = clock.elapsed;
      final result = await handle.result;
      clock.stop();

      expect(
        exitedAt,
        lessThan(const Duration(milliseconds: 4500)),
        reason: 'the hook runner waits at most the deadline plus the grace',
      );
      expect(clock.elapsed, lessThan(const Duration(seconds: 2) + _bound));
      expect(result.state, 'cancelled');
      expect(result.reason, 'deadline');
      _expectHeld(result, reason: 'hook');
      expect(h.node(handle.id)!['kind'], 'hook');
      expect(h.supervisor.liveCount, 0);
      final again = h.supervisor.start(h.request('echo next'));
      expect((await again.result).state, 'settled');
    },
    skip: unix,
  );
}
