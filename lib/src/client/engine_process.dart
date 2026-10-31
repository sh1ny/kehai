/// The client's view of the engine: a child `kehai rpc` process, or any
/// stand-in that speaks the same events (design D1).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// What the client needs from an engine.
abstract interface class EngineLink {
  /// The decoded event lines; the stream ends when the engine's output ends.
  Stream<Map<String, Object?>> get events;

  /// Writes one command line to the engine.
  void send(Map<String, Object?> command);

  /// Closes the engine's input, which asks it to shut down.
  Future<void> closeInput();

  /// Completes with the engine's exit code.
  Future<int> get exitCode;

  /// Kills the engine without waiting.
  void kill();
}

/// Starts an engine for the client with the `rpc` options [args].
typedef EngineStarter = Future<EngineLink> Function(List<String> args);

/// The command line that starts `kehai rpc` with [rpcArgs] from the running
/// executable (design D1).
///
/// A compiled `kehai` is its own script and runs by itself. Otherwise the
/// executable is the Dart VM, running a source script or a snapshot (as
/// `dart pub global activate` does), so its VM flags and the script come
/// first. [executable], [executableArguments] and [script] default to this
/// process's.
({String executable, List<String> arguments}) engineCommand(
  List<String> rpcArgs, {
  String? executable,
  List<String>? executableArguments,
  Uri? script,
}) {
  final vm = executable ?? Platform.resolvedExecutable;
  final source = script ?? Platform.script;
  final scriptPath = source.toFilePath();
  final underVm = !p.equals(p.absolute(scriptPath), p.absolute(vm));
  return (
    executable: vm,
    arguments: [
      if (underVm) ...executableArguments ?? Platform.executableArguments,
      if (underVm) scriptPath,
      'rpc',
      ...rpcArgs,
    ],
  );
}

/// Starts `kehai rpc` as a child process in the current directory.
///
/// The child's standard error is passed through to ours.
Future<EngineLink> startEngineProcess(List<String> args) async {
  final command = engineCommand(args);
  final process = await Process.start(command.executable, command.arguments);
  // Not addStream: that would bind our stderr and refuse the client's own
  // writes to it.
  process.stderr.listen(stderr.add, onError: (Object _) {});
  return _ProcessEngine(process);
}

final class _ProcessEngine implements EngineLink {
  _ProcessEngine(this._process)
    : events = _process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .map(_decode)
          .where((event) => event != null)
          .cast<Map<String, Object?>>();

  final Process _process;

  @override
  final Stream<Map<String, Object?>> events;

  @override
  void send(Map<String, Object?> command) {
    try {
      _process.stdin.writeln(jsonEncode(command));
    } on Object {
      // The engine is gone; its exit is reported through the events.
    }
  }

  @override
  Future<void> closeInput() async {
    try {
      await _process.stdin.close();
    } on Object {
      // Already closed or broken pipe.
    }
  }

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void kill() {
    _process.kill();
  }
}

Map<String, Object?>? _decode(String line) {
  try {
    final decoded = jsonDecode(line);
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    return null;
  }
}
