/// `kehai rpc`: opens the workspace's session and serves protocol v1 on
/// standard input and output (design D11, D13; specs *engine-rpc*,
/// *Model selection*).
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../auth/auth_failure.dart';
import '../auth/credential_error.dart';
import '../auth/credential_store.dart';
import '../auth/posix_ffi.dart';
import '../auth/refresher.dart';
import '../config/user_config.dart';
import '../loop/driver.dart';
import '../loop/instructions.dart';
import '../permissions/workspace_paths.dart';
import '../provider/chatgpt_adapter.dart';
import '../provider/provider.dart';
import '../results/result_store.dart';
import '../rpc/pump.dart';
import '../rpc/protocol.dart';
import '../rpc/server.dart';
import '../rpc/session_location.dart';
import '../session/errors.dart';
import '../session/journal.dart';
import '../session/path.dart';
import '../session/record.dart';
import '../session/writer.dart';
import '../tools/roster.dart';
import '../tools/runtime.dart';
import '../workspace/inventory.dart' show loadWorkspace;
import '../workspace/roles.dart';
import 'doctor.dart' show printable;
import 'settings.dart';

/// The most model ids a startup failure lists.
const int _maxListedModels = 50;

/// A reason the engine cannot start; [message] becomes the `fatal` line.
final class _StartupFailure implements Exception {
  const _StartupFailure(this.message);

  final String message;
}

/// The arguments of `kehai rpc --child`: what an agent job tells the child
/// engine it runs (design D8).
final class ChildSpec {
  /// Creates the spec.
  const ChildSpec({
    required this.parent,
    required this.job,
    required this.role,
    required this.roleDigest,
    this.yolo = false,
  });

  /// The parent session's directory; the child session is created under its
  /// `agents` directory.
  final String parent;

  /// The parent's job id, recorded in the child's lineage.
  final String job;

  /// The agent role's name.
  final String role;

  /// The SHA-256 of the role file's text as the parent saw it.
  final String roleDigest;

  /// Whether the parent runs with `--yolo`; the child's gate skips prompts.
  final bool yolo;
}

/// The engine startup boundary, injectable by command-line input tests.
typedef RpcRunner = Future<int> Function({
  required KehaiSettings settings,
  required Directory workspace,
  required Stream<List<int>> input,
  required IOSink output,
  bool resume,
  String? sessionId,
  String? modelFlag,
  String? effortFlag,
  ChildSpec? child,
});

/// Runs `kehai rpc` for [workspace] and returns the exit code.
///
/// With [child] the engine is an agent job's child: it creates a new session
/// under the parent session's directory, runs [ChildSpec.role] with the
/// roster narrowed to that role's tools, and ignores [resume] and
/// [sessionId] (the command refuses them).
///
/// Every failure to start is one `fatal` line on [output] and exit code 1.
/// With [resume] the latest session of the workspace is reopened, with
/// [sessionId] that one; otherwise a new session is created. The model is
/// [modelFlag], else the configured one, else the resumed session's last.
Future<int> runRpc({
  required KehaiSettings settings,
  required Directory workspace,
  required Stream<List<int>> input,
  required IOSink output,
  bool resume = false,
  String? sessionId,
  String? modelFlag,
  String? effortFlag,
  ChildSpec? child,
}) async {
  SessionWriter? writer;
  ToolRuntime? runtime;
  ExchangeDriver? driver;
  // A terminal sends Ctrl-C to the engine as well as the client; listening
  // ignores it (on Windows it also consumes the console event), so only the
  // `interrupt` command cancels (design D14).
  final sigint = ProcessSignal.sigint.watch().listen((_) {});
  // Once serving, a filesystem error is not a startup failure.
  var serving = false;
  try {
    final real = realPath(workspace.path) ?? p.absolute(workspace.path);
    final canonical = canonicalWorkspace(workspace.path);
    final UserConfig config;
    try {
      config = UserConfig.load(settings.home);
    } on ConfigError catch (e) {
      throw _StartupFailure(e.message);
    }
    final role = child == null
        ? null
        : _childRole(child, real, Directory(settings.home));
    final sessions = sessionsDirFor(settings.home, workspace.path);
    final existing = child != null
        ? null
        : _existingSession(sessions, resume, sessionId);
    if (existing != null) {
      writer = await _open(existing);
      final recorded = writer.tree.get(SessionPath.parse('meta/workspace'));
      if (recorded != null && recorded != canonical) {
        throw _StartupFailure(
          'session ${p.basename(existing.path)} belongs to another workspace',
        );
      }
    }

    final adapter = _adapter(settings);
    final models = await _listModels(adapter);
    final model = _chooseModel(
      flag: modelFlag,
      config: config,
      settings: settings,
      writer: writer,
      models: models,
    );

    if (writer == null) {
      writer = child == null
          ? await _create(settings.home, sessions)
          : await SessionWriter.create(
              Directory(p.join(child.parent, agentsDirName)),
              lineage: {'parent': p.basename(child.parent), 'job': child.job},
            );
      await writer.apply(
        JournalRecord(
          turn: writer.currentTurn,
          path: 'meta/workspace',
          op: Op.set,
          value: canonical,
        ),
      );
    }

    final answerer = RpcAnswerer();
    runtime = await ToolRuntime.attach(
      writer,
      ResultStore(writer.sessionDir),
      workspace: Directory(real),
      config: config,
      kehaiHome: Directory(settings.home),
      answerer: answerer,
      yolo: child?.yolo ?? false,
      model: model,
      roster: role == null
          ? null
          : roleRoster(role, toolDefinitions.map((d) => d.name)),
    );
    driver = ExchangeDriver(
      writer: writer,
      runtime: runtime,
      provider: adapter,
      model: model,
      contextWindow: resolveContextWindow(config, model, models),
      childRole: role == null
          ? null
          : ChildRole(name: role.name, digest: role.digest, body: role.body),
    );
    // Calls and jobs were finalized by attach; the exchanges and steps a dead
    // engine left running are finalized here, before hello (design D5).
    final exchanges = await driver.finalizeUnfinished();
    final server = RpcServer(
      writer: writer,
      runtime: runtime,
      driver: driver,
      answerer: answerer,
      input: input,
      output: output,
      hello: HelloInfo(
        session: p.basename(writer.sessionDir.path),
        workspace: real,
        model: model,
        requests: writer.interruptedRequests,
        calls: runtime.resumed.calls,
        jobs: runtime.resumed.jobs,
        exchanges: exchanges,
      ),
    );
    serving = true;
    return await server.run();
  } on _StartupFailure catch (e) {
    return _fatal(output, e.message);
  } on SessionError catch (e) {
    return _fatal(output, e.message);
  } on JournalCorruption catch (e) {
    return _fatal(output, 'the session journal is corrupt: $e');
  } on StorageError catch (e) {
    return _fatal(output, 'storage failure: ${e.message}');
  } on CredentialStoreError catch (e) {
    return _fatal(output, 'credentials unavailable: ${printable(e.message)}');
  } on FileSystemException catch (e) {
    if (serving) rethrow;
    return _fatal(output, 'storage failure: ${_describeFs(e)}');
  } finally {
    await sigint.cancel();
    await runtime?.close();
    await driver?.close();
    await writer?.close();
  }
}

