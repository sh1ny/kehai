/// The exchange driver: one running exchange, its steps and their tool calls
/// (design D2, D5, D9, D10, D17).
library;

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../config/user_config.dart';
import '../provider/provider.dart';
import '../session/path.dart';
import '../session/record.dart';
import '../session/requests.dart';
import '../session/writer.dart';
import '../tools/runtime.dart';
import 'instructions.dart';
import 'request_builder.dart';
import 'retry.dart';
import 'sensorium.dart';

/// The most steps one exchange runs (design D10).
const int maxSteps = 200;

/// The step failure reason when a response passed the provider's output limit.
const String stepOutputLimitReason = 'step output limit (4 MiB)';

const String _outputLimitCode = 'response_output_limit';

/// The context window of [model]: the user configuration's override, else the
/// window the backend lists, else null (design D9).
int? resolveContextWindow(
  UserConfig config,
  String model,
  List<ModelInfo> models,
) =>
    config.contextWindows[model] ??
    models.where((m) => m.id == model).firstOrNull?.contextWindow;

/// A fragment of the streaming response, for display only.
///
/// What the step commits is its `output`; these are never recorded.
final class StreamDelta {
  /// Creates a delta of the step at journal [turn]; [kind] is `text` or
  /// `reasoning`.
  const StreamDelta(this.turn, this.kind, this.delta);

  /// The journal turn of the step.
  final int turn;

  /// `text` or `reasoning`.
  final String kind;

  /// The fragment.
  final String delta;
}

/// How an exchange ended.
final class ExchangeResult {
  /// Creates a result for the exchange node [exchange].
  const ExchangeResult(this.exchange, this.state, [this.reason]);

  /// The exchange node key, such as `x-00000001`.
  final String exchange;

  /// `done`, `cancelled`, `stopped` or `failed`.
  final String state;

  /// Why it did not end `done`, or null.
  final String? reason;
}

/// What [ExchangeDriver.submit] decided.
sealed class SubmitOutcome {
  const SubmitOutcome();
}

/// The prompt was admitted and its exchange is running.
final class SubmitAdmitted extends SubmitOutcome {
  /// Creates the outcome; [done] completes when the exchange has ended.
  ///
  /// [done] fails with the writer's `StorageError` when the journal broke.
  const SubmitAdmitted(this.exchange, this.done);

  /// The exchange node key.
  final String exchange;

  /// Completes with the end of the exchange.
  final Future<ExchangeResult> done;
}

/// The request id was admitted before with the same content; nothing runs.
final class SubmitDuplicate extends SubmitOutcome {
  /// Creates the outcome from the recorded request node.
  const SubmitDuplicate(this.state, this.node);

  /// The recorded state of the request.
  final String state;

  /// The recorded request node.
  final Map<String, Object?> node;
}

/// The request id was admitted before with different content.
final class SubmitCollision extends SubmitOutcome {
  /// Creates the outcome for [id].
  const SubmitCollision(this.id);

  /// The colliding id.
  final String id;
}

/// The client's journal turn is not the session's.
final class SubmitStale extends SubmitOutcome {
  /// Creates the outcome; [turn] is the session's current turn.
  const SubmitStale(this.turn);

  /// The session's current journal turn.
  final int turn;
}

/// Another exchange is running; nothing was recorded.
final class SubmitBusy extends SubmitOutcome {
  /// Creates the outcome.
  const SubmitBusy();
}

/// Pause points that make races deterministic in tests.
final class DriverSeams {
  /// Creates seams; every callback is optional.
  const DriverSeams({this.beforeStepCommit, this.afterStepCommit, this.sleep});

  /// Runs with the step's turn before its completion record is written.
  final Future<void> Function(int turn)? beforeStepCommit;

  /// Runs with the step's turn after its completion record was written and
  /// before its calls are submitted.
  final Future<void> Function(int turn)? afterStepCommit;

  /// Waits [delay] before a retry; a test substitutes a fake clock. The wait
  /// still ends at once on interrupt.
  final Future<void> Function(Duration delay)? sleep;
}

