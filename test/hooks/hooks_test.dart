import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/answerer_support.dart';
import '../support/session_support.dart';

String _fixture(String name) => p.absolute('test', 'fixtures', name);

/// The argv that runs the Dart fixture [name] with [args].
List<String> _dart(String name, [List<String> args = const []]) => [
  Platform.resolvedExecutable,
  _fixture(name),
  ...args,
];

HookConfig _hook(
  String name,
  List<String> argv, {
  HookPolicy policy = HookPolicy.optional,
  List<String> tools = const ['bash'],
  Duration timeout = const Duration(seconds: 60),
}) => HookConfig(
  name: name,
  argv: argv,
  tools: tools,
  policy: policy,
  timeout: timeout,
);

/// A tool that records the calls it runs.
final class _Recorder implements Tool {
  final List<String> ran = [];

  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    ran.add(context.callId);
    await context.output.writeText('ran\n');
    return const ToolOutcome(summary: 'done');
  }
}

final class _Harness {
  _Harness(this.root, this.writer, this.runtime, this.tool, this.answerer);

  final Directory root;
  final SessionWriter writer;
  final ToolRuntime runtime;
  final _Recorder tool;
  final RecordingAnswerer answerer;

  Map<String, Object?> node(String callId) =>
      writer.tree.get(SessionPath.parse('body/calls/${callKey(callId)}'))!
          as Map<String, Object?>;

  /// The job nodes of the session, by id.
  Map<String, Map<String, Object?>> jobs() {
    final all = writer.tree.get(SessionPath.parse('jobs'));
    if (all is! Map<String, Object?>) return const {};
    return {
      for (final e in all.entries)
        if (e.value is Map<String, Object?>)
          e.key: e.value! as Map<String, Object?>,
    };
  }

  String stored(Map<String, Object?> ref) => utf8.decode(
    resolveHandle(
      writer.tree,
      writer.sessionDir,
      ref['handle']! as String,
    ).file.readAsBytesSync(),
  );

