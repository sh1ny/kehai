import 'dart:io';

import 'package:kehai/src/workspace/roles.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String root;
  late Directory home;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kehai_roles_');
    root = p.join(tmp.path, 'repo');
    Directory(root).createSync();
    home = Directory(p.join(tmp.path, 'home'))..createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void role(String file, String text) {
    final f = File(p.join(root, '.claude', 'agents', file));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text);
  }

  test('a role file gives name, model, tools and body', () {
    role(
      'specwright-reviewer.md',
      '---\nname: specwright-reviewer\ndescription: Reviews\nmodel: inherit\n'
          'tools: Read, Grep, Glob, Bash, Write, Skill\n---\nYou review.\n',
    );
    role('plain.md', '---\nname: plain\ndescription: No tools\n---\nBody\n');
    final found = discoverRoles(root: root, kehaiHome: home);
    expect(found.problems, isEmpty);
    expect(found.roles.map((r) => r.name), ['plain', 'specwright-reviewer']);
    final r = found.roles.last;
    expect(r.model, 'inherit');
    expect(r.tools, ['Read', 'Grep', 'Glob', 'Bash', 'Write', 'Skill']);
    expect(r.body, 'You review.\n');
    expect(r.description, 'Reviews');
    expect(r.digest, hasLength(64));
    expect(found.roles.first.tools, isNull);
    expect(found.roles.first.model, isNull);
  });

  test('a role without description is a problem', () {
    role('nodesc.md', '---\nname: nodesc\n---\nBody\n');
    role('a.md', '---\nname: dup\ndescription: x\n---\n');
    role('b.md', '---\nname: dup\ndescription: y\n---\n');
    final found = discoverRoles(root: root, kehaiHome: home);
    final reasons = {for (final e in found.problems) e.path: e.reason};
    expect(reasons['.claude/agents/nodesc.md'], 'missing description');
    expect(found.roles.map((r) => r.name), ['dup']);
    expect(reasons['.claude/agents/b.md'], contains('duplicate'));
  });

  test('a tools value that is not names makes the role invalid, never '
      'unrestricted', () {
    role('bool.md', '---\nname: bool\ndescription: x\ntools: false\n---\n');
    role('num.md', '---\nname: num\ndescription: x\ntools: 42\n---\n');
    role(
      'map.md',
      '---\nname: map\ndescription: x\ntools:\n  Read: yes\n---\n',
    );
    role(
      'nested.md',
      '---\nname: nested\ndescription: x\ntools: [[Read]]\n---\n',
    );
    role('empty.md', '---\nname: empty\ndescription: x\ntools:\n---\n');
    role(
      'list.md',
      '---\nname: list\ndescription: x\ntools: [Read, Grep]\n---\n',
    );
    final found = discoverRoles(root: root, kehaiHome: home);
    final reasons = {for (final e in found.problems) e.path: e.reason};
    for (final name in ['bool', 'num', 'map', 'nested']) {
      expect(
        reasons['.claude/agents/$name.md'],
        'tools must be a comma-separated string or a list of names',
        reason: name,
      );
    }
    expect(found.roles.map((r) => r.name), ['empty', 'list']);
    expect(found.roles.first.tools, isNull, reason: 'empty is the default');
    expect(found.roles.last.tools, ['Read', 'Grep']);
  });

  test('reviewer tools map to the ten Kehai tools', () {
    final m = mapRoleTools(['Read', 'Grep', 'Glob', 'Bash', 'Write', 'Skill']);
    expect(m.tools, [
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
    ]);
    expect(m.unmapped, isEmpty);
    expect(mapRoleTools(null).tools, isNull);
  });

  test('WebFetch is ignored and recorded as unmapped', () {
    final m = mapRoleTools(['Read', 'WebFetch']);
    expect(m.tools, ['read', 'read_more', 'search_result']);
    expect(m.unmapped, ['WebFetch']);
    role('x.md', '---\nname: x\ndescription: d\ntools: Read, WebFetch\n---\n');
    final found = discoverRoles(root: root, kehaiHome: home);
    expect(found.roles.single.unmapped, ['WebFetch']);
    expect(
      found.problems.single.toString(),
      '.claude/agents/x.md: tool WebFetch is unmapped',
    );
  });
}
