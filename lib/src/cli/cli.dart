/// The `kehai` command line (design D1).
///
/// [runCli] wires a `CommandRunner` with `login openai`, `logout openai` and
/// `doctor`. Exit codes: `0` success, `1` failure, `64` usage error. A failure
/// prints one sanitized line to standard error; no command prints a token.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../auth/browser_login.dart';
import '../auth/credential_error.dart';
import '../auth/credential_store.dart';
import '../auth/login_controller.dart';
import '../auth/logout.dart';
import '../client/client.dart';
import '../client/console_codepage.dart';
import '../client/console_input.dart';
import '../client/engine_process.dart';
import '../config/effort.dart';
import '../config/user_config.dart';
import '../provider/provider.dart' show CancelToken;
import '../workspace/inventory.dart';
import 'doctor.dart';
import 'rpc_command.dart';
import 'settings.dart';

/// The exit code of a command that succeeded.
const int exitSuccess = 0;

/// The exit code of a command that failed.
const int exitFailure = 1;

/// The exit code of a usage error (`EX_USAGE`).
const int exitUsage = 64;

/// What the commands read and write, injectable for tests.
final class CliContext {
  /// Creates a context.
  ///
  /// [environment] defaults to the process environment, [out] and [err] to
  /// standard output and error. [interrupts] is the Ctrl-C stream of a login or logout
  /// (default: `SIGINT`), and [stdinTerminalOverride] tells whether
  /// standard input is a terminal (default: ask the process).
  CliContext({
    Map<String, String>? environment,
    StringSink? out,
    StringSink? err,
    this.interrupts,
    this.stdinTerminalOverride,
    this.rpcInput,
    this.rpcOutput,
    this.engineStarter = startEngineProcess,
    this.rpcRunner = runRpc,
  }) : environment = environment ?? Platform.environment,
       out = out ?? stdout,
       err = err ?? stderr;

  /// The process environment.
  final Map<String, String> environment;

  /// Where results are printed.
  final StringSink out;

  /// Where failures are printed.
  final StringSink err;

  /// The Ctrl-C stream of a login, or `null` for `SIGINT`.
  final Stream<Object?>? interrupts;

  /// Whether standard input is a terminal, or `null` to ask the process.
  final bool? stdinTerminalOverride;

  /// The byte stream `kehai rpc` reads commands from, or `null` for standard
  /// input.
  final Stream<List<int>>? rpcInput;

  /// The sink `kehai rpc` writes events to, or `null` for standard output.
  final IOSink? rpcOutput;

  /// Starts the line client's engine process.
  final EngineStarter engineStarter;

  /// Starts the RPC engine after command-line validation.
  final RpcRunner rpcRunner;

  /// Whether standard input is a terminal.
  bool get stdinIsTerminal {
    final explicit = stdinTerminalOverride;
    if (explicit != null) return explicit;
    try {
      return stdin.hasTerminal;
    } on Object {
      return false;
    }
  }
}

/// Runs the `kehai` command line with [args] and returns the exit code.
///
/// A usage error prints its message and the usage text to `err` and returns
/// [exitUsage]. Any other failure prints one line and returns [exitFailure];
/// an unexpected error names only its type, never its message.
Future<int> runCli(
  List<String> args, {
  Map<String, String>? environment,
  StringSink? out,
  StringSink? err,
  Stream<Object?>? interrupts,
  bool? stdinIsTerminal,
  Stream<List<int>>? rpcInput,
  IOSink? rpcOutput,
  EngineStarter engineStarter = startEngineProcess,
  RpcRunner rpcRunner = runRpc,
}) async {
  final context = CliContext(
    environment: environment,
    out: out,
    err: err,
    interrupts: interrupts,
    stdinTerminalOverride: stdinIsTerminal,
    rpcInput: rpcInput,
    rpcOutput: rpcOutput,
    engineStarter: engineStarter,
    rpcRunner: rpcRunner,
  );
  if (_startsClient(args)) return _runClient(args, context);
  final runner =
      CommandRunner<int>('kehai', 'Kehai headless coding-agent engine.')
        ..addCommand(_LoginCommand(context))
        ..addCommand(_LogoutCommand(context))
        ..addCommand(_DoctorCommand(context))
        ..addCommand(_RpcCommand(context));
  try {
    return await runner.run(args) ?? exitSuccess;
  } on UsageException catch (e) {
    context.err
      ..writeln(e.message)
      ..writeln(e.usage);
    return exitUsage;
  } on Object catch (e) {
    context.err.writeln('kehai: unexpected ${e.runtimeType}');
    return exitFailure;
  }
}

