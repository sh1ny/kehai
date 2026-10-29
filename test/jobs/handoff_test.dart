import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/job_support.dart';
import '../support/session_support.dart';

/// Starts a job in turn 3 that ends once the returned `go` file exists, and
/// moves the session to turn 5 before it does.
Future<(JobHarness, JobHandle, File)> _startInTurn3(JobHooks hooks) async {
  final h = await JobHarness.create(hooks: hooks);
  for (var turn = 1; turn <= 3; turn++) {
    await h.writer.apply(rec(turn, 'body/marker', Op.set, turn));
  }
  final go = File(h.marker('go'));
  final handle = h.supervisor.start(
    h.request("echo done; while [ ! -e '${go.path}' ]; do sleep 0.05; done"),
  );
  await waitFor(
    () => h.node(handle.id)?['state'] == 'running',
    what: 'the job to run',
  );
  for (var turn = 4; turn <= 5; turn++) {
    await h.writer.apply(rec(turn, 'body/marker', Op.set, turn));
  }
  return (h, handle, go);
}

void main() {
  final skip = skipWithoutShell();

  test(
    'rewind between registration and settling registers the descriptors again',
    () async {
      final pause = Pause();
      final (h, handle, go) = await _startInTurn3(
        JobHooks(afterRegister: pause.call),
      );
      go.writeAsStringSync('');
      await pause.reached.future;
      final node = h.node(handle.id)!;
      expect(node['state'], 'running', reason: 'no reference before settle');
      expect(node.containsKey('stdout'), isFalse);

      await h.writer.rewind(4);
      expect(h.node(handle.id)!['state'], 'running', reason: 'the job is kept');
      pause.release.complete();
      final result = await handle.result;

      expect(result.state, 'settled');
      final settled = h.node(handle.id)!;
      expect(settled['state'], 'settled');
      expect(settled['exit'], 0);
      expect(h.stream(settled, 'stdout'), 'done\n');
      expect(h.stream(settled, 'output'), 'done\n');
      expect(h.at('meta/handoffs/${handle.launch}'), isNull);
      final forked = await h.writer.fork(h.writer.currentTurn);
      final child = materialize(forked.childDir).tree;
      for (final name in jobStreams) {
        final handleText =
            (settled[name]! as Map<String, Object?>)['handle']! as String;
        expect(
          resolveHandle(child, forked.childDir, handleText).descriptor.bytes,
          greaterThanOrEqualTo(0),
        );
      }
    },
    skip: skip,
  );

  test(
    'rewind between settling and clearing settles again before the intent goes',
    () async {
      final pause = Pause();
      final (h, handle, go) = await _startInTurn3(
        JobHooks(beforeClear: pause.call),
      );
      go.writeAsStringSync('');
      await pause.reached.future;
      expect(h.node(handle.id)!['state'], 'settled');

      await h.writer.rewind(4);
      expect(h.node(handle.id)!['state'], 'running', reason: 'settle undone');
      final record = h.at('meta/handoffs/${handle.launch}');
      expect(record, isA<Map<String, Object?>>());
      pause.release.complete();
      final result = await handle.result;

      expect(result.state, 'settled');
      final settled = h.node(handle.id)!;
      expect(settled['state'], 'settled');
      expect(settled['exit'], 0);
      expect(h.stream(settled, 'stdout'), 'done\n');
      expect(h.at('meta/handoffs/${handle.launch}'), isNull);
    },
    skip: skip,
  );

  test(
    'output so far is stored from a running job without stopping it',
    () async {
      final h = await JobHarness.create();
      final go = File(h.marker('go'));
      final handle = h.supervisor.start(
        h.request(
          "echo early; while [ ! -e '${go.path}' ]; do sleep 0.05; done",
        ),
      );
      await waitFor(
        () => h.node(handle.id)?['state'] == 'running',
        what: 'the job to run',
      );
      ResultWrite? snap;
      for (var i = 0; i < 400; i++) {
        snap = await h.supervisor.snapshot(handle.id, 'output');
        if (snap is ResultComplete && snap.descriptor.bytes > 0) break;
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(snap, isA<ResultComplete>());
      expect((snap! as ResultComplete).descriptor.bytes, 6);

      go.writeAsStringSync('');
      expect((await handle.result).state, 'settled');
      expect(await h.supervisor.snapshot(handle.id, 'output'), isNull);
    },
    skip: skip,
  );
}
