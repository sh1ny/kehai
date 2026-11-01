@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_openai.dart';
import '../support/login_support.dart';
import '../support/session_support.dart';
import 'process_test.dart' as client_process;

List<ScriptStep> _toolTurn(
  String id,
  String name,
  Map<String, Object?> arguments,
) => [
  SseEvent.json('response.created', {
    'response': {'id': id},
  }),
  SseEvent.json('response.output_item.done', {
    'item': {
      'type': 'function_call',
      'call_id': id,
      'name': name,
      'arguments': jsonEncode(arguments),
    },
  }),
  SseEvent.json('response.completed', {
    'response': {'id': id},
  }),
];

void main() {
  for (final effort in ['high', null]) {
    test(
      'line client ${effort ?? 'provider default'} reaches tool follow-up and reviewer requests and replay',
      () async {
        final home = TestHome();
        home.store.replace(loggedInRecord());
        final workspace = await tempDir();
        Directory(p.join(workspace.path, '.git')).createSync();
        final roles = Directory(p.join(workspace.path, '.claude', 'agents'))
          ..createSync(recursive: true);
        File(p.join(roles.path, 'specwright-reviewer.md')).writeAsStringSync(
          '---\nname: specwright-reviewer\ndescription: Reviews changes\nmodel: reviewer\n---\nReview carefully.\n',
        );
        File(p.join(workspace.path, 'evidence.txt'))
            .writeAsStringSync('local effort evidence\n');
        void config(String? value) => File(p.join(home.path, 'config.json'))
            .writeAsStringSync(
              jsonEncode({
                'model': 'gpt-fake',
                'effort': ?value,
                'agents': {
                  'models': {'reviewer': 'gpt-fake-mini'},
                },
              }),
            );
        config(effort == null ? null : 'low');
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
        for (final turn in [
          _toolTurn('read-evidence', 'read', {'path': 'evidence.txt'}),
          _toolTurn('review-evidence', 'agent', {
            'role': 'specwright-reviewer',
            'prompt': 'Review the local evidence.',
          }),
          sseTextTurn('review complete'),
          sseTextTurn('parent complete'),
        ]) {
          fake.responsesScripts.add(ResponsesScript.sse(turn));
        }

        // Start the public line client, not an RPC process or injected starter.
        final client = await client_process.startClient(
          [
            if (effort != null) ...['--effort', effort],
          ],
          home: home,
          workspace: workspace,
          fake: fake,
        );
        try {
          await client.untilOut((text) => text.endsWith('> '));
          final header = RegExp(r'session (\S+) +model gpt-fake')
              .firstMatch(client.stdoutText);
          expect(header, isNotNull, reason: client.stdoutText);
          // The engine has resolved its selection. Neither follow-ups nor the
          // real reviewer process may adopt this later config value.
          config(effort == null ? 'high' : 'none');
          client.process.stdin.writeln('Read evidence and ask for a review.');
          await client.untilOut((text) => text.endsWith('answer> '));
          expect(client.stdoutText, contains('permission: agent'));
          client.process.stdin.writeln('1');
          await client.untilOut(
            (text) => text.contains('parent complete') && text.endsWith('> '),
          );
          await client.process.stdin.close();
          expect(await client.exitCode(), 0, reason: client.stderrText);

          expect(fake.responsesRequests, hasLength(4));
          expect(
            fake.responsesRequests.map((request) => request.json!['model']),
            ['gpt-fake', 'gpt-fake', 'gpt-fake-mini', 'gpt-fake'],
          );
          for (final request in fake.responsesRequests) {
            expect(
              request.json!['reasoning'],
              effort == null
                  ? {'summary': 'auto'}
                  : {'summary': 'auto', 'effort': effort},
            );
          }
          final followUp = jsonEncode(fake.responsesRequests[1].json!['input']);
          expect(followUp, contains('local effort evidence'));
          expect(followUp, contains('function_call_output'));
          final parentFinal = jsonEncode(
            fake.responsesRequests.last.json!['input'],
          );
          expect(parentFinal, contains('review complete'));
          final childInput = fake.responsesRequests[2].json!['input']! as List;
          final childTools = (childInput.first as Map)['tools']! as List;
          expect(
            childTools.map((tool) => (tool as Map)['name']),
            isNot(contains('agent')),
          );

          final parentJournal = Directory(p.join(home.path, 'sessions'))
              .listSync(recursive: true)
              .whereType<File>()
              .singleWhere(
                (file) =>
                    p.basename(file.path) == journalFileName &&
                    p.basename(p.dirname(file.path)) == header!.group(1),
              );
          final journals = parentJournal.parent
              .listSync(recursive: true)
              .whereType<File>()
              .where((file) => p.basename(file.path) == journalFileName)
              .toList();
          expect(journals, hasLength(2));
          var stepCount = 0;
          for (final journal in journals) {
            final steps =
                scanJournal(journal).state
                        .combined()
                        .get(SessionPath.parse('body/steps'))!
                    as Map;
            expect(
              steps,
              hasLength(journal.path == parentJournal.path ? 3 : 1),
            );
            for (final step in steps.values) {
              expect(step, containsPair('effort', effort));
              expect(
                step,
                containsPair(
                  'model',
                  journal.path == parentJournal.path
                      ? 'gpt-fake'
                      : 'gpt-fake-mini',
                ),
              );
              stepCount++;
            }
          }
          expect(stepCount, fake.responsesRequests.length);
          expect(fake.responsesScripts, isEmpty);
        } finally {
          // EOF lets the line client shut its owned engine and jobs down too.
          await client.process.stdin.close();
          await client.exitCode();
        }
      },
    );
  }
}
