import 'dart:async';

import 'package:test/test.dart';

import '../support/bash_support.dart';

void main() {
  final skip = skipBash();

  group('job', () {
    test(
      'output snapshot is incomplete while running and wait returns exit',
      () async {
        final h = await BashHarness.create();
        final started = await h.call('bash', {
          'command': 'echo first; sleep 6; echo last',
          'timeout_s': 1,
        });
        final id = jobIdIn(started);

        // Under load the shell may not have printed yet at hand-off.
        var output = await h.call('job', {'id': id, 'action': 'output'});
        final clock = Stopwatch()..start();
        while (!output.contains('first') &&
            clock.elapsed < const Duration(seconds: 4)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          output = await h.call('job', {'id': id, 'action': 'output'});
        }

        final snapshot = h.lastCall;
        expect(snapshot['envelope'], 'ok');
        expect((snapshot['result']! as Map)['complete'], isFalse);
        expect(output, contains('first'));
        expect(output, isNot(contains('last')));

        final waited = await h.call('job', {
          'id': id,
          'action': 'wait',
          'timeout_s': 30,
        });

        expect(h.lastCall['envelope'], 'ok');
        expect(waited, contains('settled'));
        expect(waited, contains('exit 0'));
        expect(h.job(id)['state'], 'settled');
        expect(h.stream(h.job(id), 'output'), 'first\nlast\n');

        final status = await h.call('job', {'id': id, 'action': 'status'});
        expect(status, contains('settled'));
        expect(status, contains('exit 0'));

        final final_ = await h.call('job', {'id': id, 'action': 'output'});
        expect(final_, contains('last'));
        expect((h.lastCall['result']! as Map)['complete'], isTrue);
      },
      skip: skip,
    );

    test('unknown id errors and cancel of a settled job is a no-op', () async {
      final h = await BashHarness.create();

      final unknown = await h.call('job', {'id': 'j-nope', 'action': 'cancel'});
      expect(h.lastCall['envelope'], 'error');
      expect(h.lastCall['summary'], 'unknown job j-nope');
      expect(unknown, contains('unknown job j-nope'));

      await h.call('bash', {'command': 'echo done'});
      final id = h.jobNodes.keys.single;
      final before = h.job(id).toString();

      final text = await h.call('job', {'id': id, 'action': 'cancel'});

      expect(h.lastCall['envelope'], 'ok');
      expect(h.lastCall['summary'], 'job $id already settled');
      expect(text, contains('already settled'));
      expect(h.job(id).toString(), before);
      expect(h.job(id)['state'], 'settled');
    }, skip: skip);

    test('cancel stops a running job', () async {
      final h = await BashHarness.create();
      final started = await h.call('bash', {
        'command': 'echo up; sleep 30',
        'timeout_s': 1,
      });
      final id = jobIdIn(started);

      await h.call('job', {'id': id, 'action': 'cancel'});

      expect(h.lastCall['envelope'], 'ok');
      expect(h.job(id)['state'], 'cancelled');
      expect(h.job(id)['reason'], 'user');
    }, skip: skip);
    test('a wait that ends early leaves no timer running', () async {
      final h = await BashHarness.create();
      final started = await h.call('bash', {
        'command': 'sleep 2',
        'timeout_s': 1,
      });
      final id = jobIdIn(started);

      // Record the timers the wait creates; its 600 s limit must not
      // outlive it, or it keeps the isolate alive after close.
      final timers = <Timer>[];
      await runZoned(
        () => h.call('job', {'id': id, 'action': 'wait', 'timeout_s': 600}),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, f) {
            final timer = parent.createTimer(zone, duration, f);
            if (duration >= const Duration(seconds: 600)) timers.add(timer);
            return timer;
          },
        ),
      );

      expect(h.job(id)['state'], 'settled');
      expect(timers, isNotEmpty);
      expect(timers.where((t) => t.isActive), isEmpty);
    }, skip: skip);
  });
}
