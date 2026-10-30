/// The output pump: the one place every outgoing line passes (design D12).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// Serializes events as NDJSON lines onto an output sink.
///
/// This first version queues without bound. Task 6.1 replaces it with the
/// bounded pump (reliable and droppable queues, resync); the server only
/// uses [send], [flush] and [close], so the swap stays inside this file.
final class OutputPump {
  /// Creates a pump writing to [sink].
  OutputPump(this._sink);

  final IOSink _sink;
  final Queue<List<int>> _queue = Queue();
  Future<void>? _draining;
  bool _broken = false;

  /// Whether writing to the sink failed, for example a closed pipe.
  bool get broken => _broken;

  /// Queues [event] as one line.
  ///
  /// [droppable] marks `update` and `stream` events, which the bounded pump
  /// may discard; this version keeps everything.
  void send(Map<String, Object?> event, {bool droppable = false}) {
    if (_broken) return;
    _queue.add(utf8.encode('${jsonEncode(event)}\n'));
    _draining ??= _drain();
  }

  /// Completes when every queued line was written and flushed.
  Future<void> flush() async {
    for (var draining = _draining; draining != null; draining = _draining) {
      await draining;
    }
  }

  /// Flushes, then closes the sink.
  Future<void> close() async {
    await flush();
    try {
      await _sink.close();
    } on Object {
      _broken = true;
    }
  }

  Future<void> _drain() async {
    try {
      while (_queue.isNotEmpty && !_broken) {
        while (_queue.isNotEmpty) {
          _sink.add(_queue.removeFirst());
        }
        await _sink.flush();
      }
    } on Object {
      _broken = true;
      _queue.clear();
    } finally {
      _draining = null;
    }
  }
}