/// The options of `kehai` run without a subcommand.
final ArgParser _clientParser = ArgParser()
  ..addFlag(
    'resume',
    negatable: false,
    help: "Reopen the workspace's latest session.",
  )
  ..addOption('session', help: 'Reopen the session with this id.')
  ..addOption('model', help: 'The model id to use.')
  ..addOption(
    'effort',
    allowed: effortValues,
    help: 'The reasoning effort to select (omitted: provider default).',
  );

/// Whether [args] start the interactive client: no arguments, or only the
/// session, model and effort options.
bool _startsClient(List<String> args) =>
    args.isEmpty ||
    const ['--resume', '--session', '--model', '--effort'].any(
      (option) => args.first == option || args.first.startsWith('$option='),
    );

/// Runs the line client, which starts `kehai rpc` as its engine (design D1).
Future<int> _runClient(List<String> args, CliContext context) async {
  final ArgResults results;
  try {
    results = _clientParser.parse(args);
    if (results.rest.isNotEmpty) {
      throw UsageException('unexpected ${results.rest.first}', '');
    }
    if (results.flag('resume') && results.option('session') != null) {
      throw UsageException('use --resume or --session, not both', '');
    }
  } on FormatException catch (e) {
    context.err
      ..writeln(e.message)
      ..writeln(_clientParser.usage);
    return exitUsage;
  } on UsageException catch (e) {
    context.err
      ..writeln(e.message)
      ..writeln(_clientParser.usage);
    return exitUsage;
  }
  // Only the real process owns the console; an injected run must not touch it.
  final owned = context.interrupts == null;
  final restoreConsole = owned ? useUtf8ConsoleIfAttached() : () {};
  final interrupts =
      context.interrupts ?? ProcessSignal.sigint.watch().asBroadcastStream();
  // A Ctrl-C at a Windows console ends standard input; read on past it.
  final Stream<String> input =
      owned && Platform.isWindows && context.stdinIsTerminal
      ? windowsConsoleLines(interrupts)
      : stdin.transform(utf8.decoder).transform(const LineSplitter());
  try {
    return await runLineClient(
      engineArgs: [
        if (results.flag('resume')) '--resume',
        if (results.option('session') case final id?) ...['--session', id],
        if (results.option('model') case final model?) ...['--model', model],
        if (results.option('effort') case final effort?) ...[
          '--effort',
          effort,
        ],
      ],
      input: input,
      out: context.out,
      err: context.err,
      interactive: context.stdinIsTerminal,
      starter: context.engineStarter,
      interrupts: interrupts,
    );
  } finally {
    restoreConsole();
  }
}

/// A command that reads [KehaiSettings] and builds the credential store.
abstract class _KehaiCommand extends Command<int> {
  _KehaiCommand(this.context);

  /// The streams and environment of this run.
  final CliContext context;

  KehaiSettings get settings {
    try {
      return KehaiSettings.fromEnvironment(context.environment);
    } on SettingsError catch (e) {
      usageException(e.message);
    }
  }

  CredentialStore storeFor(KehaiSettings settings) =>
      CredentialStore(home: settings.home, backend: settings.createBackend());

  /// Prints [line] to standard error and returns [exitFailure].
  int fail(String line) {
    context.err.writeln(line);
    return exitFailure;
  }
}

