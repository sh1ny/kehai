/// Applicable `AGENTS.md` files (workspace-context spec).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import 'containment.dart';

/// Bytes of one `AGENTS.md` included in the context.
const int agentsMdLimit = 32 * 1024;

/// Most `AGENTS.md` files included in the context.
const int agentsMdMaxFiles = 8;

/// One `AGENTS.md` taken into the context.
class AgentsFile {
  /// Creates a file entry.
  const AgentsFile({
    required this.path,
    required this.text,
    required this.size,
    required this.truncated,
  });

  /// The path relative to the project root, written with `/`.
  final String path;

  /// The included text; a cut file ends with the truncation note.
  final String text;

  /// The file's full size in bytes.
  final int size;

  /// Whether [text] stops short of the file.
  final bool truncated;
}

/// The applicable `AGENTS.md` files and what went wrong with others.
class AgentsMd {
  /// Creates a result.
  const AgentsMd({required this.files, required this.problems});

  /// Files from the project root to the workspace.
  final List<AgentsFile> files;

  /// Unreadable, outside-the-root and left-out files.
  final List<Problem> problems;
}

/// Reads the `AGENTS.md` files from [root] down to [workspace].
///
/// [workspace] must be [root] or inside it. Only the [agentsMdMaxFiles]
/// files nearest the workspace are read; the others are named in one
/// problem. Every read goes through [readContained].
AgentsMd loadAgentsMd({
  required String root,
  required String workspace,
  required Directory kehaiHome,
}) {
  final dirs = <String>[root];
  final rest = p.split(p.relative(workspace, from: root));
  var current = root;
  for (final segment in rest) {
    if (segment == '.' || segment.isEmpty) continue;
    current = p.join(current, segment);
    dirs.add(current);
  }
  final present = [
    for (final dir in dirs)
      if (FileSystemEntity.typeSync(
                p.join(dir, 'AGENTS.md'),
                followLinks: false,
              ) !=
              FileSystemEntityType.notFound &&
          FileSystemEntity.typeSync(
                p.join(dir, 'AGENTS.md'),
                followLinks: false,
              ) !=
              FileSystemEntityType.directory)
        p.join(dir, 'AGENTS.md'),
  ];
  final problems = <Problem>[];
  var kept = present;
  if (present.length > agentsMdMaxFiles) {
    final left = present.length - agentsMdMaxFiles;
    kept = present.sublist(left);
    final names = [for (final f in present.take(left)) displayPath(root, f)];
    problems.add(
      Problem(
        names.first,
        'left out: only the $agentsMdMaxFiles AGENTS.md files nearest the '
        'workspace apply; $left left out (${names.join(', ')})',
      ),
    );
  }
  final files = <AgentsFile>[];
  for (final path in kept) {
    final read = readContained(
      root: root,
      path: path,
      kehaiHome: kehaiHome,
      limit: agentsMdLimit,
    );
    final problem = read.problem;
    if (problem != null) {
      problems.add(problem);
      continue;
    }
    final shown = displayPath(root, path);
    var text = read.text!;
    if (read.truncated) {
      text +=
          '[$shown truncated at ${agentsMdLimit ~/ 1024} KiB of '
          '${(read.size / 1024).round()} KiB; read the file for the rest]';
    }
    files.add(
      AgentsFile(
        path: shown,
        text: text,
        size: read.size,
        truncated: read.truncated,
      ),
    );
  }
  return AgentsMd(files: files, problems: problems);
}
