/// The tool-call runtime: one lifecycle for every model tool call.
///
/// A call is validated, recorded as the tree node `body/calls/<key>`, passed
/// through the hook and permission stages, run by its [Tool], and settled. Its
/// whole output goes to the result store; the model sees only the envelope
/// the central composer renders from the stored result. Every node update is
/// one guarded append (`SessionWriter.applyGuarded`) that checks ownership
/// (the node exists, carries this call's `attempt` and is not terminal), and
/// the terminal update, which references the stored result, additionally
/// needs the result's descriptor in the tree (design D3 and D9, ADR 0010).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../config/user_config.dart';
import '../jobs/recovery.dart';
import '../jobs/supervisor.dart';
import '../permissions/gate.dart';
import '../provider/provider.dart';
import '../results/composer.dart';
import '../results/descriptor.dart';
import '../results/result_store.dart';
import '../results/search.dart';
import '../session/errors.dart';
import '../session/path.dart';
import '../session/record.dart';
import '../session/writer.dart';
import '../shell/detect.dart';
import '../hooks/hook_stage.dart';
import '../permissions/workspace_paths.dart';
import 'ask.dart';
import 'child_env.dart';
import 'bash.dart';
import 'edit.dart';
import 'job_tool.dart';
import 'result_tools.dart';
import 'read.dart';
import 'roster.dart';
import 'schema.dart';
import 'search.dart';
import 'tool.dart';
import 'write.dart';

/// The most calls that run at once.
const int maxRunningCalls = 8;

/// The most calls that wait, in arrival order, for a running slot.
const int maxQueuedCalls = 32;

/// How many times a terminal record is retried after its descriptor vanished.
const int _maxSettleRetries = 16;

const Set<String> _terminalStatuses = {'settled', 'failed', 'cancelled'};

/// The tools every runtime has unless [ToolRuntime.attach] is given its own.
///
/// [rg] is the one resolution of `rg` made at attach.
Map<String, Tool> _builtinTools(LazyRg rg) => {
  'read': const ReadTool(),
  'edit': const EditTool(),
  'write': const WriteTool(),
  'grep': GrepTool.lazy(rg.call),
  'find': FindTool.lazy(rg.call),
  'ls': const LsTool(),
  'ask': const AskTool(),
  'read_more': const ReadMoreTool(),
  'search_result': SearchResultTool(ResultSearcher()),
  'bash': const BashTool(),
  'job': const JobTool(),
};

/// The node key `c-<12 hex>` of the provider call id [callId].
///
/// It is the first 12 hex digits of the SHA-256 of the UTF-8 call id, so any
/// provider id becomes a valid path segment.
String callKey(String callId) =>
    'c-${sha256.convert(utf8.encode(callId)).toString().substring(0, 12)}';

/// A call node was removed, replaced or finalized by someone else, so the
/// runtime's update was refused and nothing was appended.
///
/// This happens when a rewind removed the node while its call was running.
final class StaleCallError implements Exception {
  /// Creates the error for the node [key].
  const StaleCallError(this.key);

  /// The node key.
  final String key;

  @override
  String toString() => 'StaleCallError: call $key no longer owns its node';
}

/// Test seams of the runtime.
final class ToolRuntimeSeams {
  /// Creates seams; every callback is optional.
  const ToolRuntimeSeams({
    this.beforeSettle,
    this.onStale,
    this.rgProbeTimeout = defaultRgProbeTimeout,
  });

  /// How long the `rg --version` probe may take.
  final Duration rgProbeTimeout;

  /// Runs after a call's result descriptor is registered and before the
  /// record that references it is appended; a rewind may land here.
  final Future<void> Function(String key)? beforeSettle;

  /// Runs when a guarded update to the call node [key] came back `stale`.
  final void Function(String key)? onStale;
}

