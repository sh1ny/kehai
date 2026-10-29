/// Error type for the credential store, trust checks and backends.
library;

/// A failure to load, store or lock credentials.
///
/// [reason] is one of the stable categories declared on this class. [detail]
/// is a fixed local description built from paths, modes and owner ids; it
/// never holds credential bytes or text received from a server.
final class CredentialStoreError implements Exception {
  /// Creates an error with a stable [reason] and a human-readable [detail].
  const CredentialStoreError(this.reason, this.detail);

  /// The category when no secure backend can be used. There is never a
  /// plaintext fallback.
  static const String unavailable = 'secure credential storage unavailable';

  /// The category when stored credentials cannot be read or decrypted.
  static const String unreadable = 'credentials unreadable';

  /// The category when the credential path, home or file is unsafe.
  static const String unsafePath = 'unsafe credential path';

  /// The category when `auth.lock` could not be acquired before the deadline.
  ///
  /// Callers map this to the `network` failure class.
  static const String lockBusy = 'credential lock busy';

  /// The category when the caller cancelled while waiting for the lock.
  static const String cancelled = 'credential lock cancelled';

  /// The stable error category.
  final String reason;

  /// The explanation of what was wrong.
  final String detail;

  /// A readable message naming the reason and the detail.
  String get message => detail.isEmpty ? reason : '$reason: $detail';

  @override
  String toString() => 'CredentialStoreError: $message';
}
