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
import '../results/composer.dart';
import '../shell/launch.dart';
import '../workspace/inventory.dart';
import 'child_env.dart';
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
    final request = JobRequest(
      kind: JobKind.agent,
      cmd: role.name,
      cwd: cwd,
      deadline: deadline,
      call: context.callKey,
      channel: AgentRun(role: role.name, prompt: prompt, modelNote: note),
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
        final process = await startProcess(
          command.executable,
          command.arguments,
          workingDirectory: cwd,
          environment: environment,
          keepStdin: true,
        );
        return ShellProcess(process, groupKnown: false);
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
