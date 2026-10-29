/// Process settings read from the environment (design D1, D11).
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../auth/credential_backend.dart';
import '../auth/dpapi_backend.dart';
import '../auth/openai_constants.dart';
import '../auth/posix_file_backend.dart';

/// The environment variable that overrides the Kehai home.
const String homeVariable = 'KEHAI_HOME';

/// The environment variable that overrides the OpenAI issuer (loopback only).
const String issuerVariable = 'KEHAI_OPENAI_ISSUER';

/// The environment variable that overrides the API base (loopback only).
const String apiBaseVariable = 'KEHAI_OPENAI_API_BASE';

/// A setting that is missing or not allowed.
///
/// The commands report it as a usage error (exit code 64).
final class SettingsError implements Exception {
  /// Creates an error with the line to print.
  const SettingsError(this.message);

  /// The sanitized line to print.
  final String message;

  @override
  String toString() => 'SettingsError: $message';
}

/// The home directory and OpenAI endpoints a command works with.
final class KehaiSettings {
  /// Creates settings from explicit values.
  const KehaiSettings({
    required this.home,
    required this.issuer,
    required this.apiBase,
    required this.overridden,
  });

  /// Reads the settings from [environment].
  ///
  /// The home is `KEHAI_HOME`, else `.kehai` under the user's home directory
  /// (`USERPROFILE` on Windows, `HOME` elsewhere). `KEHAI_OPENAI_ISSUER` and
  /// `KEHAI_OPENAI_API_BASE` replace the production URLs only when their host
  /// is `127.0.0.1` or `localhost`, so a stray variable can never send a token
  /// to another host.
  ///
  /// Throws a [SettingsError] when no home can be found or an override is not
  /// a loopback URL.
  factory KehaiSettings.fromEnvironment(
    Map<String, String> environment, {
    bool? isWindows,
  }) {
    final issuer = _override(environment, issuerVariable);
    final apiBase = _override(environment, apiBaseVariable);
    return KehaiSettings(
      home: _home(environment, isWindows ?? Platform.isWindows),
      issuer: issuer ?? openAiIssuer,
      apiBase: apiBase ?? openAiApiBase,
      overridden: issuer != null || apiBase != null,
    );
  }

  /// The Kehai home directory, as configured.
  final String home;

  /// The OpenAI auth server.
  final String issuer;

  /// The API base URL, without a trailing slash.
  final String apiBase;

  /// Whether an endpoint is overridden, which is possible on loopback only.
  final bool overridden;

  /// Returns the platform credential backend: DPAPI on Windows, the private
  /// file elsewhere.
  CredentialBackend createBackend({bool? isWindows}) =>
      (isWindows ?? Platform.isWindows) ? DpapiBackend() : PosixFileBackend();
}

String _home(Map<String, String> environment, bool isWindows) {
  final configured = environment[homeVariable];
  if (configured != null && configured.isNotEmpty) return configured;
  final user = environment[isWindows ? 'USERPROFILE' : 'HOME'];
  if (user == null || user.isEmpty) {
    throw SettingsError(
      'cannot find the home directory; set $homeVariable '
      '(${isWindows ? 'USERPROFILE' : 'HOME'} is not set)',
    );
  }
  return (isWindows ? p.windows : p.posix).join(user, '.kehai');
}

String? _override(Map<String, String> environment, String name) {
  final value = environment[name];
  if (value == null || value.isEmpty) return null;
  final uri = Uri.tryParse(value);
  const hosts = {'127.0.0.1', 'localhost'};
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      !hosts.contains(uri.host) ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    throw SettingsError(
      '$name must be an http or https URL whose host is 127.0.0.1 or '
      'localhost',
    );
  }
  return value.replaceFirst(RegExp(r'/+$'), '');
}
