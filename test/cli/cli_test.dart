/// End-to-end tests of `bin/kehai.dart` (design D1, D11).
///
/// Every test runs the real CLI as a process with `KEHAI_HOME` set to a
/// temporary directory and `KEHAI_OPENAI_ISSUER` / `KEHAI_OPENAI_API_BASE`
/// pointing at the loopback fake. Records are seeded and inspected in this
/// process through a [CredentialStore] over the same home and the platform
/// backend, so the CLI process and the test agree on the stored bytes.
@Timeout(Duration(minutes: 3))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/src/auth/credential_store.dart';
import 'package:kehai/src/auth/failure_text.dart';
import 'package:kehai/src/auth/openai_constants.dart';
import 'package:kehai/src/auth/refresher.dart';
import 'package:kehai/src/provider/chatgpt_adapter.dart';
import 'package:kehai/src/provider/provider.dart';
import 'package:test/test.dart';

import '../support/fake_openai.dart';
import '../support/login_support.dart';

/// The outcome of one CLI run.
typedef CliRun = ({int exitCode, String stdout, String stderr});

/// Runs `dart run bin/kehai.dart [args]` against [home] and [fake].
///
/// [environment] adds to (and may replace) the loopback overrides.
Future<CliRun> runCli(
  List<String> args, {
  required TestHome home,
  FakeOpenAi? fake,
  Map<String, String> environment = const {},
}) async {
  final process = await startCli(
    args,
    home: home,
    fake: fake,
    environment: environment,
  );
  await process.stdin.close();
  final out = process.stdout.transform(utf8.decoder).join();
  final err = process.stderr.transform(utf8.decoder).join();
  final code = await process.exitCode.timeout(
    const Duration(seconds: 90),
    onTimeout: () {
      process.kill();
      fail('the CLI did not exit: kehai ${args.join(' ')}');
    },
  );
  return (exitCode: code, stdout: await out, stderr: await err);
}

/// Starts the CLI process and kills it at test teardown.
Future<Process> startCli(
  List<String> args, {
  required TestHome home,
  FakeOpenAi? fake,
  Map<String, String> environment = const {},
}) async {
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['run', 'bin/kehai.dart', ...args],
    environment: {
      'KEHAI_HOME': home.path,
      if (fake != null) 'KEHAI_OPENAI_ISSUER': fake.issuer,
      if (fake != null) 'KEHAI_OPENAI_API_BASE': fake.apiBase,
      ...environment,
    },
  );
  addTearDown(process.kill);
  return process;
}

/// Everything a CLI run printed, for token-leak assertions.
String allOutput(CliRun run) => '${run.stdout}\n${run.stderr}';

/// A model entry as `/v1/models` lists it.
Map<String, Object?> listedModel(String slug, String name) => {
  'slug': slug,
  'display_name': name,
  'visibility': 'list',
  'supported_in_api': true,
};

