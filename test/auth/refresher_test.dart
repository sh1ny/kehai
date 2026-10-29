import 'dart:io';

import 'package:kehai/src/auth/auth_failure.dart';
import 'package:kehai/src/auth/credential_error.dart';
import 'package:kehai/src/auth/credential_store.dart';
import 'package:kehai/src/auth/failure_text.dart';
import 'package:kehai/src/auth/openai_constants.dart';
import 'package:kehai/src/auth/refresher.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_openai.dart';

const _hostId = 'urn:uuid:11111111-2222-3333-4444-555555555555';

CredentialRegistration _registration({
  String subject = 'user-123',
  bool planUsage = true,
}) => CredentialRegistration(
  issuer: 'https://auth.openai.com',
  clientId: 'client-xyz',
  subject: subject,
  email: '$subject@example.com',
  plan: 'plus',
  planUsageEnabled: planUsage,
);

/// A record whose access token expires in [expiresIn] from now.
CredentialRecord _record({
  String access = 'old-access',
  String refresh = 'old-refresh',
  Duration expiresIn = const Duration(minutes: 2),
  int generation = 7,
  String subject = 'user-123',
}) {
  final now = DateTime.now().toUtc();
  return CredentialRecord(
    hostId: _hostId,
    generation: generation,
    registration: _registration(subject: subject),
    tokens: CredentialTokens(
      idToken: 'old-id-token',
      accessToken: access,
      refreshToken: refresh,
      expiresAt: now.add(expiresIn),
      scopes: const ['openid', 'offline_access', openAiPlanUsageScope],
      savedAt: now.subtract(const Duration(days: 1)),
      lastRefresh: now.subtract(const Duration(hours: 1)),
    ),
  );
}

Matcher _failure(FailureKind kind, {String? message, int? status}) =>
    isA<AuthFailure>()
        .having((f) => f.kind, 'kind', kind)
        .having((f) => f.message, 'message', contains(message ?? ''))
        .having((f) => f.status, 'status', status ?? anything);

