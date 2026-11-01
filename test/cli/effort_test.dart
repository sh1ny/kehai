@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kehai/kehai.dart';
import 'package:kehai/src/cli/cli.dart' as command;

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_openai.dart';
import '../support/login_support.dart';
import 'cli_test.dart' as cli;
import '../rpc/process_test.dart' as rpc;
import '../support/session_support.dart';

Future<
  ({
    int code,
    List<String>? clientArgs,
    int rpcStarts,
    String? effort,
    String error,
  })
>
captureStartup(List<String> args, TestHome home) async {
  List<String>? clientArgs;
  var rpcStarts = 0;
  String? effort;
  final error = StringBuffer();
  final code = await command.runCli(
    args,
    environment: {'KEHAI_HOME': home.path},
    out: StringBuffer(),
    err: error,
    stdinIsTerminal: false,
    interrupts: const Stream<Object?>.empty(),
    engineStarter: (args) async {
      clientArgs = List.of(args);
      throw const ProcessException('test engine', [], 'captured startup');
    },
    rpcRunner:
        ({
          required settings,
          required workspace,
          required input,
          required output,
          bool resume = false,
          String? sessionId,
          String? modelFlag,
          String? effortFlag,
          child,
        }) async {
          rpcStarts++;
          effort = effortFlag;
          return 0;
        },
  );
  return (
    code: code,
    clientArgs: clientArgs,
    rpcStarts: rpcStarts,
    effort: effort,
    error: error.toString(),
  );
}

Future<Directory> effortRun(
  TestHome home,
  FakeOpenAi fake,
  Directory workspace,
  List<String> args,
) async {
  fake.responsesScripts.add(ResponsesScript.sse(sseTextTurn('ok')));
  final engine = await rpc.startEngine(
    ['--model', 'gpt-fake', ...args],
    home: home,
    workspace: workspace,
    fake: fake,
  );
  try {
    final hello = await engine.nextLine();
    expect(hello['type'], 'hello');
    final snapshot = await engine.nextLine();
    engine.send({
      'type': 'submit',
      'id': 'effort-${snapshot['turn']}',
      'text': 'hi',
      'turn': snapshot['turn'],
    });
    await engine.lineWhere((line) {
      final record = line['record'];
      return record is Map<String, Object?> &&
          (record['path'] as String).startsWith('meta/requests/') &&
          record['value'] is Map<String, Object?> &&
          (record['value']! as Map<String, Object?>)['state'] == 'completed';
    });
    await engine.process.stdin.close();
    expect(await engine.exitCode(), 0, reason: await engine.stderrText);
    return Directory(
      p.join(
        home.path,
        'sessions',
        rpc.keyOf(workspace.path),
        hello['session']! as String,
      ),
    );
  } finally {
    engine.process.kill();
    await engine.process.exitCode;
    await engine.lines.cancel();
  }
}

Map<String, Object?> effortSteps(Directory session) =>
    scanJournal(File(p.join(session.path, journalFileName))).state
            .combined()
            .get(SessionPath.parse('body/steps'))!
        as Map<String, Object?>;

void expectWireAndStep(FakeOpenAi fake, Directory session, String? effort) {
  final reasoning =
      fake.responsesRequests.last.json!['reasoning']! as Map<String, Object?>;
  expect(
    reasoning,
    effort == null
        ? {'summary': 'auto'}
        : {'effort': effort, 'summary': 'auto'},
  );
  final step = effortSteps(session).values.last! as Map<String, Object?>;
  expect(step, containsPair('effort', effort));
}