/// Drives the exchanges of one session, one at a time.
///
/// Every writer operation of the driver passes the runtime's [WriteGate]
/// (design D17).
final class ExchangeDriver {
  /// Creates a driver for [writer] and [runtime] that sends requests for
  /// [model] to [provider].
  ///
  /// [contextWindow] is the model's window or null when unknown.
  ExchangeDriver({
    required this.writer,
    required this.runtime,
    required this.provider,
    required this.model,
    this.contextWindow,
    DateTime Function()? clock,
    this.retryPolicy = const BoundedRetry(),
    this.seams = const DriverSeams(),
  }) : _builder = RequestBuilder(
         sessionDir: writer.sessionDir,
         model: model,
         workspaceName: p.basename(runtime.workspace.path),
         tools: runtime.specs,
         estimateRequest: (request) => provider.estimate(request).tokens,
         window: contextWindow,
         clock: clock ?? DateTime.now,
       );

  /// The session writer.
  final SessionWriter writer;

  /// The tool runtime of the same session.
  final ToolRuntime runtime;

  /// The model provider.
  final ModelProvider provider;

  /// The model slug sent in requests.
  final String model;

  /// The context window in tokens, or null when unknown.
  final int? contextWindow;

  /// Decides whether a failed request is sent again.
  final RetryPolicy retryPolicy;

  /// Test pause points.
  final DriverSeams seams;

  final RequestBuilder _builder;
  final StreamController<StreamDelta> _deltas = StreamController.broadcast(
    sync: true,
  );
  bool _busy = false;

  /// The running exchange's cancel token, or null when idle.
  CancelToken? _token;

  /// The ephemeral stream deltas of the running step.
  Stream<StreamDelta> get deltas => _deltas.stream;

  /// Whether an exchange is running.
  bool get busy => _busy;

  /// The running exchange's cancel token, or null when idle.
  CancelToken? get exchangeToken => _token;

  /// The reason a cancelled exchange records: `user` unless shut down.
  String _cancelReason = 'user';

  /// Interrupts the running exchange; returns whether one was running.
  ///
  /// It cancels the exchange token, which aborts the provider stream and any
  /// retry wait and links every call admitted from now on, then cancels the
  /// calls live at this moment and awaits them. The exchange records its own
  /// end. Background jobs are untouched; idle, nothing is recorded.
  Future<bool> interrupt() async {
    final token = _token;
    if (token == null) return false;
    token.cancel();
    await runtime.cancelTurn();
    return true;
  }

  /// Cancels the running exchange for engine shutdown, so its step and end
  /// carry reason `shutdown`. The caller cancels the live calls itself.
  void cancelForShutdown() {
    _cancelReason = 'shutdown';
    _token?.cancel();
  }

  /// Records every step and exchange a dead engine left `running` as
  /// `cancelled` with reason `interrupted`, one `merge` each, and returns how
  /// many exchanges it finalized (design D5).
  ///
  /// Nothing is sent to the provider and no call is run again; the calls and
  /// jobs of the dead engine were finalized by `ToolRuntime.attach`. A session
  /// whose exchanges all ended records nothing. Call it before the first
  /// `submit`.
  Future<int> finalizeUnfinished() async {
    for (final key in _runningKeys('body/steps')) {
      await _apply(
        JournalRecord(
          turn: writer.currentTurn,
          path: 'body/steps/$key',
          op: Op.merge,
          value: _interrupted,
        ),
      );
    }
    final exchanges = _runningKeys('body/exchanges');
    for (final key in exchanges) {
      await _apply(
        JournalRecord(
          turn: writer.currentTurn,
          path: 'body/exchanges/$key',
          op: Op.merge,
          value: {..._interrupted, 'last': writer.currentTurn},
        ),
      );
    }
    return exchanges.length;
  }

  /// The keys under [path] whose nodes are `running`, in key order.
  List<String> _runningKeys(String path) {
    final nodes = writer.tree.get(SessionPath.parse(path));
    if (nodes is! Map<String, Object?>) return const [];
    return [
      for (final key in nodes.keys.toList()..sort())
        if (nodes[key] case {'state': 'running'}) key,
    ];
  }

  /// Closes the delta stream.
  Future<void> close() => _deltas.close();

