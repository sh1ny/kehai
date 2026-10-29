/// The OAuth token and revocation requests (design D2, D4, D6a).
///
/// Every request is a form `POST` bounded by [openAiMaxAuthBodyBytes] and
/// [openAiRequestTimeout], follows no redirects, and fails with an
/// [AuthFailure] whose message `FailureText` composes (design D12).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'auth_failure.dart';
import 'failure_text.dart';
import 'openai_constants.dart';

/// The validated fields of a successful token response.
final class TokenGrant {
  /// Creates a grant.
  const TokenGrant({
    required this.accessToken,
    required this.expiresIn,
    this.refreshToken,
    this.idToken,
    this.scope,
  });

  /// The access token, treated as opaque.
  final String accessToken;

  /// The positive lifetime of [accessToken]; the expiry is now plus this.
  final Duration expiresIn;

  /// The refresh token; always set for a code exchange, optional on refresh.
  final String? refreshToken;

  /// The ID token; always set for a code exchange, optional on refresh.
  final String? idToken;

  /// The granted scope string; always set for a code exchange.
  final String? scope;

  /// The granted scopes split on whitespace, or `null` when [scope] is absent.
  List<String>? get scopes => scope?.split(RegExp(r'\s+'));
}

/// The outcome of a revocation request.
final class RevocationResult {
  /// Creates a result.
  const RevocationResult({required this.confirmed, this.status});

  /// Whether the endpoint answered an empty `200`.
  final bool confirmed;

  /// The HTTP status, or `null` when no response arrived.
  final int? status;
}

final class _Response {
  const _Response(this.status, this.body, {required this.overflow});

  final int status;
  final List<int> body;
  final bool overflow;
}

/// Sends token and revocation requests to one issuer.
final class OAuthClient {
  /// Creates a client for [issuer], for example `https://auth.openai.com`.
  ///
  /// [cancelled] is a minimal abort signal like the one of `OidcClient`: when
  /// the future completes, the in-flight request is aborted. [timeout] bounds
  /// each request, including connecting.
  OAuthClient(
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

  /// Exchanges an authorization [code] for tokens (design D2).
  ///
  /// The response must hold `access_token`, `refresh_token`, `id_token`, a
  /// positive `expires_in` and `scope`; a missing field fails with a message
  /// naming it. [secrets] are live values that must not appear in a message,
  /// in addition to the code and verifier.
  Future<TokenGrant> exchangeCode({
    required String clientId,
    required String code,
    required String codeVerifier,
    required String redirectUri,
    Iterable<String> secrets = const [],
  }) async {
    final text = FailureText(secrets: [code, codeVerifier, ...secrets]);
    final response = await _post(Uri.parse('$issuer$openAiTokenPath'), {
      'grant_type': 'authorization_code',
      'client_id': clientId,
      'code': code,
      'code_verifier': codeVerifier,
      'redirect_uri': redirectUri,
      'resource': openAiResource,
    }, text);
    if (response.status < 200 || response.status > 299) {
      throw _exchangeRejected(response, text);
    }
    return _grant(response, text, requireAll: true);
  }

  /// Refreshes with [refreshToken] (design D4).
  ///
  /// Sends the registration's [clientId], the resource and no scope. The
  /// response must hold `access_token` and a positive `expires_in`.
  /// [secrets] are live tokens that must not appear in a message; the refresh
  /// token is always included.
  ///
  /// Throws an [AuthFailure] classified as follows: `401`, or `400` with a
  /// terminal code, is [FailureKind.reauthRequired]; `invalid_client` and any
  /// other `4xx` are [FailureKind.invalidRequest]; `5xx` is
  /// [FailureKind.server]; an I/O failure is [FailureKind.network], with
  /// `sent` telling whether the body went out and `rotationUncertain` set when
  /// it did.
  Future<TokenGrant> refresh({
    required String clientId,
    required String refreshToken,
    Iterable<String> secrets = const [],
  }) async {
    final text = FailureText(secrets: [refreshToken, ...secrets]);
    final response = await _post(
      Uri.parse('$issuer$openAiTokenPath'),
      {
        'grant_type': 'refresh_token',
        'refresh_token': refreshToken,
        'client_id': clientId,
        'resource': openAiResource,
      },
      text,
      rotates: true,
    );
    if (response.status < 200 || response.status > 299) {
      throw _refreshRejected(response, text);
    }
    return _grant(response, text, requireAll: false);
  }

  /// Revokes [refreshToken] at [endpoint] (design D6a step 3).
  ///
  /// Never throws: an empty `200` is confirmed, and every other outcome,
  /// including a network failure, an oversized body and cancellation, is an
  /// unconfirmed [RevocationResult].
  Future<RevocationResult> revoke(
    Uri endpoint, {
    required String refreshToken,
    required String clientId,
  }) async {
    try {
      final response = await _post(endpoint, {
        'token': refreshToken,
        'token_type_hint': 'refresh_token',
        'client_id': clientId,
      }, FailureText(secrets: [refreshToken]));
      return RevocationResult(
        confirmed:
            response.status == HttpStatus.ok &&
            response.body.isEmpty &&
            !response.overflow,
        status: response.status,
      );
    } on AuthFailure {
      return const RevocationResult(confirmed: false);
    }
  }

  AuthFailure _exchangeRejected(_Response response, FailureText text) {
    final fields = text.parseErrorBody(response.overflow ? [] : response.body);
    final status = response.status;
    final composed = text.compose(
      FailureKind.tokenExchange,
      status: status,
      code: fields.code,
      param: fields.param,
    );
    return AuthFailure.composed(FailureKind.tokenExchange, composed);
  }

  AuthFailure _refreshRejected(_Response response, FailureText text) {
    final fields = text.parseErrorBody(response.overflow ? [] : response.body);
    final status = response.status;
    final code = text.validateCode(fields.code);

    ComposedFailure compose(FailureKind kind) => text.compose(
      kind,
      status: status,
      code: fields.code,
      param: fields.param,
    );

    if (status >= 400 && status < 500 && code == openAiInvalidClientCode) {
      return AuthFailure.composed(
        FailureKind.invalidRequest,
        compose(FailureKind.refreshRejected),
      );
    }
    if (status == HttpStatus.unauthorized ||
        (status == HttpStatus.badRequest &&
            openAiTerminalRefreshCodes.contains(code))) {
      final kind = openAiTerminalRefreshCodes.contains(code)
          ? FailureKind.refreshRejected
          : FailureKind.reauthRequired;
      return AuthFailure.composed(FailureKind.reauthRequired, compose(kind));
    }
    if (status >= 400 && status < 500) {
      return AuthFailure.composed(
        FailureKind.invalidRequest,
        compose(FailureKind.invalidRequest),
      );
    }
    if (status >= 500) {
      return AuthFailure.composed(
        FailureKind.server,
        compose(FailureKind.server),
      );
    }
    return AuthFailure.composed(
      FailureKind.protocol,
      compose(FailureKind.protocol),
    );
  }

  AuthFailure _protocol(FailureText text, String detail, {int? status}) =>
      AuthFailure.composed(
        FailureKind.protocol,
        text.compose(FailureKind.protocol, status: status, detail: detail),
      );

  TokenGrant _grant(
    _Response response,
    FailureText text, {
    required bool requireAll,
  }) {
    if (response.overflow) {
      throw AuthFailure.composed(
        FailureKind.invalidRequest,
        text.compose(
          FailureKind.invalidRequest,
          status: response.status,
          detail: 'The response exceeds 64 KiB.',
        ),
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.body));
    } on FormatException {
      throw _protocol(text, 'The token response is not JSON.');
    }
    if (decoded is! Map<String, Object?>) {
      throw _protocol(text, 'The token response is not an object.');
    }
    final fields = decoded;
    String? string(String name, {required bool required}) {
      final value = fields[name];
      if (value is String && value.isNotEmpty) return value;
      if (value == null && !required) return null;
      throw _protocol(
        text,
        required
            ? 'The token response lacks "$name".'
            : 'The token response has an invalid "$name".',
      );
    }

    final access = string('access_token', required: true)!;
    final expiresIn = fields['expires_in'];
    if (expiresIn is! num || !expiresIn.isFinite || expiresIn < 1) {
      throw _protocol(
        text,
        'The token response lacks a positive "expires_in".',
      );
    }
    return TokenGrant(
      accessToken: access,
      expiresIn: Duration(seconds: expiresIn.floor()),
      refreshToken: string('refresh_token', required: requireAll),
      idToken: string('id_token', required: requireAll),
      scope: string('scope', required: requireAll),
    );
  }

