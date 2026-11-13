/// The exchange driver: one running exchange, its steps and their tool calls
/// (design D2, D5, D9, D10, D17).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../config/user_config.dart';
import '../provider/provider.dart';
import '../provider/chatgpt_request.dart';
import '../session/path.dart';
import '../session/record.dart';
import '../session/requests.dart';
import '../session/writer.dart';
import '../session/tree.dart';
import '../tools/runtime.dart';
import '../workspace/inventory.dart';
import '../workspace/load.dart';
import 'compaction_state.dart';
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

/// The prompt was refused before admission; nothing was recorded.
final class SubmitRefused extends SubmitOutcome {
  /// Creates the outcome with the user-facing [message].
  const SubmitRefused(this.message);

  /// Why the prompt was refused, such as `unknown command /x; start with //
  /// to send it as text`.
  final String message;
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
  /// [contextWindow] is backend metadata; ChatGPT-account capacity is resolved
  /// separately from route-qualified configuration.
  /// [onRequestCaptured] is an optional test barrier after request capture.
  ExchangeDriver({
    required this.writer,
    required this.runtime,
    required this.provider,
    required this.model,
    int? contextWindow,
    DateTime Function()? clock,
    Future<void> Function()? onRequestCaptured,
    this.retryPolicy = const BoundedRetry(),
    this.seams = const DriverSeams(),
    this.childRole,
    this.effort,
  }) : capacity = runtime.config.resolveCapacity(
         provider.id,
         'chatgpt-account',
         model,
         backendContextWindow: contextWindow,
       ),
       contextWindow = runtime.config
           .resolveCapacity(
             provider.id,
             'chatgpt-account',
             model,
             backendContextWindow: contextWindow,
           )
           .contextWindow,
       _builder = RequestBuilder(
         sessionDir: writer.sessionDir,
         model: model,
         effort: effort,
         providerId: provider.id,
         nativeCompaction:
             runtime.config
                     .effectiveCompaction(provider.id, 'chatgpt-account', model)
                     .strategy ==
                 CompactionStrategy.providerNative
             ? NativeCompactionPolicy(
                 threshold: runtime.config
                     .effectiveCompaction(provider.id, 'chatgpt-account', model)
                     .threshold,
               )
             : null,
         workspaceName: p.basename(runtime.workspace.path),
         tools: runtime.specs,
         estimateRequest: (request) => provider.estimate(request).tokens,
         window: runtime.config
             .resolveCapacity(
               provider.id,
               'chatgpt-account',
               model,
               backendContextWindow: contextWindow,
             )
             .contextWindow,
         windowEstimated:
             runtime.config
                 .resolveCapacity(
                   provider.id,
                   'chatgpt-account',
                   model,
                   backendContextWindow: contextWindow,
                 )
                 .source ==
             'user-configured estimate',
         sensoriumMaxTokens: runtime.config.sensorium.maxTokens,
         compactionThreshold: runtime.config
             .effectiveCompaction(provider.id, 'chatgpt-account', model)
             .threshold,
         legacyWindowIgnored:
             runtime.config
                 .resolveCapacity(
                   provider.id,
                   'chatgpt-account',
                   model,
                   backendContextWindow: contextWindow,
                 )
                 .migrationNotice !=
             null,
         clock: clock ?? DateTime.now,
         onCaptured: onRequestCaptured,
       );

  /// The session writer.
  final SessionWriter writer;

  /// The tool runtime of the same session.
  final ToolRuntime runtime;

  /// The model provider.
  final ModelProvider provider;

  /// The model slug sent in requests.
  final String model;

  /// The selected reasoning effort, or null for provider default.
  final String? effort;

  /// The context window in tokens, or null when unknown.
  final int? contextWindow;

  /// The effective route capacity and its distinct raw metadata/provenance.
  final RouteCapacity capacity;

  /// Decides whether a failed request is sent again.
  final RetryPolicy retryPolicy;

  /// Test pause points.
  final DriverSeams seams;

