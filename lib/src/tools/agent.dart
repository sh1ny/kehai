/// The `agent` tool (design D8, D12): runs an installed agent role as a child
/// engine under the job supervisor.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../cli/settings.dart' show homeVariable;
import '../client/engine_process.dart';
import '../jobs/agent_run.dart';
import '../jobs/supervisor.dart';
import '../permissions/workspace_paths.dart';
import '../provider/provider.dart' show CancelToken;
import '../results/composer.dart';
import '../shell/launch.dart';
import '../workspace/inventory.dart';
import 'child_env.dart';
import 'ask.dart';
import 'file_access.dart';
import 'tool.dart';

/// Builds the command that starts `kehai rpc` with the given options.
typedef EngineCommandBuilder =
    ({String executable, List<String> arguments}) Function(
      List<String> rpcArgs,
    );

/// The `agent` tool.
///
/// The call starts one job of kind `agent` whose process is a child
/// `kehai rpc --child` of the same executable. In the foreground it waits for
/// the job and answers with the child's typed result; with `background` it
/// answers with the job id and `job` takes over.
final class AgentTool implements Tool {
  /// Creates the tool.
  ///
  /// [engine] builds the child command (default: [engineCommand], which
  /// restarts the running `kehai`); [extraEnvironment] is added to the child's
  /// environment.
  AgentTool({this.engine, this.extraEnvironment = const {}});

  /// The child command builder, or null for [engineCommand].
  final EngineCommandBuilder? engine;

  /// Variables added to the child's environment.
  final Map<String, String> extraEnvironment;

  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    final jobs = context.jobs;
    final parentModel = context.model;
    if (jobs == null) return failure('agent is not available in this context');
    if (context.cancel.isCancelled) return _cancelled;

    final roleName = input['role']! as String;
    final prompt = input['prompt']! as String;
    final background = input['background'] == true;
    final deadline = Duration(
      seconds: switch (input['timeout_s']) {
        final int s => s,
        _ => defaultJobDeadline.inSeconds,
      },
    );

    final home =
        context.kehaiHome ??
        Directory(p.join(Directory.systemTemp.path, 'kehai-no-home'));
    final view = loadWorkspace(
      workspace: context.workspace.path,
      kehaiHome: home,
    );
    final role = view.role(roleName);
    if (role == null) {
      final names = [for (final r in view.roles) r.name];
      return _refused(
        'unknown agent role $roleName; '
        'roles: ${names.isEmpty ? 'none' : names.join(', ')}',
      );
    }
    if (parentModel == null) {
      return failure('agent is not available in this context');
    }

    // D12: the role's model alias, else the parent's model.
    final (model, note) = switch (role.model) {
      null || 'inherit' => (parentModel, null),
      final alias => switch (context.config.agentModels[alias]) {
        final slug? => (slug, null),
        null => (
          parentModel,
          'model $alias is not configured; used $parentModel',
        ),
      },
    };

    final cwd = realPath(context.workspace.path) ?? context.workspace.path;
    final environment = {
      ...shellEnvironment(
        Platform.environment,
        passthrough: context.config.envPassthrough,
      ),
      // The child must open the same home, whatever the parent's default was.
      if (context.kehaiHome case final h?) homeVariable: h.path,
      ...extraEnvironment,
    };
    final parentSession = jobs.store.sessionDir.path;

    // Set once `start` returned; the launcher only runs after that, because
    // the supervisor reserves the job before it awaits anything.
    String? jobId;
    // Ends with the job: its open relayed prompts are withdrawn (design D10).
    final relayEnd = CancelToken();
    late final AgentRun agentRun;
    agentRun = AgentRun(
      role: role.name,
      prompt: prompt,
      modelNote: note,
      unmapped: role.unmapped,
      onPrompt: (item) => unawaited(
        _relay(context, agentRun, role.name, jobId!, relayEnd, item),
      ),
      onWithdraw: (key) => context.prompts?.withdraw('${jobId!}.$key'),
      onProgress: (line) => context.progress('agent', line),
      onStop: relayEnd.cancel,
    );
    final request = JobRequest(
      kind: JobKind.agent,
      cmd: role.name,
      cwd: cwd,
      deadline: deadline,
      call: context.callKey,
      channel: agentRun,
      launch: () async {
        final command = (engine ?? engineCommand)([
          '--child',
          '--parent',
          parentSession,
          '--job',
          jobId!,
          '--role',
          role.name,
          '--role-digest',
          role.digest,
          '--model',
          model,
          if (context.yolo) '--yolo',
        ]);
        // On POSIX the child leads its own group, so the supervisor can end
        // its process tree; its own jobs are found as its descendants.
        final setsid = Platform.isWindows ? null : context.shell?.shell?.setsid;
        final process = await startProcess(
          command.executable,
          command.arguments,
          workingDirectory: cwd,
          environment: environment,
          setsid: setsid,
          keepStdin: true,
        );
        return ShellProcess(process, groupKnown: setsid != null);
      },
    );