  Future<_Response> _post(
    Uri uri,
    Map<String, String> form,
    FailureText text, {
    bool rotates = false,
  }) async {
    final client = HttpClient()..connectionTimeout = timeout;
    var aborted = false;
    var finished = false;
    var sent = false;
    unawaited(
      cancelled?.then((_) {
        if (finished) return;
        aborted = true;
        client.close(force: true);
      }),
    );
    AuthFailure io(String detail, {FailureKind kind = FailureKind.network}) =>
        AuthFailure.composed(
          kind,
          text.compose(kind, detail: detail),
          sent: sent,
          rotationUncertain: sent && rotates,
        );
    try {
      return await (() async {
        final request = await client.postUrl(uri);
        request.followRedirects = false;
        request.headers
          ..contentType = ContentType(
            'application',
            'x-www-form-urlencoded',
            charset: 'utf-8',
          )
          ..set(HttpHeaders.acceptHeader, 'application/json');
        // From the first byte written the server may have processed it.
        sent = true;
        request.add(utf8.encode(Uri(queryParameters: form).query));
        final response = await request.close();
        final body = <int>[];
        var overflow = false;
        await for (final chunk in response) {
          if (overflow) continue;
          body.addAll(chunk);
          if (body.length > openAiMaxAuthBodyBytes) {
            overflow = true;
            body.clear();
          }
        }
        return _Response(response.statusCode, body, overflow: overflow);
      })().timeout(timeout);
    } on AuthFailure {
      rethrow;
    } on TimeoutException {
      throw io(
        sent
            ? 'The request timed out before a response arrived.'
            : 'The request could not be sent in time.',
      );
    } on Object {
      if (aborted) {
        throw AuthFailure.composed(
          FailureKind.cancelled,
          text.compose(FailureKind.cancelled),
          sent: sent,
          rotationUncertain: sent && rotates,
        );
      }
      throw io(
        sent
            ? 'The connection failed before a response arrived.'
            : 'The request could not be sent.',
      );
    } finally {
      finished = true;
      client.close(force: true);
    }
  }
}
