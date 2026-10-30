/// The `job` tool (job-supervisor spec, "Job tool"): inspect, wait for, read
/// the output of, or cancel a background job.
library;

import 'dart:async';

import '../jobs/supervisor.dart';
import '../results/composer.dart';
import '../results/handles.dart';
import '../results/result_store.dart';
import '../session/path.dart';
import 'file_access.dart';
import 'tool.dart';

/// How long `wait` waits when the call names no `timeout_s`.
const Duration defaultJobWait = Duration(seconds: 60);

const Set<String> _terminal = {'settled', 'failed', 'cancelled'};

/// The `job` tool.
final class JobTool implements Tool {
  /// Creates the tool.
  const JobTool();

  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    final jobs = context.jobs;
    if (jobs == null) return failure('job is not available in this context');
    final id = input['id']! as String;
    final node = _node(jobs, id);
    if (node == null && jobs.whenDone(id) == null) {
      return failure('unknown job $id');
    }
    return switch (input['action']) {
      'status' => _status(context, jobs, id),
      'wait' => _wait(context, jobs, id, input['timeout_s']),
      'output' => _output(jobs, id),
      _ => _cancel(context, jobs, id),
    };
  }

  Map<String, Object?>? _node(JobSupervisor jobs, String id) {
    final node = jobs.writer.tree.get(SessionPath.parse('jobs/$id'));
    return node is Map<String, Object?> ? node : null;
  }

  Future<ToolOutcome> _status(
    ToolContext context,
    JobSupervisor jobs,
    String id,
  ) async {
    final node = _node(jobs, id);
    if (node == null) return failure('unknown job $id');
    final state = node['state'] as String? ?? 'unknown';
    final exit = node['exit'];
    final summary = _terminal.contains(state)
        ? '$state${exit is int ? ', exit $exit' : ''}'
        : state;
    await context.output.writeText(_describe(jobs, id, node));
    return ToolOutcome(summary: 'job $id: $summary');
  }

  String _describe(JobSupervisor jobs, String id, Map<String, Object?> node) {
    final out = StringBuffer('job $id\n');
    void line(String name, Object? value) {
      if (value != null) out.writeln('$name: $value');
    }

    line('state', node['state']);
    line('exit', node['exit']);
    line('reason', node['reason']);
    line('cleanup', node['cleanup']);
    line('signal', node['signal']);
    line('kind', node['kind']);
    line('shell', node['shell']);
    line('cwd', node['cwd']);
    line('cmd', node['cmd']);
    line('started', node['started']);
    line('ended', node['ended']);
    final started = DateTime.tryParse('${node['started']}');
    final ended = DateTime.tryParse('${node['ended']}') ?? DateTime.now();
    if (started != null) {
      final seconds = ended.difference(started).inMilliseconds / 1000;
      line('runtime', '${seconds.toStringAsFixed(1)}s');
    }
    final ref = node['output'];
    if (ref is Map<String, Object?> && ref['handle'] is String) {
      try {
        final resolved = resolveHandle(
          jobs.writer.tree,
          jobs.store.sessionDir,
          ref['handle']! as String,
        );
        line('output', '${resolved.descriptor.bytes} bytes');
        line('output handle', resolved.descriptor.handle);
      } on Object {
        line('output', 'unavailable');
      }
    } else if (!_terminal.contains(node['state'])) {
      line('output', 'in progress; use action output for a snapshot');
    }
    return out.toString();
  }

  Future<ToolOutcome> _wait(
    ToolContext context,
    JobSupervisor jobs,
    String id,
    Object? timeout,
  ) async {
    final limit = timeout is int ? Duration(seconds: timeout) : defaultJobWait;
    final done = jobs.whenDone(id);
    if (done != null) {
      final ended = Completer<void>();
      void end() {
        if (!ended.isCompleted) ended.complete();
      }

      final detach = context.cancel.listen(end);
      // A cancellable timer: a wait that ends early must not leave its limit
      // running, which would keep the isolate alive after close.
      final timer = Timer(limit, end);
      unawaited(done.then<void>((_) => end(), onError: (Object _) => end()));
      try {
        await ended.future;
      } finally {
        timer.cancel();
        detach();
      }
    }
    return _status(context, jobs, id);
  }

  Future<ToolOutcome> _output(JobSupervisor jobs, String id) async {
    final snapshot = await jobs.snapshot(id, 'output');
    switch (snapshot) {
      case ResultComplete(:final descriptor):
        return ToolOutcome(
          summary: 'job $id is running; output so far',
          complete: false,
          result: descriptor,
          policy: ResultPolicy.bash,
        );
      case ResultProducerFailed() || ResultStorageFailed():
        return failure('job $id output could not be stored');
      case null:
        break;
    }
    final node = _node(jobs, id);
    final ref = node?['output'];
    final reason = node?['reason'];
    if (node?['state'] == 'failed' &&
        reason is String &&
        reason.startsWith('storage: ')) {
      return failure('job $id output unavailable: $reason');
    }
    if (node == null || ref is! Map<String, Object?>) {
      return ToolOutcome(summary: 'job $id has no output yet', complete: false);
    }
    try {
      final resolved = resolveHandle(
        jobs.writer.tree,
        jobs.store.sessionDir,
        ref['handle']! as String,
      );
      final whole = ref['complete'] == true;
      return ToolOutcome(
        summary:
            'job $id ${node['state']}; ${whole ? 'full' : 'partial'} '
            'output',
        complete: whole,
        result: resolved.descriptor,
        policy: ResultPolicy.bash,
      );
    } on Object catch (e) {
      return failure('job $id output unavailable: $e');
    }
  }

  Future<ToolOutcome> _cancel(
    ToolContext context,
    JobSupervisor jobs,
    String id,
  ) async {
    final node = _node(jobs, id);
    if (node != null && _terminal.contains(node['state'])) {
      return ToolOutcome(summary: 'job $id already ${node['state']}');
    }
    final outcome = await jobs.cancelJob(id);
    switch (outcome) {
      case JobCancelled(:final result):
        // The cancel result reports whether the process tree is proven gone.
        final cleanup = result.cleanup;
        final summary =
            'job $id ${result.state}'
            '${result.reason == null ? '' : ' (${result.reason})'}'
            '${cleanup == null ? '' : '; cleanup $cleanup'}';
        final lines = [
          summary,
          'state: ${result.state}',
          if (result.reason != null) 'reason: ${result.reason}',
          if (cleanup != null) 'cleanup: $cleanup',
        ];
        await context.output.writeText('${lines.join('\n')}\n');
        return ToolOutcome(summary: summary);
      case JobAlreadyExited():
        return ToolOutcome(summary: outcome.message);
      case JobNotLive():
        return failure('job $id is not running in this session');
    }
  }
}
