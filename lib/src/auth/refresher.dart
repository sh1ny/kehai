/// Credential observation and single-flight refresh (design D4, D5).
library;

import 'dart:async';

import 'auth_failure.dart';
import 'credential_error.dart';
import 'credential_store.dart';
import 'failure_text.dart';
import 'oauth_client.dart';
import 'openai_constants.dart';

/// The credentials a request uses.
final class Credentials {
  /// Creates credentials from a stored record.
  const Credentials({
    required this.accessToken,
    required this.expiresAt,
    required this.hostId,
    required this.generation,
    required this.registration,
    required this.idToken,
  });

  /// The access token to send.
  final String accessToken;

  /// When [accessToken] expires, in UTC.
  final DateTime expiresAt;

  /// The persisted host id.
  final String hostId;

  /// The record generation these credentials were read at.
  final int generation;

  /// The client registration and account.
  final CredentialRegistration registration;

  /// The stored ID token.
  final String idToken;
}

/// Hands out credentials and refreshes them once per process and per home.
///
/// One [Refresher] serves all callers of a process. [credentials] reads the
/// stored record before every request, so an external logout or account change
/// is seen at once; only a due refresh takes `auth.lock`. The refresher never
/// retries a refresh.
final class Refresher {
  /// Creates a refresher over [store] for [issuer].
  ///
  /// [cancelled] is a minimal abort signal for the HTTP request and the lock
  /// wait. [now] defaults to the system clock and is a test seam.
  Refresher({
    required this.store,
    this.issuer = openAiIssuer,
    Future<void>? cancelled,
    DateTime Function()? now,
  }) : _now = now ?? (() => DateTime.now().toUtc()),
       _oauth = OAuthClient(issuer, cancelled: cancelled) {
    unawaited(cancelled?.then((_) => _cancelled = true));
  }

  /// The credential store.
  final CredentialStore store;

  /// The issuer of the token endpoint.
  final String issuer;

  final DateTime Function() _now;
  final OAuthClient _oauth;
  final FailureText _text = FailureText();
  bool _cancelled = false;
  Future<Credentials>? _inFlight;

  /// Returns credentials for a new request, refreshing first when due.
  ///
  /// The stored record is loaded on every call, without the lock. With no
  /// token set it fails without a backend request: `not_permitted` naming
  /// `kehai login openai --enable-plan-usage` when plan usage is disabled,
  /// else `reauth_required`. A refresh is due when the access token expires in
  /// under five minutes; concurrent callers share one refresh.
  ///
  /// Throws an [AuthFailure].
  Future<Credentials> credentials() async {
    final record = _load();
    final tokens = record?.tokens;
    if (record == null || tokens == null) throw _noTokens(record);
    final due = tokens.expiresAt.difference(_now()) < openAiRefreshDueWindow;
    if (!due) return _credentials(record, tokens);
    return _singleFlight(tokens.accessToken);
  }

  /// Refreshes after the backend rejected [staleAccessToken] with `401`.
  ///
  /// Takes the lock and reloads the record. If the stored access token already
  /// differs, it is returned and no refresh is sent; otherwise a refresh runs
  /// even though the token is not due. Joins a refresh already in flight.
  ///
  /// Throws an [AuthFailure].
  Future<Credentials> refreshAfterUnauthorized(String staleAccessToken) =>
      _singleFlight(staleAccessToken);

  Future<Credentials> _singleFlight(String staleAccessToken) {
    final existing = _inFlight;
    if (existing != null) return existing;
    // `whenComplete` runs before the result reaches any waiter, so a failure
    // is never served to a caller that arrives afterwards.
    final future = _locked(staleAccessToken).whenComplete(() {
      _inFlight = null;
    });
    _inFlight = future;
    return future;
  }

  Future<Credentials> _locked(String staleAccessToken) async {
    final CredentialLock lock;
    try {
      lock = await store.acquireLock(isCancelled: () => _cancelled);
    } on CredentialStoreError catch (e) {
      throw _lockFailure(e);
    }
    try {
      final record = _load();
      final tokens = record?.tokens;
      if (record == null || tokens == null) throw _noTokens(record);
      if (tokens.accessToken != staleAccessToken) {
        return _credentials(record, tokens);
      }
      return await _refresh(record, tokens);
    } finally {
      lock.release();
    }
  }

