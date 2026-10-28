/// OIDC discovery and key-set fetch (design D3b steps 1 and 2).
///
/// Both requests are bounded by [openAiMaxAuthBodyBytes] and by a timeout,
/// follow no redirects, and fail with an [AuthError] that carries no server
/// text. Keys are fetched per call and never cached.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'auth_error.dart';
import 'openai_constants.dart';

/// The stable [AuthError.reason] of a failed discovery.
const String discoveryFailedReason = 'discovery failed';

/// The stable [AuthError.reason] of a failed key-set fetch.
const String keyFetchFailedReason = 'key fetch failed';

/// The stable [AuthError.reason] of a request aborted by the cancel signal.
const String authCancelledReason = 'cancelled';

/// The validated OIDC discovery document.
final class OidcDiscovery {
  /// Creates a discovery result.
  const OidcDiscovery({
    required this.issuer,
    required this.jwksUri,
    required this.revocationEndpoint,
  });

  /// The issuer, equal to the configured one.
  final String issuer;

  /// The key-set URL, on the issuer's host.
  final Uri jwksUri;

  /// The revocation endpoint, on the issuer's host.
  final Uri revocationEndpoint;
}

bool _isLoopbackHost(String host) => host == '127.0.0.1' || host == 'localhost';

/// Whether [uri] is an `https` URL on the host of [issuer], or any URL on
/// loopback when [issuer] is itself on loopback (the test override of D11).
bool _isTrustedEndpoint(Uri uri, Uri issuer) {
  if (!uri.hasAuthority || uri.host.isEmpty) return false;
  if (_isLoopbackHost(uri.host) && _isLoopbackHost(issuer.host)) {
    return uri.scheme == 'http' || uri.scheme == 'https';
  }
  return uri.scheme == 'https' && uri.host == issuer.host;
}

/// Fetches the discovery document and key set of an OpenID issuer.
final class OidcClient {
  /// Creates a client for [issuer], for example `https://auth.openai.com`.
  ///
  /// [cancelled] is a minimal abort signal: when the future completes, the
  /// in-flight request is aborted and fails with reason
  /// [authCancelledReason]. A later task replaces it with a cancel token.
  /// [timeout] bounds each request, including connecting.
  OidcClient(
    this.issuer, {
    this.cancelled,
    this.timeout = openAiRequestTimeout,
  });

  /// The configured issuer.
  final String issuer;

  /// A future that completes when the caller wants the request aborted.
  final Future<void>? cancelled;

  /// The timeout of each request.
  final Duration timeout;

  /// Fetches and validates `{issuer}/.well-known/openid-configuration`.
  ///
  /// The document's `issuer` must equal [issuer], and its `jwks_uri` and
  /// `revocation_endpoint` must be `https` URLs on the issuer's host (or
  /// loopback URLs when the issuer is on loopback). Both are required.
  Future<OidcDiscovery> discover() async {
    final issuerUri = Uri.parse(issuer);
    final document = await _getJson(
      Uri.parse('$issuer$openAiDiscoveryPath'),
      discoveryFailedReason,
    );
    if (document is! Map<String, Object?>) {
      throw const AuthError(
        discoveryFailedReason,
        'the document is not an object',
      );
    }
    if (document['issuer'] != issuer) {
      throw const AuthError(
        discoveryFailedReason,
        'issuer does not match the configured issuer',
      );
    }
    Uri endpoint(String name) {
      final raw = document[name];
      final uri = raw is String ? Uri.tryParse(raw) : null;
      if (uri == null || !_isTrustedEndpoint(uri, issuerUri)) {
        throw AuthError(
          discoveryFailedReason,
          '$name is missing or not an https URL on the issuer host',
        );
      }
      return uri;
    }

    return OidcDiscovery(
      issuer: issuer,
      jwksUri: endpoint('jwks_uri'),
      revocationEndpoint: endpoint('revocation_endpoint'),
    );
  }

  /// Fetches the key set at [jwksUri] and returns its `keys` list.
  Future<List<Object?>> fetchKeys(Uri jwksUri) async {
    final document = await _getJson(jwksUri, keyFetchFailedReason);
    final keys = document is Map<String, Object?> ? document['keys'] : null;
    if (keys is! List<Object?>) {
      throw const AuthError(keyFetchFailedReason, 'the document has no keys');
    }
    return keys;
  }

  Future<Object?> _getJson(Uri uri, String reason) async {
    final bytes = await _get(uri, reason);
    try {
      return jsonDecode(utf8.decode(bytes));
    } on FormatException {
      throw AuthError(reason, 'the response is not JSON');
    }
  }

  Future<List<int>> _get(Uri uri, String reason) async {
    final client = HttpClient()..connectionTimeout = timeout;
    var aborted = false;
    var finished = false;
    unawaited(
      cancelled?.then((_) {
        if (finished) return;
        aborted = true;
        client.close(force: true);
      }),
    );
    try {
      return await _read(client, uri, reason).timeout(timeout);
    } on AuthError {
      rethrow;
    } on TimeoutException {
      throw AuthError(reason, 'the request timed out');
    } on Object {
      if (aborted) {
        throw const AuthError(authCancelledReason, 'the request was aborted');
      }
      throw AuthError(reason, 'the request failed');
    } finally {
      finished = true;
      client.close(force: true);
    }
  }

  Future<List<int>> _read(HttpClient client, Uri uri, String reason) async {
    final request = await client.getUrl(uri);
    request.followRedirects = false;
    request.headers.set(HttpHeaders.acceptHeader, 'application/json');
    final response = await request.close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw AuthError(reason, 'HTTP ${response.statusCode}');
    }
    if (response.contentLength > openAiMaxAuthBodyBytes) {
      throw AuthError(reason, 'the response is larger than the limit');
    }
    final body = <int>[];
    await for (final chunk in response) {
      body.addAll(chunk);
      if (body.length > openAiMaxAuthBodyBytes) {
        throw AuthError(reason, 'the response is larger than the limit');
      }
    }
    return body;
  }
}
