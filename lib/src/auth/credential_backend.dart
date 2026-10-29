/// The contract between the credential store and a platform backend.
library;

import 'dart:typed_data';

/// One platform's way of keeping the record bytes safe on disk.
///
/// Implementations never fall back to a less protected form. A failure throws
/// a `CredentialStoreError`.
abstract interface class CredentialBackend {
  /// The credential file name inside the home.
  String get fileName;

  /// Validates and returns the canonical home directory, or `null` when the
  /// home does not exist and [create] is `false`.
  ///
  /// Creating the home happens only after its ancestors have been validated.
  String? resolveHome(String home, {required bool create});

  /// Returns the plaintext bytes of the stored record, or `null` when no
  /// credential file exists in the canonical home [dir].
  Uint8List? read(String dir);

  /// Atomically replaces the stored record in [dir] with [plaintext].
  ///
  /// A failure leaves the previous record intact and no temporary file.
  void write(String dir, Uint8List plaintext);
}
