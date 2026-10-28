/// Error type shared by the session path, record and tree layers.
library;

/// A violation of the session journal rules.
///
/// [reason] is a short stable category such as `invalid path`,
/// `invalid record`, `path not found` or `not a map`. [detail] explains the
/// offending segment, rule or value. [op] and [path] name the operation and
/// path involved when known.
final class SessionError implements Exception {
  /// Creates an error with a stable [reason] and a human-readable [detail].
  const SessionError(this.reason, this.detail, {this.op, this.path});

  /// The stable error category.
  final String reason;

  /// The explanation of what was wrong.
  final String detail;

  /// The wire name of the operation involved, if any.
  final String? op;

  /// The path involved, if any.
  final String? path;

  /// Returns a copy of this error annotated with [op] and [path].
  SessionError at(String op, String path) =>
      SessionError(reason, detail, op: op, path: path);

  /// A readable message that names the reason, operation, path and detail.
  String get message {
    final where = [if (op != null) op, if (path != null) '"$path"'].join(' ');
    return where.isEmpty ? '$reason: $detail' : '$reason ($where): $detail';
  }

  @override
  String toString() => 'SessionError: $message';
}
