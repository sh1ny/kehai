/// Command definitions (slash-commands spec).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../permissions/workspace_paths.dart';
import 'containment.dart';
import 'frontmatter.dart';
import 'skills.dart';

/// A `.md` file under `.claude/commands`.
class Command {
  /// Creates a command.
  const Command({
    required this.name,
    required this.path,
    required this.source,
    required this.body,
    required this.size,
    required this.frontmatter,
  });

  /// The path under `commands/` without `.md`, with `/` as `:`.
  final String name;

  /// The file (absolute).
  final String path;

  /// The file relative to the project root, written with `/`.
  final String source;

  /// The text after the frontmatter; empty when [size] is over the bound.
  final String body;

  /// The file's size in bytes.
  final int size;

  /// The frontmatter keys.
  final Map<String, Object?> frontmatter;
}

/// The commands found under a project root.
class CommandDiscovery {
  /// Creates a result.
  const CommandDiscovery({required this.commands, required this.problems});

  /// Commands sorted by name.
  final List<Command> commands;

  /// Files that are not commands, and why.
  final List<Problem> problems;
}

/// Lists the commands under `<root>/.claude/commands`.
///
/// A command is a `.md` file at any depth; subdirectories become `:` in the
/// name. A file whose frontmatter does not parse is a problem. A directory
/// that resolves outside [root] is not entered and is a problem. Every read
/// goes through [readContained].
CommandDiscovery discoverCommands({
  required String root,
  required Directory kehaiHome,
}) {
  final base = p.join(root, '.claude', 'commands');
  final commands = <Command>[];
  final problems = <Problem>[];
  final realRoot = realPath(root);
  if (!FileSystemEntity.isDirectorySync(base)) {
    return const CommandDiscovery(commands: [], problems: []);
  }

  void walk(String dir) {
    final real = realPath(dir);
    if (realRoot == null || real == null || !isInside(realRoot, real)) {
      problems.add(Problem(displayPath(root, dir), 'outside the project root'));
      return;
    }
    final entries = Directory(dir).listSync(followLinks: false)
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final entry in entries) {
      if (FileSystemEntity.isDirectorySync(entry.path)) {
        walk(entry.path);
      } else if (entry.path.endsWith('.md')) {
        final command = _readCommand(
          root,
          base,
          entry.path,
          kehaiHome,
          problems,
        );
        if (command != null) commands.add(command);
      }
    }
  }

  walk(base);
  commands.sort((a, b) => a.name.compareTo(b.name));
  return CommandDiscovery(commands: commands, problems: problems);
}

Command? _readCommand(
  String root,
  String base,
  String file,
  Directory kehaiHome,
  List<Problem> problems,
) {
  final read = readContained(
    root: root,
    path: file,
    kehaiHome: kehaiHome,
    limit: maxSkillFileBytes,
  );
  final problem = read.problem;
  if (problem != null) {
    problems.add(problem);
    return null;
  }
  final shown = displayPath(root, file);
  final fm = parseFrontmatter(read.text!);
  final error = fm.error;
  if (error != null) {
    problems.add(Problem(shown, error));
    return null;
  }
  final relative = p.relative(file, from: base);
  final name = p
      .split(relative.substring(0, relative.length - '.md'.length))
      .join(':');
  return Command(
    name: name,
    path: file,
    source: shown,
    body: read.truncated ? '' : fm.body,
    size: read.size,
    frontmatter: fm.data,
  );
}

/// One name a user can type after `/`.
class SlashCommand {
  /// Creates an entry for a command file or a skill.
  const SlashCommand(this.name, {this.command, this.skill});

  /// The name.
  final String name;

  /// The command file, which wins over a skill of the same name.
  final Command? command;

  /// The skill, when no command file has the name.
  final Skill? skill;
}

/// The names usable after `/`.
class SlashCommands {
  /// Creates a result.
  const SlashCommands({required this.entries, required this.problems});

  /// Entries sorted by name.
  final List<SlashCommand> entries;

  /// Skills shadowed by a command file.
  final List<Problem> problems;
}

/// Merges [commands] with the user-invocable [skills].
///
/// A skill that sets `user-invocable: false` is not an entry. When a command
/// file and a skill share a name the command file is the entry and the skill
/// is recorded as shadowed for `/` use.
SlashCommands slashCommands({
  required String root,
  required List<Command> commands,
  required List<Skill> skills,
}) {
  final byName = <String, SlashCommand>{
    for (final c in commands) c.name: SlashCommand(c.name, command: c),
  };
  final problems = <Problem>[];
  for (final s in skills) {
    if (!s.userInvocable) continue;
    final existing = byName[s.name];
    if (existing == null) {
      byName[s.name] = SlashCommand(s.name, skill: s);
    } else {
      problems.add(
        Problem(
          displayPath(root, s.file),
          'shadowed by ${existing.command!.source} for / use',
        ),
      );
    }
  }
  final entries = byName.values.toList()
    ..sort((a, b) => a.name.compareTo(b.name));
  return SlashCommands(entries: entries, problems: problems);
}
