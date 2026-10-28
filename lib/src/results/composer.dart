/// The only place that renders a stored result for the model.
///
/// Every cut of result text happens here or in the line scanner: the line
/// cap, the head and tail cut, the per-line cap and the paging window. The
/// output uses one envelope: a header `[<tool> <status>] <summary>`, the
/// body lines, then a truncation line only when something was left out.
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'descriptor.dart';
import 'line_scanner.dart';

/// The outcome reported in the envelope header.
enum ResultStatus {
  /// The call succeeded.
  ok,

  /// The call failed.
  error,

  /// The call produced a usable but incomplete result.
  partial,

  /// The call was refused by policy.
  denied,

  /// The call ran out of time.
  timeout,
}

/// A failure to compose a result, such as a `notrunc` result over capacity.
final class ComposeError extends ResultError {
  /// Creates an error with the given [message].
  const ComposeError(super.message);
}

/// How much of a result is shown, and how it is cut.
///
/// Exactly one of [maxLines] and [maxTokens] is set. With [headTail] a cut
/// keeps whole lines from the start within 60% of the budget and from the end
/// within 40%; otherwise only the head is kept.
final class ResultPolicy {
  /// Creates a policy with a line budget or a token budget.
  const ResultPolicy({
    this.maxLines,
    this.maxTokens,
    this.headTail = false,
    this.maxLineChars = 2000,
  }) : assert(
         (maxLines == null) != (maxTokens == null),
         'set exactly one of maxLines and maxTokens',
       );

  /// The line budget, or `null` for a token policy.
  final int? maxLines;

  /// The estimated-token budget, or `null` for a line policy.
  final int? maxTokens;

  /// Whether a cut keeps a head and a tail instead of only a head.
  final bool headTail;

  /// The per-line cap in characters.
  final int maxLineChars;

  /// The default for `read`: 400 lines, head only.
  static const read = ResultPolicy(maxLines: 400);

  /// The default for `bash`: 8,000 estimated tokens, head 60% and tail 40%.
  static const bash = ResultPolicy(maxTokens: 8000, headTail: true);

  /// The default for any other tool: 8,000 estimated tokens, head only.
  static const other = ResultPolicy(maxTokens: 8000);

  /// The default policy of the tool named [tool].
  static ResultPolicy forTool(String tool) => switch (tool) {
    'read' => read,
    'bash' => bash,
    _ => other,
  };
}

/// Estimates the tokens of [bytes] UTF-8 bytes as `ceil(bytes / 3)`.
///
/// This is a heuristic, not an upper bound. It only sizes presentation cuts
/// and the `notrunc` pre-check.
int estimateTokens(int bytes) => (bytes + 2) ~/ 3;

/// Composes the stored [file] described by [descriptor] into model text.
///
/// The header names [tool], [status] and [summary]. The [policy] defaults to
/// [ResultPolicy.forTool]. Output starts at [startLine], which is how paging
/// reuses the same cuts; a cut result ends with a truncation line that states
/// the shown ranges, the total, the handle and a `read_more` hint.
///
/// With [notrunc] the whole result is written with no line or per-line cut,
/// provided its estimate is within [capacityTokens]; otherwise this throws a
/// [ComposeError] before producing any body. [stats] records the memory the
/// scan used.
Future<String> composeResult(
  String tool,
  ResultStatus status,
  String summary,
  ResultDescriptor descriptor,
  File file, {
  ResultPolicy? policy,
  bool notrunc = false,
  int? capacityTokens,
  int startLine = 1,
  ScanStats? stats,
}) async {
  final out = StringBuffer();
  await composeResultTo(
    out,
    tool,
    status,
    summary,
    descriptor,
    file,
    policy: policy,
    notrunc: notrunc,
    capacityTokens: capacityTokens,
    startLine: startLine,
    stats: stats,
  );
  return out.toString();
}

