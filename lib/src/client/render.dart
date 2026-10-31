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

/// [text] split at its line feeds, with every other control character (C0,
/// tab and carriage return included, DEL and C1) and every lone surrogate
/// written as `\u{XXXX}`, so the text cannot drive the terminal. Every other
/// character is shown as itself. A backslash that starts `\u{` is written as
/// `\u{5C}`, so each escape in the result stands for exactly one character.
/// Nothing is cut, so a reader sees what runs.
List<String> exactLines(String text) => [
  for (final line in text.split('\n')) _exactLine(line.runes.toList()),
];

String _exactLine(List<int> runes) => String.fromCharCodes([
  for (var i = 0; i < runes.length; i++)
    if (_hidden(runes[i]) || _startsEscape(runes, i))
      ...'\\u{${runes[i].toRadixString(16).toUpperCase()}}'.codeUnits
    else
      runes[i],
]);

/// Whether the rune at [index] of [runes] is a backslash that begins `\u{`.
bool _startsEscape(List<int> runes, int index) =>
    runes[index] == 0x5c &&
    index + 2 < runes.length &&
    runes[index + 1] == 0x75 &&
    runes[index + 2] == 0x7b;

bool _hidden(int unit) => _control(unit) || (unit >= 0xd800 && unit <= 0xdfff);

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

/// One line of a permission prompt's body (spec *Permission prompt body*):
/// a lead such as `  content: 2 lines, 22 bytes`, or a line of text marked
/// `|` (written content), `-` (a line an edit removes) or `+` (edit text).
///
/// A text line keeps its place in the source and is escaped only when
/// rendered, so lines that are counted but not shown cost no escaping.
final class BodyLine {
  /// A line shown as [lead], already safe to print.
  const BodyLine.lead(String lead)
    : _lead = lead,
      _source = '',
      _start = -1,
      _end = -1,
      _mark = '';

  /// The text of [source] from [start] to [end], holding no line break,
  /// after `  ` and the mark.
  const BodyLine.text(String source, int start, int end, [this._mark = '|'])
    : _lead = '',
      _source = source,
      _start = start,
      _end = end;

  final String _lead;
  final String _source;
  final int _start;
  final int _end;
  final String _mark;

  /// The line as printed.
  String render() => _start < 0
      ? _lead
      : '  $_mark '
            '${_exactLine(_source.substring(_start, _end).runes.toList())}';
}

/// The body of a `write` or `edit` permission prompt: what the call writes,
/// in lines produced on demand. Other tools have none.
Iterable<BodyLine> promptBody(String tool, Map<String, Object?> input) =>
    switch (tool) {
      'write' => _writeBody(input['content']),
      'edit' => _editBody(input['ops'], input['old']),
      _ => const [],
    };

/// The content line, then the content split at line feeds; a final line feed
/// ends the last line (design D3).
Iterable<BodyLine> _writeBody(Object? content) sync* {
  if (content is! String) return;
  var lines = 0;
  for (
    var i = content.indexOf('\n');
    i >= 0;
    i = content.indexOf('\n', i + 1)
  ) {
    lines++;
  }
  if (content.isNotEmpty && !content.endsWith('\n')) lines++;
  yield BodyLine.lead(
    '  content: $lines ${lines == 1 ? 'line' : 'lines'}, '
    '${_utf8Length(content)} bytes',
  );
  var start = 0;
  while (start < content.length) {
    final end = content.indexOf('\n', start);
    if (end < 0) {
      yield BodyLine.text(content, start, content.length);
      return;
    }
    yield BodyLine.text(content, start, end);
    start = end + 1;
  }
}

/// Each operation as given, then the lines it removes from [old], then its
/// text split as `edit` splits it: at CRLF, CR and LF, keeping empty pieces.
Iterable<BodyLine> _editBody(Object? ops, Object? old) sync* {
  if (ops is! List<Object?>) return;
  for (final (index, op) in ops.indexed) {
    if (op is! Map<String, Object?>) {
      yield const BodyLine.lead('  ? operation');
      continue;
    }
    String number(String field) {
      final value = op[field];
      return value is int ? '$value' : '?';
    }

    switch (op['op']) {
      case 'replace':
        yield BodyLine.lead(
          '  replace lines ${number('start')}-${number('end')}:',
        );
      case 'insert':
        yield BodyLine.lead('  insert after line ${number('after')}:');
      case 'delete':
        yield BodyLine.lead(
          '  delete lines ${number('start')}-${number('end')}',
        );
      default:
        yield const BodyLine.lead('  ? operation');
        continue;
    }
    // Old lines come from the engine, which read the file (no line breaks).
    if (old is List<Object?> && index < old.length) {
      if (old[index] case final List<Object?> lines
          when lines.every((line) => line is String)) {
        for (final line in lines.cast<String>()) {
          yield BodyLine.text(line, 0, line.length, '-');
        }
      }
    }
    final text = op['text'];
    if (op['op'] != 'delete' && text is String) yield* _editLines(text);
  }
}

Iterable<BodyLine> _editLines(String text) sync* {
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit != 0x0a && unit != 0x0d) continue;
    yield BodyLine.text(text, start, i, '+');
    if (unit == 0x0d && i + 1 < text.length && text.codeUnitAt(i + 1) == 0x0a) {
      i++;
    }
    start = i + 1;
  }
  yield BodyLine.text(text, start, text.length, '+');
}

/// The length of [text] in UTF-8, a lone surrogate counting as the three
/// bytes of the replacement character it is written as.
int _utf8Length(String text) {
  var bytes = 0;
  for (final rune in text.runes) {
    bytes += rune < 0x80
        ? 1
        : rune < 0x800
        ? 2
        : rune < 0x10000
        ? 3
        : 4;
  }
  return bytes;
}
