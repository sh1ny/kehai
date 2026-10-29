// Refreshes the credentials in the home argv[0] against the issuer argv[1].
//
// Prints `READY`, waits for a line on stdin, then asks a `Refresher` for
// credentials and prints `TOKEN <fingerprint>` (the first 16 hex digits of the
// access token's SHA-256, never the token) or `FAILED <kind> <message>`.
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kehai/src/auth/auth_failure.dart';
import 'package:kehai/src/auth/credential_store.dart';
import 'package:kehai/src/auth/refresher.dart';

Future<void> main(List<String> args) async {
  final store = CredentialStore(home: args[0]);
  final refresher = Refresher(store: store, issuer: args[1]);
  stdout.writeln('READY');
  await stdout.flush();
  await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
  try {
    final credentials = await refresher.credentials();
    final digest = sha256.convert(utf8.encode(credentials.accessToken));
    stdout.writeln('TOKEN ${digest.toString().substring(0, 16)}');
  } on AuthFailure catch (failure) {
    stdout.writeln('FAILED ${failure.kind.wire} ${failure.message}');
  }
  await stdout.flush();
  exit(0);
}
