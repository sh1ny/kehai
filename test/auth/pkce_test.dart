import 'package:kehai/src/auth/pkce.dart';
import 'package:test/test.dart';

void main() {
  final alphabet = RegExp(r'^[A-Za-z0-9_-]+$');

  test('S256 challenge matches the RFC 7636 Appendix B vector', () {
    expect(
      PkcePair.challengeFor('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
      'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
    );
  });

  test('verifier is 86 base64url characters and matches its challenge', () {
    final pair = PkcePair.generate();
    expect(pair.verifier, hasLength(86));
    expect(pair.verifier, matches(alphabet));
    expect(pair.challenge, hasLength(43));
    expect(pair.challenge, matches(alphabet));
    expect(pair.challenge, PkcePair.challengeFor(pair.verifier));
    expect(PkcePair.generate().verifier, isNot(pair.verifier));
  });

  test('state and nonce are 43 base64url characters and differ per call', () {
    final values = {
      generateState(),
      generateState(),
      generateNonce(),
      generateNonce(),
    };
    expect(values, hasLength(4));
    for (final value in values) {
      expect(value, hasLength(43));
      expect(value, matches(alphabet));
    }
  });
}