  Future<Credentials> _refresh(
    CredentialRecord record,
    CredentialTokens tokens,
  ) async {
    final registration = record.registration!;
    final secrets = [tokens.accessToken, tokens.idToken];
    final TokenGrant grant;
    try {
      grant = await _oauth.refresh(
        clientId: registration.clientId,
        refreshToken: tokens.refreshToken,
        secrets: secrets,
      );
    } on AuthFailure catch (failure) {
      if (failure.kind == FailureKind.reauthRequired) {
        _clearIfUnchanged(tokens.refreshToken, disablePlanUsage: false);
      }
      rethrow;
    }

    final scopes = grant.scopes;
    if (scopes != null && !scopes.contains(openAiPlanUsageScope)) {
      _clearIfUnchanged(tokens.refreshToken, disablePlanUsage: true);
      throw AuthFailure.composed(
        FailureKind.notPermitted,
        _text.compose(
          FailureKind.notPermitted,
          detail:
              'ChatGPT plan usage is no longer granted. Run kehai login '
              'openai --enable-plan-usage.',
        ),
      );
    }

    final now = _now();
    final updated = CredentialRecord(
      hostId: record.hostId,
      generation: record.generation,
      registration: registration,
      tokens: CredentialTokens(
        idToken: tokens.idToken,
        accessToken: grant.accessToken,
        refreshToken: grant.refreshToken ?? tokens.refreshToken,
        expiresAt: now.add(grant.expiresIn),
        scopes: scopes ?? tokens.scopes,
        savedAt: tokens.savedAt,
        lastRefresh: now,
      ),
    );
    try {
      store.replace(updated);
    } on CredentialStoreError catch (e) {
      // The server rotated the token and the replacement could not be kept.
      throw AuthFailure.composed(
        FailureKind.reauthRequired,
        _text.compose(
          FailureKind.reauthRequired,
          detail:
              'The refreshed credentials could not be saved (${e.reason}). '
              'Run kehai login openai.',
        ),
      );
    }
    return _credentials(updated, updated.tokens!);
  }

  /// Reloads the record and, if it still holds [rejectedRefreshToken], clears
  /// the token set, marking plan usage disabled when [disablePlanUsage].
  ///
  /// A token set stored by another process meanwhile is kept. Still holding
  /// `auth.lock`, so the reload and write cannot interleave with a login.
  void _clearIfUnchanged(
    String rejectedRefreshToken, {
    required bool disablePlanUsage,
  }) {
    final CredentialRecord? current;
    try {
      current = store.load();
    } on CredentialStoreError {
      return;
    }
    final registration = current?.registration;
    if (current == null ||
        registration == null ||
        current.tokens?.refreshToken != rejectedRefreshToken) {
      return;
    }
    try {
      store.replace(
        CredentialRecord(
          hostId: current.hostId,
          generation: current.generation,
          registration: disablePlanUsage
              ? CredentialRegistration(
                  issuer: registration.issuer,
                  clientId: registration.clientId,
                  subject: registration.subject,
                  email: registration.email,
                  plan: registration.plan,
                  planUsageEnabled: false,
                )
              : registration,
        ),
      );
    } on CredentialStoreError {
      // The original failure is the one to report; the next call retries.
    }
  }

  CredentialRecord? _load() {
    try {
      return store.load();
    } on CredentialStoreError catch (e) {
      throw AuthFailure.composed(
        FailureKind.reauthRequired,
        _text.compose(
          FailureKind.reauthRequired,
          detail:
              'The stored credentials could not be used (${e.reason}). '
              'Run kehai login openai.',
        ),
      );
    }
  }

  AuthFailure _noTokens(CredentialRecord? record) {
    if (record?.registration case final registration?
        when !registration.planUsageEnabled) {
      return AuthFailure.composed(
        FailureKind.notPermitted,
        _text.compose(
          FailureKind.notPermitted,
          detail:
              'ChatGPT plan usage is not enabled. Run kehai login openai '
              '--enable-plan-usage.',
        ),
      );
    }
    return AuthFailure.composed(
      FailureKind.reauthRequired,
      _text.compose(FailureKind.reauthRequired),
    );
  }

  AuthFailure _lockFailure(CredentialStoreError error) {
    if (error.reason == CredentialStoreError.cancelled) {
      return AuthFailure.composed(
        FailureKind.cancelled,
        _text.compose(FailureKind.cancelled),
      );
    }
    final busy = error.reason == CredentialStoreError.lockBusy;
    return AuthFailure.composed(
      FailureKind.network,
      _text.compose(
        FailureKind.network,
        detail: busy
            ? 'Credential lock busy: another Kehai process holds it.'
            : 'The credential lock is unavailable (${error.reason}).',
      ),
    );
  }

  Credentials _credentials(CredentialRecord record, CredentialTokens tokens) =>
      Credentials(
        accessToken: tokens.accessToken,
        expiresAt: tokens.expiresAt,
        hostId: record.hostId,
        generation: record.generation,
        registration: record.registration!,
        idToken: tokens.idToken,
      );
}
