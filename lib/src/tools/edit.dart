/// The `edit` tool: anchored edits applied bottom-up by original line number
/// and written atomically (design D4, D5).
///
/// Everything is validated before a byte is written: operation shapes and
/// bounds, overlaps, anchor syntax, coverage of every touched block, and a
/// fresh hash of every named block. Nothing is remapped or guessed. Untouched
/// lines are copied byte for byte with their own line endings.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:path/path.dart' as p;

import '../permissions/workspace_paths.dart';
import 'atomic_write.dart';
import 'block_hash.dart';
import 'file_access.dart';
import 'tool.dart';

/// The largest file `edit` works on; it holds the whole file in memory.
const int maxEditBytes = 16 * 1024 * 1024;

const int _lf = 0x0a;
const int _cr = 0x0d;

final RegExp _anchorPattern = RegExp(r'^(\d+)#([0-9A-Fa-f]{4})$');
final RegExp _lineBreak = RegExp(r'\r\n|\r|\n');

/// Edits a text file by line numbers and block anchors.
final class EditTool implements Tool {
  /// Creates the tool.
  const EditTool({this.seams = const FileWriteSeams()});

  /// The test seams.
  final FileWriteSeams seams;

  @override
  Future<ToolOutcome> run(ToolContext context, Map<String, Object?> input) {
    final path = input['path']! as String;
    final absolute = absolutePath(context.workspace, path);
    final denied = credentialDenial(context, absolute);
    if (denied != null) return Future.value(denied);
    // Edit the file a link points at instead of replacing the link.
    final target = realPath(absolute) ?? absolute;
    return PathLocks.run(target, () => _edit(context, path, target, input));
  }

  Future<ToolOutcome> _edit(
    ToolContext context,
    String path,
    String target,
    Map<String, Object?> input,
  ) async {
    if (context.cancel.isCancelled) return cancelledMutation;
    final file = File(target);
    switch (FileSystemEntity.typeSync(target)) {
      case FileSystemEntityType.notFound:
        return failure('no such file $path');
      case FileSystemEntityType.directory:
        return failure('$path is a directory');
      default:
    }
    final stat = await file.stat();
    if (stat.size > maxEditBytes) {
      return failure(
        'file too large to edit (${mebibytes(stat.size)}, limit '
        '${maxEditBytes ~/ (1024 * 1024)} MiB)',
      );
    }
    final bytes = await file.readAsBytes();
    try {
      const Utf8Decoder().convert(bytes);
    } on FormatException {
      return failure('$path is not valid UTF-8; edit refused');
    }

    final lines = _Lines(bytes);
    final (plan, problems) = _plan(lines, input);
    if (plan == null) return _reject(context.output, problems);

    final output = plan.apply(lines);
    if (_sameBytes(output, bytes)) return failure('edit made no change');

    try {
      await writeAtomically(
        target,
        output,
        unchangedSince: stat,
        seams: seams,
        isCancelled: () => context.cancel.isCancelled,
      );
    } on WriteFailure catch (e) {
      return failure(e.message);
    }

    final result = _Lines(output);
    final hashes = blockHashes([output]);
    final shown = plan.touchedBlocks(result.count);
    await context.output.writeText(_render(result, hashes, shown));
    final later = <String>[
      if (result.count != lines.count)
        for (
          var b = shown.isEmpty ? 0 : shown.first + 1;
          b < hashes.length;
          b++
        )
          if (!shown.contains(b)) '${b * blockLines + 1}#${hashes[b]}',
    ];
    if (later.isNotEmpty) {
      await context.output.writeText('later anchors: ${later.join(' ')}\n');
    }

    final orphans = _orphans(target);
    final ops = plan.ops.length;
    return ToolOutcome(
      summary:
          'edited $path: $ops ${ops == 1 ? 'operation' : 'operations'}, '
          '${lines.count} → ${result.count} lines'
          '${orphans.isEmpty ? '' : '; interrupted edits left ${orphans.join(', ')}'}',
    );
  }

  Future<ToolOutcome> _reject(ToolOutput output, List<String> problems) async {
    await output.writeText('${problems.join('\n')}\n');
    return failure(
      problems.length == 1 ? problems.single : '${problems.length} problems',
    );
  }
}

