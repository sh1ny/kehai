@Tags(['slow'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_openai.dart';
import '../support/login_support.dart';
import '../support/vcs_trust_support.dart';

final class _Client {
  _Client(this.process) {
    process.stdout.transform(utf8.decoder).listen((chunk) {
      output.write(chunk);
      for (final waiter in List<Completer<void>>.of(waiters)) {
        if (!waiter.isCompleted) waiter.complete();
      }
      waiters.clear();
    });
    errors = process.stderr.transform(utf8.decoder).join();
  }
  final Process process;
  final output = StringBuffer();
  final waiters = <Completer<void>>[];
  late final Future<String> errors;
  Future<void> until(bool Function(String) matches) async {
    while (!matches(output.toString())) {
      final waiter = Completer<void>();
      waiters.add(waiter);
      await waiter.future.timeout(const Duration(seconds: 90));
    }
  }

  Future<void> close() async {
    await process.stdin.close();
    expect(
      await process.exitCode.timeout(const Duration(seconds: 90)),
      0,
      reason: await errors,
    );
  }
}

Future<_Client> _start(
  ConfiguredVcsWorkspace fixture,
  TestHome home,
  FakeOpenAi fake,
  List<String> args,
) async {
  final root = Directory.current.path;
  final process = await Process.start(
    Platform.resolvedExecutable,
    [
      '--packages=${p.join(root, '.dart_tool', 'package_config.json')}',
      p.join(root, 'bin', 'kehai.dart'),
      ...args,
    ],
    workingDirectory: fixture.workspace.path,
    includeParentEnvironment: false,
    environment: {
      ...fixture.environment,
      'KEHAI_HOME': home.path,
      'KEHAI_OPENAI_ISSUER': fake.issuer,
      'KEHAI_OPENAI_API_BASE': fake.apiBase,
    },
  );
  addTearDown(process.kill);
  return _Client(process);
}

void main() {
  test(
    'line client trust reaches repository observation without persisted grant',
    () async {
      final fixture = await ConfiguredVcsWorkspace.create();
      final home = TestHome();
      home.store.replace(loggedInRecord());
      File(p.join(home.path, 'config.json')).writeAsStringSync(
        jsonEncode({
          'model': 'gpt-fake',
          'sensorium': {'collectorDeadlineMs': 10000},
        }),
      );
      final fake = await FakeOpenAi.start();
      for (final reply in [
        'untrusted-reply',
        'trusted-reply',
        'resumed-reply',
      ]) {
        fake.responsesScripts.add(ResponsesScript.sse(sseTextTurn(reply)));
      }
      final runs = <(List<String>, String, bool)>[
        ([], 'untrusted-reply', false),
        (['--trust-vcs', '--resume'], 'trusted-reply', true),
        (['--resume'], 'resumed-reply', false),
      ];
      for (final (args, reply, trusted) in runs) {
        fixture.clearMarkers();
        final client = await _start(fixture, home, fake, args);
        await client.until((text) => text.endsWith('> '));
        expect(fixture.monitorMarker.existsSync(), trusted);
        expect(fixture.filterMarker.existsSync(), trusted);
        client.process.stdin.writeln('observe workspace');
        await client.until(
          (text) => text.contains(reply) && text.endsWith('> '),
        );
        expect(fixture.monitorMarker.existsSync(), trusted);
        expect(fixture.filterMarker.existsSync(), trusted);
        await client.close();
      }
    },
  );
}
