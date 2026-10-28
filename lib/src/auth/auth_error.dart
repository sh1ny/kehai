/// Error type shared by the OpenAI sign-in path.
library;

/// A failure of discovery, key-set fetch or ID-token verification.
///
/// [reason] is a short stable category such as `invalid ID token`,
/// `discovery failed` or `key fetch failed`. [detail] names the failed check
/// or rule. Neither ever contains a token, a server message or a response
/// body (credential-store *Locally composed failure text*).
final class AuthError implements Exception {
  /// Creates an error with a stable [reason] and a [detail] naming the check.
  const AuthError(this.reason, this.detail);

  /// The stable error category.
  final String reason;

  /// The explanation of what was wrong, starting with the failed check name.
  final String detail;

  /// A readable message that names the reason and the detail.
  String get message => '$reason: $detail';

  @override
  String toString() => 'AuthError: $message';
}
