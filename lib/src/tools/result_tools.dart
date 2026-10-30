/// The `read_more` and `search_result` tools over stored results.
///
/// Both read a result the session already stored and re-run nothing. Their
/// page is the central composer's text, so the runtime answers with it as it
/// is (`ToolOutcome.composed`).
library;

import '../results/descriptor.dart';
import '../results/handles.dart';
import '../results/reader.dart';
import '../results/search.dart';
import 'file_access.dart';
import 'tool.dart';

/// The `read_more` tool: pages through a stored result from a line.
final class ReadMoreTool implements Tool {
  /// Creates the tool.
  const ReadMoreTool();

  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    final handle = input['handle']! as String;
    final from = input['from'] as int? ?? 1;
    return _answer(context, handle, '$handle from line $from', (stored) {
      return readMore(
        stored.file,
        stored.descriptor,
        from: from,
        lines: input['lines'] as int? ?? 100,
      );
    });
  }
}

/// The `search_result` tool: the lines of a stored result matching a pattern.
final class SearchResultTool implements Tool {
  /// Creates the tool; [searcher] bounds the concurrent searches.
  const SearchResultTool(this.searcher);

  /// The searcher every call of this runtime shares.
  final ResultSearcher searcher;

  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    final handle = input['handle']! as String;
    final pattern = input['pattern']! as String;
    return _answer(context, handle, '$handle matching $pattern', (stored) {
      return searcher.searchResult(stored.file, stored.descriptor, pattern);
    });
  }
}

Future<ToolOutcome> _answer(
  ToolContext context,
  String handle,
  String summary,
  Future<String> Function(ResolvedResult stored) page,
) async {
  final jobs = context.jobs;
  if (jobs == null) return failure('no stored results in this context');
  try {
    final stored = resolveHandle(
      jobs.writer.tree,
      jobs.store.sessionDir,
      handle,
    );
    await context.output.writeText(await page(stored));
    return ToolOutcome(summary: summary, composed: true);
  } on ResultError catch (e) {
    return failure(e.message);
  }
}
