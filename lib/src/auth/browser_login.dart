/// The browser login of `kehai login openai` (design D2, D3, D3b).
///
/// [BrowserLogin] runs OpenAI's native-app authorization-code flow with PKCE
/// against a loopback listener: it creates the host id, binds the callback
/// port, prints the authorize URL once, optionally opens the system browser,
/// waits for the callback or a pasted redirect URL, exchanges and verifies the
/// tokens, and commits them under `auth.lock` only if no other login, logout
/// or `--forget` committed meanwhile. Every pending step listens to the
/// [LoginController]'s cancel token.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../provider/provider.dart' show CancelToken;
import 'auth_error.dart';
import 'auth_failure.dart';
import 'credential_error.dart';
import 'credential_store.dart';
import 'failure_text.dart';
import 'jwt.dart';
import 'login_controller.dart';
import 'oauth_client.dart';
import 'oidc.dart';
import 'openai_constants.dart';
import 'pkce.dart';

/// Opens [url] in the user's browser with the given [environment].
///
/// A launcher that throws only makes the login print a hint.
typedef BrowserLauncher = Future<void> Function(
  String url,
  Map<String, String> environment,
);

const String _successPage = 'Kehai: signed in. You can close this tab.';
const String _failurePage =
    'Kehai: sign-in failed. Return to the terminal for details.';
const String _duplicatePage = 'Kehai: this sign-in already received a result.';

/// Environment variable names that are never handed to a subprocess, whatever
/// their value (provider keys, tokens and similar).
final RegExp _secretVariableName = RegExp(
  r'(token|secret|api_?key|password|credential)',
  caseSensitive: false,
);

/// Returns a new host id: `urn:uuid:` and a random UUIDv4.
///
/// [random] defaults to [Random.secure].
String newHostId({Random? random}) {
  final source = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => source.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int start, int end) => [
    for (var i = start; i < end; i++)
      bytes[i].toRadixString(16).padLeft(2, '0'),
  ].join();
  return '$openAiHostIdPrefix${hex(0, 4)}-${hex(4, 6)}-${hex(6, 8)}-'
      '${hex(8, 10)}-${hex(10, 16)}';
}

/// Returns the executable and arguments that open [url] on the platform.
///
/// Windows uses `rundll32 url.dll,FileProtocolHandler`, which needs no shell,
/// so an `&` in the query is not reinterpreted. macOS uses `open` and every
/// other platform `xdg-open`. [operatingSystem] defaults to
/// [Platform.operatingSystem].
(String, List<String>) browserCommand(String url, {String? operatingSystem}) =>
    switch (operatingSystem ?? Platform.operatingSystem) {
      'windows' => ('rundll32', ['url.dll,FileProtocolHandler', url]),
      'macos' => ('open', [url]),
      _ => ('xdg-open', [url]),
    };

/// Returns [parent] without the variables a subprocess must not see.
///
/// A variable is dropped when its name suggests a credential or its value
/// contains one of the live [secrets] (stored tokens, `state`, `nonce` and the
/// PKCE verifier).
Map<String, String> launcherEnvironment(
  Map<String, String> parent,
  Iterable<String> secrets,
) {
  final live = [
    for (final secret in secrets)
      if (secret.isNotEmpty) secret,
  ];
  return {
    for (final MapEntry(:key, :value) in parent.entries)
      if (!_secretVariableName.hasMatch(key) && !live.any(value.contains))
        key: value,
  };
}

/// Starts the system browser on [url] without waiting for it.
///
/// The process gets only [environment], never the parent environment.
Future<void> launchSystemBrowser(
  String url,
  Map<String, String> environment,
) async {
  final (executable, arguments) = browserCommand(url);
  await Process.start(
    executable,
    arguments,
    environment: environment,
    includeParentEnvironment: false,
    mode: ProcessStartMode.detached,
  );
}

/// Splits [input] into lines, keeping at most [maxBytes] bytes of each.
///
/// A longer line is delivered cut to `maxBytes + 1` bytes, so the reader sees
/// it exceed the limit without the rest ever being held in memory. A trailing
/// `\r` is removed, and a final line without a newline is delivered too.
Stream<String> boundedLines(
  Stream<List<int>> input, {
  int maxBytes = openAiMaxPastedLineBytes,
}) {
  // Not an `async*` generator: cancelling a generator that waits on `input`
  // only completes when `input` next delivers, so a login that ended with the
  // terminal silent would never stop reading standard input.
  final line = <int>[];
  late final StreamController<String> controller;
  StreamSubscription<List<int>>? source;
  controller = StreamController<String>(
    onListen: () {
      source = input.listen(
        (chunk) {
          for (final byte in chunk) {
            if (byte == 0x0a) {
              controller.add(_decodeLine(line));
              line.clear();
            } else if (line.length <= maxBytes) {
              line.add(byte);
            }
          }
        },
        onError: controller.addError,
        onDone: () {
          if (line.isNotEmpty) controller.add(_decodeLine(line));
          controller.close();
        },
      );
    },
    onPause: () => source?.pause(),
    onResume: () => source?.resume(),
    onCancel: () => source?.cancel(),
  );
  return controller.stream;
}