void main() {
  late TestHome home;
  late FakeOpenAi fake;

  setUp(() async {
    home = TestHome();
    fake = await FakeOpenAi.start();
  });

  group('doctor', () {
    test(
      'doctor prints account backend expiry models and exits zero',
      () async {
        final record = loggedInRecord();
        home.store.replace(record);

        final run = await runCli(['doctor'], home: home, fake: fake);

        expect(run.exitCode, 0, reason: allOutput(run));
        final out = run.stdout;
        expect(out, contains('user-123@example.com'));
        expect(out, contains('user-123'));
        expect(out, contains('plus'));
        expect(
          out,
          contains(Platform.isWindows ? 'DPAPI' : '0600'),
          reason: 'names the credential backend',
        );
        expect(out, contains(home.path), reason: 'names the credential path');
        expect(
          out,
          contains(record.tokens!.expiresAt.toIso8601String()),
          reason: 'prints the access-token expiry',
        );
        expect(out, contains('gpt-fake'));
        expect(out, contains('logged in'));
        expect(out, contains('refresh: not needed'));
        expect(fake.modelsRequests, hasLength(1));
        expect(fake.tokenRequests, isEmpty);
      },
    );

    test(
      'doctor refreshes a token that is about to expire and says so',
      () async {
        home.store.replace(
          loggedInRecord(expiresIn: const Duration(minutes: 1)),
        );

        final run = await runCli(['doctor'], home: home, fake: fake);

        expect(run.exitCode, 0, reason: allOutput(run));
        expect(run.stdout, contains('refresh: succeeded'));
        expect(fake.tokenRequests, hasLength(1));
        expect(fake.tokenRequests.single.form['grant_type'], 'refresh_token');
        expect(home.store.load()!.tokens!.refreshToken, startsWith('refresh-'));
      },
    );

    test('doctor output contains no stored token', () async {
      const access = 'access-token-SENTINEL-1';
      const refresh = 'refresh-token-SENTINEL-2';
      const id = 'id-token-SENTINEL-3';
      home.store.replace(
        loggedInRecord(accessToken: access, refreshToken: refresh, idToken: id),
      );

      final run = await runCli(['doctor'], home: home, fake: fake);

      expect(run.exitCode, 0, reason: allOutput(run));
      for (final secret in [access, refresh, id, 'SENTINEL']) {
        expect(allOutput(run), isNot(contains(secret)));
      }
      expect(
        fake.modelsRequests.single.headers['authorization'],
        contains(access),
      );
    });

    test('doctor without tokens or a disabled registration reports not logged in and exits non-zero', () async {
      for (final record in <CredentialRecord?>[
        null,
        hostOnlyRecord(),
        tokenlessRecord(planUsage: true),
      ]) {
        final fresh = TestHome();
        if (record != null) fresh.store.replace(record);

        final run = await runCli(['doctor'], home: fresh, fake: fake);

        expect(run.exitCode, 1, reason: allOutput(run));
        expect(run.stdout, contains('not logged in'));
        expect(run.stdout, contains('kehai login openai'));
        expect(run.stdout, isNot(contains('--enable-plan-usage')));
        expect(run.stderr.trim().split('\n'), hasLength(1));
      }
      expect(fake.modelsRequests, isEmpty);
      expect(fake.tokenRequests, isEmpty);
    });

    test('doctor with plan usage disabled names enable-plan-usage and exits non-zero', () async {
      home.store.replace(tokenlessRecord());

      final run = await runCli(['doctor'], home: home, fake: fake);

      expect(run.exitCode, 1, reason: allOutput(run));
      expect(run.stdout, contains('ChatGPT plan usage not enabled'));
      expect(run.stdout, contains('kehai login openai --enable-plan-usage'));
      expect(fake.modelsRequests, isEmpty, reason: 'no models are listed');
      expect(run.stdout, isNot(contains('gpt-fake')));
    });

    test('doctor with no listed models reports no models available', () async {
      home.store.replace(loggedInRecord());
      fake.modelsScripts.add(
        ModelsScript.json({
          'models': [
            {
              'slug': 'hidden',
              'display_name': 'Hidden',
              'visibility': 'hide',
              'supported_in_api': true,
            },
          ],
        }),
      );

      final run = await runCli(['doctor'], home: home, fake: fake);

      expect(run.exitCode, 1, reason: allOutput(run));
      expect(run.stdout, contains('no models available'));
      expect(run.stdout, isNot(contains('hidden')));
    });

    test(
      'doctor caps the model list at 200 lines and counts the rest',
      () async {
        home.store.replace(loggedInRecord());
        fake.modelsScripts.add(
          ModelsScript.json({
            'models': [
              for (var i = 0; i < 250; i++) listedModel('model-$i', 'Model $i'),
            ],
          }),
        );

        final run = await runCli(['doctor'], home: home, fake: fake);

        expect(run.exitCode, 0, reason: allOutput(run));
        expect(run.stdout, contains('model-199'));
        expect(run.stdout, isNot(contains('model-200')));
        expect(run.stdout, contains('50 more'));
      },
    );

    test('doctor reports a rejected refresh and exits non-zero', () async {
      home.store.replace(loggedInRecord(expiresIn: const Duration(minutes: 1)));
      fake.tokenScripts.add(TokenScript.error(400, 'invalid_grant'));

      final run = await runCli(['doctor'], home: home, fake: fake);

      expect(run.exitCode, 1, reason: allOutput(run));
      expect(run.stdout, contains('refresh: failed'));
      expect(run.stdout, contains('kehai login openai'));
      expect(fake.modelsRequests, isEmpty);
    });
  });

  group('model requests need a token set', () {
    test('tokenless enabled registration reports not logged in and fails reauth; disabled one fails not_permitted', () async {
      // Enabled registration without tokens: doctor says "not logged in"
      // and a model request fails with reauth_required, sending nothing.
      home.store.replace(tokenlessRecord(planUsage: true));
      final doctor = await runCli(['doctor'], home: home, fake: fake);
      expect(doctor.exitCode, 1, reason: allOutput(doctor));
      expect(doctor.stdout, contains('not logged in'));

      ChatGptAdapter adapterFor(TestHome h) => ChatGptAdapter(
        refresher: Refresher(store: h.store, issuer: fake.issuer),
        apiBase: fake.apiBase,
      );

      await expectLater(
        adapterFor(home).listModels(),
        throwsA(
          isA<ProviderFailure>().having(
            (f) => f.kind,
            'kind',
            FailureKind.reauthRequired,
          ),
        ),
      );

      // Disabled registration: not_permitted, naming the recovery command.
      final disabled = TestHome();
      disabled.store.replace(tokenlessRecord());
      await expectLater(
        adapterFor(disabled).listModels(),
        throwsA(
          isA<ProviderFailure>()
              .having((f) => f.kind, 'kind', FailureKind.notPermitted)
              .having(
                (f) => f.message,
                'message',
                contains('--enable-plan-usage'),
              ),
        ),
      );
      expect(fake.modelsRequests, isEmpty);
      expect(fake.tokenRequests, isEmpty);
    });
  });

  group('logout', () {
    test('logout clears tokens, keeps host id and registration, doctor reports not logged in', () async {
      final record = loggedInRecord(generation: 3);
      home.store.replace(record);

      final run = await runCli(['logout', 'openai'], home: home, fake: fake);

      expect(run.exitCode, 0, reason: allOutput(run));
      expect(run.stdout, contains('logged out'));
      expect(fake.revocationRequests, hasLength(1));
      expect(
        fake.revocationRequests.single.form['token'],
        record.tokens!.refreshToken,
      );
      final after = home.store.load()!;
      expect(after.tokens, isNull);
      expect(after.hostId, record.hostId);
      expect(after.registration, record.registration);
      expect(after.generation, 4);

      final doctor = await runCli(['doctor'], home: home, fake: fake);
      expect(doctor.exitCode, 1, reason: allOutput(doctor));
      expect(doctor.stdout, contains('not logged in'));
    });

    test('logout without tokens prints not logged in, exits zero, sends no revocation, advances generation', () async {
      home.store.replace(hostOnlyRecord(generation: 2));

      final run = await runCli(['logout', 'openai'], home: home, fake: fake);

      expect(run.exitCode, 0, reason: allOutput(run));
      expect(run.stdout, contains('not logged in'));
      expect(fake.revocationRequests, isEmpty);
      expect(fake.requests, isEmpty, reason: 'no network request at all');
      final after = home.store.load()!;
      expect(after.generation, 3);
      expect(after.hostId, seededHostId);
      expect(after.tokens, isNull);
    });

    test('logout --forget while logged in revokes and keeps only host id and generation', () async {
      final record = loggedInRecord(generation: 5);
      home.store.replace(record);

      final run = await runCli(
        ['logout', 'openai', '--forget'],
        home: home,
        fake: fake,
      );

      expect(run.exitCode, 0, reason: allOutput(run));
      expect(fake.revocationRequests, hasLength(1));
      final after = home.store.load()!;
      expect(after.hostId, record.hostId);
      expect(after.generation, 6);
      expect(after.registration, isNull);
      expect(after.tokens, isNull);
    });

    test('logout then logout --forget sends no revocation and keeps only host id and generation', () async {
      home.store.replace(loggedInRecord(generation: 1));

      final first = await runCli(['logout', 'openai'], home: home, fake: fake);
      expect(first.exitCode, 0, reason: allOutput(first));
      expect(fake.revocationRequests, hasLength(1));

      final second = await runCli(
        ['logout', 'openai', '--forget'],
        home: home,
        fake: fake,
      );

      expect(second.exitCode, 0, reason: allOutput(second));
      expect(second.stdout, contains('registration forgotten'));
      expect(fake.revocationRequests, hasLength(1), reason: 'no new request');
      final after = home.store.load()!;
      expect(after.hostId, seededHostId);
      expect(after.generation, 3);
      expect(after.registration, isNull);
      expect(after.tokens, isNull);
    });
  });

  group('login', () {
    test('login openai --no-browser signs in through a pasted redirect URL', () async {
      if (!await portIsFree(openAiRedirectPort)) {
        markTestSkipped('port $openAiRedirectPort is held by another process');
        return;
      }
      final process = await startCli(
        ['login', 'openai', '--no-browser'],
        home: home,
        fake: fake,
      );
      final lines = <String>[];
      final seen = StreamController<String>.broadcast();
      process.stdout
          .transform(utf8.decoder)
          .transform(const LineSplitter())
          .listen((line) {
            lines.add(line);
            seen.add(line);
          });
      final errors = process.stderr.transform(utf8.decoder).join();

      final url = await seen.stream
          .firstWhere((line) => line.startsWith('http'))
          .timeout(const Duration(seconds: 90));
      final redirect = await callbackUrlFor(url);
      process.stdin.writeln(redirect);
      await process.stdin.flush();

      final code = await process.exitCode.timeout(
        const Duration(seconds: 60),
        onTimeout: () async {
          process.kill();
          fail(
            "login did not exit; stdout: ${lines.skip(2).join(" | ")}; stderr: ${await errors}",
          );
        },
      );
      await process.stdin.close().catchError((Object _) {});

      expect(code, 0, reason: '${lines.join('\n')}\n${await errors}');
      expect(lines.join('\n'), contains('user@example.com'));
      final stored = home.store.load()!;
      expect(stored.tokens, isNotNull);
      expect(stored.registration!.planUsageEnabled, isTrue);
      expect(stored.generation, 1);
      expect(await errors, isNot(contains('access-')));
    });
  });

  group('usage and overrides', () {
    test('a non-loopback issuer override is rejected with exit 64', () async {
      home.store.replace(loggedInRecord());

      final run = await runCli(
        ['doctor'],
        home: home,
        environment: {'KEHAI_OPENAI_ISSUER': 'https://auth.example.com'},
      );

      expect(run.exitCode, 64, reason: allOutput(run));
      expect(run.stderr, contains('KEHAI_OPENAI_ISSUER'));
      expect(run.stdout, isNot(contains('user-123')));
    });

    test('a non-loopback API base override is rejected with exit 64', () async {
      home.store.replace(loggedInRecord());

      final run = await runCli(
        ['logout', 'openai'],
        home: home,
        environment: {
          'KEHAI_OPENAI_ISSUER': fake.issuer,
          'KEHAI_OPENAI_API_BASE': 'http://127.0.0.1.evil.example/v1',
        },
      );

      expect(run.exitCode, 64, reason: allOutput(run));
      expect(run.stderr, contains('KEHAI_OPENAI_API_BASE'));
      expect(fake.requests, isEmpty);
      expect(home.store.load()!.tokens, isNotNull, reason: 'nothing changed');
    });

    test('an unknown command is a usage error with exit 64', () async {
      final run = await runCli(['frobnicate'], home: home, fake: fake);

      expect(run.exitCode, 64, reason: allOutput(run));
      expect(run.stderr, contains('frobnicate'));
    });
  });
}
