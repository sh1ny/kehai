import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/mutation_support.dart';

void main() {
  test(
    'present null durable watermark cannot permit filesystem mutation',
    () async {
      final h = await MutationHarness.create();
      final file = h.file('target.txt', 'before\n');
      await h.write('valid-watermark', 'target.txt', 'recorded\n');
      expect(file.readAsStringSync(), 'recorded\n');
      await h.writer.apply(
        JournalRecord(
          turn: h.writer.currentTurn,
          path: 'meta/vcs/seqHigh',
          op: Op.set,
          value: null,
        ),
      );

      await h.write('invalid-watermark', 'target.txt', 'after\n');

      expect(file.readAsStringSync(), 'recorded\n');
      expect(h.call('invalid-watermark')['target'], isNull);
    },
  );
}
