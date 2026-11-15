import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:kehai/src/session/mutations.dart';
import 'package:kehai/src/tools/atomic_write.dart';
import 'package:kehai/src/tools/file_access.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'anchor_support.dart';
import 'session_support.dart';

Map<String, Object?> mutationNode(SessionWriter writer, String path) {
  final node = writer.tree.get(SessionPath.parse(path));
  return node is Map<String, Object?> ? node : const {};
}

Future<Map<String, Object?>> mutationRecord(
  SessionWriter writer,
  String path,
  bool Function(Map<String, Object?>) matches,
) {
  final current = mutationNode(writer, path);
  if (matches(current)) return Future.value(current);
  final result = Completer<Map<String, Object?>>();
  late StreamSubscription<CommittedUpdate> subscription;
  subscription = writer.subscribe().listen((_) {
    final current = mutationNode(writer, path);
    if (!result.isCompleted && matches(current)) {
      result.complete(current);
      unawaited(subscription.cancel());
    }
  });
  addTearDown(subscription.cancel);
  return result.future;
}

final class HeldRename {
  final entered = Completer<void>();
  final release = Completer<void>();
  final finished = Completer<void>();
  String? target;
  String? temporary;
  bool fail = false;

  Future<void> rename(String from, String to) async {
    temporary = from;
    target = to;
    entered.complete();
    try {
      await release.future;
      if (fail) throw const FileSystemException('held rename failed');
      await File(from).rename(to);
    } finally {
      finished.complete();
    }
  }

  void unblock() {
    if (!release.isCompleted) release.complete();
  }
}

final class MutationHarness {
  MutationHarness._(this.root, this.writer, this.runtime);

  final Directory root;
  final SessionWriter writer;
  final ToolRuntime runtime;

  /// Skips only journal fsync in large logic fixtures when [skipFlush] is true.
  /// Crash, recovery and flush-boundary fixtures retain native flushes by default.
  static Future<MutationHarness> create({
    FileWriteSeams seams = const FileWriteSeams(),
    CallStage gate = const AllowAllStage(),
    ToolRuntimeSeams runtimeSeams = const ToolRuntimeSeams(),
    Tool? writeTool,
    Tool? editTool,
    bool skipFlush = false,
  }) async {
    final root = Directory((await tempDir()).resolveSymbolicLinksSync());
    Directory(p.join(root.path, '.git')).createSync();
    final SessionWriter writer;
    if (skipFlush) {
      final (created, io) = await createHooked(root);
      io.skipFlush = true;
      writer = created;
    } else {
      writer = await createWriter(root);
    }
    final runtime = await ToolRuntime.attach(
      writer,
      ResultStore(writer.sessionDir),
      workspace: root,
      gate: gate,
      seams: runtimeSeams,
      tools: {
        'write': writeTool ?? WriteTool(seams: seams),
        'edit': editTool ?? EditTool(seams: seams),
      },
    );
    addTearDown(runtime.close);
    return MutationHarness._(root, writer, runtime);
  }

  File file(String relative, [String? content]) {
    final file = File(p.joinAll([root.path, ...p.posix.split(relative)]));
    if (content != null) {
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(content);
    }
    return file;
  }

  Map<String, Object?> call(String id) =>
      mutationNode(writer, 'body/calls/${callKey(id)}');

  Future<ToolOutputItem> write(
    String id,
    String path,
    String content, {
    int? stepTurn,
  }) => _run(
    ToolCall(
      callId: id,
      name: 'write',
      argumentsJson: jsonEncode({'path': path, 'content': content}),
    ),
    stepTurn,
  );

  Future<ToolOutputItem> edit(
    String id,
    String path,
    String content, {
    int? stepTurn,
  }) {
    final bytes = file(path).readAsBytesSync();
    return _run(
      ToolCall(
        callId: id,
        name: 'edit',
        argumentsJson: jsonEncode({
          'path': path,
          'anchors': ['1#${definitionHashes(bytes).first}'],
          'ops': [
            {'op': 'replace', 'start': 1, 'end': 1, 'text': content},
          ],
        }),
      ),
      stepTurn,
    );
  }

  Future<ToolOutputItem> _run(ToolCall call, int? stepTurn) async {
    if (stepTurn != null) {
      final path = mutationStepPath(stepTurn);
      final output = mutationNode(writer, path)['output'];
      await writer.apply(
        JournalRecord(
          turn: writer.currentTurn,
          path: path,
          op: Op.merge,
          value: {
            'output': [
              if (output is List) ...output,
              {
                'type': 'call',
                'call': callKey(call.callId),
                'callId': call.callId,
                'name': call.name,
                'arguments': call.argumentsJson,
              },
            ],
          },
        ),
      );
    }
    return runtime.run(call, stepTurn: stepTurn);
  }

