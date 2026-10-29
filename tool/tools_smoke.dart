/// Acceptance driver for the core tools (change core-tools, tasks 12.2, 12.3).
///
/// ```sh
/// dart run tool/tools_smoke.dart              # 12.2: the agent acceptance run
/// dart run tool/tools_smoke.dart --hung-hook  # 12.3: a hung optional hook
/// ```
///
/// Run it from the repository root. It drives a real `ToolRuntime` over this
/// repository, with `--yolo` off (the permission gate prompts) and a scripted
/// answerer that approves every permission prompt and picks the second choice
/// of a question. The repository is never modified: the file it edits lives in
/// a scratch directory, and the session and the Kehai home are scratch too.
/// Every prompt and every composed output is printed. Exits 1 when a check
/// fails.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;

/// How long the call after a hung hook may take.
const Duration _proceedBound = Duration(seconds: 3);

/// The hook deadline, as in the spec's scenario.
const Duration _hookTimeout = Duration(milliseconds: 500);

/// After the hook deadline, the job's drain: 2 s, then 2 s more, then the
/// probe of 1 s (design D8 and D10).
const Duration _drainBound = Duration(seconds: 5);

final List<String> _failures = [];

void _check(bool ok, String what) {
  stdout.writeln('check ${ok ? 'ok  ' : 'FAIL'} $what');
  if (!ok) _failures.add(what);
}

/// Answers prompts like a user who agrees to everything and picks the
/// second choice of a question.
final class _ScriptedAnswerer implements Answerer {
  late ToolRuntime runtime;
  final List<String> asked = [];

  @override
  void prompt(PromptItem item) {
    final input = jsonEncode(item.input);
    final answer = switch (item.kind) {
      PromptKind.permission => 'allow',
      PromptKind.question =>
        (item.input['choices'] as List<Object?>).last! as String,
    };
    asked.add('${item.kind.name} ${item.tool}');
    stdout.writeln(
      'asked  ${item.kind.name} ${item.tool} $input -> answered $answer',
    );
    scheduleMicrotask(() => runtime.prompts.reply(item.key, answer));
  }

  @override
  void withdraw(String key) => stdout.writeln('withdrawn $key');
}

Future<void> main(List<String> args) async {
  final hung = args.contains('--hung-hook');
  if (args.any((a) => a != '--hung-hook')) {
    stderr.writeln('usage: dart run tool/tools_smoke.dart [--hung-hook]');
    exitCode = 64;
    return;
  }
  final repo = Directory.current;
  if (!File(p.join(repo.path, 'pubspec.yaml')).existsSync() ||
      !Directory(p.join(repo.path, 'lib', 'src', 'tools')).existsSync()) {
    stderr.writeln('run it from the repository root');
    exitCode = 64;
    return;
  }

  final scratch = await Directory.systemTemp.createTemp('kehai_tools_smoke_');
  try {
    stdout.writeln('platform: ${Platform.operatingSystem}');
    stdout.writeln('repository: ${repo.path}');
    await _drive(repo, scratch, hung: hung);
  } finally {
    await scratch.delete(recursive: true);
  }
  if (_failures.isNotEmpty) {
    stdout.writeln('FAILED: ${_failures.length} check(s)');
    exitCode = 1;
  } else {
    stdout.writeln('PASSED');
  }
}

