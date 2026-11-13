import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kehai/kehai.dart';
import 'package:kehai/src/session/scratch.dart';
import 'package:kehai/src/workspace/vcs_collector.dart';
import 'package:kehai/src/workspace/workspace_perception.dart';

import 'mutation_support.dart';

typedef VcsFixtureRequest = ({
  String root,
  String backend,
  Duration deadline,
  VcsCollection? previous,
  int turn,
  DateTime? time,
  VcsAttributionInput? attribution,
});

final class CallbackWorkspaceObserver implements WorkspaceObserver {
  CallbackWorkspaceObserver(this.respond);

  final FutureOr<VcsCollection> Function(VcsFixtureRequest request) respond;
  final requests = <VcsFixtureRequest>[];

  @override
  Future<VcsCollection> collect({
    required String root,
    String backend = 'auto',
    Duration deadline = const Duration(milliseconds: 300),
    VcsCollection? previous,
    int turn = 0,
    DateTime? time,
    VcsAttributionInput? attribution,
  }) async {
    final request = (
      root: root,
      backend: backend,
      deadline: deadline,
      previous: previous,
      turn: turn,
      time: time,
      attribution: attribution,
    );
    requests.add(request);
    return respond(request);
  }
}

VcsCollection availableCollection(
  VcsFixtureRequest request, {
  required String id,
  List<VcsDelta> changes = const [],
  Map<String, VcsVerification> verification = const {},
  SensoriumVcs? value,
  bool baselineLost = false,
  bool deadlineExpired = false,
}) {
  final input = request.attribution!;
  return VcsCollection(
    observation: SensoriumAvailable(
      value ??
          SensoriumVcs(
            branch: 'main',
            paths: changes.map((row) => row.path),
            modified: changes.length,
          ),
    ),
    baseline: VcsBaseline(
      backend: 'git',
      id: id,
      turn: request.turn,
      time: request.time!,
      seq: input.sequence.reserve(),
      jobsLive: input.jobsLive,
    ),
    changes: changes,
    verification: verification,
    captureCompleted: true,
    baselineLost: baselineLost,
    deadlineExpired: deadlineExpired,
  );
}

VcsVerification verifiedFile(File file) {
  final bytes = file.readAsBytesSync();
  final stat = file.statSync();
  final sample = (
    sha256: sha256.convert(bytes).toString(),
    size: bytes.length,
    modifiedMicros: stat.modified.microsecondsSinceEpoch,
  );
  return (before: sample, after: sample);
}

WorkspacePerception workspacePerception(
  MutationHarness harness,
  WorkspaceObserver observer, {
  String backend = 'auto',
  Duration deadline = const Duration(milliseconds: 300),
}) => WorkspacePerception(
  root: harness.root.path,
  observer: observer,
  mutations: harness.runtime.mutations,
  backend: backend,
  deadline: deadline,
);

WorkspacePerceptionCapture captureWorkspace(
  WorkspacePerception perception,
  SessionWriter writer, {
  SensoriumSource? source,
}) => perception.capture(
  tree: writer.tree,
  source:
      source ??
      SensoriumSource(
        turn: writer.currentTurn,
        time: DateTime.utc(
          2026,
          11,
          12,
        ).add(Duration(seconds: writer.currentTurn)),
      ),
);

SensoriumComposition composeWorkspaceFrame(WorkspacePerceptionFrame frame) =>
    composeSensorium(
      SensoriumSnapshot(
        source: frame.source,
        workspaceName: 'fixture',
        budget: const SensoriumBudget(
          model: 'fixture',
          used: 0,
          window: 200000,
          compactionThreshold: 180000,
          turnsSinceCompaction: 0,
        ),
        scratch: ScratchState.read(null),
        vcs: frame.vcs,
        changes: frame.changes,
        notices: frame.notices,
      ),
    );

Future<void> admitWorkspaceFrame(
  SessionWriter writer,
  WorkspacePerceptionFrame frame,
) async {
  final sequence = frame.baselineSequence;
  final high = mutationNode(writer, 'meta/vcs')['seqHigh'];
  if (sequence != null && sequence > (high as int? ?? 0)) {
    await writer.apply(
      JournalRecord(
        turn: writer.currentTurn,
        path: 'meta/vcs',
        op: Op.merge,
        value: {'seqHigh': sequence},
      ),
    );
  }
  final composition = composeWorkspaceFrame(frame);
  await writer.applyGuarded(
    (_) => GuardedAppend(
      JournalRecord(
        turn: writer.currentTurn,
        path: mutationStepPath(frame.source.turn),
        op: Op.merge,
        value: {
          'sensorium': {
            'text': composition.text,
            'tokens': composition.tokens,
            'mode': composition.mode,
            'folds': [for (final fold in composition.folds) fold.name],
            'source': {
              'turn': frame.source.turn,
              'time': frame.source.time.toIso8601String(),
              if (frame.source.offset != null) 'offset': frame.source.offset,
            },
            'vcs': frame.metadata,
          },
        },
      ),
    ),
  );
}
