import 'dart:io';

import 'package:kehai/src/auth/auth_failure.dart';
import 'package:kehai/src/auth/failure_text.dart';
import 'package:kehai/src/auth/oauth_client.dart';
import 'package:kehai/src/auth/openai_constants.dart';
import 'package:test/test.dart';

import '../support/fake_openai.dart';

Map<String, Object?> _body({
  Set<String> omit = const {},
  Object? expires = 60,
}) => {
  'access_token': 'at',
  'refresh_token': 'rt',
  'id_token': 'it',
  'expires_in': expires,
  'scope': 'openid chatgpt.tokens.use.direct',
}..removeWhere((k, _) => omit.contains(k));

Matcher _protocolNaming(String field) => isA<AuthFailure>()
    .having((f) => f.kind, 'kind', FailureKind.protocol)
    .having((f) => f.message, 'message', contains(field));

void main() {
  late FakeOpenAi fake;
  late OAuthClient client;

  setUp(() async {
    fake = await FakeOpenAi.start();
    client = OAuthClient(fake.issuer);
  });

  Future<TokenGrant> exchange() => client.exchangeCode(
    clientId: 'client-xyz',
    code: 'the-code',
    codeVerifier: 'the-verifier',
    redirectUri: 'http://127.0.0.1:1455/auth/callback',
  );

  group('exchangeCode', () {
    test('sends the form without a secret and parses all fields', () async {
      fake.tokenScripts.add(TokenScript.json(200, _body()));
      final grant = await exchange();
      expect(fake.tokenRequests.single.form, {
        'grant_type': 'authorization_code',
        'client_id': 'client-xyz',
        'code': 'the-code',
        'code_verifier': 'the-verifier',
        'redirect_uri': 'http://127.0.0.1:1455/auth/callback',
        'resource': openAiResource,
      });
      expect(grant.accessToken, 'at');
      expect(grant.refreshToken, 'rt');
      expect(grant.idToken, 'it');
      expect(grant.expiresIn, const Duration(seconds: 60));
      expect(grant.scopes, contains(openAiPlanUsageScope));
    });

    for (final field in [
      'access_token',
      'refresh_token',
      'id_token',
      'scope',
    ]) {
      test('a response without $field names it', () async {
        fake.tokenScripts.add(TokenScript.json(200, _body(omit: {field})));
        await expectLater(exchange(), throwsA(_protocolNaming('"$field"')));
      });
    }

    test('a non-positive expires_in is rejected', () async {
      fake.tokenScripts.add(TokenScript.json(200, _body(expires: 0)));
      await expectLater(exchange(), throwsA(_protocolNaming('expires_in')));
    });

    test('a rejected code is a token exchange failure with its code', () async {
      fake.tokenScripts.add(TokenScript.error(400, 'invalid_grant'));
      await expectLater(
        exchange(),
        throwsA(
          isA<AuthFailure>()
              .having((f) => f.kind, 'kind', FailureKind.tokenExchange)
              .having((f) => f.code, 'code', 'invalid_grant')
              .having((f) => f.status, 'status', 400),
        ),
      );
    });
  });

  group('bounds', () {
    test('a response over 64 KiB is invalid_request', () async {
      fake.tokenScripts.add(
        TokenScript.json(200, {
          ..._body(),
          'padding': 'x' * (openAiMaxAuthBodyBytes + 1),
        }),
      );
      await expectLater(
        exchange(),
        throwsA(
          isA<AuthFailure>()
              .having((f) => f.kind, 'kind', FailureKind.invalidRequest)
              .having((f) => f.message, 'message', contains('exceeds 64 KiB')),
        ),
      );
    });

    test('a request with no response in time is sent and uncertain', () async {
      fake.tokenScripts.add(
        TokenScript.success(delay: const Duration(seconds: 5)),
      );
      final slow = OAuthClient(
        fake.issuer,
        timeout: const Duration(milliseconds: 300),
      );
      await expectLater(
        slow.refresh(clientId: 'c', refreshToken: 'r'),
        throwsA(
          isA<AuthFailure>()
              .having((f) => f.kind, 'kind', FailureKind.network)
              .having((f) => f.sent, 'sent', isTrue)
              .having((f) => f.rotationUncertain, 'rotation', isTrue),
        ),
      );
    });
  });

  group('revoke', () {
    Future<RevocationResult> revoke() => client.revoke(
      Uri.parse(fake.revocationEndpoint),
      refreshToken: 'rt',
      clientId: 'client-xyz',
    );

    test('an empty 200 is confirmed and the form is sent', () async {
      final result = await revoke();
      expect(result.confirmed, isTrue);
      expect(fake.revocationRequests.single.form, {
        'token': 'rt',
        'token_type_hint': 'refresh_token',
        'client_id': 'client-xyz',
      });
    });

    test('other outcomes are unconfirmed and never throw', () async {
      fake.revocationScripts
        ..add(const RevocationScript(status: 503))
        ..add(const RevocationScript(body: '{"ok":true}'))
        ..add(const RevocationScript(drop: true));
      final first = await revoke();
      expect((first.confirmed, first.status), (false, 503));
      expect((await revoke()).confirmed, isFalse);
      final dropped = await revoke();
      expect((dropped.confirmed, dropped.status), (false, null));
    });
  });

  group('oversized responses stop at the limit', () {
    late HttpServer server;
    final held = <HttpResponse>[];

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        await request.drain<void>();
        final response = request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..add(List.filled(openAiMaxAuthBodyBytes + 4096, 0x20));
        await response.flush();
        // The response stays open: only the client can end the wait.
        held.add(response);
      });
    });

    tearDown(() async {
      await server.close(force: true);
      held.clear();
    });

    OAuthClient slow() => OAuthClient(
      'http://127.0.0.1:${server.port}',
      timeout: const Duration(seconds: 20),
    );

    test('exchangeCode fails as oversized well before the timeout', () async {
      final watch = Stopwatch()..start();
      await expectLater(
        slow().exchangeCode(
          clientId: 'client-xyz',
          code: 'the-code',
          codeVerifier: 'the-verifier',
          redirectUri: 'http://127.0.0.1:1455/auth/callback',
        ),
        throwsA(
          isA<AuthFailure>()
              .having((f) => f.kind, 'kind', FailureKind.invalidRequest)
              .having((f) => f.message, 'message', contains('64 KiB')),
        ),
      );
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('revoke reports the status of an oversized reply at once', () async {
      final watch = Stopwatch()..start();
      final result = await slow().revoke(
        Uri.parse('http://127.0.0.1:${server.port}/revoke'),
        refreshToken: 'rt',
        clientId: 'client-xyz',
      );
      expect((result.confirmed, result.status), (false, 200));
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    });
  });
}
