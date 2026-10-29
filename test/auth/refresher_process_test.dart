import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kehai/src/auth/credential_error.dart';
import 'package:kehai/src/auth/credential_store.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_openai.dart';

String _fingerprint(String token) =>
    sha256.convert(utf8.encode(token)).toString().substring(0, 16);

/// A Dart process running one of the `test/fixtures` scripts.
final class _Child {
  _Child._(this.process);

  final Process process;
  final List<String> lines = [];

  static Future<_Child> start(String script, List<String> args) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      'run',
      'test/fixtures/$script',
      ...args,
    ]);
    final child = _Child._(process);
    addTearDown(child.stop);
    unawaited(process.stderr.drain<void>());
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(child.lines.add);
    return child;
  }

  /// Waits for a line starting with [prefix] and returns the rest of it.
  Future<String> waitFor(
    String prefix, {
    Duration timeout = const Duration(seconds: 90),
  }) async {
    final watch = Stopwatch()..start();
    while (watch.elapsed < timeout) {
      for (final line in lines) {
        if (line.startsWith(prefix)) return line.substring(prefix.length);
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    throw TimeoutException('no "$prefix" line; saw $lines');
  }

  void send(String line) => process.stdin.writeln(line);

  /// Stops the `dart run` wrapper. A VM it started is stopped by its pid.
  Future<void> stop() async {
    process.kill();
    await process.exitCode;
  }
}

CredentialRecord _record() {
  final now = DateTime.now().toUtc();
  return CredentialRecord(
    hostId: 'urn:uuid:11111111-2222-3333-4444-555555555555',
    generation: 4,
    registration: const CredentialRegistration(
      issuer: 'https://auth.openai.com',
      clientId: 'client-xyz',
      subject: 'user-123',
      email: 'user@example.com',
      plan: 'plus',
      planUsageEnabled: true,
    ),
    tokens: CredentialTokens(
      idToken: 'old-id-token',
      accessToken: 'old-access',
      refreshToken: 'old-refresh',
      expiresAt: now.add(const Duration(minutes: 1)),
      scopes: const ['openid', 'chatgpt.tokens.use.direct'],
      savedAt: now.subtract(const Duration(days: 1)),
      lastRefresh: now.subtract(const Duration(hours: 1)),
    ),
  );
}

void main() {
  late Directory tmp;
  late String home;
  late CredentialStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kehai_refresh_proc_');
    if (!Platform.isWindows) Process.runSync('chmod', ['700', tmp.path]);
    home = p.join(tmp.path, 'home');
    store = CredentialStore(home: home);
    store.replace(_record());
  });

  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // A child may still be exiting; the temp directory is disposable.
    }
  });

  const slow = Timeout(Duration(minutes: 3));

  test(
    'two processes refreshing send exactly one refresh',
    timeout: slow,
    () async {
      final fake = await FakeOpenAi.start();
      // Slow enough that the second process reaches the lock while the first
      // holds it.
      fake.tokenScripts.add(
        TokenScript.success(delay: const Duration(milliseconds: 800)),
      );

      final children = await Future.wait([
        _Child.start('refresh_once.dart', [home, fake.issuer]),
        _Child.start('refresh_once.dart', [home, fake.issuer]),
      ]);
      await Future.wait(children.map((c) => c.waitFor('READY')));
      for (final child in children) {
        child.send('go');
      }
      final tokens = await Future.wait(
        children.map((c) => c.waitFor('TOKEN ')),
      );

      expect(fake.tokenRequests, hasLength(1));
      expect(tokens.toSet(), {_fingerprint('access-1')});
      expect(store.load()!.tokens!.accessToken, 'access-1');
      expect(store.load()!.generation, 4);
    },
  );

  test(
    'killed lock holder does not block the next process',
    timeout: slow,
    () async {
      final holder = await _Child.start('hold_auth_lock.dart', [home]);
      final holderPid = int.parse(await holder.waitFor('HELD '));

      // While the holder lives, another process cannot take the lock.
      final contender = CredentialStore(
        home: home,
        lockDeadline: const Duration(milliseconds: 300),
        lockPollInterval: const Duration(milliseconds: 30),
      );
      await expectLater(
        contender.acquireLock(),
        throwsA(
          isA<CredentialStoreError>().having(
            (e) => e.reason,
            'reason',
            CredentialStoreError.lockBusy,
          ),
        ),
      );

      Process.killPid(
        holderPid,
        Platform.isWindows ? ProcessSignal.sigterm : ProcessSignal.sigkill,
      );
      holder.process.kill();

      final next = await _Child.start('hold_auth_lock.dart', [home, 'probe']);
      final loaded = await next.waitFor('LOADED ');
      expect(loaded, '4 ${_fingerprint('old-access')}');
    },
  );
}
