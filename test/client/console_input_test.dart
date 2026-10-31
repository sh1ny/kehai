/// Console input that survives Ctrl-C on Windows (design D14).
library;

import 'dart:async';

import 'package:kehai/src/client/console_input.dart';
import 'package:test/test.dart';

/// Hands out one controller per open, as the console does per `CONIN$` open.
final class _FakeConsole {
  final List<StreamController<String>> opened = [];

  Stream<String> open() {
    final c = StreamController<String>();
    opened.add(c);
    return c.stream;
  }

  StreamController<String> get current => opened.last;
}

const _grace = Duration(milliseconds: 100);

Future<void> _settle([Duration d = Duration.zero]) => Future.delayed(d);

void main() {
  test(
    'input that ends right after Ctrl-C is reopened and reading goes on',
    () async {
      final console = _FakeConsole();
      final interrupts = StreamController<void>.broadcast();
      final lines = <String>[];
      var done = false;
      consoleLines(
        open: console.open,
        interrupts: interrupts.stream,
        grace: _grace,
      ).listen(lines.add, onDone: () => done = true);
      await _settle();

      console.current.add('first');
      // Ctrl-C ends the console read either just before or just after the
      // signal arrives; both orders keep reading.
      interrupts.add(null);
      await _settle();
      unawaited(console.current.close());
      await _settle(_grace * 3);
      unawaited(console.current.close());
      await _settle(_grace ~/ 4);
      interrupts.add(null);
      await _settle(_grace * 3);
      console.current.add('second');
      await _settle();

      expect(console.opened, hasLength(3));
      expect(lines, ['first', 'second']);
      expect(done, isFalse);
    },
  );

  test('input that ends with no Ctrl-C near it is the end of input', () async {
    final console = _FakeConsole();
    final interrupts = StreamController<void>.broadcast();
    final done = Completer<void>();
    consoleLines(
      open: console.open,
      interrupts: interrupts.stream,
      grace: _grace,
    ).listen((_) {}, onDone: done.complete);
    await _settle();

    interrupts.add(null);
    await _settle(_grace * 3);
    unawaited(console.current.close());
    await done.future.timeout(const Duration(seconds: 5));

    expect(console.opened, hasLength(1));
  });

  test('one Ctrl-C reopens the console once', () async {
    final console = _FakeConsole();
    final interrupts = StreamController<void>.broadcast();
    final done = Completer<void>();
    consoleLines(
      open: console.open,
      interrupts: interrupts.stream,
      grace: _grace,
    ).listen((_) {}, onDone: done.complete);
    await _settle();

    interrupts.add(null);
    await _settle();
    unawaited(console.current.close());
    await _settle();
    // A read that ends again at once, with no new Ctrl-C, is the end.
    unawaited(console.current.close());
    await done.future.timeout(const Duration(seconds: 5));

    expect(console.opened, hasLength(2));
  });

  test('a read that ends while the lines are paused still reopens', () async {
    final console = _FakeConsole();
    final interrupts = StreamController<void>.broadcast();
    final lines = <String>[];
    final sub = consoleLines(
      open: console.open,
      interrupts: interrupts.stream,
      grace: _grace,
    ).listen(lines.add);
    await _settle();

    // The client pauses its input while an exchange runs, which is when the
    // Ctrl-C comes; the end must not wait for the resume.
    sub.pause();
    interrupts.add(null);
    unawaited(console.current.close());
    await _settle(_grace * 3);
    expect(console.opened, hasLength(2));

    console.current.add('next');
    sub.resume();
    await _settle();
    expect(lines, ['next']);
    await sub.cancel();
  });
}
