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
import '../tools/runtime.dart';
import 'doctor.dart' show printable;
import 'settings.dart';

/// The most model ids a startup failure lists.
const int _maxListedModels = 50;

/// A reason the engine cannot start; [message] becomes the `fatal` line.
final class _StartupFailure implements Exception {
  const _StartupFailure(this.message);

  final String message;
}

/// Runs `kehai rpc` for [workspace] and returns the exit code.
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
}) async {
  SessionWriter? writer;
  ToolRuntime? runtime;
  ExchangeDriver? driver;
  try {
    final real = realPath(workspace.path) ?? p.absolute(workspace.path);
    final canonical = canonicalWorkspace(workspace.path);
    final UserConfig config;
    try {
      config = UserConfig.load(settings.home);
    } on ConfigError catch (e) {
      throw _StartupFailure(e.message);
    }
    final sessions = sessionsDirFor(settings.home, workspace.path);
    final existing = _existingSession(sessions, resume, sessionId);
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
      writer = await _create(settings.home, sessions);
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
    );
    driver = ExchangeDriver(
      writer: writer,
      runtime: runtime,
      provider: adapter,
      model: model,
      contextWindow: resolveContextWindow(config, model, models),
    );
    // Task 5.3: finalize the exchanges and steps a dead engine left running
    // here, before hello. Calls and jobs were finalized by attach.
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
      ),
    );
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
  } finally {
    await runtime?.close();
    await driver?.close();
    await writer?.close();
  }
}

Future<int> _fatal(IOSink output, String message) async {
  final pump = OutputPump(output)..send(fatalEvent(message));
  await pump.flush();
  return 1;
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
