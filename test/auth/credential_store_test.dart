import 'dart:convert';
import 'dart:io';

import 'package:kehai/src/auth/credential_backend.dart';
import 'package:kehai/src/auth/credential_error.dart';
import 'package:kehai/src/auth/credential_store.dart';
import 'package:kehai/src/auth/dpapi_backend.dart';
import 'package:kehai/src/auth/home_trust.dart';
import 'package:kehai/src/auth/posix_ffi.dart';
import 'package:kehai/src/auth/posix_file_backend.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

const _access = 'access-token-AAAA1111';
const _refresh = 'refresh-token-BBBB2222';
const _idToken = 'id-token-CCCC3333';

CredentialRecord _record({String access = _access, int generation = 3}) =>
    CredentialRecord(
      hostId: 'urn:uuid:11111111-2222-3333-4444-555555555555',
      generation: generation,
      registration: const CredentialRegistration(
        issuer: 'https://auth.openai.com',
        clientId: 'client-xyz',
        subject: 'user-123',
        email: 'a@example.com',
        plan: 'plus',
        planUsageEnabled: true,
      ),
      tokens: CredentialTokens(
        idToken: _idToken,
        accessToken: access,
        refreshToken: _refresh,
        expiresAt: DateTime.utc(2026, 10, 29, 12),
        scopes: const ['openid', 'chatgpt.tokens.use.direct'],
        savedAt: DateTime.utc(2026, 10, 29, 11),
        lastRefresh: DateTime.utc(2026, 10, 29, 11, 30),
      ),
    );

/// Builds the platform's backend with optional fault injection.
CredentialBackend _backend({
  bool failSecureWrite = false,
  void Function()? beforeRename,
}) {
  if (Platform.isWindows) {
    return DpapiBackend(
      protect: failSecureWrite
          ? (_) => throw const CredentialStoreError(
              CredentialStoreError.unavailable,
              'injected protect failure',
            )
          : null,
      beforeRename: beforeRename,
    );
  }
  return PosixFileBackend(
    createPrivateFile: failSecureWrite
        ? (path, bytes) => throw const CredentialStoreError(
            CredentialStoreError.unavailable,
            'injected open failure',
          )
        : null,
    beforeRename: beforeRename,
  );
}

String get _authName => Platform.isWindows ? 'auth.dpapi' : 'auth.json';

List<String> _names(String dir) =>
    Directory(dir)
        .listSync()
        .map((e) => p.basename(e.path))
        .where((n) => n != 'auth.lock')
        .toList();

Matcher _storeError(String reason, [String? detail]) =>
    isA<CredentialStoreError>()
        .having((e) => e.reason, 'reason', reason)
        .having((e) => e.message, 'message', contains(detail ?? ''));

