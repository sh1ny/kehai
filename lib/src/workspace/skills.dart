/// Skill discovery (skills spec, design D3).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../permissions/workspace_paths.dart';
import 'containment.dart';
import 'frontmatter.dart';

/// An installed skill.
class Skill {
  /// Creates a skill.
  const Skill({
    required this.name,
    required this.description,
    required this.directory,
    required this.file,
    required this.rootDir,
    required this.size,
    this.userInvocable = true,
    this.disableModelInvocation = false,
  });

  /// The skill's name, equal to its directory name.
  final String name;

  /// The one-line description shown in the catalog.
  final String description;

  /// The skill's base directory (absolute).
  final String directory;

  /// The `SKILL.md` file (absolute).
  final String file;

  /// `.claude/skills` or `.agents/skills`.
  final String rootDir;

  /// The size of `SKILL.md` in bytes.
  final int size;

  /// False when the frontmatter sets `user-invocable: false`.
  final bool userInvocable;

  /// True when the frontmatter sets `disable-model-invocation: true`.
  final bool disableModelInvocation;
}

/// The skills found under a project root.
class SkillDiscovery {
  /// Creates a result.
  const SkillDiscovery({
    required this.skills,
    required this.shadowed,
    required this.problems,
  });

  /// Skills by name, sorted.
  final List<Skill> skills;

  /// Copies hidden by a same-name skill of `.claude/skills`.
  final List<Skill> shadowed;

  /// Invalid skills and shadowed copies.
  final List<Problem> problems;
}

/// Largest `SKILL.md` or command file loaded whole, in bytes (256 KiB).
const int maxSkillFileBytes = 256 * 1024;

/// Longest skill description, in characters.
const int maxDescriptionLength = 1024;

/// The skill roots under a project root, `.claude` first.
const List<String> skillRoots = ['.claude/skills', '.agents/skills'];

final RegExp _skillName = RegExp(r'^[a-z0-9-]{1,64}$');

/// Lists the skills of `<root>/.claude/skills` then `<root>/.agents/skills`.
///
/// A skill is a directory holding a valid `SKILL.md`. Files, directories
/// without `SKILL.md` and anything else that is not a skill directory are
/// skipped silently; invalid skills and directories that resolve outside
/// [root] are problems. On a name clash the `.claude` copy wins and the other
/// is [SkillDiscovery.shadowed] with a problem. Every read goes through
/// [readContained].
SkillDiscovery discoverSkills({
  required String root,
  required Directory kehaiHome,
}) {
  final chosen = <String, Skill>{};
  final shadowed = <Skill>[];
  final problems = <Problem>[];
  final realRoot = realPath(root);
  for (final rootDir in skillRoots) {
    final dir = p.joinAll([root, ...rootDir.split('/')]);
    if (!FileSystemEntity.isDirectorySync(dir)) continue;
    final realDir = realPath(dir);
    if (realRoot == null || realDir == null || !isInside(realRoot, realDir)) {
      problems.add(Problem(rootDir, 'outside the project root'));
      continue;
    }
    List<FileSystemEntity> entries;
    try {
      entries = Directory(dir).listSync(followLinks: false);
    } on FileSystemException catch (e) {
      problems.add(
        Problem(
          displayPath(root, dir),
          'cannot be listed: ${e.osError?.message ?? e.message}',
        ),
      );
      continue;
    }
    entries.sort((a, b) => a.path.compareTo(b.path));
    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (!FileSystemEntity.isDirectorySync(entry.path)) continue;
      final shown = displayPath(root, entry.path);
      final realEntry = realPath(entry.path);
      if (realEntry == null || !isInside(realRoot, realEntry)) {
        problems.add(Problem(shown, 'outside the project root'));
        continue;
      }
      final file = p.join(entry.path, 'SKILL.md');
      if (FileSystemEntity.typeSync(file, followLinks: false) ==
          FileSystemEntityType.notFound) {
        continue;
      }
      final skill = _readSkill(
        root: root,
        rootDir: rootDir,
        name: name,
        directory: entry.path,
        file: file,
        kehaiHome: kehaiHome,
        problems: problems,
      );
      if (skill == null) continue;
      final winner = chosen[skill.name];
      if (winner == null) {
        chosen[skill.name] = skill;
      } else {
        shadowed.add(skill);
        problems.add(
          Problem(
            displayPath(root, skill.file),
            'shadowed by ${displayPath(root, winner.file)}',
          ),
        );
      }
    }
  }
  final skills = chosen.values.toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  return SkillDiscovery(skills: skills, shadowed: shadowed, problems: problems);
}

Skill? _readSkill({
  required String root,
  required String rootDir,
  required String name,
  required String directory,
  required String file,
  required Directory kehaiHome,
  required List<Problem> problems,
}) {
  final read = readContained(
    root: root,
    path: file,
    kehaiHome: kehaiHome,
    limit: maxSkillFileBytes,
  );
  final shown = displayPath(root, file);
  final problem = read.problem;
  if (problem != null) {
    problems.add(problem);
    return null;
  }
  Skill? fail(String reason) {
    problems.add(Problem(shown, reason));
    return null;
  }

  final fm = parseFrontmatter(read.text!);
  final error = fm.error;
  if (error != null) return fail(error);
  if (!fm.present) return fail('missing frontmatter');
  final declared = fm.data['name'];
  if (declared is! String || declared.isEmpty) return fail('missing name');
  if (!_skillName.hasMatch(declared)) {
    return fail(
      'name "$declared" must be 1-64 lowercase letters, digits and hyphens',
    );
  }
  if (declared != name) {
    return fail('name "$declared" differs from the directory name "$name"');
  }
  final description = fm.data['description'];
  final text = description is String ? description.trim() : '';
  if (text.isEmpty) return fail('missing description');
  if (text.length > maxDescriptionLength) {
    return fail(
      'description is ${text.length} characters, over the '
      '$maxDescriptionLength limit',
    );
  }
  return Skill(
    name: declared,
    description: text,
    directory: directory,
    file: file,
    rootDir: rootDir,
    size: read.size,
    userInvocable: frontmatterBool(fm.data, 'user-invocable', true),
    disableModelInvocation: frontmatterBool(
      fm.data,
      'disable-model-invocation',
      false,
    ),
  );
}
