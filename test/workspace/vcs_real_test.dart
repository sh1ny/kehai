/// Qualifies workspace VCS collection against the pinned native executables.
@Tags(['slow'])
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:io';

import 'package:kehai/src/loop/sensorium.dart';
import 'package:kehai/src/workspace/vcs_collector.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _gitName = 'Nikolay Bochev';
const _gitEmail = '309868+sh1ny@users.noreply.github.com';
const _coAuthor =
    'Co-authored-by: KintsugiBot <296966193+KintsugiBot@users.noreply.github.com>';
const _collectionDeadline = Duration(seconds: 5);

void main() {
  group('real process VCS collection', () {
    test(
      'dirty jj reports identity, first description, parent, MAD and opid',
      () async {
        final workspace = _RealWorkspace.create();
        final collector = VcsCollector();
        _registerCleanup(workspace, collector);
        await workspace.initJj();
        workspace.write('notes.txt', 'base one\nbase two\n');
        workspace.write('second.txt', 'second baseline\n');
        await _jjOk(workspace.directory, ['describe', '--message', 'parent']);
        await _jjOk(workspace.directory, ['new', '--message', 'current']);
        workspace.write('notes.txt', 'changed one\nbase two\n');
        workspace.write('second.txt', 'second changed\n');
        workspace.write('added.txt', 'new content\n');
        await _jjOk(workspace.directory, [
          'describe',
          '--message',
          'first description line\nsecond description line',
        ]);

        final expectedChange = await _jjText(workspace.directory, [
          'log',
          '-r',
          '@',
          '--no-graph',
          '-T',
          'change_id',
        ]);
        final expectedParent = await _jjText(workspace.directory, [
          'log',
          '-r',
          '@-',
          '--no-graph',
          '-T',
          'commit_id',
        ]);
        final expectedOperation = await _jjText(workspace.directory, [
          'op',
          'log',
          '--ignore-working-copy',
          '-n',
          '1',
          '--no-graph',
          '-T',
          'id',
        ]);

        final result = await collector.collect(
          root: workspace.directory.path,
          deadline: _collectionDeadline,
        );
        final value = _available(result);

        expect(value.backend, 'jj');
        expect(value.change, expectedChange);
        expect(value.description, 'first description line');
        expect(value.parent, expectedParent);
        expect(value.operation, expectedOperation);
        expect(value.modified, 2);
        expect(value.added, 1);
        expect(value.deleted, 0);
        expect(value.paths, contains('notes.txt'));
        expect(value.paths, containsAll(['second.txt', 'added.txt']));
        expect(value.conflicts, isEmpty);
      },
    );

    test('unborn git branch reports its branch and untracked path', () async {
      final workspace = _RealWorkspace.create();
      final collector = VcsCollector();
      _registerCleanup(workspace, collector);
      await workspace.initGit(branch: 'unborn-topic');
      workspace.write('new.txt', 'unborn content\n');

      final result = await collector.collect(
        root: workspace.directory.path,
        deadline: _collectionDeadline,
      );
      final value = _available(result);

      expect(value.backend, 'git');
      expect(value.branch, 'unborn-topic');
      expect(value.added, 1);
      expect(value.paths, contains('new.txt'));
    });

    test(
      'partial staging preserves the original index bytes, refs and split',
      () async {
        final workspace = _RealWorkspace.create();
        final collector = VcsCollector();
        _registerCleanup(workspace, collector);
        await workspace.initGit();
        workspace.write('split.txt', 'alpha\nbeta\ngamma\n');
        await workspace.commit('base');
        workspace.write('split.txt', 'alpha\nstaged\nbeta\ngamma\n');
        await _gitOk(workspace.directory, ['add', '--', 'split.txt']);
        workspace.write('split.txt', 'alpha\nstaged\nbeta\nunstaged\ngamma\n');

        final index = File(p.join(workspace.directory.path, '.git', 'index'));
        final originalIndex = await index.readAsBytes();
        final originalRefs = await _gitText(workspace.directory, [
          'show-ref',
          '--head',
        ]);
        final originalStagedDiff = await _gitText(workspace.directory, [
          'diff',
          '--cached',
          '--',
          'split.txt',
        ]);
        final originalWorktreeDiff = await _gitText(workspace.directory, [
          'diff',
          '--',
          'split.txt',
        ]);
        expect(originalStagedDiff, isNotEmpty);
        expect(originalWorktreeDiff, isNotEmpty);

        final result = await collector.collect(
          root: workspace.directory.path,
          deadline: _collectionDeadline,
        );
        final value = _available(result);

        expect(value.backend, 'git');
        expect(value.paths, contains('split.txt'));
        expect(await index.readAsBytes(), orderedEquals(originalIndex));
        expect(
          await _gitText(workspace.directory, ['show-ref', '--head']),
          originalRefs,
        );
        expect(
          await _gitText(workspace.directory, [
            'diff',
            '--cached',
            '--',
            'split.txt',
          ]),
          originalStagedDiff,
        );
        expect(
          await _gitText(workspace.directory, ['diff', '--', 'split.txt']),
          originalWorktreeDiff,
        );
      },
    );

    test('user git add succeeds while collection is blocked without original index lock', () async {
      final workspace = _RealWorkspace.create();
      final collector = VcsCollector();
      _registerCleanup(workspace, collector);
      await workspace.initGit();
      workspace.write('base.txt', 'base\n');
      await workspace.commit('base');

      final filterScript = File(
        p.join(workspace.temporary.path, 'blocking_clean_filter.dart'),
      );
      await File(
        p.join('test', 'fixtures', 'vcs_real', 'blocking_clean_filter.dart'),
      ).copy(filterScript.path);
      final ready = File(p.join(workspace.temporary.path, 'filter-ready'));
      final release = File(p.join(workspace.temporary.path, 'filter-release'));
      final relativeFilter = _gitRelative(workspace, filterScript);
      final relativeReady = _gitRelative(workspace, ready);
      final relativeRelease = _gitRelative(workspace, release);
      workspace.write('.gitattributes', 'blocked.txt filter=realbarrier\n');
      workspace.write('blocked.txt', 'held through the clean filter\n');
      workspace.write('user-added.txt', 'user index update\n');
      await _gitOk(workspace.directory, [
        'config',
        'filter.realbarrier.clean',
        'dart $relativeFilter $relativeReady $relativeRelease',
      ]);
      await _gitOk(workspace.directory, [
        'config',
        'filter.realbarrier.required',
        'true',
      ]);

      final readySignal = _waitForFile(ready);
      final collection = collector.collect(
        root: workspace.directory.path,
        deadline: _collectionDeadline,
      );
      VcsCollection? collected;
      try {
        await Future.any<void>([
          readySignal,
          collection.then<void>((result) {
            throw TestFailure(
              'Collection ended before the clean-filter barrier: ${result.reason}',
            );
          }),
        ]);
        expect(
          File(p.join(workspace.directory.path, '.git', 'index.lock'))
              .existsSync(),
          isFalse,
        );
        await _gitOk(workspace.directory, ['add', '--', 'user-added.txt']);
        expect(
          (await _gitText(workspace.directory, [
            'ls-files',
            '--error-unmatch',
            'user-added.txt',
          ])).trim(),
          'user-added.txt',
        );
      } finally {
        if (!release.existsSync()) release.writeAsStringSync('continue');
        collected = await collection;
      }

      final value = _available(collected!);
      expect(value.backend, 'git');
      expect(value.paths, contains('user-added.txt'));
    });

    test(
      'edited force-added ignored file remains in captured tree membership',
      () async {
        final workspace = _RealWorkspace.create();
        final collector = VcsCollector();
        _registerCleanup(workspace, collector);
        await workspace.initGit();
        workspace.write('.gitignore', 'ignored.txt\n');
        workspace.write('ignored.txt', 'tracked despite ignore\n');
        await _gitOk(workspace.directory, ['add', '--', '.gitignore']);
        await _gitOk(workspace.directory, [
          'add',
          '--force',
          '--',
          'ignored.txt',
        ]);
        await workspace.commit('force-add ignored file');
        workspace.write('ignored.txt', 'edited tracked ignored file\n');

        final result = await collector.collect(
          root: workspace.directory.path,
          deadline: _collectionDeadline,
        );
        final value = _available(result);
        final capturedTreeId = _baselineId(result);

        expect(value.paths, contains('ignored.txt'));
        expect(value.modified, 1);
        expect(
          _treePaths(
            await _gitText(workspace.directory, [
              'ls-tree',
              '-r',
              '--name-only',
              capturedTreeId,
            ]),
          ),
          contains('ignored.txt'),
        );
      },
    );

    test(
      'git rm cached plus ignore removes path from captured tree membership',
      () async {
        final workspace = _RealWorkspace.create();
        final collector = VcsCollector();
        _registerCleanup(workspace, collector);
        await workspace.initGit();
        workspace.write('cached-away.txt', 'tracked before removal\n');
        await _gitOk(workspace.directory, ['add', '--', 'cached-away.txt']);
        await workspace.commit('track file');
        await _gitOk(workspace.directory, [
          'rm',
          '--cached',
          '--',
          'cached-away.txt',
        ]);
        workspace.write('.gitignore', 'cached-away.txt\n');
        await _gitOk(workspace.directory, ['add', '--', '.gitignore']);

        final result = await collector.collect(
          root: workspace.directory.path,
          deadline: _collectionDeadline,
        );
        final capturedTreeId = _baselineId(result);
        final capturedPaths = _treePaths(
          await _gitText(workspace.directory, [
            'ls-tree',
            '-r',
            '--name-only',
            capturedTreeId,
          ]),
        );

        expect(
          File(p.join(workspace.directory.path, 'cached-away.txt'))
              .existsSync(),
          isTrue,
        );
        expect(
          (await _git(workspace.directory, [
            'check-ignore',
            '--',
            'cached-away.txt',
          ])).exitCode,
          0,
        );
        expect(capturedPaths, isNot(contains('cached-away.txt')));
      },
    );

    test(
      'git baseline reports one-file added and removed line counts',
      () async {
        final workspace = _RealWorkspace.create();
        final collector = VcsCollector();
        _registerCleanup(workspace, collector);
        await workspace.initGit();
        workspace.write('counts.txt', 'zero\none\ntwo\n');
        await workspace.commit('baseline');

        final baseline = await collector.collect(
          root: workspace.directory.path,
          deadline: _collectionDeadline,
        );
        _available(baseline);
        final immutableBaselineId = _baselineId(baseline);
        workspace.write('counts.txt', 'zero\nnew line\ntwo\nextra\n');
        final current = await collector.collect(
          root: workspace.directory.path,
          deadline: _collectionDeadline,
          previous: baseline,
        );
        _available(current);

        expect(current.baseline, isNotNull);
        expect(current.baseline!.id, isNot(immutableBaselineId));
        expect(current.changes, hasLength(1));
        expect(current.changes.single.path, 'counts.txt');
        expect(current.changes.single.added, 2);
        expect(current.changes.single.removed, 1);
      },
    );

    test(
      'jj baseline reports one-file added and removed line counts',
      () async {
        final workspace = _RealWorkspace.create();
        final collector = VcsCollector();
        _registerCleanup(workspace, collector);
        await workspace.initJj();
        workspace.write('counts.txt', 'zero\none\ntwo\n');
        await _jjOk(workspace.directory, ['describe', '--message', 'baseline']);

        final baseline = await collector.collect(
          root: workspace.directory.path,
          deadline: _collectionDeadline,
        );
        _available(baseline);
        final immutableBaselineId = _baselineId(baseline);
        workspace.write('counts.txt', 'zero\nnew line\ntwo\nextra\n');
        final current = await collector.collect(
          root: workspace.directory.path,
          deadline: _collectionDeadline,
          previous: baseline,
        );
        _available(current);

        expect(current.baseline, isNotNull);
        expect(current.baseline!.id, isNot(immutableBaselineId));
        expect(current.changes, hasLength(1));
        expect(current.changes.single.path, 'counts.txt');
        expect(current.changes.single.added, 2);
        expect(current.changes.single.removed, 1);
      },
    );
  });
}