class _LoginCommand extends Command<int> {
  _LoginCommand(CliContext context) {
    addSubcommand(_LoginOpenAiCommand(context));
  }

  @override
  final String name = 'login';

  @override
  final String description = 'Sign in to a model provider.';
}

class _LoginOpenAiCommand extends _KehaiCommand {
  _LoginOpenAiCommand(super.context) {
    argParser
      ..addFlag(
        'no-browser',
        negatable: false,
        help: 'Print the sign-in URL without opening a browser.',
      )
      ..addFlag(
        'enable-plan-usage',
        negatable: false,
        help:
            'Allow ChatGPT plan usage for an account that is already signed '
            'in.',
      );
  }

  @override
  final String name = 'openai';

  @override
  final String description = 'Sign in with ChatGPT (no API key).';

  @override
  Future<int> run() async {
    final settings = this.settings;
    final login = BrowserLogin(
      store: storeFor(settings),
      out: context.out,
      err: context.err,
      issuer: settings.issuer,
      openBrowser: !argResults!.flag('no-browser'),
      enablePlanUsage: argResults!.flag('enable-plan-usage'),
      interrupts: context.interrupts ?? ProcessSignal.sigint.watch(),
      // Pasted lines are read from a terminal. Against a loopback fake the
      // paste source may be a pipe too; the redirect URL check still applies.
      isTerminal: context.stdinIsTerminal || settings.overridden,
    );
    try {
      final result = await login.run();
      final plan = result.plan;
      context.out.writeln(
        'logged in as ${printable(result.email)}'
        '${plan == null ? '' : ' (${printable(plan)} plan)'}',
      );
      return exitSuccess;
    } on LoginFailure catch (e) {
      return fail(e.message);
    } on CredentialStoreError catch (e) {
      return fail('login failed: ${e.message}');
    }
  }
}

class _LogoutCommand extends Command<int> {
  _LogoutCommand(CliContext context) {
    addSubcommand(_LogoutOpenAiCommand(context));
  }

  @override
  final String name = 'logout';

  @override
  final String description = 'Sign out of a model provider.';
}

class _LogoutOpenAiCommand extends _KehaiCommand {
  _LogoutOpenAiCommand(super.context) {
    argParser.addFlag(
      'forget',
      negatable: false,
      help: 'Also forget the stored client registration.',
    );
  }

  @override
  final String name = 'openai';

  @override
  final String description = 'Revoke and clear the stored ChatGPT sign-in.';

  @override
  Future<int> run() async {
    final settings = this.settings;
    // Ctrl-C ends discovery and revocation early; logoutOpenAi then still
    // clears the local tokens before this command exits.
    final cancel = CancelToken();
    final interrupt = (context.interrupts ?? ProcessSignal.sigint.watch())
        .listen((_) => cancel.cancel());
    try {
      final line = await logoutOpenAi(
        store: storeFor(settings),
        issuer: settings.issuer,
        forget: argResults!.flag('forget'),
        cancel: cancel,
      );
      context.out.writeln(line);
      return exitSuccess;
    } on CredentialStoreError catch (e) {
      return fail('logout failed: ${e.message}');
    } finally {
      await interrupt.cancel();
    }
  }
}

class _DoctorCommand extends _KehaiCommand {
  _DoctorCommand(super.context);

  @override
  final String name = 'doctor';

  @override
  final String description =
      'Report the credential backend, account, token expiry, refresh '
      'result and available models.';

  @override
  Future<int> run() async {
    final settings = this.settings;
    final backend = settings.createBackend();
    var config = const UserConfig();
    String? configError;
    try {
      config = UserConfig.load(settings.home);
    } on ConfigError catch (e) {
      configError = e.message;
    }
    return runDoctor(
      store: CredentialStore(home: settings.home, backend: backend),
      backendName: Platform.isWindows
          ? 'Windows DPAPI (current user)'
          : 'private file, mode 0600',
      path: p.join(settings.home, backend.fileName),
      out: context.out,
      err: context.err,
      issuer: settings.issuer,
      apiBase: settings.apiBase,
      workspace: loadWorkspace(
        workspace: Directory.current.path,
        kehaiHome: Directory(settings.home),
      ),
      config: config,
      configError: configError,
    );
  }
}

