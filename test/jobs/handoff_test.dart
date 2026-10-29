import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
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

/// A crash simulated inside attach: the hook throws.
final class _Crash implements Exception {
  const _Crash();
}

Future<void> _crash(String id) => Future<void>.error(const _Crash());

/// The records of `meta/handoffs` by launch.
Map<String, Object?> handoffsAt(SessionWriter writer) {
  final value = writer.tree.get(SessionPath.parse('meta/handoffs'));
  return value is Map<String, Object?> ? value : const {};
}

/// The records of `meta/handoffs` of a reopened session.
Map<String, Object?> handoffsOf(Reopened r) => handoffsAt(r.writer);

/// The terminal-state records the journal holds for job [id].
List<JournalRecord> terminalRecords(List<JournalRecord> records, String id) => [
  for (final r in records)
    if (r.path == 'jobs/$id' &&
        r.value is Map<String, Object?> &&
        const {
          'settled',
          'failed',
          'cancelled',
        }.contains((r.value! as Map<String, Object?>)['state']))
      r,
];

void main() {
  final skip = skipWithoutShell();
  const engineTimeout = Timeout(Duration(minutes: 6));

  test('settle waits for re-registered descriptors after rewind', () async {
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
  }, skip: skip);

  test('clear is refused while running and the settle repeats', () async {
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
    expect(
      await h.supervisor.recovery.clearLaunch(handle.launch),
      ClearOutcome.unsettled,
      reason: 'the intent stays while the job reads running',
    );
    pause.release.complete();
    final result = await handle.result;

    expect(result.state, 'settled');
    final settled = h.node(handle.id)!;
    expect(settled['state'], 'settled');
    expect(settled['exit'], 0);
    expect(h.stream(settled, 'stdout'), 'done\n');
    expect(h.at('meta/handoffs/${handle.launch}'), isNull);
  }, skip: skip);

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

  // -- the killed-engine rows ------------------------------------------

  test(
    'crash at each handoff step recovers every stream on attach',
    () async {
      for (final point in [
        'afterIntent',
        'afterStdout',
        'afterPublish',
        'afterRegister',
      ]) {
        final engine = await runEngine('quick', point: point);
        await engine.kill();
        final r = await reopen(engine.dir);
        final path = 'jobs/${engine.jobId}';

        expect(r.node(path)['state'], 'settled', reason: point);
        expect(r.node(path)['exit'], 0, reason: point);
        expect(r.stream(path, 'stdout'), 'out\n', reason: point);
        expect(r.stream(path, 'stderr'), 'err\n', reason: point);
        expect(
          r.stream(path, 'output'),
          allOf(contains('out\n'), contains('err\n')),
          reason: point,
        );
        for (final name in jobStreams) {
          expect(r.complete(path, name), isTrue, reason: '$point $name');
        }
        expect(handoffsOf(r), isEmpty, reason: point);
        expect(r.spools(), isEmpty, reason: point);
        expect(r.runtime.resumed.jobs, 1, reason: point);
      }
    },
    skip: skip,
    timeout: engineTimeout,
  );

  test(
    'second attach registers and settles once',
    () async {
      final engine = await runEngine('hang');
      await engine.kill();
      final writer = await reopenWriter(engine.dir);
      final path = 'jobs/${engine.jobId}';

      // The first attach dies after it recorded the intent and renamed the
      // spools, before it registered a descriptor.
      await expectLater(
        attachTo(writer, hooks: JobHooks(afterPublish: _crash)),
        throwsA(isA<_Crash>()),
      );
      expect(
        (writer.tree.get(SessionPath.parse(path))! as Map)['state'],
        'running',
      );
      final record = handoffsAt(writer).values.single! as Map<String, Object?>;
      expect(record['streams'], isA<Map<String, Object?>>());
      expect(
        writer.tree.get(SessionPath.parse('results')),
        anyOf(isNull, isEmpty),
      );
      await writer.close();

      final r = await reopen(engine.dir);
      expect(r.node(path)['state'], 'cancelled');
      expect(r.node(path)['reason'], 'interrupted');
      expect(terminalRecords(r.records(), engine.jobId), hasLength(1));
      for (final name in jobStreams) {
        expect(r.stream(path, name), name == 'stderr' ? '' : 'started\n');
        expect(r.complete(path, name), isFalse);
      }
      expect(handoffsOf(r), isEmpty);
      expect(r.spools(), isEmpty);
    },
    skip: skip,
    timeout: engineTimeout,
  );

  test(
    'rewind then crash still settles with all three streams',
    () async {
      final engine = await runEngine('quick', point: 'afterRegister');
      await engine.kill();
      final writer = await reopenWriter(engine.dir);
      final path = 'jobs/${engine.jobId}';

      await writer.rewind(4);
      expect(
        (writer.tree.get(SessionPath.parse(path))! as Map)['state'],
        'running',
      );
      expect(
        writer.tree.get(SessionPath.parse('results')),
        anyOf(isNull, isEmpty),
        reason: 'the descriptors went with the rewind',
      );

      final r = await attachTo(writer);
      expect(r.node(path)['state'], 'settled');
      expect(r.node(path)['exit'], 0);
      expect(r.stream(path, 'stdout'), 'out\n');
      expect(r.stream(path, 'stderr'), 'err\n');
      expect(r.stream(path, 'output'), allOf(contains('out'), contains('err')));
      expect(handoffsOf(r), isEmpty);
    },
    skip: skip,
    timeout: engineTimeout,
  );

  test(
    'attach only clears the leftover launch record',
    () async {
      final engine = await runEngine('quick', point: 'beforeClear');
      await engine.kill();
      final writer = await reopenWriter(engine.dir);
      final path = 'jobs/${engine.jobId}';
      final settled = writer.tree.get(SessionPath.parse(path))! as Map;
      expect(settled['state'], 'settled');
      final launch = settled['launch']! as String;
      final before = journalLength(engine.dir);

      final r = await attachTo(writer);
      expect(
        [
          for (final rec in r.records().skip(before))
            '${rec.op.wire} ${rec.path}',
        ],
        ['del meta/handoffs/$launch'],
      );
      expect(r.node(path), settled);
      expect(r.stream(path, 'stdout'), 'out\n');
      expect(r.runtime.resumed.jobs, 0);
      expect(r.runtime.resumed.orphans, 0);
    },
    skip: skip,
    timeout: engineTimeout,
  );

  test('clear succeeds for settled, absent and superseded jobs and repeats harmlessly', () async {
    final h = await JobHarness.create(reconcile: false);
    final done = h.supervisor.start(h.request('echo hi'));
    await done.result;
    expect(h.at('meta/handoffs/${done.launch}'), isNull, reason: 'settled');

    Future<void> record(String launch, String job) async {
      final spools = {for (final s in jobStreams) s: '.spool-$launch-$s'};
      final streams = <String, Object?>{};
      for (final s in jobStreams) {
        final live = await h.store.begin(spools[s]!);
        await live.write(utf8.encode('bytes of $s\n'));
        final d = await live.seal();
        streams[s] = {
          'spool': spools[s],
          'sha256': d.sha256,
          'bytes': d.bytes,
          'lines': d.lines,
          'complete': true,
        };
      }
      await h.writer.apply(
        rec(h.writer.currentTurn, 'meta/handoffs/$launch', Op.set, {
          'job': job,
          'session': h.at('meta/session'),
          'spools': spools,
          'streams': streams,
          'outcome': {'state': 'settled', 'exit': 0},
        }),
      );
    }

    Future<void> node(String id, String launch, String state) => h.writer.apply(
      rec(h.writer.currentTurn, 'jobs/$id', Op.set, {
        'kind': 'shell',
        'cmd': 'x',
        'launch': launch,
        'state': state,
      }),
    );

    await record('l-terminal', 'j-terminal0');
    await node('j-terminal0', 'l-terminal', 'settled');
    await record('l-absent', 'j-absent00');
    await record('l-super', 'j-super000');
    await node('j-super000', 'l-newer', 'running');

    final recovery = h.supervisor.recovery;
    expect(await recovery.clearLaunch('l-absent'), ClearOutcome.unmapped);
    expect(await recovery.clearLaunch('l-super'), ClearOutcome.unmapped);
    expect(await recovery.clearLaunch('l-terminal'), ClearOutcome.cleared);

    final r = await attachTo(h.writer);
    for (final (job, launch) in [
      ('j-absent00', 'l-absent'),
      ('j-super000', 'l-super'),
    ]) {
      final mapping = r.node('meta/orphans/$job/outputs/$launch');
      expect(mapping.keys, unorderedEquals(jobStreams), reason: job);
      for (final s in jobStreams) {
        final entry = mapping[s]! as Map<String, Object?>;
        expect(entry['spool'], '.spool-$launch-$s');
        expect(entry['sha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
        expect(entry['disposition'], 'spooled');
      }
    }
    expect(handoffsOf(r), isEmpty);

    final length = journalLength(h.dir);
    for (final launch in ['l-absent', 'l-super', 'l-terminal']) {
      expect(await recovery.clearLaunch(launch), ClearOutcome.done);
    }
    await attachTo(h.writer);
    expect(journalLength(h.dir), length, reason: 'nothing appended');
  }, skip: skip);

  test(
    'crash around the orphan record keeps the mapping and clears once',
    () async {
      for (final (point, disposition) in [
        ('afterIntent', 'spooled'),
        ('afterPublish', 'published'),
      ]) {
        final engine = await runEngine('quick', point: point);
        await engine.kill();
        final writer = await reopenWriter(engine.dir);
        final id = engine.jobId;
        await writer.rewind(2);
        expect(writer.tree.get(SessionPath.parse('jobs/$id')), isNull);
        final launch = handoffsAt(writer).keys.single;
        final mappingPath = 'meta/orphans/$id/outputs/$launch';
        Object? mapping() => writer.tree.get(SessionPath.parse(mappingPath));

        await expectLater(
          attachTo(writer, hooks: JobHooks(beforeOrphan: _crash)),
          throwsA(isA<_Crash>()),
        );
        expect(mapping(), isNull, reason: '$point before');
        expect(handoffsAt(writer), hasLength(1));

        await expectLater(
          attachTo(writer, hooks: JobHooks(afterOrphan: _crash)),
          throwsA(isA<_Crash>()),
        );
        expect(mapping(), isNotNull, reason: '$point after');
        expect(handoffsAt(writer), hasLength(1));

        final r = await attachTo(writer);
        final entries = r.node(mappingPath);
        expect(entries.keys, unorderedEquals(jobStreams));
        for (final s in jobStreams) {
          final entry = entries[s]! as Map<String, Object?>;
          expect(entry['disposition'], disposition, reason: '$point $s');
          expect(entry['sha256'], matches(RegExp(r'^[0-9a-f]{64}$')));
          final file = File(
            p.join(
              engine.dir.path,
              resultsDirName,
              disposition == 'spooled'
                  ? entry['spool']! as String
                  : entry['sha256']! as String,
            ),
          );
          expect(file.existsSync(), isTrue, reason: '$point $s');
        }
        expect(handoffsOf(r), isEmpty);
        expect(
          r.records().where((rec) => rec.path == mappingPath),
          hasLength(1),
          reason: 'the mapping is recorded once',
        );
        final length = journalLength(engine.dir);
        await attachTo(writer);
        expect(journalLength(engine.dir), length, reason: '$point repeat');
      }
    },
    skip: skip,
    timeout: engineTimeout,
  );

  test(
    'rewind before or during sealing lists spools under meta/orphans',
    () async {
      for (final (mode, point) in [
        ('hang', 'none'),
        ('quick', 'beforeIntent'),
      ]) {
        final engine = await runEngine(mode, point: point);
        await engine.kill();
        final writer = await reopenWriter(engine.dir);
        final id = engine.jobId;
        final launch = handoffsAt(writer).keys.single;
        final spools = (handoffsAt(writer)[launch]! as Map)['spools']! as Map;
        await writer.rewind(2);

        var r = await attachTo(writer);
        expect(r.at('jobs/$id'), isNull, reason: mode);
        final mapping = r.node('meta/orphans/$id/outputs/$launch');
        for (final s in jobStreams) {
          final entry = mapping[s]! as Map<String, Object?>;
          final file = File(
            p.join(engine.dir.path, resultsDirName, entry['spool']! as String),
          );
          expect(entry['spool'], spools[s], reason: '$mode $s');
          expect(entry['disposition'], 'spooled', reason: '$mode $s');
          expect(file.existsSync(), isTrue, reason: '$mode $s');
          expect(
            entry['sha256'],
            sha256.convert(file.readAsBytesSync()).toString(),
          );
        }
        expect(handoffsOf(r), isEmpty, reason: mode);
        await writer.close();

        // Opened a second time, nothing changes and no node comes back.
        final length = journalLength(engine.dir);
        r = await reopen(engine.dir);
        expect(journalLength(engine.dir), length, reason: mode);
        expect(r.at('jobs/$id'), isNull);
        expect(r.spools(), hasLength(3), reason: 'the spools stay findable');
      }
    },
    skip: skip,
    timeout: engineTimeout,
  );

  test('running job without intent is killed within the grace on cancel and rewind', () async {
    const grace = Duration(seconds: 6);
    for (final how in ['cancel', 'rewind']) {
      final h = await JobHarness.create();
      for (var turn = 1; turn <= 3; turn++) {
        await h.writer.apply(rec(turn, 'body/marker', Op.set, turn));
      }
      ShellProcess? started;
      final handle = h.supervisor.start(
        h.request(
          'sleep 30',
          launch: h.recordingLauncher('sleep 30', (s) => started = s),
        ),
      );
      await waitFor(
        () => h.node(handle.id)?['state'] == 'running',
        what: 'the job to run',
      );
      final launchRecord = h.at('meta/handoffs/${handle.launch}')! as Map;
      expect(launchRecord.containsKey('streams'), isFalse, reason: how);
      expect(h.spools(), hasLength(3), reason: how);

      final clock = Stopwatch()..start();
      if (how == 'cancel') {
        expect(await h.supervisor.cancelJob(handle.id), isA<JobCancelled>());
      } else {
        await h.writer.rewind(2);
      }
      await started!.process.exitCode.timeout(
        grace,
        onTimeout: () => fail('$how: the process tree outlived the grace'),
      );
      final result = await handle.result;
      clock.stop();
      expect(clock.elapsed, lessThan(grace), reason: how);

      if (how == 'cancel') {
        final node = h.node(handle.id)!;
        expect(node['state'], 'cancelled');
        expect(node['reason'], 'user');
        for (final name in jobStreams) {
          expect(h.complete(node, name), isFalse, reason: name);
        }
      } else {
        expect(result.stale, isTrue);
        expect(h.node(handle.id), isNull);
        final outputs =
            ((h.at('meta/orphans/${handle.id}')! as Map)['outputs']!
                    as Map)[handle.launch]!
                as Map;
        expect(outputs.keys, unorderedEquals(jobStreams));
      }
      expect(h.at('meta/handoffs/${handle.launch}'), isNull, reason: how);
    }
  }, skip: skip);

  test(
    'cancelled and deadline intents recover complete false',
    () async {
      for (final (mode, reason) in [
        ('cancel', 'user'),
        ('deadline', 'deadline'),
      ]) {
        final engine = await runEngine(mode, point: 'afterIntent');
        await engine.kill();
        final r = await reopen(engine.dir);
        final path = 'jobs/${engine.jobId}';

        expect(r.node(path)['state'], 'cancelled', reason: mode);
        expect(r.node(path)['reason'], reason, reason: mode);
        for (final name in jobStreams) {
          expect(
            r.stream(path, name),
            name == 'stderr' ? '' : 'started\n',
            reason: '$mode $name',
          );
          expect(r.complete(path, name), isFalse, reason: '$mode $name');
        }
        expect(handoffsOf(r), isEmpty, reason: mode);
      }
    },
    skip: skip,
    timeout: engineTimeout,
  );

  test(
    'inherited intent settles cancelled interrupted in the child only',
    () async {
      final pause = Pause();
      final h = await JobHarness.create(
        hooks: JobHooks(afterIntent: pause.call),
        reconcile: false,
      );
      await h.writer.apply(rec(1, 'body/marker', Op.set, 1));
      final go = File(h.marker('go'));
      final handle = h.supervisor.start(
        h.request(
          "echo done; while [ ! -e '${go.path}' ]; do sleep 0.05; done",
        ),
      );
      await waitFor(
        () => h.node(handle.id)?['state'] == 'running',
        what: 'the job to run',
      );
      go.writeAsStringSync('');
      await pause.reached.future;

      final forked = await h.writer.fork(h.writer.currentTurn);
      List<String> parentFiles() => [
        for (final f in Directory(
          p.join(h.dir.path, resultsDirName),
        ).listSync())
          '${p.basename(f.path)}:${(f as File).lengthSync()}',
      ]..sort();
      final before = parentFiles();

      final child = await reopen(forked.childDir);
      final path = 'jobs/${handle.id}';
      expect(child.node(path)['state'], 'cancelled');
      expect(child.node(path)['reason'], 'interrupted');
      expect(child.node(path).containsKey('exit'), isFalse);
      for (final name in jobStreams) {
        final ref = child.node(path)[name];
        expect(ref == null || (ref as Map)['complete'] == false, isTrue);
      }
      expect(handoffsOf(child), isEmpty);
      expect(parentFiles(), before, reason: 'the parent files are untouched');
      expect(
        h.at('meta/handoffs/${handle.launch}'),
        isA<Map<String, Object?>>(),
        reason: 'the parent keeps its own intent',
      );

      pause.release.complete();
      final result = await handle.result;
      expect(result.state, 'settled');
      expect(h.node(handle.id)!['state'], 'settled');
      expect(h.node(handle.id)!['exit'], 0);
      expect(h.stream(h.node(handle.id)!, 'stdout'), 'done\n');
      expect(h.at('meta/handoffs/${handle.launch}'), isNull);
    },
    skip: skip,
  );

  test(
    'subscriber, job tool and fork see no unresolvable handle at each pause',
    () async {
      final first = Pause();
      final second = Pause();
      final h = await JobHarness.create(reconcile: false);
      final r = await attachTo(
        h.writer,
        hooks: JobHooks(afterIntent: first.call, afterPublish: second.call),
      );
      final seen = <CommittedUpdate>[];
      final sub = h.writer.subscribe().listen(seen.add);
      addTearDown(sub.cancel);
      await h.writer.apply(rec(1, 'body/marker', Op.set, 1));
      final go = File(h.marker('go'));
      final handle = r.runtime.jobs.start(
        h.request(
          "echo done; while [ ! -e '${go.path}' ]; do sleep 0.05; done",
        ),
      );
      final id = handle.id;
      await waitFor(
        () => h.node(id)?['state'] == 'running',
        what: 'the job to run',
      );
      go.writeAsStringSync('');

      Future<void> consumers(String where) async {
        final node = h.node(id)!;
        expect(node['state'], 'running', reason: where);
        for (final name in jobStreams) {
          expect(node.containsKey(name), isFalse, reason: '$where $name');
        }
        await Future<void>.delayed(Duration.zero);
        for (final update in seen) {
          final value = update.record.value;
          if (update.record.path == 'jobs/$id' && value is Map) {
            for (final name in jobStreams) {
              expect(value.containsKey(name), isFalse, reason: where);
            }
          }
        }
        for (final action in ['status', 'output']) {
          final out = await r.runtime.run(
            ToolCall(
              callId: '$where-$action',
              name: 'job',
              argumentsJson: jsonEncode({'action': action, 'id': id}),
            ),
          );
          expect(out.output, isNot(contains('unavailable')), reason: where);
          expect(out.output, isNot(contains('unknown handle')), reason: where);
          expect(out.output, isNot(contains('tool error')), reason: where);
          expect(
            out.output,
            contains(action == 'status' ? 'job $id' : 'output so far'),
            reason: '$where $action',
          );
        }
        final forked = await h.writer.fork(h.writer.currentTurn);
        final tree = materialize(forked.childDir).tree;
        final results = tree.get(SessionPath.parse('results'));
        for (final entry in (results is Map ? results.values : const [])) {
          final handleText = (entry! as Map)['handle']! as String;
          expect(
            () => resolveHandle(tree, forked.childDir, handleText),
            returnsNormally,
            reason: '$where $handleText',
          );
        }
      }

      await first.reached.future;
      await consumers('afterIntent');
      first.release.complete();
      await second.reached.future;
      await consumers('afterPublish');
      second.release.complete();

      expect((await handle.result).state, 'settled');
      final settled = h.node(id)!;
      for (final name in jobStreams) {
        expect(
          h.stream(settled, name),
          name == 'stderr' ? '' : 'done\n',
          reason: name,
        );
      }
    },
    skip: skip,
  );
}
