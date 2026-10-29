/// The `kehai` command line (design D1).
///
/// [runCli] wires a `CommandRunner` with `login openai`, `logout openai` and
/// `doctor`. Exit codes: `0` success, `1` failure, `64` usage error. A failure
/// prints one sanitized line to standard error; no command prints a token.
library;

import 'dart:async';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:path/path.dart' as p;

import '../auth/browser_login.dart';
import '../auth/credential_error.dart';
import '../auth/credential_store.dart';
import '../auth/login_controller.dart';
import '../auth/logout.dart';
import '../provider/provider.dart' show CancelToken;
import 'doctor.dart';
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
}) async {
  final context = CliContext(
    environment: environment,
    out: out,
    err: err,
    interrupts: interrupts,
    stdinTerminalOverride: stdinIsTerminal,
  );
  final runner =
      CommandRunner<int>('kehai', 'Kehai headless coding-agent engine.')
        ..addCommand(_LoginCommand(context))
        ..addCommand(_LogoutCommand(context))
        ..addCommand(_DoctorCommand(context));
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
    );
  }
}