  /// Submits the prompt [text] as request [id], typed against journal [turn].
  ///
  /// A known id answers with its recorded state or a collision whatever the
  /// turn. Otherwise a running exchange refuses with [SubmitBusy], a turn other
  /// than the session's with [SubmitStale], and nothing is recorded. The
  /// fingerprint covers the id and the text, not the turn, so a resend after
  /// the client saw a newer turn is still the same request.
  Future<SubmitOutcome> submit({
    required String id,
    required String text,
    required int turn,
  }) async {
    final fingerprint = sha256
        .convert(
          utf8.encode(jsonEncode({'id': id, 'text': text, 'type': 'submit'})),
        )
        .toString();
    final known =
        writer.tree.get(SessionPath.parse('meta/requests/$id')) != null;
    if (!known) {
      if (_busy) return const SubmitBusy();
      final current = writer.currentTurn;
      if (turn != current) return SubmitStale(current);
      _busy = true;
    }
    final Admission admission;
    try {
      admission = await _gated(() => writer.admit(id, fingerprint));
    } on RequestCollision {
      return SubmitCollision(id);
    } on Object {
      if (!known) _busy = false;
      rethrow;
    }
    if (!admission.isNew) {
      if (!known) _busy = false;
      return SubmitDuplicate(admission.state, admission.node ?? const {});
    }
    final first = writer.currentTurn + 1;
    final done = _exchange(id, text, first).whenComplete(() {
      _busy = false;
      _token = null;
    });
    done.ignore();
    return SubmitAdmitted(_exchangeKey(first), done);
  }

  Future<ExchangeResult> _exchange(
    String requestId,
    String prompt,
    int first,
  ) async {
    final key = _exchangeKey(first);
    final token = _token = CancelToken();
    _cancelReason = 'user';
    await _apply(
      JournalRecord(
        turn: first,
        path: 'body/exchanges/$key',
        op: Op.set,
        value: {
          'request': requestId,
          'prompt': prompt,
          'state': 'running',
          'first': first,
        },
      ),
    );
    var turn = first;
    _End end;
    for (var steps = 1; ; steps++) {
      final outcome = await _step(turn, key, token);
      if (outcome is _End) {
        end = outcome;
        break;
      }
      if (token.isCancelled) {
        end = _End('cancelled', _cancelReason);
        break;
      }
      if (steps >= maxSteps) {
        end = const _End('stopped', 'step limit ($maxSteps)');
        break;
      }
      turn = writer.currentTurn + 1;
    }
    await _apply(
      JournalRecord(
        turn: writer.currentTurn,
        path: 'body/exchanges/$key',
        op: Op.merge,
        value: {
          'state': end.state,
          'reason': ?end.reason,
          'last': writer.currentTurn,
        },
      ),
    );
    await _gated(
      () => writer.complete(requestId, {'exchange': key, 'state': end.state}),
    );
    return ExchangeResult(key, end.state, end.reason);
  }

