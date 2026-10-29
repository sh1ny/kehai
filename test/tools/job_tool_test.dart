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
          'command': 'echo first; sleep 3; echo last',
          'timeout_s': 1,
        });
        final id = jobIdIn(started);

        final output = await h.call('job', {'id': id, 'action': 'output'});

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
  });
}