  Future<void> nextTurn() => writer.apply(
    JournalRecord(
      turn: writer.currentTurn + 1,
      path: 'body/markers/m-${writer.currentTurn + 1}',
      op: Op.set,
      value: true,
    ),
  );

  Future<void> drain(HeldRename held) async {
    held.unblock();
    await held.finished.future;
    if (held.target case final target?) {
      await PathLocks.run(target, () async {});
    }
    await writer.applyGuarded((_) => const GuardedRefusal('test barrier'));
  }
}

void releaseMutationAfterTest(MutationHarness harness, HeldRename held) {
  addTearDown(() async {
    held.unblock();
    if (held.entered.isCompleted) await harness.drain(held);
  });
}

final class HeldRenames {
  final _held = <String, HeldRename>{};
  final _waiting = <String, Completer<HeldRename>>{};
  final _claimed = <HeldRename>{};

  Iterable<HeldRename> get all => _held.values;

  Future<void> rename(String from, String to) {
    final name = p.basename(to);
    final held = HeldRename();
    _held[name] = held;
    _waiting.remove(name)?.complete(held);
    return held.rename(from, to);
  }

  Future<HeldRename> waitFor(String name) {
    final held = _held[name];
    if (held != null && _claimed.add(held)) return Future.value(held);
    return (_waiting[name] ??= Completer<HeldRename>()).future.then((held) {
      _claimed.add(held);
      return held;
    });
  }

  void cleanupAfterTest(MutationHarness harness) {
    addTearDown(() async {
      for (final held in _held.values) {
        held.unblock();
      }
      for (final held in _held.values) {
        await harness.drain(held);
      }
    });
  }
}

/// A real held rename with a journaled owner, for writer crash boundaries.
final class WriterHeldMutation {
  WriterHeldMutation._(
    this.workspace,
    this.writer,
    this.io,
    this.run,
    this.held,
  );

  final Directory workspace;
  final SessionWriter writer;
  final HookedIo io;
  final MutationTarget run;
  final HeldRename held;
  late final Future<void> _write;
  bool _live = true;

  File get journal => journalOf(writer.sessionDir);

  static Future<WriterHeldMutation> start({
    bool callSurvives = false,
    Future<void> Function(Directory workspace, SessionWriter writer)?
    beforeMutation,
  }) async {
    final workspace = await tempDir();
    Directory(p.join(workspace.path, '.git')).createSync();
    final target = File(p.join(workspace.path, 'lib', 'a.dart'));
    target.parent.createSync();
    target.writeAsStringSync('before\n');
    final (writer, io) = await createHooked(workspace);
    await writer.apply(rec(0, 'meta/vcs', Op.merge, {'seqHigh': 7}));
    await beforeMutation?.call(workspace, writer);
    final callPath = 'body/calls/${callKey('writer-held')}';
    final call = <String, Object?>{
      'tool': 'write',
      'callId': 'writer-held',
      'attempt': 'held-attempt',
      'input': {'path': 'lib/a.dart', 'content': 'after\n'},
      'status': 'cancelled',
      'reason': 'user',
    };
    if (callSurvives) {
      await writer.apply(rec(0, callPath, Op.set, call));
    }
    final held = HeldRename();
    late final WriterHeldMutation fixture;
    final writing = writeAtomically(
      target.path,
      utf8.encode('after\n'),
      beforeWrite: (temporary) async {
        final relative = p.posix.joinAll(
          p.split(p.relative(temporary, from: workspace.path)),
        );
        final MutationTarget run = (
          runId: 'held-attempt',
          callPath: callPath,
          target: 'lib/a.dart',
          temporary: relative,
          session: mutationNode(writer, 'meta')['session']! as String,
        );
        fixture = WriterHeldMutation._(workspace, writer, io, run, held);
        final live = [run];
        writer.liveMutationTargets = () => fixture._live ? live : const [];
        final intent = <String, Object?>{
          'target': run.target,
          'temporary': relative,
          'targetAfterSeq': mutationNode(writer, 'meta/vcs')['seqHigh'],
        };
        await writer.apply(
          rec(
            1,
            callPath,
            callSurvives ? Op.merge : Op.set,
            callSurvives ? intent : {...call, ...intent},
          ),
        );
      },
      seams: FileWriteSeams(rename: held.rename),
    );
    await Future.any([held.entered.future, writing]);
    fixture._write = writing;
    addTearDown(fixture.land);
    return fixture;
  }

  Future<void> land() async {
    if (!held.release.isCompleted) held.release.complete();
    await _write;
  }

  void retire(GuardedRead _) => _live = false;

  Future<void> finish() async {
    await land();
    await writer.finishMutation(
      run,
      sequence: MutationSequence(7),
      retire: retire,
    );
  }
}

String mutationStepPath(int turn) =>
    'body/steps/s-${turn.toString().padLeft(8, '0')}';
