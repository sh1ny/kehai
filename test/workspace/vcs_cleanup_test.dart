import 'dart:async';
import 'dart:io';

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

  test('unverifiable termination holds its slot until engine exit', () async {
    workspace = VcsWorkspace.create(git: true);
    final originalIndex = File(workspace.gitIndex).readAsBytesSync();
    final delegate = fakeGitRunner();
    final held = FakeVcsProcess(
      terminationResult: VcsTerminationResult.unverified,
    );
    var heldOnce = false;
    final runner = FakeVcsProcessRunner(
      processFor: (invocation) {
        if (!heldOnce && invocation.arguments.contains('add')) {
          heldOnce = true;
          return held;
        }
        return delegate.processFor(invocation);
      },
    );
    final collector = VcsCollector(
      processRunner: runner,
      deadlineScheduler: deadlines,
    );
    final pending = collector.collect(root: workspace.root, backend: 'git');
    final timedOutAdd = await runner.waitForInvocation(
      (invocation) => invocation.arguments.contains('add'),
    );
    await deadlines.waitForCount(1);
    final quarantinedIndex = timedOutAdd.environment['GIT_INDEX_FILE'];
    deadlines.expire(0);
    final result = await pending;

    expect(result.reason, contains('timeout'));
    expect(quarantinedIndex, isNotNull);
    final privateIndex = quarantinedIndex!;
    expect(p.isAbsolute(privateIndex), isTrue);
    expect(p.normalize(privateIndex), isNot(p.normalize(workspace.gitIndex)));
    expect(File(privateIndex).existsSync(), isTrue);
    expect(File(privateIndex).readAsBytesSync(), originalIndex);
    expect(File(workspace.gitIndex).readAsBytesSync(), originalIndex);

    final second = await collector.collect(
      root: workspace.root,
      backend: 'git',
    );
    expect(second.observation, isA<SensoriumAvailable<SensoriumVcs>>());
    final nextAdd = runner.invocations.lastWhere(
      (invocation) => invocation.arguments.contains('add'),
    );
    final nextIndex = nextAdd.environment['GIT_INDEX_FILE']!;
    expect(nextIndex, isNot(privateIndex));
    expect(File(privateIndex).existsSync(), isTrue);
    expect(File(workspace.gitIndex).readAsBytesSync(), originalIndex);

    held.finish(successResult());
    addTearDown(() {
      final directory = Directory(p.dirname(privateIndex));
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    });
    await collector.close();
    expect(File(privateIndex).existsSync(), isFalse);
    expect(Directory(p.dirname(privateIndex)).existsSync(), isFalse);
  });

  test('stalled termination returns at deadline and keeps the slot', () async {
    workspace = VcsWorkspace.create(git: true);
    final delegate = fakeGitRunner();
    final held = FakeVcsProcess(stallTermination: true);
    var heldOnce = false;
    final runner = FakeVcsProcessRunner(
      processFor: (invocation) {
        if (!heldOnce && invocation.arguments.contains('add')) {
          heldOnce = true;
          return held;
        }
        return delegate.processFor(invocation);
      },
    );
    final collector = VcsCollector(
      processRunner: runner,
      deadlineScheduler: deadlines,
    );
    final pending = collector.collect(root: workspace.root, backend: 'git');
    await runner.waitForInvocation(
      (invocation) => invocation.arguments.contains('add'),
    );
    await deadlines.waitForCount(1);
    deadlines.expire(0);

    final result = await pending;
    expect(result.reason, contains('timeout'));
    expect(held.terminationCalls, 1);
    final second = await collector.collect(
      root: workspace.root,
      backend: 'git',
    );
    expect(second.observation, isA<SensoriumAvailable<SensoriumVcs>>());
    held.finish(successResult());
    held.finishTermination(VcsTerminationResult.confirmed);
  });

  test(
    '16 held git slots read cleanup pending and resume after release',
    () async {
      workspace = VcsWorkspace.create(git: true);
      final delegate = fakeGitRunner();
      final heldProcesses = <FakeVcsProcess>[];
      final runner = FakeVcsProcessRunner(
        processFor: (invocation) {
          if (invocation.arguments.contains('add') &&
              heldProcesses.length < 16) {
            final held = FakeVcsProcess(stallTermination: true);
            heldProcesses.add(held);
            return held;
          }
          return delegate.processFor(invocation);
        },
      );
      final collector = VcsCollector(
        processRunner: runner,
        deadlineScheduler: deadlines,
      );
      var lastInvocationIndex = -1;
      for (var i = 0; i < 16; i++) {
        final pending = collector.collect(root: workspace.root, backend: 'git');
        final add = await runner.waitForInvocation(
          (invocation) =>
              runner.processIndex(invocation) > lastInvocationIndex &&
              invocation.arguments.contains('add'),
        );
        lastInvocationIndex = runner.processIndex(add);
        await deadlines.waitForCount(i + 1);
        deadlines.expire(i);
        final result = await pending;
        expect(result.reason, contains('timeout'));
      }
      expect(heldProcesses, hasLength(16));
      expect(
        heldProcesses.every((process) => process.terminationCalls == 1),
        isTrue,
      );

      final invocationCount = runner.invocations.length;
      final denied = collector.collect(root: workspace.root, backend: 'git');
      await deadlines.waitForCount(17);
      deadlines.expire(16);
      final deniedResult = await denied;
      expect(deniedResult.reason, contains('cleanup pending'));
      expect(runner.invocations.length, invocationCount);

      final firstAdd = runner.invocations.firstWhere(
        (invocation) => invocation.arguments.contains('add'),
      );
      final privateIndex = firstAdd.environment['GIT_INDEX_FILE']!;
      expect(File(privateIndex).existsSync(), isTrue);
      final removed = Completer<void>();
      final removal = Directory(p.dirname(privateIndex))
          .watch(events: FileSystemEvent.delete)
          .listen((event) {
            if (p.equals(event.path, privateIndex) && !removed.isCompleted) {
              removed.complete();
            }
          });
      addTearDown(removal.cancel);
      heldProcesses.first.finish(successResult());
      heldProcesses.first.finishTermination(VcsTerminationResult.confirmed);
      await removed.future;
      final resumed = collector.collect(root: workspace.root, backend: 'git');
      final resumedResult = await resumed;
      expect(
        resumedResult.observation,
        isA<SensoriumAvailable<SensoriumVcs>>(),
        reason: resumedResult.reason,
      );
      for (final process in heldProcesses.skip(1)) {
        process.finish(successResult());
        process.finishTermination(VcsTerminationResult.confirmed);
      }
    },
  );

  test(
    '100 jj timeouts never exceed 16 slots and every build meets its deadline',
    () async {
      workspace = VcsWorkspace.create(jj: true);
      final delegate = fakeJjRunner();
      final heldProcesses = <FakeVcsProcess>[];
      final runner = FakeVcsProcessRunner(
        processFor: (invocation) {
          if (invocation.arguments.contains('log')) {
            final held = FakeVcsProcess(stallTermination: true);
            heldProcesses.add(held);
            return held;
          }
          return delegate.processFor(invocation);
        },
      );
      final collector = VcsCollector(
        processRunner: runner,
        deadlineScheduler: deadlines,
      );
      var lastInvocationIndex = -1;
      for (var i = 0; i < 100; i++) {
        final invocationCountBefore = runner.invocations.length;
        final pending = collector.collect(root: workspace.root, backend: 'jj');
        if (i < 16) {
          final snapshot = await runner.waitForInvocation(
            (invocation) =>
                runner.processIndex(invocation) > lastInvocationIndex &&
                invocation.arguments.contains('log'),
          );
          lastInvocationIndex = runner.processIndex(snapshot);
        }
        await deadlines.waitForCount(i + 1);
        deadlines.expire(i);
        final result = await pending;
        if (i < 16) {
          expect(result.reason, contains('timeout'));
        } else {
          expect(result.reason, contains('cleanup pending'));
          expect(runner.invocations.length, invocationCountBefore);
        }
        expect(
          runner.processes.where((process) => process.isPending).length,
          lessThanOrEqualTo(16),
        );
      }
      expect(heldProcesses, hasLength(16));
      expect(
        heldProcesses.every((process) => process.terminationCalls == 1),
        isTrue,
      );
      expect(deadlines.durations, hasLength(100));
      for (final process in heldProcesses) {
        process.finish(successResult());
        process.finishTermination(VcsTerminationResult.confirmed);
      }
    },
  );
}
