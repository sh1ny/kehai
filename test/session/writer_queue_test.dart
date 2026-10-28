import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/session_support.dart';

void main() {
  late Directory root;
  setUp(() async => root = await tempDir());

  group('writer queue', () {
    test('burst of 32 operations is ordered for all subscribers', () async {
      final (writer, io) = await createHooked(root);
      io.skipFlush = true;
      final first = writer.subscribe().toList();
      final second = writer.subscribe().toList();

      final results = await Future.wait([
        for (var i = 0; i < 32; i++)
          writer.apply(rec(1, 'body/k$i', Op.set, i)),
      ]);
      await writer.close();

      final paths = [for (var i = 0; i < 32; i++) 'body/k$i'];
      expect([for (final u in results) u.record.path], paths);
      for (final got in [await first, await second]) {
        expect([for (final u in got) u.record.path], paths);
        expect(
          [for (final u in got) u.offset],
          [for (final u in results) u.offset],
        );
      }
      final lines = journalOf(writer.sessionDir).readAsLinesSync();
      expect(lines, hasLength(33));
      expect([
        for (final l in lines.skip(1)) JournalRecord.parse(l).path,
      ], paths);
    });

    test(
      'full queue rejects with writer busy and slow subscriber resyncs',
      () async {
        final (writer, io) = await createHooked(root);
        io.skipFlush = true;

        // Operation 65 is rejected synchronously and never queued.
        final accepted = [
          for (var i = 0; i < 64; i++)
            writer.apply(rec(1, 'body/k$i', Op.set, i)),
        ];
        expect(
          () => writer.apply(rec(1, 'body/overflow', Op.set, 1)),
          throwsA(
            isA<SessionError>()
                .having((e) => e.reason, 'reason', 'writer busy')
                .having((e) => e.path, 'path', 'body/overflow'),
          ),
        );
        await Future.wait(accepted);
        expect(journalOf(writer.sessionDir).readAsLinesSync(), hasLength(65));
        expect(
          writer.tree.contains(SessionPath.parse('body/overflow')),
          isFalse,
        );

        // A paused subscriber overflows at 1,024 updates; others continue.
        final healthy = <CommittedUpdate>[];
        final healthySub = writer.subscribe().listen(healthy.add);
        final received = <CommittedUpdate>[];
        Object? failure;
        final done = Future<void>.delayed(Duration.zero);
        final slow = writer.subscribe();
        final slowSub = slow.listen(
          received.add,
          onError: (Object e) => failure = e,
        )..pause();
        await done;

        for (var i = 0; i < 1025; i++) {
          await writer.apply(rec(2, 'body/s$i', Op.set, i));
        }
        expect(writer.state, WriterState.ready);
        await pumpEventQueue();
        expect(healthy, hasLength(1025));

        slowSub.resume();
        await pumpEventQueue();
        expect(received, hasLength(1024));
        expect(
          failure,
          isA<ResyncRequired>().having(
            (e) => e.lastOffset,
            'lastOffset',
            received.last.offset,
          ),
        );

        await writer.apply(rec(2, 'body/after', Op.set, 1));
        await pumpEventQueue();
        expect(healthy, hasLength(1026));
        await healthySub.cancel();
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });
}
