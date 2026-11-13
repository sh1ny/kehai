import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kehai/kehai.dart';
import 'package:kehai/src/tools/file_access.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/mutation_support.dart';
import '../workspace/link_support.dart';
import '../support/attribution_support.dart' as attribution;

import 'package:kehai/src/tools/mutation_runs.dart';
import 'package:kehai/src/workspace/vcs_collector.dart';
import 'package:kehai/src/workspace/workspace_perception.dart';

void main() {
  for (final tool in ['write', 'edit']) {
    test(
      '$tool records resolved target, resulting bytes and quiescence',
      () async {
        final h = await MutationHarness.create();
        final file = h.file('lib/a.txt', 'before\n');
        await _capture(h.root.path, h.writer, h.runtime.mutations, []);
        if (tool == 'write') {
          await h.write('successful', 'lib/a.txt', 'after\n', stepTurn: 0);
        } else {
          await h.edit('successful', 'lib/a.txt', 'after', stepTurn: 0);
        }
        expect(file.readAsStringSync(), 'after\n');
        final call = h.call('successful');
        expect(call['target'], 'lib/a.txt');
        expect(
          call['effect'],
          allOf(
            containsPair(
              'sha256',
              sha256.convert(file.readAsBytesSync()).toString(),
            ),
            containsPair('seq', greaterThan(0)),
          ),
        );
        expect(call['quiesced'], isTrue);
        expect(call['status'], 'settled');
        await _nextTurn(h.writer);
        final frame = await _capture(
          h.root.path,
          h.writer,
          h.runtime.mutations,
          [_delta('lib/a.txt')],
        );
        _expectBy(
          frame,
          'lib/a.txt',
          SensoriumChangeBy.agent,
          userEdits: false,
        );
      },
    );
  }

  test('target records the resolved symlink destination', () async {
    final h = await MutationHarness.create();
    final destination = h.file('lib/a.dart', 'before\n');
    Link(p.join(h.root.path, 'alias.dart')).createSync(destination.path);

    await _capture(h.root.path, h.writer, h.runtime.mutations, []);
    await h.write('alias', 'alias.dart', 'after\n', stepTurn: 0);
    expect(destination.readAsStringSync(), 'after\n');
    expect(h.call('alias')['target'], 'lib/a.dart');
    expect(
      h.call('alias')['effect'],
      allOf(
        containsPair(
          'sha256',
          sha256.convert(destination.readAsBytesSync()).toString(),
        ),
        containsPair('seq', greaterThan(0)),
      ),
    );
    await _nextTurn(h.writer);
    final frame = await _capture(h.root.path, h.writer, h.runtime.mutations, [
      _delta('lib/a.dart'),
    ]);
    _expectBy(frame, 'lib/a.dart', SensoriumChangeBy.agent, userEdits: false);
  });

  test('target is recorded before the rename starts', () async {
    final held = HeldRename();
    final h = await MutationHarness.create(
      seams: FileWriteSeams(rename: held.rename),
    );
    final file = h.file('lib/a.dart', 'before\n');
    Link(p.join(h.root.path, 'alias.dart')).createSync(file.path);
    await _capture(h.root.path, h.writer, h.runtime.mutations, []);
    final pending = h.write('held', 'alias.dart', 'after\n', stepTurn: 0);
    await held.entered.future;
    try {
      final call = h.call('held');
      expect(call['target'], 'lib/a.dart');
      expect(call.containsKey('effect'), isFalse);
      expect(call['quiesced'], isNot(true));
      expect(file.readAsStringSync(), 'before\n');
      await h.runtime.cancelTurn();
      await pending;
      await h.drain(held);
      await _nextTurn(h.writer);
      final frame = await _capture(h.root.path, h.writer, h.runtime.mutations, [
        _delta('lib/a.dart'),
      ]);
      _expectBy(
        frame,
        'lib/a.dart',
        SensoriumChangeBy.unknown,
        userEdits: false,
      );
    } finally {
      await h.drain(held);
      await pending;
    }
  });

  test('retargeted symlink does not redirect provenance', () async {
    final held = HeldRename();
    final h = await MutationHarness.create(
      seams: FileWriteSeams(rename: held.rename),
    );
    final original = h.file('lib/a.dart', 'original\n');
    final other = h.file('lib/b.dart', 'other\n');
    final alias = Link(p.join(h.root.path, 'alias.dart'))
      ..createSync(original.path);
    await _capture(h.root.path, h.writer, h.runtime.mutations, []);
    final pending = h.write('retarget', 'alias.dart', 'late\n', stepTurn: 0);
    await held.entered.future;
    try {
      await h.runtime.cancelTurn();
      await pending;
      await h.drain(held);
      alias.deleteSync();
      alias.createSync(other.path);
      await h.runtime.close();
      await h.writer.close();
      final reopened = await SessionWriter.open(h.writer.sessionDir);
      addTearDown(reopened.close);
      final recovered = await ToolRuntime.attach(
        reopened,
        ResultStore(reopened.sessionDir),
        workspace: h.root,
        gate: const AllowAllStage(),
      );
      addTearDown(recovered.close);

      final call = mutationNode(reopened, 'body/calls/${callKey('retarget')}');
      expect(call['target'], 'lib/a.dart');
      expect(original.readAsStringSync(), 'late\n');
      expect(other.readAsStringSync(), 'other\n');
      expect(File(alias.path).readAsStringSync(), 'other\n');
      other.writeAsStringSync('user edit\n');
      await _nextTurn(reopened);
      final observer = attribution.CallbackWorkspaceObserver((request) {
        final changes = [_delta('lib/a.dart'), _delta('lib/b.dart')];
        return attribution.availableCollection(
          request,
          id: 'resumed-${request.turn}',
          changes: changes,
          verification: {
            'lib/a.dart': attribution.verifiedFile(original),
            'lib/b.dart': attribution.verifiedFile(other),
          },
        );
      });
      final frame = await attribution
          .captureWorkspace(
            WorkspacePerception(
              root: h.root.path,
              observer: observer,
              mutations: recovered.mutations,
            ),
            reopened,
          )
          .collect();
      attribution.composeWorkspaceFrame(frame);
      await attribution.admitWorkspaceFrame(reopened, frame);
      _expectBy(
        frame,
        'lib/a.dart',
        SensoriumChangeBy.unknown,
        userEdits: true,
      );
      _expectBy(frame, 'lib/b.dart', SensoriumChangeBy.user, userEdits: true);
    } finally {
      if (!held.release.isCompleted) await h.drain(held);
    }
  });

  test('symlinked parent resolves to the real repo path', () async {
    final h = await MutationHarness.create();
    final file = h.file('lib/generated/x.dart', 'before\n');
    linkDirectory(p.join(h.root.path, 'gen'), file.parent.path);

    await _capture(h.root.path, h.writer, h.runtime.mutations, []);
    await h.edit('parent-link', 'gen/x.dart', 'after', stepTurn: 0);

    expect(file.readAsStringSync(), 'after\n');
    expect(h.call('parent-link')['target'], 'lib/generated/x.dart');
    expect(
      h.call('parent-link')['effect'],
      allOf(
        containsPair(
          'sha256',
          sha256.convert(file.readAsBytesSync()).toString(),
        ),
        containsPair('seq', greaterThan(0)),
      ),
    );
    await _nextTurn(h.writer);
    final frame = await _capture(h.root.path, h.writer, h.runtime.mutations, [
      _delta('lib/generated/x.dart'),
    ]);
    _expectBy(
      frame,
      'lib/generated/x.dart',
      SensoriumChangeBy.agent,
      userEdits: false,
    );
  });

  test('reversed completion stores increasing effect order and restored older bytes cannot claim agent', () async {
    final stage = _HeldCall('order-a');
    final h = await MutationHarness.create(gate: stage);
    final file = h.file('lib/order.txt', 'before\n');
    await _capture(h.root.path, h.writer, h.runtime.mutations, []);
    final a = h.write('order-a', 'lib/order.txt', 'A\n', stepTurn: 0);
    addTearDown(() async {
      if (!stage.release.isCompleted) stage.release.complete();
      await a;
    });
    await stage.entered.future;
    await h.write('order-b', 'lib/order.txt', 'B\n', stepTurn: 0);
    stage.release.complete();
    await a;

    expect(file.readAsStringSync(), 'A\n');
    expect(
      _effectSequence(h, 'order-a'),
      greaterThan(_effectSequence(h, 'order-b')),
    );
    file.writeAsStringSync('B\n');
    await _nextTurn(h.writer);
    final frame = await _capture(h.root.path, h.writer, h.runtime.mutations, [
      _delta('lib/order.txt'),
    ]);
    _expectBy(
      frame,
      'lib/order.txt',
      SensoriumChangeBy.unknown,
      userEdits: false,
    );
  });

  test('delayed effect keeps the resolved-target slot and restored older bytes cannot claim agent', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final renames = <String>[];
    final h = await MutationHarness.create(
      seams: FileWriteSeams(
        rename: (from, to) async {
          await File(from).rename(to);
          renames.add(File(to).readAsStringSync());
        },
      ),
      runtimeSeams: ToolRuntimeSeams(
        beforeMutationEffect: (key) async {
          if (key != callKey('delayed-a')) return;
          entered.complete();
          await release.future;
        },
      ),
    );
    final file = h.file('lib/delayed.txt', 'before\n');
    await _capture(h.root.path, h.writer, h.runtime.mutations, []);
    final a = h.write('delayed-a', 'lib/delayed.txt', 'A\n', stepTurn: 0);
    Future<ToolOutputItem>? b;
    Future<void>? probe;
    addTearDown(() async {
      if (!release.isCompleted) release.complete();
      await a;
      if (b case final pending?) await pending;
      if (probe case final pending?) await pending;
    });
    await entered.future;
    expect(file.readAsStringSync(), 'A\n');

    var passedSlot = false;
    probe = PathLocks.run(file.resolveSymbolicLinksSync(), () async {
      passedSlot = true;
    });
    await Future<void>.value();
    b = h.write('delayed-b', 'lib/delayed.txt', 'B\n', stepTurn: 0);
    // If the slot were released before the effect, force B to finish first.
    // Otherwise release A so the real lock can admit the queued work.
    if (!passedSlot) release.complete();
    await b;
    if (!release.isCompleted) release.complete();
    await a;
    await probe;

    expect(renames, ['A\n', 'B\n']);
    expect(
      _effectSequence(h, 'delayed-b'),
      greaterThan(_effectSequence(h, 'delayed-a')),
    );
    file.writeAsStringSync('A\n');
    expect(file.readAsStringSync(), 'A\n');
    await _nextTurn(h.writer);
    final frame = await _capture(h.root.path, h.writer, h.runtime.mutations, [
      _delta('lib/delayed.txt'),
    ]);
    _expectBy(
      frame,
      'lib/delayed.txt',
      SensoriumChangeBy.unknown,
      userEdits: false,
    );
  });

  test(
    'case-variant writes followed by restoring earlier bytes read unknown',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      final bResolved = Completer<void>();
      var renames = 0;
      final seams = FileWriteSeams(
        beforeRename: () async {
          if (renames++ != 0) return;
          entered.complete();
          await release.future;
        },
      );
      final h = await MutationHarness.create(
        seams: seams,
        writeTool: _AfterRun(WriteTool(seams: seams), (id) {
          if (id == 'case-b') bResolved.complete();
        }),
      );
      await _capture(h.root.path, h.writer, h.runtime.mutations, []);
      final a = h.write('case-a', 'New.txt', 'A\n', stepTurn: 0);
      Future<ToolOutputItem>? b;
      addTearDown(() async {
        if (!release.isCompleted) release.complete();
        await a;
        if (b case final pending?) await pending;
      });
      await entered.future;
      b = h.write('case-b', 'new.txt', 'B\n', stepTurn: 0);
      await bResolved.future;
      release.complete();
      await Future.wait([a, b]);

      expect((h.call('case-a')['target']! as String).toLowerCase(), 'new.txt');
      expect((h.call('case-b')['target']! as String).toLowerCase(), 'new.txt');
      _effectSequence(h, 'case-a');
      _effectSequence(h, 'case-b');
      expect(
        h.call('case-a')['effect'],
        containsPair('sha256', sha256.convert(utf8.encode('A\n')).toString()),
      );
      expect(
        h.call('case-b')['effect'],
        containsPair('sha256', sha256.convert(utf8.encode('B\n')).toString()),
      );
      h.file('New.txt').writeAsStringSync('A\n');
      await _nextTurn(h.writer);
      final frame = await _capture(h.root.path, h.writer, h.runtime.mutations, [
        _delta('New.txt'),
      ]);
      _expectBy(frame, 'New.txt', SensoriumChangeBy.unknown, userEdits: false);
    },
  );

  test(
    'effect high-water is durable before effect and survives restart',
    () async {
      final h = await MutationHarness.create();
      h.file('lib/resume.txt', 'before\n');
      final reserved = h.runtime.mutations.sequence.reserve();
      final effectSeen = Completer<void>();
      var high = 0;
      var highAtEffect = 0;
      final sub = h.writer.subscribe().listen((update) {
        final record = update.record;
        if (record.value case {'seqHigh': final int value}
            when record.path == 'meta/vcs') {
          high = value;
        }
        if (record.value case {'effect': final Map<String, Object?> _}
            when record.path == 'body/calls/${callKey('before-restart')}') {
          highAtEffect = high;
          effectSeen.complete();
        }
      });
      addTearDown(sub.cancel);
      await h.write('before-restart', 'lib/resume.txt', 'first\n');
      await effectSeen.future;
      final before = _effectSequence(h, 'before-restart');
      expect(before, greaterThan(reserved));
      expect(highAtEffect, greaterThanOrEqualTo(before));
      await h.runtime.close();
      await h.writer.close();

      final writer = await SessionWriter.open(h.writer.sessionDir);
      addTearDown(writer.close);
      final runtime = await ToolRuntime.attach(
        writer,
        ResultStore(writer.sessionDir),
        workspace: h.root,
        gate: const AllowAllStage(),
        tools: {'write': const WriteTool()},
      );
      addTearDown(runtime.close);
      await runtime.run(
        ToolCall(
          callId: 'after-restart',
          name: 'write',
          argumentsJson: jsonEncode({
            'path': 'lib/resume.txt',
            'content': 'second\n',
          }),
        ),
      );
      final effect =
          mutationNode(
                writer,
                'body/calls/${callKey('after-restart')}',
              )['effect']!
              as Map<String, Object?>;
      expect(effect['seq'], greaterThan(before));
      expect(
        mutationNode(writer, 'meta/vcs')['seqHigh'],
        greaterThanOrEqualTo(effect['seq']! as int),
      );
    },
  );

  test(
    'target boundary includes earlier durable effects before rename',
    () async {
      final held = HeldRename();
      var holdNext = false;
      final h = await MutationHarness.create(
        seams: FileWriteSeams(
          rename: (from, to) async {
            if (holdNext) {
              await held.rename(from, to);
            } else {
              await File(from).rename(to);
            }
          },
        ),
      );
      h.file('lib/boundary.txt', 'before\n');
      await _capture(h.root.path, h.writer, h.runtime.mutations, []);
      await h.write('earlier-effect', 'lib/boundary.txt', 'B\n', stepTurn: 0);
      final earlier = _effectSequence(h, 'earlier-effect');
      // An unadmitted preview must not become the durable target boundary.
      h.runtime.mutations.sequence.reserve();
      holdNext = true;
      final pending = h.write(
        'later-target',
        'lib/boundary.txt',
        'A\n',
        stepTurn: 0,
      );
      addTearDown(() async {
        held.unblock();
        await pending;
      });
      await held.entered.future;
      try {
        expect(h.call('later-target')['targetAfterSeq'], earlier);
        await _nextTurn(h.writer);
        final frame = await _capture(
          h.root.path,
          h.writer,
          h.runtime.mutations,
          [_delta('lib/boundary.txt')],
        );
        _expectBy(
          frame,
          'lib/boundary.txt',
          SensoriumChangeBy.unknown,
          userEdits: false,
        );
      } finally {
        held.unblock();
        await pending;
      }
    },
  );
}