void main() {
  late Directory tmp;
  late String home;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kehai_cred_');
    if (!Platform.isWindows) Process.runSync('chmod', ['700', tmp.path]);
    home = p.join(tmp.path, 'home');
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  final unixOnly = Platform.isWindows ? 'unix only' : false;
  final windowsOnly = Platform.isWindows ? false : 'windows only';

  group('record', () {
    test('round-trips through JSON', () {
      final record = _record();
      final decoded = CredentialRecord.fromJson(
        jsonDecode(jsonEncode(record.toJson())),
      );
      expect(decoded, record);
      expect(record.toJson()['version'], 1);
      expect(record.toJson()['provider'], 'openai');
    });

    test('tokens with plan usage disabled are unreadable', () {
      final json = _record().toJson();
      (json['registration']! as Map<String, Object?>)['plan_usage'] =
          'disabled';
      expect(
        () => CredentialRecord.fromJson(json),
        throwsA(_storeError(CredentialStoreError.unreadable)),
      );
    });

    test('a host-id-only record has no registration or tokens', () {
      final record = CredentialRecord.fromJson({
        'version': 1,
        'provider': 'openai',
        'host_id': 'urn:uuid:x',
        'generation': 0,
      });
      expect(record.registration, isNull);
      expect(record.tokens, isNull);
    });

    test('an unknown version is unreadable', () {
      expect(
        () => CredentialRecord.fromJson({
          'version': 2,
          'provider': 'openai',
          'host_id': 'h',
          'generation': 0,
        }),
        throwsA(_storeError(CredentialStoreError.unreadable)),
      );
    });
  });

  group('platform backend', () {
    test(
      '[unix] stored auth.json is 0600 in a 0700 home with version 1 and all '
      'three parts',
      () {
        CredentialStore(home: home).replace(_record());
        expect(FileStat.statSync(home).mode & 4095, 448);
        final file = File(p.join(home, 'auth.json'));
        expect(FileStat.statSync(file.path).mode & 4095, 384);
        final json =
            jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
        expect(json['version'], 1);
        expect(json['host_id'], startsWith('urn:uuid:'));
        expect(json['registration'], isA<Map<String, Object?>>());
        expect(json['tokens'], isA<Map<String, Object?>>());
        expect(CredentialStore(home: home).load(), _record());
      },
      skip: unixOnly,
    );

    test('[windows] auth.dpapi holds no token text and round-trips', () {
      CredentialStore(home: home).replace(_record());
      final bytes = File(p.join(home, 'auth.dpapi')).readAsBytesSync();
      final text = latin1.decode(bytes);
      for (final secret in [_access, _refresh, _idToken, 'a@example.com']) {
        expect(text, isNot(contains(secret)));
        expect(
          utf8.decode(bytes, allowMalformed: true),
          isNot(contains(secret)),
        );
      }
      expect(CredentialStore(home: home).load(), _record());
    }, skip: windowsOnly);

    test('[windows] blob fails to decrypt under another entropy', () {
      CredentialStore(home: home).replace(_record());
      final bytes = File(p.join(home, 'auth.dpapi')).readAsBytesSync();
      expect(
        () => DpapiBackend.unprotectBytes(bytes, 'kehai-openai-v2'),
        throwsA(_storeError(CredentialStoreError.unreadable)),
      );
      final other = CredentialStore(
        home: home,
        backend: DpapiBackend(entropy: 'kehai-openai-v2'),
      );
      expect(
        other.load,
        throwsA(
          isA<CredentialStoreError>()
              .having((e) => e.reason, 'reason', 'credentials unreadable')
              .having((e) => e.message, 'message', isNot(contains(_access))),
        ),
      );
      // The same entropy still reads it.
      expect(CredentialStore(home: home).load(), _record());
    }, skip: windowsOnly);
  });

  group('fail closed', () {
    test('[unix] group or other bits on auth.json refuse the load', () {
      final store = CredentialStore(home: home)..replace(_record());
      final file = p.join(home, 'auth.json');
      for (final mode in ['640', '604', '644']) {
        Process.runSync('chmod', [mode, file]);
        expect(
          store.load,
          throwsA(_storeError(CredentialStoreError.unsafePath, 'chmod 600')),
          reason: mode,
        );
      }
      Process.runSync('chmod', ['640', file]);
      expect(
        store.load,
        throwsA(
          isA<CredentialStoreError>().having(
            (e) => e.message,
            'message',
            allOf(contains(file), contains('0640'), isNot(contains(_access))),
          ),
        ),
      );
    }, skip: unixOnly);

    test(
      '[unix] symlinked home, symlinked or non-regular auth.json are refused',
      () {
        // Symlinked home.
        final real = Directory(p.join(tmp.path, 'real'))..createSync();
        Process.runSync('chmod', ['700', real.path]);
        final linkHome = p.join(tmp.path, 'linkhome');
        Link(linkHome).createSync(real.path);
        final viaLink = CredentialStore(home: linkHome);
        expect(viaLink.load, throwsA(isA<CredentialStoreError>()));
        expect(
          () => viaLink.replace(_record()),
          throwsA(isA<CredentialStoreError>()),
        );
        expect(real.listSync(), isEmpty);

        // Symlinked auth.json.
        final store = CredentialStore(home: home)..replace(_record());
        final auth = p.join(home, 'auth.json');
        final target = p.join(tmp.path, 'target.json');
        File(auth).renameSync(target);
        Link(auth).createSync(target);
        final before = File(target).readAsBytesSync();
        expect(
          store.load,
          throwsA(_storeError(CredentialStoreError.unsafePath, auth)),
        );
        expect(
          () => store.replace(_record(access: 'other')),
          throwsA(_storeError(CredentialStoreError.unsafePath, auth)),
        );
        expect(File(target).readAsBytesSync(), before);

        // Non-regular auth.json.
        Link(auth).deleteSync();
        Directory(auth).createSync();
        expect(
          store.load,
          throwsA(_storeError(CredentialStoreError.unsafePath, auth)),
        );
        expect(
          () => store.replace(_record()),
          throwsA(_storeError(CredentialStoreError.unsafePath, auth)),
        );
      },
      skip: unixOnly,
    );

    test('[unix] a home with group or other bits is refused', () {
      final store = CredentialStore(home: home)..replace(_record());
      Process.runSync('chmod', ['755', home]);
      expect(store.load, throwsA(isA<CredentialStoreError>()));
      expect(
        () => store.replace(_record()),
        throwsA(isA<CredentialStoreError>()),
      );
    }, skip: unixOnly);

    test('[unix] a home with group or other bits is refused before auth.lock '
        'is created', () async {
      final store = CredentialStore(home: home)..replace(_record());
      Process.runSync('chmod', ['755', home]);
      await expectLater(
        store.acquireLock(),
        throwsA(_storeError(CredentialStoreError.unsafePath, 'chmod 700')),
      );
      expect(File(p.join(home, 'auth.lock')).existsSync(), isFalse);
      Process.runSync('chmod', ['700', home]);
    }, skip: unixOnly);

    test('failing protect or open call stores nothing and leaves no file', () {
      final failing = CredentialStore(
        home: home,
        backend: _backend(failSecureWrite: true),
      );
      expect(
        () => failing.replace(_record()),
        throwsA(_storeError(CredentialStoreError.unavailable, 'injected')),
      );
      if (Directory(home).existsSync()) {
        expect(_names(home), isEmpty);
      }
      expect(CredentialStore(home: home).load(), isNull);
    });
  });

  group('atomic replacement', () {
    test('replacement returns new record and leaves no temp file', () {
      final store = CredentialStore(home: home)..replace(_record());
      store.replace(_record(access: 'access-token-NEW'));
      expect(store.load()!.tokens!.accessToken, 'access-token-NEW');
      expect(_names(home), [_authName]);
    });

    test('failure before rename keeps the previous record', () {
      CredentialStore(home: home).replace(_record());
      final failing = CredentialStore(
        home: home,
        backend: _backend(
          beforeRename: () => throw const FileSystemException('injected'),
        ),
      );
      expect(
        () => failing.replace(_record(access: 'access-token-LOST')),
        throwsA(isA<Object>()),
      );
      expect(CredentialStore(home: home).load(), _record());
      expect(_names(home), [_authName]);
    });
  });

  group('credential lock', () {
    test(
      'acquire creates auth.lock in the home and release is repeatable',
      () async {
        final store = CredentialStore(home: home);
        final lock = await store.acquireLock();
        expect(File(p.join(home, 'auth.lock')).existsSync(), isTrue);
        lock.release();
        lock.release();
        final again = await store.acquireLock();
        again.release();
      },
    );

    test(
      'a busy lock fails with credential lock busy at the deadline',
      () async {
        var attempts = 0;
        final store = CredentialStore(
          home: home,
          lockPollInterval: const Duration(milliseconds: 5),
          lockDeadline: const Duration(milliseconds: 60),
          tryLock: (_) {
            attempts++;
            return false;
          },
        );
        final started = DateTime.now();
        await expectLater(
          store.acquireLock(),
          throwsA(_storeError(CredentialStoreError.lockBusy)),
        );
        expect(attempts, greaterThan(2));
        expect(
          DateTime.now().difference(started),
          lessThan(const Duration(seconds: 5)),
        );
      },
    );

    test('the lock is taken once the holder lets go', () async {
      var attempts = 0;
      final store = CredentialStore(
        home: home,
        lockPollInterval: const Duration(milliseconds: 5),
        lockDeadline: const Duration(seconds: 5),
        tryLock: (file) {
          if (++attempts < 3) return false;
          file.lockSync(FileLock.exclusive);
          return true;
        },
      );
      final lock = await store.acquireLock();
      expect(attempts, 3);
      lock.release();
    });

    test('cancellation is checked between attempts', () async {
      var checks = 0;
      final store = CredentialStore(
        home: home,
        lockPollInterval: const Duration(milliseconds: 5),
        lockDeadline: const Duration(seconds: 5),
        tryLock: (_) => false,
      );
      await expectLater(
        store.acquireLock(isCancelled: () => ++checks > 2),
        throwsA(_storeError(CredentialStoreError.cancelled)),
      );
    });

    test('an untrusted home creates no lock file', () async {
      final fake = HomeTrustSeams(
        stat: (path) => switch (path) {
          '/srv/shared' => const StatInfo(1000, 0x4000 | 511),
          '/srv/shared/kehai' => const StatInfo(1000, 0x4000 | 448),
          _ => const StatInfo(0, 0x4000 | 493),
        },
        euid: () => 1000,
        canonicalize: (path) => path,
        isLink: (_) => false,
        exists: (_) => true,
        makeDir: (_) => fail('must not create'),
      );
      final store = CredentialStore(
        home: '/srv/shared/kehai',
        backend: PosixFileBackend(trust: HomeTrust(fake)),
      );
      await expectLater(
        store.acquireLock(),
        throwsA(_storeError(CredentialStoreError.unsafePath, '0777')),
      );
    });
  });
}
