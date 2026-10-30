import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/job_support.dart';

void _noPids(Object? value, int? pid, String where) {
  switch (value) {
    case final Map<Object?, Object?> map:
      for (final MapEntry(:key, :value) in map.entries) {
        expect(
          (key! as String).toLowerCase(),
          isNot(contains('pid')),
          reason: '$where holds a pid field',
        );
        _noPids(value, pid, '$where/$key');
      }
    case final List<Object?> list:
      for (final item in list) {
        _noPids(item, pid, where);
      }
    case final int number:
      expect(number, isNot(pid), reason: '$where holds the process id');
  }
}

void main() {
  final skip = skipWithoutShell();

  test('echo hi job node holds no pid and resolves its outputs', () async {
    final h = await JobHarness.create();
    int? pid;
    final handle = h.supervisor.start(
      h.request(
        'echo hi',
        launch: h.recordingLauncher('echo hi', (s) => pid = s.process.pid),
      ),
    );
    expect(handle.id, matches(RegExp(r'^j-[0-9a-f]{8}$')));
    final result = await handle.result;

    expect(result.state, 'settled');
    final node = h.node(handle.id)!;
    expect(node['kind'], 'shell');
    expect(node['cmd'], 'echo hi');
    expect(node['state'], 'settled');
    expect(node['exit'], 0);
    expect(node['launch'], handle.launch);
    expect(h.stream(node, 'stdout'), 'hi\n');
    expect(h.stream(node, 'output'), 'hi\n');
    expect(h.stream(node, 'stderr'), '');
    for (final name in jobStreams) {
      expect(h.complete(node, name), isTrue, reason: name);
    }
    expect(pid, isNotNull);
    _noPids(node, pid, 'jobs/${handle.id}');
    expect(h.at('meta/handoffs/${handle.launch}'), isNull);
    expect(h.spools(), isEmpty);
    expect(h.states(handle.id), ['pending', 'running', 'settled']);
  }, skip: skip);

  test('vanished shell fails the job pending to failed and clears its launch record', () async {
    final h = await JobHarness.create();
    final gone = ShellInfo(
      kind: ShellKind.bash,
      executable: '${h.cwd}/no-such-bash',
    );
    final handle = h.supervisor.start(
      JobRequest.shell(
        gone,
        'echo hi',
        cwd: h.cwd,
        environment: Platform.environment,
      ),
    );
    final result = await handle.result;

    expect(result.state, 'failed');
    final node = h.node(handle.id)!;
    expect(node['state'], 'failed');
    expect(
      node['reason'],
      isA<String>().having((r) => r, 'reason', isNotEmpty),
    );
    expect(node.containsKey('stdout'), isFalse);
    expect(node.containsKey('output'), isFalse);
    expect(h.states(handle.id), ['pending', 'failed']);
    expect(h.at('meta/handoffs/${handle.launch}'), isNull);
    expect(h.spools(), isEmpty);
    expect(h.supervisor.liveCount, 0);
  }, skip: skip);

  test('17th live job is refused until one is cancelled', () async {
    final h = await JobHarness.create();
    final handles = [
      for (var i = 0; i < maxLiveJobs; i++)
        h.supervisor.start(h.request('sleep 30')),
    ];
    expect(h.supervisor.liveCount, maxLiveJobs);

    var launched = 0;
    expect(
      () => h.supervisor.start(
        h.request(
          'echo refused',
          launch: () async {
            launched++;
            throw const ProcessException('x', []);
          },
        ),
      ),
      throwsA(
        isA<TooManyLiveJobs>().having(
          (e) => e.message,
          'message',
          'too many live jobs (16); cancel one with job',
        ),
      ),
    );
    expect(launched, 0);

    final outcome = await h.supervisor.cancelJob(handles.first.id);
    expect(outcome, isA<JobCancelled>());
    expect(h.supervisor.liveCount, maxLiveJobs - 1);

    final next = h.supervisor.start(h.request('echo again'));
    expect((await next.result).state, 'settled');
    final jobs = h.at('jobs')! as Map<String, Object?>;
    expect(jobs.length, maxLiveJobs + 1, reason: 'the refused call left none');
  }, skip: skip);

  test('exit frees the slot before the next admission', () async {
    final h = await JobHarness.create();
    final flag = h.marker('go');
    final waiter = h.supervisor.start(
      h.request("while [ ! -e '$flag' ]; do sleep 0.05; done"),
    );
    for (var i = 1; i < maxLiveJobs; i++) {
      h.supervisor.start(h.request('sleep 30'));
    }
    expect(h.supervisor.liveCount, maxLiveJobs);
    expect(
      () => h.supervisor.start(h.request('echo no')),
      throwsA(isA<TooManyLiveJobs>()),
    );

    File(flag).writeAsStringSync('');
    final result = await waiter.result;

    expect(result.state, 'settled');
    expect(h.node(waiter.id)!['state'], 'settled');
    expect(h.supervisor.liveCount, maxLiveJobs - 1);
    final next = h.supervisor.start(h.request('echo admitted'));
    expect((await next.result).state, 'settled');
  }, skip: skip);
}
