import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:kehai/src/permissions/gate.dart' show credentialRefusal;
import 'package:kehai/src/tools/file_access.dart' show PathLocks;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/anchor_support.dart';
import '../support/session_support.dart';
import '../support/tool_support.dart';

Future<void> _directoryLink(String path, String target) async {
  if (Platform.isWindows) {
    // Junctions exercise directory redirection without symlink privileges.
    final result = await Process.run('cmd.exe', [
      '/d',
      '/c',
      'mklink',
      '/J',
      path,
      target,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  } else {
    Link(path).createSync(target);
  }
}

ToolContext _context(
  Directory workspace,
  Directory home,
  String target,
  FileMutation mutation,
) => ToolContext(
  callKey: 'c-target-race',
  callId: 'target-race',
  output: RecordingOutput(),
  cancel: CancelToken(),
  workspace: workspace,
  config: const UserConfig(),
  kehaiHome: home,
  permission: {'decision': 'allow', 'by': 'answer', 'target': target},
  mutation: mutation,
);

Future<ToolOutcome> _run(String tool, ToolContext context, String path) =>
    (tool == 'write' ? WriteTool() : EditTool()).run(context, {
      'path': path,
      if (tool == 'write') 'content': 'replacement\n',
      if (tool == 'edit') ...{
        'anchors': ['1#${definitionHashes(utf8.encode('before\n')).single}'],
        'ops': [
          {'op': 'replace', 'start': 1, 'end': 1, 'text': 'replacement'},
        ],
      },
    });

Future<void> _retarget(
  String tool,
  String boundary,
  bool credential, {
  bool missingParent = false,
}) async {
  final root = await tempDir();
  final workspace = Directory(p.join(root.path, 'workspace'))..createSync();
  final home = Directory(p.join(root.path, 'home'))..createSync();
  final outside = Directory(p.join(root.path, 'outside'))..createSync();
  final destination = credential ? home : outside;
  final parent = Directory(p.join(workspace.path, 'generated'));
  final original = File(p.join(parent.path, 'auth.json'));
  if (!missingParent) {
    parent.createSync();
    original.writeAsStringSync('before\n');
  }
  final victim = File(p.join(destination.path, 'auth.json'))
    ..writeAsStringSync('secret\n');
  if (!missingParent) {
    // Keep the existing edit size/mtime guard from masking the path bypass.
    victim.setLastModifiedSync(original.statSync().modified);
  }
  final target = realPath(original.path)!;
  final entered = Completer<void>();
  final release = Completer<void>();
  Future<void>? holder;
  if (boundary == 'file-lock wait') {
    holder = PathLocks.run(target, () {
      entered.complete();
      return release.future;
    });
    await entered.future;
  }
  var effects = 0;
  final context = _context(
    workspace,
    home,
    target,
    FileMutation(
      target: (_, _) async {
        if (boundary == 'mutation-intent wait') {
          entered.complete();
          await release.future;
        }
        return true;
      },
      effect: (_) async => effects++,
    ),
  );
  final pending = _run(tool, context, p.join('generated', 'auth.json'));
  if (boundary == 'mutation-intent wait') await entered.future;
  final movedParent = Directory(p.join(root.path, 'approved-parent'));
  try {
    if (!missingParent) parent.renameSync(movedParent.path);
    await _directoryLink(parent.path, destination.path);
  } finally {
    release.complete();
  }
  final outcome = await pending;
  if (holder != null) await holder;

  expect(victim.readAsStringSync(), 'secret\n');
  expect(outcome.status, ResultStatus.denied, reason: outcome.summary);
  expect(outcome.summary, credential ? credentialRefusal : targetMovedRefusal);
  expect(effects, 0);
  expect(destination.listSync().map((entity) => p.basename(entity.path)), [
    'auth.json',
  ]);
  if (!missingParent) {
    expect(
      File(p.join(movedParent.path, 'auth.json')).readAsStringSync(),
      'before\n',
    );
    expect(movedParent.listSync().map((entity) => p.basename(entity.path)), [
      'auth.json',
    ]);
  }
}

void main() {
  for (final tool in ['write', 'edit']) {
    for (final boundary in ['mutation-intent wait', 'file-lock wait']) {
      for (final credential in [true, false]) {
        test(
          '$tool refuses ${credential ? 'credential' : 'outside'} '
          'parent retargeting during $boundary',
          () => _retarget(tool, boundary, credential),
        );
      }
    }
    test(
      '$tool still commits after an unchanged mutation-intent wait',
      () async {
        final root = await tempDir();
        final workspace = Directory(p.join(root.path, 'workspace'))
          ..createSync();
        final home = Directory(p.join(root.path, 'home'))..createSync();
        final file = File(p.join(workspace.path, 'generated', 'auth.json'));
        if (tool == 'edit') {
          file.parent.createSync();
          file.writeAsStringSync('before\n');
        }
        final entered = Completer<void>();
        final release = Completer<void>();
        var effects = 0;
        final pending = _run(
          tool,
          _context(
            workspace,
            home,
            realPath(file.path)!,
            FileMutation(
              target: (_, _) async {
                entered.complete();
                await release.future;
                return true;
              },
              effect: (_) async => effects++,
            ),
          ),
          p.join('generated', 'auth.json'),
        );
        await entered.future;
        release.complete();
        final outcome = await pending;
        expect(outcome.status, ResultStatus.ok, reason: outcome.summary);
        expect(file.readAsStringSync(), 'replacement\n');
        expect(effects, 1);
        expect(
          file.parent.listSync().map((entity) => p.basename(entity.path)),
          ['auth.json'],
        );
      },
    );
  }
  for (final credential in [true, false]) {
    test(
      'write refuses a new ${credential ? 'credential' : 'outside'} '
      'parent during mutation-intent wait',
      () => _retarget(
        'write',
        'mutation-intent wait',
        credential,
        missingParent: true,
      ),
    );
  }
}