String _decodeLine(List<int> bytes) {
  final end = bytes.isNotEmpty && bytes.last == 0x0d
      ? bytes.length - 1
      : bytes.length;
  return utf8.decode(bytes.sublist(0, end), allowMalformed: true);
}

/// The signed-in account reported by a successful login.
final class LoginResult {
  /// Creates a result.
  const LoginResult({
    required this.email,
    required this.subject,
    required this.clientId,
    this.plan,
  });

  /// The account email, or the subject when the ID token carries none.
  final String email;

  /// The verified account subject.
  final String subject;

  /// The client id the tokens were issued to.
  final String clientId;

  /// The ChatGPT plan name, if the ID token carries one.
  final String? plan;
}

/// One browser login. Create it, call [run] once, and read the outcome.
final class BrowserLogin {
  /// Creates a login against [store].
  ///
  /// [out] receives the authorize URL, the only output carrying `state` and
  /// `nonce`; [err] receives hints and rejection notices. [issuer] is the auth
  /// server. [primaryPort] and [fallbackPort] are the callback ports (the
  /// design values by default); the fallback is tried only with a stored
  /// registration. With [openBrowser] false no launcher starts. With
  /// [enablePlanUsage] the login needs a stored registration and sends
  /// `prompt=consent`.
  ///
  /// [launcher] opens the browser with [environment] stripped of secrets
  /// (default: the process environment). Lines pasted by the user arrive on
  /// [pasteLines] (default: standard input) and are read only when
  /// [isTerminal] is true (default: whether standard input is a terminal).
  /// [cancel] is the login's cancel token, [deadline] its wait limit and
  /// [interrupts] the Ctrl-C stream. [now] and [random] are test seams.
  BrowserLogin({
    required this.store,
    required this.out,
    required this.err,
    this.issuer = openAiIssuer,
    this.primaryPort = openAiRedirectPort,
    this.fallbackPort = openAiFallbackRedirectPort,
    this.openBrowser = true,
    this.enablePlanUsage = false,
    this.launcher = launchSystemBrowser,
    this.environment,
    this.pasteLines,
    this.isTerminal,
    this.cancel,
    this.deadline = openAiLoginDeadline,
    this.interrupts,
    this.now,
    this.random,
  });

  /// The credential store of the Kehai home.
  final CredentialStore store;

  /// The standard output sink.
  final StringSink out;

  /// The standard error sink.
  final StringSink err;

  /// The auth server issuer.
  final String issuer;

  /// The first-choice callback port.
  final int primaryPort;

  /// The callback port used when [primaryPort] is busy and a registration is
  /// stored.
  final int fallbackPort;

  /// Whether to open the system browser.
  final bool openBrowser;

  /// Whether this login re-runs consent for plan usage.
  final bool enablePlanUsage;

  /// Opens the browser.
  final BrowserLauncher launcher;

  /// The environment the launcher's is derived from, or `null` for the
  /// process environment.
  final Map<String, String>? environment;

  /// The lines the user pastes, or `null` for standard input.
  final Stream<String>? pasteLines;

  /// Whether standard input is a terminal, or `null` to ask the process.
  final bool? isTerminal;

  /// The cancel token of the login, or `null` for a private one.
  final CancelToken? cancel;

  /// The longest the login waits for a result.
  final Duration deadline;

  /// The Ctrl-C stream, or `null` for none.
  final Stream<Object?>? interrupts;

  /// The clock, or `null` for the system clock.
  final DateTime Function()? now;

  /// The randomness source, or `null` for [Random.secure].
  final Random? random;

  final Completer<Map<String, String>> _callback =
      Completer<Map<String, String>>();
  final Completer<bool> _finished = Completer<bool>();
  final List<Future<void>> _handlers = [];
  late final LoginController _controller;
  late Uri _redirect;

