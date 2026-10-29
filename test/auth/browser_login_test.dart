import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/src/auth/browser_login.dart';
import 'package:kehai/src/auth/credential_store.dart';
import 'package:kehai/src/auth/login_controller.dart';
import 'package:kehai/src/auth/logout.dart';
import 'package:kehai/src/auth/openai_constants.dart';
import 'package:kehai/src/auth/refresher.dart';
import 'package:kehai/src/provider/provider.dart' show CancelToken;
import 'package:test/test.dart';

import '../support/fake_openai.dart';
import '../support/login_support.dart';

const _noPlanScope = 'openid profile email offline_access resource.invoke';

/// One running login with its captured output and outcome.
final class _Session {
  _Session(this.login, this.out, this.err) {
    outcome = login.run().then<Object>(
      (result) => result,
      onError: (Object error) => error,
    );
  }

  final BrowserLogin login;
  final TestSink out;
  final TestSink err;

  /// The [LoginResult], or whatever the login threw.
  late final Future<Object> outcome;

  Future<String> url() => out.authorizeUrl();

  Future<LoginResult> success() async {
    final result = await outcome;
    if (result is LoginResult) return result;
    fail('expected the login to succeed, got: $result');
  }

  Future<LoginFailure> failure() async {
    final result = await outcome;
    if (result is LoginFailure) return result;
    fail('expected a LoginFailure, got: $result');
  }
}

/// A Kehai home, two ports and the launcher bookkeeping of one login rig.
final class _Rig {
  _Rig._(this.fake, this.home, this.primary, this.fallback);

  static Future<_Rig> create(FakeOpenAi fake, {TestHome? home}) async {
    final first = await freePort();
    var second = await freePort();
    while (second == first) {
      second = await freePort();
    }
    return _Rig._(fake, home ?? TestHome(), first, second);
  }

  final FakeOpenAi fake;
  final TestHome home;
  final int primary;
  final int fallback;
  final List<String> launches = [];
  final List<Map<String, String>> environments = [];

  CredentialStore get store => home.store;

  /// A launcher that records its call and follows the URL as a browser would.
  Future<void> followingLauncher(
    String url,
    Map<String, String> environment,
  ) async {
    launches.add(url);
    environments.add(environment);
    unawaited(getPage(url).then<void>((_) {}, onError: (Object _) {}));
  }

  /// A launcher that records its call and does nothing else.
  Future<void> recordingLauncher(
    String url,
    Map<String, String> environment,
  ) async {
    launches.add(url);
    environments.add(environment);
  }

  _Session start({
    bool openBrowser = true,
    bool enablePlanUsage = false,
    BrowserLauncher? launcher,
    Stream<String>? paste,
    bool terminal = false,
    CancelToken? cancel,
    Duration deadline = const Duration(seconds: 60),
    Map<String, String>? environment,
    int? primaryPort,
    int? fallbackPort,
  }) {
    final out = TestSink();
    final err = TestSink();
    return _Session(
      BrowserLogin(
        store: store,
        out: out,
        err: err,
        issuer: fake.issuer,
        primaryPort: primaryPort ?? primary,
        fallbackPort: fallbackPort ?? fallback,
        openBrowser: openBrowser,
        enablePlanUsage: enablePlanUsage,
        launcher: launcher ?? followingLauncher,
        environment: environment ?? const {'PATH': 'test-path'},
        pasteLines: paste,
        isTerminal: terminal,
        cancel: cancel,
        deadline: deadline,
      ),
      out,
      err,
    );
  }

  /// The redirect URI of the rig's primary port.
  String get redirectUri => 'http://127.0.0.1:$primary/auth/callback';
}

int _count(String haystack, String needle) =>
    RegExp(RegExp.escape(needle)).allMatches(haystack).length;

