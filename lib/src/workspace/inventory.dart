/// One view of the workspace for doctor, capture, tools and child mode
/// (design D1).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../permissions/workspace_paths.dart';
import 'agents_md.dart';
import 'commands.dart';
import 'containment.dart';
import 'context_text.dart';
import 'project_root.dart';
import 'roles.dart';
import 'skills.dart';

/// What the loaders found for one workspace.
class Workspace {
  /// Creates a view; [loadWorkspace] builds it from the disk.
  const Workspace({
    required this.workspace,
    required this.root,
    required this.files,
    required this.skills,
    required this.shadowedSkills,
    required this.commands,
    required this.slashCommands,
    required this.roles,
    required this.problems,
  });

  /// The workspace directory (real path).
  final String workspace;

  /// The project root (real path).
  final String root;

  /// The applicable `AGENTS.md` files, root first.
  final List<AgentsFile> files;

  /// Skills by name; the `.claude` copy where both roots hold one.
  final List<Skill> skills;

  /// Skill copies hidden by a same-name skill of `.claude/skills`.
  final List<Skill> shadowedSkills;

  /// Command files by name.
  final List<Command> commands;

  /// The names usable after `/`: commands and user-invocable skills.
  final List<SlashCommand> slashCommands;

  /// Agent roles by name.
  final List<Role> roles;

  /// Every skipped, shadowed or unmapped item, in discovery order.
  final List<Problem> problems;

  /// The skill named [name], or null.
  Skill? skill(String name) {
    for (final s in skills) {
      if (s.name == name) return s;
    }
    return null;
  }

  /// The command file named [name], or null.
  Command? command(String name) {
    for (final c in commands) {
      if (c.name == name) return c;
    }
    return null;
  }

  /// The role named [name], or null.
  Role? role(String name) {
    for (final r in roles) {
      if (r.name == name) return r;
    }
    return null;
  }

  /// The context text for the instructions (design D5).
  String get contextText => renderContextText(files: files, skills: skills);
}

/// Loads the view of [workspace]: project root, `AGENTS.md` files, skills,
/// commands, roles and problems.
///
/// Reads only; every automatic read stays inside the project root and away
/// from the credential files of [kehaiHome] (design D15).
Workspace loadWorkspace({
  required String workspace,
  required Directory kehaiHome,
}) {
  final root = projectRoot(workspace);
  final start = realPath(workspace) ?? p.normalize(p.absolute(workspace));
  final agents = loadAgentsMd(
    root: root,
    workspace: start,
    kehaiHome: kehaiHome,
  );
  final skills = discoverSkills(root: root, kehaiHome: kehaiHome);
  final commands = discoverCommands(root: root, kehaiHome: kehaiHome);
  final roles = discoverRoles(root: root, kehaiHome: kehaiHome);
  final slash = slashCommands(
    root: root,
    commands: commands.commands,
    skills: skills.skills,
  );
  return Workspace(
    workspace: start,
    root: root,
    files: agents.files,
    skills: skills.skills,
    shadowedSkills: skills.shadowed,
    commands: commands.commands,
    slashCommands: slash.entries,
    roles: roles.roles,
    problems: [
      ...agents.problems,
      ...skills.problems,
      ...commands.problems,
      ...slash.problems,
      ...roles.problems,
    ],
  );
}
