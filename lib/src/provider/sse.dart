/// Server-sent event framing (design D10).
///
/// [parseSse] follows the WHATWG event stream framing: lines end in LF, CRLF
/// or CR (also across chunk boundaries), `data:` lines join with LF, a blank
/// line dispatches, and unknown fields are ignored. A comment line surfaces as
/// an [SseEvent] with [SseEvent.isComment] set so a caller can treat it as
/// liveness.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../auth/openai_constants.dart';

/// One parsed server-sent event.
final class SseEvent {
  /// Creates an event.
  const SseEvent({this.event, this.data = '', this.isComment = false});

  /// The `event:` field, or `null` when the event had none.
  final String? event;

  /// The joined `data:` lines, or the text of a comment.
  final String data;

  /// Whether this is a `:` comment line rather than a dispatched event.
  final bool isComment;
}

/// The stream broke the framing bounds.
final class SseProtocolError implements Exception {
  /// Creates an error with a fixed [message].
  const SseProtocolError(this.message);

  /// The fixed description.
  final String message;

  @override
  String toString() => 'SseProtocolError: $message';
}

const int _cr = 0x0D;
const int _lf = 0x0A;
const int _colon = 0x3A;
const int _space = 0x20;

/// Room for the `data:` field name and one space ahead of a value.
const int _fieldSlack = 16;

const SseProtocolError _tooLarge = SseProtocolError('SSE event exceeds 8 MiB');

/// Parses [source] into events, reading a chunk only as the listener asks.
///
/// Fails with an [SseProtocolError] when one event's data exceeds
/// [openAiMaxSseEventBytes]; the buffered bytes are dropped first. A final
/// event with no terminating blank line is discarded.
Stream<SseEvent> parseSse(Stream<List<int>> source) async* {
  // Copying: lines grow one byte at a time, and a non-copying builder
  // would keep a separate allocation per byte.
  final line = BytesBuilder();
  var data = BytesBuilder(copy: false);
  var dataBytes = 0;
  var hasData = false;
  String? eventName;
  var sawCr = false;

  void reset() {
    data = BytesBuilder(copy: false);
    dataBytes = 0;
    hasData = false;
    eventName = null;
    line.clear();
  }

  // Handles one complete line; returns an event to emit, if any.
  SseEvent? endLine() {
    final bytes = line.takeBytes();
    if (bytes.isEmpty) {
      if (!hasData) {
        eventName = null;
        return null;
      }
      final event = SseEvent(
        event: eventName,
        data: utf8.decode(data.takeBytes(), allowMalformed: true),
      );
      reset();
      return event;
    }
    if (bytes[0] == _colon) {
      return SseEvent(
        data: utf8.decode(
          bytes.sublist(bytes.length > 1 && bytes[1] == _space ? 2 : 1),
          allowMalformed: true,
        ),
        isComment: true,
      );
    }
    var colon = bytes.indexOf(_colon);
    final name = utf8.decode(
      colon < 0 ? bytes : bytes.sublist(0, colon),
      allowMalformed: true,
    );
    if (colon < 0) colon = bytes.length - 1;
    var start = colon + 1;
    if (start < bytes.length && bytes[start] == _space) start++;
    switch (name) {
      case 'data':
        final value = Uint8List.sublistView(bytes, start);
        final added = value.length + (hasData ? 1 : 0);
        if (dataBytes + added > openAiMaxSseEventBytes) {
          reset();
          throw _tooLarge;
        }
        if (hasData) data.addByte(_lf);
        data.add(value);
        dataBytes += added;
        hasData = true;
      case 'event':
        eventName = utf8.decode(
          Uint8List.sublistView(bytes, start),
          allowMalformed: true,
        );
    }
    return null;
  }

  await for (final chunk in source) {
    for (final b in chunk) {
      if (sawCr) {
        sawCr = false;
        if (b == _lf) continue;
      }
      if (b == _cr || b == _lf) {
        sawCr = b == _cr;
        final event = endLine();
        if (event != null) yield event;
        continue;
      }
      line.addByte(b);
      if (dataBytes + line.length > openAiMaxSseEventBytes + _fieldSlack) {
        reset();
        throw _tooLarge;
      }
    }
  }
}
