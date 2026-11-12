import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kehai/src/loop/sensorium.dart';
import 'package:kehai/src/workspace/vcs_collector.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/vcs_support.dart';

void main() {
  late VcsWorkspace workspace;
  late ManualVcsDeadlineScheduler deadlines;

  setUp(() {
    deadlines = ManualVcsDeadlineScheduler();
  });
  tearDown(() => workspace.dispose());

  test('completed fake collection returns available', () async {
    workspace = VcsWorkspace.create(git: true);
    workspace.writeFile('lib/edited.dart', 'old bytes');
    workspace.writeFile('new-file.dart', 'new bytes');
    final runner = fakeGitRunner(
      modified: const ['lib/edited.dart'],
      untracked: const ['new-file.dart'],
      headModified: const ['lib/edited.dart'],
      headAdded: const ['new-file.dart'],
      deltaNumstat: const ['2\t1\tlib/edited.dart'],
    );

    final result =
        await VcsCollector(
          processRunner: runner,
          deadlineScheduler: deadlines,
        ).collect(
          root: workspace.root,
          backend: 'git',
          previous: _previous('git', 'older-tree'),
          turn: 2,
          time: DateTime.utc(2026, 11, 12),
        );

    expect(result.observation, isA<SensoriumAvailable<SensoriumVcs>>());
    final value =
        (result.observation as SensoriumAvailable<SensoriumVcs>).value;
    expect(value.backend, 'git');
    expect(value.branch, 'main');
    expect(value.modified, 1);
    expect(value.added, 1);
    expect(value.paths, containsAll(['lib/edited.dart', 'new-file.dart']));
    expect(result.baseline, isNotNull);
    expect(result.baseline!.backend, 'git');
    expect(result.changes.single.path, 'lib/edited.dart');
    expect(result.changes.single.added, 2);
    expect(result.changes.single.removed, 1);
  });

  test(
    'git rename reported as delete and add stays a two-path delta',
    () async {
      workspace = VcsWorkspace.create(git: true);
      workspace.writeFile('old-name.txt', 'old content');
      workspace.writeFile('new-name.txt', 'new content');
      final runner = fakeGitRunner(
        stagedAndUnstagedModified: const ['new-name.txt'],
        headAdded: const ['new-name.txt'],
        headDeleted: const ['old-name.txt'],
        deltaNumstat: const ['0\t2\told-name.txt', '3\t0\tnew-name.txt'],
      );
      final result =
          await VcsCollector(
            processRunner: runner,
            deadlineScheduler: deadlines,
          ).collect(
            root: workspace.root,
            backend: 'git',
            previous: _previous('git', 'prior-tree'),
            turn: 2,
            time: DateTime.utc(2026, 11, 12),
          );

      expect(result.observation, isA<SensoriumAvailable<SensoriumVcs>>());
      final value =
          (result.observation as SensoriumAvailable<SensoriumVcs>).value;
      expect(value.added, 1);
      expect(value.deleted, 1);
      expect(value.modified, 0);
      expect(value.paths, containsAll(['old-name.txt', 'new-name.txt']));
      expect(
        result.changes.map((change) => change.path),
        containsAll(['old-name.txt', 'new-name.txt']),
      );
    },
  );

  test(
    'held fake process at deadline yields stale with timeout and earlier value',
    () async {
      workspace = VcsWorkspace.create(git: true);
      final now = DateTime.utc(2026, 11, 12, 12);
      final previousTime = now.subtract(const Duration(hours: 2));
      final earlierValue = SensoriumVcs(
        branch: 'main',
        paths: const ['earlier.dart'],
        backend: 'git',
      );
      final previous = VcsCollection(
        observation: SensoriumAvailable(earlierValue),
        baseline: VcsBaseline(
          backend: 'git',
          id: 'earlier-tree',
          turn: 4,
          time: previousTime,
          seq: 4,
          jobsLive: false,
        ),
      );
      final heldProcesses = <FakeVcsProcess>[];
      final runner = FakeVcsProcessRunner(
        processFor: (_) {
          final process = FakeVcsProcess(stallTermination: true);
          heldProcesses.add(process);
          return process;
        },
      );
      final pending =
          VcsCollector(
            processRunner: runner,
            deadlineScheduler: deadlines,
          ).collect(
            root: workspace.root,
            backend: 'git',
            deadline: const Duration(milliseconds: 300),
            previous: previous,
            turn: 6,
            time: now,
          );
      await runner.waitForInvocation((_) => true);
      await deadlines.waitForCount(1);
      deadlines.expire(0);

      final result = await pending;
      expect(result.observation, isA<SensoriumStale<SensoriumVcs>>());
      final stale = result.observation as SensoriumStale<SensoriumVcs>;
      expect(stale.value, same(earlierValue));
      expect(stale.reason, SensoriumReason.timedOut);
      expect(stale.age, const Duration(hours: 2));
      expect(result.reason, contains('timeout'));
      expect(heldProcesses, isNotEmpty);
      expect(
        heldProcesses.every((process) => process.terminationCalls == 1),
        isTrue,
      );
      for (final process in heldProcesses) {
        process.finish(successResult());
        process.finishTermination(VcsTerminationResult.confirmed);
      }
    },
  );

  test('held fake process at deadline yields unavailable (timeout)', () async {
    workspace = VcsWorkspace.create(git: true);
    final heldProcesses = <FakeVcsProcess>[];
    final runner = FakeVcsProcessRunner(
      processFor: (_) {
        final process = FakeVcsProcess();
        heldProcesses.add(process);
        return process;
      },
    );
    final pending = VcsCollector(
      processRunner: runner,
      deadlineScheduler: deadlines,
    ).collect(root: workspace.root, backend: 'git');
    await runner.waitForInvocation((_) => true);
    await deadlines.waitForCount(1);
    deadlines.expire(0);

    final result = await pending;
    expect(result.observation, isA<SensoriumUnavailable<SensoriumVcs>>());
    expect(result.reason, contains('timeout'));
    expect(heldProcesses, isNotEmpty);
    expect(
      heldProcesses.every((process) => process.terminationCalls == 1),
      isTrue,
    );
    for (final process in heldProcesses) {
      process.finish(successResult());
    }
  });

  test(
    'missing executable reads unavailable (jj not found) and (git not found)',
    () async {
      workspace = VcsWorkspace.create(git: true, jj: true);
      for (final (backend, missingTool, runner) in [
        ('auto', 'jj', fakeJjRunner()),
        ('git', 'git', fakeGitRunner()),
      ]) {
        final result = await VcsCollector(
          processRunner: runner,
          deadlineScheduler: deadlines,
          environment: const {'PATH': ''},
        ).collect(root: workspace.root, backend: backend);

        expect(result.observation, isA<SensoriumUnavailable<SensoriumVcs>>());
        expect(result.reason, '$missingTool not found');
        expect(runner.invocations, isEmpty);
      }
    },
  );

  test('non-zero exit reads failed with clipped stderr reason', () async {
    workspace = VcsWorkspace.create(git: true);
    final stderrPadding = List.filled(3000, 'x').join();
    final stderr = utf8.encode('${stderrPadding}SENSITIVE_AFTER_LIMIT');
    final runner = FakeVcsProcessRunner(
      processFor: (_) => completedProcess(
        VcsProcessResult(exitCode: 128, stdout: const [], stderr: stderr),
      ),
    );
    final result = await VcsCollector(
      processRunner: runner,
      deadlineScheduler: deadlines,
    ).collect(root: workspace.root, backend: 'git');

    expect(result.observation, isNot(isA<SensoriumAvailable<SensoriumVcs>>()));
    expect(result.reason, contains('failed'));
    expect(result.reason!.length, lessThanOrEqualTo(200));
    expect(result.reason, isNot(contains('SENSITIVE_AFTER_LIMIT')));
  });

  test('oversized output marks partial, never clean', () async {
    workspace = VcsWorkspace.create(jj: true);
    workspace.writeFile('oversized-fixture.txt', 'real path fixture');
    final oversizedSnapshot = _oversizedJjSnapshot();
    final runner = FakeVcsProcessRunner(
      processFor: (invocation) {
        if (invocation.arguments.contains('op')) {
          return completedProcess(
            successResult(stdout: utf8.encode('operation-id\n')),
          );
        }
        if (invocation.arguments.contains('log')) {
          return completedProcess(successResult(stdout: oversizedSnapshot));
        }
        return completedProcess(successResult());
      },
    );
    final result = await VcsCollector(
      processRunner: runner,
      deadlineScheduler: deadlines,
    ).collect(root: workspace.root, backend: 'jj');

    expect(result.observation, isA<SensoriumAvailable<SensoriumVcs>>());
    final value =
        (result.observation as SensoriumAvailable<SensoriumVcs>).value;
    expect(value.partial, isTrue);
    expect(value.modified + value.added + value.deleted, greaterThan(0));
  });

  test('conflicted files are listed for jj and git', () async {
    workspace = VcsWorkspace.create(git: true, jj: true);
    const conflictPath = 'lib/conflict.dart';
    workspace.writeFile(conflictPath, 'conflicted file');
    final gitResult = await VcsCollector(
      processRunner: fakeGitRunner(
        conflicts: const [conflictPath],
        headModified: const [conflictPath],
      ),
      deadlineScheduler: deadlines,
    ).collect(root: workspace.root, backend: 'git');
    final jjResult = await VcsCollector(
      processRunner: fakeJjRunner(
        statuses: const [(conflictPath, 'C')],
        conflicts: const [conflictPath],
      ),
      deadlineScheduler: deadlines,
    ).collect(root: workspace.root, backend: 'jj');

    for (final result in [gitResult, jjResult]) {
      expect(result.observation, isA<SensoriumAvailable<SensoriumVcs>>());
      final value =
          (result.observation as SensoriumAvailable<SensoriumVcs>).value;
      expect(value.conflicts, contains(conflictPath));
      expect(value.paths, contains(conflictPath));
      expect(value.conflicts, isNotEmpty);
    }
  });

  test('jj --git diff parses quoted and newline paths', () async {
    workspace = VcsWorkspace.create(jj: true);
    final result =
        await VcsCollector(
          processRunner: fakeJjRunner(
            diff:
                gitPatch(path: 'line\nbreak.dart', added: 2, removed: 1) +
                gitPatch(path: 'quoted"name.dart', added: 1, removed: 0),
          ),
          deadlineScheduler: deadlines,
        ).collect(
          root: workspace.root,
          backend: 'jj',
          previous: _previous('jj', 'old-commit'),
          turn: 3,
          time: DateTime.utc(2026, 11, 12),
        );

    expect(
      result.changes.map((change) => change.path),
      containsAll(['line\nbreak.dart', 'quoted"name.dart']),
    );
    expect(result.changes.first.added, greaterThan(0));
  });

  test('recorded argv stays within the allowlist for jj and git', () async {
    workspace = VcsWorkspace.create(git: true, jj: true);
    final runners = [fakeGitRunner(), fakeJjRunner()];
    final invocations = <VcsInvocation>[];
    for (final (backend, runner) in [('git', runners[0]), ('jj', runners[1])]) {
      await VcsCollector(
        processRunner: runner,
        deadlineScheduler: deadlines,
      ).collect(root: workspace.root, backend: backend);
      invocations.addAll(runner.invocations);
    }

    const forbidden = {
      'fetch',
      'push',
      'pull',
      'clone',
      'checkout',
      'switch',
      'restore',
      'smudge',
    };
    for (final invocation in invocations) {
      expect(invocation.arguments.toSet().intersection(forbidden), isEmpty);
      if (p.basename(invocation.executable).toLowerCase().startsWith('git')) {
        expect(invocation.environment['GIT_OPTIONAL_LOCKS'], '0');
        expect(invocation.environment['GIT_TERMINAL_PROMPT'], '0');
      }
    }
  });

  test(
    'hanging clean filter is bounded by the deadline and terminated',
    () async {
      workspace = VcsWorkspace.create(git: true);
      workspace.writeFile('.gitattributes', '*.txt filter=hang\n');
      workspace.writeFile(
        '.git/config',
        '[filter "hang"]\n clean = hangfilter\n smudge = smudger\n required = true\n',
      );
      workspace.writeFile('filtered.txt', 'filter input');
      final ordinaryRunner = fakeGitRunner();
      final held = FakeVcsProcess(stallTermination: true);
      var heldOnce = false;
      final runner = FakeVcsProcessRunner(
        processFor: (invocation) {
          if (!heldOnce && invocation.arguments.contains('add')) {
            heldOnce = true;
            return held;
          }
          return ordinaryRunner.processFor(invocation);
        },
      );
      final pending = VcsCollector(
        processRunner: runner,
        deadlineScheduler: deadlines,
      ).collect(root: workspace.root, backend: 'git');
      final addInvocation = await runner.waitForInvocation(
        (invocation) => invocation.arguments.contains('add'),
      );
      await deadlines.waitForCount(1);
      deadlines.expire(0);

      final result = await pending;
      expect(result.reason, contains('timeout'));
      expect(held.terminationCalls, 1);
      expect(addInvocation.arguments, contains('-A'));
      expect(
        runner.invocations.expand((invocation) => invocation.arguments),
        isNot(contains('smudge')),
      );
      held.finish(successResult());
      held.finishTermination(VcsTerminationResult.confirmed);
    },
  );

  test('status preview waits behind an in-flight request collection', () async {
    workspace = VcsWorkspace.create(git: true);
    final ordinaryRunner = fakeGitRunner();
    final held = FakeVcsProcess();
    var heldOnce = false;
    final runner = FakeVcsProcessRunner(
      processFor: (invocation) {
        if (!heldOnce && invocation.arguments.contains('add')) {
          heldOnce = true;
          return held;
        }
        return ordinaryRunner.processFor(invocation);
      },
    );
    final collector = VcsCollector(
      processRunner: runner,
      deadlineScheduler: deadlines,
    );
    final build = collector.collect(root: workspace.root, backend: 'git');
    await runner.waitForInvocation(
      (invocation) => invocation.arguments.contains('add'),
    );
    final invocationsBeforePreview = runner.invocations.length;
    final preview = collector.collect(root: workspace.root, backend: 'git');
    await deadlines.waitForCount(2);
    expect(runner.invocations.length, invocationsBeforePreview);

    held.finish(successResult());
    await build;
    final previewResult = await preview;
    expect(previewResult.observation, isA<SensoriumAvailable<SensoriumVcs>>());
    expect(runner.invocations.length, greaterThan(invocationsBeforePreview));
  });

  test(
    'lock wait past deadline returns stale without starting a process',
    () async {
      workspace = VcsWorkspace.create(git: true);
      final ordinaryRunner = fakeGitRunner();
      final held = FakeVcsProcess();
      var heldOnce = false;
      final runner = FakeVcsProcessRunner(
        processFor: (invocation) {
          if (!heldOnce && invocation.arguments.contains('add')) {
            heldOnce = true;
            return held;
          }
          return ordinaryRunner.processFor(invocation);
        },
      );
      final previous = _previous('git', 'old-tree');
      final collector = VcsCollector(
        processRunner: runner,
        deadlineScheduler: deadlines,
      );
      final build = collector.collect(root: workspace.root, backend: 'git');
      await runner.waitForInvocation(
        (invocation) => invocation.arguments.contains('add'),
      );
      final processCountBeforePreview = runner.invocations.length;
      final preview = collector.collect(
        root: workspace.root,
        backend: 'git',
        previous: previous,
        turn: 2,
        time: DateTime.utc(2026, 11, 12),
      );
      await deadlines.waitForCount(2);
      deadlines.expire(1);

      final result = await preview;
      expect(result.observation, isA<SensoriumStale<SensoriumVcs>>());
      expect(result.reason, contains('timeout'));
      expect(runner.invocations.length, processCountBeforePreview);
      held.finish(successResult());
      await build;
    },
  );

  test('relative PATH entries are skipped', () async {
    workspace = VcsWorkspace.create(git: true);
    final bin = Directory(Directory.current.path).createTempSync('.vcs-path-');
    try {
      final executable = Platform.isWindows ? 'git.exe' : 'git';
      File(p.join(bin.path, executable))
          .writeAsStringSync('not a real executable');
      final pathEntry = p.relative(bin.path, from: Directory.current.path);
      final runner = fakeGitRunner();
      final result = await VcsCollector(
        processRunner: runner,
        deadlineScheduler: deadlines,
        environment: {'PATH': pathEntry},
      ).collect(root: workspace.root, backend: 'git');

      expect(result.observation, isA<SensoriumUnavailable<SensoriumVcs>>());
      expect(result.reason, contains('git not found'));
      expect(runner.invocations, isEmpty);
    } finally {
      bin.deleteSync(recursive: true);
    }
  });
}

VcsCollection _previous(String backend, String id) {
  final time = DateTime.utc(2026, 11, 11, 10);
  return VcsCollection(
    observation: SensoriumAvailable(
      SensoriumVcs(branch: 'main', paths: const [], backend: backend),
    ),
    baseline: VcsBaseline(
      backend: backend,
      id: id,
      turn: 1,
      time: time,
      seq: 1,
      jobsLive: false,
    ),
  );
}

List<int> _oversizedJjSnapshot() {
  const identity =
      '{"kind":"identity","commit":"commit-id",'
      '"change":"change-id","description":"large status",'
      '"parents":["parent-id"]}\n';
  final longPath = List<String>.filled(500, 'p').join();
  final status =
      jsonEncode({
        'kind': 'status',
        'path': 'oversized-$longPath.dart',
        'status': 'M',
      }) +
      '\n';
  final identityBytes = utf8.encode(identity);
  final statusBytes = utf8.encode(status);
  final output = BytesBuilder(copy: false)..add(identityBytes);
  while (output.length < 4 * 1024 * 1024 + 1) {
    output.add(statusBytes);
  }
  return output.takeBytes();
}