  /// Runs the login and returns the signed-in account.
  ///
  /// Throws a [LoginFailure] whose message is the line to print. When the
  /// sign-in is valid but plan usage was not allowed, the registration is
  /// stored (marked disabled) before the failure is thrown.
  Future<LoginResult> run() async {
    _controller = LoginController(
      cancel: cancel,
      deadline: deadline,
      interrupts: interrupts,
    );
    HttpServer? server;
    StreamSubscription<String>? paste;
    var succeeded = false;
    try {
      final result = await _login(
        onServer: (bound) => server = bound,
        onPaste: (subscription) => paste = subscription,
      );
      succeeded = true;
      return result;
    } finally {
      if (!_finished.isCompleted) _finished.complete(succeeded);
      await Future.wait(List.of(_handlers))
          .then<void>((_) {}, onError: (Object _) {})
          .timeout(const Duration(seconds: 2), onTimeout: () {});
      await paste?.cancel();
      await server?.close(force: true);
      await _controller.dispose();
    }
  }

  Future<LoginResult> _login({
    required void Function(HttpServer) onServer,
    required void Function(StreamSubscription<String>) onPaste,
  }) async {
    final c = _controller;
    final snapshot = await _stage(_loadRecord);
    final registration = snapshot.registration;
    final secrets = <String>[
      if (snapshot.tokens case final tokens?) ...[
        tokens.accessToken,
        tokens.refreshToken,
        tokens.idToken,
      ],
    ];

    final server = await _bind(hasRegistration: registration != null);
    onServer(server);
    c.checkpoint();
    server.listen(_serve, onError: (Object _) {});
    _redirect = Uri(
      scheme: 'http',
      host: openAiRedirectHost,
      port: server.port,
      path: openAiCallbackPath,
    );

    final pkce = PkcePair.generate(random: random);
    final state = generateState(random: random);
    final nonce = generateNonce(random: random);
    secrets.addAll([state, nonce, pkce.verifier]);
    final terminal = _stdinIsTerminal();
    if (terminal) {
      onPaste(
        (pasteLines ?? boundedLines(stdin)).listen(
          _onPastedLine,
          onError: (Object _) {},
        ),
      );
    }

    final url = Uri.parse('$issuer$openAiAuthorizePath').replace(
      queryParameters: {
        'response_type': 'code',
        'client_id': registration?.clientId ?? openAiDynamicClientId,
        'redirect_uri': _redirect.toString(),
        'scope': openAiScope,
        'resource': openAiResource,
        'code_challenge': pkce.challenge,
        'code_challenge_method': 'S256',
        'state': state,
        'nonce': nonce,
        'ext_agent_host_id': snapshot.hostId,
        if (registration == null) 'agent_name_hint': openAiAgentNameHint,
        if (enablePlanUsage) openAiReconsentParam: openAiReconsentValue,
      },
    );
    out
      ..writeln('Open this URL to sign in with ChatGPT:')
      ..writeln(url);
    if (terminal) {
      out.writeln(
        'If the browser runs on another machine, paste the final redirect '
        'URL here and press Enter.',
      );
    }
    if (openBrowser) {
      unawaited(
        _launch(
          url.toString(),
          launcherEnvironment(environment ?? Platform.environment, secrets),
        ),
      );
    }

    final params = await Future.any<Map<String, String>?>([
      _callback.future,
      c.token.whenCancelled.then<Map<String, String>?>((_) => null),
    ]);
    if (params == null) throw c.cancellation();

    final text = FailureText(secrets: secrets);
    if (params['state'] != state) {
      throw const LoginFailure('login failed: state mismatch');
    }
    if (params['error'] case final error?) {
      throw LoginFailure(
        'login failed: authorization was not granted '
        '(${text.validateCode(error)})',
      );
    }
    final issued = params['client_id'];
    final String clientId;
    if (registration == null) {
      if (issued == null || issued.isEmpty) {
        throw const LoginFailure('login failed: registration incomplete');
      }
      clientId = issued;
    } else {
      if (issued != null && issued != registration.clientId) {
        throw const LoginFailure(
          'login failed: the authorization server returned a different '
          'client id',
        );
      }
      clientId = registration.clientId;
    }
    final code = params['code'];
    if (code == null || code.isEmpty) {
      throw const LoginFailure(
        'login failed: no authorization code was returned',
      );
    }
    secrets.add(code);

    final grant = await _stage(
      () => OAuthClient(issuer, cancelled: c.token.whenCancelled).exchangeCode(
        clientId: clientId,
        code: code,
        codeVerifier: pkce.verifier,
        redirectUri: _redirect.toString(),
        secrets: [state, nonce],
      ),
    );

    final oidc = OidcClient(issuer, cancelled: c.token.whenCancelled);
    final discovery = await _stage(oidc.discover);
    final keys = await _stage(() => oidc.fetchKeys(discovery.jwksUri));
    final VerifiedIdToken verified;
    try {
      verified = verifyIdToken(
        grant.idToken!,
        keys: keys,
        issuer: issuer,
        clientId: clientId,
        nonce: nonce,
        now: now?.call(),
      );
    } on AuthError catch (e) {
      throw LoginFailure('login failed: ${e.message}');
    }
    c.checkpoint();

    Future<void> discard() => _revokeDiscarded(
      discovery.revocationEndpoint,
      grant.refreshToken!,
      clientId,
    );

    if (registration != null && verified.subject != registration.subject) {
      await discard();
      throw const LoginFailure(
        'login failed: this ChatGPT account differs from the one Kehai is '
        'registered for; run kehai logout openai --forget to switch accounts',
      );
    }

    final granted = grant.scopes!.contains(openAiPlanUsageScope);
    final saved = now?.call() ?? DateTime.now().toUtc();
    final newRegistration = CredentialRegistration(
      issuer: issuer,
      clientId: clientId,
      subject: verified.subject,
      email: verified.email ?? verified.subject,
      plan: verified.planType,
      planUsageEnabled: granted,
    );
    final tokens = granted
        ? CredentialTokens(
            idToken: grant.idToken!,
            accessToken: grant.accessToken,
            refreshToken: grant.refreshToken!,
            expiresAt: saved.add(grant.expiresIn),
            scopes: grant.scopes!,
            savedAt: saved,
            lastRefresh: saved,
          )
        : null;

    final committed = await _stage(
      () => _commit(snapshot, newRegistration, tokens),
    );
    if (!committed) {
      await discard();
      throw const LoginFailure(LoginFailure.staleMessage);
    }
    if (!granted) {
      await discard();
      throw const LoginFailure(
        'login failed: ChatGPT plan usage was not allowed; run kehai login '
        'openai --enable-plan-usage',
      );
    }
    return LoginResult(
      email: newRegistration.email,
      subject: newRegistration.subject,
      clientId: clientId,
      plan: newRegistration.plan,
    );
  }

