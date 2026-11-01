/// End-to-end tests of `kehai rpc --child` as a process (design D8, D9).
///
/// Each test starts the real executable against the loopback fake, with
/// `KEHAI_HOME` set to a temporary directory and a parent session that exists
/// only as a directory the child writes under.
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

const String _reviewerTools = 'Read, Grep, Glob, Bash, Write, Skill';

/// A role file's text.
String _roleText({
  String name = 'specwright-reviewer',
  String? tools = _reviewerTools,
  String body = 'ROLE-MARKER-ORIGINAL: review with care.',
}) =>
    '---\n'
    'name: $name\n'
    'description: Reviews changes\n'
    '${tools == null ? '' : 'tools: $tools\n'}'
    '---\n'
    '$body\n';

String _digestOf(String text) => sha256.convert(utf8.encode(text)).toString();

/// A started `kehai rpc --child` process with its stdout read line by line.
final class _Child {
  _Child(this.process)
    : lines = StreamIterator(
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .map((line) => jsonDecode(line) as Map<String, Object?>),
      ),
      stderrText = process.stderr.transform(utf8.decoder).join();

  final Process process;
  final StreamIterator<Map<String, Object?>> lines;
  final Future<String> stderrText;

  Future<Map<String, Object?>> nextLine() async {
    final more = await lines.moveNext().timeout(
      const Duration(seconds: 90),
      onTimeout: () => fail('the child wrote no line'),
    );
    if (!more) fail('the child closed stdout');
    return lines.current;
  }

  /// Reads lines until the update that completes request [id].
  Future<void> untilCompleted(String id) async {
    while (true) {
      final line = await nextLine();
      if (line['type'] != 'update') continue;
      final record = line['record']! as Map<String, Object?>;
      final value = record['value'];
      if (record['path'] == 'meta/requests/$id' &&
          value is Map<String, Object?> &&
          value['state'] == 'completed') {
        return;
      }
    }
  }

  void send(Map<String, Object?> command) =>
      process.stdin.writeln(jsonEncode(command));

  Future<int> exitCode() => process.exitCode.timeout(
    const Duration(seconds: 90),
    onTimeout: () {
      process.kill();
      fail('the child did not exit');
    },
  );

  /// Closes standard input, as the parent does, and returns the exit code.
  Future<int> finish() async {
    await process.stdin.close();
    return exitCode();
  }
}

List<ScriptStep> _toolCallTurn(String callId, String name, Object arguments) =>
    [
      SseEvent.json('response.created', {
        'response': {'id': 'resp_1'},
      }),
      SseEvent.json('response.output_item.done', {
        'item': {
          'type': 'function_call',
          'call_id': callId,
          'name': name,
          'arguments': jsonEncode(arguments),
        },
      }),
      SseEvent.json('response.completed', {
        'response': {'id': 'resp_1'},
      }),
    ];

/// The tool names of a recorded Responses request.
List<String> _toolNames(RecordedRequest request) {
  final input = request.json!['input']! as List<Object?>;
  final head = input.first! as Map<String, Object?>;
  return [
    for (final tool in head['tools']! as List<Object?>)
      (tool! as Map<String, Object?>)['name']! as String,
  ];
}

