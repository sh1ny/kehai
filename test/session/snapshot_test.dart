import 'dart:async';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/session_support.dart';

void main() {
  late Directory root;
  setUp(() async => root = await tempDir());

  group('record values are snapshotted', () {
    test('mutation during the flush changes neither tree nor replay', () async {
      final (writer, io) = await createHooked(root);
      final entered = Completer<void>();
      final release = Completer<void>();
      io.beforeFlush = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };

      final value = <String, Object?>{
        'x': 1,
        'list': <Object?>[
          1,
          <String, Object?>{'deep': 'a'},
        ],
      };
      final pending = writer.apply(rec(1, 'body/a', Op.set, value));
      await entered.future;
      value['x'] = 2;
      (value['list']! as List<Object?>).add('late');
      ((value['list']! as List<Object?>)[1]! as Map)['deep'] = 'b';
      io.beforeFlush = null;
      release.complete();
      final update = await pending;

      final persisted = {
        'x': 1,
        'list': [
          1,
          {'deep': 'a'},
        ],
      };
      expect(update.record.value, persisted);
      expect(writer.tree.toJson()['body'], {'a': persisted});
      expect(materialize(writer.sessionDir).tree.toJson()['body'], {
        'a': persisted,
      });

      await writer.apply(rec(2, 'body/b', Op.set, 1));
      await writer.rewind(1);
      expect(writer.tree.toJson()['body'], {'a': persisted});

      final child = await writer.fork(1);
      expect(materialize(child.childDir).tree.toJson()['body'], {
        'a': persisted,
      });
    });

    test('mutation while the record is queued has no effect', () async {
      final (writer, io) = await createHooked(root);
      final entered = Completer<void>();
      final release = Completer<void>();
      io.beforeFlush = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final first = writer.apply(rec(1, 'body/a', Op.set, 1));
      await entered.future;
      final value = <String, Object?>{'x': 1};
      final queued = writer.apply(rec(1, 'body/q', Op.set, value));
      value['x'] = 2;
      io.beforeFlush = null;
      release.complete();
      await first;
      await queued;

      expect(writer.tree.toJson()['body'], {
        'a': 1,
        'q': {'x': 1},
      });
      expect(materialize(writer.sessionDir).tree.toJson()['body'], {
        'a': 1,
        'q': {'x': 1},
      });
    });

    test('mutation after the ack cannot change rewind or fork', () async {
      final writer = await createWriter(root);
      final seen = <CommittedUpdate>[];
      final sub = writer.subscribe().listen(seen.add);
      addTearDown(sub.cancel);

      final value = <String, Object?>{'x': 1};
      final update = await writer.apply(rec(1, 'body/a', Op.set, value));
      value['x'] = 2;
      await writer.apply(rec(2, 'body/b', Op.set, 1));
      await pumpEventQueue();

      expect(
        () => (update.record.value! as Map<Object?, Object?>)['x'] = 3,
        throwsUnsupportedError,
      );
      expect(
        () => (seen.first.record.value! as Map<Object?, Object?>)['y'] = 3,
        throwsUnsupportedError,
      );

      await writer.rewind(1);
      expect(writer.tree.toJson()['body'], {
        'a': {'x': 1},
      });
      final child = await writer.fork(1);
      expect(materialize(child.childDir).tree.toJson()['body'], {
        'a': {'x': 1},
      });
      expect(materialize(writer.sessionDir).tree.toJson()['body'], {
        'a': {'x': 1},
      });
    });

    test('outcome of a settled request is snapshotted', () async {
      final writer = await createWriter(root);
      await writer.admit('r1', 'fp');
      final outcome = <String, Object?>{'ok': true};
      final update = await writer.complete('r1', outcome);
      outcome['ok'] = false;
      expect(
        () => ((update.record.value! as Map)['outcome']! as Map)['ok'] = false,
        throwsUnsupportedError,
      );
      expect(
        writer.tree.toJson()['meta'],
        containsPair(
          'requests',
          containsPair('r1', containsPair('outcome', {'ok': true})),
        ),
      );
    });
  });
}