/// Runs tool calls against one session.
///
/// Created by [attach]. Calls are submitted with [run]; up to
/// [maxRunningCalls] run at once and up to [maxQueuedCalls] wait. A tool
/// failure never throws from [run]: the model always gets an envelope. The
/// only exceptions are the writer's `StorageError`, after which the runtime
/// admits nothing more (the session must be reopened), and a [StaleCallError].
final class ToolRuntime {
  ToolRuntime._(
    this.writer,
    this.store,
    this.workspace,
    this.config,
    this.yolo,
    this._tools,
    this._hooks,
    this._gate,
    this.prompts,
    this._seams,
    this.kehaiHome,
    this.shell,
    this.jobs,
  );

  /// Attaches a runtime to [writer] and [store].
  ///
  /// [tools] are the available implementations by tool name; a roster tool
  /// without one fails its calls as unavailable. [hooks] and [gate] are the
  /// stages every call passes before it runs, in that order, after its
  /// arguments were validated. [hooks] defaults to the [HookStage] built from
  /// the hooks of [config], or to [AllowAllStage] when it has none. [gate]
  /// defaults to the [PermissionGate] built
  /// from [workspace], [config], [yolo], [answerer] and [kehaiHome], which
  /// then must be given.
  ///
  /// The shell is detected here, once, unless [shell] gives the detection to
  /// use. [posixShell] says whether `bash` runs under a POSIX shell, because a
  /// command is proven read-only only under one; it defaults to what the
  /// detected shell is (PowerShell is never proven, a missing shell neither).
  ///
  /// [config] defaults to `config.json` in [kehaiHome] (the defaults when the
  /// file is missing, or when there is no home); an invalid file throws a
  /// `ConfigError` before anything starts.
  ///
  /// [answerer] receives questions and permission prompts; without one the
  /// session is headless.
  ///
  /// Resume finalization (design D12) runs here before any call is admitted.
  static Future<ToolRuntime> attach(
    SessionWriter writer,
    ResultStore store, {
    required Directory workspace,
    UserConfig? config,
    bool yolo = false,
    Answerer? answerer,
    Directory? kehaiHome,
    bool? posixShell,
    ShellDetection? shell,
    Map<String, Tool> tools = const {},
    CallStage? hooks,
    CallStage? gate,
    ToolRuntimeSeams seams = const ToolRuntimeSeams(),
    JobHooks jobHooks = const JobHooks(),
  }) async {
    if (gate == null && kehaiHome == null) {
      throw ArgumentError.value(
        kehaiHome,
        'kehaiHome',
        'required when no gate is given',
      );
    }
    // Read before anything starts: an invalid file stops attach with a
    // ConfigError and nothing is left running.
    config ??= kehaiHome == null
        ? const UserConfig()
        : UserConfig.load(kehaiHome.path);
    // Detected once, now. A missing shell never fails attach: it fails the
    // `bash` calls, and the other tools work.
    final detection =
        shell ??
        detectShell(workspaceRoot: realPath(workspace.path) ?? workspace.path);
    final prompts = PromptChannel(answerer);
    final jobs = JobSupervisor(writer, store, hooks: jobHooks);
    // Resolved once, when the first grep or find needs it, as a job of the
    // supervisor; a missing `rg` never fails attach, it fails those calls.
    final rgPath = config.rgPath;
    final rg = LazyRg(
      () => resolveRg(
        rgPath: rgPath,
        workspaceRoot: realPath(workspace.path) ?? workspace.path,
        configPath: kehaiHome == null
            ? configFileName
            : p.join(kehaiHome.path, configFileName),
        jobs: jobs,
        setsid: detection.shell?.setsid,
        probeTimeout: seams.rgProbeTimeout,
      ),
    );
    // Hooks come from the user's configuration only (design D14).
    final hookStage =
        hooks ??
        (config.hooks.isEmpty
            ? const AllowAllStage()
            : HookStage(
                hooks: config.hooks,
                jobs: jobs,
                store: store,
                workspace: realPath(workspace.path) ?? workspace.path,
                environment: shellEnvironment(
                  Platform.environment,
                  passthrough: config.envPassthrough,
                ),
                session: () =>
                    writer.tree.get(SessionPath.parse('meta/session')),
                setsid: detection.shell?.setsid,
              ));
    final runtime = ToolRuntime._(
      writer,
      store,
      workspace,
      config,
      yolo,
      Map.unmodifiable({..._builtinTools(rg), ...tools}),
      hookStage,
      gate ??
          PermissionGate(
            workspace: workspace,
            kehaiHome: kehaiHome!,
            prompts: prompts,
            config: config,
            yolo: yolo,
            posixShell: posixShell ?? detection.shell?.isPosix ?? false,
          ),
      prompts,
      seams,
      kehaiHome,
      detection,
      jobs,
    );
    runtime.jobs
      ..liveCallKeys = (() => runtime._live.keys.toSet())
      ..afterReconcile = runtime._cancelRewoundCalls;
    try {
      runtime.resumed = await runtime.jobs.recovery.resume();
    } on Object {
      await runtime.jobs.close();
      rethrow;
    }
    return runtime;
  }

