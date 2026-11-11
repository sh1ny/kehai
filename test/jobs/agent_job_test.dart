/// Agent jobs end to end (subagents spec: *Role model selection*, *Agent
/// tool*, *Child engine*, *Bounded agent jobs*, *Agent cancellation and
/// deadline*; job-supervisor spec: *One job node shape*).
///
/// The child is the real `kehai rpc --child` process against the loopback fake
/// provider. The bound tests use inert processes instead, because they test the
/// supervisor's admission, not a child.
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/bash_support.dart';
import '../support/fake_openai.dart';
import '../support/job_support.dart';
import '../support/login_support.dart';
import '../support/session_support.dart';

const String _reviewer = 'specwright-reviewer';

/// The child engine command: `kehai rpc` from this checkout's sources.
({String executable, List<String> arguments}) _sourceEngine(
  List<String> rpcArgs,
) {
  final root = Directory.current.path;
  return (
    executable: Platform.resolvedExecutable,
    arguments: [
      '--packages=${p.join(root, '.dart_tool', 'package_config.json')}',
      p.join(root, 'bin', 'kehai.dart'),
      'rpc',
      ...rpcArgs,
    ],
  );
}

/// A process that does nothing and ends when its stdin closes or it is killed.
final class _InertProcess implements Process {
  _InertProcess() {
    _stdin = StreamController<List<int>>();
    _stdin.stream.listen((_) {});
    _stdin.done.then<void>((_) => end(0));
    stdin = IOSink(_stdin);
  }

  late final StreamController<List<int>> _stdin;
  final Completer<int> _exit = Completer<int>();

  @override
  late final IOSink stdin;

  /// Ends the process with [code].
  void end(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Future<int> get exitCode => _exit.future;

  @override
  int get pid => -1;

  @override
  Stream<List<int>> get stdout => const Stream.empty();

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    end(-15);
    return true;
  }
}

/// A supervisor deadline that the test fires after observing child output.
final class _ManualDeadline implements Timer {
  _ManualDeadline(this._zone, this._callback);

  final Zone _zone;
  final void Function() _callback;
  bool _active = true;
  int _tick = 0;

  void fire() {
    if (!_active) throw StateError('deadline is no longer active');
    _active = false;
    _tick = 1;
    _zone.runGuarded(_callback);
  }

  @override
  void cancel() => _active = false;

  @override
  bool get isActive => _active;

  @override
  int get tick => _tick;
}

/// Waits for the real child's text delta before firing the supervisor's timer.
final class _DeadlineGate {
  _DeadlineGate(this.text);

  static const duration = Duration(seconds: 137);
  final String text;
  final Completer<void> _ready = Completer<void>();
  final Completer<_ManualDeadline> _deadline = Completer<_ManualDeadline>();
  String _pending = '';

  JobHooks get hooks => JobHooks(
    afterSpoolWrite: (id, stream, chunk) async {
      if (stream != 'stdout' || _ready.isCompleted) return;
      // Protocol delimiters and the expected text are ASCII; preserve split
      // lines across pipe chunks without depending on chunk boundaries.
      _pending += String.fromCharCodes(chunk);
      var newline = _pending.indexOf('\n');
      while (newline >= 0) {
        final line = _pending.substring(0, newline);
        _pending = _pending.substring(newline + 1);
        if (line.contains('"type":"stream"') &&
            line.contains('"kind":"text"') &&
            line.contains('"delta":${jsonEncode(text)}')) {
          _ready.complete();
          break;
        }
        newline = _pending.indexOf('\n');
      }
    },
  );

  Future<String> run(_Fixture f) async {
    final running = runZoned(
      () => f.h.call('agent', {
        'role': _reviewer,
        'prompt': 'review',
        'timeout_s': duration.inSeconds,
      }),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, delay, callback) {
          if (delay != duration) {
            return parent.createTimer(zone, delay, callback);
          }
          final timer = _ManualDeadline(zone, callback);
          _deadline.complete(timer);
          return timer;
        },
      ),
    );
    await _ready.future.timeout(
      const Duration(seconds: 90),
      onTimeout: () => throw StateError('child did not stream $text'),
    );
    final timer = await _deadline.future.timeout(const Duration(seconds: 90));
    expect(timer.isActive, isTrue);
    timer.fire();
    return running.timeout(const Duration(seconds: 60));
  }
}

