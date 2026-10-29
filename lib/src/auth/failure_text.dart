/// Failure messages composed locally from fixed templates (design D12).
///
/// [FailureText] is the only way an auth or provider failure gets a message.
/// A message is built from a Kehai template, the HTTP status, a server error
/// code that passed `^[a-z0-9_.]{1,64}$` and a server error parameter that
/// passed `^[A-Za-z0-9_.\[\]]{1,64}$`. Server `message`, `error_description`
/// and `detail` text, bodies and headers are parsed for the code and
/// parameter and then dropped.
library;

import 'dart:convert';

import 'openai_constants.dart';

/// The code reported when a server code fails its check.
const String unrecognizedCode = 'unrecognized';

/// The longest message [FailureText.compose] returns (design D10).
const int maxFailureMessageLength = 500;

final RegExp _codePattern = RegExp(r'^[a-z0-9_.]{1,64}$');
final RegExp _paramPattern = RegExp(r'^[A-Za-z0-9_.\[\]]{1,64}$');

/// The kind of failure a message describes.
///
/// The auth kinds cover sign-in and refresh; the rest are the provider
/// failure kinds of design D10, keyed by their [wire] names.
enum FailureKind {
  /// The authorization-code exchange failed.
  tokenExchange('token_exchange'),

  /// The token endpoint rejected a refresh (terminal or configuration).
  refreshRejected('refresh_rejected'),

  /// A refresh failed for a transient or unknown reason.
  refreshFailed('refresh_failed'),

  /// The user must sign in again.
  reauthRequired('reauth_required'),

  /// The ChatGPT plan usage limit was reached.
  usageLimit('usage_limit'),

  /// The backend rate-limited the request.
  rateLimited('rate_limited'),

  /// Plan usage is not permitted for this account or route.
  notPermitted('not_permitted'),

  /// The request exceeded the model's context window.
  contextOverflow('context_overflow'),

  /// The backend rejected the request as malformed or unsupported.
  invalidRequest('invalid_request'),

  /// The backend failed or is temporarily unavailable.
  server('server'),

  /// The connection failed.
  network('network'),

  /// The backend went silent past the response deadline.
  idleTimeout('idle_timeout'),

  /// The caller cancelled the request.
  cancelled('cancelled'),

  /// The response ended incomplete.
  incomplete('incomplete'),

  /// The response broke the expected protocol.
  protocol('protocol'),

  /// A model request failed with no more specific kind.
  modelRequest('model_request');

  const FailureKind(this.wire);

  /// The stable snake_case name of this kind.
  final String wire;
}

/// The code and parameter parsed from an error body, before validation.
final class ErrorFields {
  /// Creates fields with a raw [code] and [param], both possibly `null`.
  const ErrorFields({this.code, this.param});

  /// The raw server error code, or `null` when the body has none.
  final String? code;

  /// The raw server error parameter, or `null` when the body has none.
  final String? param;
}

/// A composed failure: the message and the validated values it carries.
final class ComposedFailure {
  /// Creates a failure with its [message] and validated parts.
  const ComposedFailure({
    required this.message,
    this.status,
    this.code,
    this.param,
  });

  /// The Kehai-composed message, at most [maxFailureMessageLength] characters.
  final String message;

  /// The HTTP status, if any.
  final int? status;

  /// The validated code, [unrecognizedCode], or `null` when none was sent.
  final String? code;

  /// The validated parameter, or `null` when none was sent or it was dropped.
  final String? param;
}

/// Composes failure messages and validates server-supplied values against the
/// secrets that are live for the current call.
final class FailureText {
  /// Creates a builder that rejects any value containing one of [secrets].
  ///
  /// [secrets] are the access, refresh and ID tokens, the authorization code,
  /// the PKCE verifier, `state` and `nonce` held for the duration of the call.
  /// Empty strings are ignored.
  FailureText({Iterable<String> secrets = const []})
    : _secrets = [
        for (final secret in secrets)
          if (secret.isNotEmpty) secret,
      ];

  final List<String> _secrets;

  bool _hasSecret(String value) => _secrets.any(value.contains);

  /// Returns [raw] if it is a safe server code, [unrecognizedCode] if it is
  /// not, and `null` if [raw] is `null`.
  String? validateCode(String? raw) {
    if (raw == null) return null;
    return _codePattern.hasMatch(raw) && !_hasSecret(raw)
        ? raw
        : unrecognizedCode;
  }

