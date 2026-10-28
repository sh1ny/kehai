/// Bounded byte-level line scanner over a stored result file.
///
/// This is the only reader of stored result bytes, together with the
/// composer. It exists so that memory per line is bounded by the retained
/// prefix plus one read buffer, even for a newline-free multi-GiB file.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// The size of each read from the stored file.
const scanBufferBytes = 64 * 1024;

const _lf = 0x0a;
const _cr = 0x0d;

/// Test-visible memory statistics of a scan.
final class ScanStats {
  /// The largest number of bytes retained for any one line.
  int maxRetainedBytes = 0;

  /// The size of the read buffer used.
  int bufferBytes = 0;

  /// The number of bytes read from the file so far.
  int bytesRead = 0;
}

/// One scanned line.
///
/// A line is a `\n`-terminated segment, plus a final unterminated segment if
/// it is non-empty. A `\r` directly before the `\n` is dropped from the
/// display text only; the stored bytes are never changed.
///
/// Character counts are Unicode code points, computed over the raw bytes by
/// counting every byte that is not a UTF-8 continuation byte. For ASCII text
/// that equals the byte count; for malformed input it is approximate.
final class ScannedLine {
  /// Creates a scanned line.
  const ScannedLine({
    required this.number,
    required this.text,
    required this.totalBytes,
    required this.retainedBytes,
    required this.totalChars,
    required this.shownChars,
  });

  /// The 1-based line number.
  final int number;

  /// The decoded retained prefix, without the line terminator.
  ///
  /// Malformed UTF-8 is replaced by U+FFFD.
  final String text;

  /// The length of the whole line in bytes, without the line terminator.
  final int totalBytes;

  /// The number of leading bytes of the line that were retained.
  final int retainedBytes;

  /// The length of the whole line in characters.
  final int totalChars;

  /// The number of characters in [text].
  final int shownChars;

  /// Whether some of the line is not in [text].
  bool get cut => shownChars < totalChars || retainedBytes < totalBytes;
}

/// Scans [file] line by line in 64 KiB reads.
///
/// Per line at most [retainBytes] leading bytes are kept; the rest is
/// counted and dropped. When [maxChars] is given, the decoded text is further
/// limited to that many characters. Lines before [startLine] are counted but
/// not retained or emitted. Cancelling the stream stops reading and closes
/// the file. [stats], when given, records the memory actually used.
///
/// With [holdOpen] false the file is opened and closed around every read, so
/// that no handle is held while the consumer works. A search worker uses this
/// because it can be killed in the middle of a long match, and a killed
/// isolate never runs its cleanup.
Stream<ScannedLine> scanLines(
  File file, {
  int startLine = 1,
  required int retainBytes,
  int? maxChars,
  ScanStats? stats,
  bool holdOpen = true,
}) async* {
  RandomAccessFile? raf = holdOpen ? await file.open() : null;
  var position = 0;
  try {
    final buffer = Uint8List(scanBufferBytes);
    stats?.bufferBytes = buffer.length;
    final line = _LineState();
    var number = 1;

    ScannedLine? finish() {
      final emit = number >= startLine;
      final result = emit ? line.build(number, maxChars) : null;
      if (emit &&
          stats != null &&
          line.retained.length > stats.maxRetainedBytes) {
        stats.maxRetainedBytes = line.retained.length;
      }
      line.reset();
      number++;
      return result;
    }

    while (true) {
      int n;
      if (raf != null) {
        n = await raf.readInto(buffer);
      } else {
        final chunk = await file.open();
        try {
          await chunk.setPosition(position);
          n = await chunk.readInto(buffer);
        } finally {
          await chunk.close();
        }
        position += n;
      }
      if (n == 0) break;
      stats?.bytesRead += n;
      final view = Uint8List.sublistView(buffer, 0, n);
      var start = 0;
      while (start < n) {
        final lf = view.indexOf(_lf, start);
        final end = lf < 0 ? n : lf;
        final limit = number >= startLine ? retainBytes : 0;
        if (end > start) {
          var segEnd = end;
          if (line.pendingCr) line.addCr(limit);
          // A trailing CR is held back until we know what follows it.
          if (view[segEnd - 1] == _cr) {
            segEnd--;
            line.pendingCr = true;
          }
          line.add(view, start, segEnd, limit);
        }
        if (lf < 0) break;
        // Terminated by the LF at index [end]: a held-back CR is dropped.
        line.pendingCr = false;
        final done = finish();
        if (done != null) yield done;
        start = end + 1;
      }
    }
    // Final unterminated segment, if non-empty.
    if (line.pendingCr) line.addCr(number >= startLine ? retainBytes : 0);
    if (line.totalBytes > 0) {
      final done = finish();
      if (done != null) yield done;
    }
  } finally {
    await raf?.close();
  }
}

/// Mutable state of the line being scanned.
final class _LineState {
  final BytesBuilder retained = BytesBuilder(copy: true);
  int totalBytes = 0;
  int totalChars = 0;
  bool pendingCr = false;

  void addCr(int limit) {
    pendingCr = false;
    add(Uint8List.fromList(const [_cr]), 0, 1, limit);
  }

  void add(Uint8List data, int start, int end, int limit) {
    if (end <= start) return;
    totalBytes += end - start;
    var chars = 0;
    for (var i = start; i < end; i++) {
      if (data[i] & 0xC0 != 0x80) chars++;
    }
    totalChars += chars;
    final room = limit - retained.length;
    if (room > 0) {
      final keep = end - start < room ? end - start : room;
      retained.add(Uint8List.sublistView(data, start, start + keep));
    }
  }

  ScannedLine build(int number, int? maxChars) {
    var text = const Utf8Decoder(allowMalformed: true)
        .convert(retained.toBytes());
    var shown = _countRunes(text);
    if (maxChars != null && shown > maxChars) {
      text = _firstRunes(text, maxChars);
      shown = maxChars;
    }
    return ScannedLine(
      number: number,
      text: text,
      totalBytes: totalBytes,
      retainedBytes: retained.length,
      totalChars: totalChars,
      shownChars: shown,
    );
  }

  void reset() {
    retained.clear();
    totalBytes = 0;
    totalChars = 0;
    pendingCr = false;
  }
}

int _countRunes(String s) {
  var n = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    final isLowSurrogate = c >= 0xDC00 && c <= 0xDFFF;
    if (!isLowSurrogate || i == 0) n++;
  }
  return n;
}

String _firstRunes(String s, int count) {
  var seen = 0;
  for (var i = 0; i < s.length; i++) {
    final c = s.codeUnitAt(i);
    if (c >= 0xDC00 && c <= 0xDFFF && i > 0) continue;
    if (seen == count) return s.substring(0, i);
    seen++;
  }
  return s;
}
