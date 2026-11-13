import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:kehai/src/workspace/vcs_collector.dart';
import 'package:path/path.dart' as p;

final class VcsWorkspace {
  VcsWorkspace._(this.temporary, this.directory);

  factory VcsWorkspace.create({bool git = false, bool jj = false}) {
    final temporary = Directory.systemTemp.createTempSync('kehai_vcs_');
    final directory = Directory(p.join(temporary.path, 'workspace'))
      ..createSync();
    if (git) {
      final metadata = Directory(p.join(directory.path, '.git'))..createSync();
      File(p.join(metadata.path, 'index'))
          .writeAsBytesSync(utf8.encode('private-index-fixture'));
    }
    if (jj) Directory(p.join(directory.path, '.jj')).createSync();
    return VcsWorkspace._(temporary, directory);
  }

  final Directory temporary;
  final Directory directory;

  String get root => directory.path;
  String get gitIndex => p.join(root, '.git', 'index');

  String writeFile(String relativePath, String contents) {
    final file = File(p.join(root, relativePath));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
    return file.path;
  }

  void dispose() => temporary.deleteSync(recursive: true);
}

final class VcsInvocation {
  VcsInvocation({
    required this.executable,
    required List<String> arguments,
    required this.workingDirectory,
    required Map<String, String> environment,
  }) : arguments = List.unmodifiable(arguments),
       environment = Map.unmodifiable(environment);

  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final Map<String, String> environment;
}

final class FakeVcsProcessRunner implements VcsProcessRunner {
  FakeVcsProcessRunner({required this.processFor});

  final FakeVcsProcess Function(VcsInvocation invocation) processFor;
  final List<VcsInvocation> invocations = [];
  final List<FakeVcsProcess> processes = [];
  final List<_InvocationWaiter> _waiters = [];

  @override
  Future<VcsProcess> start({
    required String executable,
    required List<String> arguments,
    required String workingDirectory,
    required Map<String, String> environment,
  }) async {
    final invocation = VcsInvocation(
      executable: executable,
      arguments: arguments,
      workingDirectory: workingDirectory,
      environment: environment,
    );
    invocations.add(invocation);
    final process = processFor(invocation);
    processes.add(process);
    for (final waiter in List<_InvocationWaiter>.of(_waiters)) {
      if (waiter.matches(invocation)) {
        waiter.completer.complete(invocation);
        _waiters.remove(waiter);
      }
    }
    return process;
  }

  Future<VcsInvocation> waitForInvocation(
    bool Function(VcsInvocation) matches,
  ) {
    for (final invocation in invocations) {
      if (matches(invocation)) return Future.value(invocation);
    }
    final completer = Completer<VcsInvocation>();
    _waiters.add(_InvocationWaiter(matches, completer));
    return completer.future;
  }

  int processIndex(VcsInvocation invocation) => invocations.indexOf(invocation);
}

final class _InvocationWaiter {
  const _InvocationWaiter(this.matches, this.completer);

  final bool Function(VcsInvocation) matches;
  final Completer<VcsInvocation> completer;
}

final class FakeVcsProcess implements VcsProcess {
  FakeVcsProcess({
    this.terminationResult = VcsTerminationResult.unverified,
    this.stallTermination = false,
  });

  factory FakeVcsProcess.completed(VcsProcessResult result) {
    final process = FakeVcsProcess();
    process.finish(result);
    return process;
  }

  final VcsTerminationResult terminationResult;
  final bool stallTermination;
  final Completer<VcsProcessResult> _result = Completer<VcsProcessResult>();
  final Completer<VcsTerminationResult> _termination =
      Completer<VcsTerminationResult>();
  int terminationCalls = 0;

  bool get isPending => !_result.isCompleted;

  @override
  Future<VcsProcessResult> get result => _result.future;

  void finish(VcsProcessResult result) {
    if (!_result.isCompleted) _result.complete(result);
  }

  void finishTermination(VcsTerminationResult result) {
    if (!_termination.isCompleted) _termination.complete(result);
  }

  @override
  Future<VcsTerminationResult> terminate() {
    terminationCalls++;
    if (stallTermination) return _termination.future;
    return Future.value(terminationResult);
  }
}

final class ManualVcsDeadlineScheduler implements VcsDeadlineScheduler {
  final List<Duration> durations = [];
  final List<Completer<void>> _deadlines = [];
  final List<Duration> _dueTimes = [];
  final List<_CountWaiter> _waiters = [];
  final List<_DurationWaiter> _durationWaiters = [];
  Duration _elapsed = Duration.zero;

  Duration get elapsed => _elapsed;

