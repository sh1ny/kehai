/// The RPC server over the exchange driver (design D11).
library;

import 'dart:async';
import 'dart:io';

import '../loop/driver.dart';
import '../session/errors.dart';
import '../session/path.dart';
import '../session/record.dart';
import '../session/writer.dart';
import '../tools/ask.dart';
import '../tools/runtime.dart';
import 'codec.dart';
import 'protocol.dart';
import 'pump.dart';

/// The facts `hello` reports.
final class HelloInfo {
  /// Creates the facts.
  const HelloInfo({
    required this.session,
    required this.workspace,
    required this.model,
    this.requests = 0,
    this.calls = 0,
    this.jobs = 0,
    this.exchanges = 0,
  });

  /// The session id.
  final String session;

  /// The canonical workspace path.
  final String workspace;

  /// The model slug.
  final String model;

  /// Requests recorded `interrupted` when the session opened.
  final int requests;

  /// Call nodes finalized when the session opened.
  final int calls;

  /// Job nodes finalized when the session opened.
  final int jobs;

  /// Exchanges finalized when the session opened.
  final int exchanges;
}

/// The [Answerer] that forwards prompts and withdrawals to the client.
///
/// The runtime is built with it before the server exists; the server binds it
/// to its output when it starts.
final class RpcAnswerer implements Answerer {
  void Function(Map<String, Object?> event)? _emit;

  /// Sends later prompts and withdrawals to [emit].
  void bind(void Function(Map<String, Object?> event) emit) => _emit = emit;

  @override
  void prompt(PromptItem item) =>
      _emit?.call({'type': 'prompt', 'item': item.toJson()});

  @override
  void withdraw(String key) => _emit?.call({'type': 'withdraw', 'key': key});
}

/// How long the server waits for a cancelled exchange to end at shutdown.
const Duration _shutdownWait = Duration(seconds: 10);

/// Serves one client over [input] and [output].
///
/// The server reads commands only after it sent `hello` and the first
/// `snapshot`, so a caller finalizes a resumed session first.
final class RpcServer {
  /// Creates a server.
  RpcServer({
    required this.writer,
    required this.runtime,
    required this.driver,
    required this.answerer,
    required this.input,
    required this.output,
    required this.hello,
    this.limits = const PumpLimits(),
  });

  /// The session writer.
  final SessionWriter writer;

  /// The tool runtime of the session.
  final ToolRuntime runtime;

  /// The exchange driver.
  final ExchangeDriver driver;

  /// The answerer the runtime was built with.
  final RpcAnswerer answerer;

  /// The client's commands.
  final Stream<List<int>> input;

  /// The client's events.
  final IOSink output;

  /// What `hello` reports.
  final HelloInfo hello;

  /// The output bounds.
  final PumpLimits limits;

  /// The reliable bytes waiting to be written.
  int get pendingReliableBytes => _pump.reliableBytes;

  late final OutputPump _pump = OutputPump(
    output,
    limits: limits,
    resync: _resyncEvents,
    onRelief: _syncReading,
  );
  final Completer<int> _end = Completer<int>();
  StreamSubscription<CommittedUpdate>? _updates;
  StreamSubscription<LineEvent>? _commands;
  Future<void> _running = Future.value();
  bool _handling = false;
  bool _readPaused = false;

  /// Serves until the input ends or a fatal error; returns the exit code.
  ///
  /// On end of input the running exchange and every live call are cancelled
  /// (the calls with reason `shutdown`) and awaited, and the pump is flushed.
  /// Closing the runtime, the driver and the writer is the caller's, who owns
  /// them. After a `fatal` line the code is 1.
  Future<int> run() async {
    answerer.bind(_pump.send);
    _pump.send(
      helloEvent(
        session: hello.session,
        workspace: hello.workspace,
        model: hello.model,
        requests: hello.requests,
        calls: hello.calls,
        jobs: hello.jobs,
        exchanges: hello.exchanges,
      ),
    );
    final deltas = driver.deltas.listen(
      (d) => _pump.send(streamEvent(d.turn, d.kind, d.delta), droppable: true),
    );
    _subscribe();
    _sendSnapshot();

    final commands = _commands = readLines(input).listen(null);
    commands
      ..onData((event) {
        _handling = true;
        _syncReading();
        _handle(event).whenComplete(() {
          _handling = false;
          _syncReading();
        });
      })
      ..onError((Object _) => _finish(0))
      ..onDone(() => _finish(0));
    final code = await _end.future;

    await commands.cancel();
    await deltas.cancel();
    await _updates?.cancel();
    // The reasons are set before the exchange token cancels, which would
    // otherwise record its calls as cancelled by the user.
    final calls = runtime.cancelForShutdown();
    driver.cancelForShutdown();
    await calls;
    await _running.timeout(_shutdownWait, onTimeout: () {});
    answerer.bind((_) {});
    await _pump.flush();
    return code;
  }

  /// Reads commands only while none is being handled and the replies are not
  /// backed up past the reliable limit, so a stalled client's writes block.
  void _syncReading() {
    final commands = _commands;
    if (commands == null || _end.isCompleted) return;
    final wantPaused = _handling || _pump.saturated;
    if (wantPaused == _readPaused) return;
    _readPaused = wantPaused;
    if (wantPaused) {
      commands.pause();
    } else {
      commands.resume();
    }
  }

