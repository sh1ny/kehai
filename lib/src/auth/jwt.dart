/// ID-token decoding and RS256 verification (design D3b).
///
/// [verifyIdToken] runs steps 3 to 6 of D3b against an already fetched key
/// set: the header `alg` must be `RS256`, the key is chosen by `kid`, the
/// RSASSA-PKCS1-v1_5 SHA-256 signature is checked through `pointycastle`, and
/// the `iss`, `aud`, `exp`, `nonce` and `sub` claims are checked. Every
/// failure is an [AuthError] with reason `invalid ID token` whose detail
/// starts with the failed check name and never contains the token.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'auth_error.dart';
import 'openai_constants.dart';

/// The stable [AuthError.reason] of every verification failure.
const String invalidIdTokenReason = 'invalid ID token';

/// The ID-token claim that holds the OpenAI auth object.
const String _authClaim = 'https://api.openai.com/auth';

const String _sha256RsaOid = '0609608648016503040201';

/// The verified identity of an ID token.
final class VerifiedIdToken {
  /// Creates an identity.
  const VerifiedIdToken({required this.subject, this.email, this.planType});

  /// The `sub` claim.
  final String subject;

  /// The display-only `email` claim, if present.
  final String? email;

  /// The ChatGPT plan type, or `null` when the token does not carry one.
  final String? planType;
}

AuthError _fail(String check, String why) =>
    AuthError(invalidIdTokenReason, '$check: $why');

Uint8List _decodeBase64Url(String part, String what) {
  try {
    return base64Url.decode(base64Url.normalize(part));
  } on FormatException {
    throw _fail('format', '$what is not base64url');
  }
}

Map<String, Object?> _decodeObject(String part, String what) {
  final Object? decoded;
  try {
    decoded = jsonDecode(utf8.decode(_decodeBase64Url(part, what)));
  } on FormatException {
    throw _fail('format', '$what is not JSON');
  }
  if (decoded is! Map<String, Object?>) {
    throw _fail('format', '$what is not an object');
  }
  return decoded;
}

BigInt _bigIntOf(Object? value, String name) {
  if (value is! String || value.isEmpty) {
    throw _fail('key', 'RSA key has no "$name"');
  }
  final bytes = _decodeBase64Url(value, 'RSA key "$name"');
  var result = BigInt.zero;
  for (final byte in bytes) {
    result = (result << 8) | BigInt.from(byte);
  }
  return result;
}

/// Verifies [token] against the JWKS [keys] and returns its identity.
///
/// [issuer] and [clientId] are the expected `iss` and `aud` (which may also
/// be an array containing [clientId]); [nonce] is the value sent at authorize.
/// [now] defaults to the current time and exists for tests. Throws an
/// [AuthError] naming the failed check: `format`, `alg`, `kid`, `key`,
/// `signature`, `iss`, `aud`, `exp`, `nonce` or `sub`.
VerifiedIdToken verifyIdToken(
  String token, {
  required List<Object?> keys,
  required String issuer,
  required String clientId,
  required String nonce,
  DateTime? now,
}) {
  final parts = token.split('.');
  if (parts.length != 3) throw _fail('format', 'expected three parts');
  final header = _decodeObject(parts[0], 'header');
  final payload = _decodeObject(parts[1], 'payload');

  if (header['alg'] != 'RS256') {
    throw _fail('alg', 'the algorithm must be RS256');
  }
  final kid = header['kid'];
  final candidates = [
    for (final key in keys)
      if (key is Map<String, Object?> && key['kid'] == kid) key,
  ];
  if (kid is! String || candidates.isEmpty) {
    throw _fail('kid', 'no published key matches the token key id');
  }
  final key = candidates.first;
  if (key['kty'] != 'RSA') throw _fail('key', 'the key type must be RSA');
  if (key.containsKey('alg') && key['alg'] != 'RS256') {
    throw _fail('key', 'the key algorithm must be RS256');
  }

  final publicKey = RSAPublicKey(
    _bigIntOf(key['n'], 'n'),
    _bigIntOf(key['e'], 'e'),
  );
  final signature = _decodeBase64Url(parts[2], 'signature');
  final signer = RSASigner(SHA256Digest(), _sha256RsaOid)
    ..init(false, PublicKeyParameter<RSAPublicKey>(publicKey));
  var valid = false;
  try {
    valid = signer.verifySignature(
      Uint8List.fromList(ascii.encode('${parts[0]}.${parts[1]}')),
      RSASignature(signature),
    );
  } on ArgumentError {
    valid = false;
  } on StateError {
    valid = false;
  }
  if (!valid) throw _fail('signature', 'the signature does not verify');

  if (payload['iss'] != issuer) throw _fail('iss', 'unexpected issuer');
  final aud = payload['aud'];
  if (!(aud == clientId || (aud is List<Object?> && aud.contains(clientId)))) {
    throw _fail('aud', 'the audience does not include this client');
  }
  final exp = payload['exp'];
  if (exp is! num) throw _fail('exp', 'the expiry is missing');
  final nowSeconds =
      (now ?? DateTime.now()).toUtc().millisecondsSinceEpoch / 1000;
  if (exp <= nowSeconds - openAiIdTokenExpSkew.inSeconds) {
    throw _fail('exp', 'the token has expired');
  }
  if (payload['nonce'] != nonce) {
    throw _fail('nonce', 'the nonce does not match this sign-in');
  }
  final sub = payload['sub'];
  if (sub is! String || sub.isEmpty) {
    throw _fail('sub', 'the subject is missing');
  }

  final email = payload['email'];
  final auth = payload[_authClaim];
  final plan = auth is Map<String, Object?> ? auth['chatgpt_plan_type'] : null;
  return VerifiedIdToken(
    subject: sub,
    email: email is String ? email : null,
    planType: plan is String ? plan : null,
  );
}
