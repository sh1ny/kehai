/// Qualifies the installed workflow with a real parent and two real child
/// engines. Only the provider is scripted; every tool and RPC hop is real.
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kehai/kehai.dart';
import 'package:kehai/src/tools/block_hash.dart';
import 'package:kehai/src/workspace/frontmatter.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_openai.dart';
import '../support/login_support.dart';

const _slow = Duration(seconds: 90);
const _implementer = 'specwright-implementer';
const _reviewer = 'specwright-reviewer';

List<ScriptStep> _call(String id, String name, Map<String, Object?> args) => [
  SseEvent.json('response.created', {
    'response': {'id': 'resp_$id'},
  }),
  SseEvent.json('response.output_item.done', {
    'item': {
      'type': 'function_call',
      'call_id': id,
      'name': name,
      'arguments': jsonEncode(args),
    },
  }),
  SseEvent.json('response.completed', {
    'response': {'id': 'resp_$id'},
  }),
];

void _copyTree(Directory source, Directory destination) {
  destination.createSync(recursive: true);
  for (final entry in source.listSync(followLinks: false)) {
    final target = p.join(destination.path, p.basename(entry.path));
    if (entry is Directory) {
      _copyTree(entry, Directory(target));
    } else if (entry is File) {
      entry.copySync(target);
    } else {
      fail('qualification definitions must be ordinary files: ${entry.path}');
    }
  }
}

List<Map<String, Object?>> _input(RecordedRequest request) =>
    (request.json!['input']! as List).cast<Map<String, Object?>>();

String _toolOutput(RecordedRequest request, String call) =>
    _input(request).singleWhere(
          (i) => i['type'] == 'function_call_output' && i['call_id'] == call,
        )['output']!
        as String;

Set<String> _tools(RecordedRequest request) => {
  for (final tool in _input(request).first['tools']! as List)
    (tool as Map)['name']! as String,
};

