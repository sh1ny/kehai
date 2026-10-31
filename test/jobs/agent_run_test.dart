import 'dart:async';
import 'dart:convert';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

const String _role = 'specwright-reviewer';
const String _session = 'c-0001';

/// A job host that records what the run does to it.
final class _Host implements JobHost {
  /// The bytes the run wrote to the child's stdin.
  final List<int> sent = [];
  final List<Map<String, Object?>> merges = [];
  final List<String> failures = [];
  bool stdinClosed = false;

  @override
  StreamSink<List<int>> get stdin => _Sink(this);

  @override
  Future<void> merge(Map<String, Object?> fields) async => merges.add(fields);

  @override
  void fail(String reason) => failures.add(reason);

  /// The commands written to stdin so far.
  List<Map<String, Object?>> get commands => [
    for (final line in const LineSplitter().convert(utf8.decode(sent)))
      jsonDecode(line) as Map<String, Object?>,
  ];
}

final class _Sink implements StreamSink<List<int>> {
  _Sink(this._host);

  final _Host _host;

  @override
  void add(List<int> data) {
    if (_host.stdinClosed) throw StateError('stdin is closed');
    _host.sent.addAll(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> close() async => _host.stdinClosed = true;

  @override
  Future<void> get done async {}
}

String _line(Map<String, Object?> event) => '${jsonEncode(event)}\n';

Map<String, Object?> _hello({int protocol = 1}) => {
  'type': 'hello',
  'protocol': protocol,
  'session': _session,
  'workspace': '/w',
  'model': 'gpt-6.1-sol',
  'resumed': {'requests': 0, 'calls': 0, 'jobs': 0, 'exchanges': 0},
};

Map<String, Object?> _snapshot({
  int offset = 10,
  int turn = 4,
  Map<String, Object?>? exchange,
  Map<String, Object?> steps = const {},
}) => {
  'type': 'snapshot',
  'offset': offset,
  'turn': turn,
  'tree': {
    'meta': {'session': _session},
    'body': {
      'exchanges': {'x-00000005': ?exchange},
      'steps': steps,
    },
  },
};

Map<String, Object?> _update(int offset, int turn, String path, Object value) =>
    {
      'type': 'update',
      'offset': offset,
      'record': {'turn': turn, 'path': path, 'op': 'merge', 'value': value},
    };

Map<String, Object?> _exchange(String state, {String? reason}) => {
  'request': 'agent',
  'prompt': 'review it',
  'state': state,
  'reason': ?reason,
  'first': 5,
};

Map<String, Object?> _step(
  int turn,
  String? text, {
  String state = 'completed',
}) => {
  'exchange': 'x-00000005',
  'model': 'gpt-6.1-sol',
  'state': state,
  'usage': {'input': 100, 'output': 10},
  'output': [
    if (text != null) {'type': 'text', 'text': text},
  ],
};

String _stepKey(int turn) => 's-${turn.toString().padLeft(8, '0')}';

/// Feeds [text] to [run] in chunks of [size] bytes.
Future<void> _feed(AgentRun run, String text, {int size = 1 << 16}) async {
  final bytes = utf8.encode(text);
  for (var i = 0; i < bytes.length; i += size) {
    await run.onChunk(
      bytes.sublist(i, i + size > bytes.length ? bytes.length : i + size),
    );
  }
}

AgentRun _run(_Host host, {int? lineLimit, String? modelNote}) {
  final run = AgentRun(
    role: _role,
    prompt: 'review it',
    modelNote: modelNote,
    lineLimit: lineLimit ?? maxChildLineBytes,
  );
  run.attach(host);
  return run;
}

void main() {
  test('a done child gives the header line and its final text', () async {
    final host = _Host();
    final run = _run(host);

    await _feed(run, _line(_hello()));
    expect(host.merges.single, {
      'agent': {'role': _role, 'model': 'gpt-6.1-sol', 'session': _session},
    });
    await _feed(run, _line(_snapshot()));
    expect(host.commands, [
      {'type': 'submit', 'id': 'agent', 'text': 'review it', 'turn': 4},
    ]);

    var offset = 11;
    await _feed(
      run,
      _line(
        _update(offset++, 5, 'body/exchanges/x-00000005', _exchange('running')),
      ),
    );
    for (var turn = 5; turn <= 16; turn++) {
      final last = turn == 16;
      await _feed(
        run,
        _line(
          _update(
            offset++,
            turn,
            'body/steps/${_stepKey(turn)}',
            _step(turn, last ? 'VERDICT: APPROVE' : 'thinking $turn'),
          ),
        ),
      );
    }
    expect(host.stdinClosed, isFalse, reason: 'the exchange is still running');
    await _feed(
      run,
      _line(
        _update(offset++, 16, 'body/exchanges/x-00000005', {'state': 'done'}),
      ),
    );
    expect(host.stdinClosed, isTrue, reason: 'the end closes the child stdin');

    final end = await run.finish(const JobEnd(exit: 0));
    expect(
      end.result,
      'agent $_role done (12 steps, session $_session)\nVERDICT: APPROVE',
    );
    expect(end.fields, {
      'role': _role,
      'model': 'gpt-6.1-sol',
      'session': _session,
      'status': 'done',
      'steps': 12,
      'usage': {'input': 1200, 'output': 120},
    });
    expect(host.failures, isEmpty);
  });

  test('a 3 MiB committed response reaches the typed result', () async {
    final host = _Host();
    final run = _run(host);
    final big = 'x' * (3 * 1024 * 1024);

    await _feed(run, _line(_hello()));
    await _feed(run, _line(_snapshot()));
    final update = _line(
      _update(11, 5, 'body/steps/${_stepKey(5)}', _step(5, big)),
    );
    expect(utf8.encode(update).length, greaterThan(maxLineBytes * 2));
    await _feed(run, update);
    await _feed(
      run,
      _line(_update(12, 5, 'body/exchanges/x-00000005', _exchange('done'))),
    );

    final end = await run.finish(const JobEnd(exit: 0));
    expect(host.failures, isEmpty);
    expect(end.fields['status'], 'done');
    expect(end.result.length, greaterThan(big.length));
    expect(end.result, endsWith('\n$big'));
  });

  test('an end seen only in a resync snapshot ends the job', () async {
    final host = _Host();
    final run = _run(host);

    await _feed(run, _line(_hello()));
    await _feed(run, _line(_snapshot()));
    await _feed(
      run,
      _line(_update(11, 5, 'body/exchanges/x-00000005', _exchange('running'))),
    );
    expect(host.stdinClosed, isFalse);

    // The update that ended the exchange was dropped: resync and a snapshot.
    await _feed(run, _line({'type': 'resync'}));
    expect(host.stdinClosed, isFalse);
    await _feed(
      run,
      _line(
        _snapshot(
          offset: 40,
          turn: 6,
          exchange: _exchange('done'),
          steps: {_stepKey(5): _step(5, 'VERDICT: REJECT')},
        ),
      ),
    );

    expect(host.stdinClosed, isTrue);
    expect(
      host.commands.where((c) => c['type'] == 'submit'),
      hasLength(1),
      reason: 'one submit only, not one per snapshot',
    );
    final end = await run.finish(const JobEnd(exit: 0));
    expect(end.fields['status'], 'done');
    expect(end.fields['steps'], 1);
    expect(end.result, endsWith('VERDICT: REJECT'));
  });

  test('a non-JSON line fails the job with child protocol error', () async {
    final host = _Host();
    final run = _run(host);

    await _feed(run, _line(_hello()));
    await _feed(run, 'this is not json\n');

    expect(host.failures, hasLength(1));
    expect(host.failures.single, startsWith('child protocol error'));
    final end = await run.finish(
      JobEnd(exit: 1, failReason: host.failures.single),
    );
    expect(end.fields['status'], 'failed');
    expect(end.result, contains('child protocol error'));
  });

  test(
    'a hello with another protocol, or a line over the limit, fails the job',
    () async {
      final other = _Host();
      await _feed(_run(other), _line(_hello(protocol: 2)));
      expect(other.failures.single, startsWith('child protocol error'));
      expect(other.failures.single, contains('protocol 2'));

      final long = _Host();
      await _feed(_run(long, lineLimit: 1024), '${'y' * 4096}\n');
      expect(long.failures.single, 'child protocol line over 64 MiB');
    },
  );

  test('a child stopped on overflow gives status failed with its reason', () async {
    final host = _Host();
    final run = _run(host);
    const reason =
        'context overflow: ~120k of 128k tokens; rewind or start a new session';

    await _feed(run, _line(_hello()));
    await _feed(run, _line(_snapshot()));
    await _feed(
      run,
      _line(
        _update(
          11,
          5,
          'body/steps/${_stepKey(5)}',
          _step(5, 'partial verdict'),
        ),
      ),
    );
    await _feed(
      run,
      _line(
        _update(
          12,
          6,
          'body/exchanges/x-00000005',
          _exchange('stopped', reason: reason),
        ),
      ),
    );

    expect(host.stdinClosed, isTrue);
    final end = await run.finish(const JobEnd(exit: 0));
    expect(end.fields['status'], 'failed');
    expect(
      end.result,
      'agent $_role failed (1 steps, session $_session)\n'
      'child exchange stopped: $reason\n'
      'partial verdict',
    );
  });

  test(
    'a child that exits before its exchange ended gives status failed',
    () async {
      final host = _Host();
      final run = _run(host);

      await _feed(run, _line(_hello()));
      await _feed(run, _line(_snapshot()));
      await _feed(
        run,
        _line(
          _update(
            11,
            5,
            'body/steps/${_stepKey(5)}',
            _step(5, 'half way there'),
          ),
        ),
      );
      final end = await run.finish(const JobEnd(exit: 3));

      expect(end.fields['status'], 'failed');
      expect(
        end.result,
        'agent $_role failed (1 steps, session $_session)\n'
        'child exited (3) before its exchange ended\n'
        'half way there',
      );
    },
  );

  test(
    'cancel and deadline map to cancelled and timeout, with the text so far',
    () async {
      for (final (reason, status) in [
        ('user', 'cancelled'),
        ('deadline', 'timeout'),
      ]) {
        final host = _Host();
        final run = _run(host);
        await _feed(run, _line(_hello()));
        await _feed(run, _line(_snapshot()));
        await _feed(
          run,
          _line(
            _update(11, 5, 'body/steps/${_stepKey(5)}', _step(5, 'so far')),
          ),
        );

        await run.softStop();
        await run.softStop();
        expect(host.commands.last, {'type': 'interrupt'}, reason: reason);
        expect(
          host.commands.where((c) => c['type'] == 'interrupt'),
          hasLength(1),
          reason: reason,
        );
        // The child still has to report its cancelled exchange: an engine
        // whose input ends sends no more updates.
        expect(host.stdinClosed, isFalse, reason: reason);
        await _feed(
          run,
          _line(
            _update(
              12,
              5,
              'body/exchanges/x-00000005',
              _exchange('cancelled', reason: 'user'),
            ),
          ),
        );
        expect(host.stdinClosed, isTrue, reason: reason);

        final end = await run.finish(JobEnd(exit: 0, cancelReason: reason));
        expect(end.fields['status'], status, reason: reason);
        expect(end.result, endsWith('so far'), reason: reason);
      }
    },
  );

  test(
    'a soft stop before any exchange closes stdin without an interrupt',
    () async {
      final host = _Host();
      final run = _run(host);
      await _feed(run, _line(_hello()));

      await run.softStop();

      expect(host.stdinClosed, isTrue);
      expect(host.commands.where((c) => c['type'] == 'interrupt'), isEmpty);
    },
  );

  test(
    'a fatal line before the exchange fails the job as a failed start',
    () async {
      final host = _Host();
      final run = _run(host);

      await _feed(run, _line({'type': 'fatal', 'message': 'not logged in'}));

      expect(host.failures, ['agent failed to start: not logged in']);
      final end = await run.finish(
        JobEnd(exit: 1, failReason: host.failures.single),
      );
      expect(end.fields['status'], 'failed');
      expect(end.result, 'agent failed to start: not logged in');
    },
  );

  test(
    'prompts and withdrawals go to the relay hooks, answers go back',
    () async {
      final host = _Host();
      final prompts = <Map<String, Object?>>[];
      final withdrawn = <String>[];
      final run = AgentRun(
        role: _role,
        prompt: 'review it',
        onPrompt: prompts.add,
        onWithdraw: withdrawn.add,
      )..attach(host);

      await _feed(run, _line(_hello()));
      await _feed(
        run,
        _line({
          'type': 'prompt',
          'item': {'key': 'c1', 'kind': 'permission'},
        }),
      );
      await _feed(run, _line({'type': 'withdraw', 'key': 'c1'}));
      run.answer('c2', 'allow');

      expect(prompts, [
        {'key': 'c1', 'kind': 'permission'},
      ]);
      expect(withdrawn, ['c1']);
      expect(host.commands.last, {
        'type': 'answer',
        'key': 'c2',
        'text': 'allow',
      });
    },
  );

  test('a model note shows in the typed result and the agent fields', () async {
    final host = _Host();
    final run = _run(host, modelNote: 'model haiku is not configured; used m');

    await _feed(run, _line(_hello()));
    await _feed(run, _line(_snapshot(exchange: _exchange('done'))));
    final end = await run.finish(const JobEnd(exit: 0));

    expect(end.fields['note'], 'model haiku is not configured; used m');
    expect(end.result.split('\n').take(2), [
      'agent $_role done (0 steps, session $_session)',
      'model haiku is not configured; used m',
    ]);
  });
}
