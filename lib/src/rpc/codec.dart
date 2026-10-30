/// The NDJSON line codec of `kehai rpc` (spec *NDJSON framing*).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'protocol.dart';

/// What the reader found in the input.
sealed class LineEvent {
  const LineEvent();
}

/// One complete input line, without its newline.
final class InputLine extends LineEvent {
  /// Creates the event.
  const InputLine(this.text);

  /// The decoded line.
  final String text;
}

/// A line over the limit; it is discarded up to its newline.
final class OverlongLine extends LineEvent {
  /// Creates the event.
  const OverlongLine();
}

/// A line that is not valid UTF-8; it was discarded.
final class MalformedLine extends LineEvent {
  /// Creates the event.
  const MalformedLine();
}

/// Splits [input] into lines of at most [limit] bytes.
///
/// A line ends at `\n`; a `\r` before it is dropped. A longer line yields one
/// [OverlongLine] as soon as it passes [limit], and its remaining bytes are
/// dropped without being held, so memory stays within [limit] plus one chunk.
/// A last line with no newline is a line too. The stream honors pause, so a
/// paused listener stops the reads from [input].
Stream<LineEvent> readLines(
  Stream<List<int>> input, {
  int limit = maxLineBytes,
}) async* {
  final line = BytesBuilder();
  var discarding = false;
  await for (final chunk in input) {
    var start = 0;
    while (start < chunk.length) {
      final newline = chunk.indexOf(0x0a, start);
      final end = newline < 0 ? chunk.length : newline;
      if (!discarding) {
        if (line.length + (end - start) > limit) {
          discarding = true;
          line.clear();
          yield const OverlongLine();
        } else {
          line.add(chunk.sublist(start, end));
        }
      }
      if (newline < 0) break;
      if (discarding) {
        discarding = false;
      } else {
        yield _decode(line.takeBytes());
      }
      start = newline + 1;
    }
  }
  if (!discarding && line.length > 0) yield _decode(line.takeBytes());
}

LineEvent _decode(Uint8List bytes) {
  final end = bytes.isNotEmpty && bytes.last == 0x0d
      ? bytes.length - 1
      : bytes.length;
  try {
    return InputLine(utf8.decode(Uint8List.sublistView(bytes, 0, end)));
  } on FormatException {
    return const MalformedLine();
  }
}