void main() {
  test('installed apply loads commit skill and real implementer and reviewer return typed results after relayed approvals', () async {
    final source = Directory.current.path;
    final scratch = Directory.systemTemp.createTempSync('kehai_workflow_');
    addTearDown(() => scratch.deleteSync(recursive: true));
    // Copy the installed definitions byte-for-byte, not simplified stand-ins.
    for (final owner in ['.claude', '.agents']) {
      _copyTree(
        Directory(p.join(source, owner)),
        Directory(p.join(scratch.path, owner)),
      );
    }
    // The real checkout may itself have a .git file. No Git operations run.
    File(p.join(scratch.path, '.git')).writeAsStringSync('gitdir: unused\n');
    File(p.join(source, 'AGENTS.md'))
        .copySync(p.join(scratch.path, 'AGENTS.md'));
    final target = File(p.join(scratch.path, 'target.txt'))
      ..writeAsStringSync('before\n');
    final review = File(p.join(scratch.path, 'review.txt'));
    final anchor = '1#${blockHashes([utf8.encode('before\n')]).single}';
    final home = TestHome();
    home.store.replace(loggedInRecord());
    File(p.join(home.path, 'config.json'))
        .writeAsStringSync(jsonEncode({'model': 'gpt-fake'}));
    final fake = await FakeOpenAi.start();
    final turns = [
      _call('load_commit', 'skill', {
        'name': 'specwright-commit',
        'args': 'qualification',
      }),
      _call('implement', 'agent', {
        'role': _implementer,
        'prompt':
            'Skills: none. Read target.txt, then edit its first line to after. '
            'Work only in this scratch workspace. Do not commit or change planning artifacts.',
      }),
      _call('read_target', 'read', {'path': 'target.txt'}),
      _call('edit_target', 'edit', {
        'path': 'target.txt',
        'anchors': [anchor],
        'ops': [
          {'op': 'replace', 'start': 1, 'end': 1, 'text': 'after'},
        ],
      }),
      sseTextTurn('IMPLEMENTED: target.txt now says after.'),
      _call('review', 'agent', {
        'role': _reviewer,
        'prompt':
            'Skills: none. Write review.txt with the scratch review result. '
            'Do not commit or change planning artifacts.',
      }),
      _call('write_review', 'write', {
        'path': 'review.txt',
        'content': 'REVIEW: approved\n',
      }),
      sseTextTurn('REVIEWED: scratch review.txt written.'),
      sseTextTurn('WORKFLOW COMPLETE: both typed child results received.'),
    ];
    for (final turn in turns) {
      fake.responsesScripts.add(ResponsesScript.sse(turn));
    }

    // This file is a VM test (not an installed AOT executable): its SDK VM
    // is the same mise-pinned executable used by the existing process tests.
    final process = await Process.start(
      Platform.resolvedExecutable,
      [
        '--packages=${p.join(source, '.dart_tool', 'package_config.json')}',
        p.join(source, 'bin', 'kehai.dart'),
        'rpc',
      ],
      workingDirectory: scratch.path,
      environment: {
        'KEHAI_HOME': home.path,
        'KEHAI_OPENAI_ISSUER': fake.issuer,
        'KEHAI_OPENAI_API_BASE': fake.apiBase,
      },
    );
    final stderrText = process.stderr.transform(utf8.decoder).join();
    final events = <Map<String, Object?>>[];
    final lines = StreamIterator(
      process.stdout.transform(utf8.decoder).transform(const LineSplitter()),
    );
    var stopped = false;
    Future<int> stop() async {
      await process.stdin.close();
      final code = await process.exitCode.timeout(
        _slow,
        onTimeout: () async {
          process.kill();
          await process.exitCode;
          fail('parent engine did not shut down after EOF');
        },
      );
      stopped = true;
      return code;
    }

    addTearDown(() async {
      if (!stopped) await stop();
      await lines.cancel();
      await stderrText;
    });
    void send(Map<String, Object?> command) =>
        process.stdin.add(utf8.encode('${jsonEncode(command)}\n'));
    Future<Map<String, Object?>> next() async {
      if (!await lines.moveNext().timeout(_slow)) {
        fail('engine closed stdout: ${await stderrText}');
      }
      final event = jsonDecode(lines.current) as Map<String, Object?>;
      events.add(event);
      expect(event['type'], isNot('fatal'), reason: '$event');
      return event;
    }

    final hello = await next();
    expect(hello['type'], 'hello');
    expect(hello['workspace'], scratch.resolveSymbolicLinksSync());
    expect(hello['model'], 'gpt-fake');
    expect((await next())['type'], 'snapshot');
    send({
      'type': 'submit',
      'id': 'workflow',
      'text': '/opsx:apply qualification',
      'turn': 0,
    });
    final prompts = <Map<String, Object?>>[];
    var completed = false;
    while (!completed) {
      final event = await next();
      if (event['type'] == 'prompt') {
        final item = event['item']! as Map<String, Object?>;
        prompts.add(item);
        expect(item['kind'], 'permission');
        final input = item['input']! as Map;
        switch (item['tool']) {
          case 'agent':
            expect(item['agent'], isNull);
            expect(input['role'], isIn([_implementer, _reviewer]));
            break;
          case 'edit':
            final agent = item['agent']! as Map;
            expect(agent['role'], _implementer);
            expect(item['key'], startsWith('${agent['job']}.'));
            expect(input['path'], 'target.txt');
            expect(
              target.readAsStringSync(),
              'before\n',
              reason: 'edit waits for explicit child approval',
            );
            break;
          case 'write':
            final agent = item['agent']! as Map;
            expect(agent['role'], _reviewer);
            expect(item['key'], startsWith('${agent['job']}.'));
            expect(input['path'], 'review.txt');
            expect(
              review.existsSync(),
              isFalse,
              reason: 'repo frontmatter cannot approve the write',
            );
            expect(target.readAsStringSync(), 'after\n');
            break;
          default:
            fail('unexpected permission prompt: $item');
        }
        send({'type': 'answer', 'key': item['key'], 'text': 'allow'});
      }
      if (event['type'] == 'error') fail('RPC error: $event');
      if (event['type'] == 'update') {
        final record = event['record']! as Map;
        if (record['path'] == 'meta/requests/workflow') {
          final value = record['value'];
          if (value is Map && value['state'] != 'admitted') {
            expect(value['state'], 'completed');
            completed = true;
          }
        }
      }
    }
    expect(await stop(), 0, reason: await stderrText);
    expect(prompts.map((i) => i['tool']), ['agent', 'edit', 'agent', 'write']);
    expect(events.where((e) => e['type'] == 'withdraw'), isEmpty);
    expect(target.readAsStringSync(), 'after\n');
    expect(review.readAsStringSync(), 'REVIEW: approved\n');
    expect(fake.responsesRequests, hasLength(9));
    expect(fake.responsesScripts, isEmpty);
    final requests = fake.responsesRequests;

    // The expanded command reaches the provider, not the raw slash text.
    final commandFile = File(
      p.join(scratch.path, '.claude', 'commands', 'opsx', 'apply.md'),
    );
    final commandBody = parseFrontmatter(commandFile.readAsStringSync()).body;
    final expanded =
        '$commandBody${commandBody.endsWith('\n') ? '\n' : '\n\n'}ARGUMENTS: qualification';
    // RequestBuilder appends a second user message with the sensorium.
    final firstUser = _input(requests.first)
        .firstWhere((i) => i['role'] == 'user');
    expect((firstUser['content']! as List).single, {
      'type': 'input_text',
      'text': expanded,
    });
    final skillOutput = _toolOutput(requests[1], 'load_commit');
    final skillBody = parseFrontmatter(
      File(
        p.join(
          scratch.path,
          '.claude',
          'skills',
          'specwright-commit',
          'SKILL.md',
        ),
      ).readAsStringSync(),
    ).body;
    expect(skillOutput, contains(skillBody));
    expect(skillOutput, contains('ARGUMENTS: qualification'));
    expect(skillOutput, contains('Base directory for this skill: '));

    for (final (index, role) in [(2, _implementer), (6, _reviewer)]) {
      final instructions = requests[index].json!['instructions']! as String;
      final body = parseFrontmatter(
        File(p.join(scratch.path, '.claude', 'agents', '$role.md'))
            .readAsStringSync(),
      ).body;
      expect(instructions, contains(body));
      expect(requests[index].json!['model'], 'gpt-fake');
      expect(_tools(requests[index]), isNot(contains('agent')));
    }
    expect(_tools(requests[2]), contains('edit'));
    expect(_tools(requests[6]), contains('write'));
    expect(_tools(requests[6]), isNot(contains('edit')));
    expect(_toolOutput(requests[3], 'read_target'), contains(anchor));
    expect(_toolOutput(requests[4], 'edit_target'), contains('after'));
    expect(_toolOutput(requests[7], 'write_review'), contains('write'));

    final implemented = _toolOutput(requests[5], 'implement');
    final reviewed = _toolOutput(requests[8], 'review');
    expect(
      implemented,
      contains('agent $_implementer done (3 steps, session '),
    );
    expect(
      implemented,
      contains('model sonnet is not configured; used gpt-fake'),
    );
    expect(implemented, contains('IMPLEMENTED: target.txt now says after.'));
    expect(reviewed, contains('agent $_reviewer done (2 steps, session '));
    expect(reviewed, contains('REVIEWED: scratch review.txt written.'));
    // Both results remain in the parent's final provider request.
    expect(_toolOutput(requests.last, 'implement'), implemented);

    final sessionDir = Directory(
      p.join(
        home.path,
        'sessions',
        workspaceKey(scratch.path),
        hello['session']! as String,
      ),
    );
    final parent = await SessionWriter.open(sessionDir);
    addTearDown(parent.close);
    final exchange =
        parent.tree.get(SessionPath.parse('body/exchanges/x-00000001'))! as Map;
    expect(exchange['prompt'], expanded);
    expect(exchange['state'], 'done');
    expect(exchange['command'], {
      'name': 'opsx:apply',
      'args': 'qualification',
      'source': '.claude/commands/opsx/apply.md',
      'sha256': sha256.convert(utf8.encode(expanded)).toString(),
    });
    final jobs = parent.tree.get(SessionPath.parse('jobs'))! as Map;
    expect(jobs, hasLength(2));
    final childSessions = <String>{};
    for (final entry in jobs.entries) {
      final job = entry.value as Map;
      expect(job['state'], 'settled');
      expect(job['exit'], 0);
      final result = job['agent']! as Map;
      expect(result['status'], 'done');
      final role = result['role']! as String;
      final childId = result['session']! as String;
      childSessions.add(childId);
      expect(childId, isNot(hello['session']));
      expect(result['steps'], role == _implementer ? 3 : 2);
      final stream = job['result']! as Map;
      expect(stream['complete'], isTrue);
      final stored = resolveHandle(
        parent.tree,
        sessionDir,
        stream['handle']! as String,
      ).file.readAsStringSync();
      expect(
        stored,
        startsWith(
          'agent $role done (${result['steps']} steps, session $childId)',
        ),
      );
      expect(
        stored,
        contains(
          role == _implementer
              ? 'IMPLEMENTED: target.txt now says after.'
              : 'REVIEWED: scratch review.txt written.',
        ),
      );
      final child = await SessionWriter.open(
        Directory(p.join(sessionDir.path, 'agents', childId)),
      );
      try {
        expect(child.tree.get(SessionPath.parse('meta/lineage')), {
          'parent': hello['session'],
          'job': entry.key,
        });
        final calls = child.tree.get(SessionPath.parse('body/calls'))! as Map;
        final mutation = calls.values.cast<Map<String, Object?>>().singleWhere(
          (c) => c['tool'] == (role == _implementer ? 'edit' : 'write'),
        );
        expect(mutation['permission'], containsPair('by', 'answer'));
        expect(mutation['permission'], containsPair('decision', 'allow'));
      } finally {
        await child.close();
      }
    }
    expect(childSessions, hasLength(2));
  });
}
