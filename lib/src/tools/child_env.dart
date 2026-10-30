/// The environment a spawned tool child gets (design D6, D7).
///
/// Every child process the tools start builds its environment here: ripgrep
/// through [childEnvironment], the shell through [shellEnvironment] and an
/// autoapproved command run without a shell through [directEnvironment].
library;

/// The prefixes of provider credential variable names, in upper case.
const List<String> credentialPrefixes = [
  'OPENAI_',
  'ANTHROPIC_',
  'AZURE_OPENAI_',
  'GEMINI_',
  'KEHAI_',
];

/// Name fragments that make a prefixed variable a credential, in upper case.
const List<String> credentialMarkers = ['KEY', 'TOKEN', 'SECRET'];

/// Variable names ripgrep must not read its configuration from, in upper case.
const Set<String> _noConfig = {'RIPGREP_CONFIG_PATH'};

/// Variables that make a shell run startup code, in upper case.
const Set<String> _startupVariables = {
  'BASH_ENV',
  'ENV',
  'SHELLOPTS',
  'BASHOPTS',
  ..._noConfig,
};

/// Prefix of the variables bash imports as functions, in upper case.
const String _functionPrefix = 'BASH_FUNC_';

/// Whether [name] is a provider credential variable.
///
/// It starts with one of [credentialPrefixes] and contains one of
/// [credentialMarkers]; the comparison ignores case, as Windows does.
bool isCredentialVariable(String name) {
  final upper = name.toUpperCase();
  return credentialPrefixes.any(upper.startsWith) &&
      credentialMarkers.any(upper.contains);
}

/// The credential variables of [base] that [passthrough] lets a child keep.
///
/// Names are compared ignoring case. The result holds [base]'s spelling, in
/// [base]'s order, for the call summary's `passing <name>` note.
List<String> passedThrough(
  Map<String, String> base,
  Iterable<String> passthrough,
) {
  final allowed = {for (final n in passthrough) n.toUpperCase()};
  return [
    for (final name in base.keys)
      if (isCredentialVariable(name) && allowed.contains(name.toUpperCase()))
        name,
  ];
}

Map<String, String> _filter(
  Map<String, String> base,
  Iterable<String> passthrough,
  bool Function(String upperName) drop,
) {
  final allowed = {for (final n in passthrough) n.toUpperCase()};
  return {
    for (final entry in base.entries)
      if (!drop(entry.key.toUpperCase()) &&
          (!isCredentialVariable(entry.key) ||
              allowed.contains(entry.key.toUpperCase())))
        entry.key: entry.value,
  };
}

/// [base] without the variables a tool child (ripgrep) must not inherit:
/// provider credentials and `RIPGREP_CONFIG_PATH`.
///
/// Names are compared ignoring case, as Windows does.
Map<String, String> childEnvironment(
  Map<String, String> base, {
  Iterable<String> passthrough = const [],
}) => _filter(base, passthrough, _noConfig.contains);

/// The environment of a shell or hook process: all of [base] except provider
/// credentials ([isCredentialVariable]), unless named in [passthrough].
Map<String, String> shellEnvironment(
  Map<String, String> base, {
  Iterable<String> passthrough = const [],
}) => _filter(base, passthrough, (_) => false);

/// The environment of a command run directly, with no shell: the
/// [shellEnvironment] without `BASH_ENV`, `ENV`, `BASH_FUNC_*`, `SHELLOPTS`,
/// `BASHOPTS` and `RIPGREP_CONFIG_PATH`, so no startup file or imported
/// function can run.
Map<String, String> directEnvironment(
  Map<String, String> base, {
  Iterable<String> passthrough = const [],
}) => _filter(
  base,
  passthrough,
  (upper) =>
      _startupVariables.contains(upper) || upper.startsWith(_functionPrefix),
);