  /// The session writer.
  final SessionWriter writer;

  /// The result store of the same session.
  final ResultStore store;

  /// The workspace root.
  final Directory workspace;

  /// The user configuration.
  final UserConfig config;

  /// Whether the user asked to skip permission prompts.
  final bool yolo;

  /// The channel the answerer replies through, by call key.
  final PromptChannel prompts;

  /// The Kehai home, or null when the runtime was given a gate instead.
  final Directory? kehaiHome;

  /// The shell detected at attach, or what was tried when none was found.
  final ShellDetection shell;

  /// The supervisor of every process the tools start (design D8).
  final JobSupervisor jobs;

  /// What attach finalized before it admitted any call (design D12).
  ResumeReport resumed = ResumeReport.none;

  final Map<String, Tool> _tools;
  final CallStage _hooks;
  final CallStage _gate;
  final ToolRuntimeSeams _seams;

  final Map<String, ToolDefinition> _definitions = {
    for (final d in toolDefinitions) d.name: d,
  };
  final Map<String, _Live> _live = {};
  final Queue<_Live> _waiting = Queue();
  int _running = 0;
  StorageError? _fatal;
  bool _closed = false;

  /// The eleven tools the model may call, with their argument schemas.
  late final List<ToolSpec> specs = List.unmodifiable([
    for (final d in toolDefinitions)
      if (d.name == 'bash')
        ToolSpec(
          name: d.name,
          description:
              '${d.description} ${shell.shell == null ? 'No shell was found '
                        '(${shell.failure}); calls fail.' : 'The shell is '
                        '${shell.shell!.name}.'}',
          parametersJsonSchema: d.schema,
        )
      else
        d.spec,
  ]);

  /// Runs [call] and returns the output that answers it.
  ///
  /// The output is the composed envelope for the call's stored result. Throws
  /// the writer's `StorageError` when the journal is unusable, and from then
  /// on for every later call.
  Future<ToolOutputItem> run(ToolCall call) async {
    _ensureUsable();
    final live = _Live(call, callKey(call.callId));
    if (_live.containsKey(live.key)) {
      throw StateError('call id ${call.callId} is already running');
    }
    _live[live.key] = live;
    try {
      final text = await _drive(live);
      return ToolOutputItem(callId: call.callId, output: text);
    } on StaleCallError {
      live.token.cancel();
      rethrow;
    } finally {
      if (!live.terminal.isCompleted) live.terminal.complete('lost');
      _leave(live);
      _live.remove(live.key);
    }
  }

  /// Cancels every pending and running call with reason `user`.
  ///
  /// Pending calls are cancelled first, then running ones. Each is recorded
  /// `cancelled` before this returns. Jobs already moved to the background are
  /// not touched. Returns how many calls ended `cancelled`; a call that
  /// settled first is not counted.
  Future<int> cancelTurn() => _cancelAll('user');

  /// Cancels job [id] (design D10) and returns how it ended; see
  /// [JobSupervisor.cancelJob].
  Future<CancelOutcome> cancelJob(String id) => jobs.cancelJob(id);

  /// Stops admitting calls and cancels the ones still live, jobs included.
  Future<void> close() async {
    _closed = true;
    await _cancelAll('shutdown');
    await jobs.close();
  }

  Future<int> _cancelAll(String reason) async {
    final calls = _live.values.toList();
    var cancelled = 0;
    for (final running in [false, true]) {
      final group = [
        for (final c in calls)
          if (c.running == running) c,
      ];
      for (final call in group) {
        call.cancelReason ??= reason;
        call.token.cancel();
      }
      final ended = await Future.wait(group.map((c) => c.terminal.future));
      cancelled += ended.where((status) => status == 'cancelled').length;
    }
    return cancelled;
  }

  /// Cancels the live calls whose nodes a rewind removed or replaced (design
  /// D11). The call's update would be refused as stale anyway; this stops its
  /// tool early.
  void _cancelRewoundCalls() {
    final tree = writer.tree;
    for (final live in _live.values) {
      if (!live.created || live.token.isCancelled) continue;
      final node = tree.get(SessionPath.parse(live.path));
      if (node is Map<String, Object?> && node['attempt'] == live.attempt) {
        continue;
      }
      live.cancelReason ??= 'rewound';
      live.token.cancel();
    }
  }

  void _ensureUsable() {
    if (_closed) throw StateError('the tool runtime is closed');
    final fatal = _fatal;
    if (fatal != null) throw fatal;
    if (writer.state != WriterState.ready) {
      throw _fatal = const StorageError(
        'the session writer is not usable; reopen the session',
      );
    }
  }

  Future<String> _drive(_Live live) async {
    final call = live.call;
    final definition = _definitions[call.name];
    final input = parseArguments(call.argumentsJson);
    live
      ..tool = call.name
      ..version = definition?.version ?? 0
      ..input = input ?? call.argumentsJson;

    // Validation fails a call before it takes a slot or has any effect.
    var failure = _validationFailure(call.name, definition, input);
    var queued = false;
    if (failure == null) {
      if (_running < maxRunningCalls) {
        _running++;
        live.holdsSlot = true;
      } else if (_waiting.length < maxQueuedCalls) {
        _waiting.add(live);
        queued = true;
      } else {
        failure = (
          'tool busy',
          'tool busy: $maxRunningCalls calls running and $maxQueuedCalls '
              'waiting',
        );
      }
    }

    if (!await _create(live)) {
      throw StateError('call id ${call.callId} was already used');
    }
    if (failure != null) {
      final (summary, body) = failure;
      return _finishText(
        live,
        'failed',
        ResultStatus.error,
        summary,
        body,
        reason: summary,
      );
    }
    if (queued) {
      await Future.any([live.granted.future, live.token.whenCancelled]);
      if (!live.granted.isCompleted) {
        _waiting.remove(live);
        return _cancelledBeforeRun(live);
      }
    }
    return _execute(live, input!);
  }

  (String, String)? _validationFailure(
    String name,
    ToolDefinition? definition,
    Map<String, Object?>? input,
  ) {
    if (definition == null) return ('unknown tool', 'unknown tool $name');
    if (input == null) return ('invalid arguments', notAnObjectMessage);
    final violations = validateArguments(definition.schema, input);
    if (violations.isNotEmpty) {
      return (
        'invalid arguments',
        'invalid arguments for $name:\n${violations.join('\n')}',
      );
    }
    final broken = definition.check?.call(input) ?? const [];
    if (broken.isNotEmpty) {
      return (
        'invalid arguments',
        'invalid arguments for $name:\n${broken.join('\n')}',
      );
    }
    if (!_tools.containsKey(name)) {
      return ('tool unavailable', '$name is not available in this build');
    }
    return null;
  }

  Future<String> _execute(_Live live, Map<String, Object?> input) async {
    if (live.token.isCancelled) return _cancelledBeforeRun(live);
    final stageCall = StageCall(
      tool: live.tool,
      callKey: live.key,
      callId: live.call.callId,
      input: input,
    );
    Map<String, Object?>? permission;
    // Hooks (group 11) run first, then the permission gate.
    for (final (stage, field) in [(_hooks, 'hooks'), (_gate, 'permission')]) {
      final outcome = await _runStage(stage, stageCall, live);
      if (outcome == null) return _cancelledBeforeRun(live);
      if (outcome.record != null) live.extra[field] = outcome.record;
      if (field == 'permission' && outcome.record is Map<String, Object?>) {
        permission = outcome.record! as Map<String, Object?>;
      }
      live.diag.addAll(outcome.diag);
      final denied = outcome.denyReason;
      if (denied != null) {
        return _finishText(
          live,
          'settled',
          ResultStatus.denied,
          'denied',
          denied,
        );
      }
      if (live.token.isCancelled) return _cancelledBeforeRun(live);
    }

    await _update(live, {'status': 'running', ...live.takeExtra()});
    live.running = true;

    final pipe = OutputPipe();
    final stored = store.storeResult(pipe.chunks());
    final context = ToolContext(
      callKey: live.key,
      callId: live.call.callId,
      output: pipe,
      cancel: live.token,
      workspace: workspace,
      config: config,
      prompts: prompts,
      kehaiHome: kehaiHome,
      shell: shell,
      jobs: jobs,
      permission: permission,
    );
    final tool = _invoke(_tools[live.tool]!, context, input);
    var first = await Future.any<_Step>([
      tool.then(_ToolDone.new),
      live.token.whenCancelled.then((_) => const _Cancelled()),
      stored.then(_StoreEnded.new),
    ]);
    // A tool that returned because its call was cancelled can win the race
    // against the token; the call still ends cancelled.
    if (first is _ToolDone && live.token.isCancelled) {
      first = const _Cancelled();
    }
    switch (first) {
      case _ToolDone(:final outcome):
        pipe.close();
        final written = await stored;
        // A tool that answers with a result the job supervisor stored has
        // nothing of its own to store.
        final answer = outcome.result;
        final lost = outcome.storage;
        return _terminate(
          live,
          lifecycle: outcome.failed ? 'failed' : 'settled',
          envelope: outcome.status,
          summary: outcome.summary,
          write: lost != null
              ? ResultStorageFailed(lost.bytesAccepted, '', lost.error)
              : answer != null && written is! ResultStorageFailed
              ? ResultComplete(answer)
              : written,
          complete: outcome.complete,
          composed: outcome.composed && answer == null,
          reason: outcome.failed ? outcome.reason ?? outcome.summary : null,
          policy: outcome.policy,
        );
      case _Cancelled():
        pipe.close();
        final written = await stored;
        unawaited(_late(live, tool));
        // A call whose output lives in its job answers with what the job
        // printed; the job is terminated through the supervisor first.
        final partial = await jobs.cancelCallJob(
          live.key,
          reason: live.cancelReason ?? 'user',
        );
        return _terminate(
          live,
          lifecycle: 'cancelled',
          envelope: ResultStatus.error,
          summary: 'cancelled: ${live.cancelReason}',
          write: partial != null && written is! ResultStorageFailed
              ? ResultComplete(partial)
              : written,
          complete: false,
          reason: live.cancelReason,
        );
      case _StoreEnded(:final write):
        // The store stopped listening, so the producer must stop too.
        live.token.cancel();
        pipe.close();
        unawaited(_late(live, tool));
        return _terminate(
          live,
          lifecycle: 'failed',
          envelope: ResultStatus.error,
          summary: 'storage failure',
          write: write,
          complete: false,
        );
    }
  }

  /// Runs a stage, or returns `null` when the turn is cancelled first.
  Future<StageOutcome?> _runStage(
    CallStage stage,
    StageCall call,
    _Live live,
  ) async {
    Future<StageOutcome> check() async {
      try {
        return await stage.check(call, live.token);
      } on Object catch (e) {
        return StageOutcome.deny('stage failed: $e');
      }
    }

    return Future.any<StageOutcome?>([
      check(),
      live.token.whenCancelled.then((_) => null),
    ]);
  }

  Future<ToolOutcome> _invoke(
    Tool tool,
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    try {
      return await tool.run(context, input);
    } on Object catch (e) {
      return ToolOutcome(
        status: ResultStatus.error,
        summary: 'tool error: $e',
        complete: false,
      );
    }
  }

  /// A completion that arrives after the call was already finalized. The
  /// ownership guard refuses it; nothing is appended.
  Future<void> _late(_Live live, Future<ToolOutcome> tool) async {
    try {
      // Only after the call's own terminal record: a completion that merely
      // arrives first must not win against the finalization in progress.
      await live.terminal.future;
      final outcome = await tool;
      final result = await _guarded(live, {
        'status': 'settled',
        'envelope': outcome.status.name,
        'summary': outcome.summary,
      });
      if (result is Refused) _seams.onStale?.call(live.key);
    } on Object {
      // The call is final; a late completion must never surface.
    }
  }

  Future<String> _cancelledBeforeRun(_Live live) => _finishText(
    live,
    'cancelled',
    ResultStatus.error,
    'cancelled: ${live.cancelReason}',
    '',
    reason: live.cancelReason,
  );

  /// Stores [body] as the call's result and records the terminal state.
  Future<String> _finishText(
    _Live live,
    String lifecycle,
    ResultStatus envelope,
    String summary,
    String body, {
    String? reason,
  }) async {
    final write = await store.storeResult(
      body.isEmpty
          ? const Stream<List<int>>.empty()
          : Stream.value(utf8.encode(body)),
    );
    return _terminate(
      live,
      lifecycle: lifecycle,
      envelope: envelope,
      summary: summary,
      write: write,
      complete: lifecycle != 'cancelled',
      reason: reason,
    );
  }

  /// Records the terminal state for [write] and composes the model text.
  Future<String> _terminate(
    _Live live, {
    required String lifecycle,
    required ResultStatus envelope,
    required String summary,
    required ResultWrite write,
    required bool complete,
    String? reason,
    bool composed = false,
    ResultPolicy? policy,
  }) async {
    final ResultDescriptor descriptor;
    var whole = complete;
    switch (write) {
      case ResultComplete(descriptor: final d):
        descriptor = d;
      case ResultProducerFailed(descriptor: final d):
        descriptor = d;
        whole = false;
      case ResultStorageFailed():
        return _storageFailure(live, write);
    }
    await _settle(live, descriptor, {
      'status': lifecycle,
      'envelope': envelope.name,
      'summary': summary,
      'result': {'handle': descriptor.handle, 'complete': whole},
      'reason': ?reason,
      ...live.takeExtra(),
    });
    live.terminal.complete(lifecycle);
    final file = File(
      p.join(store.sessionDir.path, resultsDirName, descriptor.sha256),
    );
    final text = composed && whole
        ? await file.readAsString()
        : await composeResult(
            live.tool,
            envelope,
            summary,
            descriptor,
            file,
            policy: policy,
          );
    return text + _diagLines(live);
  }

  /// The one handle-less outcome: the result could not be stored.
  Future<String> _storageFailure(_Live live, ResultStorageFailed write) async {
    await _settle(live, null, {
      'status': 'failed',
      'envelope': 'error',
      'summary': 'storage failure',
      'reason': 'storage: ${write.error}',
      'accepted': write.bytesAccepted,
      ...live.takeExtra(),
    });
    live.terminal.complete('failed');
    return composeStorageFailure(live.tool, write.error, write.bytesAccepted) +
        _diagLines(live);
  }

  String _diagLines(_Live live) =>
      [for (final (source, text) in live.diag) '\n[diag $source] $text'].join();

  /// Registers [descriptor], then appends the terminal [fields].
  ///
  /// When a rewind between the two removed the descriptor, the append is
  /// refused with `descriptors missing`; the descriptor is registered again
  /// and the same record retried under the same ownership guard.
  Future<void> _settle(
    _Live live,
    ResultDescriptor? descriptor,
    Map<String, Object?> fields,
  ) async {
    if (descriptor != null) await _write(() => writer.recordResult(descriptor));
    await _seams.beforeSettle?.call(live.key);
    for (var attempt = 0; ; attempt++) {
      final outcome = await _guarded(live, fields);
      switch (outcome) {
        case Applied():
          return;
        case Refused(reason: 'descriptors missing')
            when descriptor != null && attempt < _maxSettleRetries:
          await _write(() => writer.recordResult(descriptor));
        case Refused(reason: 'stale'):
          _seams.onStale?.call(live.key);
          throw StaleCallError(live.key);
        case Refused():
          throw StateError(
            'the record for call ${live.key} was refused: $outcome',
          );
      }
    }
  }

  /// Appends the non-terminal update [fields] under the ownership guard.
  Future<void> _update(_Live live, Map<String, Object?> fields) async {
    final outcome = await _guarded(live, fields);
    if (outcome is Refused) {
      _seams.onStale?.call(live.key);
      throw StaleCallError(live.key);
    }
  }

  /// Merges [fields] into the call node when this call still owns it: the
  /// node exists, carries this `attempt` and is not terminal.
  Future<GuardedOutcome> _guarded(_Live live, Map<String, Object?> fields) =>
      _write(
        () => writer.applyGuarded((read) {
          final node = read(live.path);
          if (node is! Map<String, Object?> ||
              node['attempt'] != live.attempt ||
              _terminalStatuses.contains(node['status'])) {
            return const GuardedRefusal('stale');
          }
          return GuardedAppend(
            JournalRecord(
              turn: writer.currentTurn,
              path: live.path,
              op: Op.merge,
              value: fields,
            ),
          );
        }),
      );

  /// Records the `pending` node with the call's input; false when a node with
  /// this key already exists.
  Future<bool> _create(_Live live) async {
    final outcome = await _write(
      () => writer.applyGuarded((read) {
        if (read(live.path) != null) return const GuardedRefusal('exists');
        return GuardedAppend(
          JournalRecord(
            turn: writer.currentTurn,
            path: live.path,
            op: Op.set,
            value: {
              'tool': live.tool,
              'version': live.version,
              'callId': live.call.callId,
              'attempt': live.attempt,
              'input': live.input,
              'status': 'pending',
            },
          ),
        );
      }),
    );
    if (outcome is Applied) live.created = true;
    return outcome is Applied;
  }

  /// Runs a writer operation; a broken journal becomes the runtime's fatal
  /// error, which every later call then throws.
  Future<T> _write<T>(Future<T> Function() operation) async {
    try {
      return await operation();
    } on StorageError catch (e) {
      _fatal ??= e;
      rethrow;
    } on SessionError catch (e) {
      if (e.reason == 'writer broken') {
        throw _fatal ??= const StorageError('the session writer is broken');
      }
      rethrow;
    }
  }

  /// Gives back a call's running slot, or its place in the queue, and hands
  /// freed slots to the waiting calls in arrival order.
  void _leave(_Live live) {
    _waiting.remove(live);
    if (live.holdsSlot) {
      live.holdsSlot = false;
      _running--;
    }
    while (_running < maxRunningCalls && _waiting.isNotEmpty) {
      final next = _waiting.removeFirst();
      next.holdsSlot = true;
      _running++;
      next.granted.complete();
    }
  }
}

