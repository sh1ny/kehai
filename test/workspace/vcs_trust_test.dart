import 'dart:async';
import 'dart:io';

import 'package:kehai/src/loop/sensorium.dart';
import 'package:kehai/src/session/mutations.dart';
import 'package:kehai/src/workspace/vcs_collector.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/vcs_support.dart';

void main() {
  for (final scenario in const [
    (name: 'git auto', git: true, jj: false, backend: 'auto'),
    (name: 'git forced', git: true, jj: false, backend: 'git'),
    (name: 'jj auto', git: false, jj: true, backend: 'auto'),
    (name: 'jj forced', git: false, jj: true, backend: 'jj'),
    (name: 'colocated auto', git: true, jj: true, backend: 'auto'),
    (name: 'colocated forced git', git: true, jj: true, backend: 'git'),
    (name: 'colocated forced jj', git: true, jj: true, backend: 'jj'),
  ]) {
    test(
      'untrusted repository starts no VCS process: ${scenario.name}',
      () async {
        final workspace = VcsWorkspace.create(
          git: scenario.git,
          jj: scenario.jj,
        );
        addTearDown(workspace.dispose);
        final runner = scenario.jj && scenario.backend != 'git'
            ? fakeJjRunner()
            : fakeGitRunner();
        final scheduler = ManualVcsDeadlineScheduler();
        final sequence = MutationSequence(0);
        var reads = 0;
        final collector = VcsCollector(
          processRunner: runner,
          deadlineScheduler: scheduler,
          readFile: (_, _) async {
            reads++;
            return null;
          },
        );
        addTearDown(collector.close);

        final result = await collector.collect(
          root: workspace.root,
          backend: scenario.backend,
          attribution: (
            effects: const {'tracked.txt': 'hash'},
            sequence: sequence,
            jobsLive: false,
          ),
        );

        expect(runner.invocations, isEmpty);
        expect(scheduler.durations, isEmpty);
        expect(sequence.high, 0);
        expect(reads, 0);
        expect(result.observation, isA<SensoriumUnavailable<SensoriumVcs>>());
        expect(result.reason, 'trust required');
        expect(result.baseline, isNull);
        expect(result.captureCompleted, isFalse);
      },
    );
  }

  test(
    'startup without a repository never authorizes a later repository',
    () async {
      final workspace = VcsWorkspace.create();
      addTearDown(workspace.dispose);
      final trust = VcsTrust.grant(root: workspace.root);
      final runner = fakeGitRunner();
      final collector = VcsCollector(trust: trust, processRunner: runner);
      addTearDown(collector.close);
      expect(
        (await collector.collect(root: workspace.root)).reason,
        'no repository',
      );
      Directory(p.join(workspace.root, '.git')).createSync();
      expect(
        (await collector.collect(root: workspace.root)).reason,
        'trust required',
      );
      expect(runner.invocations, isEmpty);
    },
  );

  test(
    'changed backend and marker kind revoke even after restoration',
    () async {
      for (final change in ['backend', 'marker', 'absent']) {
        final workspace = VcsWorkspace.create(git: true);
        addTearDown(workspace.dispose);
        final runner = fakeGitRunner();
        final collector = VcsCollector(
          trust: VcsTrust.grant(root: workspace.root),
          processRunner: runner,
        );
        addTearDown(collector.close);
        final marker = Directory(p.join(workspace.root, '.git'));
        if (change == 'backend') {
          Directory(p.join(workspace.root, '.jj')).createSync();
        } else {
          marker.deleteSync(recursive: true);
          if (change == 'marker') {
            File(marker.path).writeAsStringSync('gitdir: elsewhere');
          }
        }
        final changed = await collector.collect(root: workspace.root);
        expect(
          changed.reason,
          change == 'absent' ? 'no repository' : 'trust required',
        );
        if (change == 'backend') {
          Directory(p.join(workspace.root, '.jj')).deleteSync();
        } else {
          if (change == 'marker') File(marker.path).deleteSync();
          marker.createSync();
        }
        expect(
          (await collector.collect(root: workspace.root)).reason,
          'trust required',
        );
        expect(runner.invocations, isEmpty);
      }
    },
  );

  test('inherited binding cannot authorize a different selection', () async {
    final workspace = VcsWorkspace.create(git: true);
    addTearDown(workspace.dispose);
    final parent = VcsTrust.grant(root: workspace.root);
    final binding = parent.childBinding(root: workspace.root, backend: 'auto')!;
    Directory(p.join(workspace.root, '.jj')).createSync();
    final child = VcsTrust.grant(
      root: workspace.root,
      inheritedBinding: binding,
    );
    final runner = fakeJjRunner();
    final collector = VcsCollector(trust: child, processRunner: runner);
    addTearDown(collector.close);
    expect(
      (await collector.collect(root: workspace.root)).reason,
      'trust required',
    );
    Directory(p.join(workspace.root, '.jj')).deleteSync();
    expect(
      (await collector.collect(root: workspace.root)).reason,
      'trust required',
    );
    expect(runner.invocations, isEmpty);
  });

  test(
    'selection follows the bound subdirectory rather than the old root',
    () async {
      final workspace = VcsWorkspace.create(git: true);
      addTearDown(workspace.dispose);
      final nested = Directory(p.join(workspace.root, 'nested'))..createSync();
      final trust = VcsTrust.grant(root: nested.path);
      final runner = fakeGitRunner();
      final collector = VcsCollector(trust: trust, processRunner: runner);
      addTearDown(collector.close);
      Directory(p.join(nested.path, '.git')).createSync();
      expect(
        (await collector.collect(root: nested.path)).reason,
        'trust required',
      );
      Directory(p.join(nested.path, '.git')).deleteSync();
      expect(
        (await collector.collect(root: nested.path)).reason,
        'trust required',
      );
      expect(runner.invocations, isEmpty);
    },
  );

  test(
    'a sibling workspace in the same repository revokes the grant',
    () async {
      final workspace = VcsWorkspace.create(git: true);
      addTearDown(workspace.dispose);
      final bound = Directory(p.join(workspace.root, 'bound'))..createSync();
      final sibling = Directory(p.join(workspace.root, 'sibling'))
        ..createSync();
      final runner = fakeGitRunner();
      final scheduler = ManualVcsDeadlineScheduler();
      final collector = VcsCollector(
        trust: VcsTrust.grant(root: bound.path),
        processRunner: runner,
        deadlineScheduler: scheduler,
      );
      addTearDown(collector.close);

      expect(
        (await collector.collect(root: sibling.path)).reason,
        'trust required',
      );
      expect(
        (await collector.collect(root: bound.path)).reason,
        'trust required',
      );
      expect(runner.invocations, isEmpty);
      expect(scheduler.durations, isEmpty);
    },
  );

  test('concurrent preview revokes a plan before its next start', () async {
    final workspace = VcsWorkspace.create(jj: true);
    addTearDown(workspace.dispose);
    final first = FakeVcsProcess();
    final delegate = fakeJjRunner();
    final runner = FakeVcsProcessRunner(
      processFor: (invocation) =>
          invocation.arguments.contains('log') &&
              !invocation.arguments.contains('op')
          ? first
          : delegate.processFor(invocation),
    );
    final collector = VcsCollector(
      trust: VcsTrust.grant(root: workspace.root),
      processRunner: runner,
      deadlineScheduler: ManualVcsDeadlineScheduler(),
    );
    addTearDown(collector.close);
    final pending = collector.collect(root: workspace.root);
    await runner.waitForInvocation((_) => true);
    final marker = Directory(p.join(workspace.root, '.jj'))..deleteSync();
    expect(
      (await collector.collect(root: workspace.root)).reason,
      'no repository',
    );
    marker.createSync();
    first.finish(
      successResult(
        stdout: jjSnapshotJsonl(
          change: 'change',
          commit: 'commit',
          description: 'working',
          parents: [],
        ),
      ),
    );
    final result = await pending;
    expect(result.reason, 'trust required');
    expect(result.observation, isA<SensoriumUnavailable<SensoriumVcs>>());
    expect(result.baseline, isNull);
    expect(result.captureCompleted, isFalse);
    expect(runner.invocations, hasLength(1));
  });

  test('plan whose starts preceded revocation keeps its result', () async {
    final workspace = VcsWorkspace.create(jj: true);
    addTearDown(workspace.dispose);
    final operation = FakeVcsProcess();
    final delegate = fakeJjRunner();
    final runner = FakeVcsProcessRunner(
      processFor: (invocation) => invocation.arguments.contains('op')
          ? operation
          : delegate.processFor(invocation),
    );
    final collector = VcsCollector(
      trust: VcsTrust.grant(root: workspace.root),
      processRunner: runner,
      deadlineScheduler: ManualVcsDeadlineScheduler(),
    );
    addTearDown(collector.close);
    final pending = collector.collect(root: workspace.root);
    await runner.waitForInvocation((i) => i.arguments.contains('op'));
    final marker = Directory(p.join(workspace.root, '.jj'))..deleteSync();
    expect(
      (await collector.collect(root: workspace.root)).reason,
      'no repository',
    );
    marker.createSync();
    operation.finish(successResult(stdout: 'operation-id\n'.codeUnits));
    final result = await pending;
    expect(result.observation, isA<SensoriumAvailable<SensoriumVcs>>());
    expect(result.baseline, isNotNull);
    expect(result.captureCompleted, isTrue);
    expect(runner.invocations, hasLength(2));
  });

  test('revocation during prehash prevents the first process start', () async {
    final workspace = VcsWorkspace.create(jj: true);
    addTearDown(workspace.dispose);
    workspace.writeFile('tracked.txt', 'dirty');
    final started = Completer<void>();
    final sample = Completer<VcsFileSample?>();
    final runner = fakeJjRunner();
    final collector = VcsCollector(
      trust: VcsTrust.grant(root: workspace.root),
      processRunner: runner,
      deadlineScheduler: ManualVcsDeadlineScheduler(),
      readFile: (_, _) {
        started.complete();
        return sample.future;
      },
    );
    addTearDown(collector.close);
    final pending = collector.collect(
      root: workspace.root,
      attribution: (
        effects: const {'tracked.txt': 'hash'},
        sequence: MutationSequence(0),
        jobsLive: false,
      ),
    );
    await started.future;
    final marker = Directory(p.join(workspace.root, '.jj'))..deleteSync();
    expect(
      (await collector.collect(root: workspace.root)).reason,
      'no repository',
    );
    marker.createSync();
    sample.complete(null);
    expect((await pending).reason, 'trust required');
    expect(runner.invocations, isEmpty);
  });

  test(
    'queued plan rechecks trust while already-started plan completes',
    () async {
      final workspace = VcsWorkspace.create(jj: true);
      addTearDown(workspace.dispose);
      final operation = FakeVcsProcess();
      final delegate = fakeJjRunner();
      final runner = FakeVcsProcessRunner(
        processFor: (invocation) => invocation.arguments.contains('op')
            ? operation
            : delegate.processFor(invocation),
      );
      final collector = VcsCollector(
        trust: VcsTrust.grant(root: workspace.root),
        processRunner: runner,
        deadlineScheduler: ManualVcsDeadlineScheduler(),
      );
      addTearDown(collector.close);
      final first = collector.collect(root: workspace.root);
      await runner.waitForInvocation((i) => i.arguments.contains('op'));
      final queued = collector.collect(root: workspace.root);
      final marker = Directory(p.join(workspace.root, '.jj'))..deleteSync();
      expect(
        (await collector.collect(root: workspace.root)).reason,
        'no repository',
      );
      marker.createSync();
      operation.finish(successResult(stdout: 'operation-id\n'.codeUnits));
      expect((await first).captureCompleted, isTrue);
      final refused = await queued;
      expect(refused.reason, 'trust required');
      expect(refused.baseline, isNull);
      expect(runner.invocations, hasLength(2));
    },
  );

  test(
    'pending process-start handle cannot authorize a later command',
    () async {
      final workspace = VcsWorkspace.create(jj: true);
      addTearDown(workspace.dispose);
      final runner = _PendingStartRunner();
      final collector = VcsCollector(
        trust: VcsTrust.grant(root: workspace.root),
        processRunner: runner,
        deadlineScheduler: ManualVcsDeadlineScheduler(),
      );
      addTearDown(collector.close);
      final pending = collector.collect(root: workspace.root);
      await runner.started.future;
      final marker = Directory(p.join(workspace.root, '.jj'))..deleteSync();
      expect(
        (await collector.collect(root: workspace.root)).reason,
        'no repository',
      );
      marker.createSync();
      runner.process.complete(
        completedProcess(
          successResult(
            stdout: jjSnapshotJsonl(
              change: 'change',
              commit: 'commit',
              description: 'working',
              parents: [],
            ),
          ),
        ),
      );
      final result = await pending;
      expect(result.reason, 'trust required');
      expect(result.captureCompleted, isFalse);
      expect(runner.starts, 1);
    },
  );

  test(
    'refused later start carries an earlier baseline without a new capture',
    () async {
      final workspace = VcsWorkspace.create(jj: true);
      addTearDown(workspace.dispose);
      final delegate = fakeJjRunner();
      final held = FakeVcsProcess();
      var holdSnapshot = false;
      final runner = FakeVcsProcessRunner(
        processFor: (invocation) =>
            holdSnapshot &&
                invocation.arguments.contains('log') &&
                !invocation.arguments.contains('op')
            ? held
            : delegate.processFor(invocation),
      );
      final collector = VcsCollector(
        trust: VcsTrust.grant(root: workspace.root),
        processRunner: runner,
        deadlineScheduler: ManualVcsDeadlineScheduler(),
      );
      addTearDown(collector.close);
      final previous = await collector.collect(root: workspace.root, turn: 3);
      expect(previous.baseline, isNotNull);
      holdSnapshot = true;
      final pending = collector.collect(
        root: workspace.root,
        previous: previous,
        turn: 4,
      );
      await runner.waitForInvocation(
        (i) => i.arguments.contains('log') && runner.invocations.length >= 3,
      );
      final marker = Directory(p.join(workspace.root, '.jj'))..deleteSync();
      expect(
        (await collector.collect(root: workspace.root)).reason,
        'no repository',
      );
      marker.createSync();
      held.finish(
        successResult(
          stdout: jjSnapshotJsonl(
            change: 'change',
            commit: 'commit',
            description: 'working',
            parents: [],
          ),
        ),
      );
      final result = await pending;
      expect(result.reason, 'trust required');
      expect(result.baseline, same(previous.baseline));
      expect(result.captureCompleted, isFalse);
      expect(result.changes, isEmpty);
      expect(runner.invocations, hasLength(3));
    },
  );
}

final class _PendingStartRunner implements VcsProcessRunner {
  final Completer<void> started = Completer<void>();
  final Completer<VcsProcess> process = Completer<VcsProcess>();
  int starts = 0;

  @override
  Future<VcsProcess> start({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    required Map<String, String> environment,
  }) {
    starts++;
    if (!started.isCompleted) started.complete();
    return process.future;
  }
}
