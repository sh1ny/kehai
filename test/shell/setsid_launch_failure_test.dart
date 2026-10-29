/// Pre-ship round 4, F2: under `setsid` a program that cannot run is a launch
/// failure, not an exit 127 (shell-tool and job-supervisor, "Launch failure").
library;

import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/bash_support.dart';
import '../support/job_support.dart';

void main() {
  final skip = skipUnlessUnix();

  ShellInfo vanished(String dir) => ShellInfo(
    kind: ShellKind.bash,
    executable: '$dir/no-such-bash',
    setsid: posixShell()!.setsid,
  );

  test(
    'a vanished shell under setsid fails the job pending to failed',
    () async {
      final h = await JobHarness.create();
      final handle = h.supervisor.start(
        JobRequest.shell(
          vanished(h.cwd),
          'echo hi',
          cwd: h.cwd,
          environment: Platform.environment,
        ),
      );

      final result = await handle.result;

      expect(result.state, 'failed');
      final node = h.node(handle.id)!;
      expect(node['state'], 'failed');
      expect(node['reason'], contains('No such file or directory'));
      expect(node.containsKey('exit'), isFalse);
      expect(h.states(handle.id), ['pending', 'failed']);
      expect(h.at('meta/handoffs/${handle.launch}'), isNull);
    },
    skip: skip,
  );

  test('a vanished shell under setsid settles the bash call failed', () async {
    final probe = await BashHarness.create();
    final h = await BashHarness.create(
      shell: ShellDetection.found(vanished(probe.workspace.path)),
    );

    final text = await h.call('bash', {'command': 'echo hi'});

    final node = h.lastCall;
    expect(node['status'], 'failed');
    expect(node['envelope'], 'error');
    final job = h.jobNodes.values.single;
    expect(job['state'], 'failed');
    expect(node['reason'], job['reason']);
    expect(job['reason'], contains('No such file or directory'));
    expect(text, contains('failed to start'));
    expect(text, isNot(contains('exit 127')));
  }, skip: skip);

  test(
    'startProcess under setsid throws for a missing or unrunnable program',
    () async {
      final h = await JobHarness.create();
      final setsid = posixShell()!.setsid!;
      final env = Platform.environment;
      final plain = File('${h.cwd}/plain')..writeAsStringSync('x');

      Future<void> launch(String program) async {
        final p = await startProcess(
          program,
          const [],
          workingDirectory: h.cwd,
          environment: env,
          setsid: setsid,
        );
        p.kill();
      }

      await expectLater(
        launch('${h.cwd}/missing'),
        throwsA(
          isA<ProcessException>().having((e) => e.errorCode, 'errorCode', 2),
        ),
      );
      await expectLater(
        launch('no-such-program-anywhere'),
        throwsA(isA<ProcessException>().having((e) => e.errorCode, 'code', 2)),
      );
      await expectLater(
        launch(plain.path),
        throwsA(isA<ProcessException>().having((e) => e.errorCode, 'code', 13)),
      );
      // A bare name on PATH still launches.
      final ok = await startProcess(
        'true',
        const [],
        workingDirectory: h.cwd,
        environment: env,
        setsid: setsid,
      );
      expect(await ok.exitCode, 0);
    },
    skip: skip,
  );
}