class _RpcCommand extends _KehaiCommand {
  _RpcCommand(super.context) {
    argParser
      ..addFlag(
        'resume',
        negatable: false,
        help: "Reopen the workspace's latest session.",
      )
      ..addOption('session', help: 'Reopen the session with this id.')
      ..addOption('model', help: 'The model id to use.')
      ..addOption(
        'effort',
        allowed: effortValues,
        help: 'The reasoning effort to select (omitted: provider default).',
      )
      ..addFlag(
        'effort-default',
        negatable: false,
        hide: true,
        help: 'Child mode: inherit provider-default reasoning effort.',
      )
      ..addFlag(
        'child',
        negatable: false,
        help: 'Run as the child engine of an agent job (internal).',
      )
      ..addOption('parent', help: 'Child mode: the parent session directory.')
      ..addOption('job', help: 'Child mode: the parent job id.')
      ..addOption('role', help: 'Child mode: the agent role name.')
      ..addOption(
        'role-digest',
        help: 'Child mode: the SHA-256 of the role file.',
      )
      ..addOption('compaction-policy', hide: true)
      ..addFlag(
        'yolo',
        negatable: false,
        help: 'Child mode: run calls without permission prompts.',
      );
  }

  @override
  final String name = 'rpc';

  @override
  final String description =
      'Serve the engine to a client as newline-delimited JSON on standard '
      'input and output.';

  @override
  Future<int> run() async {
    final results = argResults!;
    if (results.flag('resume') && results.option('session') != null) {
      usageException('use --resume or --session, not both');
    }
    final ChildSpec? child;
    try {
      child = _childSpec(results, usageException);
    } on ConfigError catch (e) {
      context.err.writeln(e.message);
      return exitFailure;
    }
    return context.rpcRunner(
      settings: settings,
      workspace: Directory.current,
      input: context.rpcInput ?? stdin,
      output: context.rpcOutput ?? stdout,
      resume: results.flag('resume'),
      sessionId: results.option('session'),
      modelFlag: results.option('model'),
      effortFlag: results.option('effort'),
      child: child,
    );
  }
}

/// The child-mode options of `rpc`, or null outside child mode.
///
/// Child mode needs all of `--parent`, `--job`, `--role` and `--role-digest`
/// and refuses `--resume` and `--session`; the child-only options are refused
/// without `--child`. [usage] throws the usage error.
ChildSpec? _childSpec(ArgResults results, Never Function(String) usage) {
  const childOnly = ['parent', 'job', 'role', 'role-digest'];
  if (!results.flag('child')) {
    for (final name in [
      ...childOnly,
      'yolo',
      'effort-default',
      'compaction-policy',
    ]) {
      if (results.wasParsed(name)) usage('--$name needs --child');
    }
    return null;
  }
  if (results.flag('effort-default') && results.wasParsed('effort')) {
    usage('--effort-default cannot be combined with --effort');
  }
  if (results.flag('resume') || results.option('session') != null) {
    usage('--child cannot be combined with --resume or --session');
  }
  for (final name in childOnly) {
    if (results.option(name) == null) usage('--child needs --$name');
  }
  final policy = results.option('compaction-policy');
  if (policy == null) {
    throw const ConfigError(
      'compaction-policy',
      'child launch needs captured provider policy',
    );
  }
  UserConfig.decodeProviderPolicy(policy);
  return ChildSpec(
    parent: results.option('parent')!,
    job: results.option('job')!,
    role: results.option('role')!,
    roleDigest: results.option('role-digest')!,
    yolo: results.flag('yolo'),
    effortDefault: results.flag('effort-default'),
    compactionPolicy: policy,
  );
}
