import 'dart:io';

import 'package:kehai/src/workspace/inventory.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late Directory home;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kehai_inventory_');
    home = Directory(p.join(tmp.path, 'home'))..createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(String relative, String text) {
    final f = File(p.join(tmp.path, 'repo', relative));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text);
  }

  test('one Workspace value holds root, files, skills, commands, roles and '
      'problems', () {
    write('.git/HEAD', 'ref');
    write('AGENTS.md', 'rules\n');
    write('.claude/skills/a/SKILL.md', '---\nname: a\ndescription: A\n---\n');
    write('.agents/skills/a/SKILL.md', '---\nname: a\ndescription: A2\n---\n');
    write('.claude/commands/opsx/go.md', 'go\n');
    write('.claude/commands/a.md', 'command a\n');
    write('.claude/agents/r.md', '---\nname: r\ndescription: R\n---\nbody\n');
    write('sub/placeholder', '');
    final ws = loadWorkspace(
      workspace: p.join(tmp.path, 'repo', 'sub'),
      kehaiHome: home,
    );
    expect(
      ws.root,
      Directory(p.join(tmp.path, 'repo')).resolveSymbolicLinksSync(),
    );
    expect(ws.files.map((f) => f.path), ['AGENTS.md']);
    expect(ws.skills.map((s) => s.name), ['a']);
    expect(ws.skill('a')!.description, 'A');
    expect(ws.commands.map((c) => c.name), ['a', 'opsx:go']);
    expect(ws.slashCommands.map((c) => c.name), ['a', 'opsx:go']);
    expect(ws.slashCommands.first.command, isNotNull);
    expect(ws.roles.map((r) => r.name), ['r']);
    expect(ws.problems.map((e) => e.path), [
      '.agents/skills/a/SKILL.md',
      '.claude/skills/a/SKILL.md',
    ]);
    expect(ws.contextText, contains('## AGENTS.md'));
    expect(ws.contextText, contains('- a: A\n'));
  });
}
