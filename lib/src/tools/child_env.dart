/// The environment a spawned tool child gets (design D6, D7).
///
/// Every child process the tools start builds its environment here, so the
/// shell tool's filtering (change group 8) extends this one function.
library;

/// Variable names no child inherits, in upper case.
const Set<String> _dropped = {'RIPGREP_CONFIG_PATH'};

/// [base] without the variables a child must not inherit.
///
/// Names are compared ignoring case, as Windows does.
Map<String, String> childEnvironment(Map<String, String> base) => {
  for (final entry in base.entries)
    if (!_dropped.contains(entry.key.toUpperCase())) entry.key: entry.value,
};
