@Tags(['slow'])
@Timeout(Duration(minutes: 5))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kehai/kehai.dart';
import 'package:kehai/src/workspace/vcs_collector.dart' show VcsTrust;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_openai.dart';
import '../support/login_support.dart';
import '../support/vcs_trust_support.dart';

const _deadline = Duration(seconds: 90);

final class _Engine {
  _Engine(this.process)
    : lines = StreamIterator(
        process.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .map((line) => jsonDecode(line) as Map<String, Object?>),
      ),
      errors = process.stderr.transform(utf8.decoder).join();
  final Process process;
  final StreamIterator<Map<String, Object?>> lines;
  final Future<String> errors;
  Map<String, Object?>? _compaction;
  void send(Map<String, Object?> value) =>
      process.stdin.writeln(jsonEncode(value));
  Future<Map<String, Object?>> next() async {
    if (!await lines.moveNext().timeout(_deadline)) {
      fail('RPC closed unexpectedly: ${await errors}');
    }
    final event = lines.current;
    if (event['type'] == 'compaction_status') {
      _compaction = event['compaction']! as Map<String, Object?>;
    }
    return event;
  }

  Future<Map<String, Object?>> compactionStatus() async {
    if (_compaction == null) {
      await until((event) => event['type'] == 'compaction_status');
    }
    return _compaction!;
  }

  Future<Map<String, Object?>> until(
    bool Function(Map<String, Object?>) matches,
  ) async {
    while (true) {
      final event = await next();
      if (event['type'] == 'prompt') {
        final item = event['item']! as Map<String, Object?>;
        send({'type': 'answer', 'key': item['key'], 'text': 'allow'});
      }
      if (matches(event)) return event;
    }
  }

  Future<void> submit(String id, int turn) async {
    send({
      'type': 'submit',
      'id': id,
      'text': 'observe workspace',
      'turn': turn,
    });
    await until((event) {
      final record = event['record'];
      if (event['type'] != 'update' || record is! Map) return false;
      final value = record['value'];
      return record['path'] == 'meta/requests/$id' &&
          value is Map &&
          value['state'] == 'completed';
    });
  }

  Future<void> close() async {
    await process.stdin.close();
    while (await lines.moveNext().timeout(_deadline)) {}
    expect(await process.exitCode.timeout(_deadline), 0, reason: await errors);
  }
}

Future<_Engine> _start(
  ConfiguredVcsWorkspace fixture,
  TestHome home,
  FakeOpenAi fake,
  List<String> args, {
  Directory? workspace,
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
    workingDirectory: (workspace ?? fixture.workspace).path,
    includeParentEnvironment: false,
    environment: {
      ...fixture.environment,
      'KEHAI_HOME': home.path,
      'KEHAI_OPENAI_ISSUER': fake.issuer,
      'KEHAI_OPENAI_API_BASE': fake.apiBase,
    },
  );
  addTearDown(process.kill);
  return _Engine(process);
}

void _noPrograms(ConfiguredVcsWorkspace fixture) {
  expect(fixture.monitorMarker.existsSync(), isFalse);
  expect(fixture.filterMarker.existsSync(), isFalse);
}

void _programs(ConfiguredVcsWorkspace fixture) {
  expect(
    fixture.monitorMarker.existsSync(),
    isTrue,
    reason: 'trusted fsmonitor executed',
  );
  expect(
    fixture.filterMarker.existsSync(),
    isTrue,
    reason: 'trusted clean filter executed',
  );
}

Directory _session(TestHome home, Directory workspace, String id) =>
    Directory(p.join(home.path, 'sessions', workspaceKey(workspace.path), id));

Future<List<Map<String, Object?>>> _steps(Directory session) async {
  final writer = await SessionWriter.open(session);
  try {
    final steps =
        writer.tree.get(SessionPath.parse('body/steps'))!
            as Map<String, Object?>;
    final keys = steps.keys.toList()..sort();
    return [for (final key in keys) steps[key]! as Map<String, Object?>];
  } finally {
    await writer.close();
  }
}

List<ScriptStep> _agentCall() => [
  SseEvent.json('response.created', {
    'response': {'id': 'agent-call'},
  }),
  SseEvent.json('response.output_item.done', {
    'item': {
      'type': 'function_call',
      'call_id': 'agent-call',
      'name': 'agent',
      'arguments': jsonEncode({'role': 'reviewer', 'prompt': 'review'}),
    },
  }),
  SseEvent.json('response.completed', {
    'response': {'id': 'agent-call'},
  }),
];

