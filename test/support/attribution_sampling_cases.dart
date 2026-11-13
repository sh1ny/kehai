import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kehai/kehai.dart';
import 'package:kehai/src/workspace/vcs_collector.dart';
import 'package:kehai/src/workspace/workspace_perception.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'attribution_support.dart';
import 'mutation_support.dart';
import 'vcs_support.dart';

const _maxAttributionFileBytes = 4 * 1024 * 1024;
const _requestDeadline = Duration(milliseconds: 300);
const _prehashFractionForDefaultDeadline = Duration(milliseconds: 100);

/// Registers bounded-attribution tests used by the loop attribution suite.
void registerAttributionSamplingTests() {
  group('bounded attribution sampling', () {
    test('file over 4 MiB reads unknown without hashing', () async {
      const path = 'sampling/oversized.bin';
      final reader = _ControlledFileReader();
      final fixture = await _createFixture([path], reader);
      const oversizedBytes = _maxAttributionFileBytes + 1;
      final oversized = 'x' * oversizedBytes;
      await _writeEffect(fixture, path, oversized, id: 'oversized');

      final frame = await _capture(fixture);

      expect(fixture.harness.file(path).lengthSync(), oversizedBytes);
      _expectUnknown(frame, path);
      expect(
        reader.hashedPaths.any(
          (absolute) => _relativePath(fixture, absolute) == path,
        ),
        isFalse,
      );
    });

    test('held read is abandoned within the overall deadline and its row reads unknown', () async {
      const path = 'sampling/held-before.txt';
      final reader = _ControlledFileReader(holdWhen: (_, _) => true);
      final fixture = await _createFixture([path], reader);
      await _writeEffect(fixture, path, 'written by the agent', id: 'held');

      final pending = _capture(fixture);
      await reader.waitForCount(1);
      await fixture.clock.waitForDuration(_prehashFractionForDefaultDeadline);
      fixture.clock.advance(_prehashFractionForDefaultDeadline);
      final frame = await pending;

      _expectUnknown(frame, path);
      expect(frame.notices, isNot(contains(SensoriumNotice.vcsTimeout)));
      await admitWorkspaceFrame(fixture.harness.writer, frame);
      final admitted = _admittedSensorium(fixture, frame.source.turn);

      await reader.completeHeld(0);

      _expectUnknown(frame, path);
      expect(_admittedSensorium(fixture, frame.source.turn), admitted);
    });

    test('nonzero lock wait reduces pre-hash budget; fresh capture has unknown row without vcs_timeout', () async {
      const path = 'sampling/lock-wait.txt';
      final reader = _ControlledFileReader(holdWhen: (index, _) => index >= 3);
      final fixture = await _createFixture([path], reader);
      await _writeEffect(fixture, path, 'written by the agent', id: 'locked');
      fixture.git.branch = 'fresh-after-lock';
      fixture.git.tree = '2222222222222222222222222222222222222222';

      final heldProcess = FakeVcsProcess();
      fixture.git.holdNextAdd = heldProcess;
      final priorProcessCount = fixture.git.runner.processes.length;
      final lockHolder = _capture(fixture);
      await fixture.git.runner.waitForInvocation(
        (invocation) =>
            fixture.git.runner.processIndex(invocation) >= priorProcessCount &&
            invocation.arguments.contains('add'),
      );

      final waitingCapture = _capture(fixture);
      fixture.clock.advance(const Duration(milliseconds: 90));
      heldProcess.finish(successResult());
      await lockHolder;
      await reader.waitForCount(3);
      await fixture.clock.waitForDuration(const Duration(milliseconds: 70));
      fixture.clock.advance(const Duration(milliseconds: 70));
      final frame = await waitingCapture;

      _expectUnknown(frame, path);
      expect(frame.notices, isNot(contains(SensoriumNotice.vcsTimeout)));
      expect(_availableVcs(frame).branch, 'fresh-after-lock');
      expect(frame.metadata['state'], 'available');
      expect(fixture.clock.elapsed, const Duration(milliseconds: 160));
      expect(
        fixture.clock.durations,
        contains(const Duration(milliseconds: 70)),
      );
    });

    test('post-hash expiry retains fresh capture and baseline with unknown row and vcs_timeout', () async {
      const path = 'sampling/post-hash.txt';
      final reader = _ControlledFileReader(holdWhen: (index, _) => index == 2);
      final fixture = await _createFixture([path], reader);
      await _writeEffect(
        fixture,
        path,
        'written by the agent',
        id: 'post-hash',
      );
      fixture.git.branch = 'fresh-at-deadline';
      fixture.git.tree = '3333333333333333333333333333333333333333';

      final pending = _capture(fixture);
      await reader.waitForCount(2);
      await fixture.clock.waitForDuration(_requestDeadline);
      fixture.clock.advance(_requestDeadline);
      final frame = await pending;

      _expectUnknown(frame, path);
      expect(frame.notices, contains(SensoriumNotice.vcsTimeout));
      expect(_availableVcs(frame).branch, 'fresh-at-deadline');
      expect(frame.metadata['state'], 'available');
      expect(frame.metadata['baseline'], isNotNull);
      expect(
        frame.baselineSequence,
        greaterThan(fixture.baseline.baselineSequence!),
      );
      expect(
        fixture.git.runner.invocations.any(
          (invocation) => invocation.arguments.contains('--numstat'),
        ),
        isTrue,
      );
      expect(
        fixture.git.runner.processes.every((process) => !process.isPending),
        isTrue,
      );
    });

    test('paths beyond 64 read unknown', () async {
      final effectPaths = [
        for (var i = 0; i < 100; i++)
          p.posix.join('many', 'file-${i.toString().padLeft(3, '0')}.txt'),
      ];
      final vcsOrder = effectPaths.reversed.toList();
      final reader = _ControlledFileReader();
      final fixture = await _createFixture(vcsOrder, reader);
      await _writeEffects(fixture, effectPaths);

      final frame = await _capture(fixture);
      final changes = _availableChanges(frame);
      final sampledPaths = reader.hashedPaths
          .map((absolute) => _relativePath(fixture, absolute))
          .toSet();
      final visibleUnhashed = changes.rows
          .where((row) => !sampledPaths.contains(row.path))
          .toList();

      expect(reader.maxActive, lessThanOrEqualTo(64));
      expect(sampledPaths.length, lessThanOrEqualTo(64));
      expect(changes.totalPaths, 100);
      expect(changes.rows.length, lessThanOrEqualTo(12));
      expect(visibleUnhashed, isNotEmpty);
      for (final row in visibleUnhashed) {
        expect(row.by, SensoriumChangeBy.unknown);
      }
      expect(composeWorkspaceFrame(frame).text, contains('… +88 more'));
    });

    test('abandoned reads never exceed 64 engine-wide', () async {
      final effectPaths = [
        for (var i = 0; i < 100; i++)
          p.posix.join('many', 'file-${i.toString().padLeft(3, '0')}.txt'),
      ];
      final reader = _ControlledFileReader(holdWhen: (_, _) => true);
      final fixture = await _createFixture(effectPaths.reversed, reader);
      await _writeEffects(fixture, effectPaths);

      final firstPending = _capture(fixture);
      await reader.waitForCount(64);
      await fixture.clock.waitForDuration(_prehashFractionForDefaultDeadline);
      fixture.clock.advance(_prehashFractionForDefaultDeadline);
      final firstFrame = await firstPending;
      _expectUnknown(firstFrame, effectPaths.last);

      var built = 1;
      for (var i = 1; i < 100; i++) {
        final frame = await _capture(fixture);
        built++;
        _expectUnknown(frame, effectPaths.last);
      }
      expect(built, 100);
      expect(reader.calls, hasLength(64));
      expect(reader.maxActive, 64);
      expect(reader.active, 64);

      await admitWorkspaceFrame(fixture.harness.writer, firstFrame);
      final admittedBeforeLateRead = _admittedSensorium(
        fixture,
        firstFrame.source.turn,
      );
      await reader.completeHeld(0);
      expect(reader.active, 63);

      const laterPath = 'many/after-admission.txt';
      fixture.git.addChangeAtFront(laterPath);
      await _writeEffect(
        fixture,
        laterPath,
        'effect after admitted capture',
        id: 'after-admission',
        stepTurn: firstFrame.source.turn,
      );
      final laterCapture = _capture(fixture);
      final newReadStarted = await Future.any<bool>([
        reader.waitForCount(65).then((_) => true),
        laterCapture.then((_) => false),
      ]);
      expect(newReadStarted, isTrue);
      fixture.clock.advance(_prehashFractionForDefaultDeadline);
      final laterFrame = await laterCapture;

      expect(reader.calls, hasLength(65));
      expect(reader.active, 64);
      _expectUnknown(laterFrame, laterPath);
      _expectUnknown(firstFrame, effectPaths.last);
      expect(
        _admittedSensorium(fixture, firstFrame.source.turn),
        admittedBeforeLateRead,
      );
    });
  });

  group('attribution timeout process ownership', () {
    test('attribution-only expiry creates no VCS cleanup lease', () async {
      const path = 'sampling/repeated-post-hash.txt';
      final reader = _ControlledFileReader(
        holdWhen: (index, _) => index.isEven,
      );
      final fixture = await _createFixture([path], reader);
      await _writeEffect(fixture, path, 'written by the agent', id: 'repeated');
      fixture.git.branch = 'complete-command-plan';

      for (var request = 0; request < 17; request++) {
        final expectedReadCount = (request + 1) * 2;
        final pending = _capture(fixture);
        final postReadStarted = await Future.any<bool>([
          reader.waitForCount(expectedReadCount).then((_) => true),
          pending.then((_) => false),
        ]);
        expect(postReadStarted, isTrue);
        fixture.clock.advance(_requestDeadline);
        final frame = await pending;

        expect(frame.notices, contains(SensoriumNotice.vcsTimeout));
        expect(frame.metadata['state'], 'available');
        expect(_availableVcs(frame).branch, 'complete-command-plan');
        expect(
          fixture.git.runner.processes.every(
            (process) => !process.isPending && process.terminationCalls == 0,
          ),
          isTrue,
        );
      }

      expect(
        fixture.git.runner.invocations.where(
          (invocation) => invocation.arguments.contains('--numstat'),
        ),
        hasLength(17),
      );
    });
  });
}

