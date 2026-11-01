/// YAML frontmatter of skill, command and role files (design D2).
library;

import 'package:yaml/yaml.dart';

/// The parsed head of a Markdown file.
class Frontmatter {
  /// Creates a result; see [parseFrontmatter].
  const Frontmatter({
    required this.present,
    required this.data,
    required this.body,
    this.error,
  });

  /// Whether the text starts with a `---` line.
  final bool present;

  /// The top-level keys of the mapping; empty when absent or invalid.
  final Map<String, Object?> data;

  /// The text after the closing `---` line, or all of the text when the file
  /// has no frontmatter.
  final String body;

  /// Why the frontmatter is unusable, or null.
  final String? error;
}

/// Splits [text] into frontmatter and body.
///
/// Frontmatter is the text between a first line `---` and the next line
/// `---`; it must parse to a mapping. Other keys than the ones a caller reads
/// are kept in [Frontmatter.data] and simply not looked at.
Frontmatter parseFrontmatter(String text) {
  var source = text;
  if (source.startsWith('﻿')) source = source.substring(1);
  final lines = _lines(source);
  if (lines.isEmpty || lines.first.text.trimRight() != '---') {
    return Frontmatter(present: false, data: const {}, body: source);
  }
  var close = -1;
  for (var i = 1; i < lines.length; i++) {
    if (lines[i].text.trimRight() == '---') {
      close = i;
      break;
    }
  }
  if (close < 0) {
    return const Frontmatter(
      present: true,
      data: {},
      body: '',
      error: 'frontmatter is not closed (no closing ---)',
    );
  }
  final body = source.substring(lines[close].end);
  final yamlText = source.substring(lines[1].start, lines[close].start);
  Object? parsed;
  try {
    parsed = loadYaml(yamlText);
  } on YamlException catch (e) {
    final line = e.span == null ? '?' : '${e.span!.start.line + 2}';
    return Frontmatter(
      present: true,
      data: const {},
      body: body,
      error: 'invalid YAML frontmatter at line $line: ${e.message}',
    );
  }
  if (parsed == null) {
    return Frontmatter(present: true, data: const {}, body: body);
  }
  if (parsed is! YamlMap) {
    return Frontmatter(
      present: true,
      data: const {},
      body: body,
      error: 'frontmatter must be a mapping',
    );
  }
  return Frontmatter(
    present: true,
    data: {for (final e in parsed.entries) '${e.key}': e.value},
    body: body,
  );
}

class _Line {
  const _Line(this.text, this.start, this.end);
  final String text;
  final int start;
  final int end;
}

List<_Line> _lines(String s) {
  final out = <_Line>[];
  var start = 0;
  while (start < s.length) {
    final nl = s.indexOf('\n', start);
    final end = nl < 0 ? s.length : nl + 1;
    out.add(_Line(s.substring(start, nl < 0 ? s.length : nl), start, end));
    start = end;
  }
  return out;
}

/// Reads a boolean frontmatter value: a YAML bool or the text `true` or
/// `false`; [fallback] for anything else.
bool frontmatterBool(Map<String, Object?> data, String key, bool fallback) =>
    switch (data[key]) {
      final bool b => b,
      'true' => true,
      'false' => false,
      _ => fallback,
    };
