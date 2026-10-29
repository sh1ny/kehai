/// The cancellation owner and commit point of a browser login (design D3).
///
/// One [LoginController] per login owns cancellation: the 10-minute deadline,
/// Ctrl-C and any caller-supplied cancel all trip its `CancelToken`, and every
/// pending step of the login listens to it. The commit begins when the login,
/// holding `auth.lock` with the token not tripped, calls [commit]. From then
/// the token is ignored, so a trip during the atomic replace is reported after
/// success (spec *Interrupt during commit*).
library;

import 'dart:async';

import '../provider/provider.dart' show CancelToken;
import 'openai_constants.dart';

/// A login that ended without storing a complete sign-in, or that stored one
/// and still reports a problem (plan usage not allowed).
///
/// [message] is the one sanitized line the command prints to stderr. It is
/// composed from Kehai templates and validated values only (credential-store
/// *Locally composed failure text*).
final class LoginFailure implements Exception {
  /// Creates a failure with the line to print.
  const LoginFailure(this.message);

  /// The message printed for a login that timed out.
  static const String timedOutMessage = 'login timed out';

  /// The message printed for a login cancelled by the user.
  static const String cancelledMessage = 'login cancelled';

  /// The message printed for a login rejected at the commit check.
  static const String staleMessage =
      'login failed: another login or logout happened meanwhile; run kehai '
      'login openai again';

  /// The line to print.
  final String message;

  @override
  String toString() => 'LoginFailure: $message';
}

/// Owns the cancel token, the deadline and the commit point of one login.
final class LoginController {
  /// Creates a controller whose deadline starts now.
  ///
  /// [cancel] defaults to a fresh token; a caller that wants to trip the login
  /// itself passes its own. [interrupts] is the Ctrl-C stream: its first event
  /// cancels the login. The deadline is [deadline].
  LoginController({
    CancelToken? cancel,
    this.deadline = openAiLoginDeadline,
    Stream<Object?>? interrupts,
  }) : token = cancel ?? CancelToken() {
    _timer = Timer(deadline, () {
      _timedOut = true;
      token.cancel();
    });
    _interrupts = interrupts?.listen((_) => token.cancel());
  }

  /// The token every pending step listens to.
  final CancelToken token;

  /// How long the login may wait before it times out.
  final Duration deadline;

  Timer? _timer;
  StreamSubscription<Object?>? _interrupts;
  bool _timedOut = false;
  bool _committed = false;

  /// Whether the deadline, rather than the user, tripped the token.
  bool get timedOut => _timedOut;

  /// Whether the commit has begun.
  bool get committed => _committed;

  /// Whether pending work must stop: the token is tripped and the commit has
  /// not begun.
  bool get isCancelled => !_committed && token.isCancelled;

  /// Throws the cancellation or timeout [LoginFailure] if [isCancelled].
  void checkpoint() {
    if (isCancelled) throw cancellation();
  }

  /// The failure to report for the current cancellation.
  LoginFailure cancellation() => LoginFailure(
    _timedOut ? LoginFailure.timedOutMessage : LoginFailure.cancelledMessage,
  );

  /// Runs [replace], the atomic credential replacement, as the commit.
  ///
  /// Throws the cancellation first if the token is already tripped. Otherwise
  /// the commit begins: [isCancelled] stays `false` from here on, even if the
  /// token trips while [replace] runs.
  T commit<T>(T Function() replace) {
    checkpoint();
    _committed = true;
    return replace();
  }

  /// Stops the deadline timer and the interrupt subscription.
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    final subscription = _interrupts;
    _interrupts = null;
    await subscription?.cancel();
  }
}
