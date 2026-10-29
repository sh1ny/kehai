import 'dart:io';

import 'package:kehai/src/auth/credential_store.dart';
import 'package:kehai/src/auth/dpapi_backend.dart';
import 'package:kehai/src/auth/failure_text.dart';
import 'package:kehai/src/auth/openai_constants.dart';
import 'package:kehai/src/auth/posix_file_backend.dart';
import 'package:kehai/src/auth/refresher.dart';
import 'package:kehai/src/provider/chatgpt_adapter.dart';
import 'package:kehai/src/provider/provider.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_openai.dart';

CredentialRecord _record({bool tokens = true}) {
  final now = DateTime.now().toUtc();
  return CredentialRecord(
    hostId: 'urn:uuid:11111111-2222-3333-4444-555555555555',
    generation: 3,
    registration: const CredentialRegistration(
      issuer: 'https://auth.openai.com',
      clientId: 'client-xyz',
      subject: 'user-123',
      email: 'user-123@example.com',
      plan: 'plus',
      planUsageEnabled: true,
    ),
    tokens: tokens
        ? CredentialTokens(
            idToken: 'old-id-token',
            accessToken: 'old-access',
            refreshToken: 'old-refresh',
            expiresAt: now.add(const Duration(minutes: 30)),
            scopes: const ['openid', 'offline_access', openAiPlanUsageScope],
            savedAt: now.subtract(const Duration(days: 1)),
            lastRefresh: now.subtract(const Duration(hours: 1)),
          )
        : null,
  );
}

TypeMatcher<ProviderFailure> _providerFailure(FailureKind kind) =>
    isA<ProviderFailure>().having((f) => f.kind, 'kind', kind);

void main() {
  late Directory tmp;
  late CredentialStore store;
  late FakeOpenAi fake;
  late ChatGptAdapter adapter;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('kehai_models_');
    if (!Platform.isWindows) Process.runSync('chmod', ['700', tmp.path]);
    store = CredentialStore(home: p.join(tmp.path, 'home'))..replace(_record());
    fake = await FakeOpenAi.start();
    adapter = ChatGptAdapter(
      refresher: Refresher(store: store, issuer: fake.issuer),
      apiBase: fake.apiBase,
    );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('listed models exclude non-list visibility and unsupported', () async {
    fake.modelsScripts.add(
      ModelsScript.json({
        'models': [
          {
            'slug': 'gpt-a',
            'display_name': 'GPT A',
            'visibility': 'list',
            'supported_in_api': true,
          },
          {'slug': 'gpt-b', 'display_name': 'GPT B', 'visibility': 'list'},
          {
            'slug': 'gpt-hidden',
            'display_name': 'Hidden',
            'visibility': 'hide',
            'supported_in_api': true,
          },
          {
            'slug': 'gpt-unsupported',
            'display_name': 'Unsupported',
            'visibility': 'list',
            'supported_in_api': false,
          },
        ],
      }),
    );

    final models = await adapter.listModels();

    expect(models.map((m) => (m.id, m.name)), [
      ('gpt-a', 'GPT A'),
      ('gpt-b', 'GPT B'),
    ]);
    final sent = fake.modelsRequests.single;
    expect(sent.method, 'GET');
    expect(sent.path, '/v1/models');
    expect(sent.headers['authorization'], 'Bearer old-access');
  });

  test(
    'a store failure after a rotating refresh fails reauth_required',
    () async {
      void failRename() => throw const FileSystemException(
        'No space left on device',
        'auth.tmp',
        OSError('No space left on device', 28),
      );
      var armed = false;
      final failing = CredentialStore(
        home: p.join(tmp.path, 'disk'),
        backend: Platform.isWindows
            ? DpapiBackend(beforeRename: () => armed ? failRename() : null)
            : PosixFileBackend(beforeRename: () => armed ? failRename() : null),
      );
      final now = DateTime.now().toUtc();
      final stored = _record();
      failing.replace(
        CredentialRecord(
          hostId: stored.hostId,
          generation: stored.generation,
          registration: stored.registration,
          tokens: CredentialTokens(
            idToken: 'old-id-token',
            accessToken: 'old-access',
            refreshToken: 'old-refresh',
            expiresAt: now.add(const Duration(minutes: 1)),
            scopes: const ['openid', 'offline_access', openAiPlanUsageScope],
            savedAt: now,
            lastRefresh: now,
          ),
        ),
      );
      armed = true;
      final disk = ChatGptAdapter(
        refresher: Refresher(store: failing, issuer: fake.issuer),
        apiBase: fake.apiBase,
      );

      await expectLater(
        disk.listModels(),
        throwsA(_providerFailure(FailureKind.reauthRequired)),
      );
      expect(fake.modelsRequests, isEmpty);
    },
  );

  test('503 fails server with no list', () async {
    fake.modelsScripts.add(const ModelsScript.raw('<html>SECRET</html>', 503));

    await expectLater(
      adapter.listModels(),
      throwsA(
        _providerFailure(FailureKind.server)
            .having((f) => f.status, 'status', 503)
            .having((f) => f.message, 'message', isNot(contains('SECRET'))),
      ),
    );
  });

  test('body over 4 MiB fails protocol', () async {
    fake.modelsScripts.add(
      ModelsScript.raw(
        'x' * (openAiMaxModelsBodyBytes + 1),
        200,
        contentType: 'application/json',
      ),
    );

    await expectLater(
      adapter.listModels(),
      throwsA(
        _providerFailure(FailureKind.protocol)
            .having((f) => f.message, 'message', contains('4 MiB')),
      ),
    );
  });

  test('a body that is not a models document fails protocol', () async {
    fake.modelsScripts.add(const ModelsScript.json({'models': 'nope'}));
    await expectLater(
      adapter.listModels(),
      throwsA(_providerFailure(FailureKind.protocol)),
    );
  });

  test('401 refreshes and repeats once', () async {
    fake.modelsScripts
      ..add(const ModelsScript.json({'detail': 'expired'}, status: 401))
      ..add(
        const ModelsScript.json({
          'models': [
            {'slug': 'gpt-a', 'display_name': 'GPT A', 'visibility': 'list'},
          ],
        }),
      );

    final models = await adapter.listModels();

    expect(models.map((m) => m.id), ['gpt-a']);
    expect(fake.tokenRequests, hasLength(1));
    expect(fake.modelsRequests.map((r) => r.headers['authorization']), [
      'Bearer old-access',
      'Bearer access-1',
    ]);
  });

  test('second 401 is reauth_required', () async {
    fake.modelsScripts
      ..add(const ModelsScript.json({'detail': 'expired'}, status: 401))
      ..add(const ModelsScript.json({'detail': 'expired'}, status: 401));

    await expectLater(
      adapter.listModels(),
      throwsA(_providerFailure(FailureKind.reauthRequired)),
    );
    expect(fake.modelsRequests, hasLength(2));
    expect(store.load()!.tokens, isNotNull);
  });

  test('no token set fails reauth_required without a request', () async {
    store.replace(_record(tokens: false));
    await expectLater(
      adapter.listModels(),
      throwsA(_providerFailure(FailureKind.reauthRequired)),
    );
    expect(fake.modelsRequests, isEmpty);
  });
}