Future<_SamplingFixture> _createFixture(
  Iterable<String> vcsOrder,
  _ControlledFileReader reader,
) async {
  final harness = await MutationHarness.create();
  final git = _ScenarioVcsRunner(vcsOrder);
  final clock = ManualVcsDeadlineScheduler();
  final collector = VcsCollector(
    processRunner: git.runner,
    deadlineScheduler: clock,
    readFile: reader.read,
  );
  addTearDown(() async {
    await reader.releaseAll();
    await collector.close();
  });
  final perception = workspacePerception(
    harness,
    collector,
    backend: 'git',
    deadline: _requestDeadline,
  );
  final baseline = await captureWorkspace(perception, harness.writer).collect();
  await admitWorkspaceFrame(harness.writer, baseline);
  return _SamplingFixture(
    harness: harness,
    git: git,
    clock: clock,
    perception: perception,
    baseline: baseline,
  );
}

Future<void> _writeEffect(
  _SamplingFixture fixture,
  String path,
  String content, {
  required String id,
  int? stepTurn,
}) => fixture.harness.write(
  id,
  path,
  content,
  stepTurn: stepTurn ?? fixture.baseline.source.turn,
);

Future<void> _writeEffects(
  _SamplingFixture fixture,
  Iterable<String> paths,
) async {
  var index = 0;
  for (final path in paths) {
    await _writeEffect(fixture, path, 'effect-$index', id: 'effect-$index');
    index++;
  }
}