  /// The role of a child engine, captured in the tree with each exchange's
  /// context (design D4, D8), or null outside a child.
  final ChildRole? childRole;

  final RequestBuilder _builder;
  final StreamController<StreamDelta> _deltas = StreamController.broadcast(
    sync: true,
  );
  bool _busy = false;

  /// The context key of the running exchange, or null when idle.
  String? _contextKey;

  /// The running exchange's cancel token, or null when idle.
  CancelToken? _token;

  /// The ephemeral stream deltas of the running step.
  Stream<StreamDelta> get deltas => _deltas.stream;

  /// Whether an exchange is running.
  bool get busy => _busy;

  /// The running exchange's cancel token, or null when idle.
  CancelToken? get exchangeToken => _token;

  /// Reconstructs scalar status from a committed snapshot and current inputs.
  ///
  /// This neither appends journal state nor makes provider requests. Opaque
  /// contents and raw server errors are never included in this projection.
  Future<Map<String, Object?>> compactionStatus(
    SessionTree tree,
    int turn,
  ) async {
    final (contextKey, value) = _contextSnapshot();
    tree = SessionTree.fromJson(tree.toJson());
    tree.apply(
      JournalRecord(
        turn: turn,
        path: 'body/contexts/$contextKey',
        op: Op.set,
        value: value,
      ),
    );
    final lineage = _builder.requestLineage(tree, contextKey: contextKey);
    final policy = runtime.config.effectiveCompaction(
      provider.id,
      'chatgpt-account',
      model,
    );
    final boundary = _builder.selectedBoundary(tree);
    final evidence = CompactionState.fold(tree, lineage, policy, boundary);
    final native = policy.strategy == CompactionStrategy.providerNative;
    BuiltRequest? built;
    var continuity = 'compatible';
    Map<String, Object?> perception = {'state': 'available'};
    try {
      built = await _builder.build(
        tree,
        turn: turn,
        contextKey: contextKey,
        sourceOffset: writer.committedLength,
      );
    } on SensoriumCompositionError catch (error) {
      // Scratch validation can fail before the boundary lineage is checked.
      if (error.code == 'scratch_state') continuity = 'unknown';
      perception = {
        'state': 'unavailable',
        'code': error.code,
        'message': error.message,
      };
    } on StateError catch (e) {
      // Do not expose arbitrary exception text from history or result files.
      continuity = e.message.startsWith('incompatible continuity')
          ? 'incompatible continuity'
          : 'projection unavailable; reopen to recover or start a new session';
      perception = {'state': 'unavailable'};
    }
    final calibration = native && boundary != null && built?.used == null;
    return {
      'provider': provider.id,
      'route': 'chatgpt-account',
      'model': model,
      'instructions': lineage['instructions'],
      'tools': lineage['tools'],
      'strategy': policy.strategy.wireName,
      'threshold': policy.threshold,
      'strategySource': policy.strategySource,
      'thresholdSource': policy.thresholdSource,
      'capability': native ? evidence.state : 'disabled',
      'capabilityReason': native
          ? evidence.reason
          : 'native compaction disabled',
      'boundary': boundary,
      'continuity': continuity,
      'window': capacity.contextWindow,
      'windowSource': capacity.source,
      'windowConfigPath': capacity.configPath,
      'backendWindow': capacity.backendContextWindow,
      'legacyWindowHint': capacity.legacyHint,
      'migrationNotice': capacity.migrationNotice,
      'used': built?.used,
      'perception': perception,
      'budgetQuality':
          built?.quality ??
          (perception['code'] != null
              ? 'unknown; perception blocked'
              : 'unknown; continuity blocked'),
      'retained': built?.retained,
      'calibration': !native
          ? 'disabled'
          : perception['state'] != 'available' || continuity != 'compatible'
          ? 'blocked'
          : !calibration
          ? 'not needed'
          : evidence.calibrationConsumed
          ? 'consumed'
          : 'available',
      'previousNativeStop': compactionStopReason(tree, lineage),
      'recoveryNotice': compactionRecoveryNotice(tree, lineage),
    };
  }

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
  ///
  /// For a new id a leading `/name` is expanded before admission (design D7):
  /// the exchange's prompt is the expansion and its `command` records what was
  /// typed. An unknown or non-user-invocable name, or a file that cannot be
  /// loaded, answers [SubmitRefused] with nothing recorded. A leading `//` is
  /// sent as the text without its first slash. A known id is never expanded
  /// again.
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
    var expanded = _Expanded(text);
    if (!known) {
      if (_busy) return const SubmitBusy();
      final current = writer.currentTurn;
      if (turn != current) return SubmitStale(current);
      try {
        expanded = _expand(text);
      } on LoadFailure catch (e) {
        return SubmitRefused(e.message);
      }
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
    final done = _exchange(id, expanded, first).whenComplete(() {
      _busy = false;
      _token = null;
    });
    done.ignore();
    return SubmitAdmitted(_exchangeKey(first), done);
  }