  /// Waits until the supervisor holds no live job.
  Future<void> jobsGone() async {
    final clock = Stopwatch()..start();
    while (runtime.jobs.liveCount > 0) {
      if (clock.elapsed > const Duration(seconds: 20)) fail('jobs stayed live');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}

Future<_Harness> _attach(
  List<HookConfig> hooks, {
  bool realGate = false,
  Directory? workspace,
  JobHooks jobHooks = const JobHooks(),
}) async {
  final root = workspace ?? await tempDir();
  final home = await tempDir();
  final writer = await createWriter(await tempDir());
  final store = ResultStore(writer.sessionDir);
  final tool = _Recorder();
  final answerer = RecordingAnswerer();
  final runtime = await ToolRuntime.attach(
    writer,
    store,
    workspace: root,
    config: UserConfig(hooks: hooks),
    tools: {'bash': tool, 'read': tool},
    kehaiHome: home,
    answerer: answerer,
    posixShell: true,
    gate: realGate ? null : const AllowAllStage(),
    jobHooks: jobHooks,
  );
  addTearDown(runtime.close);
  return _Harness(root, writer, runtime, tool, answerer);
}

ToolCall _bash(String id, [String command = 'ls']) => ToolCall(
  callId: id,
  name: 'bash',
  argumentsJson: jsonEncode({'command': command}),
);

/// Whether the process [pid] exists, asked without signalling it.
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

void main() {
  test('hook stdin carries the call JSON', () async {
    final h = await _attach([_hook('see', _dart('echo_stdin.dart'))]);

    final item = await h.runtime.run(_bash('s1', 'ls -la'));

    expect(h.tool.ran, ['s1']);
    expect(item.output, isNot(contains('[diag')));
    final jobs = h.jobs().values.toList();
    expect(jobs, hasLength(1));
    final job = jobs.single;
    expect(job['kind'], 'hook');
    expect(job['state'], 'settled');
    expect(job['call'], callKey('s1'));
    final stdout = job['stdout']! as Map<String, Object?>;
    final sent = jsonDecode(h.stored(stdout)) as Map<String, Object?>;
    expect(sent['tool'], 'bash');
    expect(sent['input'], {'command': 'ls -la'});
    expect(sent['workspace'], realPath(h.root.path) ?? h.root.path);
    expect(
      sent['session'],
      h.writer.tree.get(SessionPath.parse('meta/session')),
    );
    final record = h.node('s1')['hooks']! as List<Object?>;
    expect((record.single! as Map<String, Object?>)['name'], 'see');
  });

  test('hooks declared in the repository are never run', () async {
    final workspace = await tempDir();
    final marker = File(p.join(workspace.path, 'ran.marker'));
    final argv = _dart('crash_hook.dart', ['0']);
    for (final file in [
      '.kehai/hooks.json',
      '.kehai/config.json',
      '.claude/settings.json',
      'kehai.json',
    ]) {
      final f = File(p.join(workspace.path, file))..createSync(recursive: true);
      f.writeAsStringSync(
        jsonEncode({
          'hooks': [
            {
              'name': 'repo',
              'argv': argv,
              'tools': ['bash'],
              'policy': 'deny',
            },
          ],
        }),
      );
    }
    marker.createSync();
    final h = await _attach(const [], workspace: workspace);

    await h.runtime.run(_bash('r1'));

    expect(h.tool.ran, ['r1']);
    expect(h.jobs(), isEmpty, reason: 'no hook job started');
    expect(h.node('r1').containsKey('hooks'), isFalse);
  });

  test('exit 2 denies the call before any effect', () async {
    final h = await _attach([
      _hook(
        'guard',
        _dart('crash_hook.dart', ['2', 'no force pushes']),
        policy: HookPolicy.deny,
      ),
    ], realGate: true);

    final item = await h.runtime.run(_bash('d1', 'git push --force'));

    expect(h.tool.ran, isEmpty);
    expect(h.answerer.items, isEmpty, reason: 'no prompt is shown');
    final node = h.node('d1');
    expect(node['status'], 'settled');
    expect(node['envelope'], 'denied');
    expect(node.containsKey('permission'), isFalse);
    expect(item.output, contains('hook guard: no force pushes'));
    final result = node['result']! as Map<String, Object?>;
    expect(h.stored(result), 'hook guard: no force pushes');
  });

  test('exit 2 denies an optional hook too', () async {
    final h = await _attach([
      _hook('guard', _dart('crash_hook.dart', ['2', 'stop\n'])),
    ]);

    final item = await h.runtime.run(_bash('d2'));

    expect(h.tool.ran, isEmpty);
    expect(item.output, contains('hook guard: stop'));
    expect(h.node('d2')['envelope'], 'denied');
  });

  test('optional hook crash adds a diag line and the call runs', () async {
    final h = await _attach([
      _hook('flaky', _dart('crash_hook.dart', ['1', 'boom'])),
    ]);

    final item = await h.runtime.run(_bash('o1'));

    expect(h.tool.ran, ['o1']);
    expect(item.output, contains('[diag hook:flaky] exited 1; ignored'));
    expect(h.node('o1')['envelope'], 'ok');
  });

  test('a deny hook that crashes or cannot start denies', () async {
    final h = await _attach([
      _hook(
        'crashy',
        _dart('crash_hook.dart', ['1']),
        policy: HookPolicy.deny,
        tools: const ['bash'],
      ),
      _hook(
        'missing',
        [p.join(Directory.systemTemp.path, 'kehai-no-such-hook')],
        policy: HookPolicy.deny,
        tools: const ['read'],
      ),
    ]);

    final crashed = await h.runtime.run(_bash('c1'));
    final missing = await h.runtime.run(
      const ToolCall(callId: 'c2', name: 'read', argumentsJson: '{"path":"x"}'),
    );

    expect(h.tool.ran, isEmpty);
    expect(crashed.output, contains('hook crashy exited 1'));
    expect(missing.output, contains('hook missing failed to start'));
    expect(h.node('c1')['envelope'], 'denied');
    expect(h.node('c2')['envelope'], 'denied');
  });

  test('hooks run in configuration order and only for their tools', () async {
    final h = await _attach([
      _hook('first', _dart('crash_hook.dart', ['1'])),
      _hook('reader', _dart('crash_hook.dart', ['1']), tools: const ['read']),
      _hook('second', _dart('crash_hook.dart', ['3'])),
    ]);

    final item = await h.runtime.run(_bash('m1'));

    final text = item.output;
    expect(text, contains('[diag hook:first] exited 1; ignored'));
    expect(text, contains('[diag hook:second] exited 3; ignored'));
    expect(text, isNot(contains('hook:reader')));
    expect(text.indexOf('hook:first'), lessThan(text.indexOf('hook:second')));
    expect(h.jobs(), hasLength(2));
  });

  test(
    'hung optional hook with timeout_ms 500 lets the call proceed within 3 s',
    () async {
      final dir = await tempDir();
      final pidFile = p.join(dir.path, 'hang.pid');
      final h = await _attach([
        _hook(
          'slow',
          _dart('hang_forever.dart', [pidFile]),
          timeout: const Duration(milliseconds: 500),
        ),
      ]);

      final clock = Stopwatch()..start();
      final item = await h.runtime.run(_bash('h1'));
      clock.stop();

      expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
      expect(h.tool.ran, ['h1']);
      expect(
        item.output,
        contains('[diag hook:slow] timed out after 500 ms; ignored'),
      );
      await h.jobsGone();
      final job = h.jobs().values.single;
      expect(job['kind'], 'hook');
      expect(job['state'], 'cancelled');
      expect(job['reason'], 'deadline');
      // The fixture, once it wrote its pid, is gone with its tree.
      final file = File(pidFile);
      if (file.existsSync()) {
        expect(_alive(int.parse(file.readAsStringSync().trim())), isFalse);
      }
    },
  );

  test('a slow job settle does not hold the call past the grace', () async {
    final release = Completer<void>();
    final h = await _attach([
      _hook(
        'gate',
        _dart('hang_forever.dart'),
        policy: HookPolicy.deny,
        timeout: const Duration(milliseconds: 500),
      ),
    ], jobHooks: JobHooks(beforeIntent: (_) => release.future));
    addTearDown(() => release.isCompleted ? null : release.complete());

    final clock = Stopwatch()..start();
    final item = await h.runtime.run(_bash('h4'));
    clock.stop();

    expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
    expect(h.node('h4')['envelope'], 'denied');
    expect(item.output, contains('hook gate timed out after 500 ms'));
    release.complete();
    await h.jobsGone();
    expect(h.jobs().values.single['reason'], 'deadline');
  });

  test('hung deny-class hook denies within 3 s', () async {
    final dir = await tempDir();
    final pidFile = p.join(dir.path, 'hang.pid');
    final h = await _attach([
      _hook(
        'gate',
        _dart('hang_forever.dart', [pidFile]),
        policy: HookPolicy.deny,
        timeout: const Duration(milliseconds: 500),
      ),
    ]);

    final clock = Stopwatch()..start();
    final item = await h.runtime.run(_bash('h2'));
    clock.stop();

    expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
    expect(h.tool.ran, isEmpty);
    expect(h.node('h2')['envelope'], 'denied');
    expect(item.output, contains('hook gate timed out after 500 ms'));

    // The next call of the turn is not delayed by the dead hook.
    final next = Stopwatch()..start();
    await h.runtime.run(
      const ToolCall(callId: 'h3', name: 'read', argumentsJson: '{"path":"x"}'),
    );
    expect(next.elapsed, lessThan(const Duration(seconds: 1)));
    expect(h.tool.ran, ['h3']);
    await h.jobsGone();
    final file = File(pidFile);
    if (file.existsSync()) {
      expect(_alive(int.parse(file.readAsStringSync().trim())), isFalse);
    }
  });
}
