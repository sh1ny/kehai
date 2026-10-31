import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/bash_support.dart';
import '../support/session_support.dart';

String _role(String name) =>
    '---\nname: $name\ndescription: Does $name work\n---\nBody of $name.\n';

void main() {
  group('agent tool', () {
    test(
      'an unknown role fails listing the roles and starts nothing',
      () async {
        final workspace = await tempDir();
        Directory(p.join(workspace.path, '.git')).createSync();
        final agents = Directory(p.join(workspace.path, '.claude', 'agents'))
          ..createSync(recursive: true);
        File(p.join(agents.path, 'specwright-reviewer.md'))
            .writeAsStringSync(_role('specwright-reviewer'));
        File(p.join(agents.path, 'specwright-implementer.md'))
            .writeAsStringSync(_role('specwright-implementer'));
        final home = await tempDir();
        final h = await BashHarness.create(
          workspace: workspace,
          kehaiHome: home,
          model: 'gpt-fake',
        );

        final text = await h.call('agent', {
          'role': 'general-purpose',
          'prompt': 'look around',
        });

        const message =
            'unknown agent role general-purpose; roles: '
            'specwright-implementer, specwright-reviewer';
        expect(text, contains(message));
        expect(h.lastCall['status'], 'failed');
        expect(h.lastCall['envelope'], 'error');
        expect(h.lastCall['reason'], message);
        expect(h.jobNodes, isEmpty);
        expect(h.runtime.jobs.liveCount, 0);
      },
    );
  });
}
