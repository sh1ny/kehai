/// Path and argument substitution (skills spec).
library;

final RegExp _placeholder = RegExp(r'\$\{CLAUDE_SKILL_DIR\}|\$ARGUMENTS');

/// Replaces every `${CLAUDE_SKILL_DIR}` in [body] by [baseDir] written with
/// forward slashes and every `$ARGUMENTS` by [arguments].
///
/// Nothing else changes; shell variables stay as written. Replaced text is
/// not scanned again. Without a [baseDir], `${CLAUDE_SKILL_DIR}` stays.
String substitute(String body, {String? baseDir, required String arguments}) {
  final dir = baseDir?.replaceAll(r'\', '/');
  return body.replaceAllMapped(_placeholder, (m) {
    if (m[0] == r'$ARGUMENTS') return arguments;
    return dir ?? m[0]!;
  });
}

/// Composes what the `skill` tool and `/` expansion return.
///
/// A skill ([baseDir] set) starts with `Base directory for this skill: <dir>`
/// and a blank line. The body follows with substitutions applied, then
/// `ARGUMENTS: <arguments>` when arguments were given and the body has no
/// `$ARGUMENTS`.
String renderLoaded(String body, {String? baseDir, required String arguments}) {
  final out = StringBuffer();
  if (baseDir != null) {
    out
      ..write('Base directory for this skill: ')
      ..write(baseDir.replaceAll(r'\', '/'))
      ..write('\n\n');
  }
  out.write(substitute(body, baseDir: baseDir, arguments: arguments));
  if (arguments.isNotEmpty && !body.contains(r'$ARGUMENTS')) {
    out
      ..write(out.toString().endsWith('\n') ? '\n' : '\n\n')
      ..write('ARGUMENTS: ')
      ..write(arguments);
  }
  return out.toString();
}
