import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'session_support.dart';

/// The detected shell, when it is a POSIX shell.
ShellInfo? posixShell() {
  final shell = detectShell().shell;
  return shell != null && shell.isPosix ? shell : null;
}

/// Why job tests cannot run here, or `false` when they can.
Object skipWithoutShell() =>
    posixShell() == null ? 'no POSIX shell on this host' : false;

/// Why a test that needs real process groups cannot run here.
Object skipUnlessUnix() => Platform.isWindows
    ? 'POSIX only'
    : (posixShell()?.setsid == null ? 'needs bash and setsid' : false);

/// Polls [condition] every 10 ms until it holds or [limit] passes.
Future<void> waitFor(
  bool Function() condition, {
  Duration limit = const Duration(seconds: 20),
  String what = 'the condition',
}) async {
  final clock = Stopwatch()..start();
  while (!condition()) {
    if (clock.elapsed > limit) fail('timed out waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Whether process [pid] exists, asked through `kill -0`.
bool processAlive(int pid) =>
    Process.runSync('kill', ['-0', '$pid']).exitCode == 0;

/// Everything a job test needs: a session, a store and a supervisor.
final class JobHarness {
  JobHarness._(this.writer, this.store, this.supervisor, this.shell, this.cwd);

  /// Creates a harness; [hooks], [timings] and the signal seams are passed on.
  static Future<JobHarness> create({
    JobHooks hooks = const JobHooks(),
    JobTimings timings = const JobTimings(),
    GroupSignal? groupSignal,
    bool? windows,
  }) async {
    final root = await tempDir();
    final cwd = await tempDir();
    final writer = await createWriter(root);
    final store = ResultStore(writer.sessionDir);
    final supervisor = JobSupervisor(
      writer,
      store,
      hooks: hooks,
      timings: timings,
      groupSignal: groupSignal,
      windows: windows,
    );
    addTearDown(supervisor.close);
    return JobHarness._(writer, store, supervisor, posixShell()!, cwd.path);
  }

  /// The session writer.
  final SessionWriter writer;

  /// The result store.
  final ResultStore store;

  /// The supervisor under test.
  final JobSupervisor supervisor;

  /// The shell commands run through.
  final ShellInfo shell;

  /// The working directory of every job.
  final String cwd;

  /// The session directory.
  Directory get dir => writer.sessionDir;

  /// A request for [command] with the host environment.
  JobRequest request(
    String command, {
    Duration deadline = const Duration(seconds: 60),
    JobKind kind = JobKind.shell,
    JobLauncher? launch,
  }) {
    final base = JobRequest.shell(
      shell,
      command,
      cwd: cwd,
      environment: Platform.environment,
      kind: kind,
      deadline: deadline,
    );
    if (launch == null) return base;
    return JobRequest(
      kind: kind,
      cmd: command,
      cwd: cwd,
      shell: shell.name,
      deadline: deadline,
      launch: launch,
    );
  }

  /// A launcher that starts [command] and reports the started process.
  JobLauncher recordingLauncher(
    String command,
    void Function(ShellProcess started) onStart, {
    bool groupKnown = false,
  }) => () async {
    final started = await startShell(
      shell,
      command,
      workingDirectory: cwd,
      environment: Platform.environment,
    );
    onStart(started);
    return groupKnown
        ? ShellProcess(started.process, groupKnown: true)
        : started;
  };

  /// The node `jobs/<id>`, or null.
  Map<String, Object?>? node(String id) {
    final value = writer.tree.get(SessionPath.parse('jobs/$id'));
    return value is Map<String, Object?> ? value : null;
  }

  /// The node at [path], or null.
  Object? at(String path) => writer.tree.get(SessionPath.parse(path));

  /// The journal records, in order.
  List<JournalRecord> records() => [
    for (final line in journalOf(dir).readAsLinesSync())
      JournalRecord.parse(line),
  ];

  /// The `state` values the journal recorded for `jobs/<id>`, in order.
  List<String> states(String id) => [
    for (final r in records())
      if (r.path == 'jobs/$id' &&
          r.value is Map<String, Object?> &&
          (r.value! as Map<String, Object?>)['state'] is String)
        (r.value! as Map<String, Object?>)['state']! as String,
  ];

  /// The bytes of the result [handle] resolves to through the live tree.
  String bytesOf(String handle) => utf8.decode(
    resolveHandle(writer.tree, dir, handle).file.readAsBytesSync(),
  );

  /// The bytes of a node's stream reference.
  String stream(Map<String, Object?> node, String name) =>
      bytesOf((node[name]! as Map<String, Object?>)['handle']! as String);

  /// The `complete` flag of a node's stream reference.
  bool? complete(Map<String, Object?> node, String name) =>
      (node[name]! as Map<String, Object?>)['complete'] as bool?;

  /// The names of the spool files still under `results/`.
  List<String> spools() {
    final results = Directory(p.join(dir.path, resultsDirName));
    if (!results.existsSync()) return const [];
    return [
      for (final f in results.listSync())
        if (p.basename(f.path).startsWith('.spool-')) p.basename(f.path),
    ];
  }

  /// A path for a marker file the test and a command share.
  String marker(String name) => p.join(cwd, name).replaceAll(r"\", "/");
}

/// Reads the pid in marker file [path] once it holds a full line.
Future<int> readPid(String path) async {
  late int pid;
  await waitFor(() {
    final file = File(path);
    if (!file.existsSync()) return false;
    final text = file.readAsStringSync().trim();
    final value = int.tryParse(text);
    if (value == null) return false;
    pid = value;
    return true;
  }, what: 'the pid in $path');
  return pid;
}

/// The command that prints `printed`, starts a descendant in a new session
/// that keeps stdout open and sleeps, and records its pid in [pidFile].
///
/// Stderr is detached from the descendant, so only stdout stays held.
String holdStdout(String pidFile) =>
    "echo printed; setsid sleep 30 2>/dev/null & echo \$! > '$pidFile'";

/// Kills the descendant whose pid [pidFile] holds when the test ends.
void killHolderAtEnd(String pidFile) {
  addTearDown(() {
    final file = File(pidFile);
    if (!file.existsSync()) return;
    final pid = int.tryParse(file.readAsStringSync().trim());
    if (pid != null) Process.killPid(pid, ProcessSignal.sigkill);
  });
}

/// A hook that parks the job at one boundary until [release] completes.
final class Pause {
  /// Completes with the job id when the job reaches the boundary.
  final Completer<String> reached = Completer<String>();

  /// Completing this lets the job go on.
  final Completer<void> release = Completer<void>();

  /// The hook callback.
  Future<void> call(String id) async {
    reached.complete(id);
    await release.future;
  }
}
