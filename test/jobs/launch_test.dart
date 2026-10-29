import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/job_support.dart';
import '../support/session_support.dart';

void main() {
  final skip = skipWithoutShell();

  test(
    'rewind during launch kills the started process and never records running',
    () async {
      final pause = Pause();
      final h = await JobHarness.create(
        hooks: JobHooks(afterPending: pause.call),
      );
      await h.writer.apply(rec(1, 'body/marker', Op.set, 1));
      await h.writer.apply(rec(2, 'body/marker', Op.set, 2));

      ShellProcess? started;
      final handle = h.supervisor.start(
        h.request(
          'sleep 30',
          launch: h.recordingLauncher('sleep 30', (s) => started = s),
        ),
      );
      expect(await pause.reached.future, handle.id);
      expect(h.node(handle.id)?['state'], 'pending');
      expect(
        h.at('meta/handoffs/${handle.launch}'),
        isA<Map<String, Object?>>(),
      );

      await h.writer.rewind(1);
      expect(h.node(handle.id), isNull, reason: 'rewind removed the node');

      final clock = Stopwatch()..start();
      pause.release.complete();
      final result = await handle.result;
      clock.stop();

      expect(result.stale, isTrue);
      expect(started, isNotNull, reason: 'the start then succeeded');
      await started!.process.exitCode.timeout(
        const Duration(seconds: 5),
        onTimeout: () => fail('the started process tree was not terminated'),
      );
      expect(clock.elapsed, lessThan(const Duration(seconds: 6)));
      expect(h.states(handle.id), ['pending'], reason: 'never running');
      expect(h.node(handle.id), isNull);

      final orphan = h.at('meta/orphans/${handle.id}')! as Map<String, Object?>;
      expect(orphan['cmd'], 'sleep 30');
      expect(orphan['cleanup'], isA<String>());
      expect(orphan['rewoundTo'], 1);
      final outputs =
          (orphan['outputs']! as Map<String, Object?>)[handle.launch]
              as Map<String, Object?>;
      expect(outputs.keys, unorderedEquals(jobStreams));
      expect(h.at('meta/handoffs/${handle.launch}'), isNull);
      expect(h.supervisor.liveCount, 0);
    },
    skip: skip,
  );

  test(
    'cancel during launch records cancelled user and never running',
    () async {
      for (final point in ['afterPending', 'afterStart', 'beforeRunning']) {
        final pause = Pause();
        final h = await JobHarness.create(
          hooks: switch (point) {
            'afterPending' => JobHooks(afterPending: pause.call),
            'afterStart' => JobHooks(afterStart: pause.call),
            _ => JobHooks(beforeRunning: pause.call),
          },
        );
        ShellProcess? started;
        final handle = h.supervisor.start(
          h.request(
            'sleep 30',
            launch: h.recordingLauncher('sleep 30', (s) => started = s),
          ),
        );
        expect(await pause.reached.future, handle.id, reason: point);

        final cancel = h.supervisor.cancelJob(handle.id);
        pause.release.complete();
        final outcome = await cancel;

        expect(outcome, isA<JobCancelled>(), reason: point);
        final node = h.node(handle.id)!;
        expect(node['state'], 'cancelled', reason: point);
        expect(node['reason'], 'user', reason: point);
        expect(h.states(handle.id), ['pending', 'cancelled'], reason: point);
        for (final name in jobStreams) {
          expect(h.complete(node, name), isFalse, reason: '$point $name');
        }
        if (point == 'afterPending') {
          expect(started, isNull, reason: 'nothing was started');
        } else {
          expect(started, isNotNull, reason: point);
          await started!.process.exitCode.timeout(
            const Duration(seconds: 5),
            onTimeout: () => fail('$point: the process was not terminated'),
          );
        }
        expect(h.at('meta/handoffs/${handle.launch}'), isNull, reason: point);
        expect(h.supervisor.liveCount, 0, reason: point);
      }
    },
    skip: skip,
  );
}
