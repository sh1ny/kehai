import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:kehai/kehai.dart';
import 'package:kehai/src/auth/dpapi_backend.dart';
import 'package:kehai/src/auth/posix_file_backend.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/session_support.dart';
import '../support/tool_support.dart';

const String _secret = 'SECRET-TOKEN-0123456789';
const String _token = 'access-token-AAAA1111';

/// Replaces the credential record in `args['home']` in a second isolate and
/// holds the write between the temporary file and the rename until the file
/// `args['release']` exists, so the caller can search meanwhile.
void _writeAndHold(Map<String, Object?> args) {
  final port = args['port']! as SendPort;
  final release = args['release']! as String;
  void hold() {
    port.send('held');
    while (!File(release).existsSync()) {}
  }

  final store = CredentialStore(
    home: args['home']! as String,
    backend: Platform.isWindows
        ? DpapiBackend(protect: (plain) => plain, beforeRename: hold)
        : PosixFileBackend(beforeRename: hold),
  );
  store.replace(
    CredentialRecord(
      hostId: 'urn:uuid:11111111-2222-3333-4444-555555555555',
      generation: 3,
      registration: const CredentialRegistration(
        issuer: 'https://auth.openai.com',
        clientId: 'client-xyz',
        subject: 'user-123',
        email: 'a@example.com',
        plan: 'plus',
        planUsageEnabled: true,
      ),
      tokens: CredentialTokens(
        idToken: 'id-token-CCCC3333',
        accessToken: _token,
        refreshToken: 'refresh-token-BBBB2222',
        expiresAt: DateTime.utc(2026, 10, 29, 12),
        scopes: const ['openid'],
        savedAt: DateTime.utc(2026, 10, 29, 11),
        lastRefresh: DateTime.utc(2026, 10, 29, 11, 30),
      ),
    ),
  );
  port.send('done');
}

/// The family of names the credential store writes in the Kehai home.
const List<String> _credentialNames = [
  'auth.json',
  'auth.dpapi',
  'auth.lock',
  'auth.json.1234_0.tmp',
];