  void _finish(int code) {
    if (!_end.isCompleted) _end.complete(code);
  }

  void _fatal(String message) {
    if (_end.isCompleted) return;
    _pump.send(fatalEvent(message));
    _finish(1);
  }

  /// Subscribes to committed updates and takes the snapshot in one step, so no
  /// commit falls between them.
  void _subscribe() {
    _updates = writer.subscribe().listen(_onUpdate, onError: _onUpdateError);
  }

  void _sendSnapshot() => _pump.send(
    snapshotEvent(
      offset: writer.committedLength,
      turn: writer.currentTurn,
      tree: writer.tree.toJson(),
    ),
  );

  /// The events the pump writes for a pending resync: the client drops its
  /// mirror and starts again from this snapshot.
  ///
  /// The updates are resubscribed before the tree is read, in one step, so
  /// none falls between them; those committed since the resync was requested
  /// are in the snapshot and were not queued.
  List<Map<String, Object?>> _resyncEvents() {
    unawaited(_updates?.cancel());
    if (!_end.isCompleted) _subscribe();
    return [
      const {'type': 'resync'},
      snapshotEvent(
        offset: writer.committedLength,
        turn: writer.currentTurn,
        tree: writer.tree.toJson(),
      ),
    ];
  }

  void _onUpdate(CommittedUpdate update) {
    final record = update.record;
    _pump.send(
      updateEvent(update.offset, {
        'turn': record.turn,
        'path': record.path,
        'op': record.op.wire,
        'value': record.value,
      }),
      droppable: true,
    );
    // A client mirror holds no timeline to fold a rewind into; the resync
    // follows the update, which stays queued.
    if (record.op == Op.rewind) _pump.requestResync(keepQueued: true);
  }

  void _onUpdateError(Object error) {
    if (error is ResyncRequired) _pump.requestResync();
  }

  Future<void> _handle(LineEvent event) async {
    try {
      switch (event) {
        case OverlongLine():
          _pump.send(errorEvent('line too long (limit 1 MiB)'));
        case MalformedLine():
          _pump.send(errorEvent('invalid UTF-8'));
        case InputLine(:final text):
          final Command command;
          try {
            command = parseCommand(text);
          } on ProtocolError catch (e) {
            _pump.send(errorEvent(e.message, to: e.to));
            return;
          }
          await _dispatch(command);
      }
    } on StorageError catch (e) {
      _fatal('storage failure: ${e.message}');
    } on SessionError catch (e) {
      _pump.send(errorEvent(e.message));
    } on Object catch (e) {
      _pump.send(errorEvent('internal error: ${e.runtimeType}'));
    }
  }

  Future<void> _dispatch(Command command) async {
    switch (command) {
      case SubmitCommand():
        await _submit(command);
      case InterruptCommand():
        unawaited(_interrupt());
      case AnswerCommand(:final key, :final text):
        final refusal = runtime.prompts.reply(key, text);
        _pump.send(
          refusal == null
              ? replyEvent('answer', {'key': key})
              : errorEvent(refusal, to: 'answer'),
        );
      case StatusCommand(:final id):
        _status(id);
    }
  }

  Future<void> _submit(SubmitCommand command) async {
    final id = command.id;
    final outcome = await driver.submit(
      id: id,
      text: command.text,
      turn: command.turn,
    );
    switch (outcome) {
      case SubmitAdmitted(:final exchange, :final done):
        _pump.send(replyEvent(id, {'state': 'admitted', 'exchange': exchange}));
        _running = done.then<void>((_) {}, onError: _exchangeFailed);
      case SubmitDuplicate(:final state, :final node):
        _pump.send(replyEvent(id, _recorded(state, node)));
      case SubmitCollision():
        _pump.send(errorEvent('request id collision', to: id));
      case SubmitStale(:final turn):
        _pump.send(errorEvent('stale: session is at turn $turn', to: id));
      case SubmitBusy():
        _pump.send(errorEvent('busy: an exchange is running', to: id));
    }
  }

  void _exchangeFailed(Object error) {
    if (error is StorageError) {
      _fatal('storage failure: ${error.message}');
    } else {
      _pump.send(errorEvent('exchange failed: ${error.runtimeType}'));
    }
  }

  Future<void> _interrupt() async {
    final bool running;
    try {
      running = await driver.interrupt();
    } on StorageError catch (e) {
      _fatal('storage failure: ${e.message}');
      return;
    } on Object catch (e) {
      _pump.send(errorEvent('interrupt failed: ${e.runtimeType}'));
      return;
    }
    _pump.send(replyEvent('interrupt', {'running': running}));
  }

  void _status(String id) {
    final node = writer.tree.get(SessionPath.parse('meta/requests/$id'));
    if (node is! Map<String, Object?>) {
      _pump.send(replyEvent(id, {'state': 'not-admitted'}));
      return;
    }
    _pump.send(replyEvent(id, _recorded(node['state']! as String, node)));
  }
}

/// The reply fields for a recorded request: its state and any outcome or
/// reason.
Map<String, Object?> _recorded(String state, Map<String, Object?> node) => {
  'state': state,
  'outcome': ?node['outcome'],
  'reason': ?node['reason'],
};
