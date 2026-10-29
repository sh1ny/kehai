/// The failure type of the OAuth client and the refresher.
library;

import 'failure_text.dart';

/// A failed token exchange, refresh or credential lookup.
///
/// [kind] is the failure class of design D10 that the caller reports:
/// [FailureKind.reauthRequired] when the user must sign in again,
/// [FailureKind.invalidRequest] for a rejected client or other `4xx`,
/// [FailureKind.server] for a `5xx`, [FailureKind.network] for an I/O failure,
/// [FailureKind.notPermitted] when plan usage is off, and so on. The
/// [message] is composed by `FailureText` (design D12) and never holds server
/// text, a token or a response body.
///
/// Task 6.1 maps an [AuthFailure] onto the provider failure type; until then
/// callers read these fields directly.
final class AuthFailure implements Exception {
  /// Creates a failure.
  const AuthFailure({
    required this.kind,
    required this.message,
    this.status,
    this.code,
    this.param,
    this.sent = false,
    this.rotationUncertain = false,
  });

  /// Creates a failure from a [ComposedFailure].
  AuthFailure.composed(
    this.kind,
    ComposedFailure composed, {
    this.sent = false,
    this.rotationUncertain = false,
  }) : message = composed.message,
       status = composed.status,
       code = composed.code,
       param = composed.param;

  /// The failure class reported to the user.
  final FailureKind kind;

  /// The Kehai-composed message.
  final String message;

  /// The HTTP status, if a response arrived.
  final int? status;

  /// The validated server error code, if one was sent.
  final String? code;

  /// The validated server error parameter, if one was sent.
  final String? param;

  /// Whether the request body went out before the failure.
  ///
  /// Meaningful for [FailureKind.network]: `false` means the request was
  /// certainly not processed.
  final bool sent;

  /// Whether a refresh was sent without a response, so the server may have
  /// rotated the refresh token and the replacement is lost.
  final bool rotationUncertain;

  @override
  String toString() => 'AuthFailure(${kind.wire}): $message';
}