Future<void> _drive(
  Directory repo,
  Directory scratch, {
  required bool hung,
}) async {
  final sessions = Directory(p.join(scratch.path, 'sessions'))..createSync();
  final home = Directory(p.join(scratch.path, 'home'))..createSync();
  final pidFile = p.join(scratch.path, 'hook.pid');

  final config = hung
      ? UserConfig(
          hooks: [
            HookConfig(
              name: 'slow',
              argv: [
                Platform.resolvedExecutable,
                p.join(repo.path, 'test', 'fixtures', 'hang_forever.dart'),
                pidFile,
              ],
              tools: const ['read'],
              policy: HookPolicy.optional,
              timeout: _hookTimeout,
            ),
          ],
        )
      : const UserConfig();

  final writer = await SessionWriter.create(sessions);
  final store = ResultStore(writer.sessionDir);
  final answerer = _ScriptedAnswerer();
  final runtime = await ToolRuntime.attach(
    writer,
    store,
    workspace: repo,
    config: config,
    yolo: false,
    answerer: answerer,
    kehaiHome: home,
  );
  answerer.runtime = runtime;
  stdout.writeln(
    'shell: ${runtime.shell.shell?.name ?? 'none (${runtime.shell.failure})'}'
    '; yolo: off; hooks: ${config.hooks.length}',
  );

  var n = 0;
  Future<(String, Duration)> call(
    String name,
    Map<String, Object?> input,
  ) async {
    final id = 'smoke-${++n}';
    stdout.writeln('');
    stdout.writeln('=== call $id $name ${jsonEncode(input)}');
    final clock = Stopwatch()..start();
    final item = await runtime.run(
      ToolCall(callId: id, name: name, argumentsJson: jsonEncode(input)),
    );
    clock.stop();
    stdout.writeln(item.output);
    stdout.writeln('--- ${clock.elapsedMilliseconds} ms');
    return (item.output, clock.elapsed);
  }

  try {
    if (hung) {
      await _hungHook(runtime, repo, pidFile, call);
    } else {
      await _acceptance(repo, scratch, answerer, call);
    }
  } finally {
    await runtime.close();
    await writer.close();
  }
}

Future<void> _acceptance(
  Directory repo,
  Directory scratch,
  _ScriptedAnswerer answerer,
  Future<(String, Duration)> Function(String, Map<String, Object?>) call,
) async {
  // 1. read, then an anchored edit of a scratch file outside the repository.
  final file = File(p.join(scratch.path, 'scratch.txt'))
    ..writeAsStringSync([for (var i = 1; i <= 20; i++) 'line $i\n'].join());
  final path = file.path;

  final (read, _) = await call('read', {'path': path});
  _check(read.startsWith('[read ok]'), 'read settles ok');
  final anchor = RegExp(r'(?<![\w#])(1#[0-9A-Fa-f]+)')
      .firstMatch(read)
      ?.group(1);
  _check(anchor != null, 'read shows the anchor of block 1 ($anchor)');
  final anchors = [
    for (final m in RegExp(r'(?<![\w#])(\d+#[0-9A-Fa-f]+)').allMatches(read))
      m.group(1)!,
  ];

  final (edit, _) = await call('edit', {
    'path': path,
    'anchors': anchors,
    'ops': [
      {'op': 'replace', 'start': 3, 'end': 3, 'text': 'line 3 (edited)'},
    ],
  });
  _check(edit.startsWith('[edit ok]'), 'edit settles ok');
  _check(
    file.readAsLinesSync()[2] == 'line 3 (edited)',
    'the scratch file changed on disk',
  );

  // 2. bash: dart analyze, dart test, and the VCS status.
  final (analyze, _) = await call('bash', {
    'command': 'dart analyze',
    'timeout_s': 300,
  });
  _check(analyze.startsWith('[bash ok]'), 'dart analyze settles ok');
  final (test, _) = await call('bash', {
    'command': 'dart test test/smoke_test.dart',
    'timeout_s': 300,
  });
  _check(test.startsWith('[bash ok]'), 'dart test settles ok');
  // `jj status` where this checkout is a jj repository, else `git status`.
  final vcs = _onPath('jj') && Directory(p.join(repo.path, '.jj')).existsSync()
      ? 'jj status'
      : 'git status --short';
  final (status, _) = await call('bash', {'command': vcs, 'timeout_s': 60});
  _check(status.startsWith('[bash ok]'), '$vcs settles ok');

  // 3. grep and find over lib/.
  final (grep, _) = await call('grep', {
    'pattern': 'composeResult',
    'path': 'lib',
  });
  _check(grep.startsWith('[grep ok]'), 'grep settles ok');
  _check(grep.contains('lib/src/results/composer.dart'), 'grep finds composer');
  final (find, _) = await call('find', {
    'glob': 'src/tools/*.dart',
    'path': 'lib',
  });
  _check(find.startsWith('[find ok]'), 'find settles ok');
  _check(find.contains('lib/src/tools/roster.dart'), 'find lists the roster');

  // 4. ask, with two choices.
  final (ask, _) = await call('ask', {
    'question': 'Which one do you want?',
    'choices': ['first', 'second'],
  });
  _check(ask.startsWith('[ask ok]'), 'ask settles ok');
  _check(ask.contains('{"choice":"second"}'), 'ask returns the second choice');

  // The gate really prompted (yolo is off).
  _check(
    answerer.asked.contains('permission edit'),
    'the gate prompted for the edit',
  );
  _check(
    answerer.asked.contains('question ask'),
    'the question reached the answerer',
  );
}