/// What ended the wait of a running call.
sealed class _Step {
  const _Step();
}

final class _ToolDone extends _Step {
  const _ToolDone(this.outcome);

  final ToolOutcome outcome;
}

final class _Cancelled extends _Step {
  const _Cancelled();
}

final class _StoreEnded extends _Step {
  const _StoreEnded(this.write);

  final ResultWrite write;
}

/// The runtime's state for one live call.
final class _Live {
  _Live(this.call, this.key) : attempt = _newAttempt();

  final ToolCall call;
  final String key;
  final String attempt;
  final CancelToken token = CancelToken();
  final Completer<void> granted = Completer<void>();
  final Completer<String> terminal = Completer<String>();
  final Map<String, Object?> extra = {};
  final List<(String, String)> diag = [];

  String tool = '';
  int version = 0;
  Object? input;
  bool holdsSlot = false;
  bool running = false;
  bool created = false;
  String? cancelReason;
  bool _diagTaken = false;

  String get path => 'body/calls/$key';

  /// The stage records and diagnostics not yet merged into the node.
  Map<String, Object?> takeExtra() {
    final out = <String, Object?>{...extra};
    extra.clear();
    if (diag.isNotEmpty && !_diagTaken) {
      _diagTaken = true;
      out['diag'] = [
        for (final (source, text) in diag) {'source': source, 'text': text},
      ];
    }
    return out;
  }
}

String _newAttempt() {
  final random = Random.secure();
  return List.generate(16, (_) => random.nextInt(16).toRadixString(16)).join();
}