Future<WorkspacePerceptionFrame> _capture(_SamplingFixture fixture) async {
  final writer = fixture.harness.writer;
  if (mutationNode(writer, mutationStepPath(writer.currentTurn))['sensorium']
      is Map<String, Object?>) {
    await fixture.harness.nextTurn();
  }
  return captureWorkspace(fixture.perception, writer).collect();
}

SensoriumChanges _availableChanges(WorkspacePerceptionFrame frame) {
  final observation = frame.changes;
  if (observation is SensoriumAvailable<SensoriumChanges>) {
    return observation.value;
  }
  throw StateError(
    'Expected available changes, got ${observation.runtimeType}',
  );
}

SensoriumVcs _availableVcs(WorkspacePerceptionFrame frame) {
  final observation = frame.vcs;
  if (observation is SensoriumAvailable<SensoriumVcs>) {
    return observation.value;
  }
  throw StateError('Expected available VCS, got ${observation.runtimeType}');
}

void _expectUnknown(WorkspacePerceptionFrame frame, String path) {
  final rows = _availableChanges(frame).rows
      .where((row) => row.path == path)
      .toList();
  expect(rows, hasLength(1), reason: 'expected a visible row for $path');
  expect(rows.single.by, SensoriumChangeBy.unknown);
}

String _relativePath(_SamplingFixture fixture, String absolutePath) =>
    p.relative(absolutePath, from: fixture.harness.root.path);

String _admittedSensorium(_SamplingFixture fixture, int turn) {
  final step = mutationNode(fixture.harness.writer, mutationStepPath(turn));
  return jsonEncode((step['sensorium'] as Map<String, Object?>));
}

final class _SamplingFixture {
  const _SamplingFixture({
    required this.harness,
    required this.git,
    required this.clock,
    required this.perception,
    required this.baseline,
  });

  final MutationHarness harness;
  final _ScenarioVcsRunner git;
  final ManualVcsDeadlineScheduler clock;
  final WorkspacePerception perception;
  final WorkspacePerceptionFrame baseline;
}

final class _ScenarioVcsRunner {
  _ScenarioVcsRunner(Iterable<String> paths) {
    changePaths.addAll(paths);
    runner = FakeVcsProcessRunner(processFor: _respond);
  }

  final List<String> changePaths = [];
  late final FakeVcsProcessRunner runner;
  String branch = 'baseline';
  String tree = '1111111111111111111111111111111111111111';
  FakeVcsProcess? holdNextAdd;

