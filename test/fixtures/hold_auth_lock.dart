// Takes `auth.lock` in the home argv[0].
//
// Mode argv[1], default `hold`:
//   hold   acquires the lock, prints `HELD <pid>` and keeps it until killed.
//   probe  acquires the lock (waiting up to 10 s), loads the record, prints
//          `LOADED <generation> <fingerprint>` (the first 16 hex digits of the
//          access token's SHA-256) and releases the lock.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kehai/src/auth/credential_store.dart';

Future<void> main(List<String> args) async {
  // Keep the isolate alive while holding the lock.
  Timer.periodic(const Duration(hours: 1), (_) {});
  final probe = args.length > 1 && args[1] == 'probe';
  final store = CredentialStore(
    home: args[0],
    lockDeadline: const Duration(seconds: 10),
  );
  final lock = await store.acquireLock();
  if (!probe) {
    stdout.writeln('HELD $pid');
    await stdout.flush();
    return;
  }
  final record = store.load()!;
  final digest = sha256.convert(utf8.encode(record.tokens!.accessToken));
  stdout.writeln(
    'LOADED ${record.generation} ${digest.toString().substring(0, 16)}',
  );
  await stdout.flush();
  lock.release();
  exit(0);
}
