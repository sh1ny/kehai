/// The `bash` tool (design D6, D7, D8): a command runs as a supervised job and
/// the call waits for it up to the foreground budget.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../jobs/supervisor.dart';
import '../permissions/workspace_paths.dart';
import '../results/composer.dart';
import '../results/result_store.dart';
import '../shell/detect.dart';
import '../shell/direct_exec.dart';
import '../shell/launch.dart';
import '../shell/proof.dart';
import 'child_env.dart';
import 'file_access.dart';
import 'tool.dart';

/// The foreground budget when the call names none.
const Duration defaultForegroundBudget = Duration(seconds: 120);

/// The `bash` tool.
final class BashTool implements Tool {
  /// Creates the tool.
  const BashTool();

  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    final detection = context.shell;
    final jobs = context.jobs;
    if (detection == null || jobs == null) {
      return failure('bash is not available in this context');
    }
    final shell = detection.shell;
    if (shell == null) return failure(detection.failure!);
    if (context.cancel.isCancelled) return _cancelled(shell);

    final command = input['command']! as String;
    final budget = switch (input['timeout_s']) {
      final int s => Duration(seconds: s),
      _ => defaultForegroundBudget,
    };
    final deadline = switch (input['deadline_s']) {
      final int s => Duration(seconds: s),
      _ => defaultJobDeadline,
    };
    final cwd = _workingDirectory(context, input['cwd']);
    if (!Directory(cwd).existsSync()) return failure('no such directory $cwd');

    final environment = Platform.environment;
    final passthrough = context.config.envPassthrough;
    final passing = passedThrough(environment, passthrough);
    final note = passing.isEmpty ? '' : '; passing ${passing.join(', ')}';
    final tag = ' (${shell.name})';

    final JobRequest request;
    try {
      request = _request(
        context,
        shell,
        command,
        cwd,
        deadline,
        environment,
        passthrough,
      );
    } on _Refused catch (e) {
      return failure('${e.message}$tag');
    }

    final JobHandle handle;
    try {
      handle = jobs.start(request);
    } on TooManyLiveJobs catch (e) {
      // The call settles `failed` with the bound message; nothing started.
      return ToolOutcome(
        status: ResultStatus.error,
        summary: e.message,
        complete: false,
        failed: true,
      );
    }

