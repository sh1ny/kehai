/// Validated addresses of nodes in the session tree.
library;

import 'errors.dart';

final RegExp _segmentAlphabet = RegExp(r'^[A-Za-z0-9_.:\-]+$');

/// A validated `/`-separated address of a node in the session tree.
///
/// A path has 1 to 32 segments of 1 to 128 characters from
/// `A-Z a-z 0-9 _ . : -`, and its first segment must be in [roots]. The
/// empty path ([empty]) addresses the whole tree; whether it is allowed is a
/// property of the record that carries it, not of the path itself.
final class SessionPath {
  const SessionPath._(this.segments);

  /// Parses and validates [text].
  ///
  /// The empty string yields [empty]. Throws a [SessionError] with reason
  /// `invalid path` naming the offending segment or rule otherwise.
  factory SessionPath.parse(String text) {
    if (text.isEmpty) return empty;
    final segments = text.split('/');
    if (segments.length > maxSegments) {
      throw SessionError(
        'invalid path',
        '${segments.length} segments exceeds the limit of $maxSegments',
      );
    }
    for (final segment in segments) {
      if (segment.isEmpty) {
        throw const SessionError('invalid path', 'empty segment');
      }
      if (segment.length > maxSegmentLength) {
        throw SessionError(
          'invalid path',
          'segment of ${segment.length} characters exceeds the limit of '
              '$maxSegmentLength',
        );
      }
      if (!_segmentAlphabet.hasMatch(segment)) {
        throw SessionError(
          'invalid path',
          'segment "$segment" has characters outside A-Z a-z 0-9 _ . : -',
        );
      }
    }
    if (!roots.contains(segments.first)) {
      throw SessionError(
        'invalid path',
        'unknown root "${segments.first}"; expected one of ${roots.join(', ')}',
      );
    }
    return SessionPath._(List.unmodifiable(segments));
  }

  /// The empty path, which denotes the root of the tree.
  static const SessionPath empty = SessionPath._([]);

  /// The top-level subtree names of the current format version.
  static const Set<String> roots = {
    'meta',
    'body',
    'scratch',
    'checkpoints',
    'jobs',
    'collectors',
    'results',
  };

  /// The maximum number of segments in a path.
  static const int maxSegments = 32;

  /// The maximum number of characters in one segment.
  static const int maxSegmentLength = 128;

  /// The segments of this path, empty for [empty].
  final List<String> segments;

  /// Whether this is the empty (root) path.
  bool get isEmpty => segments.isEmpty;

  /// The name of the top-level subtree this path lies in.
  ///
  /// Throws a [StateError] for [empty].
  String get root => segments.first;

  @override
  String toString() => segments.join('/');
}
