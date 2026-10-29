import 'package:kehai/src/auth/logout.dart';
import 'package:kehai/src/provider/provider.dart' show CancelToken;
import 'package:test/test.dart';

import '../support/fake_openai.dart';
import '../support/login_support.dart';

const _notConfirmedTail = 'You can disconnect Kehai in ChatGPT settings.';

void main() {
  late TestHome home;
  late FakeOpenAi fake;

  setUp(() async {
    home = TestHome();
    fake = await FakeOpenAi.start();
  });

  Future<String> logout({
    bool forget = false,
    CancelToken? cancel,
    Duration timeout = const Duration(seconds: 30),
  }) => logoutOpenAi(
    store: home.store,
    issuer: fake.issuer,
    forget: forget,
    cancel: cancel,
    timeout: timeout,
  );

  group('with a token set', () {
    test('logout posts revocation form and reports logged out', () async {
      home.store.replace(loggedInRecord(generation: 3));

      final message = await logout();

      expect(message, 'logged out');
      expect(fake.discoveryRequests, hasLength(1));
      expect(fake.revocationRequests, hasLength(1));
      final request = fake.revocationRequests.single;
      expect(request.method, 'POST');
      expect(request.headers['content-type'], contains('form-urlencoded'));
      expect(request.form, {
        'token': 'stored-refresh-token',
        'token_type_hint': 'refresh_token',
        'client_id': 'oaiapp_fake',
      });
      final record = home.store.load()!;
      expect(record.tokens, isNull);
      expect(record.hostId, seededHostId);
      expect(record.registration, isNotNull);
      expect(record.generation, 4);
    });

    test(
      'failed revocation still clears tokens and says not confirmed',
      () async {
        home.store.replace(loggedInRecord(generation: 3));
        fake.revocationScripts.add(const RevocationScript(status: 500));

        final message = await logout();

        expect(
          message,
          'logged out locally; remote revocation was not confirmed (500). '
          '$_notConfirmedTail',
        );
        final record = home.store.load()!;
        expect(record.tokens, isNull);
        expect(record.registration, isNotNull);
        expect(record.generation, 4);
      },
    );

    test('a network failure is not confirmed and still clears', () async {
      home.store.replace(loggedInRecord(generation: 3));
      fake.revocationScripts.add(const RevocationScript(drop: true));

      final message = await logout();

      expect(message, contains('not confirmed (network)'));
      expect(message, endsWith(_notConfirmedTail));
      expect(home.store.load()!.tokens, isNull);
    });

    test('a 200 with a body is not confirmed', () async {
      home.store.replace(loggedInRecord());
      fake.revocationScripts.add(const RevocationScript(body: '{"x":1}'));

      final message = await logout();

      expect(message, contains('not confirmed (200)'));
      expect(home.store.load()!.tokens, isNull);
    });

    test('failed discovery sends no revocation and still clears', () async {
      home.store.replace(loggedInRecord());
      fake.discoveryStatus = 503;

      final message = await logout();

      expect(message, contains('not confirmed (network)'));
      expect(fake.revocationRequests, isEmpty);
      expect(home.store.load()!.tokens, isNull);
    });

    test('a cancelled logout clears the tokens in the finally', () async {
      home.store.replace(loggedInRecord(generation: 3));
      fake.revocationScripts.add(
        const RevocationScript(delay: Duration(seconds: 20)),
      );
      final cancel = CancelToken();

      final pending = logout(cancel: cancel);
      while (fake.revocationRequests.isEmpty) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      cancel.cancel();
      final message = await pending;

      expect(message, contains('not confirmed'));
      final record = home.store.load()!;
      expect(record.tokens, isNull);
      expect(record.generation, 4);
    });

    test('the 30 s budget covers discovery and revocation together', () async {
      home.store.replace(loggedInRecord());
      fake.revocationScripts.add(
        const RevocationScript(delay: Duration(seconds: 20)),
      );

      final message = await logout(timeout: const Duration(milliseconds: 300));

      expect(message, contains('not confirmed (network)'));
      expect(home.store.load()!.tokens, isNull);
    });

    test('forget with a token set revokes and keeps only host id and '
        'generation', () async {
      home.store.replace(loggedInRecord(generation: 3));

      final message = await logout(forget: true);

      expect(message, 'logged out');
      expect(fake.revocationRequests, hasLength(1));
      final record = home.store.load()!;
      expect(record.tokens, isNull);
      expect(record.registration, isNull);
      expect(record.hostId, seededHostId);
      expect(record.generation, 4);
    });
  });

  group('without a token set', () {
    test('host-only record advances generation without a request', () async {
      home.store.replace(hostOnlyRecord(generation: 2));

      final message = await logout();

      expect(message, 'not logged in');
      expect(fake.requests, isEmpty);
      final record = home.store.load()!;
      expect(record.generation, 3);
      expect(record.hostId, seededHostId);
    });

    test(
      'registration without tokens is kept and generation advances',
      () async {
        home.store.replace(tokenlessRecord(generation: 5));

        final message = await logout();

        expect(message, 'not logged in');
        expect(fake.requests, isEmpty);
        final record = home.store.load()!;
        expect(record.generation, 6);
        expect(record.registration, isNotNull);
        expect(record.registration!.planUsageEnabled, isFalse);
      },
    );

    test('forget removes the registration, keeps host id and generation + 1, '
        'sends nothing', () async {
      home.store.replace(tokenlessRecord(generation: 5));

      final message = await logout(forget: true);

      expect(message, 'registration forgotten');
      expect(fake.requests, isEmpty);
      final record = home.store.load()!;
      expect(record.registration, isNull);
      expect(record.tokens, isNull);
      expect(record.hostId, seededHostId);
      expect(record.generation, 6);
    });

    test(
      'logout then forget removes the registration with no revocation',
      () async {
        home.store.replace(loggedInRecord(generation: 3));
        await logout();
        fake.revocationRequests.clear();

        final message = await logout(forget: true);

        expect(message, 'registration forgotten');
        expect(fake.revocationRequests, isEmpty);
        final record = home.store.load()!;
        expect(record.registration, isNull);
        expect(record.hostId, seededHostId);
        expect(record.generation, 5);
      },
    );

    test('forget of a host-only record says not logged in', () async {
      home.store.replace(hostOnlyRecord(generation: 1));

      final message = await logout(forget: true);

      expect(message, 'not logged in');
      expect(home.store.load()!.generation, 2);
    });

    test('no record at all writes nothing', () async {
      expect(await logout(), 'not logged in');
      expect(await logout(forget: true), 'not logged in');

      expect(home.store.load(), isNull);
      expect(fake.requests, isEmpty);
    });
  });

  test('logout holds the credential lock while it works', () async {
    home.store.replace(loggedInRecord());
    home.lockHeld = true;
    var finished = false;

    final pending = logout().whenComplete(() => finished = true);
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(finished, isFalse, reason: 'waiting for auth.lock');
    expect(fake.requests, isEmpty);

    home.lockHeld = false;
    expect(await pending, 'logged out');
  });
}