void main() {
  test('untrusted engine runs no configured repository program from hello snapshot through submit, status and resume', () async {
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
    fake.responsesScripts.add(ResponsesScript.sse(sseTextTurn('first')));
    final engine = await _start(fixture, home, fake, []);
    final hello = await engine.next();
    expect(hello['type'], 'hello');
    final snapshot = await engine.next();
    expect(snapshot['type'], 'snapshot');
    _noPrograms(fixture);
    engine.send({'type': 'status', 'id': 'not-admitted'});
    expect(
      (await engine.until((e) => e['type'] == 'reply'))['state'],
      'not-admitted',
    );
    _noPrograms(fixture);
    await engine.submit('first', snapshot['turn']! as int);
    expect(await engine.compactionStatus(), isA<Map<String, Object?>>());
    _noPrograms(fixture);
    await engine.close();
    final resumed = await _start(fixture, home, fake, ['--resume']);
    expect((await resumed.next())['session'], hello['session']);
    final reopened = await resumed.next();
    expect(reopened['type'], 'snapshot');
    _noPrograms(fixture);
    fake.responsesScripts.add(ResponsesScript.sse(sseTextTurn('second')));
    await resumed.submit('second', reopened['turn']! as int);
    expect(await resumed.compactionStatus(), isA<Map<String, Object?>>());
    _noPrograms(fixture);
    await resumed.close();
    final steps = await _steps(
      _session(home, fixture.workspace, hello['session']! as String),
    );
    for (final step in steps) {
      final sensorium = step['sensorium']! as Map<String, Object?>;
      expect(sensorium['text'], contains('vcs: unavailable (trust required)'));
    }
  });

  test(
    'trusted resume after an untrusted gap compares with the carried baseline',
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
      for (final text in ['first', 'gap', 'after']) {
        fake.responsesScripts.add(ResponsesScript.sse(sseTextTurn(text)));
      }
      final first = await _start(fixture, home, fake, ['--trust-vcs']);
      final hello = await first.next();
      final snapshot = await first.next();
      await first.submit('first', snapshot['turn']! as int);
      _programs(fixture);
      await first.close();
      final session = _session(
        home,
        fixture.workspace,
        hello['session']! as String,
      );
      final original =
          (await _steps(session)).first['sensorium']! as Map<String, Object?>;
      final originalVcs = original['vcs']! as Map<String, Object?>;
      final source = original['source']! as Map<String, Object?>;
      fixture.clearMarkers();
      fixture.tracked.writeAsStringSync(
        'external user edit during untrusted gap\n',
      );
      final gap = await _start(fixture, home, fake, ['--resume']);
      await gap.next();
      final gapSnapshot = await gap.next();
      await gap.submit('gap', gapSnapshot['turn']! as int);
      _noPrograms(fixture);
      await gap.close();
      final carried =
          (await _steps(session)).last['sensorium']! as Map<String, Object?>;
      final carriedVcs = carried['vcs']! as Map<String, Object?>;
      expect(carriedVcs['baseline'], originalVcs['baseline']);
      expect(carried['text'], contains('unavailable (trust required)'));
      final last = await _start(fixture, home, fake, [
        '--resume',
        '--trust-vcs',
      ]);
      await last.next();
      final lastSnapshot = await last.next();
      await last.submit('after', lastSnapshot['turn']! as int);
      _programs(fixture);
      await last.close();
      final after =
          (await _steps(session)).last['sensorium']! as Map<String, Object?>;
      expect(after['text'], contains('since_turn: ${source['turn']}'));
      expect(after['text'], contains('tracked.txt'));
      expect(after['text'], contains('by: user'));
    },
  );

  test('child binding without explicit trust, or a malformed, oversized or foreign-workspace binding, fails startup before provider discovery and starts no VCS process', () async {
    final fixture = await ConfiguredVcsWorkspace.create();
    final other = await ConfiguredVcsWorkspace.create();
    final home = TestHome();
    home.store.replace(loggedInRecord());
    File(p.join(home.path, 'config.json'))
        .writeAsStringSync(jsonEncode({'model': 'gpt-fake'}));
    final fake = await FakeOpenAi.start();
    final role =
        '---\nname: reviewer\ndescription: Reviews\ntools: Read\n---\nReview.\n';
    final roles = Directory(p.join(fixture.workspace.path, '.claude', 'agents'))
      ..createSync(recursive: true);
    File(p.join(roles.path, 'reviewer.md')).writeAsStringSync(role);
    final parent = await SessionWriter.create(
      Directory(p.join(home.path, 'parent')),
    );
    final parentPath = parent.sessionDir.path;
    await parent.close();
    final child = [
      '--child',
      '--parent',
      parentPath,
      '--job',
      'j1',
      '--role',
      'reviewer',
      '--role-digest',
      sha256.convert(utf8.encode(role)).toString(),
      '--compaction-policy',
      UserConfig.load(home.path).captureProviderPolicy(),
    ];
    final binding = VcsTrust.grant(root: fixture.workspace.path)
        .childBinding(root: fixture.workspace.path, backend: 'auto')!;
    final foreign = VcsTrust.grant(root: other.workspace.path)
        .childBinding(root: other.workspace.path, backend: 'auto')!;
    for (final args in [
      ['--vcs-trust-binding', binding],
      [...child, '--vcs-trust-binding', binding],
      [...child, '--trust-vcs', '--vcs-trust-binding', '{secret-invalid'],
      [
        ...child,
        '--trust-vcs',
        '--vcs-trust-binding',
        '$binding${' ' * 16385}',
      ],
      [...child, '--trust-vcs', '--vcs-trust-binding', foreign],
    ]) {
      final before = fake.modelsRequests.length;
      final engine = await _start(fixture, home, fake, args);
      if (args.contains('--trust-vcs')) {
        final fatal = await engine.next();
        expect(fatal['type'], 'fatal');
        expect(fatal['message'], 'Invalid inherited VCS trust binding.');
        expect(await engine.process.exitCode.timeout(_deadline), 1);
      } else {
        expect(await engine.process.exitCode.timeout(_deadline), 64);
        expect(await engine.errors, contains('needs --'));
      }
      expect(fake.modelsRequests.length, before);
      _noPrograms(fixture);
    }
  });

  test('direct yolo child does not grant VCS trust, while explicit child trust does', () async {
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
    final role =
        '---\nname: reviewer\ndescription: Reviews\ntools: Read\n---\nReview.\n';
    final roles = Directory(p.join(fixture.workspace.path, '.claude', 'agents'))
      ..createSync(recursive: true);
    File(p.join(roles.path, 'reviewer.md')).writeAsStringSync(role);
    final parent = await SessionWriter.create(
      Directory(p.join(home.path, 'parent')),
    );
    final parentPath = parent.sessionDir.path;
    await parent.close();
    final args = [
      '--child',
      '--parent',
      parentPath,
      '--job',
      'j1',
      '--role',
      'reviewer',
      '--role-digest',
      sha256.convert(utf8.encode(role)).toString(),
      '--compaction-policy',
      UserConfig.load(home.path).captureProviderPolicy(),
      '--yolo',
    ];
    for (final trusted in [false, true]) {
      fake.responsesScripts.add(ResponsesScript.sse(sseTextTurn('reviewed')));
      final engine = await _start(fixture, home, fake, [
        ...args,
        if (trusted) '--trust-vcs',
      ]);
      final hello = await engine.next();
      final snapshot = await engine.next();
      await engine.submit('review', snapshot['turn']! as int);
      if (trusted) {
        _programs(fixture);
      } else {
        _noPrograms(fixture);
      }
      await engine.close();
      final steps = await _steps(
        Directory(p.join(parentPath, 'agents', hello['session']! as String)),
      );
      final sensorium = steps.single['sensorium']! as Map<String, Object?>;
      final vcs = sensorium['vcs']! as Map<String, Object?>;
      expect(vcs['state'], trusted ? 'available' : 'unavailable');
      if (!trusted) expect(sensorium['text'], contains('trust required'));
      fixture.clearMarkers();
    }
  });

  test('managed child inherits only the parent invocation', () async {
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
    final roles = Directory(p.join(fixture.workspace.path, '.claude', 'agents'))
      ..createSync(recursive: true);
    File(p.join(roles.path, 'reviewer.md')).writeAsStringSync(
      '---\nname: reviewer\ndescription: Reviews\ntools: Read\n---\nReview.\n',
    );
    for (final trusted in [false, true]) {
      fake.responsesScripts.add(ResponsesScript.sse(_agentCall()));
      fake.responsesScripts.add(ResponsesScript.sse(sseTextTurn('child done')));
      fake.responsesScripts.add(
        ResponsesScript.sse(sseTextTurn('parent done')),
      );
      final engine = await _start(fixture, home, fake, [
        if (trusted) '--trust-vcs',
      ]);
      final hello = await engine.next();
      final snapshot = await engine.next();
      await engine.submit('agent', snapshot['turn']! as int);
      await engine.close();
      final parent = _session(
        home,
        fixture.workspace,
        hello['session']! as String,
      );
      final children = Directory(p.join(parent.path, 'agents'))
          .listSync()
          .whereType<Directory>()
          .toList();
      expect(children, hasLength(1));
      final steps = await _steps(children.single);
      final sensorium = steps.single['sensorium']! as Map<String, Object?>;
      final vcs = sensorium['vcs']! as Map<String, Object?>;
      expect(vcs['state'], trusted ? 'available' : 'unavailable');
      if (!trusted) expect(sensorium['text'], contains('trust required'));
      if (trusted) {
        _programs(fixture);
      } else {
        _noPrograms(fixture);
      }
      fixture.clearMarkers();
    }
  });
  test('original inherited binding cannot rebind a child to a newly selected repository', () async {
    final fixture = await ConfiguredVcsWorkspace.create();
    final subdir = Directory(p.join(fixture.workspace.path, 'child'))
      ..createSync();
    final trust = VcsTrust.grant(root: subdir.path);
    final binding = trust.childBinding(root: subdir.path, backend: 'auto')!;
    final home = TestHome();
    home.store.replace(loggedInRecord());
    File(p.join(home.path, 'config.json'))
        .writeAsStringSync(jsonEncode({'model': 'gpt-fake'}));
    final fake = await FakeOpenAi.start();
    final role =
        '---\nname: reviewer\ndescription: Reviews\ntools: Read\n---\nReview.\n';
    final roles = Directory(p.join(subdir.path, '.claude', 'agents'))
      ..createSync(recursive: true);
    File(p.join(roles.path, 'reviewer.md')).writeAsStringSync(role);
    final parent = await SessionWriter.create(
      Directory(p.join(home.path, 'parent')),
    );
    final parentPath = parent.sessionDir.path;
    await parent.close();
    Directory(p.join(subdir.path, '.git')).createSync();
    fake.responsesScripts.add(ResponsesScript.sse(sseTextTurn('reviewed')));
    final engine = await _start(fixture, home, fake, [
      '--child',
      '--parent',
      parentPath,
      '--job',
      'j1',
      '--role',
      'reviewer',
      '--role-digest',
      sha256.convert(utf8.encode(role)).toString(),
      '--compaction-policy',
      UserConfig.load(home.path).captureProviderPolicy(),
      '--trust-vcs',
      '--vcs-trust-binding',
      binding,
    ], workspace: subdir);
    final hello = await engine.next();
    final snapshot = await engine.next();
    await engine.submit('review', snapshot['turn']! as int);
    _noPrograms(fixture);
    await engine.close();
    final steps = await _steps(
      Directory(p.join(parentPath, 'agents', hello['session']! as String)),
    );
    final sensorium = steps.single['sensorium']! as Map<String, Object?>;
    expect(sensorium['text'], contains('unavailable (trust required)'));
  });

  test('engine selection follows the canonical subdirectory and revoked trust is not rebound in a real child', () async {
    final fixture = await ConfiguredVcsWorkspace.create();
    final subdir = Directory(p.join(fixture.workspace.path, 'subdir'))
      ..createSync();
    final role =
        '---\nname: reviewer\ndescription: Reviews\ntools: Read\n---\nReview.\n';
    for (final root in [fixture.workspace, subdir]) {
      final roles = Directory(p.join(root.path, '.claude', 'agents'))
        ..createSync(recursive: true);
      File(p.join(roles.path, 'reviewer.md')).writeAsStringSync(role);
    }
    final home = TestHome();
    home.store.replace(loggedInRecord());
    File(p.join(home.path, 'config.json')).writeAsStringSync(
      jsonEncode({
        'model': 'gpt-fake',
        'sensorium': {'collectorDeadlineMs': 10000},
      }),
    );
    final fake = await FakeOpenAi.start();
    fake.responsesScripts.add(ResponsesScript.sse(_agentCall()));
    fake.responsesScripts.add(ResponsesScript.sse(sseTextTurn('child done')));
    fake.responsesScripts.add(ResponsesScript.sse(sseTextTurn('parent done')));
    final engine = await _start(fixture, home, fake, [
      '--trust-vcs',
    ], workspace: subdir);
    final hello = await engine.next();
    expect(hello['workspace'], realPath(subdir.path));
    final snapshot = await engine.next();
    engine.send({
      'type': 'submit',
      'id': 'agent',
      'text': 'review',
      'turn': snapshot['turn'],
    });
    while (true) {
      final event = await engine.next();
      if (event['type'] != 'prompt') continue;
      final item = event['item']! as Map<String, Object?>;
      expect(item['tool'], 'agent');
      _programs(fixture);
      fixture.clearMarkers();
      Directory(p.join(subdir.path, '.git')).createSync();
      engine.send({'type': 'answer', 'key': item['key'], 'text': 'allow'});
      break;
    }
    await engine.until((event) {
      final record = event['record'];
      if (event['type'] != 'update' || record is! Map) return false;
      final value = record['value'];
      return record['path'] == 'meta/requests/agent' &&
          value is Map &&
          value['state'] == 'completed';
    });
    _noPrograms(fixture);
    await engine.close();
    final parent = _session(home, subdir, hello['session']! as String);
    final children = Directory(p.join(parent.path, 'agents'))
        .listSync()
        .whereType<Directory>()
        .toList();
    expect(children, hasLength(1));
    final child =
        (await _steps(children.single)).single['sensorium']!
            as Map<String, Object?>;
    expect(child['text'], contains('unavailable (trust required)'));
  });
}
