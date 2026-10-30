import 'dart:async';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/session_support.dart';

void main() {
  late Directory root;
  setUp(() async {
    root = await tempDir();
  });

  test('128 concurrent gated operations never exceed 48 in the writer, run in '
      'FIFO order and never raise writer busy', () async {
    final (writer, io) = await createHooked(root);
    final release = Completer<void>();
    io.beforeFlush = () => release.future;
    final gate = WriteGate();
    var inWriter = 0;
    var peak = 0;
    final errors = <Object>[];

    final all = [
      for (var i = 0; i < 128; i++)
        gate
            .run(() async {
              inWriter++;
              if (inWriter > peak) peak = inWriter;
              try {
                await writer.apply(rec(1, 'body/n$i', Op.set, i));
              } finally {
                inWriter--;
              }
            })
            .catchError(errors.add),
    ];
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(peak, lessThanOrEqualTo(48));
    expect(peak, 48, reason: 'the gate fills before it holds back');
    release.complete();
    await Future.wait(all);

    expect(errors, isEmpty);
    expect(peak, lessThanOrEqualTo(48));
    final order = [
      for (final line in journalOf(writer.sessionDir).readAsLinesSync())
        JournalRecord.parse(line).path,
    ].where((path) => path.startsWith('body/n')).toList();
    expect(order, [for (var i = 0; i < 128; i++) 'body/n$i']);
  });
}
