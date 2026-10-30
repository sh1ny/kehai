// Feedback round 2: a hook named by a bare program resolves only outside the
// workspace, like every other launcher, so a checkout cannot supply it.
@TestOn('!windows')
library;

import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/job_support.dart' show skipWithoutShell;
import '../support/session_support.dart';

void main() {
  late Directory ws;
  late String marker;
  late JobSupervisor jobs;
  late ResultStore store;

  setUp(() async {
    final root = Directory((await tempDir()).resolveSymbolicLinksSync());
    ws = Directory(p.join(root.path, 'ws'))..createSync();
    marker = p.join(root.path, 'marker');
    final writer = await createWriter(await tempDir());
    store = ResultStore(writer.sessionDir);
    jobs = JobSupervisor(writer, store);
    addTearDown(jobs.close);
  });

  /// Plants an executable `kehai-hook` in the workspace that leaves [marker].
  void plant(String dir) {
    final file = File(p.join(ws.path, dir, 'kehai-hook'))
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\ntouch "$marker"\nexit 2\n');
    Process.runSync('chmod', ['755', file.path]);
  }

  HookStage stage(String path, HookPolicy policy) => HookStage(
    hooks: [
      HookConfig(
        name: 'h',
        argv: const ['kehai-hook'],
        tools: const ['bash'],
        policy: policy,
        timeout: const Duration(seconds: 30),
      ),
    ],
    jobs: jobs,
    store: store,
    workspace: ws.path,
    environment: {'PATH': '$path:${Platform.environment['PATH']}'},
    session: () => 's',
  );

  const call = StageCall(
    tool: 'bash',
    callKey: 'c1',
    callId: 'c1',
    input: {'command': 'ls'},
  );

  for (final (label, entry) in [
    ('an absolute PATH entry inside the workspace', null),
    ('a relative PATH entry', 'bin'),
  ]) {
    test('$label never supplies the hook program', () async {
      plant('bin');

      final outcome = await stage(
        entry ?? p.join(ws.path, 'bin'),
        HookPolicy.deny,
      ).check(call, CancelToken());

      expect(File(marker).existsSync(), isFalse);
      expect(outcome.denyReason, contains('could not start'));
      expect(outcome.denyReason, contains('kehai-hook'));
    }, skip: skipWithoutShell());
  }

  test('an optional hook that does not resolve is a visible no-op', () async {
    plant('bin');

    final outcome = await stage(
      p.join(ws.path, 'bin'),
      HookPolicy.optional,
    ).check(call, CancelToken());

    expect(File(marker).existsSync(), isFalse);
    expect(outcome.denyReason, isNull);
    expect(outcome.diag.single.$2, contains('could not start'));
  }, skip: skipWithoutShell());
}
