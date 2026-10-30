/// End-to-end tests of `kehai rpc` as a process (design D13).
///
/// Each test starts the real executable against the loopback fake, with
/// `KEHAI_HOME` set to a temporary directory.
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_openai.dart';
import '../support/login_support.dart';

/// The directory key of [workspace] under the sessions tree (design D13).
String keyOf(String workspace) => sha256
    .convert(utf8.encode(p.canonicalize(realPath(workspace)!)))
    .toString()
    .substring(0, 16);

/// A started `kehai rpc` process with its stdout read line by line.
final class Engine {
  Engine._(this.process, this.lines, this.stderrText);

  final Process process;

  /// Decoded stdout lines.
  final StreamIterator<Map<String, Object?>> lines;

  /// Everything the process wrote to stderr.
  final Future<String> stderrText;

  Future<Map<String, Object?>> nextLine() async {
    final more = await lines.moveNext().timeout(
      const Duration(seconds: 90),
      onTimeout: () => fail('the engine wrote no line'),
    );
    if (!more) fail('the engine closed stdout');
    return lines.current;
  }

  Future<int> exitCode() => process.exitCode.timeout(
    const Duration(seconds: 90),
    onTimeout: () {
      process.kill();
      fail('the engine did not exit');
    },
  );
}

Future<Engine> startEngine(
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
      'rpc',
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
  final lines = StreamIterator(
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .map((line) => jsonDecode(line) as Map<String, Object?>),
  );
  return Engine._(
    process,
    lines,
    process.stderr.transform(utf8.decoder).join(),
  );
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
        // The engine process may still hold its working directory on Windows.
      }
    });
  });

  group('Session opened for the workspace', () {
    test(
      'rpc starts with hello v1 and a session under the workspace key',
      () async {
        final fake = await FakeOpenAi.start();
        home.store.replace(loggedInRecord());
        File(p.join(home.path, 'config.json'))
            .writeAsStringSync(jsonEncode({'model': 'gpt-fake'}));

        final engine = await startEngine(
          const [],
          home: home,
          workspace: workspace,
          fake: fake,
        );
        final hello = await engine.nextLine();

        expect(hello['type'], 'hello');
        expect(hello['protocol'], 1);
        expect(hello['model'], 'gpt-fake');
        expect(hello['workspace'], realPath(workspace.path));
        final session = hello['session']! as String;
        final dir = Directory(
          p.join(home.path, 'sessions', keyOf(workspace.path), session),
        );
        expect(dir.existsSync(), isTrue);
        final snapshot = await engine.nextLine();
        expect(snapshot['type'], 'snapshot');
        final meta =
            (snapshot['tree']! as Map<String, Object?>)['meta']!
                as Map<String, Object?>;
        expect(meta['session'], session);
        expect(meta['workspace'], p.canonicalize(realPath(workspace.path)!));
        expect(fake.modelsRequests, hasLength(1), reason: 'models listed once');

        await engine.process.stdin.close();
        expect(await engine.exitCode(), 0);
      },
    );

    test('resume of a locked session writes fatal naming the holder and '
        'exits 1', () async {
      final sessions = Directory(
        p.join(home.path, 'sessions', keyOf(workspace.path)),
      )..createSync(recursive: true);
      final held = await SessionWriter.create(sessions);
      addTearDown(held.close);
      final journal = File(p.join(held.sessionDir.path, journalFileName));
      final before = journal.readAsBytesSync();

      final engine = await startEngine(
        const ['--resume'],
        home: home,
        workspace: workspace,
      );
      final fatal = await engine.nextLine();

      expect(fatal['type'], 'fatal');
      expect(fatal['message'], contains('session locked'));
      expect(fatal['message'], contains('pid $pid'));
      expect(await engine.exitCode(), 1);
      expect(journal.readAsBytesSync(), before);
    });

    test('resume with no session writes fatal and exits 1', () async {
      final engine = await startEngine(
        const ['--resume'],
        home: home,
        workspace: workspace,
      );
      final fatal = await engine.nextLine();

      expect(fatal['type'], 'fatal');
      expect(fatal['message'], 'no session to resume for this workspace');
      expect(await engine.exitCode(), 1);
    });
  });
}
