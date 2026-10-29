// The killed-engine fixture of the job tests.
//
// usage: run_job_then_wait.dart <root> <mode> [<pause point>]
//
// Creates a session under <root>, starts one job and prints
// `READY <pid> <job pid> <job id> <session dir>` once the job is in the state
// the mode names (or its handoff reached the pause point), then waits until
// it is killed. A pause point parks the job's handoff for good, so the kill
// lands exactly there.
//
// Modes:
//   quick     `out` on stdout and `err` on stderr; the job exits by itself
//             after the session reached turn 5 (the job started in turn 3).
//   hang      prints `started`, then sleeps; ready once `started` is spooled.
//   lines     prints 300 lines, then sleeps; ready once all are spooled.
//   cancel    like hang, then cancels the job (`user`); parks at the point.
//   deadline  like hang with a 1 s deadline; parks at the point.
//   bash      a `bash` call through the tool runtime that runs like hang and
//             appends a line to `<root>/count` first; ready once the call and
//             its job both read `running` and `started` is spooled.
//
// Pause points: beforeIntent, afterIntent, afterStdout, afterPublish,
// afterRegister, beforeClear.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  // Keep the isolate alive until the parent kills the process.
  Timer.periodic(const Duration(hours: 1), (_) {});
  final root = Directory(args[0]);
  final mode = args[1];
  final point = args.length > 2 ? args[2] : 'none';
  final shell = detectShell().shell!;
  final cwd = p.join(root.path, 'work').replaceAll(r'\', '/');
  Directory(cwd).createSync(recursive: true);

  var jobPid = 0;
  var jobId = '-';
  late SessionWriter writer;
  late String ready;

  Future<void> announce() async {
    stdout.writeln('READY $pid $jobPid $jobId ${writer.sessionDir.path}');
    await stdout.flush();
  }

  Future<void> park(String name) async {
    if (point != name) return;
    await announce();
    await Completer<void>().future;
  }

  final hooks = JobHooks(
    beforeIntent: (_) => park('beforeIntent'),
    afterIntent: (_) => park('afterIntent'),
    afterStreamPublish: (_, stream) =>
        stream == 'stdout' ? park('afterStdout') : Future<void>.value(),
    afterPublish: (_) => park('afterPublish'),
    afterRegister: (_) => park('afterRegister'),
    beforeClear: (_) => park('beforeClear'),
  );

  JobLauncher capture(String command) => () async {
    final started = await startShell(
      shell,
      command,
      workingDirectory: cwd,
      environment: Platform.environment,
    );
    jobPid = started.process.pid;
    return started;
  };

  JobRequest request(String command, {Duration? deadline}) => JobRequest(
    kind: JobKind.shell,
    cmd: command,
    cwd: cwd,
    shell: shell.name,
    deadline: deadline ?? const Duration(seconds: 60),
    launch: capture(command),
  );

  writer = await SessionWriter.create(root);
  final store = ResultStore(writer.sessionDir);
  Object? at(String path) => writer.tree.get(SessionPath.parse(path));

  Future<void> until(bool Function() condition) async {
    while (!condition()) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  int spoolLines() {
    final results = Directory(p.join(writer.sessionDir.path, 'results'));
    if (!results.existsSync()) return 0;
    var most = 0;
    for (final file in results.listSync().whereType<File>()) {
      if (!p.basename(file.path).endsWith('-output')) continue;
      final lines = '\n'.allMatches(file.readAsStringSync()).length;
      if (lines > most) most = lines;
    }
    return most;
  }

  for (var turn = 1; turn <= 3; turn++) {
    await writer.apply(
      JournalRecord(turn: turn, path: 'body/marker', op: Op.set, value: turn),
    );
  }

  if (mode == 'bash') {
    final tool = _Bash(request, (id) => jobId = id);
    final runtime = await ToolRuntime.attach(
      writer,
      store,
      workspace: root,
      tools: {'bash': tool},
      gate: const AllowAllStage(),
      jobHooks: hooks,
    );
    final command =
        "echo run >> '${p.join(root.path, 'count').replaceAll(r'\', '/')}'; "
        'echo started; sleep 30';
    unawaited(
      runtime
          .run(
            ToolCall(
              callId: 'call-1',
              name: 'bash',
              argumentsJson: jsonEncode({'command': command}),
            ),
          )
          .then<void>((_) {}, onError: (Object _) {}),
    );
    await until(
      () =>
          (at('body/calls/${callKey('call-1')}')
                  as Map<String, Object?>?)?['status'] ==
              'running' &&
          (at('jobs/$jobId') as Map<String, Object?>?)?['state'] == 'running' &&
          spoolLines() >= 1,
    );
    ready = 'bash';
    await announce();
    await Completer<void>().future;
  }

  final supervisor = JobSupervisor(writer, store, hooks: hooks);
  final go = p.join(root.path, 'go').replaceAll(r'\', '/');
  final command = switch (mode) {
    'quick' =>
      "echo out; echo err 1>&2; while [ ! -e '$go' ]; do sleep 0.05; done",
    'lines' =>
      'i=0; while [ \$i -lt 300 ]; do echo line\$i; i=\$((i+1)); done; '
          'sleep 30',
    _ => 'echo started; sleep 30',
  };
  final handle = supervisor.start(
    request(
      command,
      deadline: mode == 'deadline' ? const Duration(seconds: 1) : null,
    ),
  );
  jobId = handle.id;
  ready = mode;
  await until(() => (at('jobs/$jobId') as Map?)?['state'] == 'running');
  if (mode == 'quick') {
    for (var turn = 4; turn <= 5; turn++) {
      await writer.apply(
        JournalRecord(turn: turn, path: 'body/marker', op: Op.set, value: turn),
      );
    }
    File(go).writeAsStringSync('');
  } else {
    await until(() => spoolLines() >= (mode == 'lines' ? 300 : 1));
    if (mode == 'cancel') unawaited(supervisor.cancelJob(jobId));
  }
  if (point == 'none' && mode != 'deadline') {
    await announce();
  }
  await handle.result.then<void>((_) {}, onError: (Object _) {});
  // Only reached when the job ended without parking at a point.
  assert(ready.isNotEmpty);
  stdout.writeln('ENDED');
  await stdout.flush();
  await Completer<void>().future;
}

/// A `bash` stand-in that runs its command as a supervised job with the
/// call's key, so the fixture knows the process id.
final class _Bash implements Tool {
  _Bash(this._request, this._onJob);

  final JobRequest Function(String command) _request;
  final void Function(String id) _onJob;

  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    final base = _request(input['command']! as String);
    final handle = context.jobs!.start(
      JobRequest(
        kind: base.kind,
        cmd: base.cmd,
        cwd: base.cwd,
        shell: base.shell,
        call: context.callKey,
        deadline: base.deadline,
        launch: base.launch,
      ),
    );
    _onJob(handle.id);
    await handle.result;
    return const ToolOutcome(summary: 'done');
  }
}
