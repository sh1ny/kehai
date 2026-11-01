@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:kehai/src/cli/cli.dart' as command;

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_openai.dart';
import '../support/login_support.dart';
import 'cli_test.dart' as cli;

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

void main() {
  late TestHome home;
  late FakeOpenAi fake;

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
