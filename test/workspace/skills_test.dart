import 'dart:io';

import 'package:kehai/src/workspace/skills.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String root;
  late Directory home;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kehai_skills_');
    root = p.join(tmp.path, 'repo');
    Directory(root).createSync();
    home = Directory(p.join(tmp.path, 'home'))..createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void skill(String dir, String name, String text, {String? file}) {
    final f = File(p.join(root, dir, name, file ?? 'SKILL.md'));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text);
  }

  SkillDiscovery discover() => discoverSkills(root: root, kehaiHome: home);

  test('a valid SKILL.md becomes a skill with its directory as base', () {
    skill(
      '.claude/skills',
      'specwright-roadmap',
      '---\nname: specwright-roadmap\ndescription: "Plan: roadmap"\n'
          'user-invocable: false\ndisable-model-invocation: true\n---\nBody\n',
    );
    final found = discover();
    expect(found.problems, isEmpty);
    final s = found.skills.single;
    expect(s.name, 'specwright-roadmap');
    expect(s.description, 'Plan: roadmap');
    expect(
      s.directory,
      p.join(root, '.claude', 'skills', 'specwright-roadmap'),
    );
    expect(s.rootDir, '.claude/skills');
    expect(s.userInvocable, isFalse);
    expect(s.disableModelInvocation, isTrue);
  });

  test('missing frontmatter, mismatched name or empty description is a '
      'problem', () {
    skill('.claude/skills', 'plain', '# no frontmatter\n');
    skill(
      '.claude/skills',
      'other',
      '---\nname: different\ndescription: d\n---\n',
    );
    skill(
      '.claude/skills',
      'blank',
      '---\nname: blank\ndescription: ""\n---\n',
    );
    skill(
      '.claude/skills',
      'broken',
      '---\nname: broken\ndescription: [1, 2\n---\n',
    );
    final found = discover();
    expect(found.skills, isEmpty);
    final byPath = {for (final e in found.problems) e.path: e.reason};
    expect(
      byPath.keys,
      containsAll([
        '.claude/skills/plain/SKILL.md',
        '.claude/skills/other/SKILL.md',
        '.claude/skills/blank/SKILL.md',
        '.claude/skills/broken/SKILL.md',
      ]),
    );
    expect(byPath['.claude/skills/plain/SKILL.md'], contains('frontmatter'));
    expect(byPath['.claude/skills/other/SKILL.md'], contains('name'));
    expect(byPath['.claude/skills/blank/SKILL.md'], contains('description'));
    expect(byPath['.claude/skills/broken/SKILL.md'], contains('invalid YAML'));
  });

  test('files and folders without SKILL.md are skipped silently', () {
    Directory(p.join(root, '.agents', 'skills', 'empty'))
        .createSync(recursive: true);
    File(p.join(root, '.agents', 'skills', 'LICENSE.dart'))
        .writeAsStringSync('x');
    final found = discover();
    expect(found.skills, isEmpty);
    expect(found.problems, isEmpty);
  });

  test('the .claude copy wins and the .agents copy is shadowed', () {
    String doc(String d) =>
        '---\nname: openspec-propose\ndescription: $d\n---\n';
    skill('.agents/skills', 'openspec-propose', doc('agents text'));
    skill('.claude/skills', 'openspec-propose', doc('claude text'));
    skill('.agents/skills', 'alpha', '---\nname: alpha\ndescription: a\n---\n');
    final found = discover();
    expect(found.skills.map((s) => s.name), ['alpha', 'openspec-propose']);
    expect(
      found.skills.firstWhere((s) => s.name == 'openspec-propose').description,
      'claude text',
    );
    expect(found.shadowed.single.rootDir, '.agents/skills');
    expect(
      found.problems.single.path,
      '.agents/skills/openspec-propose/SKILL.md',
    );
    expect(found.problems.single.reason, startsWith('shadowed by '));
  });
}