  @override
  Future<void> wait(Duration duration) {
    durations.add(duration);
    final deadline = Completer<void>();
    _deadlines.add(deadline);
    _dueTimes.add(_elapsed + duration);
    _notifyWaiters();
    _notifyDurationWaiters(duration);
    return deadline.future;
  }

  Future<void> waitForCount(int count) {
    if (_deadlines.length >= count) return Future.value();
    final completer = Completer<void>();
    _waiters.add(_CountWaiter(count, completer));
    return completer.future;
  }

  Future<void> waitForDuration(Duration duration) {
    if (durations.contains(duration)) return Future.value();
    final completer = Completer<void>();
    _durationWaiters.add(_DurationWaiter(duration, completer));
    return completer.future;
  }

  void advance(Duration duration) {
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'must not be negative');
    }
    _elapsed += duration;
    _completeDue();
  }

  void expire(int index) {
    final dueTime = _dueTimes[index];
    if (dueTime > _elapsed) _elapsed = dueTime;
    if (!_deadlines[index].isCompleted) _deadlines[index].complete();
  }

  void _completeDue() {
    for (var i = 0; i < _deadlines.length; i++) {
      if (_dueTimes[i] <= _elapsed && !_deadlines[i].isCompleted) {
        _deadlines[i].complete();
      }
    }
  }

  void _notifyWaiters() {
    for (final waiter in List<_CountWaiter>.of(_waiters)) {
      if (_deadlines.length >= waiter.count) {
        waiter.completer.complete();
        _waiters.remove(waiter);
      }
    }
  }

  void _notifyDurationWaiters(Duration duration) {
    for (final waiter in List<_DurationWaiter>.of(_durationWaiters)) {
      if (waiter.duration == duration) {
        waiter.completer.complete();
        _durationWaiters.remove(waiter);
      }
    }
  }
}

final class _CountWaiter {
  const _CountWaiter(this.count, this.completer);

  final int count;
  final Completer<void> completer;
}

final class _DurationWaiter {
  const _DurationWaiter(this.duration, this.completer);

  final Duration duration;
  final Completer<void> completer;
}

VcsProcessResult successResult({
  List<int> stdout = const [],
  List<int> stderr = const [],
}) => VcsProcessResult(exitCode: 0, stdout: stdout, stderr: stderr);

FakeVcsProcess completedProcess(VcsProcessResult result) =>
    FakeVcsProcess.completed(result);

FakeVcsProcessRunner fakeGitRunner({
  String branch = 'main',
  String head = '0123456789abcdef0123456789abcdef01234567',
  String tree = '1123456789abcdef0123456789abcdef01234567',
  List<String> modified = const [],
  List<String> stagedAndUnstagedModified = const [],
  List<String> added = const [],
  List<String> deleted = const [],
  List<String> untracked = const [],
  List<String> conflicts = const [],
  List<String> headModified = const [],
  List<String> headAdded = const [],
  List<String> headDeleted = const [],
  List<String> deltaNumstat = const [],
}) {
  final status = gitStatusV2(
    branch: branch,
    oid: head,
    modified: modified,
    stagedAndUnstagedModified: stagedAndUnstagedModified,
    added: added,
    deleted: deleted,
    untracked: untracked,
    conflicts: conflicts,
  );
  final headStatus = gitNameStatusZ(
    modified: headModified,
    added: headAdded,
    deleted: headDeleted,
  );
  final numstat = gitNumstatZ(deltaNumstat);

  return FakeVcsProcessRunner(
    processFor: (invocation) {
      final args = invocation.arguments;
      if (args.contains('write-tree')) {
        return completedProcess(successResult(stdout: utf8.encode('$tree\n')));
      }
      if (args.contains('--git-path')) {
        return completedProcess(
          successResult(
            stdout: utf8.encode(
              p.join(invocation.workingDirectory, '.git', 'index'),
            ),
          ),
        );
      }
      if (args.contains('status')) {
        return completedProcess(successResult(stdout: status));
      }
      if (args.contains('--name-status')) {
        return completedProcess(successResult(stdout: headStatus));
      }
      if (args.contains('--numstat')) {
        return completedProcess(successResult(stdout: numstat));
      }
      if (args.contains('--show-toplevel')) {
        return completedProcess(
          successResult(
            stdout: utf8.encode('${invocation.workingDirectory}\n'),
          ),
        );
      }
      if (args.contains('--abbrev-ref')) {
        return completedProcess(
          successResult(stdout: utf8.encode('$branch\n')),
        );
      }
      if (args.contains('HEAD')) {
        return completedProcess(successResult(stdout: utf8.encode('$head\n')));
      }
      return completedProcess(successResult());
    },
  );
}

