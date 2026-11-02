/// The shared reasoning-effort input vocabulary.
library;

/// The exact effort values accepted by configuration and the command line.
///
/// `none` is an explicit selection, not the absent provider default.
const List<String> effortValues = [
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
];

/// Whether [value] is an exact supported effort string.
bool isValidEffort(Object? value) =>
    value is String && effortValues.contains(value);