void _registerCleanup(_RealWorkspace workspace, VcsCollector collector) {
  addTearDown(() async {
    await collector.close();
    await workspace.dispose();
  });
}

SensoriumVcs _available(VcsCollection result) {
  expect(result.observation, isA<SensoriumAvailable<SensoriumVcs>>());
  return (result.observation as SensoriumAvailable<SensoriumVcs>).value;
}

String _baselineId(VcsCollection result) {
  expect(result.baseline, isNotNull);
  return result.baseline!.id;
}

List<String> _treePaths(String output) =>
    output.split('\n').where((path) => path.isNotEmpty).toList();

String _gitRelative(_RealWorkspace workspace, File file) => p.posix.joinAll(
  p.split(p.relative(file.path, from: workspace.directory.path)),
);

Future<void> _waitForFile(File file) {
  final ready = Completer<void>();
  late final StreamSubscription<FileSystemEvent> subscription;
  subscription = file.parent.watch().listen((_) {
    if (file.existsSync() && !ready.isCompleted) ready.complete();
  }, onError: ready.completeError);
  addTearDown(subscription.cancel);
  if (file.existsSync()) ready.complete();
  return ready.future.whenComplete(subscription.cancel);
}

Future<ProcessResult> _git(Directory directory, List<String> arguments) =>
    Process.run('git', [
      '-c',
      'user.name=$_gitName',
      '-c',
      'user.email=$_gitEmail',
      '-c',
      'commit.gpgsign=false',
      ...arguments,
    ], workingDirectory: directory.path);

