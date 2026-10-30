import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import 'job_support.dart';
import 'session_support.dart';

/// A stage that lets every call through and records [permission] on it.
final class RecordingStage implements CallStage {
  /// Creates a stage recording [permission] (null records nothing).
  const RecordingStage([this.permission]);

  /// The permission record.
  final Map<String, Object?>? permission;

  @override
  Future<StageOutcome> check(StageCall call, CancelToken cancel) async =>
      StageOutcome.proceed(record: permission);
}

/// A runtime over a fresh session with a real shell and no permission prompts.
final class BashHarness {
  BashHarness._(this.writer, this.store, this.runtime, this.workspace);

  /// Attaches a runtime; [permission] is what the gate records on each call.
  static Future<BashHarness> create({
    Map<String, Object?>? permission,
    UserConfig config = const UserConfig(),
    ShellDetection? shell,
    JobHooks jobHooks = const JobHooks(),
  }) async {
    final root = await tempDir();
    final workspace = await tempDir();
    final writer = await createWriter(root);
    final store = ResultStore(writer.sessionDir);
    final runtime = await ToolRuntime.attach(
      writer,
      store,
      workspace: workspace,
      config: config,
      shell: shell,
      gate: RecordingStage(permission),
      jobHooks: jobHooks,
    );
    addTearDown(runtime.close);
    return BashHarness._(writer, store, runtime, workspace);
  }

  /// The session writer.
  final SessionWriter writer;

  /// The result store.
  final ResultStore store;

  /// The runtime under test.
  final ToolRuntime runtime;

  /// The workspace root.
  final Directory workspace;

  int _calls = 0;

  /// Runs [tool] with [arguments] and returns the model-facing text.
  Future<String> call(String tool, Map<String, Object?> arguments) async {
    final item = await runtime.run(
      ToolCall(
        callId: 'call-${_calls++}',
        name: tool,
        argumentsJson: jsonEncode(arguments),
      ),
    );
    return item.output;
  }

  /// The node of the most recent call.
  Map<String, Object?> get lastCall {
    final calls = writer.tree.get(SessionPath.parse('body/calls'));
    final nodes = (calls! as Map<String, Object?>).values.toList();
    return nodes.last! as Map<String, Object?>;
  }

  /// The job nodes by id.
  Map<String, Map<String, Object?>> get jobNodes {
    final jobs = writer.tree.get(SessionPath.parse('jobs'));
    if (jobs is! Map<String, Object?>) return const {};
    return {
      for (final e in jobs.entries) e.key: e.value! as Map<String, Object?>,
    };
  }

  /// The node of job [id].
  Map<String, Object?> job(String id) => jobNodes[id]!;

  /// The stored bytes behind a node's stream reference.
  String stream(Map<String, Object?> node, String name) {
    final ref = node[name]! as Map<String, Object?>;
    final resolved = resolveHandle(
      writer.tree,
      writer.sessionDir,
      ref['handle']! as String,
    );
    return utf8.decode(resolved.file.readAsBytesSync());
  }

  /// The stored result of the call node [node].
  String resultOf(Map<String, Object?> node) => stream(node, 'result');
}

/// The job id in a `still running as job <id>` summary.
String jobIdIn(String text) =>
    RegExp(r'job (j-[0-9a-f]+)').firstMatch(text)!.group(1)!;

/// Why bash tests cannot run here.
Object skipBash() => skipWithoutShell();
