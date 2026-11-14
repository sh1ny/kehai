import 'dart:convert';
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

  test('colocated .jj and .git selects jj', () async {
    workspace = VcsWorkspace.create(git: true, jj: true);
    workspace.writeFile('src/edited.dart', 'actual workspace file');
    final runner = fakeJjRunner(statuses: const [('src/edited.dart', 'M')]);
    final result = await VcsCollector(
      processRunner: runner,
      deadlineScheduler: deadlines,
    ).collect(root: workspace.root);

    expect(result.observation, isA<SensoriumAvailable<SensoriumVcs>>());
    final value =
        (result.observation as SensoriumAvailable<SensoriumVcs>).value;
    expect(value.backend, 'jj');
    expect(value.change, 'change-id');
    expect(value.operation, 'operation-id');
    expect(
      p.basename(runner.invocations.first.executable).toLowerCase(),
      startsWith('jj'),
    );
    expect(runner.invocations, isNotEmpty);
  });

  test('.git without .jj selects git', () async {
    workspace = VcsWorkspace.create(git: true);
    workspace.writeFile('lib/actual.dart', 'actual path fixture');
    final runner = fakeGitRunner(
      modified: const ['lib/actual.dart'],
      headModified: const ['lib/actual.dart'],
    );
    final result = await VcsCollector(
      processRunner: runner,

      deadlineScheduler: deadlines,
    ).collect(root: workspace.root);

    expect(result.observation, isA<SensoriumAvailable<SensoriumVcs>>());
    final value =
        (result.observation as SensoriumAvailable<SensoriumVcs>).value;
    expect(value.backend, 'git');
    expect(value.branch, 'main');
    expect(value.modified, 1);
    expect(value.paths, contains('lib/actual.dart'));
    expect(
      p.basename(runner.invocations.first.executable).toLowerCase(),
      startsWith('git'),
    );
  });

  test(
    '.git worktree marker finds the repository above a workspace subdirectory',
    () async {
      workspace = VcsWorkspace.create();
      final metadata = Directory(
        p.join(workspace.temporary.path, 'git-metadata'),
      )..createSync();
      File(p.join(metadata.path, 'index'))
          .writeAsBytesSync(utf8.encode('worktree-index'));
      workspace.writeFile('.git', 'gitdir: ${metadata.path}\n');
      final nested = Directory(p.join(workspace.root, 'packages', 'app'))
        ..createSync(recursive: true);
      workspace.writeFile('packages/app/actual.dart', 'tracked workspace path');
      final delegate = fakeGitRunner(
        modified: const ['packages/app/actual.dart'],
        headModified: const ['packages/app/actual.dart'],
      );
      final runner = FakeVcsProcessRunner(
        processFor: (invocation) {
          if (invocation.arguments.contains('--git-path')) {
            return completedProcess(
              successResult(
                stdout: utf8.encode('${p.join(metadata.path, 'index')}\n'),
              ),
            );
          }
          if (invocation.arguments.contains('--show-toplevel')) {
            return completedProcess(
              successResult(stdout: utf8.encode('${workspace.root}\n')),
            );
          }
          return delegate.processFor(invocation);
        },
      );
      final result = await VcsCollector(
        processRunner: runner,
        deadlineScheduler: deadlines,
      ).collect(root: nested.path);

      expect(result.observation, isA<SensoriumAvailable<SensoriumVcs>>());
      final value =
          (result.observation as SensoriumAvailable<SensoriumVcs>).value;
      expect(value.backend, 'git');
      expect(value.paths, contains('packages/app/actual.dart'));
    },
  );

  test('no repository reads unavailable (no repository)', () async {
    workspace = VcsWorkspace.create();
    final runner = fakeGitRunner();
    final result = await VcsCollector(
      processRunner: runner,
      deadlineScheduler: deadlines,
    ).collect(root: workspace.root);

    expect(result.observation, isA<SensoriumUnavailable<SensoriumVcs>>());
    expect(result.reason, 'no repository');
    expect(runner.invocations, isEmpty);
  });

  test('vcs.backend none starts no process and reads disabled', () async {
    workspace = VcsWorkspace.create(git: true, jj: true);
    final runner = fakeGitRunner();
    final result = await VcsCollector(
      processRunner: runner,
      deadlineScheduler: deadlines,
    ).collect(root: workspace.root, backend: 'none');

    expect(result.observation, isA<SensoriumUnavailable<SensoriumVcs>>());
    expect(result.reason, 'disabled');
    expect(runner.invocations, isEmpty);
  });
}
