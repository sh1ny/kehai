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
import '../support/killed_exchange_support.dart';
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

  /// Reads lines until one satisfies [test], answering every permission prompt
  /// with `allow` on the way.
  Future<Map<String, Object?>> lineWhere(
    bool Function(Map<String, Object?> line) test,
  ) async {
    while (true) {
      final line = await nextLine();
      if (line['type'] == 'prompt') {
        final item = line['item']! as Map<String, Object?>;
        send({'type': 'answer', 'key': item['key'], 'text': 'allow'});
      }
      if (test(line)) return line;
    }
  }

  void send(Map<String, Object?> command) =>
      process.stdin.writeln(jsonEncode(command));

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

/// Whether [line] is an update that sets the node at [path] to a map with
/// `state` or `status` equal to [value].
bool _updates(Map<String, Object?> line, String path, String value) {
  if (line['type'] != 'update') return false;
  final record = line['record']! as Map<String, Object?>;
  final node = record['value'];
  return record['path'] == path &&
      node is Map<String, Object?> &&
      (node['state'] == value || node['status'] == value);
}

void main() {
  final unixOnly = Platform.isWindows ? 'unix only' : false;
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

  group('Interrupt, answer and status', () {
    test(
      'status of a request killed mid-exchange is interrupted effect-uncertain',
      () async {
        final fake = await FakeOpenAi.start();
        home.store.replace(loggedInRecord());
        File(p.join(home.path, 'config.json'))
            .writeAsStringSync(jsonEncode({'model': 'gpt-fake'}));
        final killed = await startKilledExchange(
          sessions: Directory(
            p.join(home.path, 'sessions', keyOf(workspace.path)),
          ),
          workspace: workspace,
        );
        await killed.kill();

        final engine = await startEngine(
          const ['--resume'],
          home: home,
          workspace: workspace,
          fake: fake,
        );
        final hello = await engine.nextLine();
        final snapshot = await engine.nextLine();

        expect(hello['type'], 'hello');
        expect(hello['resumed'], containsPair('requests', 1));
        expect(hello['resumed'], containsPair('exchanges', 1));
        final body =
            (snapshot['tree']! as Map<String, Object?>)['body']!
                as Map<String, Object?>;
        for (final node in [
          (body['exchanges']! as Map<String, Object?>)['x-00000001'],
          (body['steps']! as Map<String, Object?>)['s-00000001'],
        ]) {
          expect(node, containsPair('state', 'cancelled'));
          expect(node, containsPair('reason', 'interrupted'));
        }

        engine.process.stdin.writeln(
          jsonEncode({'type': 'status', 'id': 'r9'}),
        );
        final reply = await engine.nextLine();
        expect(reply['type'], 'reply');
        expect(reply['to'], 'r9');
        expect(reply['state'], 'interrupted');
        expect(reply['reason'], 'effect-uncertain');
        expect(fake.responsesRequests, isEmpty, reason: 'not executed again');

        await engine.process.stdin.close();
        expect(await engine.exitCode(), 0);
      },
    );
  });

  group('Signals and client loss', () {
    test('[unix] SIGINT to the engine does not stop the exchange', () async {
      final fake = await FakeOpenAi.start();
      home.store.replace(loggedInRecord());
      File(p.join(home.path, 'config.json'))
          .writeAsStringSync(jsonEncode({'model': 'gpt-fake'}));
      final turn = sseTextTurn('par');
      fake.responsesScripts.add(
        ResponsesScript.sse([
          turn[0],
          turn[1],
          const Delay(Duration(seconds: 2)),
          ...turn.skip(2),
        ]),
      );
      final engine = await startEngine(
        const [],
        home: home,
        workspace: workspace,
        fake: fake,
      );
      await engine.nextLine();
      await engine.nextLine();
      engine.send({'type': 'submit', 'id': 'r1', 'text': 'hi', 'turn': 0});
      await engine.lineWhere((l) => l['type'] == 'stream');

      expect(engine.process.kill(ProcessSignal.sigint), isTrue);

      final done = await engine.lineWhere(
        (l) => _updates(l, 'meta/requests/r1', 'completed'),
      );
      final outcome =
          ((done['record']! as Map<String, Object?>)['value']!
                  as Map<String, Object?>)['outcome']
              as Map<String, Object?>;
      expect(outcome['state'], 'done');
      await engine.process.stdin.close();
      expect(await engine.exitCode(), 0);
    }, skip: unixOnly);

    test('stdin EOF cancels the foreground bash, releases the lock and '
        'exits 0', () async {
      final fake = await FakeOpenAi.start();
      home.store.replace(loggedInRecord());
      File(p.join(home.path, 'config.json'))
          .writeAsStringSync(jsonEncode({'model': 'gpt-fake'}));
      fake.responsesScripts.add(
        ResponsesScript.sse([
          SseEvent.json('response.created', {
            'response': {'id': 'resp_1'},
          }),
          SseEvent.json('response.output_item.done', {
            'item': {
              'type': 'function_call',
              'call_id': 'call_sleep',
              'name': 'bash',
              'arguments': jsonEncode({'command': 'sleep 120'}),
            },
          }),
          SseEvent.json('response.completed', {
            'response': {'id': 'resp_1'},
          }),
        ]),
      );
      final engine = await startEngine(
        const [],
        home: home,
        workspace: workspace,
        fake: fake,
      );
      final hello = await engine.nextLine();
      await engine.nextLine();
      engine.send({'type': 'submit', 'id': 'r1', 'text': 'wait', 'turn': 0});
      final key = callKey('call_sleep');
      await engine.lineWhere((l) => _updates(l, 'body/calls/$key', 'running'));

      await engine.process.stdin.close();

      expect(await engine.exitCode(), 0);
      final dir = Directory(
        p.join(
          home.path,
          'sessions',
          keyOf(workspace.path),
          hello['session']! as String,
        ),
      );
      final reopened = await SessionWriter.open(dir);
      addTearDown(reopened.close);
      final tree = reopened.tree;
      expect(
        tree.get(SessionPath.parse('body/calls/$key')),
        allOf(
          containsPair('status', 'cancelled'),
          containsPair('reason', 'shutdown'),
        ),
      );
      expect(
        tree.get(SessionPath.parse('body/exchanges/x-00000001')),
        allOf(
          containsPair('state', 'cancelled'),
          containsPair('reason', 'shutdown'),
        ),
      );
    });
  });
}
