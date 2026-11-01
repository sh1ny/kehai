@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:kehai/src/cli/cli.dart' as command;

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_openai.dart';
import '../support/login_support.dart';
import 'cli_test.dart' as cli;
import '../rpc/process_test.dart' as rpc;
import '../support/session_support.dart';

Future<({int code, List<String>? clientArgs, int rpcStarts, String? effort})>
captureStartup(List<String> args, TestHome home) async {
  List<String>? clientArgs;
  var rpcStarts = 0;
  String? effort;
  final code = await command.runCli(
    args,
    environment: {'KEHAI_HOME': home.path},
    out: StringBuffer(),
    err: StringBuffer(),
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
  late TestHome home;
  late FakeOpenAi fake;

  setUp(() async {
    home = TestHome();
    home.store.replace(loggedInRecord());
    fake = await FakeOpenAi.start();
  });

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

  void expectNoStartupEffects() {
    expect(Directory(p.join(home.path, 'sessions')).existsSync(), isFalse);
    expect(fake.modelsRequests, isEmpty);
    expect(fake.responsesRequests, isEmpty);
    expect(fake.tokenRequests, isEmpty);
  }

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
