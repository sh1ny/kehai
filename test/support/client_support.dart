/// An in-memory engine and a harness for line-client tests.
library;

import 'dart:async';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import 'login_support.dart';

/// An [EngineLink] the test drives by hand.
final class FakeEngine implements EngineLink {
  final StreamController<Map<String, Object?>> _events = StreamController();
  final Completer<int> _exit = Completer();

  /// Every command the client sent, in order.
  final List<Map<String, Object?>> sent = [];

  /// Whether the client closed the engine's input.
  bool inputClosed = false;

  /// Whether the client killed the engine.
  bool killed = false;

  @override
  Stream<Map<String, Object?>> get events => _events.stream;

  @override
  void send(Map<String, Object?> command) => sent.add(command);

  @override
  Future<void> closeInput() async {
    inputClosed = true;
  }

  @override
  Future<int> get exitCode => _exit.future;

  @override
  void kill() {
    killed = true;
  }

  /// Delivers [event] to the client.
  void emit(Map<String, Object?> event) => _events.add(event);

  /// Ends the engine's output and exit with [code].
  Future<void> exit(int code) async {
    if (!_exit.isCompleted) _exit.complete(code);
    if (!_events.isClosed) unawaited(_events.close());
    await pumpEventQueue();
  }

  /// The sent commands of [type].
  List<Map<String, Object?>> sentOfType(String type) => [
    for (final c in sent)
      if (c['type'] == type) c,
  ];
}

/// A client wired to a [FakeEngine] and recording sinks.
final class ClientRig {
  ClientRig._(
    this.engine,
    this.input,
    this.interrupts,
    this.out,
    this.err,
    this.exit,
  );

  /// The engine stand-in.
  final FakeEngine engine;

  final StreamController<String> input;

  /// The Ctrl-C events the client watches.
  final StreamController<Object?> interrupts;

  /// What the client printed to its output.
  final TestSink out;

  /// What the client printed to its error output.
  final TestSink err;

  /// The client's exit code, once it returned.
  final Future<int> exit;

  int _offset = 10;

  /// Types [line] as the user; a terminal echoes it and its newline.
  void type(String line) {
    out.writeln(line);
    input.add(line);
  }

  /// Waits until every queued event was handled.
  Future<void> settle() async {
    await pumpEventQueue();
    await pumpEventQueue();
  }

  /// Sends `hello` and a first `snapshot` holding [tree] at turn [turn].
  Future<void> start({
    Map<String, Object?> tree = const {},
    int turn = 0,
    String session = 's-test',
    String model = 'gpt-5.5',
  }) async {
    engine
      ..emit({
        'type': 'hello',
        'protocol': 1,
        'session': session,
        'workspace': '/ws',
        'model': model,
        'resumed': {'requests': 0, 'calls': 0, 'jobs': 0, 'exchanges': 0},
      })
      ..emit({
        'type': 'snapshot',
        'offset': _offset,
        'turn': turn,
        'tree': tree,
      });
    await settle();
  }

  /// Sends a snapshot at the next offset, as after a `resync`.
  Future<void> resnapshot(Map<String, Object?> tree, {int turn = 0}) async {
    engine.emit({
      'type': 'snapshot',
      'offset': ++_offset,
      'turn': turn,
      'tree': tree,
    });
    await settle();
  }

  /// Sends one committed record as an `update` at the next offset.
  Future<void> update(
    String path,
    String op,
    Object? value, {
    int turn = 1,
  }) async {
    engine.emit({
      'type': 'update',
      'offset': ++_offset,
      'record': {'turn': turn, 'path': path, 'op': op, 'value': value},
    });
    await settle();
  }

  /// Sends a `stream` delta of the step at [turn].
  Future<void> stream(int turn, String delta, {String kind = 'text'}) async {
    engine.emit({'type': 'stream', 'turn': turn, 'kind': kind, 'delta': delta});
    await settle();
  }

  /// Sends a `prompt` event.
  Future<void> prompt(
    String key,
    String tool,
    Map<String, Object?> input, {
    String kind = 'permission',
  }) async {
    engine.emit({
      'type': 'prompt',
      'item': {'key': key, 'kind': kind, 'tool': tool, 'input': input},
    });
    await settle();
  }

  /// Sends any other event.
  Future<void> emit(Map<String, Object?> event) async {
    engine.emit(event);
    await settle();
  }

  /// Presses Ctrl-C.
  Future<void> ctrlC() async {
    interrupts.add(null);
    await settle();
  }

  /// Ends the user's input, as a closed pipe.
  Future<void> endInput() async {
    unawaited(input.close());
    await settle();
  }
}

/// Starts a [LineClient] over a [FakeEngine]; everything is torn down after
/// the test.
ClientRig clientRig({
  bool interactive = true,
  Duration exitGrace = const Duration(milliseconds: 50),
}) {
  final engine = FakeEngine();
  final input = StreamController<String>();
  final interrupts = StreamController<Object?>();
  final out = TestSink();
  final err = TestSink();
  final client = LineClient(
    engine: engine,
    input: input.stream,
    out: out,
    err: err,
    interactive: interactive,
    interrupts: interrupts.stream,
    exitGrace: exitGrace,
  );
  final exit = client.run();
  addTearDown(() async {
    if (!input.isClosed) unawaited(input.close());
    if (!interrupts.isClosed) unawaited(interrupts.close());
    await engine.exit(0);
    await exit.timeout(const Duration(seconds: 5), onTimeout: () => -1);
  });
  return ClientRig._(engine, input, interrupts, out, err, exit);
}

/// A step node that committed [text] as its only output.
Map<String, Object?> committedText(String text) => {
  'state': 'completed',
  'stop': 'end_turn',
  'output': [
    {'type': 'text', 'text': text},
  ],
};

/// The step path of the step at journal [turn].
String stepPath(int turn) => 'body/steps/s-${turn.toString().padLeft(8, '0')}';