  Future<ExchangeResult> _exchange(
    String requestId,
    _Expanded prompt,
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
          'prompt': prompt.text,
          'command': ?prompt.command,
          'state': 'running',
          'first': first,
        },
      ),
    );
    await _captureContext(key, first);
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
    await _applyForExchange(
      key,
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

  /// Expands a leading `/name` of [text] (design D7); throws a [LoadFailure]
  /// to refuse it.
  _Expanded _expand(String text) {
    if (text.startsWith('//')) return _Expanded(text.substring(1));
    final match = RegExp(r'^/(\S+)').firstMatch(text);
    if (match == null) return _Expanded(text);
    final name = match[1]!;
    final rest = text.substring(match.end);
    final newline = rest.indexOf('\n');
    final first = (newline < 0 ? rest : rest.substring(0, newline)).trim();
    final more = newline < 0 ? '' : rest.substring(newline + 1);
    final args = more.isEmpty
        ? first
        : first.isEmpty
        ? more
        : '$first\n$more';

    final home = runtime.kehaiHome ?? _noHome;
    final view = loadWorkspace(
      workspace: runtime.workspace.path,
      kehaiHome: home,
    );
    final entry = view.slashCommands.where((e) => e.name == name).firstOrNull;
    if (entry == null) {
      throw LoadFailure(
        view.skill(name) != null
            ? '$name is not a user command'
            : 'unknown command /$name; start with // to send it as text',
      );
    }
    final LoadedText loaded;
    if (entry.command case final command?) {
      loaded = loadFile(
        root: view.root,
        path: command.path,
        kehaiHome: home,
        name: name,
        kind: 'command',
        arguments: args,
      );
    } else {
      final skill = entry.skill!;
      loaded = loadFile(
        root: view.root,
        path: skill.file,
        kehaiHome: home,
        name: name,
        kind: 'skill',
        arguments: args,
        baseDir: skill.directory,
      );
    }
    return _Expanded(loaded.text, {
      'name': name,
      'args': args,
      'source': loaded.source,
      'sha256': sha256.convert(utf8.encode(loaded.text)).toString(),
    });
  }

  (String, Map<String, Object?>) _contextSnapshot() {
    final loaded = loadWorkspace(
      workspace: runtime.workspace.path,
      kehaiHome: runtime.kehaiHome ?? _noHome,
    );
    final role = childRole;
    final value = <String, Object?>{
      'text': loaded.contextText,
      'files': [
        for (final f in loaded.files)
          {'path': f.path, 'bytes': f.size, 'truncated': f.truncated},
      ],
      'skills': loaded.skills.length,
      'role': ?role?.toJson(),
      'problems': [
        for (final problem in loaded.problems)
          {'path': problem.path, 'reason': problem.reason},
      ],
    };
    // The key covers everything stored, not the text alone: a problem that
    // appears or goes away without changing the text (an unreadable file, a
    // broken skill) is another context, so no exchange reuses stale
    // diagnostics. The role is part of it too: another role digest is
    // another context.
    final contextKey = sha256
        .convert(utf8.encode(jsonEncode(value)))
        .toString()
        .substring(0, 16);
    return (contextKey, value);
  }

  /// Captures the current workspace inputs for the admitted exchange.
  Future<void> _captureContext(String exchange, int first) async {
    final (contextKey, value) = _contextSnapshot();
    final stored = writer.tree.get(
      SessionPath.parse('body/contexts/$contextKey'),
    );
    if (stored == null) {
      await _applyForExchange(
        exchange,
        JournalRecord(
          turn: first,
          path: 'body/contexts/$contextKey',
          op: Op.set,
          value: value,
        ),
      );
    }
    await _applyForExchange(
      exchange,
      JournalRecord(
        turn: first,
        path: 'body/exchanges/$exchange',
        op: Op.merge,
        value: {'context': contextKey},
      ),
    );
    _contextKey = contextKey;
  }

  /// Runs one step; returns [_End] when the exchange ends with it, else
  /// [_Continue] after its calls are all terminal.
  Future<_StepOutcome> _step(
    int turn,
    String exchange,
    CancelToken token,
  ) async {
    final policy = runtime.config.effectiveCompaction(
      provider.id,
      'chatgpt-account',
      model,
    );
    final started = await _applyForExchange(
      exchange,
      JournalRecord(
        turn: turn,
        path: _stepPath(turn),
        op: Op.set,
        value: {
          'exchange': exchange,
          'model': model,
          'effort': effort,
          'lineage': _builder.requestLineage(writer.tree),
          'policy': {
            'strategy': policy.strategy.wireName,
            'threshold': policy.threshold,
            'strategySource': policy.strategySource,
            'thresholdSource': policy.thresholdSource,
          },
          'instructions': InstructionsIdentity(
            instructionsVersion,
            _contextKey,
            childRole?.digest ?? _builder.roleDigest,
          ).toJson(),
          'state': 'running',
          'attempts': 0,
        },
      ),
    );
    if (!started) return _End('cancelled', _cancelReason);
    final BuiltRequest built;
    try {
      built = await _builder.build(
        writer.tree,
        turn: turn,
        sourceOffset: writer.committedLength,
      );
    } on SensoriumCompositionError catch (e) {
      await _mergeStep(turn, exchange, {
        'state': 'failed',
        'reason': e.message,
      });
      return _End('stopped', e.message);
    } on StateError catch (e) {
      await _mergeStep(turn, exchange, {
        'state': 'failed',
        'reason': e.message,
      });
      return _End('stopped', e.message);
    }
    if (!_ownsCurrentStep(turn, exchange) || token.isCancelled) {
      return _cancelStep(turn, exchange);
    }
    await _mergeStep(turn, exchange, {'boundary': built.boundary});
    final context = {
      'used': built.used,
      'window': ?contextWindow,
      'block': built.block,
      'estimated': true,
      'quality': built.quality,
      'retained': built.retained,
      'windowSource': capacity.source,
      'backendWindow': ?capacity.backendContextWindow,
      'legacyWindowHint': ?capacity.legacyHint,
      'migrationNotice': ?capacity.migrationNotice,
    };
    final native = policy.strategy == CompactionStrategy.providerNative;
    final evidence = CompactionState.fold(
      writer.tree,
      built.lineage,
      policy,
      built.boundary,
    );
    final calibration = native && built.boundary != null && built.used == null;
    context['calibration'] = calibration;
    await _mergeStep(turn, exchange, {'capability': evidence.toJson()});
    String? nativeStop;
    if (native && evidence.state == 'unsupported') {
      nativeStop = evidence.reason;
    } else if (native &&
        encodeChatGptBody(buildChatGptBody(built.request)) == null) {
      nativeStop = 'serialized request exceeds 1 MiB';
    } else if (calibration && evidence.calibrationConsumed) {
      nativeStop = 'calibration allowance consumed';
    } else if (calibration && built.retained * 2 > policy.threshold) {
      nativeStop = 'retained-content calibration cap exceeded';
    } else if (native &&
        !calibration &&
        built.used! > (policy.threshold * 5 + 3) ~/ 4) {
      nativeStop = 'submission safety ceiling exceeded';
    }
    if (nativeStop != null) {
      await _mergeStep(turn, exchange, {
        'state': 'failed',
        'reason': _nativeMessage(nativeStop),
        'nativeStop': nativeStop,
        'context': context,
      });
      return _End('stopped', _nativeMessage(nativeStop));
    }
    if (built.overflow ||
        (built.used == null &&
            contextWindow != null &&
            built.retained > contextWindow!)) {
      final message = _overflowMessage(built.used);
      await _mergeStep(turn, exchange, {
        'state': 'failed',
        'reason': message,
        'context': context,
      });
      return _End('stopped', message);
    }

    final source = built.source!;
    // Local admission is durable before streaming, not proof of provider receipt.
    // Calibration consumption keeps its existing pre-submission cutoff.
    final admitted = await _mergeStep(turn, exchange, {
      'context': context,
      'sensorium': {
        'text': built.blockText,
        'tokens': built.block,
        'mode': 'full',
        'folds': [for (final fold in built.folds) fold.name],
        'source': {
          'turn': source.turn,
          'time': source.time.toIso8601String(),
          'offset': source.offset,
        },
      },
      if (calibration) 'calibration': true,
    }, admitting: token);
    if (!admitted) return _cancelStep(turn, exchange);
    var attempts = 0;
    _Streamed streamed;
    while (true) {
      // Recheck after admission's flush (and retry waits), without an await
      // between the live ownership/cancellation check and stream invocation.
      if (!_ownsCurrentStep(turn, exchange) || token.isCancelled) {
        return _cancelStep(turn, exchange);
      }
      attempts++;
      streamed = await _stream(built.request, turn, token);
      final failure = streamed.failure;
      if (failure == null || failure.kind == ProviderFailureKind.cancelled) {
        break;
      }
      if (calibration || (native && _fieldRejected(failure))) break;
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
      } else if (native && _fieldRejected(failure!)) {
        state = 'failed';
        reason = 'context_management rejected';
        evidence.state = 'unsupported';
        evidence.reason = reason;
        end = _End('stopped', _nativeMessage(reason));
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
      await _mergeStep(turn, exchange, {
        'state': state,
        'reason': reason,
        'attempts': attempts,
        'capability': evidence.toJson(),
        if (native && evidence.state == 'unsupported')
          'nativeStop': evidence.reason,
        if (failure != null)
          'failure': {
            'kind': failure.kind.wire,
            'message': native && _fieldRejected(failure)
                ? 'context_management rejected'
                : failure.message,
            'status': ?failure.status,
            if (!(native && _fieldRejected(failure))) 'code': ?failure.code,
            'sent': failure.sent,
          },
        if (partial.isNotEmpty) 'partial': partial,
        if (streamed.usage case final usage?) 'usage': _usageJson(usage),
        'context': context,
      });
      return end;
    }

    String? completionStop;
    if (native) {
      if (parts.any((part) => part is _CompactionPart)) {
        evidence.state = 'observed-supported';
        evidence.reason = 'compaction item observed';
      } else if ((streamed.usage?.input ?? built.used ?? 0) >=
          policy.threshold) {
        evidence.state = 'unsupported';
        evidence.reason = streamed.usage?.input == null
            ? 'estimated input at threshold without compaction'
            : 'no compaction item at threshold';
        completionStop = evidence.reason;
      } else if (calibration &&
          (streamed.usage?.input == null || streamed.usage?.output == null)) {
        completionStop = 'calibration usage unavailable';
      }
    }
    await seams.beforeStepCommit?.call(turn);
    final committed = await _mergeStep(turn, exchange, {
      'state': 'completed',
      'stop': streamed.stop!.wire,
      'capability': evidence.toJson(),
      'nativeStop': ?completionStop,
      'attempts': attempts,
      if (streamed.usage case final usage?) 'usage': _usageJson(usage),
      'context': context,
      'output': [for (final part in parts) ?_outputEntry(part)],
    });
    if (!committed) return _End('cancelled', _cancelReason);
    await seams.afterStepCommit?.call(turn);
    if (!_ownsCurrentStep(turn, exchange, state: 'completed')) {
      return _End('cancelled', _cancelReason);
    }

    final calls = [
      for (final part in parts.whereType<_CallPart>())
        ToolCall(
          callId: part.callId,
          name: part.name,
          argumentsJson: part.arguments,
        ),
    ];
    if (calls.isEmpty) {
      if (completionStop != null && !token.isCancelled) {
        return _End('stopped', _nativeMessage(completionStop));
      }
      // An interrupt during the commit still cancels the exchange; the step
      // arrived whole and stays committed.
      return token.isCancelled
          ? _End('cancelled', _cancelReason)
          : const _End('done', null);
    }

    // Every call is submitted before any is awaited, so the runtime's own
    // bounds decide what runs, queues or is refused busy.
    final errors = await Future.wait([
      for (final call in calls) _runCall(call, token, stepTurn: turn),
    ]);
    for (final error in errors) {
      if (error is StorageError) throw error;
    }
    final broken = errors.nonNulls.firstOrNull;
    if (broken != null) return _End('failed', 'tool runtime error: $broken');
    if (completionStop != null) {
      return _End('stopped', _nativeMessage(completionStop));
    }
    return const _Continue();
  }

  Future<Object?> _runCall(
    ToolCall call,
    CancelToken token, {
    required int stepTurn,
  }) async {
    try {
      await runtime.run(call, cancel: token, stepTurn: stepTurn);
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
          case TextDelta(:final text):
            streamed.addText(event);
            _deltas.add(StreamDelta(turn, 'text', text));
          case TextDeltaPosition(:final delta, :final outputIndex):
            streamed.positionText(delta, outputIndex);
          case ReasoningSummaryDelta(:final text):
            _deltas.add(StreamDelta(turn, 'reasoning', text));
          case OpaqueItem(:final json, :final outputIndex):
            streamed.add(_ReasoningPart(json, outputIndex));
          case CompactionItem(:final json, :final outputIndex):
            streamed.add(_CompactionPart(json, outputIndex));
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

  String _overflowMessage(int? used) {
    final window = contextWindow;
    final size = used == null
        ? 'unknown tokens in use'
        : window == null
        ? '~${formatTokens(used)} tokens in use'
        : '~${formatTokens(used)} of ${formatTokens(window)} tokens';
    return 'context overflow: $size; rewind or start a new session';
  }

  bool _ownsStep(
    GuardedRead read,
    int turn,
    String exchange, {
    String state = 'running',
  }) {
    final step = read(_stepPath(turn));
    final owner = read('body/exchanges/$exchange');
    return step is Map<String, Object?> &&
        step['exchange'] == exchange &&
        step['state'] == state &&
        owner is Map<String, Object?> &&
        owner['state'] == 'running';
  }

  bool _ownsCurrentStep(int turn, String exchange, {String state = 'running'}) {
    final tree = writer.tree;
    return _ownsStep(
      (path) => tree.get(SessionPath.parse(path)),
      turn,
      exchange,
      state: state,
    );
  }

  Future<_End> _cancelStep(int turn, String exchange) async {
    await _mergeStep(turn, exchange, {
      'state': 'cancelled',
      'reason': _cancelReason,
    });
    return _End('cancelled', _cancelReason);
  }

  Future<bool> _mergeStep(
    int turn,
    String exchange,
    Map<String, Object?> fields, {
    CancelToken? admitting,
  }) async {
    final outcome = await _gated(
      () => writer.applyGuarded((read) {
        if (!_ownsStep(read, turn, exchange) ||
            (admitting?.isCancelled ?? false)) {
          return const GuardedRefusal('stale');
        }
        return GuardedAppend(
          JournalRecord(
            turn: turn,
            path: _stepPath(turn),
            op: Op.merge,
            value: fields,
          ),
        );
      }),
    );
    return outcome is Applied;
  }

  Future<bool> _applyForExchange(String exchange, JournalRecord record) async {
    final outcome = await _gated(
      () => writer.applyGuarded((read) {
        final owner = read('body/exchanges/$exchange');
        if (owner is! Map<String, Object?> || owner['state'] != 'running') {
          return const GuardedRefusal('stale');
        }
        return GuardedAppend(record);
      }),
    );
    return outcome is Applied;
  }

  Future<CommittedUpdate> _apply(JournalRecord record) =>
      _gated(() => writer.apply(record));

  Future<T> _gated<T>(Future<T> Function() operation) =>
      runtime.writeGate.run(operation);
}

/// The prompt an exchange starts with and the `command` that produced it.
final class _Expanded {
  const _Expanded(this.text, [this.command]);

  final String text;
  final Map<String, Object?>? command;
}

/// A Kehai home that does not exist, for a runtime attached without one.
final Directory _noHome = Directory(
  p.join(Directory.systemTemp.path, 'kehai-no-home'),
);

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
  _CompactionPart(:final json) => {'type': 'compaction', 'item': json},
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
  int? index;

  /// The arrival sequence, set by [_Streamed.add].
  int seq = 0;
}

final class _TextPart extends _Part {
  _TextPart(super.index);

  final StringBuffer text = StringBuffer();
}

final class _CompactionPart extends _Part {
  _CompactionPart(this.json, super.index);
  final Map<String, Object?> json;
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
  final Map<TextDelta, _TextPart> _textParts = Map.identity();
  Usage? usage;
  StopReason? stop;
  ProviderFailure? failure;

  void add(_Part part) {
    part.seq = _parts.length;
    _parts.add(part);
  }

  void addText(TextDelta delta) {
    final part = _TextPart(delta.outputIndex)..text.write(delta.text);
    if (delta.outputIndex == null) _textParts[delta] = part;
    add(part);
  }

  void positionText(TextDelta delta, int index) {
    _textParts[delta]?.index = index;
  }

  /// The parts by output index, then the unindexed ones in arrival order.
  List<_Part> ordered() {
    // Coalesce only after position updates, so anonymous deltas for distinct
    // done messages cannot accidentally share an output position.
    final grouped = <_Part>[];
    for (final part in _parts) {
      if (part is! _TextPart) {
        grouped.add(part);
        continue;
      }
      _TextPart? target;
      if (part.index != null) {
        target = grouped
            .whereType<_TextPart>()
            .where((text) => text.index == part.index)
            .lastOrNull;
      } else if (grouped.lastOrNull case _TextPart(index: null) && final last) {
        target = last;
      }
      if (target == null) {
        target = _TextPart(part.index)..seq = part.seq;
        grouped.add(target);
      }
      target.text.write(part.text);
    }
    final indexed = grouped.where((part) => part.index != null).toList()
      ..sort((a, b) {
        final byIndex = a.index!.compareTo(b.index!);
        return byIndex != 0 ? byIndex : a.seq.compareTo(b.seq);
      });
    return [...indexed, ...grouped.where((part) => part.index == null)];
  }
}

bool _fieldRejected(ProviderFailure failure) =>
    (failure.kind == ProviderFailureKind.invalidRequest ||
        failure.kind == ProviderFailureKind.notPermitted) &&
    (failure.param == 'context_management' ||
        ('${failure.code ?? ''} ${failure.message}').toLowerCase().contains(
          'context_management',
        ));

String _nativeMessage(String reason) =>
    'native compaction stopped: $reason; '
    'explicitly select off or a different policy, rewind, or start a new session';
