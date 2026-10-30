/// The output pump: the one place every outgoing line passes (design D12).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// The byte bounds of an [OutputPump].
final class PumpLimits {
  /// Creates limits; the defaults are the protocol's.
  const PumpLimits({
    this.reliable = 1024 * 1024,
    this.droppable = 16 * 1024 * 1024,
    this.batch = 64 * 1024,
  });

  /// Queued reliable bytes above which the server stops reading commands.
  final int reliable;

  /// Queued droppable bytes above which they are discarded for a resync.
  final int droppable;

  /// The bytes handed to the sink before each awaited flush.
  final int batch;
}

/// Produces the events that follow a resync, taken when they are written.
typedef ResyncEvents = List<Map<String, Object?>> Function();

/// One queued line, or the single pending resync when [bytes] is null.
final class _Line {
  const _Line(this.bytes, {this.droppable = false});

  final List<int>? bytes;
  final bool droppable;
}

/// Serializes events as NDJSON lines onto an output sink.
///
/// `update` and `stream` events are droppable; everything else is reliable and
/// never dropped. Lines leave in batches of `limits.batch` bytes, each handed
/// to the sink with `add` and then awaited with one flush, so a slow reader
/// backs the pump up. A line counts against its bound until the flush that
/// wrote it completes.
///
/// When the droppable bytes exceed `limits.droppable`, or the caller asks with
/// [requestResync], the queued droppable events are discarded and one resync
/// is left pending; a further request before it is written changes nothing.
/// The resync events come from the `resync` callback at the moment they are
/// written, so they describe the latest state. Droppable events sent while a
/// resync is pending are discarded, since that state covers them.
final class OutputPump {
  /// Creates a pump writing to [sink].
  ///
  /// [resync] makes the events written for a pending resync, by default a bare
  /// `resync`. [onRelief] runs when the reliable bytes fall back to the limit
  /// after exceeding it.
  OutputPump(
    this._sink, {
    this.limits = const PumpLimits(),
    this.resync,
    this.onRelief,
  });

  final IOSink _sink;

  /// The byte bounds.
  final PumpLimits limits;

  /// Makes the events of a pending resync when they are written.
  final ResyncEvents? resync;

  /// Runs when the reliable bytes fall back to the limit.
  final void Function()? onRelief;
  final Queue<_Line> _queue = Queue();
  static const _Line _marker = _Line(null);
  int _reliableBytes = 0;
  int _droppableBytes = 0;
  bool _resyncPending = false;
  Future<void>? _draining;
  bool _broken = false;

  /// Whether writing to the sink failed, for example a closed pipe.
  bool get broken => _broken;

  /// The reliable bytes queued or being written.
  int get reliableBytes => _reliableBytes;

  /// Whether more than the reliable limit is queued, so input should wait.
  bool get saturated => _reliableBytes > limits.reliable;

  /// Whether a resync is waiting to be written.
  bool get resyncPending => _resyncPending;

  /// Leaves one resync pending after the queued events.
  ///
  /// The queued droppable events are discarded, unless [keepQueued] is set,
  /// which a caller uses when they must reach the client first.
  void requestResync({bool keepQueued = false}) {
    if (_broken) return;
    if (!keepQueued) {
      _queue.removeWhere((line) {
        if (!line.droppable) return false;
        _droppableBytes -= line.bytes!.length;
        return true;
      });
    }
    if (!_resyncPending) {
      _resyncPending = true;
      _queue.add(_marker);
    }
    _draining ??= _drain();
  }

  /// Queues [event] as one line.
  ///
  /// [droppable] marks `update` and `stream` events, which are discarded when
  /// the client falls behind.
  void send(Map<String, Object?> event, {bool droppable = false}) {
    if (_broken) return;
    if (droppable && _resyncPending) return;
    final bytes = _encode(event);
    _queue.add(_Line(bytes, droppable: droppable));
    if (droppable) {
      _droppableBytes += bytes.length;
      if (_droppableBytes > limits.droppable) requestResync();
    } else {
      _reliableBytes += bytes.length;
    }
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
        final batch = <_Line>[];
        var size = 0;
        while (_queue.isNotEmpty && size < limits.batch) {
          final line = _queue.removeFirst();
          final bytes = line.bytes;
          if (bytes != null) {
            _sink.add(bytes);
            batch.add(line);
            size += bytes.length;
            continue;
          }
          // The resync events are taken now, so they are the latest state.
          _resyncPending = false;
          final events =
              resync?.call() ??
              const [
                {'type': 'resync'},
              ];
          for (final event in events) {
            final written = _encode(event);
            _sink.add(written);
            size += written.length;
          }
        }
        await _sink.flush();
        final wasSaturated = saturated;
        for (final line in batch) {
          if (line.droppable) {
            _droppableBytes -= line.bytes!.length;
          } else {
            _reliableBytes -= line.bytes!.length;
          }
        }
        if (wasSaturated && !saturated) onRelief?.call();
      }
    } on Object {
      _broken = true;
      _queue.clear();
      _reliableBytes = 0;
      _droppableBytes = 0;
      _resyncPending = false;
      onRelief?.call();
    } finally {
      _draining = null;
    }
  }
}

List<int> _encode(Map<String, Object?> event) =>
    utf8.encode('${jsonEncode(event)}\n');
