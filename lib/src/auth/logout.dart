/// Logout and remote revocation (design D6a).
library;

import 'dart:async';

import '../provider/provider.dart' show CancelToken;
import 'auth_error.dart';
import 'credential_store.dart';
import 'oauth_client.dart';
import 'oidc.dart';
import 'openai_constants.dart';

const String _notLoggedIn = 'not logged in';

/// Logs out of OpenAI under the credential lock and returns the line to print.
///
/// Without a token set nothing is sent to the network. A record that exists
/// (a host id only, or a registration without tokens) is written back with
/// `generation + 1`, so a login pending in another process is rejected at its
/// commit; with no record at all nothing is written. With a token set, the
/// issuer's discovery document yields the revocation endpoint and the refresh
/// token is revoked with a form `POST`. The record is then rewritten in a
/// `finally` without tokens and with `generation + 1`, so a failure or
/// [cancel] still clears them. [forget] also drops the registration and keeps
/// the host id.
///
/// [timeout] bounds discovery and revocation together. The result is one of
/// `logged out`, the not-confirmed line (which names the HTTP status, or
/// `network` when no response arrived), `registration forgotten` and
/// `not logged in`; every one of them is a success.
///
/// Throws a `CredentialStoreError` when the home is unsafe or the lock cannot
/// be taken.
Future<String> logoutOpenAi({
  required CredentialStore store,
  String issuer = openAiIssuer,
  bool forget = false,
  CancelToken? cancel,
  Duration timeout = openAiRequestTimeout,
}) async {
  final lock = await store.acquireLock(isCancelled: () => false);
  try {
    final record = store.load();
    if (record == null) return _notLoggedIn;
    final tokens = record.tokens;
    final registration = record.registration;
    if (tokens == null || registration == null) {
      _write(store, record, forget: forget);
      return forget && registration != null
          ? 'registration forgotten'
          : _notLoggedIn;
    }
    final RevocationResult? result;
    try {
      result = await _revoke(
        issuer: issuer,
        refreshToken: tokens.refreshToken,
        clientId: registration.clientId,
        cancel: cancel,
        timeout: timeout,
      );
    } finally {
      _write(store, record, forget: forget);
    }
    if (result?.confirmed ?? false) return 'logged out';
    return 'logged out locally; remote revocation was not confirmed '
        '(${result?.status ?? 'network'}). '
        'You can disconnect Kehai in ChatGPT settings.';
  } finally {
    lock.release();
  }
}

void _write(
  CredentialStore store,
  CredentialRecord record, {
  required bool forget,
}) {
  store.replace(
    CredentialRecord(
      hostId: record.hostId,
      generation: record.generation + 1,
      registration: forget ? null : record.registration,
    ),
  );
}

/// Discovers the revocation endpoint and revokes the token, within [timeout].
///
/// Returns `null` when discovery fails, so no revocation was sent. Never
/// throws for a network, discovery or cancellation failure.
Future<RevocationResult?> _revoke({
  required String issuer,
  required String refreshToken,
  required String clientId,
  required CancelToken? cancel,
  required Duration timeout,
}) async {
  final abort = Completer<void>();
  final timer = Timer(timeout, () {
    if (!abort.isCompleted) abort.complete();
  });
  unawaited(
    cancel?.whenCancelled.then((_) {
      if (!abort.isCompleted) abort.complete();
    }),
  );
  try {
    final OidcDiscovery discovery;
    try {
      discovery = await OidcClient(
        issuer,
        cancelled: abort.future,
        timeout: timeout,
      ).discover();
    } on AuthError {
      return null;
    }
    return await OAuthClient(
      issuer,
      cancelled: abort.future,
      timeout: timeout,
    ).revoke(
      discovery.revocationEndpoint,
      refreshToken: refreshToken,
      clientId: clientId,
    );
  } finally {
    timer.cancel();
  }
}
