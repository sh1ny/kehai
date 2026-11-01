/// The context text appended to the built-in instructions (design D5).
library;

import 'agents_md.dart';
import 'skills.dart';

/// Skills listed with their descriptions; the rest are listed by name.
const int catalogDescribedSkills = 64;

final RegExp _whitespace = RegExp(r'\s+');

/// Renders the captured `AGENTS.md` files and the skill catalog.
///
/// The text is `# Project instructions` with one `## <path>` section per file
/// (root first), then `# Skills` with one `- <name>: <description>` line per
/// skill that the model may invoke, sorted by name. Only the first
/// [catalogDescribedSkills] carry a description; the others follow by name
/// under a line saying their descriptions were left out. A part with nothing
/// to say is omitted, so a workspace with no files and no skills gives the
/// empty string.
String renderContextText({
  required List<AgentsFile> files,
  required List<Skill> skills,
}) {
  final out = StringBuffer();
  if (files.isNotEmpty) {
    out.write('# Project instructions\n\n');
    for (final file in files) {
      out
        ..write('## ')
        ..write(file.path)
        ..write('\n\n')
        ..write(file.text.trimRight())
        ..write('\n\n');
    }
  }
  final listed = [
    for (final s in skills)
      if (!s.disableModelInvocation) s,
  ]..sort((a, b) => a.name.compareTo(b.name));
  if (listed.isNotEmpty) {
    out.write('# Skills\n\n');
    for (final s in listed.take(catalogDescribedSkills)) {
      out
        ..write('- ')
        ..write(s.name)
        ..write(': ')
        ..write(s.description.replaceAll(_whitespace, ' ').trim())
        ..write('\n');
    }
    final rest = listed.skip(catalogDescribedSkills).toList();
    if (rest.isNotEmpty) {
      out
        ..write('\nThe descriptions of these ${rest.length} skills were left ')
        ..write('out; load one with the skill tool to read it:\n');
      for (final s in rest) {
        out
          ..write('- ')
          ..write(s.name)
          ..write('\n');
      }
    }
  }
  return out.toString();
}