int _effectSequence(MutationHarness h, String id) {
  final effect = h.call(id)['effect'];
  expect(effect, containsPair('seq', greaterThan(0)));
  return (effect! as Map<String, Object?>)['seq']! as int;
}

final class _HeldCall implements CallStage {
  _HeldCall(this.id);

  final String id;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<StageOutcome> check(StageCall call, CancelToken cancel) async {
    if (call.callId == id) {
      entered.complete();
      await release.future;
    }
    return const StageOutcome.proceed();
  }
}

final class _AfterRun implements Tool {
  _AfterRun(this.tool, this.afterRun);

  final Tool tool;
  final void Function(String id) afterRun;

  @override
  Future<ToolOutcome> run(ToolContext context, Map<String, Object?> input) {
    final pending = tool.run(context, input);
    afterRun(context.callId);
    return pending;
  }
}

Future<WorkspacePerceptionFrame> _capture(
  String root,
  SessionWriter writer,
  MutationRuns mutations,
  List<VcsDelta> changes,
) async {
  final observer = attribution.CallbackWorkspaceObserver((request) {
    final verification = <String, VcsVerification>{};
    for (final change in changes) {
      final file = File(p.joinAll([root, ...p.posix.split(change.path)]));
      if (file.existsSync())
        verification[change.path] = attribution.verifiedFile(file);
    }
    return attribution.availableCollection(
      request,
      id: 'fixture-${request.turn}',
      changes: changes,
      verification: verification,
    );
  });
  final frame = await attribution
      .captureWorkspace(
        WorkspacePerception(
          root: root,
          observer: observer,
          mutations: mutations,
        ),
        writer,
      )
      .collect();
  attribution.composeWorkspaceFrame(frame);
  await attribution.admitWorkspaceFrame(writer, frame);
  return frame;
}

void _expectBy(
  WorkspacePerceptionFrame frame,
  String path,
  SensoriumChangeBy by, {
  required bool userEdits,
}) {
  final changes = frame.changes;
  expect(changes, isA<SensoriumAvailable<SensoriumChanges>>());
  final rows = (changes as SensoriumAvailable<SensoriumChanges>).value.rows;
  expect(rows.singleWhere((row) => row.path == path).by, by);
  expect(frame.notices.contains(SensoriumNotice.userEdits), userEdits);
  final text = attribution.composeWorkspaceFrame(frame).text;
  expect(text, contains(path));
  expect(text, contains('by: ${by.name}'));
  expect(text.contains('user_edits'), userEdits);
}

Future<void> _nextTurn(SessionWriter writer) => writer.apply(
  JournalRecord(
    turn: writer.currentTurn + 1,
    path: 'body/markers/${writer.currentTurn + 1}',
    op: Op.set,
    value: true,
  ),
);
VcsDelta _delta(String path) =>
    VcsDelta(path: path, added: 1, removed: 0, binary: false);