    final JobHandle handle;
    try {
      handle = jobs.start(request);
    } on TooManyLiveAgents catch (e) {
      return _refused(e.message);
    } on TooManyLiveJobs catch (e) {
      return _refused(e.message);
    }
    jobId = handle.id;
    unawaited(
      handle.result.then<void>((_) {}, onError: (Object _) {}).then((_) {
        relayEnd.cancel();
      }),
    );

    if (background) {
      return ToolOutcome(
        summary:
            'agent ${role.name} running as job ${handle.id}; '
            'use job(${handle.id})',
      );
    }

    final cancelled = Completer<void>();
    final detach = context.cancel.listen(() {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    try {
      final cancelFirst = await Future.any<bool>([
        handle.result.then((_) => false, onError: (Object _) => false),
        cancelled.future.then((_) => true),
      ]);
      if (cancelFirst) {
        // Only this call's own job is stopped. A child that already ended keeps
        // its own status; the call is cancelled all the same.
        await jobs.cancelJob(handle.id);
        return _cancelled;
      }
      return await _settled(context, role.name, await handle.result);
    } on Object catch (e) {
      return failure('job failed: $e');
    } finally {
      detach();
    }
  }

  /// Puts a child's prompt into the parent's prompt FIFO as `<job>.<key>`
  /// (design D10) and passes the answer back to the child.
  ///
  /// The prompt is withdrawn when [relayEnd] is cancelled, which is when the
  /// job is asked to stop or has ended; the child's own `withdraw` withdraws
  /// it too. A prompt that arrives after [relayEnd] is dropped. The call's
  /// own cancel token is not used: an interrupt reaches a prompt only through
  /// the cancellation of its foreground job.
  Future<void> _relay(
    ToolContext context,
    AgentRun run,
    String role,
    String jobId,
    CancelToken relayEnd,
    Map<String, Object?> item,
  ) async {
    if (relayEnd.isCancelled) return;
    final key = item['key'];
    final input = item['input'];
    final kind = switch (item['kind']) {
      'permission' => PromptKind.permission,
      'question' => PromptKind.question,
      _ => null,
    };
    final tool = item['tool'];
    if (key is! String || kind == null || tool is! String) return;
    final prompts = context.prompts;
    if (prompts == null || !prompts.hasAnswerer) {
      // Nobody to ask: a permission is refused, so the child goes on.
      if (kind == PromptKind.permission) run.answer(key, 'deny');
      return;
    }
    final fields = input is Map<String, Object?> ? input : <String, Object?>{};
    final choices = kind == PromptKind.permission
        ? const ['allow', 'deny']
        : [
            for (final c in (fields['choices'] as List<Object?>? ?? const []))
              if (c is String) c,
          ];
    final String? answer;
    try {
      answer = await prompts.open(
        PromptItem(
          key: '$jobId.$key',
          kind: kind,
          tool: tool,
          input: fields,
          agent: {'role': role, 'job': jobId},
        ),
        relayEnd,
        choices: choices,
        acceptText:
            kind == PromptKind.question &&
            (fields['allow_text'] as bool? ?? choices.isEmpty),
      );
    } on StateError {
      // The same child key twice: the first prompt stays the open one.
      return;
    }
    if (answer != null) run.answer(key, answer);
  }

  Future<ToolOutcome> _settled(
    ToolContext context,
    String role,
    JobResult result,
  ) async {
    final lost = result.storage;
    if (lost != null) {
      return ToolOutcome(
        status: ResultStatus.error,
        summary: 'storage failure',
        complete: false,
        failed: true,
        reason: result.reason,
        storage: lost,
      );
    }
    final stream = result.streams[resultStream];
    final descriptor = stream?.descriptor;
    final complete = stream?.complete ?? false;
    final status = result.agent?['status'];
    switch (result.state) {
      case 'settled' || 'cancelled':
        final reason = result.reason ?? 'cancelled';
        return ToolOutcome(
          status: switch (status) {
            'done' => ResultStatus.ok,
            'timeout' => ResultStatus.timeout,
            _ => ResultStatus.error,
          },
          summary: switch (status) {
            'done' || 'failed' => 'agent $role $status',
            'timeout' => 'agent $role reached its deadline and was terminated',
            _ when result.state == 'cancelled' =>
              'agent $role cancelled: $reason',
            _ => 'agent $role ended',
          },
          complete: complete,
          result: descriptor,
        );
      default:
        final reason = result.reason ?? 'unknown';
        if (descriptor == null) {
          // No typed result was stored (the process never started): the
          // failure is the result.
          await context.output.writeText('agent failed to start: $reason');
        }
        return ToolOutcome(
          status: ResultStatus.error,
          summary: reason,
          complete: false,
          result: descriptor,
          failed: true,
          reason: reason,
        );
    }
  }

  ToolOutcome _refused(String message) => ToolOutcome(
    status: ResultStatus.error,
    summary: message,
    complete: false,
    failed: true,
  );

  static const ToolOutcome _cancelled = ToolOutcome(
    status: ResultStatus.error,
    summary: 'cancelled',
    complete: false,
  );
}
