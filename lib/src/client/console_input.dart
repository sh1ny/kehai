/// Console input of the line client that survives Ctrl-C (design D14).
///
/// On a Windows console, Ctrl-C aborts the pending read, which returns no
/// bytes, and Dart's standard input stream ends as if input had ended. The
/// client would then exit after the interrupted exchange instead of returning
/// to its prompt. So the console is read again when a read ends around a
/// Ctrl-C; an end with no Ctrl-C near it, such as Ctrl-Z Enter, is still the
/// end of input.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

/// The lines of the console, read from [open], which is called again when a
/// read ends within [grace] of a Ctrl-C on [interrupts], before or after the
/// end. Each Ctrl-C reopens at most once.
///
/// Pausing the lines does not pause the read, so the end of a read is seen
/// when it happens: the client pauses its input while an exchange runs, which
/// is when the Ctrl-C comes. Lines are buffered until the resume.
Stream<String> consoleLines({
  required Stream<String> Function() open,
  required Stream<void> interrupts,
  Duration grace = const Duration(milliseconds: 500),
}) {
  late final StreamController<String> out;
  StreamSubscription<String>? reading;
  StreamSubscription<void>? signals;
  Timer? deciding;
  final clock = Stopwatch()..start();
  // When the last Ctrl-C that has not reopened the console yet arrived.
  Duration? unused;

  late void Function() read;

  void ended() {
    reading = null;
    final last = unused;
    unused = null;
    if (last != null && clock.elapsed - last <= grace) {
      read();
      return;
    }
    // The signal may still be on its way; wait for it before ending.
    deciding = Timer(grace, () {
      deciding = null;
      unawaited(signals?.cancel());
      unawaited(out.close());
    });
  }

  read = () {
    reading = open().listen(out.add, onError: out.addError, onDone: ended);
  };

  out = StreamController<String>(
    onListen: () {
      signals = interrupts.listen((_) {
        if (deciding case final timer?) {
          timer.cancel();
          deciding = null;
          read();
        } else {
          unused = clock.elapsed;
        }
      });
      read();
    },
    onCancel: () async {
      deciding?.cancel();
      await signals?.cancel();
      await reading?.cancel();
    },
  );
  return out.stream;
}

/// The lines typed at the Windows console.
///
/// Standard input as a stream cannot be listened to again once a Ctrl-C has
/// ended it, and `CONIN$` cannot be opened through [File]. So a helper
/// isolate reads with [Stdin.readLineSync], which starts a new read on each
/// call: it reads until a read ends, then waits to be told to read again.
/// The isolate stays blocked in its read until the process exits.
Stream<String> windowsConsoleLines(Stream<void> interrupts) {
  final lines = ReceivePort();
  final messages = lines.asBroadcastStream();
  final reader = Isolate.spawn(_readConsole, lines.sendPort);
  final control = messages
      .where((m) => m is SendPort)
      .first
      .then((port) => port as SendPort);
  return consoleLines(
    open: () {
      unawaited(control.then((port) => port.send(true)));
      return messages
          .takeWhile((m) => m != _end)
          .where((m) => m is String)
          .cast<String>();
    },
    interrupts: interrupts,
  ).transform(
    StreamTransformer.fromHandlers(
      handleDone: (sink) {
        lines.close();
        unawaited(reader.then((isolate) => isolate.kill()));
        sink.close();
      },
    ),
  );
}

/// Sent by the reader when a read ends.
const String _end = '\u0000end';

void _readConsole(SendPort out) {
  final go = ReceivePort();
  out.send(go.sendPort);
  go.listen((_) {
    while (true) {
      final line = stdin.readLineSync(encoding: utf8);
      if (line == null) break;
      out.send(line);
    }
    out.send(_end);
  });
}
