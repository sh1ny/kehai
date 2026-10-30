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