  /// Returns [raw] if it is a safe server parameter, or `null` to drop it.
  String? validateParam(String? raw) {
    if (raw == null) return null;
    return _paramPattern.hasMatch(raw) && !_hasSecret(raw) ? raw : null;
  }

  /// Parses the code and parameter out of an error [body] already read.
  ///
  /// The code comes from a string `error` or from `error.code`, and the
  /// parameter from `error.param`. A body that is larger than
  /// [openAiMaxErrorBodyBytes], not UTF-8 JSON, or not an object (such as
  /// HTML) yields no fields, and so does a `{"detail": "..."}` body. All
  /// other fields are discarded.
  ErrorFields parseErrorBody(List<int> body) {
    if (body.isEmpty || body.length > openAiMaxErrorBodyBytes) {
      return const ErrorFields();
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(body, allowMalformed: true));
    } on FormatException {
      return const ErrorFields();
    }
    return switch (decoded) {
      {'error': final String code} => ErrorFields(code: code),
      {'error': final Map<Object?, Object?> error} => ErrorFields(
        code: error['code'] is String ? error['code'] as String : null,
        param: error['param'] is String ? error['param'] as String : null,
      ),
      _ => const ErrorFields(),
    };
  }

  /// Composes the failure message for [kind].
  ///
  /// [code] and [param] are raw server values; they are validated here, so a
  /// caller passes them straight from [parseErrorBody].
  ///
  /// [detail] is a fixed Kehai sentence that replaces the template's own
  /// closing sentence. It must never hold server text.
  ComposedFailure compose(
    FailureKind kind, {
    int? status,
    String? code,
    String? param,
    String? detail,
  }) {
    final safeCode = validateCode(code);
    final safeParam = validateParam(param);
    final (head, templateTail) = _template(kind, safeCode);
    final tail = detail ?? templateTail;
    final buffer = StringBuffer(head);
    if (status != null) buffer.write(': HTTP $status');
    if (safeCode != null) buffer.write(' ($safeCode)');
    if (safeParam != null) buffer.write(', parameter $safeParam');
    if (tail != null) buffer.write('. $tail');
    var message = buffer.toString();
    if (message.length > maxFailureMessageLength) {
      message = message.substring(0, maxFailureMessageLength);
    }
    return ComposedFailure(
      message: message,
      status: status,
      code: safeCode,
      param: safeParam,
    );
  }

  /// Returns the fixed head and optional tail sentence for a template keyed by
  /// (kind, code).
  (String, String?) _template(FailureKind kind, String? code) => switch ((
    kind,
    code,
  )) {
    (FailureKind.refreshRejected, 'refresh_token_reused') => (
      'refresh rejected',
      'The refresh token was already used, possibly by an earlier '
          'refresh whose response was lost. Run kehai login openai.',
    ),
    (FailureKind.refreshRejected, final String c)
        when openAiTerminalRefreshCodes.contains(c) =>
      (
        'refresh rejected',
        'The refresh token is no longer valid. Run kehai login openai.',
      ),
    (FailureKind.refreshRejected, openAiInvalidClientCode) => (
      'refresh rejected',
      'The stored client registration was refused. Run kehai logout '
          'openai --forget, then kehai login openai.',
    ),
    (FailureKind.refreshRejected, _) => ('refresh rejected', null),
    (FailureKind.refreshFailed, _) => ('refresh failed', null),
    (FailureKind.tokenExchange, _) => ('sign-in token exchange failed', null),
    (FailureKind.reauthRequired, _) => (
      'sign-in required',
      'Run kehai login openai.',
    ),
    (FailureKind.usageLimit, _) => (
      'ChatGPT plan usage limit reached',
      'See ChatGPT settings > Usage.',
    ),
    (FailureKind.rateLimited, _) => ('rate limited', null),
    (FailureKind.notPermitted, _) => (
      'ChatGPT plan usage not permitted',
      'Do not retry; check the ChatGPT account and its usage settings.',
    ),
    (FailureKind.contextOverflow, _) => (
      'the conversation is too long for the model',
      null,
    ),
    (FailureKind.invalidRequest, _) => ('request rejected', null),
    (FailureKind.server, _) => ('ChatGPT service error', null),
    (FailureKind.network, _) => ('network error', null),
    (FailureKind.idleTimeout, _) => ('the backend stopped responding', null),
    (FailureKind.cancelled, _) => ('request cancelled', null),
    (FailureKind.incomplete, _) => ('response incomplete', null),
    (FailureKind.protocol, _) => ('unexpected response from the backend', null),
    (FailureKind.modelRequest, _) => ('model request failed', null),
  };
}
