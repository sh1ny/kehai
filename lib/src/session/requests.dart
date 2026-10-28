/// Request correlation types for `meta/requests`.
library;

/// The result of admitting a request id with a fingerprint.
///
/// Only a newly admitted request may be executed. A known request returns the
/// recorded node, which holds its `state` and any `outcome` or `reason`, and
/// gives no permission to execute.
final class Admission {
  /// The request was recorded as `admitted` by this call.
  const Admission.newlyAdmitted() : node = null;

  /// The request was already recorded; [node] is a copy of its record.
  const Admission.existing(Map<String, Object?> this.node);

  /// The recorded node of an existing request, or `null` when newly admitted.
  final Map<String, Object?>? node;

  /// Whether this call recorded the admission and may execute the request.
  bool get isNew => node == null;

  /// The recorded state of an existing request, or `admitted` when new.
  String get state => node == null ? 'admitted' : node!['state']! as String;
}

/// A request id that is already recorded under a different fingerprint.
final class RequestCollision implements Exception {
  /// Creates the error for the colliding request [id].
  const RequestCollision(this.id);

  /// The stable error category.
  String get reason => 'request id collision';

  /// The colliding request id.
  final String id;

  /// A readable message naming the reason and the id.
  String get message =>
      '$reason: request "$id" is recorded with a different fingerprint';

  @override
  String toString() => 'RequestCollision: $message';
}