void main() {
  late TestHome home;
  late Directory workspace;
  late Directory parent;
  late String parentId;

  setUp(() async {
    home = TestHome();
    workspace = Directory.systemTemp.createTempSync('kehai_child_ws_');
    Directory(p.join(workspace.path, '.git')).createSync();
    addTearDown(() {
      try {
        if (workspace.existsSync()) workspace.deleteSync(recursive: true);
      } on FileSystemException {
        // The child may still hold its working directory on Windows.
      }
    });
    final sessions = Directory(
      p.join(home.path, 'sessions', workspaceKey(workspace.path)),
    )..createSync(recursive: true);
    // The sessions folder created the home with the default mode; the
    // credential store refuses a home others can read.
    if (!Platform.isWindows) Process.runSync('chmod', ['700', home.path]);
    final writer = await SessionWriter.create(sessions);
    parentId = p.basename(writer.sessionDir.path);
    parent = writer.sessionDir;
    await writer.close();
  });

  void login() {
    home.store.replace(loggedInRecord());
    File(p.join(home.path, 'config.json'))
        .writeAsStringSync(jsonEncode({'model': 'gpt-fake'}));
  }

  File writeRole(String text, {String file = 'specwright-reviewer.md'}) {
    final dir = Directory(p.join(workspace.path, '.claude', 'agents'))
      ..createSync(recursive: true);
    return File(p.join(dir.path, file))..writeAsStringSync(text);
  }

  Future<_Child> startChild({
    FakeOpenAi? fake,
    String role = 'specwright-reviewer',
    required String roleDigest,
    String job = 'j3',
    List<String> extra = const [],
  }) async {
    final root = Directory.current.path;
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        '--packages=${p.join(root, '.dart_tool', 'package_config.json')}',
        p.join(root, 'bin', 'kehai.dart'),
        'rpc',
        '--child',
        '--parent',
        parent.path,
        '--job',
        job,
        '--role',
        role,
        '--role-digest',
        roleDigest,
        '--model',
        'gpt-fake',
        ...extra,
      ],
      workingDirectory: workspace.path,
      environment: {
        'KEHAI_HOME': home.path,
        if (fake != null) 'KEHAI_OPENAI_ISSUER': fake.issuer,
        if (fake != null) 'KEHAI_OPENAI_API_BASE': fake.apiBase,
      },
    );
    addTearDown(process.kill);
    return _Child(process);
  }

  Directory agentsDir() => Directory(p.join(parent.path, 'agents'));

  group('Child engine mode', () {
    test('child mode hello names protocol 1, the child session and '
        'model', () async {
      final fake = await FakeOpenAi.start();
      login();
      final text = _roleText();
      writeRole(text);

      final child = await startChild(fake: fake, roleDigest: _digestOf(text));
      final hello = await child.nextLine();

      expect(hello['type'], 'hello');
      expect(hello['protocol'], 1);
      expect(hello['model'], 'gpt-fake');
      expect(hello['workspace'], realPath(workspace.path));
      final session = hello['session']! as String;
      expect(Directory(p.join(agentsDir().path, session)).existsSync(), isTrue);
      expect((await child.nextLine())['type'], 'snapshot');

      expect(await child.finish(), 0);
    });

    test('child mode with an unknown role is fatal and creates no '
        'session', () async {
      // No login: the role is checked before anything else can fail.
      writeRole(_roleText());

      final child = await startChild(role: 'nope', roleDigest: 'abc');
      final fatal = await child.nextLine();

      expect(fatal['type'], 'fatal');
      expect(fatal['message'], 'unknown agent role nope');
      expect(await child.exitCode(), 1);
      expect(agentsDir().existsSync(), isFalse);
    });

    test('child mode with a changed role file is fatal and creates no '
        'session', () async {
      login();
      final text = _roleText();
      writeRole(text);

      final child = await startChild(
        roleDigest: _digestOf('${text}edited later\n'),
      );
      final fatal = await child.nextLine();

      expect(fatal['type'], 'fatal');
      expect(fatal['message'], 'role changed');
      expect(await child.exitCode(), 1);
      expect(agentsDir().existsSync(), isFalse);
    });

    test('child mode refuses resume and session', () async {
      login();
      final text = _roleText();
      writeRole(text);

      for (final flag in [
        ['--resume'],
        ['--session', 'x'],
      ]) {
        final child = await startChild(
          roleDigest: _digestOf(text),
          extra: flag,
        );
        expect(await child.exitCode(), isNot(0), reason: '$flag');
        expect(agentsDir().existsSync(), isFalse, reason: '$flag');
      }
    });

    test('the child session lives under the parent and records its '
        'lineage', () async {
      final fake = await FakeOpenAi.start();
      login();
      fake.responsesScripts.add(ResponsesScript.sse(sseTextTurn('VERDICT')));
      final text = _roleText();
      writeRole(text);

      final child = await startChild(fake: fake, roleDigest: _digestOf(text));
      final hello = await child.nextLine();
      final snapshot = await child.nextLine();
      final meta =
          (snapshot['tree']! as Map<String, Object?>)['meta']!
              as Map<String, Object?>;
      expect(meta['lineage'], {'parent': parentId, 'job': 'j3'});

      child.send({
        'type': 'submit',
        'id': 'agent',
        'text': 'review',
        'turn': 0,
      });
      await child.untilCompleted('agent');
      expect(await child.finish(), 0);

      final dir = Directory(
        p.join(parent.path, 'agents', hello['session']! as String),
      );
      final reopened = await SessionWriter.open(dir);
      addTearDown(reopened.close);
      expect(reopened.tree.get(SessionPath.parse('meta/lineage')), {
        'parent': parentId,
        'job': 'j3',
      });
      final exchange =
          reopened.tree.get(SessionPath.parse('body/exchanges/x-00000001'))!
              as Map<String, Object?>;
      expect(exchange['prompt'], 'review');
      expect(exchange['state'], 'done');
    });

    test('a rebuilt child request carries the role text captured at '
        'start', () async {
      final fake = await FakeOpenAi.start();
      login();
      fake.responsesScripts.add(ResponsesScript.sse(sseTextTurn('VERDICT')));
      final text = _roleText();
      final file = writeRole(text);

      final child = await startChild(fake: fake, roleDigest: _digestOf(text));
      final hello = await child.nextLine();
      await child.nextLine();
      child.send({
        'type': 'submit',
        'id': 'agent',
        'text': 'review',
        'turn': 0,
      });
      await child.untilCompleted('agent');
      expect(await child.finish(), 0);

      final sent =
          fake.responsesRequests.single.json!['instructions']! as String;
      expect(sent, contains('ROLE-MARKER-ORIGINAL'));
      expect(sent, contains('specwright-reviewer'));

      // The role file is edited, then deleted, after the child ended.
      file.writeAsStringSync(_roleText(body: 'ROLE-MARKER-EDITED'));
      file.deleteSync();

      final dir = Directory(
        p.join(parent.path, 'agents', hello['session']! as String),
      );
      final reopened = await SessionWriter.open(dir);
      addTearDown(reopened.close);
      final step =
          reopened.tree.get(SessionPath.parse('body/steps/s-00000001'))!
              as Map<String, Object?>;
      expect(
        (step['instructions']! as Map<String, Object?>)['role'],
        _digestOf(text),
      );
      final rebuilt = await RequestBuilder(
        sessionDir: reopened.sessionDir,
        model: 'gpt-fake',
        workspaceName: p.basename(workspace.path),
        tools: const [],
        estimateRequest: (_) => 100,
      ).build(reopened.tree, turn: reopened.currentTurn + 1);
      final instructions = rebuilt.request.instructions;
      expect(instructions, contains('ROLE-MARKER-ORIGINAL'));
      expect(instructions, isNot(contains('ROLE-MARKER-EDITED')));
      expect(instructions, startsWith(builtInInstructions));
    });
  });

  group('Child roster', () {
    test("a reviewer child's edit call fails as unknown tool", () async {
      final fake = await FakeOpenAi.start();
      login();
      File(p.join(workspace.path, 'target.txt')).writeAsStringSync('one\n');
      fake.responsesScripts
        ..add(
          ResponsesScript.sse(
            _toolCallTurn('call_edit', 'edit', {
              'path': 'target.txt',
              'anchors': <String>[],
              'ops': [
                {'op': 'delete', 'start': 1, 'end': 1},
              ],
            }),
          ),
        )
        ..add(ResponsesScript.sse(sseTextTurn('done')));
      final text = _roleText();
      writeRole(text);

      final child = await startChild(fake: fake, roleDigest: _digestOf(text));
      final hello = await child.nextLine();
      await child.nextLine();
      child.send({
        'type': 'submit',
        'id': 'agent',
        'text': 'review',
        'turn': 0,
      });
      await child.untilCompleted('agent');
      expect(await child.finish(), 0);

      expect(_toolNames(fake.responsesRequests.first).toSet(), {
        'read',
        'grep',
        'find',
        'ls',
        'bash',
        'job',
        'write',
        'skill',
        'read_more',
        'search_result',
      });
      expect(
        File(p.join(workspace.path, 'target.txt')).readAsStringSync(),
        'one\n',
      );
      final dir = Directory(
        p.join(parent.path, 'agents', hello['session']! as String),
      );
      final reopened = await SessionWriter.open(dir);
      addTearDown(reopened.close);
      final node =
          reopened.tree.get(
                SessionPath.parse('body/calls/${callKey('call_edit')}'),
              )!
              as Map<String, Object?>;
      expect(node['status'], 'failed');
      expect(node['envelope'], 'error');
      expect(fake.responsesRequests.last.body, contains('unknown tool edit'));
    });

    test('a child without role tools offers twelve tools and refuses '
        'agent', () async {
      final fake = await FakeOpenAi.start();
      login();
      fake.responsesScripts
        ..add(
          ResponsesScript.sse(
            _toolCallTurn('call_agent', 'agent', {
              'role': 'specwright-reviewer',
              'prompt': 'nest',
            }),
          ),
        )
        ..add(ResponsesScript.sse(sseTextTurn('done')));
      final text = _roleText(tools: null);
      writeRole(text);

      final child = await startChild(fake: fake, roleDigest: _digestOf(text));
      final hello = await child.nextLine();
      await child.nextLine();
      child.send({'type': 'submit', 'id': 'agent', 'text': 'go', 'turn': 0});
      await child.untilCompleted('agent');
      expect(await child.finish(), 0);

      final offered = _toolNames(fake.responsesRequests.first);
      expect(offered, hasLength(12));
      expect(offered, isNot(contains('agent')));
      expect(offered.toSet(), {
        for (final d in toolDefinitions)
          if (d.name != 'agent') d.name,
      });
      final dir = Directory(
        p.join(parent.path, 'agents', hello['session']! as String),
      );
      final reopened = await SessionWriter.open(dir);
      addTearDown(reopened.close);
      final node =
          reopened.tree.get(
                SessionPath.parse('body/calls/${callKey('call_agent')}'),
              )!
              as Map<String, Object?>;
      expect(node['status'], 'failed');
      expect(fake.responsesRequests.last.body, contains('unknown tool agent'));
    });
  });
}