void main() {
  late Directory ws;
  late Directory home;
  setUp(() async {
    ws = await tempDir();
    home = Directory(p.join(ws.path, '.kehai-home'))..createSync();
    for (final name in _credentialNames) {
      File(p.join(home.path, name)).writeAsStringSync(_secret);
    }
  });

  Future<ToolRuntime> attach({required bool gated}) async {
    final writer = await createWriter(ws);
    final runtime = await ToolRuntime.attach(
      writer,
      ResultStore(writer.sessionDir),
      workspace: ws,
      kehaiHome: home,
      yolo: true,
      gate: gated ? null : const AllowAllStage(),
    );
    addTearDown(runtime.close);
    return runtime;
  }

  Map<String, Object?> args(String tool, String path) => switch (tool) {
    'read' => {'path': path},
    'edit' => {
      'path': path,
      'anchors': ['1#AAAA'],
      'ops': [
        {'op': 'delete', 'start': 1, 'end': 1},
      ],
    },
    _ => {'path': path, 'content': 'overwritten'},
  };

  test(
    'file tools refuse every auth.* in the Kehai home even under yolo',
    () async {
      // The gate refuses first; with no gate the tools refuse on their own.
      for (final gated in [true, false]) {
        final runtime = await attach(gated: gated);
        var n = 0;
        for (final name in _credentialNames) {
          for (final tool in ['read', 'edit', 'write']) {
            final paths = [
              p.join('.kehai-home', name),
              p.join(home.path, name),
              p.join('sub', '..', '.kehai-home', name),
            ];
            for (final path in paths) {
              final id = 'c${gated ? 'g' : 'n'}${n++}';
              final item = await runtime.run(
                ToolCall(
                  callId: id,
                  name: tool,
                  argumentsJson: jsonEncode(args(tool, path)),
                ),
              );

              final reason = 'gated=$gated $tool $path';
              expect(item.output, startsWith('[$tool denied]'), reason: reason);
              expect(
                item.output,
                contains('credential files are not readable by tools'),
                reason: reason,
              );
              expect(item.output, isNot(contains(_secret)), reason: reason);
              final node =
                  runtime.writer.tree.get(
                        SessionPath.parse('body/calls/${callKey(id)}'),
                      )!
                      as Map<String, Object?>;
              expect(node['status'], 'settled', reason: reason);
              expect(node['envelope'], 'denied', reason: reason);
              final handle =
                  (node['result']! as Map<String, Object?>)['handle']!
                      as String;
              final stored = resolveHandle(
                runtime.writer.tree,
                runtime.writer.sessionDir,
                handle,
              ).file.readAsStringSync();
              expect(stored, isNot(contains(_secret)), reason: reason);
            }
          }
        }
        // Nothing was read, edited, replaced or left behind.
        for (final name in _credentialNames) {
          expect(
            File(p.join(home.path, name)).readAsStringSync(),
            _secret,
            reason: name,
          );
        }
        expect(
          home.listSync().map((e) => p.basename(e.path)).toList()..sort(),
          [..._credentialNames]..sort(),
        );
      }
    },
  );

  group('search tools', () {
    late RgFound rg;
    setUpAll(() async {
      rg = await resolveRg(configPath: 'config.json') as RgFound;
    });

    Future<(ToolOutcome, RecordingOutput)> run(
      Tool tool,
      Directory home,
      Map<String, Object?> input,
    ) async {
      final output = RecordingOutput();
      final outcome = await tool.run(
        toolContext(ws, output, kehaiHome: home),
        input,
      );
      return (outcome, output);
    }

    test(
      'glob metacharacters in the home path do not defeat the exclusion',
      () async {
        final names = [
          'home[1]',
          'home{a,b}',
          if (!Platform.isWindows) ...['home*x', 'home?y', 'home!z', r'home\w'],
        ];
        final grep = GrepTool(Future.value(rg));
        final find = FindTool(Future.value(rg));
        for (final name in names) {
          final odd = Directory(p.join(ws.path, 'outer', name))
            ..createSync(recursive: true);
          for (final file in _credentialNames) {
            File(p.join(odd.path, file)).writeAsStringSync(_secret);
          }
          File(p.join(odd.path, 'config.json')).writeAsStringSync(_secret);
          final want = 'outer/$name/config.json';
          final (outcome, output) = await run(grep, odd, {
            'pattern': 'SECRET-TOKEN',
            'path': 'outer',
          });
          expect(outcome.status, ResultStatus.ok, reason: name);
          expect(outcome.summary, contains('credential files excluded'));
          expect(output.lines, ['$want:1: $_secret'], reason: name);
          final (found, foundOut) = await run(find, odd, {
            'glob': '*',
            'path': 'outer',
          });
          expect(found.summary, contains('credential files excluded'));
          expect(foundOut.lines, [want], reason: name);
          odd.deleteSync(recursive: true);
        }
      },
    );

    test('grep over the home excludes auth.* and says so', () async {
      final visible = Directory(p.join(ws.path, 'khome'))..createSync();
      for (final name in _credentialNames) {
        File(p.join(visible.path, name)).writeAsStringSync(_secret);
      }
      File(p.join(visible.path, 'config.json')).writeAsStringSync(_secret);
      final grep = GrepTool(Future.value(rg));

      // The workspace root contains the home, and so does the home itself.
      for (final (input, want) in [
        (
          <String, Object?>{'pattern': 'SECRET-TOKEN'},
          'khome/config.json:1: $_secret',
        ),
        (
          <String, Object?>{'pattern': 'SECRET-TOKEN', 'path': 'khome'},
          'khome/config.json:1: $_secret',
        ),
      ]) {
        final (outcome, output) = await run(grep, visible, input);
        expect(outcome.status, ResultStatus.ok, reason: '$input');
        expect(outcome.summary, contains('credential files excluded'));
        expect(output.lines, [want], reason: '$input');
      }

      // find lists no credential file either.
      final (found, foundOut) = await run(FindTool(Future.value(rg)), visible, {
        'glob': '*',
        'path': 'khome',
      });
      expect(found.summary, contains('credential files excluded'));
      expect(foundOut.lines, ['khome/config.json']);

      // A search that does not cover the home says nothing about it.
      Directory(p.join(ws.path, 'other')).createSync();
      File(p.join(ws.path, 'other', 'x.txt')).writeAsStringSync(_secret);
      final (elsewhere, _) = await run(grep, visible, {
        'pattern': 'SECRET-TOKEN',
        'path': 'other',
      });
      expect(elsewhere.summary, isNot(contains('credential files excluded')));

      // Naming a credential file is refused outright.
      final (direct, directOut) = await run(grep, visible, {
        'pattern': 'SECRET-TOKEN',
        'path': p.join('khome', 'auth.json'),
      });
      expect(direct.status, ResultStatus.denied);
      expect(directOut.total, 0);
    });

    test('paused credential temp file is never matched or stored', () async {
      final visible = Directory(p.join(ws.path, 'khome'));
      final release = File(p.join(ws.path, 'release'));
      addTearDown(() {
        if (!release.existsSync()) release.writeAsStringSync('x');
      });
      if (!Platform.isWindows) Process.runSync('chmod', ['700', ws.path]);
      File(p.join(ws.path, 'note.txt')).writeAsStringSync(_token);

      final port = ReceivePort();
      final events = StreamIterator<Object?>(port);
      addTearDown(port.close);
      await Isolate.spawn(_writeAndHold, {
        'port': port.sendPort,
        'home': visible.path,
        'release': release.path,
      });
      expect(await events.moveNext() ? events.current : null, 'held');

      // The temporary file is on disk, with the token inside, right now.
      final temps = visible
          .listSync()
          .map((e) => p.basename(e.path))
          .where((n) => n.endsWith('.tmp'))
          .toList();
      expect(temps, hasLength(1));
      expect(temps.single, startsWith('auth.'));
      expect(
        File(p.join(visible.path, temps.single)).readAsStringSync(),
        contains(_token),
      );

      final grep = GrepTool(Future.value(rg));
      final (whole, wholeOut) = await run(grep, visible, {
        'pattern': 'access-token-AAAA',
      });
      final (inHome, inHomeOut) = await run(grep, visible, {
        'pattern': 'access-token-AAAA',
        'path': 'khome',
      });

      release.writeAsStringSync('x');
      expect(await events.moveNext() ? events.current : null, 'done');

      // Only the ordinary file matched; no byte of the temporary file reached
      // the output.
      expect(whole.status, ResultStatus.ok);
      expect(wholeOut.lines, ['note.txt:1: $_token']);
      expect(inHome.status, ResultStatus.ok);
      expect(inHome.summary, startsWith('no matches'));
      expect(inHome.summary, contains('credential files excluded'));
      expect(inHomeOut.total, 0);
    });
  });
}