    var finished = false;
    final done = handle.result.whenComplete(() => finished = true);
    final budgetTimer = Completer<void>();
    final timer = Timer(budget, budgetTimer.complete);
    final cancelled = Completer<void>();
    final detach = context.cancel.listen(() {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    try {
      final first = await Future.any<int>([
        done.then((_) => 0, onError: (Object _) => 0),
        budgetTimer.future.then((_) => 1),
        cancelled.future.then((_) => 2),
      ]);
      if (first == 2) {
        // Only this call's own foreground job is stopped; jobs handed off by
        // earlier calls are not touched.
        await jobs.cancelJob(handle.id);
        return _cancelled(shell);
      }
      if (first == 1 && !finished) {
        return await _handOff(context, jobs, handle, tag, note);
      }
      return await _settled(await handle.result, tag, note);
    } on Object catch (e) {
      return failure('job failed: $e$tag');
    } finally {
      timer.cancel();
      detach();
    }
  }

  String _workingDirectory(ToolContext context, Object? cwd) {
    final root = realPath(context.workspace.path) ?? context.workspace.path;
    if (cwd is! String) return root;
    // The gate and the read-only proof resolve a `..` after a link against
    // the link's target; the directory bash runs in must be that one.
    final joined = p.join(root, cwd);
    return realPath(joined) ??
        (p.style == p.Style.windows ? p.normalize(joined) : joined);
  }

  JobRequest _request(
    ToolContext context,
    ShellInfo shell,
    String command,
    String cwd,
    Duration deadline,
    Map<String, String> environment,
    Iterable<String> passthrough,
  ) {
    final by = context.permission?['by'];
    final root = realPath(context.workspace.path) ?? context.workspace.path;
    if (by == 'builtin' || by == 'user') {
      // An autoapproved command runs without a shell: what the gate proved
      // (or the user's rule matched) is exactly the argv that runs.
      final List<String> argv;
      final String directCwd;
      if (by == 'builtin') {
        final rawCwd = p.relative(cwd, from: root);
        final proven = proveReadOnly(command, workspaceRoot: root, cwd: rawCwd);
        if (proven == null || !p.equals(proven.cwd, cwd)) {
          throw const _Refused('command is no longer proven read-only');
        }
        argv = proven.argv;
        directCwd = proven.cwd;
      } else {
        final tokens = tokenizeSimple(command);
        if (tokens == null) {
          throw const _Refused('command is not a simple command');
        }
        argv = tokens;
        directCwd = cwd;
      }
      return JobRequest(
        kind: JobKind.shell,
        cmd: command,
        cwd: directCwd,
        deadline: deadline,
        call: context.callKey,
        launch: () async {
          try {
            final process = await startDirect(
              argv,
              cwd: directCwd,
              workspaceRoot: root,
              environment: environment,
              passthrough: passthrough,
              setsid: shell.setsid,
            );
            return ShellProcess(
              process,
              groupKnown: !Platform.isWindows && shell.setsid != null,
            );
          } on DirectExecRefused catch (e) {
            throw ProcessException(
              argv.first,
              argv.skip(1).toList(),
              e.message,
            );
          }
        },
      );
    }
    return JobRequest.shell(
      shell,
      command,
      cwd: cwd,
      environment: shellEnvironment(environment, passthrough: passthrough),
      call: context.callKey,
      deadline: deadline,
    );
  }

  Future<ToolOutcome> _handOff(
    ToolContext context,
    JobSupervisor jobs,
    JobHandle handle,
    String tag,
    String note,
  ) async {
    final summary =
        'still running as job ${handle.id}; use job(${handle.id})$tag$note';
    final snapshot = await jobs.snapshot(handle.id, 'output');
    switch (snapshot) {
      case ResultComplete(:final descriptor):
        return ToolOutcome(
          status: ResultStatus.partial,
          summary: summary,
          complete: false,
          result: descriptor,
        );
      case null:
        // The job ended or has no spool yet.
        final result = await _endedOrEmpty(jobs, handle);
        if (result != null) return _settled(result, tag, note);
        return ToolOutcome(
          status: ResultStatus.partial,
          summary: summary,
          complete: false,
        );
      default:
        return ToolOutcome(
          status: ResultStatus.partial,
          summary: summary,
          complete: false,
        );
    }
  }

  Future<JobResult?> _endedOrEmpty(JobSupervisor jobs, JobHandle handle) async {
    if (jobs.whenDone(handle.id) == null) return handle.result;
    return null;
  }

  Future<ToolOutcome> _settled(
    JobResult result,
    String tag,
    String note,
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
    final stream = result.streams['output'];
    final descriptor = stream?.descriptor;
    final whole = stream?.complete ?? false;
    switch (result.state) {
      case 'settled':
        final code = result.exit;
        final signal = code != null && code < 0 ? ' (signal ${-code})' : '';
        return ToolOutcome(
          status: code == 0 ? ResultStatus.ok : ResultStatus.error,
          summary: 'exit ${code ?? '?'}$signal$tag$note',
          complete: whole,
          result: descriptor,
        );
      case 'cancelled':
        final reason = result.reason ?? 'cancelled';
        final cleanup = result.cleanup;
        final unproven = cleanup != null && cleanup.startsWith('uncertain')
            ? '; cleanup $cleanup'
            : '';
        return ToolOutcome(
          status: reason == 'deadline'
              ? ResultStatus.timeout
              : ResultStatus.error,
          summary: reason == 'deadline'
              ? 'job reached its deadline and was terminated$tag$note$unproven'
              : 'job cancelled: $reason$tag$note$unproven',
          complete: false,
          result: descriptor,
        );
      default:
        return ToolOutcome(
          status: ResultStatus.error,
          summary: 'failed to start: ${result.reason ?? 'unknown'}$tag$note',
          complete: false,
          result: descriptor,
          failed: true,
          reason: result.reason,
        );
    }
  }

  ToolOutcome _cancelled(ShellInfo shell) => ToolOutcome(
    status: ResultStatus.error,
    summary: 'cancelled (${shell.name})',
    complete: false,
  );
}

/// A command that cannot be started as the gate approved it.
final class _Refused implements Exception {
  const _Refused(this.message);

  final String message;
}
