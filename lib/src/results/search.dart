/// Regular-expression search over a stored result.
///
/// Dart's `RegExp` has no timeout, so every search runs in a worker isolate
/// that the caller kills at a deadline. The worker never presents a partial
/// match list as complete.
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'composer.dart';
import 'descriptor.dart';
import 'line_scanner.dart';

/// The number of leading bytes of each line that is matched.
const searchPrefixBytes = 64 * 1024;

/// The most matches shown before the `… +N more` line.
const maxShownMatches = 200;

/// The most long-line notices listed in one result.
const _maxNotices = 20;

/// Runs searches in worker isolates with a deadline and a slot limit.
///
/// An instance owns its slot count, so concurrency is limited per engine and
/// not globally.
final class ResultSearcher {
  /// Creates a searcher with [slots] concurrent workers and a [timeout].
  ///
  /// The defaults are 4 workers and 5 seconds; other values exist for tests.
  ResultSearcher({this.slots = 4, this.timeout = const Duration(seconds: 5)});

  /// The most workers that may run at once.
  final int slots;

  /// The deadline after which a worker is killed.
  final Duration timeout;

  /// The number of workers spawned so far.
  int workersSpawned = 0;

  int _active = 0;

  /// Returns the lines of the stored [file] that match [pattern].
  ///
  /// Matches appear as `<line>: <text>`, at most 200 of them, followed by
  /// `… +<N> more` when there are others. Each line is matched only within
  /// its first 64 KiB, and the result lists the lines where that applied.
  /// The [descriptor] supplies the handle for the header.
  ///
  /// Throws a [ResultError] for an invalid pattern (`invalid pattern: ...`),
  /// when every slot is taken (`search busy`, with no worker started), and
  /// when the deadline passes (`search timed out after 5s; narrow the
  /// pattern`).
  Future<String> searchResult(
    File file,
    ResultDescriptor descriptor,
    String pattern,
  ) async {
    try {
      RegExp(pattern);
    } on FormatException catch (e) {
      throw ResultError('invalid pattern: ${e.message}');
    }
    if (_active >= slots) throw const ResultError('search busy');
    _active++;

    final results = ReceivePort();
    final exits = ReceivePort();
    final exited = Completer<void>();
    Isolate? worker;
    Timer? deadline;
    try {
      final done = Completer<void>();
      final matches = <(int, String, int)>[];
      final notices = <(int, int, int)>[];
      var matchTotal = 0;
      var noticeTotal = 0;

      results.listen((Object? m) {
        switch (m) {
          case ['m', final int n, final String text, final int chars]:
            matches.add((n, text, chars));
          case ['long', final int n, final int kept, final int total]:
            notices.add((n, kept, total));
          case ['done', final int found, final int longLines]:
            matchTotal = found;
            noticeTotal = longLines;
            if (!done.isCompleted) done.complete();
          case ['error', final String reason]:
            if (!done.isCompleted) {
              done.completeError(ResultError('search failed: $reason'));
            }
        }
      });
      exits.listen((_) {
        if (!exited.isCompleted) exited.complete();
        if (!done.isCompleted) {
          done.completeError(const ResultError('search worker exited'));
        }
      });

      workersSpawned++;
      final spawned = worker = await Isolate.spawn<_Job>(
        _searchWorker,
        _Job(results.sendPort, file.path, pattern),
        onExit: exits.sendPort,
      );
      deadline = Timer(timeout, () {
        if (done.isCompleted) return;
        done.completeError(ResultError(_timedOut(timeout)));
        spawned.kill(priority: Isolate.immediate);
      });
      await done.future;

      final out = StringBuffer()
        ..write(
          '[search_result ok] ${matchTotal == 0 ? 'no matches' : '$matchTotal '
                    'match${matchTotal == 1 ? '' : 'es'}'} for /$pattern/ '
          'in ${descriptor.handle}',
        );
      // The worker sends one message past the cap so the caller can tell
      // that matches were left out; only the first `maxShownMatches` render.
      for (final (n, text, chars) in matches.take(maxShownMatches)) {
        if (n < 0) continue;
        out.write('\n$n: ${clipLine(text, chars)}');
      }
      if (matchTotal > maxShownMatches) {
        out.write('\n… +${matchTotal - maxShownMatches} more');
      }
      for (final (n, kept, total) in notices) {
        out.write('\nline $n searched first $kept of $total bytes');
      }
      if (noticeTotal > notices.length) {
        out.write(
          '\n… +${noticeTotal - notices.length} more lines searched by '
          'prefix only',
        );
      }
      return out.toString();
    } finally {
      deadline?.cancel();
      if (worker != null) {
        worker.kill(priority: Isolate.immediate);
        // Wait for the worker to be gone so its file handle is released.
        await exited.future.timeout(
          const Duration(seconds: 2),
          onTimeout: () {},
        );
      }
      results.close();
      exits.close();
      _active--;
    }
  }
}

String _timedOut(Duration d) {
  final span = d.inMilliseconds % 1000 == 0
      ? '${d.inSeconds}s'
      : '${d.inMilliseconds}ms';
  return 'search timed out after $span; narrow the pattern';
}

/// The message sent to a search worker.
final class _Job {
  const _Job(this.port, this.path, this.pattern);

  final SendPort port;
  final String path;
  final String pattern;
}

/// The worker entry point: scans the file and streams matches back.
///
/// At most 201 match messages are sent, then only the final count, so the
/// caller's buffer stays bounded.
Future<void> _searchWorker(_Job job) async {
  final port = job.port;
  try {
    final re = RegExp(job.pattern);
    var found = 0;
    var longLines = 0;
    await for (final line in scanLines(
      File(job.path),
      retainBytes: searchPrefixBytes,
      holdOpen: false,
    )) {
      if (line.retainedBytes < line.totalBytes) {
        if (longLines < _maxNotices) {
          port.send(['long', line.number, line.retainedBytes, line.totalBytes]);
        }
        longLines++;
      }
      if (re.hasMatch(line.text)) {
        if (found <= maxShownMatches) {
          port.send(['m', line.number, line.text, line.totalChars]);
        }
        found++;
      }
    }
    port.send(['done', found, longLines]);
  } catch (e) {
    port.send(['error', e.toString()]);
  }
}
