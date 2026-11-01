import 'package:kehai/src/workspace/agents_md.dart';
import 'package:kehai/src/workspace/context_text.dart';
import 'package:kehai/src/workspace/skills.dart';
import 'package:test/test.dart';

Skill _skill(String name, {bool hidden = false, String? description}) => Skill(
  name: name,
  description: description ?? 'does $name',
  directory: '/r/.claude/skills/$name',
  file: '/r/.claude/skills/$name/SKILL.md',
  rootDir: '.claude/skills',
  size: 10,
  disableModelInvocation: hidden,
);

void main() {
  test('80 skills list 64 with descriptions and 16 by name', () {
    final skills = [
      for (var i = 0; i < 80; i++)
        _skill('skill-${i.toString().padLeft(2, '0')}'),
    ];
    final text = renderContextText(files: const [], skills: skills);
    final lines = text.split('\n');
    final described = lines.where(
      (l) => l.startsWith('- skill-') && l.contains(': does '),
    );
    final bare = lines.where((l) => RegExp(r'^- skill-\d\d$').hasMatch(l));
    expect(described.length, 64);
    expect(bare.length, 16);
    expect(described.first, '- skill-00: does skill-00');
    expect(described.last, '- skill-63: does skill-63');
    expect(bare.first, '- skill-64');
    expect(bare.last, '- skill-79');
    final note = lines.indexWhere(
      (l) => l.contains('descriptions') && l.contains('left out'),
    );
    expect(note, greaterThan(lines.indexOf('- skill-63: does skill-63')));
    expect(note, lessThan(lines.indexOf('- skill-64')));
    expect(text, startsWith('# Skills\n'));
  });

  test('project instructions come first, one section per file', () {
    final text = renderContextText(
      files: const [
        AgentsFile(
          path: 'AGENTS.md',
          text: 'root rules\n',
          size: 11,
          truncated: false,
        ),
        AgentsFile(
          path: 'pkg/AGENTS.md',
          text: 'pkg rules',
          size: 9,
          truncated: false,
        ),
      ],
      skills: [
        _skill('b-skill', description: 'two\nlines'),
        _skill('a-skill'),
        _skill('hidden', hidden: true),
      ],
    );
    expect(
      text,
      '# Project instructions\n\n'
      '## AGENTS.md\n\nroot rules\n\n'
      '## pkg/AGENTS.md\n\npkg rules\n\n'
      '# Skills\n\n'
      '- a-skill: does a-skill\n'
      '- b-skill: two lines\n',
    );
  });

  test('nothing to say gives empty text', () {
    expect(renderContextText(files: const [], skills: const []), '');
  });
}
