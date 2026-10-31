import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:kehai/src/workspace/inventory.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/answerer_support.dart';
import '../support/fake_bin.dart';
import '../support/session_support.dart';

StageCall _call(String tool, Map<String, Object?> input) => StageCall(
  tool: tool,
  callKey: callKey('id-$tool'),
  callId: 'id-$tool',
  input: input,
);

void main() {
  late Directory workspace;
  late Directory home;
  late Directory bin;

  setUp(() async {
    final root = await tempDir();
    workspace = Directory(p.join(root.path, 'ws'))..createSync();
    Directory(p.join(workspace.path, '.git')).createSync();
    home = Directory(p.join(root.path, 'home'))..createSync();
    bin = fakeBin(Directory(p.join(root.path, 'bin')), ['openspec']);
  });

  /// The prompt `openspec new change x` raises, or null when the gate decided
  /// without asking.
  Future<PromptItem?> promptFor() async {
    final answerer = RecordingAnswerer();
    final channel = PromptChannel(answerer);
    final pending = PermissionGate(
      workspace: workspace,
      kehaiHome: home,
      prompts: channel,
      posixShell: true,
      environment: {'PATH': bin.path},
    ).check(_call('bash', {'command': 'openspec new change x'}), CancelToken());
    final first = await Future.any<Object?>([answerer.item(0), pending]);
    if (first is! PromptItem) return null;
    expect(channel.reply(first.key, 'deny'), isNull);
    await pending;
    return first;
  }

  test('allowed-tools does not autoapprove a bash call', () async {
    final without = await promptFor();
    expect(without, isNotNull);

    File(p.join(workspace.path, '.claude', 'commands', 'opsx', 'propose.md'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '---\nname: "OPSX: Propose"\nallowed-tools: Bash(openspec:*)\n---\n'
        r'Propose $ARGUMENTS'
        '\n',
      );
    File(p.join(workspace.path, '.claude', 'skills', 'x', 'SKILL.md'))
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '---\nname: x\ndescription: d\nallowed-tools: Bash\n---\nBody\n',
      );
    final view = loadWorkspace(workspace: workspace.path, kehaiHome: home);
    expect(
      view.command('opsx:propose')!.frontmatter['allowed-tools'],
      'Bash(openspec:*)',
    );
    expect(view.skill('x'), isNotNull);

    final withFrontmatter = await promptFor();

    expect(withFrontmatter, isNotNull);
    expect(withFrontmatter!.tool, 'bash');
    expect(withFrontmatter.input, without!.input);
  });

  test('a skill call is allowed without a prompt', () async {
    final answerer = RecordingAnswerer();

    final outcome = await PermissionGate(
      workspace: workspace,
      kehaiHome: home,
      prompts: PromptChannel(answerer),
    ).check(_call('skill', {'name': 'x'}), CancelToken());

    expect(outcome.denyReason, isNull);
    expect(outcome.record, containsPair('by', 'builtin'));
    expect(answerer.items, isEmpty);
  });
}
