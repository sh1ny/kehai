import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/job_support.dart';

/// A fake child engine: reads lines from stdin and answers on stdout.
///
/// Modes: `echo` answers `got <line>` per line and exits when stdin ends;
/// `obedient` also exits 0 on an `interrupt` line; `stubborn` answers an
/// `interrupt` with `saw interrupt` and then ignores stdin and its end.
const String _fakeChild = r'''
import 'dart:async';
import 'dart:convert';
import 'dart:io';

Future<void> main(List<String> args) async {
  final mode = args.first;
  final done = Completer<void>();
  stdin.transform(utf8.decoder).transform(const LineSplitter()).listen(
    (line) {
      if (line == 'interrupt') {
        stdout.writeln('saw interrupt');
        if (mode == 'obedient') exit(0);
        return;
      }
      stdout.writeln('got $line');
    },
    onDone: () {
      if (mode != 'stubborn') done.complete();
    },
  );
  if (mode == 'stubborn') {
    await Future<void>.delayed(const Duration(minutes: 5));
  }
  await done.future;
}
''';

/// Records what the supervisor does to a channel.
final class _Channel implements JobChannel {
  _Channel(this.h, {this.onLine, this.end});

  final JobHarness h;

  /// Runs for every chunk after it was recorded.
  final FutureOr<void> Function(_Channel channel, String chunk)? onLine;

  /// The typed end [finish] returns.
  final ChannelEnd? end;

  late JobHost host;
  final List<String> events = [];
  final List<String> chunks = [];
  final List<bool> spooledFirst = [];
  JobEnd? finished;
  int _seen = 0;

  @override
  void attach(JobHost host) {
    this.host = host;
    events.add('attach');
  }

  @override
  Future<void> onChunk(List<int> chunk) async {
    // The chunk must already be in the stdout spool.
    _seen += chunk.length;
    final spool = h.spools().where((n) => n.endsWith('-stdout')).single;
    final bytes = File(p.join(h.dir.path, resultsDirName, spool))
        .readAsBytesSync();
    spooledFirst.add(bytes.length >= _seen);
    final text = utf8.decode(chunk);
    chunks.add(text);
    events.add('chunk');
    await onLine?.call(this, text);
  }

  @override
  Future<void> softStop() async {
    events.add('softStop');
    try {
      host.stdin.add(utf8.encode('interrupt\n'));
      await host.stdin.close();
    } on Object {
      // Already closed.
    }
  }

  @override
  Future<ChannelEnd> finish(JobEnd end) async {
    events.add('finish');
    finished = end;
    return this.end ?? const ChannelEnd('', {'status': 'done'});
  }
}

/// Starts the fake child in [mode] with stdin kept open.
Future<ShellProcess> _child(JobHarness h, String mode) async {
  final script = File(p.join(h.cwd, 'fake_child.dart'))
    ..writeAsStringSync(_fakeChild);
  final process = await startProcess(
    Platform.resolvedExecutable,
    [script.path, mode],
    workingDirectory: h.cwd,
    environment: Platform.environment,
    keepStdin: true,
  );
  return ShellProcess(process, groupKnown: false);
}

JobRequest _agent(
  JobHarness h,
  String mode,
  _Channel channel, {
  Duration deadline = const Duration(seconds: 60),
  JobKind kind = JobKind.agent,
}) => JobRequest(
  kind: kind,
  cmd: 'agent fake',
  cwd: h.cwd,
  deadline: deadline,
  channel: channel,
  launch: () => _child(h, mode),
);

