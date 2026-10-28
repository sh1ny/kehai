import 'dart:async';
import 'dart:io';

import 'package:kehai/src/auth/auth_error.dart';
import 'package:kehai/src/auth/jwt.dart';
import 'package:kehai/src/auth/oidc.dart';
import 'package:test/test.dart';

import '../support/fake_openai.dart';

void main() {
  late FakeOpenAi fake;
  late OidcClient oidc;

  setUp(() async {
    fake = await FakeOpenAi.start();
    oidc = OidcClient(fake.issuer);
  });

  Future<void> expectDiscoveryFails(String why) => expectLater(
    oidc.discover(),
    throwsA(
      isA<AuthError>()
          .having((e) => e.reason, 'reason', discoveryFailedReason)
          .having((e) => e.detail, 'detail', contains(why)),
    ),
  );

  test(
    'discovery then key fetch yields keys that verify a signed token',
    () async {
      final discovery = await oidc.discover();
      expect(discovery.issuer, fake.issuer);
      expect(discovery.jwksUri.toString(), fake.jwksUri);
      expect(discovery.revocationEndpoint.toString(), fake.revocationEndpoint);

      final keys = await oidc.fetchKeys(discovery.jwksUri);
      final token = fake.signIdToken(nonce: 'n1');
      final identity = verifyIdToken(
        token,
        keys: keys,
        issuer: fake.issuer,
        clientId: fake.issuedClientId,
        nonce: 'n1',
      );
      expect(identity.subject, fake.subject);
      // Keys are fetched per call, never cached.
      await oidc.fetchKeys(discovery.jwksUri);
      expect(fake.jwksRequests, hasLength(2));
    },
  );

  test('discovery rejects a different issuer', () async {
    fake.discoveryOverrides['issuer'] = 'https://evil.example';
    await expectDiscoveryFails('issuer');
  });

  test('discovery rejects endpoints off the issuer host', () async {
    fake.discoveryOverrides['jwks_uri'] = 'https://evil.example/jwks.json';
    await expectDiscoveryFails('jwks_uri');
    fake.discoveryOverrides.remove('jwks_uri');
    fake.discoveryOverrides['revocation_endpoint'] =
        'https://evil.example/revoke';
    await expectDiscoveryFails('revocation_endpoint');
    fake.discoveryOverrides['revocation_endpoint'] = null;
    await expectDiscoveryFails('revocation_endpoint');
    fake.discoveryOverrides.remove('revocation_endpoint');
    fake.discoveryOverrides['jwks_uri'] = null;
    await expectDiscoveryFails('jwks_uri');
  });

  test('discovery and key fetch fail on status and oversized bodies', () async {
    fake.discoveryStatus = 500;
    await expectDiscoveryFails('HTTP 500');
    fake.discoveryStatus = 200;
    fake.discoveryOverrides['padding'] = 'x' * (64 * 1024);
    await expectDiscoveryFails('larger than the limit');
    fake.discoveryOverrides.remove('padding');

    fake.jwksStatus = 503;
    await expectLater(
      oidc.fetchKeys(Uri.parse(fake.jwksUri)),
      throwsA(
        isA<AuthError>().having(
          (e) => e.reason,
          'reason',
          keyFetchFailedReason,
        ),
      ),
    );
  });

  test('the cancel signal aborts an in-flight request', () async {
    // A server that accepts the connection and never answers.
    final silent = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => silent.close());
    final accepted = Completer<void>();
    final sockets = <Socket>[];
    silent.listen((socket) {
      sockets.add(socket);
      if (!accepted.isCompleted) accepted.complete();
    });
    addTearDown(() {
      for (final socket in sockets) {
        socket.destroy();
      }
    });
    final signal = Completer<void>();
    final cancellable = OidcClient(
      'http://127.0.0.1:${silent.port}',
      cancelled: signal.future,
    );
    final result = cancellable.discover();
    final expectation = expectLater(
      result,
      throwsA(
        isA<AuthError>().having((e) => e.reason, 'reason', authCancelledReason),
      ),
    );
    await accepted.future;
    signal.complete();
    await expectation;
  });
}
