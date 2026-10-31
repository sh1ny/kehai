/// Agent roles (subagents spec).
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import '../permissions/workspace_paths.dart';
import 'containment.dart';
import 'frontmatter.dart';
import 'skills.dart';

/// An agent role under `.claude/agents`.
class Role {
  /// Creates a role.
  const Role({
    required this.name,
    required this.description,
    required this.model,
    required this.tools,
    required this.unmapped,
    required this.body,
    required this.path,
    required this.source,
    required this.digest,
  });

  /// The role's name.
  final String name;

  /// What the role is for.
  final String description;

  /// The `model` value, or null.
  final String? model;

  /// The listed Claude Code tool names, or null when `tools` is absent.
  final List<String>? tools;

  /// Listed names with no Kehai tool.
  final List<String> unmapped;

  /// The role's instructions: the text after the frontmatter.
  final String body;

  /// The file (absolute).
  final String path;

  /// The file relative to the project root, written with `/`.
  final String source;

  /// The SHA-256 of the file's text, in hex.
  final String digest;
}

/// The roles found under a project root.
class RoleDiscovery {
  /// Creates a result.
  const RoleDiscovery({required this.roles, required this.problems});

  /// Roles sorted by name.
  final List<Role> roles;

  /// Invalid files, duplicates and unmapped tool names.
  final List<Problem> problems;
}

final RegExp _roleName = RegExp(r'^[a-z0-9-]{1,64}$');

/// Lists the roles directly under `<root>/.claude/agents`.
///
/// A role needs frontmatter with a valid `name` and a `description`. An
/// invalid file, a duplicate name or a file over the size bound is a problem
/// and not a role; so is each tool name with no Kehai tool. Every read goes
/// through [readContained].
RoleDiscovery discoverRoles({
  required String root,
  required Directory kehaiHome,
}) {
  final dir = p.join(root, '.claude', 'agents');
  final roles = <String, Role>{};
  final problems = <Problem>[];
  if (!FileSystemEntity.isDirectorySync(dir)) {
    return const RoleDiscovery(roles: [], problems: []);
  }
  final realRoot = realPath(root);
  final realDir = realPath(dir);
  if (realRoot == null || realDir == null || !isInside(realRoot, realDir)) {
    return RoleDiscovery(
      roles: const [],
      problems: [Problem('.claude/agents', 'outside the project root')],
    );
  }
  final entries = Directory(dir).listSync(followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entry in entries) {
    if (!entry.path.endsWith('.md') ||
        FileSystemEntity.isDirectorySync(entry.path)) {
      continue;
    }
    final shown = displayPath(root, entry.path);
    final read = readContained(
      root: root,
      path: entry.path,
      kehaiHome: kehaiHome,
      limit: maxSkillFileBytes,
    );
    final problem = read.problem;
    if (problem != null) {
      problems.add(problem);
      continue;
    }
    if (read.truncated) {
      problems.add(
        Problem(
          shown,
          'file is ${(read.size / 1024).round()} KiB, over the '
          '${maxSkillFileBytes ~/ 1024} KiB limit',
        ),
      );
      continue;
    }
    final fm = parseFrontmatter(read.text!);
    final error = fm.error ?? (fm.present ? null : 'missing frontmatter');
    if (error != null) {
      problems.add(Problem(shown, error));
      continue;
    }
    final name = fm.data['name'];
    if (name is! String || !_roleName.hasMatch(name)) {
      problems.add(
        Problem(
          shown,
          name is String
              ? 'name "$name" must be 1-64 lowercase letters, digits and '
                    'hyphens'
              : 'missing name',
        ),
      );
      continue;
    }
    final description = fm.data['description'];
    final text = description is String ? description.trim() : '';
    if (text.isEmpty) {
      problems.add(Problem(shown, 'missing description'));
      continue;
    }
    if (roles.containsKey(name)) {
      problems.add(
        Problem(
          shown,
          'duplicate role name "$name" (see ${roles[name]!.source})',
        ),
      );
      continue;
    }
    final tools = _toolNames(fm.data['tools']);
    final mapped = mapRoleTools(tools);
    for (final unmapped in mapped.unmapped) {
      problems.add(Problem(shown, 'tool $unmapped is unmapped'));
    }
    final model = fm.data['model'];
    roles[name] = Role(
      name: name,
      description: text,
      model: model is String && model.trim().isNotEmpty ? model.trim() : null,
      tools: tools,
      unmapped: mapped.unmapped,
      body: fm.body,
      path: entry.path,
      source: shown,
      digest: sha256.convert(utf8.encode(read.text!)).toString(),
    );
  }
  final sorted = roles.values.toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  return RoleDiscovery(roles: sorted, problems: problems);
}

List<String>? _toolNames(Object? value) => switch (value) {
  final String s => [
    for (final t in s.split(','))
      if (t.trim().isNotEmpty) t.trim(),
  ],
  final List<Object?> l => [
    for (final t in l)
      if ('$t'.trim().isNotEmpty) '$t'.trim(),
  ],
  _ => null,
};

/// A role's tools as Kehai tool names.
class RoleTools {
  /// Creates a mapping result.
  const RoleTools(this.tools, this.unmapped);

  /// The Kehai tools, or null for every tool but `agent`.
  final List<String>? tools;

  /// Names that have no Kehai tool.
  final List<String> unmapped;
}

const Map<String, List<String>> _toolMap = {
  'Read': ['read'],
  'Grep': ['grep'],
  'Glob': ['find', 'ls'],
  'Edit': ['edit'],
  'Write': ['write'],
  'Bash': ['bash', 'job'],
  'Skill': ['skill'],
  'AskUserQuestion': ['ask'],
};

/// Tools every role is offered, whatever its `tools`.
const List<String> alwaysOfferedTools = ['read_more', 'search_result'];

/// Maps Claude Code tool names to Kehai tools.
///
/// `read_more` and `search_result` are always offered and `agent` never is.
/// With no names ([names] null) the role gets every tool but `agent`, which
/// is [RoleTools.tools] null. Unknown names are ignored and listed in
/// [RoleTools.unmapped].
RoleTools mapRoleTools(List<String>? names) {
  if (names == null) return const RoleTools(null, []);
  final tools = <String>{};
  final unmapped = <String>[];
  for (final name in names) {
    final mapped = _toolMap[name];
    if (mapped == null) {
      if (!unmapped.contains(name)) unmapped.add(name);
    } else {
      tools.addAll(mapped);
    }
  }
  tools.addAll(alwaysOfferedTools);
  return RoleTools(tools.toList(), unmapped);
}

/// The roster tool names a child engine of [role] offers (design D9).
///
/// Without `tools` that is every tool in [allTools] but `agent`; with them the
/// mapped tools and the always-offered ones. `agent` is never included, so a
/// child cannot start children of its own.
Set<String> roleRoster(Role role, Iterable<String> allTools) {
  final mapped = mapRoleTools(role.tools).tools;
  return {
    for (final name in allTools)
      if (name != 'agent' && (mapped == null || mapped.contains(name))) name,
  };
}
