import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/answerer_support.dart';
import '../support/fake_bin.dart';
import '../support/session_support.dart';

final class _Env {
  _Env(this.workspace, this.home, this.bin);

  final Directory workspace;
  final Directory home;

  /// Outside the workspace; holds the programs the proven commands name.
  final Directory bin;
  final RecordingAnswerer answerer = RecordingAnswerer();
  late final PromptChannel channel = PromptChannel(answerer);

  PermissionGate gate({
    UserConfig config = const UserConfig(),
    bool yolo = false,
    bool posixShell = true,
  }) => PermissionGate(
    workspace: workspace,
    kehaiHome: home,
    prompts: channel,
    config: config,
    yolo: yolo,
    posixShell: posixShell,
    environment: {'PATH': bin.path},
  );
}

StageCall _call(String tool, Map<String, Object?> input) => StageCall(
  tool: tool,
  callKey: callKey('id-$tool'),
  callId: 'id-$tool',
  input: input,
);

Future<_Env> _env() async {
  final root = await tempDir();
  final workspace = Directory(p.join(root.path, 'ws'))..createSync();
  Directory(p.join(workspace.path, 'lib')).createSync();
  File(p.join(workspace.path, 'lib', 'kehai.dart')).writeAsStringSync('x\n');
  final home = Directory(p.join(root.path, 'home'))..createSync();
  final bin = fakeBin(Directory(p.join(root.path, 'bin')), ['rg', 'pwd', 'jj']);
  return _Env(workspace, home, bin);
}