  /// Reads the record, creating the host id first when none exists (step 1).
  ///
  /// With [enablePlanUsage] and no registration this fails before anything is
  /// written.
  Future<CredentialRecord> _loadRecord() async {
    final existing = store.load();
    if (enablePlanUsage && existing?.registration == null) {
      throw const LoginFailure(
        'login failed: --enable-plan-usage needs a stored sign-in; run kehai '
        'login openai first',
      );
    }
    if (existing != null) return existing;
    final lock = await store.acquireLock(
      isCancelled: () => _controller.isCancelled,
    );
    try {
      final again = store.load();
      if (again != null) return again;
      final created = CredentialRecord(
        hostId: newHostId(random: random),
        generation: 0,
      );
      store.replace(created);
      return created;
    } finally {
      lock.release();
    }
  }

  /// Binds the callback listener (step 2).
  Future<HttpServer> _bind({required bool hasRegistration}) async {
    try {
      return await HttpServer.bind(InternetAddress.loopbackIPv4, primaryPort);
    } on SocketException {
      if (!hasRegistration) {
        throw LoginFailure(
          'login failed: port $primaryPort is busy; another login (for '
          'example the Codex CLI) may be holding it. Close it and run kehai '
          'login openai again',
        );
      }
    }
    try {
      return await HttpServer.bind(InternetAddress.loopbackIPv4, fallbackPort);
    } on SocketException {
      throw LoginFailure(
        'login failed: ports $primaryPort and $fallbackPort are both busy; '
        'another login (for example the Codex CLI) may be holding them. '
        'Close it and run kehai login openai again',
      );
    }
  }

  /// Compares with the start snapshot and replaces the record, under the lock
  /// (step 8). Returns `false`, writing nothing, when the record changed.
  Future<bool> _commit(
    CredentialRecord snapshot,
    CredentialRegistration registration,
    CredentialTokens? tokens,
  ) async {
    final lock = await store.acquireLock(
      isCancelled: () => _controller.isCancelled,
    );
    try {
      _controller.checkpoint();
      final current = store.load();
      if (current == null ||
          current.generation != snapshot.generation ||
          current.registration?.clientId != snapshot.registration?.clientId ||
          current.registration?.subject != snapshot.registration?.subject) {
        return false;
      }
      _controller.commit(
        () => store.replace(
          CredentialRecord(
            hostId: current.hostId,
            generation: current.generation + 1,
            registration: registration,
            tokens: tokens,
          ),
        ),
      );
      return true;
    } finally {
      lock.release();
    }
  }