Future<String> _gitText(Directory directory, List<String> arguments) async {
  final result = await _git(directory, arguments);
  expect(
    result.exitCode,
    0,
    reason: 'git ${arguments.join(' ')} failed: ${result.stderr}',
  );
  return (result.stdout as String).trimRight();
}

Future<void> _gitOk(Directory directory, List<String> arguments) async {
  final result = await _git(directory, arguments);
  expect(
    result.exitCode,
    0,
    reason: 'git ${arguments.join(' ')} failed: ${result.stderr}',
  );
}

Future<String> _jjText(Directory directory, List<String> arguments) async {
  final result = await Process.run(
    'jj',
    arguments,
    workingDirectory: directory.path,
  );
  expect(
    result.exitCode,
    0,
    reason: 'jj ${arguments.join(' ')} failed: ${result.stderr}',
  );
  return (result.stdout as String).trim();
}

Future<void> _jjOk(Directory directory, List<String> arguments) async {
  final result = await Process.run(
    'jj',
    arguments,
    workingDirectory: directory.path,
  );
  expect(
    result.exitCode,
    0,
    reason: 'jj ${arguments.join(' ')} failed: ${result.stderr}',
  );
}

final class _RealWorkspace {
  _RealWorkspace._(this.temporary, this.directory);

  factory _RealWorkspace.create() {
    final temporary = Directory.systemTemp.createTempSync('kehai_vcs_real_');
    final directory = Directory(p.join(temporary.path, 'repo'))..createSync();
    return _RealWorkspace._(temporary, directory);
  }

  final Directory temporary;
  final Directory directory;

  void write(String relativePath, String contents) {
    final file = File(p.join(directory.path, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  }

  Future<void> initGit({String branch = 'main'}) =>
      _gitOk(directory, ['init', '--initial-branch', branch]);

  Future<void> commit(String message) async {
    await _gitOk(directory, ['add', '--all']);
    await _gitOk(directory, [
      'commit',
      '--no-gpg-sign',
      '--message',
      message,
      '--message',
      _coAuthor,
    ]);
  }

  Future<void> initJj() async {
    final result = await Process.run('jj', [
      'git',
      'init',
      '--colocate',
    ], workingDirectory: directory.path);
    expect(
      result.exitCode,
      0,
      reason: 'jj git init --colocate failed: ${result.stderr}',
    );
    File(
      p.join(directory.path, '.jj', 'repo', 'config.toml'),
    ).writeAsStringSync('[user]\nname = "$_gitName"\nemail = "$_gitEmail"\n');
  }

  Future<void> dispose() => temporary.delete(recursive: true);
}
