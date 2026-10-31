/// Text the line client prints for tool calls (spec *One line per tool
/// call*).
library;

/// The longest status line, in characters.
const int maxLineLength = 160;

/// The input fields that name what a call works on, most telling first.
const List<String> _argumentFields = ['command', 'path', 'pattern', 'id'];

/// [text] on one line: control characters become spaces.
String oneLine(String text) => String.fromCharCodes([
  for (final unit in text.runes) unit < 0x20 || unit == 0x7f ? 0x20 : unit,
]);

/// [text] cut to at most [max] characters, ending with `…` when it was cut.
String cutTo(String text, int max) {
  final runes = text.runes.toList();
  if (runes.length <= max) return text;
  return '${String.fromCharCodes(runes.take(max - 1))}…';
}

/// The path, pattern or command a call was given, as given, or null.
String? argumentText(Object? input) {
  if (input is! Map<String, Object?>) return null;
  for (final field in _argumentFields) {
    final value = input[field];
    if (value is String && value.isNotEmpty) return value;
  }
  return null;
}

/// The path, pattern or command a call was given, or an empty string.
String argumentSummary(Object? input) => oneLine(argumentText(input) ?? '');

/// [text] split at its line feeds, with every other character that a
/// terminal would not show as itself written as `\u{XXXX}`: C0 and C1
/// controls (carriage return and tab included), DEL, and invisible format
/// and direction characters. Nothing is cut, so a reader sees what runs.
List<String> exactLines(String text) => [
  for (final line in text.split('\n'))
    String.fromCharCodes([
      for (final unit in line.runes)
        if (_hidden(unit))
          ...'\\u{${unit.toRadixString(16).toUpperCase()}}'.codeUnits
        else
          unit,
    ]),
];

bool _hidden(int unit) =>
    unit < 0x20 ||
    (unit >= 0x7f && unit <= 0x9f) ||
    unit == 0xad ||
    unit == 0x061c ||
    (unit >= 0x200b && unit <= 0x200f) ||
    (unit >= 0x2028 && unit <= 0x202e) ||
    (unit >= 0x2060 && unit <= 0x2069) ||
    unit == 0xfeff;

/// `[<tool> <label>] <summary>: <argument>`, cut to [maxLineLength].
///
/// [label] is the envelope status, or the lifecycle status of a call that has
/// no envelope. Empty parts are left out.
String callLine({
  required String tool,
  required String label,
  String? summary,
  Object? input,
}) {
  final parts = [
    if (summary != null && summary.isNotEmpty) oneLine(summary),
    argumentSummary(input),
  ].where((part) => part.isNotEmpty).join(': ');
  final line =
      '[${oneLine(tool)} ${oneLine(label)}]'
      '${parts.isEmpty ? '' : ' $parts'}';
  return cutTo(line, maxLineLength);
}
