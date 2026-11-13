/// Pre-ship round 4, F1: a mutation whose call was cancelled never changes
/// the file, not even when the lock it waited for is released afterwards.
/// Every test drives the real runtime and the real `write` and `edit` tools.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:kehai/src/tools/file_access.dart' show PathLocks;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/anchor_support.dart';
import '../support/job_support.dart';
import '../support/mutation_support.dart' as mutation;
import '../support/session_support.dart';
import '../support/attribution_support.dart' as attribution;

import 'package:kehai/src/workspace/vcs_collector.dart';
import 'package:kehai/src/workspace/workspace_perception.dart';

Future<(ToolRuntime, SessionWriter, Directory)> _attach({
  FileWriteSeams seams = const FileWriteSeams(),
}) async {
  final root = await tempDir();
  final writer = await createWriter(root);
  final runtime = await ToolRuntime.attach(
    writer,
    ResultStore(writer.sessionDir),
    workspace: root,
    gate: const AllowAllStage(),
    tools: {
      'write': WriteTool(seams: seams),
      'edit': EditTool(seams: seams),
    },
  );
  addTearDown(runtime.close);
  return (runtime, writer, root);
}

Map<Object?, Object?> _calls(SessionWriter writer) {
  final node = writer.tree.get(SessionPath.parse('body/calls'));
  return node is Map ? node : const {};
}

String _statusOf(SessionWriter writer, String callId) {
  final node = _calls(writer)[callKey(callId)];
  return node is Map<String, Object?> ? '${node['status']}' : 'absent';
}

Future<ToolOutputItem> _submit(
  ToolRuntime runtime,
  String id,
  String tool,
  Map<String, Object?> arguments,
) => runtime.run(
  ToolCall(callId: id, name: tool, argumentsJson: jsonEncode(arguments)),
);

List<String> _temporaries(Directory dir) => [
  for (final e in dir.listSync())
    if (p.basename(e.path).contains('.kehai-')) p.basename(e.path),
];

void main() {
  _provenanceCancellationTests();
  for (final tool in ['write', 'edit']) {
    test('F1: a $tool queued behind a file lock and then cancelled leaves '
        'the file untouched after the lock frees', () async {
      final (runtime, writer, root) = await _attach();
      final file = File(p.join(root.path, 'a.txt'))
        ..writeAsStringSync('base\n');
      final target = realPath(file.path)!;

      // Hold the lock the way an earlier same-file operation does.
      final release = Completer<void>();
      final held = Completer<void>();
      final holder = PathLocks.run(target, () {
        held.complete();
        return release.future;
      });
      await held.future;

      final arguments = tool == 'write'
          ? {'path': 'a.txt', 'content': 'overwritten\n'}
          : {
              'path': 'a.txt',
              'anchors': [
                '1#${definitionHashes(utf8.encode('base\n')).single}',
              ],
              'ops': [
                {'op': 'replace', 'start': 1, 'end': 1, 'text': 'overwritten'},
              ],
            };
      final answer = _submit(runtime, 'queued', tool, arguments);
      await waitFor(
        () => _statusOf(writer, 'queued') == 'running',
        what: 'the call to be running',
      );

      expect(await runtime.cancelTurn(), 1);
      expect(_statusOf(writer, 'queued'), 'cancelled');

      // Free the lock and wait for everything queued behind it to finish.
      release.complete();
      await holder;
      await PathLocks.run(target, () async {});
      await answer;

      expect(file.readAsStringSync(), 'base\n');
      expect(_statusOf(writer, 'queued'), 'cancelled');
      expect(_temporaries(root), isEmpty);
    });
  }

  for (final tool in ['write', 'edit']) {
    test(
      'F1: a $tool cancelled after it took the lock does not rename',
      () async {
        final entered = Completer<void>();
        final release = Completer<void>();
        final (runtime, writer, root) = await _attach(
          seams: FileWriteSeams(
            beforeRename: () async {
              entered.complete();
              await release.future;
            },
          ),
        );
        final file = File(p.join(root.path, 'a.txt'))
          ..writeAsStringSync('base\n');
        final target = realPath(file.path)!;

        final arguments = tool == 'write'
            ? {'path': 'a.txt', 'content': 'overwritten\n'}
            : {
                'path': 'a.txt',
                'anchors': [
                  '1#${definitionHashes(utf8.encode('base\n')).single}',
                ],
                'ops': [
                  {
                    'op': 'replace',
                    'start': 1,
                    'end': 1,
                    'text': 'overwritten',
                  },
                ],
              };
        final answer = _submit(runtime, 'racing', tool, arguments);
        await entered.future;

        expect(await runtime.cancelTurn(), 1);
        expect(_statusOf(writer, 'racing'), 'cancelled');

        release.complete();
        await PathLocks.run(target, () async {});
        await answer;

        expect(file.readAsStringSync(), 'base\n');
        expect(_temporaries(root), isEmpty);
      },
    );
  }
}