void main() {
  late FakeOpenAi fake;
  late _Rig rig;

  setUp(() async {
    fake = await FakeOpenAi.start();
    rig = await _Rig.create(fake);
  });

  group('sign in', () {
    test('verified callback stores registration and tokens and reports '
        'account', () async {
      final session = rig.start();

      final result = await session.success();

      expect(result.email, 'user@example.com');
      expect(result.subject, 'user-123');
      expect(result.clientId, 'oaiapp_fake');
      final record = rig.store.load()!;
      expect(
        record.hostId,
        matches(
          RegExp(
            r'^urn:uuid:[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-'
            r'[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
          ),
        ),
      );
      expect(record.generation, 1);
      final registration = record.registration!;
      expect(registration.clientId, 'oaiapp_fake');
      expect(registration.subject, 'user-123');
      expect(registration.email, 'user@example.com');
      expect(registration.plan, 'plus');
      expect(registration.planUsageEnabled, isTrue);
      expect(registration.issuer, fake.issuer);
      final tokens = record.tokens!;
      expect(tokens.scopes, contains(openAiPlanUsageScope));
      expect(
        tokens.expiresAt.difference(DateTime.now().toUtc()),
        greaterThan(const Duration(minutes: 55)),
      );

      final exchange = fake.tokenRequests.single.form;
      expect(exchange['grant_type'], 'authorization_code');
      expect(exchange['client_id'], 'oaiapp_fake');
      expect(exchange['redirect_uri'], rig.redirectUri);
      expect(exchange['resource'], openAiResource);
      expect(fake.discoveryRequests, isNotEmpty);
      expect(fake.jwksRequests, isNotEmpty);

      // The only secret-bearing output is the authorize URL.
      for (final secret in [
        tokens.accessToken,
        tokens.refreshToken,
        tokens.idToken,
        exchange['code']!,
        exchange['code_verifier']!,
      ]) {
        expect(session.out.text, isNot(contains(secret)));
        expect(session.err.text, isNot(contains(secret)));
      }
      expect(await portIsFree(rig.primary), isTrue, reason: 'port released');
    });

    test('state mismatch exchanges nothing', () async {
      fake.authorizeScripts.add(const AuthorizeScript(state: 'forged-state'));
      final session = rig.start(openBrowser: false);

      final url = await session.url();
      final (status, body) = await getPage(url);
      final failure = await session.failure();

      expect(failure.message, 'login failed: state mismatch');
      expect(fake.tokenRequests, isEmpty);
      expect(status, isNot(200));
      expect(body, contains('sign-in failed'));
      expect(body, isNot(contains('forged-state')));
      final record = rig.store.load()!;
      expect(record.registration, isNull);
      expect(record.tokens, isNull);
    });

    test('error parameter fails naming the code', () async {
      fake.authorizeScripts.add(const AuthorizeScript.accessDenied());
      final session = rig.start();

      final failure = await session.failure();

      expect(failure.message, contains('access_denied'));
      expect(fake.tokenRequests, isEmpty);
      final record = rig.store.load()!;
      expect(record.registration, isNull);
      expect(record.tokens, isNull);
    });

    test('error equal to the received code does not print the code', () async {
      final session = rig.start(openBrowser: false);
      final callback = Uri.parse(await callbackUrlFor(await session.url()));
      final query = {...callback.queryParameters, 'code': 'code_abc'};
      query['error'] = 'code_abc';

      await getPage(callback.replace(queryParameters: query).toString());
      final failure = await session.failure();

      expect(failure.message, contains('authorization was not granted'));
      expect(failure.message, isNot(contains('code_abc')));
      expect(session.out.text, isNot(contains('code_abc')));
      expect(session.err.text, isNot(contains('code_abc')));
      expect(fake.tokenRequests, isEmpty);
    });

    test('invalid_grant on exchange stores nothing', () async {
      fake.tokenScripts.add(TokenScript.error(400, 'invalid_grant'));
      final session = rig.start();

      final failure = await session.failure();

      expect(failure.message, contains('invalid_grant'));
      expect(failure.message, contains('kehai login openai'));
      final record = rig.store.load()!;
      expect(record.registration, isNull);
      expect(record.tokens, isNull);
      expect(record.generation, 0);
    });

    test('no api key grant and no api key field', () async {
      final session = rig.start();
      await session.success();

      final url = Uri.parse(
        session.out.lines.firstWhere((line) => line.startsWith('http')),
      );
      for (final key in url.queryParameters.keys) {
        expect(key.toLowerCase(), isNot(contains('api')));
      }
      for (final request in fake.tokenRequests) {
        expect(request.form['grant_type'], 'authorization_code');
        for (final key in request.form.keys) {
          expect(key.toLowerCase(), isNot(contains('api')));
        }
      }
      final stored = jsonEncode(rig.store.load()!.toJson()).toLowerCase();
      expect(stored, isNot(contains('api_key')));
      expect(stored, isNot(contains('apikey')));
    });
  });

  group('dynamic client registration', () {
    test(
      'first login uses dynamic_agent_client and saves the issued id',
      () async {
        fake.issuedClientId = 'oaiapp_abc';
        final session = rig.start();

        await session.success();

        final query = fake.authorizeRequests.single.query;
        expect(query['client_id'], 'dynamic_agent_client');
        expect(query['agent_name_hint'], 'Kehai');
        expect(fake.tokenRequests.single.form['client_id'], 'oaiapp_abc');
        expect(rig.store.load()!.registration!.clientId, 'oaiapp_abc');
      },
    );

    test('first login without issued id stores nothing', () async {
      fake.authorizeScripts.add(const AuthorizeScript.withoutClientId());
      final session = rig.start();

      final failure = await session.failure();

      expect(failure.message, 'login failed: registration incomplete');
      expect(fake.tokenRequests, isEmpty);
      final record = rig.store.load()!;
      expect(record.registration, isNull);
      expect(record.tokens, isNull);
    });

    test('later login reuses saved client without name hint', () async {
      rig.store.replace(loggedInRecord(clientId: 'oaiapp_abc', generation: 3));
      fake.authorizeScripts.add(const AuthorizeScript.withoutClientId());
      final session = rig.start();

      await session.success();

      final query = fake.authorizeRequests.single.query;
      expect(query['client_id'], 'oaiapp_abc');
      expect(query.containsKey('agent_name_hint'), isFalse);
      expect(fake.tokenRequests.single.form['client_id'], 'oaiapp_abc');
      final record = rig.store.load()!;
      expect(record.registration!.clientId, 'oaiapp_abc');
      expect(record.generation, 4);
    });

    test('different issued id is rejected', () async {
      final seeded = loggedInRecord(clientId: 'oaiapp_abc');
      rig.store.replace(seeded);
      fake.authorizeScripts.add(
        const AuthorizeScript.withClientId('oaiapp_xyz'),
      );
      final session = rig.start();

      final failure = await session.failure();

      expect(failure.message, startsWith('login failed:'));
      expect(fake.tokenRequests, isEmpty);
      expect(rig.store.load(), seeded);
    });

    test('different subject fails naming logout --forget', () async {
      final seeded = loggedInRecord(subject: 'someone-else');
      rig.store.replace(seeded);
      final session = rig.start();

      final failure = await session.failure();

      expect(failure.message, contains('kehai logout openai --forget'));
      expect(rig.store.load(), seeded, reason: 'nothing stored');
      expect(fake.revocationRequests, hasLength(1), reason: 'unused token');
    });

    test('host id survives logout --forget', () async {
      await rig.start().success();
      await logoutOpenAi(store: rig.store, issuer: fake.issuer, forget: true);
      await rig.start().success();

      expect(fake.authorizeRequests, hasLength(2));
      final first = fake.authorizeRequests[0].query;
      final second = fake.authorizeRequests[1].query;
      expect(first['ext_agent_host_id'], startsWith(openAiHostIdPrefix));
      expect(second['ext_agent_host_id'], first['ext_agent_host_id']);
      expect(second['client_id'], 'dynamic_agent_client');
      expect(rig.store.load()!.hostId, first['ext_agent_host_id']);
    });
  });

  group('authorize url', () {
    test('carries the documented parameters', () async {
      final session = rig.start();
      await session.success();

      final query = fake.authorizeRequests.single.query;
      expect(query['response_type'], 'code');
      expect(query['redirect_uri'], rig.redirectUri);
      expect(query['scope'], openAiScope);
      expect(query['resource'], openAiResource);
      expect(query['code_challenge_method'], 'S256');
      expect(query['code_challenge'], hasLength(43));
      expect(query['state'], hasLength(43));
      expect(query['nonce'], hasLength(43));
      expect(query['state'], isNot(query['nonce']));
    });

    test('ordinary login url has no prompt or force_reconsent', () async {
      await rig.start().success();

      final query = fake.authorizeRequests.single.query;
      expect(query.containsKey('prompt'), isFalse);
      expect(query.containsKey('force_reconsent'), isFalse);
    });

    test('authorize url with state and nonce appears once on stdout and as '
        'launcher argument, nowhere else', () async {
      fake.authorizeScripts.add(const AuthorizeScript(state: 'forged'));
      final session = rig.start();

      final failure = await session.failure();

      expect(failure.message, 'login failed: state mismatch');
      final url = session.out.lines.firstWhere((l) => l.startsWith('http'));
      final query = Uri.parse(url).queryParameters;
      final state = query['state']!;
      final nonce = query['nonce']!;
      expect(rig.launches, [url]);
      expect(_count(session.out.text, url), 1);
      expect(_count(session.out.text, state), 1);
      expect(_count(session.out.text, nonce), 1);
      for (final secret in [state, nonce, 'code-']) {
        expect(session.err.text, isNot(contains(secret)));
        expect(failure.message, isNot(contains(secret)));
        for (final line in session.out.lines.where((l) => l != url)) {
          expect(line, isNot(contains(secret)));
        }
        for (final value in rig.environments.single.values) {
          expect(value, isNot(contains(secret)));
        }
      }
    });

    test('browser launcher environment contains no token', () async {
      final seeded = loggedInRecord();
      rig.store.replace(seeded);
      final cancel = CancelToken();
      final session = rig.start(
        launcher: rig.recordingLauncher,
        cancel: cancel,
        environment: {
          'PATH': '/usr/bin',
          'SystemRoot': r'C:\Windows',
          'HARMLESS': 'ok',
          'LEAKY': 'prefix-${seeded.tokens!.accessToken}-suffix',
          'ALSO_ID': seeded.tokens!.idToken,
          'OPENAI_API_KEY': 'sk-unrelated',
          'MY_REFRESH_TOKEN': 'abc',
          'github_secret': 'abc',
        },
      );

      final url = await session.url();
      while (rig.environments.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      cancel.cancel();
      await session.failure();

      final environment = rig.environments.single;
      expect(environment['PATH'], '/usr/bin');
      expect(environment['HARMLESS'], 'ok');
      expect(environment.keys, isNot(contains('LEAKY')));
      expect(environment.keys, isNot(contains('ALSO_ID')));
      expect(environment.keys, isNot(contains('OPENAI_API_KEY')));
      expect(environment.keys, isNot(contains('MY_REFRESH_TOKEN')));
      expect(environment.keys, isNot(contains('github_secret')));
      final query = Uri.parse(url).queryParameters;
      for (final value in environment.values) {
        expect(value, isNot(contains(seeded.tokens!.accessToken)));
        expect(value, isNot(contains(seeded.tokens!.refreshToken)));
        expect(value, isNot(contains(seeded.tokens!.idToken)));
        expect(value, isNot(contains(query['state']!)));
        expect(value, isNot(contains(query['nonce']!)));
      }
    });

    test('launcher command per platform', () {
      const url = 'https://auth.example/a?x=1&y=2';
      final (windows, windowsArgs) = browserCommand(
        url,
        operatingSystem: 'windows',
      );
      expect(windows, 'rundll32');
      expect(windowsArgs, ['url.dll,FileProtocolHandler', url]);
      final (macos, macosArgs) = browserCommand(url, operatingSystem: 'macos');
      expect(macos, 'open');
      expect(macosArgs, [url]);
      final (linux, linuxArgs) = browserCommand(url, operatingSystem: 'linux');
      expect(linux, 'xdg-open');
      expect(linuxArgs, [url]);
    });

    test('bounded lines split on newlines and cap each line', () async {
      final input = Stream.fromIterable([
        utf8.encode('first\r\nsec'),
        utf8.encode('ond\n'),
        utf8.encode('${'x' * 40}\nlast'),
      ]);

      final lines = await boundedLines(input, maxBytes: 10).toList();

      expect(lines, ['first', 'second', 'x' * 11, 'last']);
    });

    test('launcher environment drops secret names and secret values', () {
      final environment = launcherEnvironment(
        {
          'PATH': 'p',
          'A': 'has-secret-inside',
          'GITHUB_TOKEN': 'x',
          'openai_api_key': 'x',
          'KEEP': 'y',
        },
        ['secret'],
      );
      expect(environment, {'PATH': 'p', 'KEEP': 'y'});
    });
  });

  group('plan usage', () {
    test('grant without direct scope stores registration as plan usage '
        'disabled and no tokens', () async {
      fake.grantedScope = _noPlanScope;
      final session = rig.start();

      final failure = await session.failure();

      expect(failure.message, contains('not allowed'));
      expect(
        failure.message,
        contains('kehai login openai --enable-plan-usage'),
      );
      final record = rig.store.load()!;
      expect(record.tokens, isNull);
      expect(record.registration!.planUsageEnabled, isFalse);
      expect(record.registration!.clientId, 'oaiapp_fake');
      expect(record.generation, 1);
      expect(fake.revocationRequests, hasLength(1), reason: 'unused token');
    });

    test(
      'enable-plan-usage sends saved client, full scopes and prompt=consent, '
      'then stores tokens',
      () async {
        rig.store.replace(tokenlessRecord(generation: 2));
        final session = rig.start(enablePlanUsage: true);

        await session.success();

        final query = fake.authorizeRequests.single.query;
        expect(query['client_id'], 'oaiapp_fake');
        expect(query['scope'], openAiScope);
        expect(query['prompt'], 'consent');
        expect(query.containsKey('agent_name_hint'), isFalse);
        final record = rig.store.load()!;
        expect(record.tokens, isNotNull);
        expect(record.registration!.planUsageEnabled, isTrue);
        expect(record.generation, 3);
      },
    );

    test(
      'enable-plan-usage still without scope keeps plan usage disabled',
      () async {
        rig.store.replace(tokenlessRecord(generation: 2));
        fake.grantedScope = _noPlanScope;
        final session = rig.start(enablePlanUsage: true);

        final failure = await session.failure();

        expect(failure.message, contains('--enable-plan-usage'));
        expect(fake.authorizeRequests.single.query['prompt'], 'consent');
        final record = rig.store.load()!;
        expect(record.tokens, isNull);
        expect(record.registration!.planUsageEnabled, isFalse);
      },
    );

    test(
      'enable-plan-usage without registration binds nothing and fails',
      () async {
        final session = rig.start(enablePlanUsage: true);

        final failure = await session.failure();

        expect(failure.message, contains('kehai login openai'));
        expect(await portIsFree(rig.primary), isTrue);
        expect(session.out.text, isEmpty);
        expect(fake.authorizeRequests, isEmpty);
        expect(rig.launches, isEmpty);
        expect(rig.store.load(), isNull, reason: 'nothing stored');
      },
    );
  });

  group('stale login', () {
    test('logout committed during a pending login rejects the login', () async {
      rig.store.replace(loggedInRecord(generation: 3));
      final session = rig.start(openBrowser: false);
      final url = await session.url();

      await logoutOpenAi(store: rig.store, issuer: fake.issuer);
      final (_, page) = await getPage(url);
      final failure = await session.failure();

      expect(failure.message, LoginFailure.staleMessage);
      expect(failure.message, contains('kehai login openai'));
      expect(page, contains('sign-in failed'));
      final record = rig.store.load()!;
      expect(record.tokens, isNull);
      expect(record.generation, 4);
      expect(fake.revocationRequests, hasLength(2));
      final discarded = fake.revocationRequests.last.form['token']!;
      expect(discarded, startsWith('refresh-'));
    });

    test('account replaced during a pending login keeps account b', () async {
      rig.store.replace(loggedInRecord(generation: 3));
      final session = rig.start(openBrowser: false);
      final url = await session.url();

      await logoutOpenAi(store: rig.store, issuer: fake.issuer, forget: true);
      final accountB = loggedInRecord(
        generation: rig.store.load()!.generation + 1,
        clientId: 'oaiapp_b',
        subject: 'user-b',
        accessToken: 'b-access',
        refreshToken: 'b-refresh',
      );
      rig.store.replace(accountB);
      await getPage(url);
      final failure = await session.failure();

      expect(failure.message, LoginFailure.staleMessage);
      expect(rig.store.load(), accountB);
    });

    test('second of two first sign-ins stores nothing and revokes its '
        'token', () async {
      final other = await freePort();
      final first = rig.start(openBrowser: false);
      final firstUrl = await first.url();
      final second = rig.start(openBrowser: false, primaryPort: other);
      final secondUrl = await second.url();

      await getPage(firstUrl);
      await first.success();
      await getPage(secondUrl);
      final failure = await second.failure();

      expect(failure.message, LoginFailure.staleMessage);
      final record = rig.store.load()!;
      expect(record.registration!.clientId, 'oaiapp_fake');
      expect(record.generation, 1);
      expect(fake.revocationRequests, hasLength(1));
      final revoked = fake.revocationRequests.single.form;
      expect(revoked['token'], isNot(record.tokens!.refreshToken));
      expect(revoked['token'], startsWith('refresh-'));
      expect(revoked['client_id'], 'oaiapp_fake');
      expect(revoked['token_type_hint'], 'refresh_token');
    });

    test('host-only logout, host-only forget and disabled-registration logout '
        'each reject the pending login', () async {
      // Host-only record (the pending login stored it), plain logout.
      var current = await _Rig.create(fake);
      var session = current.start(openBrowser: false);
      var url = await session.url();
      await logoutOpenAi(store: current.store, issuer: fake.issuer);
      await getPage(url);
      expect((await session.failure()).message, LoginFailure.staleMessage);
      var record = current.store.load()!;
      expect(record.generation, 1);
      expect(record.registration, isNull);
      expect(record.tokens, isNull);

      // Host-only record, --forget.
      current = await _Rig.create(fake);
      session = current.start(openBrowser: false);
      url = await session.url();
      await logoutOpenAi(
        store: current.store,
        issuer: fake.issuer,
        forget: true,
      );
      await getPage(url);
      expect((await session.failure()).message, LoginFailure.staleMessage);
      record = current.store.load()!;
      expect(record.generation, 1);
      expect(record.tokens, isNull);

      // Registration marked plan usage disabled, pending --enable-plan-usage.
      current = await _Rig.create(fake);
      current.store.replace(tokenlessRecord(generation: 4));
      session = current.start(openBrowser: false, enablePlanUsage: true);
      url = await session.url();
      await logoutOpenAi(store: current.store, issuer: fake.issuer);
      await getPage(url);
      expect((await session.failure()).message, LoginFailure.staleMessage);
      record = current.store.load()!;
      expect(record.generation, 5);
      expect(record.tokens, isNull);
      expect(record.registration!.planUsageEnabled, isFalse);
    });

    test('refresh during a pending login does not reject it', () async {
      rig.store.replace(
        loggedInRecord(generation: 3, expiresIn: const Duration(minutes: 2)),
      );
      final session = rig.start(openBrowser: false);
      final url = await session.url();

      final refreshed = await Refresher(
        store: rig.store,
        issuer: fake.issuer,
      ).credentials();
      expect(rig.store.load()!.generation, 3);
      await getPage(url);
      await session.success();

      final record = rig.store.load()!;
      expect(record.generation, 4);
      expect(record.tokens!.accessToken, isNot(refreshed.accessToken));
      expect(record.tokens!.accessToken, isNot('stored-access-token'));
    });
  });

  group('callback port', () {
    test('free 1455 yields 127.0.0.1:1455 redirect', () async {
      await rig.start().success();

      expect(
        fake.authorizeRequests.single.query['redirect_uri'],
        'http://127.0.0.1:${rig.primary}/auth/callback',
      );
      expect(fake.tokenRequests.single.form['redirect_uri'], rig.redirectUri);
    });

    test('busy 1455 with registration falls back to 1457 without contacting '
        'holder', () async {
      rig.store.replace(loggedInRecord());
      final holder = await PortHolder.hold();
      final session = rig.start(primaryPort: holder.port);

      await session.success();

      final redirect = 'http://127.0.0.1:${rig.fallback}/auth/callback';
      expect(fake.authorizeRequests.single.query['redirect_uri'], redirect);
      expect(fake.tokenRequests.single.form['redirect_uri'], redirect);
      expect(holder.connections, 0);
    });

    test('busy 1455 without registration fails naming the port', () async {
      final holder = await PortHolder.hold();
      final session = rig.start(primaryPort: holder.port);

      final failure = await session.failure();

      expect(failure.message, contains('${holder.port}'));
      expect(failure.message, contains('Codex'));
      expect(holder.connections, 0);
      expect(rig.launches, isEmpty);
      expect(fake.authorizeRequests, isEmpty);
      expect(await portIsFree(rig.fallback), isTrue, reason: 'fallback unused');
    });

    test('both ports busy fails naming both', () async {
      rig.store.replace(loggedInRecord());
      final primary = await PortHolder.hold();
      final fallback = await PortHolder.hold();
      final session = rig.start(
        primaryPort: primary.port,
        fallbackPort: fallback.port,
      );

      final failure = await session.failure();

      expect(failure.message, contains('${primary.port}'));
      expect(failure.message, contains('${fallback.port}'));
      expect(primary.connections + fallback.connections, 0);
      expect(rig.launches, isEmpty);
    });
  });

  group('launcher', () {
    test('failing launcher still prints url and completes', () async {
      final session = rig.start(
        launcher: (url, environment) async {
          rig.launches.add(url);
          throw const ProcessException('xdg-open', [], 'not found', 2);
        },
      );

      final url = await session.url();
      await getPage(url);
      await session.success();

      expect(rig.launches, [url]);
      expect(_count(session.out.text, url), 1);
      expect(session.err.text, isNotEmpty, reason: 'a hint is printed');
      expect(session.err.text, isNot(contains(url)));
    });

    test('no-browser starts no launcher', () async {
      final session = rig.start(openBrowser: false);

      final url = await session.url();
      await getPage(url);
      await session.success();

      expect(rig.launches, isEmpty);
      expect(_count(session.out.text, url), 1);
    });
  });

  group('pasted redirect', () {
    test('pasted redirect url completes the login', () async {
      final lines = StreamController<String>();
      addTearDown(lines.close);
      final session = rig.start(
        openBrowser: false,
        paste: lines.stream,
        terminal: true,
      );

      final callback = await callbackUrlFor(await session.url());
      lines.add(callback);
      final result = await session.success();

      expect(result.subject, 'user-123');
      expect(rig.store.load()!.tokens, isNotNull);
      expect(await portIsFree(rig.primary), isTrue);
    });

    test('a callback arriving after a pasted redirect gets 409', () async {
      fake.tokenScripts.add(
        TokenScript.success(delay: const Duration(milliseconds: 600)),
      );
      final lines = StreamController<String>();
      addTearDown(lines.close);
      final session = rig.start(
        openBrowser: false,
        paste: lines.stream,
        terminal: true,
      );

      final callback = await callbackUrlFor(await session.url());
      lines.add(callback);
      while (fake.tokenRequests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      final (status, _) = await getPage(callback);

      expect(status, HttpStatus.conflict);
      await session.success();
      expect(fake.tokenRequests, hasLength(1));
    });

    test(
      'pasted url with another prefix is rejected and waiting continues',
      () async {
        final lines = StreamController<String>();
        addTearDown(lines.close);
        final session = rig.start(
          openBrowser: false,
          paste: lines.stream,
          terminal: true,
        );
        final callback = await callbackUrlFor(await session.url());
        final query = Uri.parse(callback).query;

        lines
          ..add('http://127.0.0.1:${rig.fallback}/auth/callback?$query')
          ..add('http://localhost:${rig.primary}/auth/callback?$query')
          ..add('http://127.0.0.1:${rig.primary}/other?$query')
          ..add('https://127.0.0.1:${rig.primary}/auth/callback?$query');
        await session.err.until((t) => _count(t, rig.redirectUri) >= 4);

        var finished = false;
        unawaited(session.outcome.then((_) => finished = true));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(finished, isFalse, reason: 'still waiting');
        expect(fake.tokenRequests, isEmpty);

        lines.add(callback);
        await session.success();
      },
    );

    test('rejected pasted url is not echoed', () async {
      final lines = StreamController<String>();
      addTearDown(lines.close);
      final cancel = CancelToken();
      final session = rig.start(
        openBrowser: false,
        paste: lines.stream,
        terminal: true,
        cancel: cancel,
      );
      await session.url();

      lines
        ..add(
          'http://127.0.0.1:${rig.fallback}/auth/callback'
          '?code=PASTEDCODE&state=PASTEDSTATE',
        )
        ..add('not a url PASTEDGARBAGE')
        ..add('x' * (openAiMaxPastedLineBytes + 1) + 'PASTEDOVERSIZE');
      await session.err.until((t) => _count(t, rig.redirectUri) >= 3);

      for (final sink in [session.out, session.err]) {
        expect(sink.text, isNot(contains('PASTED')));
        expect(sink.text, isNot(contains('code=')));
      }
      expect(fake.tokenRequests, isEmpty);

      // End the login; the message of the failure also carries no pasted text.
      lines.add('');
      cancel.cancel();
      final failure = await session.failure();
      expect(failure.message, isNot(contains('PASTED')));
    });

    test('pasted error equal to the received code does not print it', () async {
      final lines = StreamController<String>();
      addTearDown(lines.close);
      final session = rig.start(
        openBrowser: false,
        paste: lines.stream,
        terminal: true,
      );
      final callback = Uri.parse(await callbackUrlFor(await session.url()));
      final query = {...callback.queryParameters, 'code': 'code_abc'};
      query['error'] = 'code_abc';

      lines.add(callback.replace(queryParameters: query).toString());
      final failure = await session.failure();

      expect(failure.message, contains('authorization was not granted'));
      expect(failure.message, isNot(contains('code_abc')));
      expect(session.out.text, isNot(contains('code_abc')));
      expect(session.err.text, isNot(contains('code_abc')));
      expect(fake.tokenRequests, isEmpty);
    });

    test('standard input that is not a terminal is not read', () async {
      final lines = StreamController<String>();
      // Nothing listens, so `close` would never complete; do not await it.
      addTearDown(() => unawaited(lines.close()));
      final session = rig.start(
        openBrowser: false,
        paste: lines.stream,
        deadline: const Duration(milliseconds: 400),
      );
      final callback = await callbackUrlFor(await session.url());

      expect(lines.hasListener, isFalse);
      lines.add(callback);
      final failure = await session.failure();

      expect(failure.message, 'login timed out');
      expect(fake.tokenRequests, isEmpty);
    });
  });

  group('deadline and cancellation', () {
    test('deadline expiry releases port and stores nothing', () async {
      final seeded = loggedInRecord();
      rig.store.replace(seeded);
      final session = rig.start(
        openBrowser: false,
        deadline: const Duration(milliseconds: 300),
      );

      final failure = await session.failure();

      expect(failure.message, 'login timed out');
      expect(await portIsFree(rig.primary), isTrue);
      expect(rig.store.load(), seeded);
      expect(fake.tokenRequests, isEmpty);
    });

    test('cancel while waiting stores nothing', () async {
      final cancel = CancelToken();
      final session = rig.start(openBrowser: false, cancel: cancel);
      await session.url();

      cancel.cancel();
      final failure = await session.failure();

      expect(failure.message, 'login cancelled');
      expect(await portIsFree(rig.primary), isTrue);
      final record = rig.store.load()!;
      expect(record.registration, isNull);
      expect(record.tokens, isNull);
      expect(record.generation, 0);
    });

    test(
      'cancel during exchange, key fetch or lock wait never writes',
      () async {
        Future<void> expectUntouched(_Rig target) async {
          await Future<void>.delayed(const Duration(milliseconds: 250));
          final record = target.store.load()!;
          expect(record.registration, isNull);
          expect(record.tokens, isNull);
          expect(record.generation, 0);
        }

        // Exchange pending.
        var cancel = CancelToken();
        var target = await _Rig.create(fake);
        fake.tokenScripts.add(
          TokenScript.success(delay: const Duration(seconds: 30)),
        );
        var session = target.start(openBrowser: false, cancel: cancel);
        unawaited(getPage(await session.url()));
        while (fake.tokenRequests.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        cancel.cancel();
        expect((await session.failure()).message, 'login cancelled');
        await expectUntouched(target);

        // Key fetch pending: the key set URL points at a server that never
        // answers.
        final silent = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        addTearDown(() => silent.close(force: true));
        var silentRequests = 0;
        silent.listen((_) => silentRequests++);
        fake.discoveryOverrides['jwks_uri'] =
            'http://127.0.0.1:${silent.port}/jwks';
        cancel = CancelToken();
        target = await _Rig.create(fake);
        session = target.start(openBrowser: false, cancel: cancel);
        unawaited(getPage(await session.url()));
        while (silentRequests == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        cancel.cancel();
        expect((await session.failure()).message, 'login cancelled');
        await expectUntouched(target);
        fake.discoveryOverrides.clear();

        // Lock wait pending: another process holds auth.lock.
        cancel = CancelToken();
        target = await _Rig.create(fake);
        session = target.start(openBrowser: false, cancel: cancel);
        final url = await session.url();
        target.home.lockHeld = true;
        final jwksBefore = fake.jwksRequests.length;
        unawaited(getPage(url));
        while (fake.jwksRequests.length == jwksBefore) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        await Future<void>.delayed(const Duration(milliseconds: 150));
        cancel.cancel();
        expect((await session.failure()).message, 'login cancelled');
        target.home.lockHeld = false;
        await expectUntouched(target);
      },
    );

    test('cancel during commit completes and reports success', () async {
      final backend = HookedBackend();
      final home = TestHome(backend: backend);
      final target = await _Rig.create(fake, home: home);
      final cancel = CancelToken();
      backend.onWrite = (plaintext) {
        if (plaintext.contains('"tokens"')) cancel.cancel();
      };
      final session = target.start(cancel: cancel);

      final result = await session.success();

      expect(cancel.isCancelled, isTrue, reason: 'tripped during the replace');
      expect(result.email, 'user@example.com');
      final record = home.store.load()!;
      expect(record.tokens, isNotNull);
      expect(record.registration!.subject, 'user-123');
    });

    test('Ctrl-C during the wait cancels the login', () async {
      final interrupts = StreamController<Object?>();
      addTearDown(interrupts.close);
      final controller = LoginController(interrupts: interrupts.stream);
      addTearDown(controller.dispose);

      interrupts.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(controller.token.isCancelled, isTrue);
      expect(controller.timedOut, isFalse);
      expect(controller.cancellation().message, 'login cancelled');
    });

    test('a trip after the commit began is ignored by the controller', () {
      final controller = LoginController();
      addTearDown(controller.dispose);

      final value = controller.commit(() {
        controller.token.cancel();
        return 42;
      });

      expect(value, 42);
      expect(controller.committed, isTrue);
      expect(controller.isCancelled, isFalse);
      controller.checkpoint();
    });

    test('a trip before the commit means the replace is never called', () {
      final controller = LoginController();
      addTearDown(controller.dispose);
      controller.token.cancel();
      var replaced = false;

      expect(
        () => controller.commit(() => replaced = true),
        throwsA(isA<LoginFailure>()),
      );
      expect(replaced, isFalse);
    });
  });
}