/// Like [composeResult], but writes to [sink] as lines are scanned.
///
/// Under `notrunc` lines are streamed to [sink] and not retained here.
Future<void> composeResultTo(
  StringSink sink,
  String tool,
  ResultStatus status,
  String summary,
  ResultDescriptor descriptor,
  File file, {
  ResultPolicy? policy,
  bool notrunc = false,
  int? capacityTokens,
  int startLine = 1,
  ScanStats? stats,
}) async {
  final p = policy ?? ResultPolicy.forTool(tool);
  final handle = descriptor.handle;
  final total = descriptor.lines;

  if (notrunc) {
    if (capacityTokens == null) {
      throw ArgumentError.value(
        capacityTokens,
        'capacityTokens',
        'required with notrunc',
      );
    }
    final estimate = estimateTokens(descriptor.bytes);
    if (estimate > capacityTokens) {
      throw ComposeError(
        'notrunc result of $estimate tokens exceeds capacity '
        '$capacityTokens; use read_more',
      );
    }
    sink.write(_header(tool, status, summary));
    await for (final line in scanLines(
      file,
      startLine: startLine,
      retainBytes: 1 << 62,
      stats: stats,
    )) {
      sink
        ..write('\n')
        ..write(line.text);
    }
    return;
  }

  Stream<ScannedLine> scan() => scanLines(
    file,
    startLine: startLine,
    retainBytes: p.maxLineChars * 4,
    maxChars: p.maxLineChars,
    stats: stats,
  );

  final budget = p.maxLines ?? p.maxTokens!;
  // Lines cost one unit each; under a token budget a line costs its bytes
  // (with its newline) and the estimate is taken over the running total, so
  // that no per-line rounding accumulates.
  int unit(String text) =>
      p.maxLines != null ? 1 : utf8.encode(text).length + 1;
  bool within(int used, int cap) =>
      (p.maxLines != null ? used : estimateTokens(used)) <= cap;

  final remaining = total - startLine + 1;
  final fits = p.maxLines != null
      ? remaining <= budget
      : startLine == 1 && estimateTokens(descriptor.bytes) <= budget;

  sink.write(_header(tool, status, summary));

  // A result that fits by its stored bytes is not cut for rounding: the
  // final line's counted newline may not be stored.
  // The rendered text is checked too, since malformed UTF-8 grows when
  // decoded (each bad byte becomes a 3-byte U+FFFD); once it outgrows the
  // stored bytes the budget applies as for any other result, and a head and
  // tail policy then keeps only the head.
  bool allowed(int used) =>
      within(used, budget) ||
      fits && (p.maxLines != null || used <= descriptor.bytes + 1);

  if (!p.headTail || fits) {
    // Head only: whole lines from [startLine] until the budget is used.
    var count = 0;
    var used = 0;
    await for (final line in scan()) {
      final text = count == 0 && p.maxTokens != null
          ? _fitFirst(line, budget)
          : _render(line);
      final cost = unit(text);
      if (count > 0 && !allowed(used + cost)) break;
      sink
        ..write('\n')
        ..write(text);
      count++;
      used += cost;
      // Under a line cap the next line is never shown, so stop before the
      // scanner reads it: it may be a huge newline-free line.
      if (!fits && p.maxLines != null && count >= budget) break;
    }
    final last = startLine + count - 1;
    if (last < total) {
      sink
        ..write('\n')
        ..write(
          _truncation('${_n(startLine)}–${_n(last)}', total, handle, last + 1),
        );
    }
    return;
  }

  // Head and tail: one pass, a bounded ring keeps the last lines.
  final headBudget = budget * 6 ~/ 10;
  final tailBudget = budget - headBudget;
  final head = <String>[];
  var headUsed = 0;
  var headOpen = true;
  final ring = Queue<({int number, String text, int cost})>();
  var ringUsed = 0;
  await for (final line in scan()) {
    final text = head.isEmpty && p.maxTokens != null
        ? _fitFirst(line, headBudget)
        : _render(line);
    final cost = unit(text);
    if (headOpen) {
      if (head.isEmpty || within(headUsed + cost, headBudget)) {
        head.add(text);
        headUsed += cost;
        continue;
      }
      headOpen = false;
    }
    ring.add((number: line.number, text: text, cost: cost));
    ringUsed += cost;
    while (ring.isNotEmpty && !within(ringUsed, tailBudget)) {
      ringUsed -= ring.removeFirst().cost;
    }
  }
  final headEnd = startLine + head.length - 1;
  for (final text in head) {
    sink
      ..write('\n')
      ..write(text);
  }
  if (ring.isEmpty) {
    if (headEnd < total) {
      sink
        ..write('\n')
        ..write(
          _truncation(
            '${_n(startLine)}–${_n(headEnd)}',
            total,
            handle,
            headEnd + 1,
          ),
        );
    }
    return;
  }
  final omitted = ring.first.number - headEnd - 1;
  if (omitted > 0) {
    sink
      ..write('\n')
      ..write('[… ${_n(omitted)} lines omitted …]');
  }
  for (final entry in ring) {
    sink
      ..write('\n')
      ..write(entry.text);
  }
  if (omitted > 0) {
    final ranges =
        '${_n(startLine)}–${_n(headEnd)} and '
        '${_n(ring.first.number)}–${_n(ring.last.number)}';
    sink
      ..write('\n')
      ..write(_truncation(ranges, total, handle, headEnd + 1));
  }
}

