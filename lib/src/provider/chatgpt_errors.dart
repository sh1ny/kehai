/// Error mapping of the ChatGPT plan adapter (design D10, D12).
library;

import '../auth/auth_failure.dart';
import '../auth/failure_text.dart';
import '../auth/openai_constants.dart';
import 'provider.dart';

/// Maps a backend error to a [ProviderFailure], by code first, then by status.
///
/// [status] is `null` for an error carried in an event. [fields] holds the raw
/// code and parameter; [text] validates them and composes the message.
/// [retryAfter] is kept only for a plain `429`. A `401` here has already been
/// refreshed and repeated, so it is `reauth_required`.
ProviderFailure mapBackendError(
  FailureText text, {
  required ErrorFields fields,
  int? status,
  Duration? retryAfter,
}) {
  final code = fields.code;
  final kind = _kindFor(code, status);
  final composed = text.compose(
    kind,
    status: status,
    code: code,
    param: kind == FailureKind.invalidRequest ? fields.param : null,
  );
  return ProviderFailure(
    kind: kind,
    message: composed.message,
    status: status,
    code: composed.code,
    param: composed.param,
    retryAfter: kind == FailureKind.rateLimited ? retryAfter : null,
    sent: true,
  );
}

FailureKind _kindFor(String? code, int? status) {
  if (code != null) {
    if (openAiUsageLimitCodes.contains(code)) return FailureKind.usageLimit;
    if (openAiNotPermittedCodes.contains(code)) return FailureKind.notPermitted;
    if (openAiUnavailableCodes.contains(code)) return FailureKind.server;
    if (code == openAiUnsupportedCapabilityCode) {
      return FailureKind.invalidRequest;
    }
    if (code == openAiContextLengthExceededCode) {
      return FailureKind.contextOverflow;
    }
  }
  return switch (status) {
    null => FailureKind.server,
    401 => FailureKind.reauthRequired,
    403 => FailureKind.notPermitted,
    400 => FailureKind.invalidRequest,
    429 => FailureKind.rateLimited,
    >= 500 && < 600 => FailureKind.server,
    >= 400 && < 500 => FailureKind.invalidRequest,
    _ => FailureKind.protocol,
  };
}

/// Builds a failure that carries no server fields.
ProviderFailure localFailure(
  FailureText text,
  FailureKind kind, {
  String? detail,
  bool sent = false,
}) => ProviderFailure(
  kind: kind,
  message: text.compose(kind, detail: detail).message,
  sent: sent,
);

/// Converts an [AuthFailure] from the refresher to a [ProviderFailure].
ProviderFailure fromAuthFailure(AuthFailure failure) => ProviderFailure(
  kind: failure.kind,
  message: failure.message,
  status: failure.status,
  code: failure.code,
  param: failure.param,
  sent: failure.sent,
  rotationUncertain: failure.rotationUncertain,
);

/// Parses a `Retry-After` header given in whole seconds.
Duration? parseRetryAfter(String? value) {
  final seconds = int.tryParse(value?.trim() ?? '');
  return seconds == null || seconds < 0 ? null : Duration(seconds: seconds);
}
