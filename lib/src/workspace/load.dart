/// Loading a skill or command file for the model and for `/` (design D6, D7).
library;

import 'dart:io';

import 'containment.dart';
import 'frontmatter.dart';
import 'skills.dart';
import 'substitution.dart';

/// A skill or command file loaded and substituted.
class LoadedText {
  /// Creates a loaded text.
  const LoadedText({required this.text, required this.source});

  /// The text the model receives: base directory line, body, arguments.
  final String text;

  /// The file relative to the project root, written with `/`.
  final String source;
}

/// Why a file could not be loaded: [message] says it in one line.
class LoadFailure implements Exception {
  /// Creates a failure.
  const LoadFailure(this.message);

  /// The one-line reason.
  final String message;

  @override
  String toString() => message;
}

/// Reads the file at [path] now and returns its body after the frontmatter,
/// with substitutions applied (see [renderLoaded]).
///
/// [kind] is `skill` or `command` and names the file in messages; a skill
/// passes its directory as [baseDir]. The read goes through [readContained]
/// and is bounded by [maxSkillFileBytes]. Throws a [LoadFailure] when the file
/// is refused, over the bound (the message names the size and says to read
/// the file instead) or has invalid frontmatter.
LoadedText loadFile({
  required String root,
  required String path,
  required Directory kehaiHome,
  required String name,
  required String kind,
  required String arguments,
  String? baseDir,
}) {
  final read = readContained(
    root: root,
    path: path,
    kehaiHome: kehaiHome,
    limit: maxSkillFileBytes,
  );
  final shown = displayPath(root, path);
  final problem = read.problem;
  if (problem != null) throw LoadFailure('cannot load $name: $problem');
  if (read.truncated) {
    throw LoadFailure(
      '$kind file is ${(read.size + 1023) ~/ 1024} KiB, over the '
      '${maxSkillFileBytes ~/ 1024} KiB limit; read $shown instead',
    );
  }
  final parsed = parseFrontmatter(read.text!);
  final broken = parsed.error;
  if (broken != null) throw LoadFailure('cannot load $name: $broken');
  return LoadedText(
    text: renderLoaded(parsed.body, baseDir: baseDir, arguments: arguments),
    source: shown,
  );
}
