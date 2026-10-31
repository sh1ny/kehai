import 'dart:io';

import 'package:kehai/src/workspace/commands.dart';
import 'package:kehai/src/workspace/skills.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String root;
  late Directory home;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kehai_commands_');
    root = p.join(tmp.path, 'repo');
    Directory(root).createSync();
    home = Directory(p.join(tmp.path, 'home'))..createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void command(String relative, String text) {
    final f = File(p.join(root, '.claude', 'commands', relative));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text);
  }

  test('opsx/propose.md is the command opsx:propose without its '
      'frontmatter', () {
    command(
      'opsx/propose.md',
      '---\nname: "OPSX: Propose"\ndescription: Propose\n---\nDo the thing.\n',
    );
    command('plain.md', 'No frontmatter here\n');
    command('notes.txt', 'ignored');
    final found = discoverCommands(root: root, kehaiHome: home);
    expect(found.problems, isEmpty);
    expect(found.commands.map((c) => c.name), ['opsx:propose', 'plain']);
    final c = found.commands.first;
    expect(c.body, 'Do the thing.\n');
    expect(c.source, '.claude/commands/opsx/propose.md');
    expect(found.commands.last.body, 'No frontmatter here\n');
  });

  test('an unclosed frontmatter is not a command and is a problem', () {
    command('opsx/bad.md', '---\nname: x\nno closing line\n');
    command('opsx/good.md', 'ok\n');
    final found = discoverCommands(root: root, kehaiHome: home);
    expect(found.commands.map((c) => c.name), ['opsx:good']);
    expect(found.problems.single.path, '.claude/commands/opsx/bad.md');
    expect(found.problems.single.reason, contains('not closed'));
  });

  Skill skill(String name, {bool invocable = true}) => Skill(
    name: name,
    description: 'd',
    directory: p.join(root, '.claude', 'skills', name),
    file: p.join(root, '.claude', 'skills', name, 'SKILL.md'),
    rootDir: '.claude/skills',
    size: 1,
    userInvocable: invocable,
  );

  test('skills are commands unless not user-invocable, and a command file '
      'wins', () {
    command('opsx/propose.md', 'cmd\n');
    command('same.md', 'cmd same\n');
    final found = discoverCommands(root: root, kehaiHome: home);
    final merged = slashCommands(
      root: root,
      commands: found.commands,
      skills: [
        skill('same'),
        skill('hidden', invocable: false),
        skill('alpha'),
      ],
    );
    expect(merged.entries.map((e) => e.name), [
      'alpha',
      'opsx:propose',
      'same',
    ]);
    expect(
      merged.entries.firstWhere((e) => e.name == 'same').command,
      isNotNull,
    );
    expect(
      merged.entries.firstWhere((e) => e.name == 'alpha').skill,
      isNotNull,
    );
    expect(merged.problems.single.path, '.claude/skills/same/SKILL.md');
    expect(merged.problems.single.reason, startsWith('shadowed by '));
  });
}
