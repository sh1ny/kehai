/// End-to-end tests of `kehai` (the line client) as a process, which starts
/// `kehai rpc` as its engine against the loopback fake (design D1).
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_openai.dart';
import '../support/login_support.dart';

/// A started `kehai` client with its output collected.
final class Client {
  Client._(this.process) {
    process.stdout
        .transform(utf8.decoder)
        .listen((chunk) => _stdout.write(chunk));
    process.stderr
        .transform(utf8.decoder)
        .listen((chunk) => _stderr.write(chunk));
  }

  final Process process;
  final StringBuffer _stdout = StringBuffer();
  final StringBuffer _stderr = StringBuffer();

  /// Everything written to standard output so far.
  String get stdoutText => _stdout.toString();

  /// Everything written to standard error so far.
  String get stderrText => _stderr.toString();

  /// Waits until standard output satisfies [test].
  Future<void> untilOut(bool Function(String text) test) async {
    final deadline = DateTime.now().add(const Duration(seconds: 90));
    while (!test(stdoutText)) {
      if (DateTime.now().isAfter(deadline)) {
        fail('timed out; stdout:\n$stdoutText\nstderr:\n$stderrText');
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
  }

  /// The exit code, after standard output and error were drained.
  Future<int> exitCode() async {
    final code = await process.exitCode.timeout(
      const Duration(seconds: 90),
      onTimeout: () {
        process.kill();
        fail('kehai did not exit; stdout:\n$stdoutText\nstderr:\n$stderrText');
      },
    );
    await pumpEventQueue();
    return code;
  }
}

Future<Client> startClient(
  List<String> args, {
  required TestHome home,
  required Directory workspace,
  FakeOpenAi? fake,
}) async {
  final root = Directory.current.path;
  final process = await Process.start(
    Platform.resolvedExecutable,
    [
      '--packages=${p.join(root, '.dart_tool', 'package_config.json')}',
      p.join(root, 'bin', 'kehai.dart'),
      ...args,
    ],
    workingDirectory: workspace.path,
    environment: {
      'KEHAI_HOME': home.path,
      if (fake != null) 'KEHAI_OPENAI_ISSUER': fake.issuer,
      if (fake != null) 'KEHAI_OPENAI_API_BASE': fake.apiBase,
    },
  );
  addTearDown(process.kill);
  return Client._(process);
}

void main() {
  late TestHome home;
  late Directory workspace;

  setUp(() {
    home = TestHome();
    workspace = Directory.systemTemp.createTempSync('kehai_ws_');
    addTearDown(() {
      try {
        if (workspace.existsSync()) workspace.deleteSync(recursive: true);
      } on FileSystemException {
        // A process may still hold its working directory on Windows.
      }
    });
  });

  group('Client over the engine process', () {
    test(
      'kehai --model starts kehai rpc and shows session, model and prompt',
      () async {
        final fake = await FakeOpenAi.start();
        home.store.replace(loggedInRecord());

        final client = await startClient(
          const ['--model', 'gpt-fake'],
          home: home,
          workspace: workspace,
          fake: fake,
        );
        await client.untilOut((text) => text.endsWith('> '));

        final header = RegExp(r'session (\S+) +model gpt-fake')
            .firstMatch(client.stdoutText);
        expect(header, isNotNull, reason: client.stdoutText);
        final session = header!.group(1)!;
        final onDisk = Directory(p.join(home.path, 'sessions'))
            .listSync(recursive: true)
            .whereType<Directory>();
        expect(onDisk.any((d) => p.basename(d.path) == session), isTrue);
        expect(fake.modelsRequests, hasLength(1));

        await client.process.stdin.close();
        expect(await client.exitCode(), 0);
      },
    );

    test('logged-out start prints the engine fatal and exits 1', () async {
      final client = await startClient(
        const ['--model', 'gpt-fake'],
        home: home,
        workspace: workspace,
      );

      expect(await client.exitCode(), 1);
      expect(client.stderrText, contains('kehai login openai'));
    });
  });

  group('Model selection', () {
    test('no model anywhere fails with the hint and the model list', () async {
      final fake = await FakeOpenAi.start();
      home.store.replace(loggedInRecord());

      final client = await startClient(
        const [],
        home: home,
        workspace: workspace,
        fake: fake,
      );

      expect(await client.exitCode(), 1);
      expect(
        client.stderrText,
        contains('no model selected; use --model <id> or set "model" in '),
      );
      expect(client.stderrText, contains('available models: gpt-fake'));
    });

    test('unlisted model fails naming it and the model list', () async {
      final fake = await FakeOpenAi.start();
      home.store.replace(loggedInRecord());

      final client = await startClient(
        const ['--model', 'gpt-0'],
        home: home,
        workspace: workspace,
        fake: fake,
      );

      expect(await client.exitCode(), 1);
      expect(client.stderrText, contains('model gpt-0 is not available'));
      expect(client.stderrText, contains('available models: gpt-fake'));
    });
  });

  group('Native Windows and Linux', () {
    test('piped two lines run in order and exit at end of input', () async {
      final fake = await FakeOpenAi.start();
      home.store.replace(loggedInRecord());
      fake.responsesScripts
        ..add(ResponsesScript.sse(sseTextTurn('first reply')))
        ..add(ResponsesScript.sse(sseTextTurn('second reply')));

      final client = await startClient(
        const ['--model', 'gpt-fake'],
        home: home,
        workspace: workspace,
        fake: fake,
      );
      client.process.stdin.write('one\ntwo\n');
      await client.process.stdin.close();

      expect(await client.exitCode(), 0);
      final out = client.stdoutText;
      expect(out, contains('first reply'));
      expect(out, contains('second reply'));
      expect(out.indexOf('first reply'), lessThan(out.indexOf('second reply')));
      expect(fake.responsesRequests, hasLength(2));
    });
  });
}