void main() {
  late _Env env;
  setUp(() async => env = await _env());

  group('built-in allowlist', () {
    test('workspace read is autoapproved', () async {
      final outcome = await env.gate().check(
        _call('read', {'path': 'lib/kehai.dart'}),
        CancelToken(),
      );

      expect(outcome.denyReason, isNull);
      expect(outcome.record, {'decision': 'allow', 'by': 'builtin'});
      expect(env.answerer.items, isEmpty);
    });

    test('path outside the workspace goes to the prompt', () async {
      final escape = env.gate().check(
        _call('read', {'path': '../other/secret.txt'}),
        CancelToken(),
      );
      final item = await env.answerer.item(0);
      expect(item.kind, PromptKind.permission);
      expect(item.tool, 'read');
      expect(item.input, {'path': '../other/secret.txt'});
      expect(env.channel.reply(item.key, 'deny'), isNull);
      expect((await escape).denyReason, isNotNull);
    });

    test('a workspace symlink resolving outside goes to the prompt', () async {
      final outside = Directory(p.join(env.workspace.parent.path, 'outside'))
        ..createSync();
      File(p.join(outside.path, 's.txt')).writeAsStringSync('s');
      try {
        Link(p.join(env.workspace.path, 'out')).createSync(outside.path);
      } on FileSystemException {
        markTestSkipped('symbolic links need privileges here');
        return;
      }

      final pending = env.gate().check(
        _call('read', {'path': 'out/s.txt'}),
        CancelToken(),
      );
      final item = await env.answerer.item(0);
      expect(env.channel.reply(item.key, 'allow'), isNull);
      expect((await pending).record, {'decision': 'allow', 'by': 'answer'});
    });

    test('status tools, job status and ask need no prompt', () async {
      final gate = env.gate();
      final calls = [
        _call('read_more', {'handle': 'r-1'}),
        _call('search_result', {'handle': 'r-1', 'pattern': 'x'}),
        _call('job', {'id': 'j-1', 'action': 'status'}),
        _call('job', {'id': 'j-1', 'action': 'output'}),
        _call('ask', {'question': 'q'}),
        _call('grep', {'pattern': 'x'}),
        _call('find', {'glob': '*.dart', 'path': 'lib'}),
        _call('ls', {}),
      ];
      for (final call in calls) {
        final outcome = await gate.check(call, CancelToken());
        expect(outcome.denyReason, isNull, reason: call.tool);
        expect((outcome.record! as Map)['by'], 'builtin', reason: call.tool);
      }
      expect(env.answerer.items, isEmpty);
    });

    test('job cancel and edit still ask', () async {
      final gate = env.gate();
      final pending = [
        gate.check(
          _call('job', {'id': 'j', 'action': 'cancel'}),
          CancelToken(),
        ),
        gate.check(_call('edit', {'path': 'a'}), CancelToken()),
      ];
      await env.answerer.item(1);
      for (final item in env.answerer.items) {
        env.channel.reply(item.key, 'deny');
      }
      for (final outcome in await Future.wait(pending)) {
        expect(outcome.denyReason, isNotNull);
      }
    });

    test('a proven bash command records the program as the rule', () async {
      final outcome = await env.gate().check(
        _call('bash', {'command': 'rg -n TODO lib'}),
        CancelToken(),
      );

      expect(outcome.record, {
        'decision': 'allow',
        'by': 'builtin',
        'rule': 'rg',
      });
    });

    test('bash is never proven without a POSIX shell', () async {
      final pending = env
          .gate(posixShell: false)
          .check(_call('bash', {'command': 'pwd'}), CancelToken());
      final item = await env.answerer.item(0);
      env.channel.reply(item.key, 'deny');
      expect((await pending).denyReason, isNotNull);
    });
  });

  group('user allowlist', () {
    const jjStatus = UserConfig(
      allow: [
        AllowRule('bash', ['jj', 'status']),
      ],
    );

    test('user rule autoapproves jj status', () async {
      final outcome = await env
          .gate(config: jjStatus)
          .check(
            _call('bash', {'command': 'jj status --no-pager'}),
            CancelToken(),
          );

      expect(outcome.denyReason, isNull);
      expect(outcome.record, {
        'decision': 'allow',
        'by': 'user',
        'rule': 'bash:jj status',
      });
    });

    test('rules in repository files are ignored', () async {
      final rules = jsonEncode({
        'allow': [
          {
            'tool': 'bash',
            'argv': ['jj', 'status'],
          },
        ],
      });
      for (final file in ['.kehai/config.json', '.claude/settings.json']) {
        File(p.join(env.workspace.path, file))
          ..createSync(recursive: true)
          ..writeAsStringSync(rules);
      }
      // The configuration comes from the Kehai home only.
      final config = UserConfig.load(env.home.path);

      final pending = env
          .gate(config: config)
          .check(_call('bash', {'command': 'jj status'}), CancelToken());
      final item = await env.answerer.item(0);
      expect(item.tool, 'bash');
      env.channel.reply(item.key, 'deny');
      expect((await pending).denyReason, isNotNull);
    });

    const anyBash = UserConfig(allow: [AllowRule('bash')]);

    test('a tool-wide bash rule allows a plain simple command', () async {
      final outcome = await env
          .gate(config: anyBash)
          .check(_call('bash', {'command': 'jj log -n 3'}), CancelToken());

      expect(outcome.denyReason, isNull);
      expect(outcome.record, {
        'decision': 'allow',
        'by': 'user',
        'rule': 'bash',
      });
      expect(env.answerer.items, isEmpty);
    });

    test('a tool-wide bash rule does not approve a compound command', () async {
      final pending = env
          .gate(config: anyBash)
          .check(_call('bash', {'command': 'echo a && echo b'}), CancelToken());
      final item = await env.answerer.item(0);
      expect(item.input['command'], 'echo a && echo b');
      env.channel.reply(item.key, 'deny');
      expect((await pending).denyReason, isNotNull);

      // Under yolo the command falls through to yolo, not to the rule.
      final yolo = await env
          .gate(config: anyBash, yolo: true)
          .check(_call('bash', {'command': 'echo a; echo b'}), CancelToken());
      expect(yolo.record, {'decision': 'allow', 'by': 'yolo'});
    });

    test('a tool-wide bash rule does not approve a workspace-shadowed '
        'program', () async {
      final shadow = fakeBin(Directory(p.join(env.workspace.path, 'sh')), [
        'jj',
      ]);
      final gate = PermissionGate(
        workspace: env.workspace,
        kehaiHome: env.home,
        prompts: env.channel,
        config: anyBash,
        posixShell: true,
        environment: {
          'PATH': [shadow.path, '.'].join(Platform.isWindows ? ';' : ':'),
        },
      );

      final pending = gate.check(
        _call('bash', {'command': 'jj status'}),
        CancelToken(),
      );
      final item = await env.answerer.item(0);
      expect(item.tool, 'bash');
      env.channel.reply(item.key, 'deny');
      expect((await pending).denyReason, isNotNull);
    });

    test('prefix rule does not approve an appended command', () async {
      final pending = env
          .gate(config: jjStatus)
          .check(
            _call('bash', {'command': 'jj status && jj git push'}),
            CancelToken(),
          );
      final item = await env.answerer.item(0);
      expect(item.input['command'], 'jj status && jj git push');
      env.channel.reply(item.key, 'deny');
      expect((await pending).denyReason, isNotNull);
    });

    test('a tool rule allows that tool and records its label', () async {
      final outcome = await env
          .gate(config: const UserConfig(allow: [AllowRule('edit')]))
          .check(_call('edit', {'path': 'lib/kehai.dart'}), CancelToken());

      expect(outcome.record, {
        'decision': 'allow',
        'by': 'user',
        'rule': 'edit',
      });
    });
  });

  group('ask otherwise, or yolo', () {
    test('yolo approves without prompting except credential paths', () async {
      final gate = env.gate(yolo: true);

      final run = await gate.check(
        _call('bash', {'command': 'dart test'}),
        CancelToken(),
      );
      final creds = await gate.check(
        _call('read', {'path': p.join(env.home.path, 'auth.json')}),
        CancelToken(),
      );

      expect(run.record, {'decision': 'allow', 'by': 'yolo'});
      expect(creds.denyReason, 'credential files are not readable by tools');
      expect(env.answerer.items, isEmpty);
    });

    test('credential files are refused despite a tool rule', () async {
      final gate = env.gate(
        config: const UserConfig(allow: [AllowRule('read')]),
      );
      for (final name in ['auth.json', 'auth.lock', 'auth.json.12_0.tmp']) {
        final outcome = await gate.check(
          _call('read', {'path': p.join(env.home.path, name)}),
          CancelToken(),
        );
        expect(outcome.denyReason, isNotNull, reason: name);
      }
    });

    test('allow answer lets the call proceed and is recorded', () async {
      final pending = env.gate().check(
        _call('write', {'path': 'a', 'content': 'x'}),
        CancelToken(),
      );
      final item = await env.answerer.item(0);
      expect(item.toJson()['kind'], 'permission');
      expect(env.channel.reply(item.key, 'allow'), isNull);

      expect((await pending).record, {'decision': 'allow', 'by': 'answer'});
    });

    test('a cancelled prompt is withdrawn', () async {
      final cancel = CancelToken();
      final pending = env.gate().check(_call('edit', {'path': 'a'}), cancel);
      final item = await env.answerer.item(0);
      cancel.cancel();
      await pending;

      expect(env.answerer.withdrawn, [item.key]);
      expect(env.channel.reply(item.key, 'allow'), 'question withdrawn');
    });
  });

  group('through the runtime', () {
    Future<(ToolRuntime, SessionWriter, int Function())> attach({
      required RecordingAnswerer? answerer,
      required String tool,
    }) async {
      final root = await tempDir();
      final writer = await createWriter(root);
      var runs = 0;
      final runtime = await ToolRuntime.attach(
        writer,
        ResultStore(writer.sessionDir),
        workspace: env.workspace,
        kehaiHome: env.home,
        answerer: answerer,
        tools: {tool: _Counting(() => runs++)},
      );
      addTearDown(runtime.close);
      return (runtime, writer, () => runs);
    }

    Map<String, Object?> node(SessionWriter w, String id) =>
        w.tree.get(SessionPath.parse('body/calls/${callKey(id)}'))!
            as Map<String, Object?>;

    test(
      'a tool-wide bash rule still prompts for a compound command',
      () async {
        final root = await tempDir();
        final writer = await createWriter(root);
        var runs = 0;
        final runtime = await ToolRuntime.attach(
          writer,
          ResultStore(writer.sessionDir),
          workspace: env.workspace,
          kehaiHome: env.home,
          config: const UserConfig(allow: [AllowRule('bash')]),
          answerer: env.answerer,
          tools: {'bash': _Counting(() => runs++)},
        );
        addTearDown(runtime.close);

        final done = runtime.run(
          ToolCall(
            callId: 'k1',
            name: 'bash',
            argumentsJson: jsonEncode({'command': 'echo a && echo b'}),
          ),
        );
        final item = await env.answerer.item(0);
        expect(runtime.prompts.reply(item.key, 'deny'), isNull);
        await done;

        final n = node(writer, 'k1');
        expect(n['permission'], {'decision': 'deny', 'by': 'answer'});
        expect(runs, 0);
      },
    );

    test('denied prompt settles denied without effect', () async {
      final (runtime, writer, runs) = await attach(
        answerer: env.answerer,
        tool: 'edit',
      );

      final done = runtime.run(
        ToolCall(
          callId: 'e1',
          name: 'edit',
          argumentsJson: jsonEncode({
            'path': 'lib/kehai.dart',
            'anchors': <String>[],
            'ops': [
              {'op': 'delete', 'start': 1, 'end': 1},
            ],
          }),
        ),
      );
      final item = await env.answerer.item(0);
      expect(runtime.prompts.reply(item.key, 'deny'), isNull);
      final output = await done;

      final n = node(writer, 'e1');
      expect(n['status'], 'settled');
      expect(n['envelope'], 'denied');
      expect(n['permission'], {'decision': 'deny', 'by': 'answer'});
      expect(runs(), 0);
      expect(output.output, startsWith('[edit denied]'));
      expect(
        File(p.join(env.workspace.path, 'lib', 'kehai.dart'))
            .readAsStringSync(),
        'x\n',
      );
    });

    test('headless unapproved call settles denied', () async {
      final (runtime, writer, runs) = await attach(
        answerer: null,
        tool: 'write',
      );

      final output = await runtime.run(
        ToolCall(
          callId: 'w1',
          name: 'write',
          argumentsJson: '{"path":"new.txt","content":"x"}',
        ),
      );

      final n = node(writer, 'w1');
      expect(n['envelope'], 'denied');
      expect(output.output, contains('no user attached'));
      expect(n['permission'], containsPair('decision', 'deny'));
      expect(runs(), 0);
      expect(File(p.join(env.workspace.path, 'new.txt')).existsSync(), isFalse);
    });

    test('an allowed call runs with its permission recorded', () async {
      final (runtime, writer, runs) = await attach(
        answerer: env.answerer,
        tool: 'read',
      );

      await runtime.run(
        ToolCall(
          callId: 'r1',
          name: 'read',
          argumentsJson: '{"path":"lib/kehai.dart"}',
        ),
      );

      expect(node(writer, 'r1')['permission'], {
        'decision': 'allow',
        'by': 'builtin',
      });
      expect(runs(), 1);
    });
  });
}

final class _Counting implements Tool {
  _Counting(this.onRun);

  final void Function() onRun;

  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    onRun();
    return const ToolOutcome(summary: 'ran');
  }
}
