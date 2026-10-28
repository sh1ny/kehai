/// Paging over a stored result.
library;

import 'dart:io';

import 'composer.dart';
import 'descriptor.dart';

/// The most lines one [readMore] call returns, the same as a `read`.
const maxPageLines = 400;

/// Returns up to [lines] lines of the stored [file], starting at line [from].
///
/// The page is composed like a `read` result: it is capped at [maxPageLines]
/// lines and the per-line cap, and it ends with a paging line offering
/// the next `from` when more lines remain. Nothing is re-run; the bytes come
/// from [file] and the totals from [descriptor].
///
/// Throws a [ResultError] with `from <n> beyond last line <m>` when [from] is
/// past the last line, and for a [from] or [lines] below 1.
Future<String> readMore(
  File file,
  ResultDescriptor descriptor, {
  required int from,
  int lines = 100,
}) async {
  if (from < 1) throw ResultError('from $from must be at least 1');
  if (lines < 1) throw ResultError('lines $lines must be at least 1');
  if (from > descriptor.lines) {
    throw ResultError('from $from beyond last line ${descriptor.lines}');
  }
  final page = lines < maxPageLines ? lines : maxPageLines;
  return await composeResult(
    'read_more',
    ResultStatus.ok,
    '${descriptor.handle} from line $from',
    descriptor,
    file,
    policy: ResultPolicy(maxLines: page),
    startLine: from,
  );
}
