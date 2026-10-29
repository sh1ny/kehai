/// The seams between the tool runtime and the tools it runs.
///
/// A [Tool] streams its whole output into [ToolContext.output] and returns a
/// [ToolOutcome]; it never cuts, samples or drops bytes, because only the
/// central composer decides what the model sees. The runtime runs the stages
/// of a call in a fixed order: validate, then [CallStage] hooks (change
/// group 11), then the permission [CallStage] (group 5), then the tool.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import '../config/user_config.dart';
import '../provider/provider.dart';
import '../results/composer.dart';

/// What a tool reports when it finishes.
///
/// The output itself went to [ToolContext.output]; the outcome only says how
/// the call ended.
final class ToolOutcome {
  /// Creates an outcome with the envelope [status] and a one-line [summary].
  ///
  /// A tool that stopped before it produced everything it should (a budget
  /// ran out, say) passes `complete: false`.
  const ToolOutcome({
    this.status = ResultStatus.ok,
    required this.summary,
    this.complete = true,
  });

  /// The envelope status of the call.
  final ResultStatus status;

  /// The summary shown in the envelope header.
  final String summary;

  /// Whether the stored output holds everything the tool meant to produce.
  final bool complete;
}

/// Where a tool streams its output.
///
/// Every [write] completes once the result store took the chunk, so a tool is
/// never ahead of the disk by more than the chunk in hand. After the call is
/// cancelled or its storage failed, [isClosed] is true and writes do nothing.
abstract interface class ToolOutput {
  /// Whether the output no longer accepts bytes.
  bool get isClosed;

  /// Stores [bytes] whole and completes once they were taken.
  Future<void> write(List<int> bytes);

  /// Stores [text] as UTF-8.
  Future<void> writeText(String text);
}

/// What the runtime gives a tool for one call.
final class ToolContext {
  /// Creates the context of the call keyed [callKey].
  ToolContext({
    required this.callKey,
    required this.callId,
    required this.output,
    required this.cancel,
    required this.workspace,
    required this.config,
  });

  /// The call's node key, `c-<12 hex>`.
  final String callKey;

  /// The provider's call id.
  final String callId;

  /// Where the tool streams its output.
  final ToolOutput output;

  /// Cancelled when the turn is cancelled or the output can no longer be
  /// stored. A tool that sees it stops its producer and returns.
  final CancelToken cancel;

  /// The workspace root.
  final Directory workspace;

  /// The user configuration read at attach.
  final UserConfig config;
}

/// One tool implementation.
abstract interface class Tool {
  /// Runs the call with the validated [input].
  ///
  /// It streams the whole output to `context.output` and returns how the call
  /// ended. Throwing settles the call `error` with the exception text.
  Future<ToolOutcome> run(ToolContext context, Map<String, Object?> input);
}

/// The call a [CallStage] looks at.
final class StageCall {
  /// Creates the description of a validated call.
  const StageCall({
    required this.tool,
    required this.callKey,
    required this.callId,
    required this.input,
  });

  /// The tool name.
  final String tool;

  /// The node key of the call.
  final String callKey;

  /// The provider's call id.
  final String callId;

  /// The validated arguments.
  final Map<String, Object?> input;
}

/// What a [CallStage] decided.
final class StageOutcome {
  /// The stage lets the call proceed.
  ///
  /// [record] is merged into the call node as `hooks` or `permission` before
  /// the call runs, and each of [diag] becomes a `[diag <source>] <text>` line.
  const StageOutcome.proceed({this.record, this.diag = const []})
    : denyReason = null;

  /// The stage refuses the call with [reason]; nothing runs and the call
  /// settles with envelope status `denied`.
  const StageOutcome.deny(
    String this.denyReason, {
    this.record,
    this.diag = const [],
  });

  /// The reason the call was refused, or `null` when it proceeds.
  final String? denyReason;

  /// What to record on the call node, or `null` for nothing.
  final Object? record;

  /// Diagnostic lines as `(source, text)`.
  final List<(String, String)> diag;
}

/// One step before a tool runs: the hook runner or the permission gate.
abstract interface class CallStage {
  /// Decides whether [call] proceeds. [cancel] fires when the turn is
  /// cancelled while the stage waits.
  Future<StageOutcome> check(StageCall call, CancelToken cancel);
}

/// The default stage until its group lands: every call proceeds.
final class AllowAllStage implements CallStage {
  /// Creates the stage.
  const AllowAllStage();

  @override
  Future<StageOutcome> check(StageCall call, CancelToken cancel) async =>
      const StageOutcome.proceed();
}

/// The runtime's end of a [ToolOutput]: a one-chunk-at-a-time rendezvous
/// with the result store.
final class OutputPipe implements ToolOutput {
  final Queue<_Chunk> _queue = Queue();
  _Chunk? _inFlight;
  Completer<void>? _wake;
  bool _closed = false;

  @override
  bool get isClosed => _closed;

  @override
  Future<void> write(List<int> bytes) {
    if (_closed || bytes.isEmpty) return Future.value();
    final chunk = _Chunk(bytes);
    _queue.add(chunk);
    _signal();
    return chunk.taken.future;
  }

  @override
  Future<void> writeText(String text) => write(utf8.encode(text));

  /// Stops accepting bytes. Chunks already accepted are still delivered to
  /// [chunks], which then ends.
  void close() {
    _closed = true;
    _signal();
  }

  /// The accepted chunks, in order, for the result store to consume.
  ///
  /// Each chunk's [write] completes when the store asks for the next one. If
  /// the store stops listening, the pipe closes and no write stays pending.
  Stream<List<int>> chunks() async* {
    try {
      while (true) {
        if (_queue.isEmpty) {
          if (_closed) return;
          final wake = _wake = Completer<void>();
          await wake.future;
          continue;
        }
        final chunk = _inFlight = _queue.removeFirst();
        yield chunk.bytes;
        _inFlight = null;
        chunk.taken.complete();
      }
    } finally {
      _closed = true;
      final inFlight = _inFlight;
      if (inFlight != null && !inFlight.taken.isCompleted) {
        inFlight.taken.complete();
      }
      for (final chunk in _queue) {
        chunk.taken.complete();
      }
      _queue.clear();
    }
  }

  void _signal() {
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }
}

final class _Chunk {
  _Chunk(this.bytes);

  final List<int> bytes;
  final Completer<void> taken = Completer<void>();
}
