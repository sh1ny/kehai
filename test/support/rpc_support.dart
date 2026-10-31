import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'fake_provider.dart';
import 'session_support.dart';

/// A server running over in-memory byte streams, with a client side that
/// records every line the server writes.
final class RpcRig {
  RpcRig._(
    this.writer,
    this.runtime,
    this.driver,
    this.provider,
    this.server,
    this._input,
  );

  /// The session writer.
  final SessionWriter writer;

  /// The tool runtime.
  final ToolRuntime runtime;

  /// The exchange driver.
  final ExchangeDriver driver;

  /// The scripted provider.
  final FakeProvider provider;

  /// The server under test.
  final RpcServer server;

  final StreamController<List<int>> _input;
  late final StreamSubscription<String> _lines;

  /// Every event the server wrote, decoded, in order.
  final List<Map<String, Object?>> events = [];

  /// The server's exit code, once it returned.
  late final Future<int> exit;

  final List<Completer<void>> _waiting = [];

  /// Writes [command] as one line.
  void send(Map<String, Object?> command) => sendRaw(jsonEncode(command));

  /// Writes [line] and a newline.
  void sendRaw(String line) => _input.add(utf8.encode('$line\n'));

  /// Writes raw [bytes].
  void sendBytes(List<int> bytes) => _input.add(bytes);

  /// Whether the server paused its reading of the input.
  bool get inputPaused => _input.isPaused;

  /// Stops reading the server's output, as a client that stalled.
  void stallOutput() => _lines.pause();

  /// Reads the server's output again.
  void resumeOutput() => _lines.resume();

  /// Ends the input, as a client that went away.
  Future<void> closeInput() => _input.close();

  /// The events of [type], in order.
  List<Map<String, Object?>> ofType(String type) => [
    for (final e in events)
      if (e['type'] == type) e,
  ];

  /// Waits for the first event at or after [from] that satisfies [test].
  Future<Map<String, Object?>> next(
    bool Function(Map<String, Object?> event) test, {
    int from = 0,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (true) {
      for (var i = from; i < events.length; i++) {
        if (test(events[i])) return events[i];
      }
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out waiting for an event; got:\n${events.join('\n')}');
      }
      final wake = Completer<void>();
      _waiting.add(wake);
      await wake.future.timeout(
        const Duration(milliseconds: 50),
        onTimeout: () {},
      );
    }
  }

  /// Waits for the first event of [type] at or after [from].
  Future<Map<String, Object?>> nextOfType(String type, {int from = 0}) =>
      next((e) => e['type'] == type, from: from);

  /// Waits for the `reply` or `error` answering [to].
  Future<Map<String, Object?>> answerTo(String to, {int from = 0}) => next(
    (e) => (e['type'] == 'reply' || e['type'] == 'error') && e['to'] == to,
    from: from,
  );

  /// Waits for the update that completes request [id].
  Future<Map<String, Object?>> requestSettled(String id) => next((e) {
    if (e['type'] != 'update') return false;
    final record = e['record'] as Map<String, Object?>;
    final value = record['value'];
    return record['path'] == 'meta/requests/$id' &&
        value is Map<String, Object?> &&
        value['state'] != null &&
        value['state'] != 'admitted';
  });

  /// Closes the input and waits for the server to return.
  Future<int> finish() async {
    resumeOutput();
    if (!_input.isClosed) unawaited(_input.close());
    return exit;
  }
}

/// Builds a server over a fresh session with [provider] and runs it.
Future<RpcRig> rpcRig(
  FakeProvider provider, {
  Map<String, Tool> tools = const {},
  CallStage? gate,
  bool kehaiHome = false,
  int seedTurn = 0,
  PumpLimits limits = const PumpLimits(),
  Directory? resumeSession,
}) async {
  final root = await tempDir();
  final ws = Directory(p.join(root.path, 'ws'))..createSync();
  final writer = resumeSession != null
      ? await SessionWriter.open(resumeSession)
      : await SessionWriter.create(Directory(p.join(root.path, 's')));
  for (var turn = 1; turn <= seedTurn; turn++) {
    await writer.apply(
      rec(turn, 'body/exchanges/x-seed$turn', Op.set, {'state': 'done'}),
    );
  }
  final answerer = RpcAnswerer();
  final home = Directory(p.join(root.path, 'home'))..createSync();
  final runtime = await ToolRuntime.attach(
    writer,
    ResultStore(writer.sessionDir),
    workspace: ws,
    tools: tools,
    gate: gate ?? (kehaiHome ? null : const AllowAllStage()),
    kehaiHome: kehaiHome ? home : null,
    answerer: answerer,
  );
  final driver = ExchangeDriver(
    writer: writer,
    runtime: runtime,
    provider: provider,
    model: 'gpt-5.5',
    clock: () => DateTime(2026, 10, 30, 9, 5),
  );
  final input = StreamController<List<int>>();
  final out = StreamController<List<int>>();
  final server = RpcServer(
    writer: writer,
    runtime: runtime,
    driver: driver,
    answerer: answerer,
    input: input.stream,
    output: IOSink(out),
    hello: HelloInfo(
      session: p.basename(writer.sessionDir.path),
      workspace: ws.path,
      model: 'gpt-5.5',
    ),
    limits: limits,
  );
  final rig = RpcRig._(writer, runtime, driver, provider, server, input);
  rig._lines = out.stream
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen((line) {
        rig.events.add(jsonDecode(line) as Map<String, Object?>);
        for (final wake in rig._waiting.toList()) {
          if (!wake.isCompleted) wake.complete();
        }
        rig._waiting.clear();
      });
  rig.exit = server.run();
  addTearDown(() async {
    await rig.finish();
    await runtime.close();
    await driver.close();
    await writer.close();
  });
  return rig;
}

/// A text-only step: `Hel`, `lo`, then end of turn.
List<ProviderEvent> textStep(List<String> deltas) => [
  for (final d in deltas) TextDelta(d),
  const Completed(StopReason.endTurn),
];

/// The tree a client holds after reading [events]: the last `snapshot` with
/// every later `update` at or after its offset applied.
///
/// Null before the first snapshot. A `resync` drops the mirror until the
/// snapshot that follows it.
SessionTree? mirrorOf(List<Map<String, Object?>> events) {
  SessionTree? mirror;
  var from = 0;
  for (final event in events) {
    switch (event['type']) {
      case 'resync':
        mirror = null;
      case 'snapshot':
        mirror = SessionTree.fromJson(event['tree']! as Map<Object?, Object?>);
        from = event['offset']! as int;
      case 'update':
        final offset = event['offset']! as int;
        final record = event['record']! as Map<String, Object?>;
        // A mirror holds no timeline to rewind; the resync that follows resets it.
        if (record['op'] == 'rewind') {
          mirror = null;
        } else if (mirror != null && offset >= from) {
          mirror.apply(
            JournalRecord(
              turn: record['turn']! as int,
              path: record['path']! as String,
              op: Op.fromWire(record['op']! as String)!,
              value: record['value'],
            ),
          );
        }
    }
  }
  return mirror;
}

/// Waits until the client mirror of [rig] equals the engine's tree.
Future<void> expectConverges(RpcRig rig) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (true) {
    final mirror = mirrorOf(rig.events);
    if (mirror != null &&
        equals(rig.writer.tree.toJson()).matches(mirror.toJson(), {})) {
      return;
    }
    if (DateTime.now().isAfter(deadline)) {
      fail('the client mirror never matched the engine tree');
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}