  /// Revokes a refresh token that Kehai will not keep. Never throws.
  Future<void> _revokeDiscarded(
    Uri endpoint,
    String refreshToken,
    String clientId,
  ) async {
    await OAuthClient(
      issuer,
      timeout: openAiStaleRevocationTimeout,
    ).revoke(endpoint, refreshToken: refreshToken, clientId: clientId);
  }

  /// Runs one pending step: maps its errors to a [LoginFailure] and discards
  /// its result when the login was cancelled meanwhile.
  Future<T> _stage<T>(Future<T> Function() step) async {
    try {
      final value = await step();
      _controller.checkpoint();
      return value;
    } on LoginFailure {
      rethrow;
    } on AuthFailure catch (e) {
      throw _failureFor(
        e.kind == FailureKind.cancelled,
        'login failed: ${e.message}; run kehai login openai again',
      );
    } on AuthError catch (e) {
      throw _failureFor(
        e.reason == authCancelledReason,
        'login failed: ${e.message}',
      );
    } on CredentialStoreError catch (e) {
      throw _failureFor(
        e.reason == CredentialStoreError.cancelled,
        'login failed: ${e.message}',
      );
    }
  }

  LoginFailure _failureFor(bool aborted, String message) {
    if (_controller.isCancelled || aborted) return _controller.cancellation();
    return LoginFailure(message);
  }

  bool _stdinIsTerminal() {
    final explicit = isTerminal;
    if (explicit != null) return explicit;
    try {
      return stdin.hasTerminal;
    } on Object {
      return false;
    }
  }

  Future<void> _launch(
    String url,
    Map<String, String> launchEnvironment,
  ) async {
    try {
      await launcher(url, launchEnvironment);
    } on Object {
      err.writeln('Could not open a browser; open the URL above to continue.');
    }
  }

  /// Offers [params] as the result of this login. Returns whether they were
  /// the first.
  bool _accept(Map<String, String> params) {
    if (_callback.isCompleted) return false;
    _callback.complete(params);
    return true;
  }

  void _onPastedLine(String line) {
    if (_callback.isCompleted) return;
    void reject() => err.writeln(
      'Pasted text ignored: expected the redirect URL starting with '
      '$_redirect',
    );
    if (utf8.encode(line).length > openAiMaxPastedLineBytes) return reject();
    final text = line.trim();
    if (text.isEmpty) return;
    final uri = Uri.tryParse(text);
    if (uri == null ||
        uri.scheme != _redirect.scheme ||
        uri.host != _redirect.host ||
        uri.port != _redirect.port ||
        uri.path != _redirect.path) {
      return reject();
    }
    final Map<String, String> params;
    try {
      params = uri.queryParameters;
    } on FormatException {
      return reject();
    }
    _accept(params);
  }

  void _serve(HttpRequest request) {
    final handler = _respond(request);
    _handlers.add(handler);
    unawaited(handler.whenComplete(() => _handlers.remove(handler)));
  }

  Future<void> _respond(HttpRequest request) async {
    try {
      if (request.method != 'GET' || request.uri.path != openAiCallbackPath) {
        return await _page(request.response, HttpStatus.notFound, 'Not found.');
      }
      final Map<String, String> params;
      try {
        params = request.uri.queryParameters;
      } on FormatException {
        return await _page(
          request.response,
          HttpStatus.badRequest,
          _failurePage,
        );
      }
      if (!_accept(params)) {
        return await _page(
          request.response,
          HttpStatus.conflict,
          _duplicatePage,
        );
      }
      final ok = await _finished.future;
      await _page(
        request.response,
        ok ? HttpStatus.ok : HttpStatus.badRequest,
        ok ? _successPage : _failurePage,
      );
    } on Object {
      // The browser went away; nothing to report.
    }
  }

  Future<void> _page(HttpResponse response, int status, String message) async {
    response
      ..statusCode = status
      ..headers.contentType = ContentType.html
      ..headers.set('cache-control', 'no-store')
      ..headers.set('referrer-policy', 'no-referrer')
      ..write('<!doctype html><meta charset="utf-8"><title>Kehai</title>')
      ..write('<p>$message</p>');
    await response.close();
  }
}
