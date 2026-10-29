/// The `kehai doctor` report (design D1, D8; spec *Doctor report*).
library;

import '../auth/auth_failure.dart';
import '../auth/credential_error.dart';
import '../auth/credential_store.dart';
import '../auth/openai_constants.dart';
import '../auth/refresher.dart';
import '../provider/chatgpt_adapter.dart';
import '../provider/provider.dart';

/// The most model lines doctor prints before it only counts the rest.
const int doctorMaxModelLines = 200;

const int _maxFieldLength = 120;

/// Replaces control characters in [text] and cuts it to a printable length.
///
/// Model ids and names come from the backend; this keeps a hostile value from
/// moving the cursor or forging report lines.
String printable(String text) {
  final clean = String.fromCharCodes([
    for (final unit in text.runes)
      if (unit < 0x20 || (unit >= 0x7f && unit <= 0x9f)) 0x3f else unit,
  ]);
  return clean.length <= _maxFieldLength
      ? clean
      : '${clean.substring(0, _maxFieldLength)}...';
}

/// Prints the doctor report to [out] and returns the exit code.
///
/// Sections, in order: backend and path, login and plan-usage state, account,
/// expiry, refresh result, and the model list capped at
/// [doctorMaxModelLines] lines with a count of the rest. It returns `0` only
/// when credentials load, are valid or refresh, and the model list is not
/// empty; otherwise it returns `1` and writes one summary line to [err]. No
/// token is ever printed.
///
/// [backendName] and [path] describe the credential storage. [issuer] and
/// [apiBase] are the endpoints; [now] is a test seam.
Future<int> runDoctor({
  required CredentialStore store,
  required String backendName,
  required String path,
  required StringSink out,
  required StringSink err,
  String issuer = openAiIssuer,
  String apiBase = openAiApiBase,
  DateTime Function()? now,
}) async {
  final clock = now ?? (() => DateTime.now().toUtc());
  out
    ..writeln('backend: $backendName')
    ..writeln('path: $path');

  final CredentialRecord? record;
  try {
    record = store.load();
  } on CredentialStoreError catch (e) {
    out.writeln('login: unavailable (${printable(e.message)})');
    err.writeln('doctor: credentials unavailable: ${printable(e.message)}');
    return 1;
  }

  final registration = record?.registration;
  final tokens = record?.tokens;
  if (tokens == null) {
    return _notLoggedIn(registration, out, err);
  }

  out
    ..writeln('login: logged in')
    ..writeln('plan usage: enabled');
  _account(registration, out);

  final due = tokens.expiresAt.difference(clock()) < openAiRefreshDueWindow;
  final refresher = Refresher(store: store, issuer: issuer);
  final Credentials credentials;
  try {
    credentials = await refresher.credentials();
  } on AuthFailure catch (failure) {
    out
      ..writeln('expiry: ${tokens.expiresAt.toIso8601String()}')
      ..writeln(
        '${due ? 'refresh' : 'credentials'}: failed '
        '(${printable(failure.message)})',
      )
      ..writeln('models: unavailable');
    err.writeln('doctor: ${printable(failure.message)}');
    return 1;
  }
  out
    ..writeln('expiry: ${credentials.expiresAt.toIso8601String()}')
    ..writeln('refresh: ${due ? 'succeeded' : 'not needed'}');

  final List<ModelInfo> models;
  try {
    models = await ChatGptAdapter(
      refresher: refresher,
      apiBase: apiBase,
    ).listModels();
  } on ProviderFailure catch (failure) {
    out.writeln('models: unavailable (${printable(failure.message)})');
    err.writeln('doctor: ${printable(failure.message)}');
    return 1;
  }
  if (models.isEmpty) {
    out.writeln('models: no models available');
    err.writeln('doctor: no models available for this account');
    return 1;
  }
  out.writeln('models: ${models.length}');
  for (final model in models.take(doctorMaxModelLines)) {
    out.writeln('  ${printable(model.id)}  ${printable(model.name)}');
  }
  if (models.length > doctorMaxModelLines) {
    out.writeln('  ... and ${models.length - doctorMaxModelLines} more');
  }
  return 0;
}

int _notLoggedIn(
  CredentialRegistration? registration,
  StringSink out,
  StringSink err,
) {
  out.writeln('login: not logged in');
  final String reason;
  if (registration != null && !registration.planUsageEnabled) {
    out
      ..writeln('plan usage: disabled')
      ..writeln(
        'ChatGPT plan usage not enabled; run '
        'kehai login openai --enable-plan-usage',
      );
    reason = 'ChatGPT plan usage not enabled';
  } else {
    out
      ..writeln('plan usage: ${registration == null ? 'unknown' : 'enabled'}')
      ..writeln('Run kehai login openai to sign in.');
    reason = 'not logged in';
  }
  _account(registration, out);
  out.writeln('models: unavailable');
  err.writeln('doctor: $reason');
  return 1;
}

void _account(CredentialRegistration? registration, StringSink out) {
  if (registration == null) return;
  out
    ..writeln('account email: ${printable(registration.email)}')
    ..writeln('account subject: ${printable(registration.subject)}');
  if (registration.plan case final plan?) {
    out.writeln('account plan: ${printable(plan)}');
  }
}