String _roleText(String name, {String? model, String? tools}) =>
    '---\n'
    'name: $name\n'
    'description: Does $name work\n'
    '${model == null ? '' : 'model: $model\n'}'
    '${tools == null ? '' : 'tools: $tools\n'}'
    '---\n'
    'Be the $name.\n';

/// A parent session, its workspace and a fake provider.
final class _Fixture {
  _Fixture._(this.home, this.workspace, this.fake, this.h);

  static Future<_Fixture> create({
    bool login = true,
    Map<String, Tool>? tools,
    JobHooks jobHooks = const JobHooks(),
  }) async {
    final home = TestHome();
    final workspace = await tempDir();
    Directory(p.join(workspace.path, '.git')).createSync();
    final fake = await FakeOpenAi.start();
    fake.defaultModels = {
      'models': [
        for (final slug in ['gpt-fake', 'gpt-fake-mini'])
          {
            'slug': slug,
            'display_name': slug,
            'visibility': 'list',
            'supported_in_api': true,
          },
      ],
    };
    if (login) home.store.replace(loggedInRecord());
    Directory(home.path).createSync(recursive: true);
    if (!Platform.isWindows) Process.runSync('chmod', ['700', home.path]);
    File(p.join(home.path, 'config.json')).writeAsStringSync(
      jsonEncode({
        'model': 'gpt-fake',
        'agents': {
          'models': {'sonnet': 'gpt-fake-mini'},
        },
      }),
    );
    final h = await BashHarness.create(
      workspace: workspace,
      kehaiHome: Directory(home.path),
      model: 'gpt-fake',
      config: UserConfig.load(home.path),
      jobHooks: jobHooks,
      tools:
          tools ??
          {
            'agent': AgentTool(
              engine: _sourceEngine,
              extraEnvironment: {
                'KEHAI_OPENAI_ISSUER': fake.issuer,
                'KEHAI_OPENAI_API_BASE': fake.apiBase,
              },
            ),
          },
    );
    return _Fixture._(home, workspace, fake, h);
  }

  final TestHome home;
  final Directory workspace;
  final FakeOpenAi fake;
  final BashHarness h;

  void writeRole(String name, {String? model, String? tools}) {
    final dir = Directory(p.join(workspace.path, '.claude', 'agents'))
      ..createSync(recursive: true);
    File(p.join(dir.path, '$name.md'))
        .writeAsStringSync(_roleText(name, model: model, tools: tools));
  }

  void script(String text) =>
      fake.responsesScripts.add(ResponsesScript.sse(sseTextTurn(text)));

  /// A step that streams [text] and then stalls.
  void stall(String text) => fake.responsesScripts.add(
    ResponsesScript.sse([
      SseEvent.json('response.created', {
        'response': {'id': 'resp_1'},
      }),
      SseEvent.json('response.output_text.delta', {'delta': text}),
      const Delay(Duration(seconds: 120)),
    ]),
  );

  /// The only job node.
  Map<String, Object?> get job => h.jobNodes.values.single;

  /// The child session of [node].
  Directory childDir(Map<String, Object?> node) => Directory(
    p.join(
      h.writer.sessionDir.path,
      'agents',
      (node['agent']! as Map<String, Object?>)['session']! as String,
    ),
  );

  /// The models the child's steps recorded.
  Future<List<Object?>> childModels(Map<String, Object?> node) async {
    final child = await SessionWriter.open(childDir(node));
    addTearDown(child.close);
    final steps =
        child.tree.get(SessionPath.parse('body/steps'))!
            as Map<String, Object?>;
    return [
      for (final step in steps.values) (step! as Map<String, Object?>)['model'],
    ];
  }

