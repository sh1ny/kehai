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
    final pending = h.write('late', 'lib/a.dart', 'after\n');
    await held.entered.future;
    await h.runtime.cancelTurn();
    await pending;
    expect(h.call('late')['status'], 'cancelled');
    expect(h.call('late')['target'], 'lib/a.dart');
    expect(h.call('late')['quiesced'], isNot(true));
    expect(h.call('late').containsKey('effect'), isFalse);
    await h.nextTurn();
    final finished = mutation.mutationRecord(
      h.writer,
      'body/calls/${callKey('late')}',
      (node) => node['quiesced'] == true,
    );
    await h.drain(held);
    await finished;
    expect(file.readAsStringSync(), 'after\n');
    expect(h.call('late')['status'], 'cancelled');
    expect(h.call('late').containsKey('effect'), isFalse);
  });

  test('failed late work closes the target without an effect', () async {
    final held = mutation.HeldRename()..fail = true;
    final h = await mutation.MutationHarness.create(
      seams: FileWriteSeams(rename: held.rename),
    );
    mutation.releaseMutationAfterTest(h, held);
    final file = h.file('lib/a.dart', 'before\n');
    final pending = h.write('failed-late', 'lib/a.dart', 'not written\n');
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
  });

  test(
    'late finish after rewind creates no call node and leaves an orphan record',
    () async {
      final held = mutation.HeldRename();
      final h = await mutation.MutationHarness.create(
        seams: FileWriteSeams(rename: held.rename),
      );
      mutation.releaseMutationAfterTest(h, held);
      h.file('lib/a.dart', 'before\n');
      await h.nextTurn();
      final pending = h.write('removed', 'lib/a.dart', 'after\n');
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
    await h.nextTurn();
    final old = h.write('reused', 'old.txt', 'old late bytes\n');
    final oldRename = await held.waitFor('old.txt');
    final originalAttempt = h.call('reused')['attempt'];
    await h.runtime.cancelTurn();
    await old;
    await h.writer.rewind(0);
    await h.nextTurn();
    final replacement = h.write('reused', 'new.txt', 'replacement bytes\n');
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
    await h.runtime.cancelTurn();
    await replacement;
  });

  test(
    '40 cancelled writes keep 16 unfinished and refuse the rest untouched',
    () async {
      final held = mutation.HeldRenames();
      final h = await mutation.MutationHarness.create(
        seams: FileWriteSeams(rename: held.rename),
      );
      held.cleanupAfterTest(h);
      for (var i = 0; i < 40; i++) {
        final path = 'capacity-$i.txt';
        final pending = h.write('capacity-$i', path, 'new bytes\n');
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
    },
  );

  test('finished held rename admits the next write', () async {
    final held = mutation.HeldRenames();
    final h = await mutation.MutationHarness.create(
      seams: FileWriteSeams(rename: held.rename),
    );
    held.cleanupAfterTest(h);
    for (var i = 0; i < 16; i++) {
      final pending = h.write('held-$i', 'held-$i.txt', 'bytes\n');
      await held.waitFor('held-$i.txt');
      await h.runtime.cancelTurn();
      await pending;
    }
    final finished = mutation.mutationRecord(
      h.writer,
      'body/calls/${callKey('held-0')}',
      (node) => node['quiesced'] == true,
    );
    await h.drain(await held.waitFor('held-0.txt'));
    await finished;
    final next = h.write(
      'after-release',
      'after-release.txt',
      'capacity returned\n',
    );
    final nextRename = await held.waitFor('after-release.txt');
    await h.drain(nextRename);
    await next;
    expect(
      h.file('after-release.txt').readAsStringSync(),
      'capacity returned\n',
    );
    expect(h.call('after-release')['status'], 'settled');
  });
}