void main() {
  late Directory tmp;
  late CredentialStore store;
  late FakeOpenAi fake;
  late Refresher refresher;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('kehai_refresh_');
    if (!Platform.isWindows) Process.runSync('chmod', ['700', tmp.path]);
    store = CredentialStore(home: p.join(tmp.path, 'home'));
    fake = await FakeOpenAi.start();
    refresher = Refresher(store: store, issuer: fake.issuer);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('proactive refresh', () {
    test('token expiring within 5 minutes is refreshed first with form and '
        'resource', () async {
      store.replace(_record());
      final before = DateTime.now().toUtc();

      final credentials = await refresher.credentials();

      expect(fake.tokenRequests, hasLength(1));
      final request = fake.tokenRequests.single;
      expect(request.method, 'POST');
      expect(request.headers['content-type'], contains('form-urlencoded'));
      expect(request.form, {
        'grant_type': 'refresh_token',
        'refresh_token': 'old-refresh',
        'client_id': 'client-xyz',
        'resource': openAiResource,
      });
      expect(credentials.accessToken, 'access-1');
      final stored = store.load()!.tokens!;
      expect(stored.accessToken, 'access-1');
      expect(stored.refreshToken, 'refresh-1');
      expect(
        stored.expiresAt.difference(before),
        greaterThan(const Duration(minutes: 59)),
      );
      expect(stored.lastRefresh.isAfter(before), isTrue);
    });

    test('a token not yet due is used without a request', () async {
      store.replace(_record(expiresIn: const Duration(minutes: 30)));
      final credentials = await refresher.credentials();
      expect(credentials.accessToken, 'old-access');
      expect(fake.tokenRequests, isEmpty);
    });

    test('omitted refresh token keeps the previous one', () async {
      store.replace(_record());
      fake.tokenScripts.add(TokenScript.success(omit: {'refresh_token'}));

      await refresher.credentials();

      final stored = store.load()!.tokens!;
      expect(stored.accessToken, 'access-1');
      expect(stored.refreshToken, 'old-refresh');
    });

    test('refresh leaves generation unchanged', () async {
      store.replace(_record(generation: 7));
      await refresher.credentials();
      expect(store.load()!.generation, 7);
    });
  });

  group('transient failures', () {
    test(
      'unsent or 5xx refresh leaves credentials and is not reauth',
      () async {
        final record = _record();
        store.replace(record);
        final closedIssuer = fake.issuer;
        await fake.close();
        final unsent = Refresher(store: store, issuer: closedIssuer);
        await expectLater(
          unsent.credentials(),
          throwsA(
            isA<AuthFailure>()
                .having((f) => f.kind, 'kind', FailureKind.network)
                .having((f) => f.sent, 'sent', isFalse)
                .having((f) => f.rotationUncertain, 'rotation', isFalse),
          ),
        );
        expect(store.load(), record);

        final live = await FakeOpenAi.start();
        live.tokenScripts.add(TokenScript.error(503, 'service_unavailable'));
        await expectLater(
          Refresher(store: store, issuer: live.issuer).credentials(),
          throwsA(_failure(FailureKind.server, status: 503)),
        );
        expect(store.load(), record);
      },
    );

    test('sent refresh without response is rotation uncertain', () async {
      final record = _record();
      store.replace(record);
      fake.tokenScripts.add(TokenScript.drop());

      await expectLater(
        refresher.credentials(),
        throwsA(
          isA<AuthFailure>()
              .having((f) => f.kind, 'kind', FailureKind.network)
              .having((f) => f.sent, 'sent', isTrue)
              .having((f) => f.rotationUncertain, 'rotation', isTrue),
        ),
      );
      expect(fake.tokenRequests, hasLength(1), reason: 'no second refresh');
      expect(store.load(), record);
    });

    test('reused after uncertain rotation is reauth with lost-rotation '
        'message', () async {
      store.replace(_record());
      fake.tokenScripts
        ..add(TokenScript.drop())
        ..add(TokenScript.error(400, 'refresh_token_reused'));

      await expectLater(
        refresher.credentials(),
        throwsA(
          isA<AuthFailure>().having(
            (f) => f.rotationUncertain,
            'rotation',
            isTrue,
          ),
        ),
      );
      await expectLater(
        refresher.credentials(),
        throwsA(
          isA<AuthFailure>()
              .having((f) => f.kind, 'kind', FailureKind.reauthRequired)
              .having((f) => f.rotationUncertain, 'rotation', isFalse)
              .having((f) => f.message, 'message', contains('earlier refresh'))
              .having(
                (f) => f.message,
                'message',
                contains('kehai login openai'),
              ),
        ),
      );
    });

    test(
      'a busy credential lock is a network failure and sends nothing',
      () async {
        store.replace(_record());
        final busy = CredentialStore(
          home: store.home,
          lockDeadline: const Duration(milliseconds: 150),
          lockPollInterval: const Duration(milliseconds: 20),
          tryLock: (_) => false,
        );
        await expectLater(
          Refresher(store: busy, issuer: fake.issuer).credentials(),
          throwsA(
            _failure(FailureKind.network, message: 'Credential lock busy'),
          ),
        );
        expect(fake.tokenRequests, isEmpty);
        expect(CredentialStoreError.lockBusy, 'credential lock busy');
      },
    );
  });

  group('credentials per request', () {
    test(
      'request after external logout fails reauth without backend call',
      () async {
        final record = _record(expiresIn: const Duration(hours: 1));
        store.replace(record);
        expect((await refresher.credentials()).accessToken, 'old-access');

        store.replace(
          CredentialRecord(
            hostId: _hostId,
            generation: 8,
            registration: record.registration,
          ),
        );

        await expectLater(
          refresher.credentials(),
          throwsA(
            _failure(FailureKind.reauthRequired, message: 'kehai login openai'),
          ),
        );
        expect(fake.tokenRequests, isEmpty);
        expect(fake.requests, isEmpty);
      },
    );

    test('tokenless record with plan usage disabled is not_permitted without '
        'backend call', () async {
      store.replace(
        CredentialRecord(
          hostId: _hostId,
          generation: 8,
          registration: _registration(planUsage: false),
        ),
      );
      await expectLater(
        refresher.credentials(),
        throwsA(
          _failure(
            FailureKind.notPermitted,
            message: 'kehai login openai --enable-plan-usage',
          ),
        ),
      );
      expect(fake.requests, isEmpty);
    });

    test('a missing record is reauth without backend call', () async {
      await expectLater(
        refresher.credentials(),
        throwsA(_failure(FailureKind.reauthRequired)),
      );
      expect(fake.requests, isEmpty);
    });

    test('request after account replacement uses the new account', () async {
      store.replace(_record(expiresIn: const Duration(hours: 1)));
      expect((await refresher.credentials()).registration.subject, 'user-123');

      store.replace(
        _record(
          access: 'b-access',
          subject: 'user-456',
          expiresIn: const Duration(hours: 1),
          generation: 9,
        ),
      );

      final credentials = await refresher.credentials();
      expect(credentials.accessToken, 'b-access');
      expect(credentials.registration.subject, 'user-456');
      expect(credentials.generation, 9);
      expect(fake.tokenRequests, isEmpty);
    });
  });

  group('single flight', () {
    test('five parallel callers share one refresh', () async {
      store.replace(_record(expiresIn: const Duration(minutes: -1)));
      fake.tokenScripts.add(
        TokenScript.success(delay: const Duration(milliseconds: 100)),
      );

      final results = await Future.wait([
        for (var i = 0; i < 5; i++) refresher.credentials(),
      ]);

      expect(fake.tokenRequests, hasLength(1));
      expect(results.map((c) => c.accessToken).toSet(), {'access-1'});
    });

    test('shared failure reaches all waiters and is not cached', () async {
      store.replace(_record(expiresIn: const Duration(minutes: -1)));
      fake.tokenScripts.add(TokenScript.error(503, 'unavailable'));

      final outcomes = await Future.wait([
        for (var i = 0; i < 5; i++)
          refresher.credentials().then<Object>(
            (c) => c,
            onError: (Object e) => e,
          ),
      ]);

      expect(fake.tokenRequests, hasLength(1));
      expect(outcomes.every((o) => o is AuthFailure), isTrue);
      expect(outcomes.toSet(), hasLength(1), reason: 'the same failure');
      expect((outcomes.first as AuthFailure).kind, FailureKind.server);

      final sixth = await refresher.credentials();
      expect(fake.tokenRequests, hasLength(2));
      expect(sixth.accessToken, 'access-1');
    });
  });

  group('forced refresh after unauthorized', () {
    test(
      'refreshes a token that is not due when it is still the stale one',
      () async {
        store.replace(_record(expiresIn: const Duration(hours: 1)));
        final credentials = await refresher.refreshAfterUnauthorized(
          'old-access',
        );
        expect(fake.tokenRequests, hasLength(1));
        expect(credentials.accessToken, 'access-1');
      },
    );

    test('uses a token another refresher stored without refreshing', () async {
      store.replace(
        _record(access: 'newer', expiresIn: const Duration(hours: 1)),
      );
      final credentials = await refresher.refreshAfterUnauthorized(
        'old-access',
      );
      expect(credentials.accessToken, 'newer');
      expect(fake.tokenRequests, isEmpty);
    });
  });

  group('terminal and configuration errors', () {
    test(
      'refresh_token_reused is reauth, clears tokens and does not retry',
      () async {
        store.replace(_record());
        fake.tokenScripts.add(TokenScript.error(400, 'refresh_token_reused'));

        await expectLater(
          refresher.credentials(),
          throwsA(
            isA<AuthFailure>()
                .having((f) => f.kind, 'kind', FailureKind.reauthRequired)
                .having((f) => f.message, 'message', contains('already used'))
                .having(
                  (f) => f.message,
                  'message',
                  contains('kehai login openai'),
                ),
          ),
        );
        expect(fake.tokenRequests, hasLength(1));
        final stored = store.load()!;
        expect(stored.tokens, isNull);
        expect(stored.registration, _registration());
        expect(stored.hostId, _hostId);
        expect(stored.generation, 7);

        await expectLater(
          refresher.credentials(),
          throwsA(_failure(FailureKind.reauthRequired)),
        );
        expect(fake.tokenRequests, hasLength(1), reason: 'not retried');
      },
    );

    test('a 401 refresh is terminal', () async {
      store.replace(_record());
      fake.tokenScripts.add(TokenScript.raw(401, 'nope'));
      await expectLater(
        refresher.credentials(),
        throwsA(
          _failure(
            FailureKind.reauthRequired,
            message: 'kehai login openai',
            status: 401,
          ),
        ),
      );
      expect(store.load()!.tokens, isNull);
    });

    test('terminal failure keeps a token set stored meanwhile', () async {
      store.replace(_record());
      fake.tokenScripts.add(
        TokenScript.error(
          400,
          'invalid_grant',
          delay: const Duration(milliseconds: 400),
        ),
      );

      final outcome = refresher.credentials().then<Object>(
        (c) => c,
        onError: (Object e) => e,
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));
      store.replace(
        _record(
          access: 'new-access',
          refresh: 'new-refresh',
          expiresIn: const Duration(hours: 1),
          generation: 8,
        ),
      );

      expect(await outcome, isA<AuthFailure>());
      final stored = store.load()!;
      expect(stored.tokens!.refreshToken, 'new-refresh');
      expect(stored.generation, 8);
      final next = await refresher.credentials();
      expect(next.accessToken, 'new-access');
      expect(fake.tokenRequests, hasLength(1));
    });

    test('invalid_client is invalid_request naming logout --forget', () async {
      final record = _record();
      store.replace(record);
      fake.tokenScripts
        ..add(TokenScript.error(400, 'invalid_client'))
        ..add(TokenScript.error(401, 'invalid_client'));

      for (var i = 0; i < 2; i++) {
        await expectLater(
          refresher.credentials(),
          throwsA(
            isA<AuthFailure>()
                .having((f) => f.kind, 'kind', FailureKind.invalidRequest)
                .having(
                  (f) => f.message,
                  'message',
                  contains('kehai logout openai --forget'),
                ),
          ),
        );
      }
      expect(store.load(), record);
    });

    test('unknown 400 code is invalid_request', () async {
      final record = _record();
      store.replace(record);
      fake.tokenScripts.add(TokenScript.error(400, 'weird_thing'));

      await expectLater(
        refresher.credentials(),
        throwsA(
          isA<AuthFailure>()
              .having((f) => f.kind, 'kind', FailureKind.invalidRequest)
              .having((f) => f.code, 'code', 'weird_thing')
              .having((f) => f.message, 'message', contains('weird_thing'))
              .having(
                (f) => f.message,
                'message',
                isNot(contains('kehai login openai')),
              ),
        ),
      );
      expect(store.load(), record);
    });

    test('refresh without direct scope is not_permitted, clears tokens, '
        'disables plan usage', () async {
      store.replace(_record());
      fake.tokenScripts.add(
        TokenScript.success(scope: 'openid profile email offline_access'),
      );

      await expectLater(
        refresher.credentials(),
        throwsA(
          isA<AuthFailure>()
              .having((f) => f.kind, 'kind', FailureKind.notPermitted)
              .having(
                (f) => f.message,
                'message',
                contains('no longer granted'),
              )
              .having(
                (f) => f.message,
                'message',
                contains('kehai login openai --enable-plan-usage'),
              ),
        ),
      );
      final stored = store.load()!;
      expect(stored.tokens, isNull);
      expect(stored.registration!.planUsageEnabled, isFalse);
      expect(stored.registration!.clientId, 'client-xyz');
      expect(stored.hostId, _hostId);

      await expectLater(
        refresher.credentials(),
        throwsA(_failure(FailureKind.notPermitted)),
      );
      expect(fake.tokenRequests, hasLength(1));
    });
  });
}