/// [e]'s message, path and OS error, on one line.
String _describeFs(FileSystemException e) => printable(
  [
    e.message,
    ?e.path,
    if (e.osError case final os?) os.message,
  ].where((part) => part.isNotEmpty).join(': '),
);

Future<int> _fatal(IOSink output, String message) async {
  final pump = OutputPump(output)..send(fatalEvent(message));
  await pump.flush();
  return 1;
}

/// The directory under a parent session that holds its child sessions.
const String agentsDirName = 'agents';

/// The role [child] runs, loaded now from the workspace view.
///
/// Throws a [_StartupFailure] when the role does not exist, when its file no
/// longer has the digest the parent saw, or when the parent session is
/// missing. Nothing is created before this passes.
Role _childRole(ChildSpec child, String workspace, Directory home) {
  final role = loadWorkspace(
    workspace: workspace,
    kehaiHome: home,
  ).role(child.role);
  if (role == null) throw _StartupFailure('unknown agent role ${child.role}');
  if (role.digest != child.roleDigest) {
    throw const _StartupFailure('role changed');
  }
  if (!File(p.join(child.parent, journalFileName)).existsSync()) {
    throw _StartupFailure(
      'parent session not found: ${printable(child.parent)}',
    );
  }
  return role;
}

/// The session to reopen, or null for a new one.
Directory? _existingSession(Directory sessions, bool resume, String? id) {
  if (id != null) {
    final dir = Directory(p.join(sessions.path, id));
    if (!isSessionId(id) || !dir.existsSync()) {
      throw _StartupFailure('no session $id for this workspace');
    }
    return dir;
  }
  if (!resume) return null;
  return latestSession(sessions) ??
      (throw const _StartupFailure('no session to resume for this workspace'));
}

Future<SessionWriter> _open(Directory dir) => SessionWriter.open(dir);

Future<SessionWriter> _create(String home, Directory sessions) async {
  final root = Directory(p.join(home, 'sessions'));
  final fresh = !root.existsSync();
  root.createSync(recursive: true);
  if (fresh && !Platform.isWindows) PosixLibc.instance.chmod(root.path, 448);
  return SessionWriter.create(sessions);
}

ChatGptAdapter _adapter(KehaiSettings settings) {
  final store = CredentialStore(
    home: settings.home,
    backend: settings.createBackend(),
  );
  if (store.load()?.tokens == null) {
    throw const _StartupFailure('not logged in; run kehai login openai');
  }
  return ChatGptAdapter(
    refresher: Refresher(store: store, issuer: settings.issuer),
    apiBase: settings.apiBase,
  );
}

Future<List<ModelInfo>> _listModels(ModelProvider provider) async {
  try {
    return await provider.listModels();
  } on AuthFailure catch (e) {
    throw _StartupFailure('login failed: ${printable(e.message)}');
  } on ProviderFailure catch (e) {
    throw _StartupFailure('cannot list models: ${printable(e.message)}');
  }
}

String _chooseModel({
  required String? flag,
  required UserConfig config,
  required KehaiSettings settings,
  required SessionWriter? writer,
  required List<ModelInfo> models,
}) {
  final chosen = flag ?? config.model ?? _lastModel(writer);
  final listing =
      'available models: '
      '${models.take(_maxListedModels).map((m) => printable(m.id)).join(', ')}'
      '${models.length > _maxListedModels ? ', ... and ${models.length - _maxListedModels} more' : ''}';
  if (chosen == null) {
    throw _StartupFailure(
      'no model selected; use --model <id> or set "model" in '
      '${p.join(settings.home, configFileName)}\n$listing',
    );
  }
  if (!models.any((m) => m.id == chosen)) {
    throw _StartupFailure(
      'model ${printable(chosen)} is not available\n$listing',
    );
  }
  return chosen;
}

/// The model of the resumed session's last step, or null.
String? _lastModel(SessionWriter? writer) {
  if (writer == null) return null;
  final steps = writer.tree.get(SessionPath.parse('body/steps'));
  if (steps is! Map<String, Object?> || steps.isEmpty) return null;
  final last = (steps.keys.toList()..sort()).last;
  final step = steps[last];
  return step is Map<String, Object?> && step['model'] is String
      ? step['model']! as String
      : null;
}
