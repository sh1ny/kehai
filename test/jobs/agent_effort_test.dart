@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../rpc/process_test.dart' as rpc;
import '../support/fake_openai.dart';
import '../support/login_support.dart';
import '../support/session_support.dart';

List<ScriptStep> _agent(String id) => [
  SseEvent.json('response.created', {
    'response': {'id': id},
  }),
  SseEvent.json('response.output_item.done', {
    'item': {
      'type': 'function_call',
      'call_id': id,
      'name': 'agent',
      'arguments': jsonEncode({
        'role': 'specwright-reviewer',
        'prompt': 'review it',
      }),
    },
  }),
  SseEvent.json('response.completed', {
    'response': {'id': id},
  }),
];

void main() {
  for (final scenario in [
    (
      name:
          'reviewer child inherits parent override across role model selection',
      initial: 'low',
      flag: 'high',
      edited: 'low',
    ),
    (
      name: 'child inherits provider default despite edited config',
      initial: null,
      flag: null,
      edited: 'high',
    ),
    (
      name: 'explicit selected effort survives edited child config',
      initial: 'low',
      flag: 'none',
      edited: 'high',
    ),
  ]) {
    test(scenario.name, () async {
      final home = TestHome();
      home.store.replace(loggedInRecord());
      final workspace = await tempDir();
      Directory(p.join(workspace.path, '.git')).createSync();
      final roles = Directory(p.join(workspace.path, '.claude', 'agents'))
        ..createSync(recursive: true);
      File(p.join(roles.path, 'specwright-reviewer.md')).writeAsStringSync(
        '---\nname: specwright-reviewer\ndescription: Reviews changes\nmodel: reviewer\n---\nReview carefully.\n',
      );
      void config(String? effort) => File(p.join(home.path, 'config.json'))
          .writeAsStringSync(
            jsonEncode({
              'model': 'gpt-fake',
              'effort': ?effort,
              'agents': {
                'models': {'reviewer': 'gpt-fake-mini'},
              },
            }),
          );
      config(scenario.initial);
      final fake = await FakeOpenAi.start();
      fake.defaultModels = {
        'models': [
          for (final slug in ['gpt-fake', 'gpt-fake-mini'])
            {
              'slug': slug,
              'display_name': slug,
              'visibility': 'list',
              'supported_in_api': true,
            },
        ],
      };
      // Two sibling reviewer launches, never a nested agent execution.
      for (final turn in [
        _agent('review-1'),
        sseTextTurn('first review done'),
        _agent('review-2'),
        sseTextTurn('second review done'),
        sseTextTurn('parent done'),
      ]) {
        fake.responsesScripts.add(ResponsesScript.sse(turn));
      }
      final engine = await rpc.startEngine(
        [if (scenario.flag != null) '--effort=${scenario.flag}'],
        home: home,
        workspace: workspace,
        fake: fake,
      );
      try {
        final hello = await engine.nextLine();
        expect(hello['type'], 'hello');
        final snapshot = await engine.nextLine();
        // The parent's immutable selection is already resolved.
        config(scenario.edited);
        engine.send({
          'type': 'submit',
          'id': 'inherit',
          'text': 'review',
          'turn': snapshot['turn'],
        });
        await engine.lineWhere((event) {
          expect(event['type'], isNot('error'), reason: '$event');
          final record = event['record'];
          return record is Map &&
              record['path'] == 'meta/requests/inherit' &&
              record['value'] is Map &&
              (record['value'] as Map)['state'] == 'completed';
        });
        await engine.process.stdin.close();
        expect(await engine.exitCode(), 0, reason: await engine.stderrText);
        final expected = scenario.flag ?? scenario.initial;
        expect(fake.responsesRequests, hasLength(5));
        for (final index in [1, 3]) {
          final childRequest = fake.responsesRequests[index].json!;
          expect(childRequest['model'], 'gpt-fake-mini');
          final tools =
              ((childRequest['input']! as List).first as Map)['tools']! as List;
          expect(
            tools.map((tool) => (tool as Map)['name']),
            isNot(contains('agent')),
          );
        }
        for (final request in fake.responsesRequests) {
          expect(
            request.json!['reasoning'],
            expected == null
                ? {'summary': 'auto'}
                : {'summary': 'auto', 'effort': expected},
            reason:
                'model ${request.json!['model']} must inherit parent selection',
          );
        }
        final parent = Directory(
          p.join(
            home.path,
            'sessions',
            rpc.keyOf(workspace.path),
            hello['session']! as String,
          ),
        );
        final journals = parent
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => p.basename(file.path) == journalFileName)
            .toList();
        expect(journals, hasLength(3));
        var stepCount = 0;
        for (final journal in journals) {
          final tree = scanJournal(journal).state.combined();
          final steps = tree.get(SessionPath.parse('body/steps'))! as Map;
          for (final step in steps.values) {
            expect(step, containsPair('effort', expected));
            stepCount++;
          }
        }
        expect(stepCount, fake.responsesRequests.length);
        expect(fake.responsesScripts, isEmpty);
      } finally {
        engine.process.kill();
        await engine.process.exitCode;
        await engine.lines.cancel();
        await engine.stderrText;
      }
    });
  }
}
