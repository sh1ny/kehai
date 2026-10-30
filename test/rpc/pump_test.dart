import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/fake_provider.dart';
import '../support/rpc_support.dart';
import '../support/session_support.dart';

/// An output sink that a test can stall: while stalled, flushes do not
/// complete, whatever the OS pipe buffers would hold.
final class _Wire {
  _Wire() {
    _sub = _controller.stream.listen(
      (bytes) => _text.write(utf8.decode(bytes)),
    );
    sink = IOSink(_controller);
  }

  final StreamController<List<int>> _controller = StreamController();
  final StringBuffer _text = StringBuffer();
  late final StreamSubscription<List<int>> _sub;
  late final IOSink sink;

  void stall() => _sub.pause();

  void resume() => _sub.resume();

  /// The events written so far.
  List<Map<String, Object?>> get events => [
    for (final line in const LineSplitter().convert(_text.toString()))
      jsonDecode(line) as Map<String, Object?>,
  ];
}

Map<String, Object?> _update(int offset) => updateEvent(offset, {
  'turn': 1,
  'path': 'body/n$offset',
  'op': 'set',
  'value': offset,
});

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

void main() {
  group('Resync of a slow client', () {
    test('stalled reader gets resync and snapshot then converges', () async {
      final rig = await rpcRig(
        FakeProvider.steps(const []),
        limits: const PumpLimits(droppable: 4096, batch: 1024),
      );
      await rig.nextOfType('snapshot');
      rig.stallOutput();

      for (var i = 0; i < 300; i++) {
        await rig.writer.apply(rec(1, 'body/n$i', Op.set, {'i': i}));
      }
      rig.resumeOutput();

      await expectConverges(rig);
      final resyncs = rig.ofType('resync');
      expect(resyncs, hasLength(1));
      final at = rig.events.indexOf(resyncs.single);
      final snapshot = rig.events[at + 1];
      expect(snapshot['type'], 'snapshot');
      expect(rig.ofType('update').length, lessThan(300));

      await rig.writer.apply(rec(1, 'body/after', Op.set, 'tail'));
      await expectConverges(rig);
      final last = rig.ofType('update').last;
      expect(last['offset'], greaterThanOrEqualTo(snapshot['offset']! as int));
      expect(rig.ofType('resync'), hasLength(1));
    });

    test(
      'three overflows keep one pending resync with the latest tree',
      () async {
        var latest = 0;
        final wire = _Wire();
        final pump = OutputPump(
          wire.sink,
          limits: const PumpLimits(droppable: 300, batch: 1),
          resync: () => [
            {'type': 'resync'},
            snapshotEvent(offset: latest, turn: 1, tree: {'n': latest}),
          ],
        );
        wire.stall();
        pump.send({'type': 'hello'});
        await _settle();

        for (var round = 1; round <= 3; round++) {
          latest = round;
          for (var i = 0; i < 20; i++) {
            pump.send(_update(i), droppable: true);
          }
          pump.requestResync();
          expect(pump.resyncPending, isTrue);
        }
        wire.resume();
        await pump.flush();

        expect(wire.events.map((e) => e['type']), [
          'hello',
          'resync',
          'snapshot',
        ]);
        expect(
          (wire.events.last['tree']! as Map<String, Object?>)['n'],
          3,
          reason: 'the snapshot is taken when it is written',
        );
        expect(pump.resyncPending, isFalse);
      },
    );

    test('1 MiB of pending replies pauses stdin reading', () async {
      final rig = await rpcRig(FakeProvider.steps(const []));
      await rig.nextOfType('snapshot');
      rig.stallOutput();

      final id = 'a' * 128;
      final line = '${jsonEncode({'type': 'status', 'id': id})}\n';
      const count = 8000;
      rig.sendBytes(utf8.encode(line * count));
      rig.send({'type': 'status', 'id': 'tail'});

      const limit = 1024 * 1024;
      final deadline = DateTime.now().add(const Duration(seconds: 20));
      while (rig.server.pendingReliableBytes <= limit) {
        if (DateTime.now().isAfter(deadline)) {
          fail('the replies never piled up');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      await _settle();
      final pending = rig.server.pendingReliableBytes;
      await _settle();

      expect(rig.server.pendingReliableBytes, pending, reason: 'input paused');
      expect(pending, lessThan(limit + 1024), reason: 'limit plus one reply');
      expect(rig.inputPaused, isTrue);

      rig.resumeOutput();
      final tail = await rig.answerTo('tail');
      expect(tail['state'], 'not-admitted');
      expect(
        rig.ofType('reply').where((e) => e['to'] == id),
        hasLength(count),
        reason: 'replies are never dropped',
      );
      expect(rig.server.pendingReliableBytes, 0);
      expect(rig.inputPaused, isFalse);
    });

    test('prompt reader never gets resync', () async {
      final rig = await rpcRig(
        FakeProvider.steps(const []),
        limits: const PumpLimits(droppable: 128 * 1024, batch: 4096),
      );
      await rig.nextOfType('snapshot');

      for (var i = 0; i < 2000; i++) {
        await rig.writer.apply(rec(1, 'body/n$i', Op.set, {'i': i}));
      }

      await expectConverges(rig);
      expect(rig.ofType('resync'), isEmpty);
      expect(rig.ofType('update'), hasLength(2000));
    });
  });
}
