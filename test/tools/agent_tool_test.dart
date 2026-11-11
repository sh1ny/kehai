import 'dart:io';

import 'dart:convert';

import 'package:kehai/kehai.dart';
import 'package:kehai/src/workspace/roles.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/bash_support.dart';
import '../support/session_support.dart';

String _role(String name) =>
    '---\nname: $name\ndescription: Does $name work\n---\nBody of $name.\n';

void main() {
  group('agent tool', () {
    for (final selected in <String?>['xhigh', null]) {
      test(
        'repeated child launch seam preserves ${selected ?? 'provider default'} without nested agents',
        () async {
          const allTools = ['read', 'agent', 'read_more', 'search_result'];
          const role = Role(
            name: 'reviewer',
            description: 'Review',
            model: 'reviewer',
            tools: null,
            unmapped: [],
            body: 'Review.',
            path: 'unused',
            source: 'unused',
            digest: 'digest',
          );
          final childRoster = roleRoster(role, allTools);
          expect(childRoster, {'read', 'read_more', 'search_result'});
          // Even an explicit Agent frontmatter entry must not widen the roster.
          expect(mapRoleTools(['Read', 'Agent']).unmapped, contains('Agent'));
          final workspace = await tempDir();
          final root = await tempDir();
          String? inherited = selected;
          for (var pass = 0; pass < 2; pass++) {
            final writer = await createWriter(root);
            final base = [
              '--child',
              '--parent',
              writer.sessionDir.path,
              '--job',
              'j-seam',
              '--role',
              role.name,
              '--role-digest',
              role.digest,
              '--model',
              'gpt-reviewer',
            ];
            final capture = _CaptureChildCommand(base);
            final runtime = await ToolRuntime.attach(
              writer,
              ResultStore(writer.sessionDir),
              workspace: workspace,
              config: const UserConfig(effort: 'low'),
              model: pass == 0 ? 'gpt-parent' : 'gpt-reviewer',
              effort: inherited,
              roster: pass == 0 ? null : childRoster,
              tools: {'read': capture},
              gate: const AllowAllStage(),
            );
            try {
              expect(runtime.effort, selected);
              if (pass == 1) {
                expect(
                  runtime.specs.map((spec) => spec.name),
                  isNot(contains('agent')),
                );
                final denied = await runtime.run(
                  const ToolCall(
                    callId: 'nested-refused',
                    name: 'agent',
                    argumentsJson:
                        '{"role":"reviewer","prompt":"not executed"}',
                  ),
                );
                expect(denied.output, contains('unknown tool'));
              }
              await runtime.run(
                ToolCall(
                  callId: 'capture-$pass',
                  name: 'read',
                  argumentsJson: jsonEncode({'path': 'unused'}),
                ),
              );
              expect(
                capture.effort,
                selected,
                reason: 'runtime must pass immutable selection to tool context',
              );
              expect(capture.arguments, [
                ...base,
                if (selected == null)
                  '--effort-default'
                else ...[
                  '--effort',
                  selected,
                ],
                '--compaction-policy',
                const UserConfig().captureProviderPolicy(),
              ]);
              expect(runtime.jobs.liveCount, 0);
              expect(
                writer.tree.get(SessionPath.parse('jobs')),
                anyOf(isNull, isEmpty),
              );
              final args = capture.arguments!;
              inherited = args.contains('--effort-default')
                  ? null
                  : args[args.indexOf('--effort') + 1];
            } finally {
              await runtime.close();
            }
          }
        },
      );
    }

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

// Invokes only the argv-building seam: no child process or nested agent call.
final class _CaptureChildCommand implements Tool {
  _CaptureChildCommand(this.base);

  final List<String> base;
  List<String>? arguments;
  String? effort;

  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    effort = context.effort;
    AgentTool(
      engine: (args) {
        arguments = List.of(args);
        return (executable: 'not-started', arguments: args);
      },
    ).buildChildCommand(context, base);
    return const ToolOutcome(summary: 'captured argv without launching');
  }
}
