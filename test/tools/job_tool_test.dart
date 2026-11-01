import 'dart:async';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/bash_support.dart';

/// An agent channel whose child printed protocol noise and left a typed end.
final class _Typed implements JobChannel {
  static const String text =
      'agent r done (2 steps, session c-1)\nVERDICT: APPROVE';

  @override
  void attach(JobHost host) {}

  @override
  Future<void> onChunk(List<int> chunk) async {}

  @override
  Future<void> softStop() async {}

  @override
  Future<ChannelEnd> finish(JobEnd end) async => const ChannelEnd(text, {
    'role': 'r',
    'model': 'm',
    'session': 'c-1',
    'status': 'done',
    'steps': 2,
    'usage': <String, Object?>{},
  });
}

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
    test(
      'job wait and output on an agent job return the typed result',
      () async {
        final h = await BashHarness.create();
        final handle = h.runtime.jobs.start(
          JobRequest(
            kind: JobKind.agent,
            cmd: 'r',
            cwd: h.workspace.path,
            channel: _Typed(),
            // The process prints its version: protocol noise in the output stream.
            launch: () async => ShellProcess(
              await startProcess(
                Platform.resolvedExecutable,
                ['--version'],
                workingDirectory: h.workspace.path,
                environment: Platform.environment,
                keepStdin: true,
              ),
              groupKnown: false,
            ),
          ),
        );
        await handle.result;

        final waited = await h.call('job', {
          'id': handle.id,
          'action': 'wait',
          'timeout_s': 30,
        });
        final output = await h.call('job', {
          'id': handle.id,
          'action': 'output',
        });

        for (final text in [waited, output]) {
          expect(text, contains(_Typed.text));
          expect(text, isNot(contains('Dart SDK version')));
        }
        expect(h.lastCall['envelope'], 'ok');
        expect(h.stream(h.job(handle.id), 'output'), contains('Dart SDK'));
      },
    );

    test(
      'job on an agent job without a result names its interruption',
      () async {
        final h = await BashHarness.create();
        await h.writer.apply(
          JournalRecord(
            turn: h.writer.currentTurn,
            path: 'jobs/j-dead',
            op: Op.set,
            value: {
              'kind': 'agent',
              'cmd': 'r',
              'cwd': h.workspace.path,
              'state': 'cancelled',
              'reason': 'interrupted',
              'agent': {'role': 'r', 'session': 'c-9', 'status': 'cancelled'},
            },
          ),
        );
        const text =
            'agent r cancelled (interrupted before its result was stored; '
            'session c-9)';

        final waited = await h.call('job', {'id': 'j-dead', 'action': 'wait'});
        final output = await h.call('job', {
          'id': 'j-dead',
          'action': 'output',
        });

        expect(waited, contains(text));
        expect(output, contains(text));
      },
    );

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