Future<void> _hungHook(
  ToolRuntime runtime,
  Directory repo,
  String pidFile,
  Future<(String, Duration)> Function(String, Map<String, Object?>) call,
) async {
  final clock = Stopwatch()..start();

  // The first call carries the hook, which never exits.
  final (first, firstTime) = await call('read', {'path': 'pubspec.yaml'});
  _check(first.startsWith('[read ok]'), 'the call proceeded');
  _check(
    first.contains('[diag hook:slow] timed out after 500 ms; ignored'),
    'the hook is reported as timed out and ignored',
  );
  _check(
    firstTime < _proceedBound,
    'the hung hook call took ${firstTime.inMilliseconds} ms '
    '(bound ${_proceedBound.inMilliseconds} ms)',
  );

  // The next call is not delayed by the dead hook.
  final (next, nextTime) = await call('ls', {'path': 'lib'});
  _check(next.startsWith('[ls ok]'), 'the next call proceeded');
  _check(
    nextTime < _proceedBound,
    'the next call took ${nextTime.inMilliseconds} ms '
    '(bound ${_proceedBound.inMilliseconds} ms)',
  );

  // The hook job settles within the drain bound.
  final bound = _hookTimeout + _drainBound;
  while (runtime.jobs.liveCount > 0 && clock.elapsed < bound * 2) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  final settled = clock.elapsed;
  stdout.writeln('');
  stdout.writeln(
    'hook job settled ${settled.inMilliseconds} ms after the first call '
    'started (deadline ${_hookTimeout.inMilliseconds} ms, bound '
    '${bound.inMilliseconds} ms)',
  );
  _check(runtime.jobs.liveCount == 0, 'no job is live');
  _check(settled <= bound, 'the hook job settled within the drain bound');

  final jobs = runtime.writer.tree.get(SessionPath.parse('jobs'));
  final nodes = jobs is Map<String, Object?> ? jobs.values : const <Object?>[];
  final hook = nodes.whereType<Map<String, Object?>>().singleOrNull;
  stdout.writeln(
    'hook job node: kind ${hook?['kind']}, state ${hook?['state']}, '
    'reason ${hook?['reason']}, cleanup ${hook?['cleanup']}, '
    'started ${hook?['started']}, ended ${hook?['ended']}',
  );
  _check(
    hook?['kind'] == 'hook' &&
        hook?['state'] == 'cancelled' &&
        hook?['reason'] == 'deadline',
    'the hook job ended cancelled by its deadline',
  );

  // The fixture, once it wrote its pid, is gone with its tree.
  final pidText = File(pidFile).existsSync()
      ? File(pidFile).readAsStringSync().trim()
      : null;
  final pid = pidText == null ? null : int.tryParse(pidText);
  if (pid == null) {
    stdout.writeln('hook process: it was killed before it wrote its pid');
  } else {
    final alive = _alive(pid);
    stdout.writeln('hook process $pid alive after settle: $alive');
    _check(!alive, 'the hook process tree is gone');
  }
}

bool _onPath(String program) {
  final result = Platform.isWindows
      ? Process.runSync('where', [program])
      : Process.runSync('sh', ['-c', 'command -v $program']);
  return result.exitCode == 0;
}

bool _alive(int pid) {
  if (Platform.isWindows) {
    final out = Process.runSync('tasklist', [
      '/FI',
      'PID eq $pid',
      '/NH',
      '/FO',
      'CSV',
    ]).stdout.toString();
    return out.contains('"$pid"');
  }
  return Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
}