  /// Runs one step; returns [_End] when the exchange ends with it, else
  /// [_Continue] after its calls are all terminal.
  Future<_StepOutcome> _step(
    int turn,
    String exchange,
    CancelToken token,
  ) async {
    await _apply(
      JournalRecord(
        turn: turn,
        path: _stepPath(turn),
        op: Op.set,
        value: {
          'exchange': exchange,
          'model': model,
          'instructions': instructionsVersion,
          'state': 'running',
          'attempts': 0,
        },
      ),
    );
    final built = await _builder.build(writer.tree, turn: turn);
    final context = {
      'used': built.used,
      'window': ?contextWindow,
      'block': built.block,
      'estimated': true,
    };
    if (built.overflow) {
      final message = _overflowMessage(built.used);
      await _mergeStep(turn, {
        'state': 'failed',
        'reason': message,
        'context': context,
      });
      return _End('stopped', message);
    }

    var attempts = 0;
    _Streamed streamed;
    while (true) {
      attempts++;
      streamed = await _stream(built.request, turn, token);
      final failure = streamed.failure;
      if (failure == null || failure.kind == ProviderFailureKind.cancelled) {
        break;
      }
      final delay = retryPolicy.delayFor(failure, attempts);
      if (delay == null) break;
      await _wait(delay, token);
      if (token.isCancelled) break;
    }

    final parts = streamed.ordered();
    final partial = parts.whereType<_TextPart>().map((t) => '${t.text}').join();
    final failure = streamed.failure;
    // The token is authoritative: a stream that ended or even completed after
    // the interrupt is a cancelled step, without a provider failure to say so.
    final cancelled =
        token.isCancelled || failure?.kind == ProviderFailureKind.cancelled;
    if (cancelled || failure != null) {
      final String state;
      final String reason;
      final _End end;
      if (cancelled) {
        state = 'cancelled';
        reason = _cancelReason;
        end = _End('cancelled', _cancelReason);
      } else if (failure!.kind == ProviderFailureKind.contextOverflow) {
        state = 'failed';
        reason = 'context overflow';
        end = _End('stopped', _overflowMessage(built.used));
      } else if (failure.kind == ProviderFailureKind.protocol &&
          failure.code == _outputLimitCode) {
        state = 'failed';
        reason = stepOutputLimitReason;
        end = const _End('failed', stepOutputLimitReason);
      } else {
        state = 'failed';
        reason = _failureReason(failure, attempts);
        end = _End('failed', reason);
      }
      await _mergeStep(turn, {
        'state': state,
        'reason': reason,
        'attempts': attempts,
        if (failure != null)
          'failure': {
            'kind': failure.kind.wire,
            'message': failure.message,
            'status': ?failure.status,
            'code': ?failure.code,
            'sent': failure.sent,
          },
        if (partial.isNotEmpty) 'partial': partial,
        'context': context,
      });
      return end;
    }

    await seams.beforeStepCommit?.call(turn);
    await _mergeStep(turn, {
      'state': 'completed',
      'stop': streamed.stop!.wire,
      'attempts': attempts,
      if (streamed.usage case final usage?) 'usage': _usageJson(usage),
      'context': context,
      'output': [for (final part in parts) ?_outputEntry(part)],
    });
    await seams.afterStepCommit?.call(turn);

    final calls = [
      for (final part in parts.whereType<_CallPart>())
        ToolCall(
          callId: part.callId,
          name: part.name,
          argumentsJson: part.arguments,
        ),
    ];
    if (calls.isEmpty) return const _End('done', null);

    // Every call is submitted before any is awaited, so the runtime's own
    // bounds decide what runs, queues or is refused busy.
    final errors = await Future.wait([
      for (final call in calls) _runCall(call, token),
    ]);
    for (final error in errors) {
      if (error is StorageError) throw error;
    }
    final broken = errors.nonNulls.firstOrNull;
    if (broken != null) return _End('failed', 'tool runtime error: $broken');
    return const _Continue();
  }

  Future<Object?> _runCall(ToolCall call, CancelToken token) async {
    try {
      await runtime.run(call, cancel: token);
      return null;
    } on Object catch (e) {
      return e;
    }
  }

  Future<_Streamed> _stream(
    ModelRequest request,
    int turn,
    CancelToken token,
  ) async {
    final streamed = _Streamed();
    try {
      await for (final event in provider.stream(request, cancel: token)) {
        switch (event) {
          case TextDelta(:final text, :final outputIndex):
            streamed.addText(text, outputIndex);
            _deltas.add(StreamDelta(turn, 'text', text));
          case ReasoningSummaryDelta(:final text):
            _deltas.add(StreamDelta(turn, 'reasoning', text));
          case OpaqueItem(:final json, :final outputIndex):
            streamed.add(_ReasoningPart(json, outputIndex));
          case ToolCall(
            :final callId,
            :final name,
            :final argumentsJson,
            :final outputIndex,
          ):
            streamed.add(_CallPart(callId, name, argumentsJson, outputIndex));
          case Usage():
            streamed.usage = event;
          case Completed(:final stop):
            streamed.stop = stop;
          case Failed(:final failure):
            streamed.failure = failure;
        }
      }
    } on Object catch (e) {
      streamed.failure ??= ProviderFailure(
        kind: ProviderFailureKind.modelRequest,
        message: 'the model stream failed: $e',
      );
    }
    if (streamed.stop == null && streamed.failure == null) {
      streamed.failure = ProviderFailure(
        kind: ProviderFailureKind.protocol,
        message: 'the model stream ended without a result',
      );
    }
    return streamed;
  }

  /// Waits [delay], or until [token] is cancelled.
  Future<void> _wait(Duration delay, CancelToken token) {
    final custom = seams.sleep;
    if (custom != null) {
      return Future.any<void>([custom(delay), token.whenCancelled]);
    }
    final done = Completer<void>();
    final timer = Timer(delay, done.complete);
    final detach = token.listen(() {
      timer.cancel();
      if (!done.isCompleted) done.complete();
    });
    return done.future.whenComplete(detach);
  }

