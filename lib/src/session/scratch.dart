/// The bounded, verbatim representation and presentation of session scratch.
library;

/// The maximum number of scratch entries.
const int maxScratchKeys = 20;

/// The maximum conservative token count of one stored value.
const int maxScratchValueTokens = 80;

/// The maximum conservative token count of the complete rendered section.
const int maxScratchSectionTokens = 400;

final RegExp _boundaries = RegExp(r'\r\n|[\n\r\x0b\x0c\u0085\u2028\u2029]');

/// Whether [key] is one journal segment of 1–128 ASCII characters.
bool validScratchKey(String key) {
  if (key.isEmpty || key.length > 128) return false;
  for (final unit in key.codeUnits) {
    if ((unit >= 65 && unit <= 90) ||
        (unit >= 97 && unit <= 122) ||
        (unit >= 48 && unit <= 57) ||
        unit == 95 ||
        unit == 46 ||
        unit == 58 ||
        unit == 45) {
      continue;
    }
    return false;
  }
  return true;
}

/// Counts ceil(UTF-8 bytes / 3) without allocating an encoded copy of [text].
int scratchTokens(String text) {
  var bytes = 0;
  for (final rune in text.runes) {
    bytes += rune <= 0x7f
        ? 1
        : rune <= 0x7ff
        ? 2
        : rune <= 0xffff
        ? 3
        : 4;
  }
  return (bytes + 2) ~/ 3;
}

/// An unsupported stored scratch subtree, with a bounded value-free diagnostic.
final class ScratchStateError implements Exception {
  /// Creates an error from an implementation-owned diagnostic.
  const ScratchStateError(this.message);

  /// The safe diagnostic, never containing stored value text.
  final String message;

  @override
  String toString() => 'scratch-state error: $message';
}

/// A validated scratch snapshot with one shared admission/rendering format.
final class ScratchState {
  ScratchState._(Map<String, String> values)
    : values = Map.unmodifiable(values);

  /// Reads the journal shape, refusing malformed or over-limit nonempty state.
  factory ScratchState.read(Object? node) {
    if (node == null) return ScratchState._({});
    if (node is! Map<String, Object?>) {
      throw const ScratchStateError('scratch must be an object');
    }
    if (node.length > maxScratchKeys) {
      throw const ScratchStateError('scratch exceeds the 20-key limit');
    }
    final values = <String, String>{};
    for (final entry in node.entries) {
      final key = entry.key;
      if (!validScratchKey(key)) {
        throw const ScratchStateError('scratch contains an invalid entry key');
      }
      final child = entry.value;
      if (child is! Map<String, Object?> ||
          child.length != 1 ||
          child['value'] is! String) {
        throw ScratchStateError('entry $key must contain only a text value');
      }
      final value = child['value']! as String;
      // UTF-8 has at least as many bytes as UTF-16 units. Reject oversized
      // stored input before scanning or rendering it.
      if (value.length > maxScratchValueTokens * 3 ||
          scratchTokens(value) > maxScratchValueTokens) {
        throw ScratchStateError('entry $key exceeds the 80-token value limit');
      }
      values[key] = value;
    }
    final state = ScratchState._(values);
    if (state.tokens > maxScratchSectionTokens) {
      throw const ScratchStateError(
        'scratch exceeds the 400-token section limit',
      );
    }
    return state;
  }

  /// The validated, unchanged plain-text values by key.
  final Map<String, String> values;

  /// The complete section, sorted lexically and including every prefix.
  String get text => renderScratch(values);

  /// The conservative size of [text].
  int get tokens => scratchTokens(text);
}

/// Renders bounded validated values with reversible presentation indentation.
///
/// Callers validate key count, key grammar and per-value size before rendering.
/// All original delimiters survive, including a final empty presentation line.
String renderScratch(Map<String, String> values) {
  if (values.isEmpty) return 'scratch: none';
  final keys = values.keys.toList()..sort();
  return 'scratch:\n${keys.map((key) {
    final value = values[key]!.replaceAllMapped(_boundaries, (match) => '${match[0]}    ');
    return '  $key:\n    $value';
  }).join('\n')}';
}
