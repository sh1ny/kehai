/// Backdates the stored access token expiry, for the forced-refresh check.
///
/// ```sh
/// dart run tool/expire_credentials.dart
/// ```
///
/// The record is encrypted with DPAPI on Windows, so `expires_at` cannot be
/// edited by hand there. This tool sets it one hour in the past under
/// `auth.lock` and advances the generation, so the next `kehai doctor` must
/// refresh silently. It prints no token.
library;

import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:kehai/src/cli/settings.dart';

Future<void> main() async {
  final KehaiSettings settings;
  try {
    settings = KehaiSettings.fromEnvironment(Platform.environment);
  } on SettingsError catch (e) {
    stderr.writeln('expire: ${e.message}');
    exitCode = 64;
    return;
  }
  final store = CredentialStore(
    home: settings.home,
    backend: settings.createBackend(),
  );
  try {
    final lock = await store.acquireLock();
    try {
      final record = store.load();
      final tokens = record?.tokens;
      if (record == null || tokens == null) {
        stderr.writeln('expire: not logged in');
        exitCode = 1;
        return;
      }
      final expiresAt = DateTime.now().toUtc().subtract(
        const Duration(hours: 1),
      );
      store.replace(
        CredentialRecord(
          hostId: record.hostId,
          generation: record.generation + 1,
          registration: record.registration,
          tokens: CredentialTokens(
            idToken: tokens.idToken,
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: expiresAt,
            scopes: tokens.scopes,
            savedAt: tokens.savedAt,
            lastRefresh: tokens.lastRefresh,
          ),
        ),
      );
      stdout.writeln('expires_at set to ${expiresAt.toIso8601String()}');
    } finally {
      lock.release();
    }
  } on CredentialStoreError catch (e) {
    stderr.writeln('expire: ${e.reason}');
    exitCode = 1;
  }
}
