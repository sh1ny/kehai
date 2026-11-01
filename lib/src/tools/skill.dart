/// The `skill` tool: loads an installed skill or command whole (design D6).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../results/composer.dart';
import '../workspace/inventory.dart';
import '../workspace/load.dart';
import 'tool.dart';

/// The most close names an unknown-name error lists.
const int maxSuggestions = 5;

/// Loads a skill or a command by name.
///
/// The name is resolved as a model-invocable skill, then as a command. The
/// file is read when the call runs, through [readContained], and delivered
/// whole: the outcome asks the runtime to compose it with no cut, within the
/// capacity [ToolContext.capacity] reports.
final class SkillTool implements Tool {
  /// Creates the tool.
  const SkillTool();

  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    final name = input['name']! as String;
    final args = switch (input['args']) {
      final String s => s,
      _ => '',
    };
    final home =
        context.kehaiHome ??
        Directory(p.join(Directory.systemTemp.path, 'kehai-no-home'));
    final view = loadWorkspace(
      workspace: context.workspace.path,
      kehaiHome: home,
    );

    final skill = view.skill(name);
    final command = view.command(name);
    final String path;
    final String kind;
    final String? baseDir;
    if (skill != null && !skill.disableModelInvocation) {
      path = skill.file;
      kind = 'skill';
      baseDir = skill.directory;
    } else if (command != null) {
      path = command.path;
      kind = 'command';
      baseDir = null;
    } else if (skill != null) {
      return _error('skill $name cannot be loaded by the model');
    } else {
      return _error(_unknown(name, view));
    }

    final LoadedText loaded;
    try {
      loaded = loadFile(
        root: view.root,
        path: path,
        kehaiHome: home,
        name: name,
        kind: kind,
        arguments: args,
        baseDir: baseDir,
      );
    } on LoadFailure catch (e) {
      return _error(e.message);
    }

    await context.output.writeText(loaded.text);
    return ToolOutcome(
      summary: 'loaded $kind $name',
      notrunc: true,
      capacityTokens: context.capacity?.call(),
    );
  }

  ToolOutcome _error(String message) =>
      ToolOutcome(status: ResultStatus.error, summary: message);
}

/// The error for an unknown [name], with up to [maxSuggestions] close names
/// of the skills the model may load and of the commands.
String _unknown(String name, Workspace view) {
  final names = <String>{
    for (final s in view.skills)
      if (!s.disableModelInvocation) s.name,
    for (final c in view.commands) c.name,
  }.toList();
  final ranked = {for (final n in names) n: _distance(name, n)};
  names.sort((a, b) {
    final byDistance = ranked[a]!.compareTo(ranked[b]!);
    return byDistance != 0 ? byDistance : a.compareTo(b);
  });
  final close = names.take(maxSuggestions);
  final base = 'unknown skill or command $name';
  return close.isEmpty ? base : '$base; closest: ${close.join(', ')}';
}

/// The Levenshtein distance between [a] and [b].
int _distance(String a, String b) {
  var previous = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final row = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (var j = 1; j <= b.length; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      row[j] = [
        previous[j] + 1,
        row[j - 1] + 1,
        previous[j - 1] + cost,
      ].reduce((x, y) => x < y ? x : y);
    }
    previous = row;
  }
  return previous[b.length];
}
