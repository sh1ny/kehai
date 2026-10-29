/// PKCE, `state` and `nonce` generation for the sign-in flow (design D2).
library;

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

import 'openai_constants.dart';

/// Encodes [bytes] as base64url without padding.
String _base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

/// Returns [byteCount] random bytes from [random] as base64url without
/// padding.
String randomBase64Url(int byteCount, Random random) =>
    _base64UrlNoPad([for (var i = 0; i < byteCount; i++) random.nextInt(256)]);

/// A PKCE verifier and its S256 challenge.
final class PkcePair {
  /// Creates a pair from a [verifier] and its [challenge].
  const PkcePair(this.verifier, this.challenge);

  /// Generates a fresh pair from 64 random bytes (an 86-character verifier).
  ///
  /// [random] defaults to [Random.secure]; tests may pass a seeded source.
  factory PkcePair.generate({Random? random}) {
    final verifier = randomBase64Url(
      openAiPkceVerifierBytes,
      random ?? Random.secure(),
    );
    return PkcePair(verifier, challengeFor(verifier));
  }

  /// Returns the S256 challenge of [verifier]: the base64url, unpadded SHA-256
  /// of its ASCII bytes.
  static String challengeFor(String verifier) =>
      _base64UrlNoPad(sha256.convert(ascii.encode(verifier)).bytes);

  /// The secret sent at the token exchange.
  final String verifier;

  /// The S256 challenge sent at authorize.
  final String challenge;
}

/// Returns a fresh `state` value: 32 random bytes, base64url without padding.
String generateState({Random? random}) =>
    randomBase64Url(openAiStateBytes, random ?? Random.secure());

/// Returns a fresh `nonce` value: 32 random bytes, base64url without padding.
String generateNonce({Random? random}) =>
    randomBase64Url(openAiStateBytes, random ?? Random.secure());