  void addChangeAtFront(String path) => changePaths.insert(0, path);

  FakeVcsProcess _respond(VcsInvocation invocation) {
    final arguments = invocation.arguments;
    final heldAdd = holdNextAdd;
    if (heldAdd != null && arguments.contains('add')) {
      holdNextAdd = null;
      return heldAdd;
    }
    if (arguments.contains('--show-toplevel')) {
      return completedProcess(
        successResult(stdout: utf8.encode('${invocation.workingDirectory}\n')),
      );
    }
    if (arguments.contains('--git-path')) {
      return completedProcess(
        successResult(
          stdout: utf8.encode(
            p.join(invocation.workingDirectory, '.git', 'index'),
          ),
        ),
      );
    }
    if (arguments.contains('status')) {
      return completedProcess(
        successResult(
          stdout: gitStatusV2(
            branch: branch,
            oid: '0123456789abcdef0123456789abcdef01234567',
            modified: changePaths,
          ),
        ),
      );
    }
    if (arguments.contains('--name-status')) {
      return completedProcess(
        successResult(stdout: gitNameStatusZ(modified: changePaths)),
      );
    }
    if (arguments.contains('--numstat')) {
      return completedProcess(
        successResult(
          stdout: gitNumstatZ([for (final path in changePaths) '1\t0\t$path']),
        ),
      );
    }
    if (arguments.contains('write-tree')) {
      return completedProcess(successResult(stdout: utf8.encode('$tree\n')));
    }
    if (arguments.contains('--abbrev-ref')) {
      return completedProcess(successResult(stdout: utf8.encode('$branch\n')));
    }
    if (arguments.contains('HEAD')) {
      return completedProcess(
        successResult(
          stdout: utf8.encode('0123456789abcdef0123456789abcdef01234567\n'),
        ),
      );
    }
    if (arguments.contains('hash-object')) {
      return completedProcess(
        successResult(stdout: utf8.encode('empty-tree\n')),
      );
    }
    return completedProcess(successResult());
  }
}

final class _ControlledFileReader {
  _ControlledFileReader({this.holdWhen});

  final bool Function(int index, String absolutePath)? holdWhen;
  final List<_RecordedRead> calls = [];
  final List<_RecordedRead> _held = [];
  final List<String> hashedPaths = [];
  final List<_ReadCountWaiter> _waiters = [];
  int active = 0;
  int maxActive = 0;

  Future<VcsFileSample?> read(String absolutePath, int maxBytes) {
    final call = _RecordedRead(absolutePath, maxBytes);
    calls.add(call);
    _notifyWaiters();
    final file = File(absolutePath);
    if (file.lengthSync() > maxBytes) {
      call.settled.complete();
      return Future.value(null);
    }

    final held = holdWhen?.call(calls.length, absolutePath) ?? false;
    if (held) _held.add(call);
    active++;
    if (active > maxActive) maxActive = active;
    final result = held
        ? call.result.future
        : Future<VcsFileSample?>.sync(() => _sample(file, maxBytes));
    return result.whenComplete(() {
      active--;
      call.settled.complete();
    });
  }

  Future<void> waitForCount(int count) {
    if (calls.length >= count) return Future.value();
    final completer = Completer<void>();
    _waiters.add(_ReadCountWaiter(count, completer));
    return completer.future;
  }

  Future<void> completeHeld(int index) async {
    final read = _held[index];
    if (!read.result.isCompleted) {
      read.result.complete(_sample(File(read.absolutePath), read.maxBytes));
    }
    await read.settled.future;
  }

  Future<void> releaseAll() async {
    for (final read in _held) {
      if (!read.result.isCompleted) read.result.complete(null);
    }
    await Future.wait(_held.map((read) => read.settled.future));
  }

  VcsFileSample? _sample(File file, int maxBytes) {
    final stat = file.statSync();
    if (stat.size > maxBytes) return null;
    final bytes = file.readAsBytesSync();
    if (bytes.length > maxBytes) return null;
    hashedPaths.add(file.path);
    return (
      sha256: sha256.convert(bytes).toString(),
      size: bytes.length,
      modifiedMicros: stat.modified.microsecondsSinceEpoch,
    );
  }

  void _notifyWaiters() {
    for (final waiter in List<_ReadCountWaiter>.of(_waiters)) {
      if (calls.length >= waiter.count) {
        waiter.completer.complete();
        _waiters.remove(waiter);
      }
    }
  }
}

final class _RecordedRead {
  _RecordedRead(this.absolutePath, this.maxBytes);

  final String absolutePath;
  final int maxBytes;
  final Completer<VcsFileSample?> result = Completer<VcsFileSample?>();
  final Completer<void> settled = Completer<void>();
}

final class _ReadCountWaiter {
  const _ReadCountWaiter(this.count, this.completer);

  final int count;
  final Completer<void> completer;
}
