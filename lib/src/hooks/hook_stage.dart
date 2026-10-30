/// User-configured pre-tool hooks (design D14).
///
/// A hook is a `hook` job started like any other process (design D7, D8): its
/// argv runs directly, the call goes to its stdin as one JSON object and stdin
/// is then closed. The deadline is the job's own, enforced by the supervisor's
/// termination (design D10), so a hook that hangs or ignores SIGTERM cannot
/// hold the call past the deadline plus the kill grace.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../jobs/supervisor.dart';
import '../provider/provider.dart';
import '../config/user_config.dart';
import '../results/result_store.dart';
import '../shell/launch.dart';
import '../tools/tool.dart';

/// The most bytes of a hook's stderr used as a denial reason.
const int maxHookReasonBytes = 8192;

/// Runs the configured hooks of a call, in configuration order.
///
/// Exit 0 lets the call go on to the permission decision (it never approves).
/// Exit 2 denies under either policy, with the hook's stderr as the reason.
/// Any other exit, a crash, a launch failure or the deadline is ignored for an
/// `optional` hook, with a diag note, and denies for a `deny` hook.
final class HookStage implements CallStage {
  /// Creates the stage.
  ///
  /// [environment] is the complete child environment, [workspace] the root
  /// the hooks run in and [session] gives the session id. [setsid] is the
  /// detected `setsid` on POSIX hosts; without it a hook's process group is
  /// not known and its termination is `uncertain`.
  HookStage({
    required this.hooks,
    required this.jobs,
    required this.store,
    required this.workspace,
    required this.environment,
    required this.session,
    this.setsid,
  });

  /// The hooks, in configuration order.
  final List<HookConfig> hooks;

  /// The supervisor every hook job runs in.
  final JobSupervisor jobs;

  /// The result store of the session.
  final ResultStore store;

  /// The workspace root, the working directory of every hook.
  final String workspace;

  /// The complete environment of a hook process.
  final Map<String, String> environment;

  /// The session id, as `meta/session` holds it.
  final Object? Function() session;

  /// The detected `setsid`, or null.
  final String? setsid;

  @override
  Future<StageOutcome> check(StageCall call, CancelToken cancel) async {
    final applicable = [
      for (final hook in hooks)
        if (hook.tools.contains(call.tool)) hook,
    ];
    if (applicable.isEmpty) return const StageOutcome.proceed();
    final payload = utf8.encode(
      jsonEncode({
        'tool': call.tool,
        'input': call.input,
        'workspace': workspace,
        'session': session(),
      }),
    );
    final records = <Map<String, Object?>>[];
    final diag = <(String, String)>[];
    for (final hook in applicable) {
      if (cancel.isCancelled) break;
      final run = await _run(hook, call, payload, cancel);
      records.add(run.record);
      diag.addAll(run.diag);
      final reason = run.denyReason;
      if (reason != null) {
        return StageOutcome.deny(reason, record: records, diag: diag);
      }
    }
    return StageOutcome.proceed(record: records, diag: diag);
  }

  Future<_Run> _run(
    HookConfig hook,
    StageCall call,
    List<int> payload,
    CancelToken cancel,
  ) async {
    final JobHandle handle;
    try {
      handle = jobs.start(
        JobRequest(
          kind: JobKind.hook,
          // The argv may carry secrets; the tree gets the name only.
          cmd: 'hook:${hook.name}',
          cwd: workspace,
          call: call.callKey,
          deadline: hook.timeout,
          launch: () async {
            final process = await startProcess(
              hook.argv.first,
              hook.argv.skip(1).toList(),
              workingDirectory: workspace,
              environment: environment,
              setsid: Platform.isWindows ? null : setsid,
              input: payload,
            );
            return ShellProcess(
              process,
              groupKnown: !Platform.isWindows && setsid != null,
            );
          },
        ),
      );
    } on TooManyLiveJobs catch (e) {
      return _failed(hook, null, 'could not start: ${e.message}');
    }
    final detach = cancel.listen(() {
      unawaited(
        jobs.cancelJob(handle.id).then<void>((_) {}, onError: (Object _) {}),
      );
    });
    final JobResult? result;
    try {
      // The call waits no longer than the deadline plus the kill grace; the
      // termination, the drain and the job's settle finish in the background.
      result = await handle.result
          .then<JobResult?>((r) => r)
          .timeout(hook.timeout + jobs.timings.grace, onTimeout: () => null);
    } finally {
      detach();
    }
    if (result == null) {
      // The job may still be reserved or launching (admission, spools and the
      // launch run before its own deadline starts). Cancel it, so a launch
      // still in flight is stopped at once and the hook never outlives the
      // stage.
      unawaited(
        jobs
            .cancelJob(handle.id, reason: 'deadline')
            .then<void>((_) {}, onError: (Object _) {}),
      );
      return _failed(
        hook,
        handle.id,
        'timed out after ${hook.timeout.inMilliseconds} ms',
      );
    }

    switch (result.state) {
      case 'settled':
        final code = result.exit;
        if (code == 0) return _Run(hook, handle.id, 'allowed');
        if (code == 2) {
          return _Run(
            hook,
            handle.id,
            'denied',
            denyReason: 'hook ${hook.name}: ${await _stderr(result)}',
          );
        }
        return _failed(
          hook,
          handle.id,
          code == null
              ? 'ended without an exit code'
              : code < 0
              ? 'was killed by signal ${-code}'
              : 'exited $code',
        );
      case 'cancelled':
        return result.reason == 'deadline'
            ? _failed(
                hook,
                handle.id,
                'timed out after ${hook.timeout.inMilliseconds} ms',
              )
            : _failed(hook, handle.id, 'was cancelled (${result.reason})');
      default:
        return _failed(
          hook,
          handle.id,
          result.storage != null
              ? 'failed: ${result.reason}'
              : 'failed to start: ${result.reason ?? 'unknown'}',
        );
    }
  }

  /// A hook that gave no answer: ignored when optional, a denial otherwise.
  _Run _failed(HookConfig hook, String? job, String what) {
    if (hook.policy == HookPolicy.optional) {
      return _Run(
        hook,
        job,
        'ignored',
        diag: [('hook:${hook.name}', '$what; ignored')],
      );
    }
    return _Run(hook, job, 'denied', denyReason: 'hook ${hook.name} $what');
  }

  /// The stderr of a finished hook, trimmed, cut at [maxHookReasonBytes].
  Future<String> _stderr(JobResult result) async {
    const none = 'denied with no reason given';
    final descriptor = result.streams['stderr']?.descriptor;
    if (descriptor == null || descriptor.bytes == 0) return none;
    try {
      final file = File(
        p.join(store.sessionDir.path, resultsDirName, descriptor.sha256),
      );
      final bytes = <int>[];
      await for (final chunk in file.openRead(0, maxHookReasonBytes)) {
        bytes.addAll(chunk);
      }
      final text = utf8.decode(bytes, allowMalformed: true).trim();
      if (text.isEmpty) return none;
      return descriptor.bytes > maxHookReasonBytes ? '$text...' : text;
    } on FileSystemException {
      return none;
    }
  }
}

final class _Run {
  _Run(
    HookConfig hook,
    String? job,
    String outcome, {
    this.denyReason,
    this.diag = const [],
  }) : record = {'name': hook.name, 'job': ?job, 'outcome': outcome};

  final Map<String, Object?> record;
  final String? denyReason;
  final List<(String, String)> diag;
}
