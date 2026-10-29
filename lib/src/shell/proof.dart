/// The whole-command read-only proof (design D13).
///
/// A command is proven only when it is one simple command of a listed program
/// with listed options and every path operand inside the workspace. Anything
/// the small tokenizer or the option tables do not understand is not proven,
/// and an unproven command asks the user.
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../permissions/workspace_paths.dart';

/// A command proven read-only.
final class ProvenCommand {
  /// Creates the proof result.
  const ProvenCommand({required this.argv, required this.cwd});

  /// The tokenized argv: the program and its arguments, quotes removed.
  ///
  /// Running exactly this argv in [cwd] with no shell does what the proof
  /// checked.
  final List<String> argv;

  /// The effective working directory as a real path inside the workspace.
  final String cwd;

  /// The program name.
  String get program => argv.first;
}

/// Characters that are never allowed outside single quotes: command
/// separators, redirection, grouping, expansion, comments and escapes.
const String _forbidden = ';&|<>()\$`\n\r~#\\';

/// Glob characters; they are not allowed anywhere in a command.
const String _glob = '*?[]{}';

/// The argv of [command] when it is one simple command, else null.
///
/// This is the shape check of the proof without the program tables: words
/// separated by spaces or tabs, with single quotes (anything inside is
/// literal) and double quotes (no `$`, backquote or backslash inside). A
/// forbidden character outside single quotes, a glob character anywhere, an
/// unterminated quote, an empty command or a leading `NAME=value` assignment
/// gives null.
List<String>? tokenizeSimple(String command) {
  final words = <String>[];
  final word = StringBuffer();
  var inWord = false;
  var i = 0;
  while (i < command.length) {
    final c = command[i];
    if (_glob.contains(c)) return null;
    if (c == "'") {
      final end = command.indexOf("'", i + 1);
      if (end < 0) return null;
      final quoted = command.substring(i + 1, end);
      if (quoted.split('').any(_glob.contains)) return null;
      word.write(quoted);
      inWord = true;
      i = end + 1;
    } else if (c == '"') {
      final end = command.indexOf('"', i + 1);
      if (end < 0) return null;
      final quoted = command.substring(i + 1, end);
      if (quoted.split('').any((ch) => r'$`\'.contains(ch))) return null;
      word.write(quoted);
      inWord = true;
      i = end + 1;
    } else if (c == ' ' || c == '\t') {
      if (inWord) words.add(word.toString());
      word.clear();
      inWord = false;
      i++;
    } else if (_forbidden.contains(c)) {
      return null;
    } else {
      word.write(c);
      inWord = true;
      i++;
    }
  }
  if (inWord) words.add(word.toString());
  if (words.isEmpty || _assignment.hasMatch(words.first)) return null;
  return words;
}

final RegExp _assignment = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=');

/// Proves [command] read-only, or returns null when it is not proven.
///
/// [workspaceRoot] is the workspace directory and [cwd] the call's working
/// directory relative to it (default: the root). The working directory must
/// exist and be inside the workspace, and so must every path operand once
/// resolved from it, symbolic links followed.
ProvenCommand? proveReadOnly(
  String command, {
  required String workspaceRoot,
  String? cwd,
}) {
  final argv = tokenizeSimple(command);
  if (argv == null) return null;
  final program = _programs[argv.first];
  if (program == null) return null;
  final root = realPath(workspaceRoot);
  if (root == null) return null;
  final base = realPath(p.join(root, cwd ?? '.'));
  if (base == null || !isInside(root, base) || !Directory(base).existsSync()) {
    return null;
  }
  final paths = program.paths(argv.sublist(1));
  if (paths == null) return null;
  for (final operand in paths) {
    final real = realPath(p.join(base, operand));
    if (real == null || !isInside(root, real)) return null;
  }
  return ProvenCommand(argv: argv, cwd: base);
}

enum _Kind { flag, value, path }

/// One program of the proof: its options and what its operands are.
final class _Program {
  const _Program({
    this.shorts = const {},
    this.longs = const {},
    this.minOperands = 0,
    this.maxOperands,
    this.patternFirst = false,
  });

  /// Short options by letter.
  final Map<String, _Kind> shorts;

  /// Long options by name without the dashes.
  final Map<String, _Kind> longs;

  /// How many operands are needed.
  final int minOperands;

  /// The most operands allowed, or null for any number.
  final int? maxOperands;

  /// Whether the first operand is a search pattern, not a path, unless `-e`,
  /// `-f` or `--files` replaces it.
  final bool patternFirst;

  /// The path operands of [args], or null when [args] are not proven.
  List<String>? paths(List<String> args) {
    final paths = <String>[];
    final operands = <String>[];
    var patternGiven = false;
    var listsFiles = false;
    for (var i = 0; i < args.length; i++) {
      final arg = args[i];
      if (arg == '-' || arg == '--') return null;
      if (!arg.startsWith('-')) {
        operands.add(arg);
        continue;
      }
      // One option, with its value when it takes one.
      String? option;
      String? attached;
      if (arg.startsWith('--')) {
        final eq = arg.indexOf('=');
        option = eq < 0 ? arg.substring(2) : arg.substring(2, eq);
        attached = eq < 0 ? null : arg.substring(eq + 1);
        final kind = longs[option];
        if (kind == null) return null;
        if (kind == _Kind.flag) {
          if (attached != null) return null;
          listsFiles |= option == 'files';
          continue;
        }
        final value = attached ?? (i + 1 < args.length ? args[++i] : null);
        if (value == null) return null;
        if (kind == _Kind.path) paths.add(value);
        patternGiven |= option == 'file';
        continue;
      }
      for (var j = 1; j < arg.length; j++) {
        final letter = arg[j];
        final kind = shorts[letter];
        if (kind == null) return null;
        if (kind == _Kind.flag) continue;
        var value = arg.substring(j + 1);
        if (value.isEmpty) {
          if (i + 1 >= args.length) return null;
          value = args[++i];
        }
        if (kind == _Kind.path) paths.add(value);
        patternGiven |= letter == 'e' || letter == 'f';
        break;
      }
    }
    var rest = operands;
    if (patternFirst && !patternGiven && !listsFiles) {
      if (operands.isEmpty) return null;
      rest = operands.sublist(1);
    }
    if (rest.length < minOperands ||
        (maxOperands != null && rest.length > maxOperands!)) {
      return null;
    }
    return [...paths, ...rest];
  }
}

const Map<String, _Program> _programs = {
  'pwd': _Program(maxOperands: 0),
  'ls': _Program(
    shorts: {
      'a': _Kind.flag,
      'l': _Kind.flag,
      '1': _Kind.flag,
      'h': _Kind.flag,
      'R': _Kind.flag,
      't': _Kind.flag,
      'r': _Kind.flag,
      'S': _Kind.flag,
    },
  ),
  'cat': _Program(shorts: {'n': _Kind.flag, 'A': _Kind.flag}, minOperands: 1),
  'head': _Program(
    shorts: {'n': _Kind.value, 'c': _Kind.value},
    minOperands: 1,
  ),
  'tail': _Program(
    shorts: {'n': _Kind.value, 'c': _Kind.value},
    minOperands: 1,
  ),
  'wc': _Program(
    shorts: {
      'l': _Kind.flag,
      'w': _Kind.flag,
      'c': _Kind.flag,
      'm': _Kind.flag,
    },
    minOperands: 1,
  ),
  'rg': _Program(
    shorts: {
      'n': _Kind.flag,
      'i': _Kind.flag,
      'S': _Kind.flag,
      'F': _Kind.flag,
      'w': _Kind.flag,
      'l': _Kind.flag,
      'c': _Kind.flag,
      'v': _Kind.flag,
      'e': _Kind.value,
      'g': _Kind.value,
      't': _Kind.value,
      'A': _Kind.value,
      'B': _Kind.value,
      'C': _Kind.value,
      'm': _Kind.value,
      'f': _Kind.path,
    },
    longs: {
      'hidden': _Kind.flag,
      'no-ignore': _Kind.flag,
      'files': _Kind.flag,
      'glob': _Kind.value,
      'type': _Kind.value,
      'file': _Kind.path,
    },
    patternFirst: true,
  ),
};