  String _failureReason(ProviderFailure failure, int attempts) {
    final base = attempts > 1
        ? 'model request failed after $attempts attempts: ${failure.message}'
        : 'model request failed: ${failure.message}';
    final asked = failure.retryAfter;
    return asked != null && asked > maxRetryAfter
        ? '$base; the server asked to wait ${asked.inSeconds} s'
        : base;
  }

  String _overflowMessage(int used) {
    final window = contextWindow;
    final size = window == null
        ? '~${formatTokens(used)} tokens in use'
        : '~${formatTokens(used)} of ${formatTokens(window)} tokens';
    return 'context overflow: $size; rewind or start a new session';
  }

  Future<void> _mergeStep(int turn, Map<String, Object?> fields) => _apply(
    JournalRecord(
      turn: turn,
      path: _stepPath(turn),
      op: Op.merge,
      value: fields,
    ),
  );

  Future<CommittedUpdate> _apply(JournalRecord record) =>
      _gated(() => writer.apply(record));

  Future<T> _gated<T>(Future<T> Function() operation) =>
      runtime.writeGate.run(operation);
}

const Map<String, Object?> _interrupted = {
  'state': 'cancelled',
  'reason': 'interrupted',
};

String _exchangeKey(int turn) => 'x-${turn.toString().padLeft(8, '0')}';

String _stepPath(int turn) => 'body/steps/s-${turn.toString().padLeft(8, '0')}';

Map<String, Object?> _usageJson(Usage usage) => {
  'input': ?usage.input,
  'cachedInput': ?usage.cachedInput,
  'output': ?usage.output,
  'reasoning': ?usage.reasoning,
};

Map<String, Object?>? _outputEntry(_Part part) => switch (part) {
  _TextPart(:final text) when text.isEmpty => null,
  _TextPart(:final text) => {'type': 'text', 'text': '$text'},
  _ReasoningPart(:final json) => {'type': 'reasoning', 'item': json},
  _CallPart(:final callId, :final name, :final arguments) => {
    'type': 'call',
    'call': callKey(callId),
    'callId': callId,
    'name': name,
    'arguments': arguments,
  },
};

/// What a step led to.
sealed class _StepOutcome {
  const _StepOutcome();
}

/// The exchange ends with this step.
final class _End extends _StepOutcome {
  const _End(this.state, this.reason);

  final String state;
  final String? reason;
}

/// The step's calls are all terminal and the exchange goes on.
final class _Continue extends _StepOutcome {
  const _Continue();
}

/// One part of a streamed response, in arrival order.
sealed class _Part {
  _Part(this.index);

  /// The backend's output index, or null when it sent none.
  final int? index;

  /// The arrival sequence, set by [_Streamed.add].
  int seq = 0;
}

final class _TextPart extends _Part {
  _TextPart(super.index);

  final StringBuffer text = StringBuffer();
}

final class _ReasoningPart extends _Part {
  _ReasoningPart(this.json, super.index);

  final Map<String, Object?> json;
}

final class _CallPart extends _Part {
  _CallPart(this.callId, this.name, this.arguments, super.index);

  final String callId;
  final String name;
  final String arguments;
}

/// What one response streamed.
final class _Streamed {
  final List<_Part> _parts = [];
  Usage? usage;
  StopReason? stop;
  ProviderFailure? failure;

  void add(_Part part) {
    part.seq = _parts.length;
    _parts.add(part);
  }

  /// Appends [text] to the text part of [index], or to the last unindexed text
  /// part, or starts a new one.
  void addText(String text, int? index) {
    _TextPart? target;
    if (index != null) {
      target = _parts
          .whereType<_TextPart>()
          .where((t) => t.index == index)
          .lastOrNull;
    } else if (_parts.lastOrNull case _TextPart(index: null) && final last) {
      target = last;
    }
    if (target == null) {
      target = _TextPart(index);
      add(target);
    }
    target.text.write(text);
  }

  /// The parts by output index, then the unindexed ones in arrival order.
  List<_Part> ordered() {
    final indexed = _parts.where((part) => part.index != null).toList()
      ..sort((a, b) {
        final byIndex = a.index!.compareTo(b.index!);
        return byIndex != 0 ? byIndex : a.seq.compareTo(b.seq);
      });
    return [...indexed, ..._parts.where((part) => part.index == null)];
  }
}
