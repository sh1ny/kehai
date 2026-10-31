/// Text the line client prints for tool calls (spec *One line per tool
/// call*).
library;

/// The longest status line, in characters.
const int maxLineLength = 160;

/// The input fields that name what a call works on, most telling first.
const List<String> _argumentFields = ['command', 'path', 'pattern', 'id'];

/// [text] on one line: control characters (C0, DEL and C1) become spaces.
String oneLine(String text) => String.fromCharCodes([
  for (final unit in text.runes) _control(unit) ? 0x20 : unit,
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

/// Model [text] safe to print: line feeds and tabs are kept, and every other
/// control character (C0, DEL and C1, carriage return included) is written as
/// `\u{XXXX}`, so the model cannot move the cursor, hide text or change the
/// terminal's state.
String modelText(String text) => String.fromCharCodes([
  for (final unit in text.runes)
    if (unit != 0x0a && unit != 0x09 && _control(unit))
      ...'\\u{${unit.toRadixString(16).toUpperCase()}}'.codeUnits
    else
      unit,
]);

bool _control(int unit) => unit < 0x20 || (unit >= 0x7f && unit <= 0x9f);

/// [text] split at its line feeds, with every other character that a
/// terminal would not show as itself written as `\u{XXXX}`: C0 and C1
/// controls (carriage return and tab included), DEL, every Unicode
/// default-ignorable code point (format, direction, tag and variation
/// selector characters among them), spaces other than U+0020, and unpaired
/// surrogates. A backslash that starts `\u{` is written as `\u{5C}`, so each
/// escape in the result stands for exactly one character. Nothing is cut, so
/// a reader sees what runs.
List<String> exactLines(String text) => [
  for (final line in text.split('\n'))
    String.fromCharCodes([
      for (final (i, unit) in line.runes.indexed)
        if (_hidden(unit) || _startsEscape(line, i, unit))
          ...'\\u{${unit.toRadixString(16).toUpperCase()}}'.codeUnits
        else
          unit,
    ]),
];

/// Whether the backslash [unit] at rune [index] of [line] begins `\u{`.
bool _startsEscape(String line, int index, int unit) {
  if (unit != 0x5c) return false;
  final runes = line.runes.skip(index + 1).take(2).toList();
  return runes.length == 2 && runes[0] == 0x75 && runes[1] == 0x7b;
}

/// The ranges, inclusive, of the characters [exactLines] escapes besides
/// the controls: Unicode's Default_Ignorable_Code_Point, the spaces other
/// than U+0020, the line and paragraph separators, the interlinear
/// annotation characters and the surrogates.
const List<(int, int)> _hiddenRanges = [
  (0x00a0, 0x00a0),
  (0x00ad, 0x00ad),
  (0x034f, 0x034f),
  (0x061c, 0x061c),
  (0x115f, 0x1160),
  (0x1680, 0x1680),
  (0x17b4, 0x17b5),
  (0x180b, 0x180f),
  (0x2000, 0x200f),
  (0x2028, 0x202f),
  (0x205f, 0x206f),
  (0x3000, 0x3000),
  (0x3164, 0x3164),
  (0xd800, 0xdfff),
  (0xfe00, 0xfe0f),
  (0xfeff, 0xfeff),
  (0xffa0, 0xffa0),
  (0xfff0, 0xfffb),
  (0x1bca0, 0x1bca3),
  (0x1d173, 0x1d17a),
  (0xe0000, 0xe0fff),
];

bool _hidden(int unit) =>
    _control(unit) ||
    _hiddenRanges.any((range) => unit >= range.$1 && unit <= range.$2);

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
