import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/session_support.dart';

void main() {
  late Directory root;
  late SessionWriter writer;
  setUp(() async {
    root = await tempDir();
    writer = await createWriter(root);
  });

  Future<void> advanceTo(int turn) async {
    for (var t = 1; t <= turn; t++) {
      await writer.apply(rec(t, 'body/t$t', Op.set, t));
    }
  }

  group('turn rule', () {
    test('turns advance by one', () async {
      await advanceTo(3);
      expect(writer.currentTurn, 3);
      await writer.apply(rec(3, 'body/same', Op.set, 1));
      expect(writer.currentTurn, 3);
      final update = await writer.apply(rec(4, 'body/next', Op.set, 1));
      expect(update.record.turn, 4);
      expect(writer.currentTurn, 4);
    });

    test('skipped or past turn is rejected', () async {
      await advanceTo(3);
      final length = journalOf(writer.sessionDir).lengthSync();
      for (final turn in [5, 2]) {
        await expectLater(
          writer.apply(rec(turn, 'body/x', Op.set, 1)),
          throwsA(
            isA<SessionError>()
                .having((e) => e.reason, 'reason', 'invalid turn')
                .having((e) => e.message, 'message', contains('3 or 4')),
          ),
        );
      }
      expect(journalOf(writer.sessionDir).lengthSync(), length);
      expect(writer.currentTurn, 3);
    });
  });
}
