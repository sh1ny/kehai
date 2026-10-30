/// The retry policy for model requests (design D8).
library;

import '../provider/provider.dart';

/// The waits before retries one to four.
const List<Duration> retryDelays = [
  Duration(seconds: 1),
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
];

/// The longest `Retry-After` the driver waits for.
const Duration maxRetryAfter = Duration(seconds: 60);

/// Decides whether a failed request is sent again.
abstract interface class RetryPolicy {
  /// How long to wait before send number `attempts + 1`, or null to give up.
  ///
  /// [attempts] counts the sends so far, so the first failure asks with 1.
  Duration? delayFor(ProviderFailure failure, int attempts);
}

/// The policy that never retries.
final class NoRetry implements RetryPolicy {
  /// Creates the policy.
  const NoRetry();

  @override
  Duration? delayFor(ProviderFailure failure, int attempts) => null;
}

/// Retries only failures that prove no work started: `rate_limited`, and
/// `network` before the body was sent.
///
/// It waits 1, 2, 4 and 8 s, or the server's `Retry-After` when that is at most
/// [maxRetryAfter]; a longer wait is not retried.
final class BoundedRetry implements RetryPolicy {
  /// Creates the policy.
  const BoundedRetry();

  @override
  Duration? delayFor(ProviderFailure failure, int attempts) {
    if (!isRetryable(failure) || attempts > retryDelays.length) return null;
    final asked = failure.retryAfter;
    if (asked == null) return retryDelays[attempts - 1];
    return asked <= maxRetryAfter ? asked : null;
  }
}

/// Whether [failure] proves that no work started on the backend.
bool isRetryable(ProviderFailure failure) => switch (failure.kind) {
  ProviderFailureKind.rateLimited => true,
  ProviderFailureKind.network => !failure.sent,
  _ => false,
};