void main() {
  final skip = skipWithoutShell();
  const fast = JobTimings(
    softStop: Duration(milliseconds: 600),
    grace: Duration(milliseconds: 300),
    drain: Duration(milliseconds: 300),
  );

  test('stdin stays open and writable until the channel closes it', () async {
    final h = await JobHarness.create();
    final channel = _Channel(
      h,
      onLine: (c, chunk) async {
        if (chunk.contains('got one')) {
          c.host.stdin.add(utf8.encode('two\n'));
        } else if (chunk.contains('got two')) {
          await c.host.stdin.close();
        }
      },
    );
    final handle = h.supervisor.start(_agent(h, 'echo', channel));
    await waitFor(() => channel.events.contains('attach'));
    channel.host.stdin.add(utf8.encode('one\n'));
    final result = await handle.result.timeout(const Duration(seconds: 60));

    expect(result.state, 'settled');
    expect(result.exit, 0);
    expect(channel.chunks.join(), 'got one\ngot two\n');
    expect(channel.events.first, 'attach');
    expect(channel.events.last, 'finish');
    expect(channel.events, isNot(contains('softStop')));
    final node = h.node(handle.id)!;
    expect(h.stream(node, 'stdout'), 'got one\ngot two\n');
  }, skip: skip);

  test(
    'each stdout chunk reaches the channel only after it is spooled',
    () async {
      final h = await JobHarness.create();
      final channel = _Channel(
        h,
        onLine: (c, chunk) async {
          if (chunk.contains('got b')) await c.host.stdin.close();
        },
      );
      final handle = h.supervisor.start(_agent(h, 'echo', channel));
      await waitFor(() => channel.events.contains('attach'));
      channel.host.stdin.add(utf8.encode('a\n'));
      await waitFor(() => channel.chunks.join().contains('got a'));
      channel.host.stdin.add(utf8.encode('b\n'));
      await handle.result.timeout(const Duration(seconds: 60));

      expect(channel.spooledFirst, isNotEmpty);
      expect(channel.spooledFirst, everyElement(isTrue));
    },
    skip: skip,
  );

  test(
    'cancel soft-stops the child first and spares it when it exits',
    () async {
      final h = await JobHarness.create(timings: fast);
      final channel = _Channel(h);
      final handle = h.supervisor.start(_agent(h, 'obedient', channel));
      await waitFor(() => channel.events.contains('attach'));
      await Future<void>.delayed(const Duration(milliseconds: 200));

      final outcome = await h.supervisor.cancelJob(handle.id);

      final result = (outcome as JobCancelled).result;
      expect(result.state, 'cancelled');
      expect(result.reason, 'user');
      expect(result.exit, 0, reason: 'the child ended by itself, unsignalled');
      expect(channel.events.where((e) => e == 'softStop'), hasLength(1));
      expect(channel.chunks.join(), contains('saw interrupt'));
      expect(
        channel.events.indexOf('softStop'),
        lessThan(channel.events.indexOf('finish')),
      );
      expect(channel.finished?.cancelReason, 'user');
    },
    skip: skip,
  );

  test(
    'cancel waits the soft stop before terminating a stubborn child',
    () async {
      final h = await JobHarness.create(timings: fast);
      final channel = _Channel(h);
      final handle = h.supervisor.start(_agent(h, 'stubborn', channel));
      await waitFor(() => channel.events.contains('attach'));
      await Future<void>.delayed(const Duration(milliseconds: 300));

      final clock = Stopwatch()..start();
      final outcome = await h.supervisor.cancelJob(handle.id);

      final result = (outcome as JobCancelled).result;
      expect(result.state, 'cancelled');
      expect(result.exit, isNot(0), reason: 'the child was terminated');
      expect(
        clock.elapsed,
        greaterThanOrEqualTo(const Duration(milliseconds: 550)),
        reason: 'the 600 ms soft stop ran before any signal',
      );
      expect(channel.events.where((e) => e == 'softStop'), hasLength(1));
      expect(channel.chunks.join(), contains('saw interrupt'));
    },
    skip: skip,
  );

  test('the deadline takes the same soft-stop path', () async {
    final h = await JobHarness.create(timings: fast);
    final channel = _Channel(h);
    final handle = h.supervisor.start(
      _agent(
        h,
        'obedient',
        channel,
        deadline: const Duration(milliseconds: 1500),
      ),
    );
    final result = await handle.result.timeout(const Duration(seconds: 60));

    expect(result.state, 'cancelled');
    expect(result.reason, 'deadline');
    expect(result.exit, 0);
    expect(channel.events.where((e) => e == 'softStop'), hasLength(1));
    expect(channel.finished?.cancelReason, 'deadline');
  }, skip: skip);

  test(
    'a channel failure ends the job failed with the cause and soft-stops',
    () async {
      final h = await JobHarness.create(timings: fast);
      final channel = _Channel(
        h,
        onLine: (c, chunk) {
          if (chunk.contains('got boom')) {
            c.host.fail('child protocol error: not JSON');
          }
        },
      );
      final handle = h.supervisor.start(_agent(h, 'obedient', channel));
      await waitFor(() => channel.events.contains('attach'));
      channel.host.stdin.add(utf8.encode('boom\n'));
      final result = await handle.result.timeout(const Duration(seconds: 60));

      expect(result.state, 'failed');
      expect(result.reason, 'child protocol error: not JSON');
      expect(channel.events, contains('softStop'));
      expect(channel.finished?.failReason, 'child protocol error: not JSON');
      expect(h.node(handle.id)!['state'], 'failed');
      expect(h.node(handle.id)!['reason'], 'child protocol error: not JSON');
    },
    skip: skip,
  );

  group('the stream set per kind', () {
    test(
      'an agent job carries result and agent through the intent to the settle',
      () async {
        late Map<String, Object?> intent;
        late JobHarness h;
        h = await JobHarness.create(
          hooks: JobHooks(
            afterIntent: (id) async {
              final launch =
                  (h.at('jobs/$id')! as Map<String, Object?>)['launch'];
              intent = h.at('meta/handoffs/$launch')! as Map<String, Object?>;
            },
          ),
        );
        final channel = _Channel(
          h,
          end: const ChannelEnd('agent r done (1 steps, session c1)\nOK\n', {
            'role': 'r',
            'session': 'c1',
            'status': 'done',
            'steps': 1,
          }),
          onLine: (c, chunk) async {
            if (chunk.contains('got x')) await c.host.stdin.close();
          },
        );
        final handle = h.supervisor.start(_agent(h, 'echo', channel));
        await waitFor(() => channel.events.contains('attach'));
        await channel.host.merge({
          'agent': {'role': 'r', 'model': 'm', 'session': 'c1'},
        });
        expect(h.node(handle.id)!['agent'], containsPair('session', 'c1'));
        channel.host.stdin.add(utf8.encode('x\n'));
        final result = await handle.result.timeout(const Duration(seconds: 60));

        expect(result.state, 'settled');
        expect(result.streams.keys, [...jobStreams, 'result']);
        final node = h.node(handle.id)!;
        expect(node['kind'], 'agent');
        expect(h.stream(node, 'result'), startsWith('agent r done (1 steps'));
        expect(h.complete(node, 'result'), isTrue);
        expect(node['agent'], containsPair('status', 'done'));
        expect(node['agent'], containsPair('steps', 1));
        expect((intent['streams']! as Map<String, Object?>).keys, [
          ...jobStreams,
          'result',
        ]);
        expect(
          (intent['outcome']! as Map<String, Object?>)['agent'],
          containsPair('status', 'done'),
        );
        expect(h.at('meta/handoffs/${handle.launch}'), isNull);
        expect(h.spools(), isEmpty);
      },
      skip: skip,
    );

    test('shell and hook jobs keep the three streams and no result', () async {
      final h = await JobHarness.create();
      for (final kind in [JobKind.shell, JobKind.hook]) {
        final handle = h.supervisor.start(h.request('echo hi', kind: kind));
        final result = await handle.result;
        expect(result.streams.keys, jobStreams, reason: kind.wire);
        final node = h.node(handle.id)!;
        expect(node.containsKey('result'), isFalse, reason: kind.wire);
        expect(node.containsKey('agent'), isFalse, reason: kind.wire);
      }
      expect(JobKind.shell.streams, jobStreams);
      expect(JobKind.hook.streams, jobStreams);
      expect(JobKind.agent.streams, [...jobStreams, 'result']);
    }, skip: skip);
  });
}