/// Clips one already-scanned line for display.
///
/// Returns [text] unchanged when it is whole and within [cap] characters.
/// Otherwise it keeps the first [cap] characters and appends
/// `[line truncated: showing <shown> of <total> chars]`, where [totalChars]
/// is the length of the whole line before any prefix was dropped.
///
/// The cap holds even when [totalChars] is approximate: it is applied to
/// the decoded [text] itself, since malformed UTF-8 can count fewer
/// characters than it decodes to.
String clipLine(String text, int totalChars, {int cap = 2000}) {
  final runes = text.runes;
  final shown = runes.length < cap ? runes.length : cap;
  if (runes.length <= cap && shown >= totalChars) return text;
  final kept = runes.length > cap
      ? String.fromCharCodes(runes.take(cap))
      : text;
  final total = totalChars > runes.length ? totalChars : runes.length;
  return '$kept ${_lineMarker(shown, total)}';
}

String _header(String tool, ResultStatus status, String summary) =>
    '[$tool ${status.name}] $summary';

/// Renders the first shown [line] so that it costs at most [cap] tokens.
///
/// A line that fits is rendered as usual. Otherwise it keeps the longest
/// prefix whose rendering, with its `[line truncated: …]` marker, is within
/// [cap], so a result is never empty and never over its budget. Throws a
/// [ComposeError] when not even the marker alone fits.
String _fitFirst(ScannedLine line, int cap) {
  final whole = _render(line);
  int cost(String text) => estimateTokens(utf8.encode(text).length + 1);
  if (cost(whole) <= cap) return whole;
  final runes = line.text.runes.toList();
  String clipped(int keep) =>
      '${String.fromCharCodes(runes.take(keep))} '
      '${_lineMarker(keep, line.totalChars)}';
  if (cost(clipped(0)) > cap) {
    throw ComposeError(
      'a token budget of $cap is too small to show any of line '
      '${_n(line.number)}',
    );
  }
  var low = 0;
  var high = runes.length;
  while (low < high) {
    final mid = (low + high + 1) ~/ 2;
    if (cost(clipped(mid)) <= cap) {
      low = mid;
    } else {
      high = mid - 1;
    }
  }
  return clipped(low);
}

String _render(ScannedLine line) => line.cut
    ? '${line.text} ${_lineMarker(line.shownChars, line.totalChars)}'
    : line.text;

String _lineMarker(int shown, int total) =>
    '[line truncated: showing ${_n(shown)} of ${_n(total)} chars]';

String _truncation(String ranges, int total, String handle, int next) =>
    '[truncated: showing lines $ranges of ${_n(total)}; handle $handle; '
    'read_more($handle, from=$next)]';

/// Formats [n] with comma thousands separators.
String _n(int n) {
  final digits = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) out.write(',');
    out.write(digits[i]);
  }
  return out.toString();
}