void _provenanceCancellationTests() {
  test('cancelled write stays open until its held rename finishes', () async {
    final held = mutation.HeldRename();
    final h = await mutation.MutationHarness.create(
      seams: FileWriteSeams(rename: held.rename),
    );
    mutation.releaseMutationAfterTest(h, held);
    final file = h.file('lib/a.dart', 'before\n');
    final unrelated = h.file('lib/unrelated.dart', 'before\n');
    await _capture(h, []);
    final pending = h.write('late', 'lib/a.dart', 'after\n', stepTurn: 0);
    await held.entered.future;
    await h.runtime.cancelTurn();
    await pending;
    expect(h.call('late')['status'], 'cancelled');
    expect(h.call('late')['target'], 'lib/a.dart');
    expect(h.call('late')['quiesced'], isNot(true));
    expect(h.call('late').containsKey('effect'), isFalse);
    file.writeAsStringSync('user bytes while rename is open\n');
    unrelated.writeAsStringSync('user edit\n');
    await h.nextTurn();
    final finished = mutation.mutationRecord(
      h.writer,
      'body/calls/${callKey('late')}',
      (node) => node['quiesced'] == true,
    );
    final pendingFrame = await _capture(h, [
      _delta('lib/a.dart'),
      _delta('lib/unrelated.dart'),
    ]);
    _expectBy(
      pendingFrame,
      'lib/a.dart',
      SensoriumChangeBy.unknown,
      userEdits: true,
    );
    _expectBy(
      pendingFrame,
      'lib/unrelated.dart',
      SensoriumChangeBy.user,
      userEdits: true,
    );
    await h.drain(held);
    await finished;
    expect(file.readAsStringSync(), 'after\n');
    expect(h.call('late')['status'], 'cancelled');
    expect(h.call('late').containsKey('effect'), isFalse);
    await h.nextTurn();
    final lateFrame = await _capture(h, [_delta('lib/a.dart')]);
    _expectBy(
      lateFrame,
      'lib/a.dart',
      SensoriumChangeBy.unknown,
      userEdits: false,
    );
  });

  test('failed late work closes the target without an effect', () async {
    final held = mutation.HeldRename()..fail = true;
    final h = await mutation.MutationHarness.create(
      seams: FileWriteSeams(rename: held.rename),
    );
    mutation.releaseMutationAfterTest(h, held);
    final file = h.file('lib/a.dart', 'before\n');
    await _capture(h, []);
    final pending = h.write(
      'failed-late',
      'lib/a.dart',
      'not written\n',
      stepTurn: 0,
    );
    await held.entered.future;
    await h.runtime.cancelTurn();
    await pending;
    final finished = mutation.mutationRecord(
      h.writer,
      'body/calls/${callKey('failed-late')}',
      (node) => node['quiesced'] == true,
    );
    await h.drain(held);
    await finished;
    expect(file.readAsStringSync(), 'before\n');
    expect(h.call('failed-late')['status'], 'cancelled');
    expect(h.call('failed-late').containsKey('effect'), isFalse);
    await h.nextTurn();
    await _capture(h, []);
    file.writeAsStringSync('later user edit\n');
    await h.nextTurn();
    final frame = await _capture(h, [_delta('lib/a.dart')]);
    _expectBy(frame, 'lib/a.dart', SensoriumChangeBy.user, userEdits: true);
  });

  test(
    'late finish after rewind creates no call node and leaves an orphan record',
    () async {
      final held = mutation.HeldRename();
      final h = await mutation.MutationHarness.create(
        seams: FileWriteSeams(rename: held.rename),
      );
      mutation.releaseMutationAfterTest(h, held);
      final target = h.file('lib/a.dart', 'before\n');
      final unrelated = h.file('lib/unrelated.txt', 'before\n');
      await _capture(h, []);
      await h.nextTurn();
      final pending = h.write('removed', 'lib/a.dart', 'after\n', stepTurn: 1);
      await held.entered.future;
      await h.runtime.cancelTurn();
      await pending;
      await h.writer.rewind(0);
      final finished = mutation.mutationRecord(
        h.writer,
        'meta/orphanedMutations',
        (nodes) => nodes.values.any(
          (node) =>
              node is Map &&
              node['target'] == 'lib/a.dart' &&
              node['finishedSeq'] is int,
        ),
      );
      await h.drain(held);
      final records = await finished;
      unrelated.writeAsStringSync('user edit\n');
      await h.nextTurn();
      final frame = await _capture(h, [
        _delta('lib/a.dart'),
        _delta('lib/unrelated.txt'),
      ]);
      _expectBy(
        frame,
        'lib/a.dart',
        SensoriumChangeBy.unknown,
        userEdits: true,
      );
      _expectBy(
        frame,
        'lib/unrelated.txt',
        SensoriumChangeBy.user,
        userEdits: true,
      );
      expect(h.call('removed'), isEmpty);
      expect(
        records.values.where(
          (node) => node is Map && node['target'] == 'lib/a.dart',
        ),
        hasLength(1),
      );
    },
  );

  test('late finish does not close a re-admitted attempt', () async {
    final held = mutation.HeldRenames();
    final h = await mutation.MutationHarness.create(
      seams: FileWriteSeams(rename: held.rename),
    );
    held.cleanupAfterTest(h);
    h.file('old.txt', 'old baseline\n');
    h.file('new.txt', 'new baseline\n');
    final unrelated = h.file('unrelated.txt', 'before user edit\n');
    await _capture(h, []);
    await h.nextTurn();
    final old = h.write('reused', 'old.txt', 'old late bytes\n', stepTurn: 1);
    final oldRename = await held.waitFor('old.txt');
    final originalAttempt = h.call('reused')['attempt'];
    await h.runtime.cancelTurn();
    await old;
    await h.writer.rewind(0);
    await h.nextTurn();
    final replacement = h.write(
      'reused',
      'new.txt',
      'replacement bytes\n',
      stepTurn: 1,
    );
    await held.waitFor('new.txt');
    final finished = mutation.mutationRecord(
      h.writer,
      'meta/orphanedMutations',
      (nodes) => nodes.values.any(
        (node) =>
            node is Map &&
            node['target'] == 'old.txt' &&
            node['finishedSeq'] is int,
      ),
    );
    await h.drain(oldRename);
    await finished;
    expect(h.call('reused')['attempt'], isNot(originalAttempt));
    expect(h.call('reused')['status'], 'running');
    expect(h.call('reused')['quiesced'], isNot(true));
    expect(h.file('new.txt').readAsStringSync(), 'new baseline\n');
    h
        .file('new.txt')
        .writeAsStringSync('user bytes while replacement is open\n');
    unrelated.writeAsStringSync('user edit\n');
    final frame = await _capture(h, [
      _delta('old.txt'),
      _delta('new.txt'),
      _delta('unrelated.txt'),
    ]);
    _expectBy(frame, 'old.txt', SensoriumChangeBy.unknown, userEdits: true);
    _expectBy(frame, 'new.txt', SensoriumChangeBy.unknown, userEdits: true);
    _expectBy(frame, 'unrelated.txt', SensoriumChangeBy.user, userEdits: true);
    await h.runtime.cancelTurn();
    await replacement;
  });

  test(
    'later cancelled rename prevents older effect proof after user restoration',
    () async {
      final held = mutation.HeldRename();
      var holdRename = false;
      final h = await mutation.MutationHarness.create(
        seams: FileWriteSeams(
          rename: (from, to) async {
            if (holdRename) {
              await held.rename(from, to);
            } else {
              await File(from).rename(to);
            }
          },
        ),
      );
      mutation.releaseMutationAfterTest(h, held);
      final file = h.file('lib/a.dart', 'before\n');
      await _capture(h, []);
      await h.write('successful-b', 'lib/a.dart', 'B\n', stepTurn: 0);
      final effect = h.call('successful-b')['effect']! as Map<String, Object?>;
      holdRename = true;
      final pending = h.write('cancelled-a', 'lib/a.dart', 'A\n', stepTurn: 0);
      await held.entered.future;
      expect(h.call('cancelled-a')['targetAfterSeq'], effect['seq']);
      await h.runtime.cancelTurn();
      await pending;
      await h.drain(held);
      expect(file.readAsStringSync(), 'A\n');
      file.writeAsStringSync('B\n');
      await h.nextTurn();
      final frame = await _capture(h, [_delta('lib/a.dart')]);
      _expectBy(
        frame,
        'lib/a.dart',
        SensoriumChangeBy.unknown,
        userEdits: false,
      );
    },
  );

  test(
    '40 cancelled writes keep 16 unfinished and refuse the rest untouched',
    () async {
      final held = mutation.HeldRenames();
      final h = await mutation.MutationHarness.create(
        seams: FileWriteSeams(rename: held.rename),
      );
      held.cleanupAfterTest(h);
      final unrelated = h.file('unrelated.txt', 'before\n');
      await _capture(h, []);
      for (var i = 0; i < 40; i++) {
        final path = 'capacity-$i.txt';
        final pending = h.write(
          'capacity-$i',
          path,
          'new bytes\n',
          stepTurn: 0,
        );
        if (i < 16) {
          await held.waitFor(path);
          await h.runtime.cancelTurn();
          await pending;
        } else {
          final outcome = await Future.any<Object>([
            pending,
            held.waitFor(path),
          ]);
          expect(
            outcome,
            isA<ToolOutputItem>(),
            reason: 'a 17th rename started',
          );
          expect(h.call('capacity-$i')['summary'], contains('16'));
          expect(h.call('capacity-$i')['summary'], contains('unfinished'));
          expect(h.file(path).existsSync(), isFalse);
          expect(h.call('capacity-$i').containsKey('target'), isFalse);
        }
      }
      expect(held.all, hasLength(16));
      for (var i = 0; i < 16; i++) {
        expect(h.call('capacity-$i')['quiesced'], isNot(true));
        expect(h.call('capacity-$i')['target'], 'capacity-$i.txt');
      }
      await h.drain(held.all.first);
      unrelated.writeAsStringSync('user edit\n');
      await h.nextTurn();
      final frame = await _capture(h, [
        _delta('capacity-0.txt'),
        _delta('unrelated.txt'),
      ]);
      _expectBy(
        frame,
        'capacity-0.txt',
        SensoriumChangeBy.unknown,
        userEdits: false,
      );
      _expectBy(
        frame,
        'unrelated.txt',
        SensoriumChangeBy.unknown,
        userEdits: false,
      );
      unrelated.writeAsStringSync('user edit after refusals\n');
      await h.nextTurn();
      final afterRefusals = await _capture(h, [_delta('unrelated.txt')]);
      _expectBy(
        afterRefusals,
        'unrelated.txt',
        SensoriumChangeBy.user,
        userEdits: true,
      );
    },
  );

  test('finished held rename admits the next write', () async {
    final held = mutation.HeldRenames();
    final h = await mutation.MutationHarness.create(
      seams: FileWriteSeams(rename: held.rename),
    );
    held.cleanupAfterTest(h);
    final unrelated = h.file('unrelated.txt', 'before\n');
    await _capture(h, []);
    mutation.HeldRename? firstRename;
    for (var i = 0; i < 16; i++) {
      final pending = h.write('held-$i', 'held-$i.txt', 'bytes\n', stepTurn: 0);
      final rename = await held.waitFor('held-$i.txt');
      if (i == 0) firstRename = rename;
      await h.runtime.cancelTurn();
      await pending;
    }
    final finished = mutation.mutationRecord(
      h.writer,
      'body/calls/${callKey('held-0')}',
      (node) => node['quiesced'] == true,
    );
    await h.drain(firstRename!);
    await finished;
    unrelated.writeAsStringSync('user edit\n');
    await h.nextTurn();
    final heldFrame = await _capture(h, [
      _delta('held-0.txt'),
      _delta('unrelated.txt'),
    ]);
    _expectBy(
      heldFrame,
      'held-0.txt',
      SensoriumChangeBy.unknown,
      userEdits: true,
    );
    _expectBy(
      heldFrame,
      'unrelated.txt',
      SensoriumChangeBy.user,
      userEdits: true,
    );
    final next = h.write(
      'after-release',
      'after-release.txt',
      'capacity returned\n',
      stepTurn: 1,
    );
    final nextRename = await held.waitFor('after-release.txt');
    await h.drain(nextRename);
    await next;
    expect(
      h.file('after-release.txt').readAsStringSync(),
      'capacity returned\n',
    );
    expect(h.call('after-release')['status'], 'settled');
    await h.nextTurn();
    final nextFrame = await _capture(h, [_delta('after-release.txt')]);
    _expectBy(
      nextFrame,
      'after-release.txt',
      SensoriumChangeBy.agent,
      userEdits: false,
    );
  });
}

Future<WorkspacePerceptionFrame> _capture(
  mutation.MutationHarness h,
  List<VcsDelta> changes,
) async {
  final observer = attribution.CallbackWorkspaceObserver((request) {
    final verification = <String, VcsVerification>{};
    for (final change in changes) {
      final file = h.file(change.path);
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
      .captureWorkspace(attribution.workspacePerception(h, observer), h.writer)
      .collect();
  attribution.composeWorkspaceFrame(frame);
  await attribution.admitWorkspaceFrame(h.writer, frame);
  return frame;
}

VcsDelta _delta(String path) =>
    VcsDelta(path: path, added: 1, removed: 0, binary: false);

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