void main() {
  test(
    'internal effort default marker rejects misuse before startup',
    () async {
      for (final args in [
        ['rpc', '--effort-default'],
        [
          'rpc',
          '--child',
          '--parent',
          'unused',
          '--job',
          'j-1',
          '--role',
          'reviewer',
          '--role-digest',
          'unused',
          '--effort-default',
          '--effort',
          'high',
        ],
      ]) {
        final captured = await captureStartup(args, TestHome());
        expect(captured.code, 64);
        expect(captured.rpcStarts, 0);
        expect(captured.clientArgs, isNull);
        expect(
          captured.error,
          contains(
            args.contains('--child')
                ? 'cannot be combined with --effort'
                : 'needs --child',
          ),
        );
      }
    },
  );

  late TestHome home;
  late FakeOpenAi fake;

  late String executable;

  setUpAll(() async {
    // Keep every process-level form check without paying JIT startup 24 times.
    final build = await Directory.systemTemp.createTemp('kehai-effort-cli-');
    addTearDown(() => build.delete(recursive: true));
    executable = p.join(build.path, Platform.isWindows ? 'kehai.exe' : 'kehai');
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'exe',
      'bin/kehai.dart',
      '-o',
      executable,
    ]);
    expect(
      compiled.exitCode,
      0,
      reason: '${compiled.stdout}\n${compiled.stderr}',
    );
  });

  setUp(() async {
    home = TestHome();
    home.store.replace(loggedInRecord());
    fake = await FakeOpenAi.start();
  });

  void expectNoStartupEffects() {
    expect(Directory(p.join(home.path, 'sessions')).existsSync(), isFalse);
    expect(fake.modelsRequests, isEmpty);
    expect(fake.responsesRequests, isEmpty);
    expect(fake.tokenRequests, isEmpty);
  }

  Future<({Directory workspace, List<String> args})> childFixture() async {
    final workspace = await tempDir();
    Directory(p.join(workspace.path, '.git')).createSync();
    final roles = Directory(p.join(workspace.path, '.claude', 'agents'))
      ..createSync(recursive: true);
    const text = '---\nname: reviewer\ndescription: Reviews\n---\nReview.\n';
    File(p.join(roles.path, 'reviewer.md')).writeAsStringSync(text);
    final parentWriter = await SessionWriter.create(await tempDir());
    final parent = parentWriter.sessionDir;
    await parentWriter.close();
    return (
      workspace: workspace,
      args: [
        '--child',
        '--parent',
        parent.path,
        '--job',
        'j-1',
        '--role',
        'reviewer',
        '--role-digest',
        sha256.convert(utf8.encode(text)).toString(),
      ],
    );
  }

  for (final scenario in [
    (
      name: 'direct child without marker uses config effort',
      config: 'low',
      flags: <String>[],
      expected: 'low',
    ),
    (
      name: 'direct child without marker honors flag over config',
      config: 'low',
      flags: ['--effort=high'],
      expected: 'high',
    ),
    (
      name: 'direct child without marker falls back to provider default',
      config: null,
      flags: <String>[],
      expected: null,
    ),
    (
      name: 'child default marker bypasses config selection',
      config: 'high',
      flags: ['--effort-default'],
      expected: null,
    ),
  ]) {
    test(scenario.name, () async {
      final fixture = await childFixture();
      File(p.join(home.path, 'config.json')).writeAsStringSync(
        jsonEncode({if (scenario.config != null) 'effort': scenario.config}),
      );
      // Child sessions live below the supplied parent, not the usual sessions root.
      final engine = await rpc.startEngine(
        ['--model', 'gpt-fake', ...fixture.args, ...scenario.flags],
        home: home,
        workspace: fixture.workspace,
        fake: fake,
      );
      fake.responsesScripts.add(ResponsesScript.sse(sseTextTurn('done')));
      try {
        final hello = await engine.nextLine();
        expect(hello['type'], 'hello', reason: '$hello');
        final snapshot = await engine.nextLine();
        engine.send({
          'type': 'submit',
          'id': 'direct',
          'text': 'review',
          'turn': snapshot['turn'],
        });
        await engine.lineWhere((event) {
          final record = event['record'];
          return record is Map &&
              record['path'] == 'meta/requests/direct' &&
              record['value'] is Map &&
              (record['value'] as Map)['state'] == 'completed';
        });
        await engine.process.stdin.close();
        expect(await engine.exitCode(), 0, reason: await engine.stderrText);
        final parent = fixture.args[2];
        final session = Directory(
          p.join(parent, 'agents', hello['session']! as String),
        );
        expectWireAndStep(fake, session, scenario.expected);
      } finally {
        engine.process.kill();
        await engine.process.exitCode;
        await engine.lines.cancel();
        await engine.stderrText;
      }
    });
  }

  test(
    'invalid config is refused even with inherited default marker',
    () async {
      final fixture = await childFixture();
      final path = p.join(home.path, 'config.json');
      for (final bad in <Object?>[null, true, 1, '', 'HIGH', 'turbo']) {
        File(path).writeAsStringSync(jsonEncode({'effort': bad}));
        final engine = await rpc.startEngine(
          [...fixture.args, '--effort-default'],
          home: home,
          workspace: fixture.workspace,
          fake: fake,
        );
        try {
          final fatal = await engine.nextLine();
          expect(fatal['type'], 'fatal');
          expect(
            fatal['message'],
            startsWith('$path: effort: must be one of '),
          );
          expect(await engine.exitCode(), 1, reason: await engine.stderrText);
          expectNoStartupEffects();
          expect(
            Directory(p.join(fixture.args[2], 'agents')).existsSync(),
            isFalse,
          );
        } finally {
          engine.process.kill();
          await engine.process.exitCode;
          await engine.lines.cancel();
          await engine.stderrText;
        }
      }
    },
  );

  for (final scenario in [
    (
      'flag effort overrides user config in rpc startup',
      'medium',
      'high',
      'high',
    ),
    ('config effort reaches request without flag', 'low', null, 'low'),
    (
      'provider default omits effort and records explicit null',
      null,
      null,
      null,
    ),
    ('explicit none reaches wire rather than omission', 'high', 'none', 'none'),
  ]) {
    test(scenario.$1, () async {
      final workspace = await tempDir();
      File(p.join(home.path, 'config.json')).writeAsStringSync(
        jsonEncode({if (scenario.$2 != null) 'effort': scenario.$2}),
      );
      final session = await effortRun(home, fake, workspace, [
        if (scenario.$3 != null) '--effort=${scenario.$3}',
      ]);
      expectWireAndStep(fake, session, scenario.$4);
    });
  }

  test('resume without effort does not inherit historical selection', () async {
    final workspace = await tempDir();
    final session = await effortRun(home, fake, workspace, ['--effort=high']);
    final writer = await SessionWriter.open(session);
    // Seed historical evidence independently of the feature under test.
    await writer.apply(
      rec(writer.currentTurn, 'body/steps/s-00000001', Op.merge, {
        'effort': 'high',
      }),
    );
    await writer.close();
    await effortRun(home, fake, workspace, ['--resume']);
    expectWireAndStep(fake, session, null);
    expect(effortSteps(session)['s-00000001'], containsPair('effort', 'high'));
  });

  test(
    'legacy steps remain unchanged and new steps record current effort',
    () async {
      final workspace = await tempDir();
      final session = await effortRun(home, fake, workspace, []);
      final writer = await SessionWriter.open(session);
      final legacy = Map<String, Object?>.from(
        effortSteps(session).values.single! as Map<String, Object?>,
      )..remove('effort');
      await writer.apply(
        rec(writer.currentTurn, 'body/steps/s-00000001', Op.set, legacy),
      );
      await writer.close();
      await effortRun(home, fake, workspace, ['--resume', '--effort=low']);
      expect(effortSteps(session)['s-00000001'], legacy);
      expectWireAndStep(fake, session, 'low');
    },
  );

  test(
    'client and rpc accept effort including leading and equals forms',
    () async {
      // No prompt is sent: group 2 checks startup inputs, not request propagation.
      for (final effort in [
        'none',
        'minimal',
        'low',
        'medium',
        'high',
        'xhigh',
      ]) {
        for (final prefix in [
          <String>[],
          ['rpc'],
        ]) {
          for (final option in [
            ['--effort', effort],
            ['--effort=$effort'],
          ]) {
            final captured = await captureStartup([
              ...prefix,
              ...option,
              '--model',
              'gpt-fake',
            ], home);
            if (prefix.isEmpty) {
              expect(captured.clientArgs, [
                '--model',
                'gpt-fake',
                '--effort',
                effort,
              ]);
              expect(
                captured.code,
                1,
                reason: 'the capturing starter refuses launch',
              );
              expect(captured.rpcStarts, 0);
            } else {
              expect(captured.clientArgs, isNull);
              expect(captured.rpcStarts, 1);
              expect(captured.effort, effort);
              expect(captured.code, 0);
            }
            final run = await cli.runCli(
              [...prefix, ...option, '--model', 'gpt-fake'],
              home: home,
              fake: fake,
              executable: executable,
            );
            expect(
              run.exitCode,
              0,
              reason: '$prefix $option: ${cli.allOutput(run)}',
            );
          }
        }
      }
      expect(fake.modelsRequests, hasLength(24));
      expect(fake.responsesRequests, isEmpty);
    },
  );

  test('invalid or missing effort exits 64 before engine startup', () async {
    for (final prefix in [
      <String>[],
      ['rpc'],
    ]) {
      for (final option in [
        ['--effort', 'HIGH'],
        ['--effort=turbo'],
        ['--effort='],
        ['--effort', ''],
        ['--effort'],
        ['--effort', '--model', 'gpt-fake'],
      ]) {
        final captured = await captureStartup([...prefix, ...option], home);
        expect(captured.code, 64);
        expect(
          captured.clientArgs,
          isNull,
          reason: 'client did not start an engine',
        );
        expect(captured.rpcStarts, 0, reason: 'rpc startup was not invoked');
        final run = await cli.runCli(
          [...prefix, ...option],
          home: home,
          fake: fake,
        );
        expect(run.exitCode, 64, reason: cli.allOutput(run));
        expect(run.stdout, isEmpty);
        expect(run.stderr, contains('effort'));
        expect(run.stderr, isNot(contains('Could not find an option named')));
        expect(run.stderr, contains('xhigh'), reason: 'prints effort usage');
        expectNoStartupEffects();
      }
    }
  });

  test('invalid effort names config path even with valid flag', () async {
    final path = p.join(home.path, 'config.json');
    for (final bad in <Object?>[
      null,
      1,
      true,
      <Object?>[],
      <String, Object?>{},
      '',
      'turbo',
      'HIGH',
      ' high',
    ]) {
      File(path).writeAsStringSync(jsonEncode({'effort': bad}));
      for (final prefix in [
        <String>[],
        ['rpc'],
      ]) {
        final run = await cli.runCli(
          [...prefix, '--effort', 'high', '--model', 'gpt-fake'],
          home: home,
          fake: fake,
        );
        expect(run.exitCode, 1, reason: cli.allOutput(run));
        if (prefix.isEmpty) {
          expect(run.stderr, startsWith('$path: effort: must be one of '));
        } else {
          final fatal = jsonDecode(run.stdout) as Map<String, Object?>;
          expect(fatal['type'], 'fatal');
          expect(
            fatal['message'],
            startsWith('$path: effort: must be one of '),
          );
          expect(run.stderr, isEmpty);
        }
        expectNoStartupEffects();
      }
    }
  });
}