  /// Starts an agent job on an inert process, bypassing the tool.
  JobHandle startInert(
    List<_InertProcess> into, {
    JobKind kind = JobKind.agent,
  }) {
    return h.runtime.jobs.start(
      JobRequest(
        kind: kind,
        cmd: kind == JobKind.agent ? _reviewer : 'sleep',
        cwd: workspace.path,
        channel: kind == JobKind.agent
            ? AgentRun(role: _reviewer, prompt: 'x')
            : null,
        launch: () async {
          final process = _InertProcess();
          into.add(process);
          return ShellProcess(process, groupKnown: false);
        },
      ),
    );
  }
}

void main() {
  group('role model selection', () {
    test("inherit runs the child on the parent's model", () async {
      final f = await _Fixture.create();
      f.writeRole(_reviewer, model: 'inherit');
      f.script('VERDICT: APPROVE');

      await f.h.call('agent', {'role': _reviewer, 'prompt': 'review it'});

      expect(f.fake.responsesRequests.single.json!['model'], 'gpt-fake');
      expect(await f.childModels(f.job), ['gpt-fake']);
      expect((f.job['agent']! as Map)['model'], 'gpt-fake');
      expect((f.job['agent']! as Map).containsKey('note'), isFalse);
    });

    test('a configured alias picks its slug', () async {
      final f = await _Fixture.create();
      f.writeRole(_reviewer, model: 'sonnet');
      f.script('done');

      await f.h.call('agent', {'role': _reviewer, 'prompt': 'review it'});

      expect(f.fake.responsesRequests.single.json!['model'], 'gpt-fake-mini');
      expect(await f.childModels(f.job), ['gpt-fake-mini']);
      expect((f.job['agent']! as Map)['model'], 'gpt-fake-mini');
    });

    test('an unmapped alias uses the parent\'s model with a note', () async {
      final f = await _Fixture.create();
      f.writeRole(_reviewer, model: 'haiku');
      f.script('done');

      final text = await f.h.call('agent', {
        'role': _reviewer,
        'prompt': 'review it',
      });

      const note = 'model haiku is not configured; used gpt-fake';
      expect(f.fake.responsesRequests.single.json!['model'], 'gpt-fake');
      expect(await f.childModels(f.job), ['gpt-fake']);
      expect((f.job['agent']! as Map)['note'], note);
      expect(text, contains(note));
    });

    test('a role tool with no Kehai counterpart is named on the job and in '
        'the result', () async {
      final f = await _Fixture.create();
      f.writeRole(_reviewer, tools: 'Read, WebFetch');
      f.script('done');

      final text = await f.h.call('agent', {
        'role': _reviewer,
        'prompt': 'review it',
      });

      expect((f.job['agent']! as Map)['unmapped'], ['WebFetch']);
      expect(text, contains('unmapped role tools: WebFetch'));
    });
  });

  group('agent calls', () {
    test('a foreground agent call settles with the typed result', () async {
      final f = await _Fixture.create();
      f.writeRole(_reviewer);
      f.script('VERDICT: APPROVE');

      final text = await f.h.call('agent', {
        'role': _reviewer,
        'prompt': 'review it',
      });

      final session = (f.job['agent']! as Map)['session']! as String;
      expect(
        text,
        contains(
          'agent $_reviewer done (1 steps, session $session)\n'
          'VERDICT: APPROVE',
        ),
      );
      expect(f.h.lastCall['status'], 'settled');
      expect(f.h.lastCall['envelope'], 'ok');
      expect(f.job['state'], 'settled');
      expect(f.childDir(f.job).existsSync(), isTrue);
    });

    test('a background agent returns its id and job wait returns the '
        'result', () async {
      final f = await _Fixture.create();
      f.writeRole(_reviewer);
      f.script('VERDICT: APPROVE');

      final started = await f.h.call('agent', {
        'role': _reviewer,
        'prompt': 'review it',
        'background': true,
      });

      final id = jobIdIn(started);
      expect(f.h.lastCall['status'], 'settled');
      expect(f.h.lastCall['envelope'], 'ok');
      expect(f.h.jobNodes.keys, [id]);

      final waited = await f.h.call('job', {
        'id': id,
        'action': 'wait',
        'timeout_s': 120,
      });

      expect(f.h.job(id)['state'], 'settled');
      expect(waited, contains('agent $_reviewer done (1 steps, session '));
      expect(waited, contains('VERDICT: APPROVE'));

      final output = await f.h.call('job', {'id': id, 'action': 'output'});
      expect(output, contains('VERDICT: APPROVE'));
    });

    test('a child fatal before its exchange fails the job with that '
        'message', () async {
      final f = await _Fixture.create(login: false);
      f.writeRole(_reviewer);

      final text = await f.h.call('agent', {
        'role': _reviewer,
        'prompt': 'review it',
      });

      const message =
          'agent failed to start: not logged in; run kehai login '
          'openai';
      expect(f.job['state'], 'failed');
      expect(f.job['reason'], message);
      expect(f.h.lastCall['status'], 'failed');
      expect(f.h.lastCall['envelope'], 'error');
      expect(text, contains(message));
      expect(f.fake.responsesRequests, isEmpty);
    });

    test('an agent job node records kind, agent fields and a result '
        'reference', () async {
      final f = await _Fixture.create();
      f.writeRole(_reviewer);
      f.script('VERDICT: APPROVE');

      await f.h.call('agent', {'role': _reviewer, 'prompt': 'review it'});

      final node = f.job;
      final agent = node['agent']! as Map<String, Object?>;
      expect(node['kind'], 'agent');
      expect(node['cmd'], _reviewer);
      expect(node['state'], 'settled');
      expect(agent, containsPair('role', _reviewer));
      expect(agent, containsPair('model', 'gpt-fake'));
      expect(agent, containsPair('status', 'done'));
      expect(agent, containsPair('steps', 1));
      expect(agent['usage'], isA<Map<String, Object?>>());
      expect(agent['session'], isA<String>());
      expect(
        f.h.stream(node, 'result'),
        'agent $_reviewer done (1 steps, session ${agent['session']})\n'
        'VERDICT: APPROVE',
      );
      expect(jsonEncode(node).toLowerCase(), isNot(contains('pid')));
    });
  });

  group('bounds', () {
    test('a fifth live agent is refused until one ends', () async {
      final f = await _Fixture.create(
        tools: {
          'agent': AgentTool(
            engine: (args) => (
              executable: Platform.resolvedExecutable,
              arguments: [
                File(
                  p.join(
                    Directory.current.path,
                    'test',
                    'fixtures',
                    'idle_child.dart',
                  ),
                ).path,
              ],
            ),
          ),
        },
      );
      f.writeRole(_reviewer);
      final inert = <_InertProcess>[];
      for (var n = 0; n < maxLiveAgents; n++) {
        f.startInert(inert);
      }
      await waitFor(() => inert.length == maxLiveAgents);
      final before = f.h.jobNodes.length;

      final refused = await f.h.call('agent', {
        'role': _reviewer,
        'prompt': 'one more',
        'background': true,
      });

      const message =
          'too many live agents (4); wait for or cancel one with '
          'job';
      expect(refused, contains(message));
      expect(f.h.lastCall['status'], 'failed');
      expect(f.h.lastCall['reason'], message);
      expect(f.h.jobNodes, hasLength(before));

      inert.first.end(0);
      await waitFor(() => f.h.runtime.jobs.liveCount == maxLiveAgents - 1);

      final started = await f.h.call('agent', {
        'role': _reviewer,
        'prompt': 'one more',
        'background': true,
      });
      expect(f.h.lastCall['status'], 'settled');
      expect(f.h.jobNodes, hasLength(before + 1));
      final id = jobIdIn(started);
      await f.h.call('job', {'id': id, 'action': 'cancel'});
    });

    test('agents count toward the sixteen-job bound', () async {
      final f = await _Fixture.create();
      f.writeRole(_reviewer);
      final inert = <_InertProcess>[];
      for (var n = 0; n < 14; n++) {
        f.startInert(inert, kind: JobKind.shell);
      }
      for (var n = 0; n < 2; n++) {
        f.startInert(inert);
      }
      await waitFor(() => inert.length == 16);

      final text = await f.h.call('agent', {
        'role': _reviewer,
        'prompt': 'x',
        'background': true,
      });

      expect(text, contains('too many live jobs (16); cancel one with job'));
      expect(f.h.lastCall['status'], 'failed');
      expect(f.h.jobNodes, hasLength(16));
      expect(inert, hasLength(16));
    });
  });

  group('cancellation and deadline', () {
    test('interrupt soft-stops the child and records cancelled', () async {
      final f = await _Fixture.create();
      f.writeRole(_reviewer);
      f.stall('thinking ');
      final token = CancelToken();

      final running = f.h.runtime.run(
        ToolCall(
          callId: 'agent-call',
          name: 'agent',
          argumentsJson: jsonEncode({'role': _reviewer, 'prompt': 'review'}),
        ),
        cancel: token,
      );
      await waitFor(
        () => f.fake.responsesRequests.isNotEmpty,
        limit: const Duration(seconds: 90),
        what: 'the child to ask the provider',
      );
      token.cancel();
      final item = await running.timeout(const Duration(seconds: 60));

      expect(f.h.lastCall['status'], 'cancelled');
      final node = f.job;
      expect(node['state'], 'cancelled');
      expect(node['reason'], 'user');
      expect(node['exit'], 0, reason: 'the child ended by itself');
      expect((node['agent']! as Map)['status'], 'cancelled');
      expect(item.output, contains('agent $_reviewer cancelled'));
      final child = await SessionWriter.open(f.childDir(node));
      addTearDown(child.close);
      final exchanges =
          child.tree.get(SessionPath.parse('body/exchanges'))!
              as Map<String, Object?>;
      expect(
        (exchanges.values.single! as Map<String, Object?>)['state'],
        'cancelled',
      );
    });

    test('a child past its deadline ends with status timeout and its text so '
        'far', () async {
      final deadline = _DeadlineGate('partial words');
      final f = await _Fixture.create(jobHooks: deadline.hooks);
      f.writeRole(_reviewer);
      f.stall('partial words');

      final text = await deadline.run(f);

      final agent = f.job['agent']! as Map<String, Object?>;
      expect(agent['status'], 'timeout');
      expect(f.h.stream(f.job, 'result'), contains('agent $_reviewer timeout'));
      expect(text, contains('agent $_reviewer timeout'));
      expect(text, contains('partial words'));
      expect(f.h.lastCall['envelope'], 'timeout');
    });

    test('a timed-out child returns its latest partial text, not an earlier '
        "step's commentary", () async {
      final deadline = _DeadlineGate('latest answer so far');
      final f = await _Fixture.create(jobHooks: deadline.hooks);
      f.writeRole(_reviewer, tools: 'read');
      File(p.join(f.workspace.path, 'notes.txt')).writeAsStringSync('notes');
      f.fake.responsesScripts.add(
        ResponsesScript.sse([
          SseEvent.json('response.created', {
            'response': {'id': 'resp_1'},
          }),
          SseEvent.json('response.output_text.delta', {
            'delta': 'early commentary',
          }),
          SseEvent.json('response.output_item.done', {
            'item': {
              'type': 'message',
              'role': 'assistant',
              'content': [
                {'type': 'output_text', 'text': 'early commentary'},
              ],
            },
          }),
          SseEvent.json('response.output_item.done', {
            'item': {
              'type': 'function_call',
              'call_id': 'call_read',
              'name': 'read',
              'arguments': jsonEncode({'path': 'notes.txt'}),
            },
          }),
          SseEvent.json('response.completed', {
            'response': {'id': 'resp_1'},
          }),
        ]),
      );
      f.stall('latest answer so far');

      final text = await deadline.run(f);

      expect((f.job['agent']! as Map<String, Object?>)['status'], 'timeout');
      expect(f.fake.responsesRequests, hasLength(2));
      expect(text, contains('latest answer so far'));
      expect(text, isNot(contains('early commentary')));
    });
  });
}