List<String> _orphans(String target) {
  final prefix = temporaryPrefix(target);
  try {
    return [
      for (final entry in Directory(p.dirname(target)).listSync())
        if (p.basename(entry.path).startsWith(prefix)) p.basename(entry.path),
    ]..sort();
  } on FileSystemException {
    return const [];
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

String _render(_Lines lines, List<String> hashes, List<int> blocks) {
  final out = StringBuffer();
  for (final block in blocks) {
    final first = block * blockLines + 1;
    final last = math.min(first + blockLines - 1, lines.count);
    for (var n = first; n <= last; n++) {
      out.write(n == first ? '$n#${hashes[block]}:' : '$n:');
      out
        ..write(utf8.decode(lines.content(n), allowMalformed: true))
        ..write('\n');
    }
  }
  return out.toString();
}

/// The lines of a file as byte ranges, each with its own terminator.
final class _Lines {
  _Lines(this.bytes) {
    var at =
        bytes.length >= 3 &&
            bytes[0] == 0xEF &&
            bytes[1] == 0xBB &&
            bytes[2] == 0xBF
        ? 3
        : 0;
    bom = at;
    while (at < bytes.length) {
      final begin = at;
      while (at < bytes.length && bytes[at] != _lf && bytes[at] != _cr) {
        at++;
      }
      _begin.add(begin);
      _end.add(at);
      if (at < bytes.length) {
        at += bytes[at] == _cr && at + 1 < bytes.length && bytes[at + 1] == _lf
            ? 2
            : 1;
      }
      _next.add(at);
    }
  }

  final Uint8List bytes;
  late final int bom;
  final List<int> _begin = [];
  final List<int> _end = [];
  final List<int> _next = [];

  int get count => _begin.length;

  /// The content of line [n] (1-based), without its terminator.
  Uint8List content(int n) =>
      Uint8List.sublistView(bytes, _begin[n - 1], _end[n - 1]);

  /// The terminator of line [n]; empty for an unterminated last line.
  Uint8List terminator(int n) =>
      Uint8List.sublistView(bytes, _end[n - 1], _next[n - 1]);

  /// The bytes of lines `from..to` (1-based, inclusive) with terminators.
  Uint8List range(int from, int to) =>
      Uint8List.sublistView(bytes, _begin[from - 1], _next[to - 1]);

  /// The first line terminator of the file, or LF.
  Uint8List get firstTerminator {
    for (var n = 1; n <= count; n++) {
      final t = terminator(n);
      if (t.isNotEmpty) return t;
    }
    return Uint8List.fromList(const [_lf]);
  }
}

enum _Kind { replace, insert, delete }

final class _Op {
  _Op(this.kind, this.start, this.end, this.text);

  final _Kind kind;

  /// First line of a replace or delete; the line after which an insert goes.
  final int start;

  /// Last line of a replace or delete.
  final int end;

  /// The new lines, each already UTF-8 encoded.
  final List<Uint8List> text;

  /// The boundary this operation acts at: lines before it are untouched.
  int get boundary => kind == _Kind.insert ? start : start - 1;
}

/// A validated list of operations.
final class _Plan {
  _Plan(List<_Op> ops)
    : ops = [...ops]
        ..sort((a, b) {
          final c = a.boundary.compareTo(b.boundary);
          if (c != 0) return c;
          return (a.kind == _Kind.insert ? 0 : 1).compareTo(
            b.kind == _Kind.insert ? 0 : 1,
          );
        });

  /// The operations, ordered by position in the original file.
  final List<_Op> ops;

  Uint8List apply(_Lines file) {
    final out = BytesBuilder(copy: false)
      ..add(Uint8List.sublistView(file.bytes, 0, file.bom));
    final n = file.count;
    final first = file.firstTerminator;
    var done = 0; // original lines 1..done are in the output
    void copyUpTo(int line) {
      if (line > done) out.add(file.range(done + 1, line));
      done = math.max(done, line);
    }

    for (final op in ops) {
      copyUpTo(op.boundary);
      switch (op.kind) {
        case _Kind.delete:
          done = op.end;
        case _Kind.replace:
          for (final (j, text) in op.text.indexed) {
            out.add(text);
            final last = j == op.text.length - 1;
            if (last && op.end == n) {
              out.add(file.terminator(n));
              continue;
            }
            final source = op.start + j <= op.end ? op.start + j : op.end;
            final terminator = file.terminator(source);
            out.add(terminator.isEmpty ? first : terminator);
          }
          done = op.end;
        case _Kind.insert:
          final after = op.start;
          final follows = after == 0 ? first : file.terminator(after);
          final unterminatedTail = after > 0 && after == n && follows.isEmpty;
          if (unterminatedTail) out.add(first);
          for (final (j, text) in op.text.indexed) {
            out.add(text);
            final last = j == op.text.length - 1;
            if (last && unterminatedTail) continue;
            out.add(follows.isEmpty ? first : follows);
          }
      }
    }
    copyUpTo(n);
    return out.toBytes();
  }

  /// The blocks of the new file, from 0, that hold a changed line.
  List<int> touchedBlocks(int newCount) {
    final blocks = <int>{};
    var shift = 0;
    void touch(int line) {
      if (newCount > 0) {
        blocks.add((math.min(math.max(line, 1), newCount) - 1) ~/ blockLines);
      }
    }

    for (final op in ops) {
      switch (op.kind) {
        case _Kind.delete:
          touch(op.start + shift);
          shift -= op.end - op.start + 1;
        case _Kind.replace:
          for (var j = 0; j < op.text.length; j++) {
            touch(op.start + shift + j);
          }
          shift += op.text.length - (op.end - op.start + 1);
        case _Kind.insert:
          for (var j = 0; j < op.text.length; j++) {
            touch(op.start + shift + 1 + j);
          }
          shift += op.text.length;
      }
    }
    return blocks.toList()..sort();
  }
}

/// Validates the call against [file]; returns the plan, or null and the
/// problems that rule it out.
(_Plan?, List<String>) _plan(_Lines file, Map<String, Object?> input) {
  final n = file.count;
  final ops = <_Op>[];
  final problems = <String>[];
  final raw = (input['ops']! as List).cast<Map<String, Object?>>();
  for (final (i, op) in raw.indexed) {
    final label = 'op ${i + 1}';
    final kind = switch (op['op']) {
      'replace' => _Kind.replace,
      'insert' => _Kind.insert,
      'delete' => _Kind.delete,
      _ => null,
    };
    final start = op[kind == _Kind.insert ? 'after' : 'start'] as int?;
    final end = kind == _Kind.insert ? start : op['end'] as int?;
    final text = op['text'] as String?;
    if (kind == null || start == null || end == null) {
      problems.add(
        kind == _Kind.insert
            ? '$label: insert needs after and text'
            : '$label: ${op['op']} needs start and end',
      );
    } else if (kind != _Kind.delete && text == null) {
      problems.add('$label: ${kind.name} needs text');
    } else if (end < start) {
      problems.add('$label: end $end is before start $start');
    } else {
      ops.add(
        _Op(kind, start, end, [
          if (text != null)
            for (final line in text.split(_lineBreak))
              Uint8List.fromList(utf8.encode(line)),
        ]),
      );
    }
  }
  if (problems.isNotEmpty) return (null, problems);

  for (final op in ops) {
    final lowest = op.kind == _Kind.insert ? 0 : 1;
    for (final line in [op.start, op.end]) {
      if (line < lowest || line > n) {
        return (null, ['line $line does not exist (file has $n lines)']);
      }
    }
  }

  final overlap = _overlap(ops);
  if (overlap != null) return (null, [overlap]);

  final named = <int, String>{};
  for (final anchor in (input['anchors']! as List).cast<String>()) {
    final match = _anchorPattern.firstMatch(anchor);
    final line = match == null ? 0 : int.parse(match.group(1)!);
    if (match == null || line < 1 || (line - 1) % blockLines != 0) {
      problems.add(
        '$anchor is not a block anchor; blocks start at 1, 17, 33, …',
      );
    } else {
      named[line] = match.group(2)!.toUpperCase();
    }
  }
  if (problems.isNotEmpty) return (null, problems);

  final touched = <int>{};
  for (final op in ops) {
    final from = op.kind == _Kind.insert ? math.max(op.start, 1) : op.start;
    final to = op.kind == _Kind.insert ? from : op.end;
    if (n == 0) continue;
    for (var b = (from - 1) ~/ blockLines; b <= (to - 1) ~/ blockLines; b++) {
      touched.add(b * blockLines + 1);
    }
  }
  for (final line in touched.toList()..sort()) {
    if (!named.containsKey(line)) {
      problems.add(
        'no anchor for block $line '
        '(lines $line–${math.min(line + blockLines - 1, n)})',
      );
    }
  }
  if (problems.isNotEmpty) return (null, problems);

  final current = blockHashes([file.bytes]);
  for (final MapEntry(key: line, value: hash) in named.entries) {
    final label = '$line#$hash';
    final block = (line - 1) ~/ blockLines;
    if (block >= current.length) {
      problems.add(
        'stale anchor $label: the file has $n lines now; read the file again',
      );
    } else if (current[block] != hash) {
      problems.add(
        'stale anchor $label: lines $line–'
        '${math.min(line + blockLines - 1, n)} now hash ${current[block]}; '
        'read the file again',
      );
    }
  }
  return problems.isEmpty ? (_Plan(ops), const []) : (null, problems);
}

String? _overlap(List<_Op> ops) {
  final ranges = [
    for (final op in ops)
      if (op.kind != _Kind.insert) op,
  ]..sort((a, b) => a.start.compareTo(b.start));
  for (var i = 1; i < ranges.length; i++) {
    final previous = ranges[i - 1];
    final next = ranges[i];
    if (next.start <= previous.end) {
      return _overlapAt(next.start, math.min(previous.end, next.end));
    }
  }
  final inserts = <int>{};
  for (final op in ops) {
    if (op.kind != _Kind.insert) continue;
    if (!inserts.add(op.start)) {
      return 'operations overlap after line ${op.start}';
    }
    for (final range in ranges) {
      if (range.start <= op.start && op.start < range.end) {
        return _overlapAt(op.start, op.start + 1);
      }
    }
  }
  return null;
}

String _overlapAt(int from, int to) => from == to
    ? 'operations overlap at line $from'
    : 'operations overlap at lines $from–$to';
