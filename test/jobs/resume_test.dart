import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/job_support.dart';
import '../support/session_support.dart';

const Timeout _engineTimeout = Timeout(Duration(minutes: 6));

/// The bytes the call node [path] of [r] stored as its result.
String _callText(Reopened r, String path) {
  final handle = (r.node(path)['result']! as Map<String, Object?>)['handle'];
  return utf8.decode(
    resolveHandle(
      r.writer.tree,
      r.writer.sessionDir,
      handle! as String,
    ).file.readAsBytesSync(),
  );
}

void main() {
  final skip = skipWithoutShell();

  test(
    'killed engine reopens with call and job cancelled interrupted, not rerun',
    () async {
      final engine = await runEngine('bash');
      final counter = File(p.join(engine.dir.parent.path, 'count'));
      await engine.kill();
      final writer = await reopenWriter(engine.dir);
      final callPath = 'body/calls/${callKey('call-1')}';
      final jobPath = 'jobs/${engine.jobId}';
      expect(
        (writer.tree.get(SessionPath.parse(callPath))! as Map)['status'],
        'running',
      );
      expect(
        (writer.tree.get(SessionPath.parse(jobPath))! as Map)['state'],
        'running',
      );
      final runs = counter.readAsLinesSync().length;
      expect(runs, 1);

      final r = await attachTo(writer);

      // Both nodes are final before the first call can be admitted.
      expect(r.node(callPath)['status'], 'cancelled');
      expect(r.node(callPath)['reason'], 'interrupted');
      expect(r.node(callPath)['envelope'], 'error');
      expect((r.node(callPath)['result']! as Map)['complete'], isFalse);
      expect(r.node(jobPath)['state'], 'cancelled');
      expect(r.node(jobPath)['reason'], 'interrupted');
      expect(r.stream(jobPath, 'output'), 'started\n');
      expect(r.complete(jobPath, 'output'), isFalse);
      expect(r.runtime.resumed.finalized, 2);
      expect(r.runtime.resumed.calls, 1);
      expect(r.runtime.resumed.jobs, 1);
      expect(r.runtime.resumed.warning, contains('may still run'));
      final text = _callText(r, callPath);
      expect(
        text,
        startsWith(
          'interrupted: the engine stopped while this call was running; '
          'effects uncertain',
        ),
      );
      expect(
        text,
        contains((r.node(jobPath)['output']! as Map)['handle']! as String),
        reason: 'the result points at the job output',
      );
      expect(counter.readAsLinesSync().length, runs, reason: 'not rerun');
    },
    skip: skip,
    timeout: _engineTimeout,
  );

  test('pending call gets an interrupted result with complete false', () async {
    final root = await tempDir();
    final first = await SessionWriter.create(root);
    final key = callKey('call-pending');
    await first.apply(
      rec(1, 'body/calls/$key', Op.set, {
        'tool': 'bash',
        'version': 1,
        'callId': 'call-pending',
        'attempt': 'a1',
        'input': {'command': 'echo hi'},
        'status': 'pending',
      }),
    );
    await first.close();

    final r = await reopen(first.sessionDir);
    final node = r.node('body/calls/$key');
    expect(node['status'], 'cancelled');
    expect(node['reason'], 'interrupted');
    expect(node['envelope'], 'error');
    final result = node['result']! as Map<String, Object?>;
    expect(result['complete'], isFalse);
    final text = _callText(r, 'body/calls/$key');
    expect(text, contains('interrupted'));
    expect(text, contains('pending'));
    expect(text, contains('effects uncertain'));
    expect(r.runtime.resumed.calls, 1);
    expect(r.runtime.resumed.jobs, 0);
  });

  test(
    'spooled 300 lines are adopted complete false and the spool is gone',
    () async {
      final engine = await runEngine('lines');
      await engine.kill();
      final r = await reopen(engine.dir);
      final path = 'jobs/${engine.jobId}';

      expect(r.node(path)['state'], 'cancelled');
      expect(r.node(path)['reason'], 'interrupted');
      for (final name in ['stdout', 'output']) {
        final text = r.stream(path, name);
        expect(
          '\n'.allMatches(text).length,
          greaterThanOrEqualTo(300),
          reason: name,
        );
        expect(text, startsWith('line0\n'));
        expect(r.complete(path, name), isFalse, reason: name);
      }
      expect(r.spools(), isEmpty);
      expect(
        r.runtime.resumed.leftovers,
        0,
        reason: 'every result file is named by a reference',
      );
    },
    skip: skip,
    timeout: _engineTimeout,
  );

  test('fork child finalizes its copy while the parent job runs on', () async {
    final h = await JobHarness.create();
    await h.writer.apply(rec(1, 'body/marker', Op.set, 1));
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
    final parentNode = h.node(handle.id)!;
    final forked = await h.writer.fork(h.writer.currentTurn);

    final child = await reopen(forked.childDir);
    final path = 'jobs/${handle.id}';
    expect(child.node(path)['state'], 'cancelled');
    expect(child.node(path)['reason'], 'interrupted');
    expect(
      child.node(path)['absent'],
      unorderedEquals(jobStreams),
      reason: 'the child has none of the parent spool files',
    );
    expect(child.at('meta/handoffs'), anyOf(isNull, isEmpty));
    expect(child.runtime.resumed.jobs, 1);

    // The parent's job runs on, and its node is unchanged.
    expect(h.node(handle.id), parentNode);
    final ended = await Future.any<bool>([
      started!.process.exitCode.then((_) => true),
      Future<bool>.delayed(const Duration(milliseconds: 500), () => false),
    ]);
    expect(ended, isFalse, reason: 'the parent process was not touched');
    expect(h.at('meta/handoffs/${handle.launch}'), isA<Map<String, Object?>>());
  }, skip: skip);

  test(
    'storage error during finalization fails attach and admits nothing',
    () async {
      final root = await tempDir();
      final first = await SessionWriter.create(root);
      final key = callKey('call-1');
      await first.apply(
        rec(1, 'body/calls/$key', Op.set, {
          'tool': 'bash',
          'version': 1,
          'callId': 'call-1',
          'attempt': 'a1',
          'input': {'command': 'echo hi'},
          'status': 'running',
        }),
      );
      await first.close();

      late HookedIo io;
      final writer = await SessionWriter.open(
        first.sessionDir,
        decorate: (inner) => io = HookedIo(inner),
      );
      addTearDown(writer.close);
      io.onWrite = (_) async => throw const FileSystemException('disk full');

      await expectLater(attachTo(writer), throwsA(isA<StorageError>()));
      expect(writer.state, WriterState.broken);
      expect(
        (writer.tree.get(SessionPath.parse('body/calls/$key'))!
            as Map)['status'],
        'running',
        reason: 'nothing was finalized',
      );
    },
  );
}
