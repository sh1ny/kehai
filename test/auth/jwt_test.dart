import 'package:kehai/src/auth/auth_error.dart';
import 'package:kehai/src/auth/jwt.dart';
import 'package:test/test.dart';

import '../support/fake_openai.dart';

const _nonce = 'nonce-abc';
const _clientId = 'oaiapp_fake';

void main() {
  late FakeOpenAi fake;

  setUp(() async {
    fake = await FakeOpenAi.start();
  });

  VerifiedIdToken verify(
    String token, {
    List<Object?>? keys,
    String? nonce,
    DateTime? now,
  }) => verifyIdToken(
    token,
    keys: keys ?? fake.jwks,
    issuer: fake.issuer,
    clientId: _clientId,
    nonce: nonce ?? _nonce,
    now: now,
  );

  /// Asserts that verifying [token] fails with the check named [check] and
  /// that the failure text does not contain the token.
  void expectFails(
    String token,
    String check, {
    List<Object?>? keys,
    DateTime? now,
  }) {
    try {
      verify(token, keys: keys, now: now);
      fail('expected the "$check" check to fail');
    } on AuthError catch (error) {
      expect(error.reason, 'invalid ID token');
      expect(error.detail, startsWith('$check:'), reason: error.message);
      expect(error.message, isNot(contains(token)));
      for (final part in token.split('.')) {
        if (part.length > 8) expect(error.message, isNot(contains(part)));
      }
    }
  }

  test('rs256 token with expected claims verifies and yields subject and '
      'email', () {
    final token = fake.signIdToken(
      nonce: _nonce,
      sub: 'user-42',
      email: 'me@example.com',
      planType: 'plus',
    );
    final identity = verify(token);
    expect(identity.subject, 'user-42');
    expect(identity.email, 'me@example.com');
    expect(identity.planType, 'plus');

    // aud may be an array containing the client id; plan may be absent.
    final multi = fake.signIdToken(
      nonce: _nonce,
      aud: ['other', _clientId],
      planType: null,
    );
    expect(verify(multi).planType, isNull);
  });

  test('bad signature, alg, iss, aud, exp or nonce each fail naming the '
      'check', () {
    final wrong = FakeRsaKey.generate(kid: 'fake-key-1');
    expectFails(fake.signIdToken(nonce: _nonce, wrongKey: wrong), 'signature');
    final tampered = fake.signIdToken(nonce: _nonce).split('.');
    tampered[1] = fake
        .signIdToken(nonce: _nonce, sub: 'someone-else')
        .split('.')[1];
    expectFails(tampered.join('.'), 'signature');

    expectFails(fake.signIdToken(nonce: _nonce, alg: 'none'), 'alg');
    expectFails(fake.signIdToken(nonce: _nonce, alg: 'HS256'), 'alg');
    expectFails(
      fake.signIdToken(nonce: _nonce, iss: 'https://evil.example'),
      'iss',
    );
    expectFails(fake.signIdToken(nonce: _nonce, aud: 'someone-else'), 'aud');
    expectFails(fake.signIdToken(nonce: _nonce, aud: ['a', 'b']), 'aud');
    expectFails(
      fake.signIdToken(
        nonce: _nonce,
        exp: DateTime.now().toUtc().subtract(const Duration(minutes: 5)),
      ),
      'exp',
    );
    expectFails(fake.signIdToken(nonce: 'other-nonce'), 'nonce');
    expectFails(fake.signIdToken(), 'nonce');
    expectFails(fake.signIdToken(nonce: _nonce, sub: ''), 'sub');
    expectFails(fake.signIdToken(nonce: _nonce, omit: {'sub'}), 'sub');
    expectFails(fake.signIdToken(nonce: _nonce, omit: {'exp'}), 'exp');
    expectFails('not-a-jwt', 'format');
    expectFails('a.b.c', 'format');
  });

  test('exp allows 60 seconds of skew', () {
    final now = DateTime.now().toUtc();
    final within = fake.signIdToken(
      nonce: _nonce,
      exp: now.subtract(const Duration(seconds: 30)),
    );
    expect(verify(within, now: now).subject, isNotEmpty);
    final beyond = fake.signIdToken(
      nonce: _nonce,
      exp: now.subtract(const Duration(seconds: 90)),
    );
    expectFails(beyond, 'exp', now: now);
  });

  test('key is selected by kid and must be an RS256-capable RSA key', () {
    final other = FakeRsaKey.generate(kid: 'other-kid');
    final keys = [other.jwk, fake.key.jwk];

    // The kid selects the right key regardless of order.
    expect(
      verify(fake.signIdToken(nonce: _nonce), keys: keys).subject,
      isNotEmpty,
    );
    expect(
      verify(
        fake.signIdToken(nonce: _nonce, wrongKey: other),
        keys: keys,
      ).subject,
      isNotEmpty,
    );

    // An unknown kid fails; so does a token signed by key A under key B's kid.
    expectFails(fake.signIdToken(nonce: _nonce, kid: 'missing'), 'kid');
    expectFails(
      fake.signIdToken(nonce: _nonce, wrongKey: other, kid: fake.key.kid),
      'signature',
      keys: keys,
    );

    // Key shape: kty must be RSA, alg absent or RS256.
    final base = fake.key.jwk;
    final token = fake.signIdToken(nonce: _nonce);
    expectFails(
      token,
      'key',
      keys: [
        {...base, 'kty': 'EC'},
      ],
    );
    expectFails(
      token,
      'key',
      keys: [
        {...base, 'alg': 'RS512'},
      ],
    );
    expect(
      verify(
        token,
        keys: [
          {...base}..remove('alg'),
        ],
      ).subject,
      isNotEmpty,
    );
  });
}
