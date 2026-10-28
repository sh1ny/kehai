/// Shared result descriptor and error types for the result store read side.
library;

final RegExp _handlePattern = RegExp(r'^r/[0-9a-f]{12}$');
final RegExp _sha256Pattern = RegExp(r'^[0-9a-f]{64}$');

/// Facts about one stored result's bytes.
///
/// A descriptor says nothing about how the bytes are shown to the model;
/// that is the composer's job. The [handle] has the form `r/<12 hex>`,
/// [sha256] is the lowercase hex digest of the stored bytes, [bytes] their
/// length and [lines] the number of lines under the line definition of the
/// scanner: each `\n`-terminated segment plus a final non-empty unterminated
/// segment.
final class ResultDescriptor {
  /// Creates a descriptor from already-known facts.
  const ResultDescriptor({
    required this.handle,
    required this.sha256,
    required this.bytes,
    required this.lines,
  });

  /// Reads a descriptor from its [toJson] form and [validate]s it.
  ///
  /// Throws a [ResultError] when the shape or any fact is invalid.
  factory ResultDescriptor.fromJson(Map<String, Object?> json) {
    final descriptor = switch (json) {
      {
        'handle': final String handle,
        'sha256': final String sha256,
        'bytes': final int bytes,
        'lines': final int lines,
      } =>
        ResultDescriptor(
          handle: handle,
          sha256: sha256,
          bytes: bytes,
          lines: lines,
        ),
      _ => throw ResultError('invalid result descriptor: $json'),
    };
    return descriptor..validate();
  }

  /// Checks that the facts are well formed, else throws a [ResultError].
  ///
  /// The [handle] must be `r/` plus 12 lowercase hex digits, the [sha256]
  /// exactly 64 lowercase hex digits starting with those 12, and [bytes] and
  /// [lines] non-negative. Anything that becomes a file name is thereby
  /// confined to hex digits.
  void validate() {
    if (!_handlePattern.hasMatch(handle)) {
      throw ResultError('invalid result descriptor: bad handle "$handle"');
    }
    if (!_sha256Pattern.hasMatch(sha256)) {
      throw ResultError('invalid result descriptor: bad sha256 "$sha256"');
    }
    if (!sha256.startsWith(handle.substring(2))) {
      throw ResultError(
        'invalid result descriptor: handle $handle does not match $sha256',
      );
    }
    if (bytes < 0 || lines < 0) {
      throw ResultError(
        'invalid result descriptor: negative size ($bytes bytes, '
        '$lines lines)',
      );
    }
  }

  /// The result handle, `r/<12 hex>`.
  final String handle;

  /// The lowercase hex SHA-256 of the stored bytes.
  final String sha256;

  /// The size of the stored bytes.
  final int bytes;

  /// The number of lines in the stored bytes.
  final int lines;

  /// The JSON form: `{handle, sha256, bytes, lines}`.
  Map<String, Object?> toJson() => {
    'handle': handle,
    'sha256': sha256,
    'bytes': bytes,
    'lines': lines,
  };

  @override
  bool operator ==(Object other) =>
      other is ResultDescriptor &&
      other.handle == handle &&
      other.sha256 == sha256 &&
      other.bytes == bytes &&
      other.lines == lines;

  @override
  int get hashCode => Object.hash(handle, sha256, bytes, lines);

  @override
  String toString() => 'ResultDescriptor($handle, $bytes bytes, $lines lines)';
}

/// A failure to page, search or compose a stored result.
///
/// [message] is the complete, stable text shown to the caller; no partial
/// body accompanies it.
class ResultError implements Exception {
  /// Creates an error with the given [message].
  const ResultError(this.message);

  /// The explanation of the failure.
  final String message;

  @override
  String toString() => message;
}