List<int> gitStatusV2({
  required String branch,
  required String oid,
  List<String> modified = const [],
  List<String> stagedAndUnstagedModified = const [],
  List<String> added = const [],
  List<String> deleted = const [],
  List<String> untracked = const [],
  List<String> conflicts = const [],
}) {
  final output = BytesBuilder(copy: false)
    ..add(utf8.encode('# branch.oid $oid\u0000# branch.head $branch\u0000'));
  for (final path in modified) {
    output.add(
      utf8.encode('1 .M N... 100644 100644 100644 1111111 2222222 $path\u0000'),
    );
  }
  for (final path in stagedAndUnstagedModified) {
    output.add(
      utf8.encode('1 MM N... 100644 100644 100644 1111111 2222222 $path\u0000'),
    );
  }
  for (final path in added) {
    output.add(utf8.encode('? $path\u0000'));
  }
  for (final path in deleted) {
    output.add(
      utf8.encode('1 .D N... 100644 000000 000000 1111111 0000000 $path\u0000'),
    );
  }
  for (final path in conflicts) {
    output.add(
      utf8.encode(
        'u UU N... 100644 100644 100644 100644 1111111 2222222 3333333 $path\u0000',
      ),
    );
  }
  return output.takeBytes();
}

List<int> gitNameStatusZ({
  List<String> modified = const [],
  List<String> added = const [],
  List<String> deleted = const [],
}) {
  final output = BytesBuilder(copy: false);
  for (final (status, paths) in [
    ('M', modified),
    ('A', added),
    ('D', deleted),
  ]) {
    for (final path in paths) {
      output.add(utf8.encode('$status\u0000$path\u0000'));
    }
  }
  return output.takeBytes();
}

List<int> gitNumstatZ(List<String> records) =>
    utf8.encode(records.map((record) => '$record\u0000').join());

FakeVcsProcessRunner fakeJjRunner({
  String change = 'change-id',
  String commit = 'commit-id',
  String description = 'working change',
  List<String> parents = const ['parent-id'],
  List<(String, String)> statuses = const [],
  List<String> conflicts = const [],
  String operation = 'operation-id',
  String diff = '',
}) {
  final snapshot = jjSnapshotJsonl(
    change: change,
    commit: commit,
    description: description,
    parents: parents,
    statuses: statuses,
    conflicts: conflicts,
  );
  return FakeVcsProcessRunner(
    processFor: (invocation) {
      final args = invocation.arguments;
      if (args.contains('op')) {
        return completedProcess(
          successResult(stdout: utf8.encode('$operation\n')),
        );
      }
      if (args.contains('--git')) {
        return completedProcess(successResult(stdout: utf8.encode(diff)));
      }
      if (args.contains('log')) {
        return completedProcess(successResult(stdout: snapshot));
      }
      return completedProcess(successResult());
    },
  );
}

List<int> jjSnapshotJsonl({
  required String change,
  required String commit,
  required String description,
  required List<String> parents,
  List<(String, String)> statuses = const [],
  List<String> conflicts = const [],
}) {
  final rows = <Map<String, Object?>>[
    {
      'kind': 'identity',
      'commit': commit,
      'change': change,
      'description': description,
      'parents': parents,
    },
    for (final (path, status) in statuses)
      {'kind': 'status', 'path': path, 'status': status},
    for (final path in conflicts) {'kind': 'conflict', 'path': path},
  ];
  return utf8.encode('${rows.map(jsonEncode).join('\n')}\n');
}

String gitPatch({required String path, int added = 1, int removed = 0}) {
  final oldPath = _quoteGitPath('a/$path');
  final newPath = _quoteGitPath('b/$path');
  final oldRange = removed == 0 ? '0,0' : '1,$removed';
  final newRange = added == 0 ? '0,0' : '1,$added';
  final body = [
    for (var i = 0; i < removed; i++) '-old-$i',
    for (var i = 0; i < added; i++) '+new-$i',
  ].join('\n');
  return 'diff --git $oldPath $newPath\n'
      'index 1111111..2222222 100644\n'
      '--- $oldPath\n'
      '+++ $newPath\n'
      '@@ -$oldRange +$newRange @@\n'
      '$body\n';
}

String _quoteGitPath(String path) {
  if (!path.contains('\n') &&
      !path.contains('\r') &&
      !path.contains('"') &&
      !path.contains('\\')) {
    return path;
  }
  final escaped = path
      .replaceAll('\\', '\\\\')
      .replaceAll('"', '\\"')
      .replaceAll('\n', '\\n')
      .replaceAll('\r', '\\r');
  return '"$escaped"';
}
