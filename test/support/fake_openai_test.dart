import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';

import 'fake_openai.dart';

Future<(HttpClientResponse, String)> _send(
  HttpClient client,
  String method,
  String url, {
  String? body,
  Map<String, String> headers = const {},
}) async {
  final request = await client.openUrl(method, Uri.parse(url));
  request.followRedirects = false;
  headers.forEach(request.headers.set);
  if (body != null) request.add(utf8.encode(body));
  final response = await request.close();
  final text = await utf8.decodeStream(response);
  return (response, text);
}

void main() {
  late FakeOpenAi fake;
  late HttpClient client;

  setUp(() async {
    fake = await FakeOpenAi.start();
    client = HttpClient();
    addTearDown(() => client.close(force: true));
  });

  test('a scripted SSE response round-trips and is recorded', () async {
    fake.responsesScripts.add(ResponsesScript.sse(sseTextTurn('hello')));
    final (response, text) = await _send(
      client,
      'POST',
      '${fake.apiBase}/responses',
      body: jsonEncode({'model': 'm', 'input': <Object>[]}),
      headers: {'content-type': 'application/json'},
    );
    expect(response.statusCode, 200);
    expect(text, contains('event: response.output_text.delta'));
    expect(text, contains('event: response.completed'));
    expect(fake.responsesRequests.single.json!['model'], 'm');
  });

  test('a drop step truncates the chunked body', () async {
    fake.responsesScripts.add(
      ResponsesScript.sse([SseEvent.json('response.created'), const Drop()]),
    );
    await expectLater(
      _send(client, 'POST', '${fake.apiBase}/responses', body: '{}'),
      throwsA(isA<HttpException>()),
    );
  });

  test('error scripts serve detail JSON and models', () async {
    fake.responsesScripts.add(
      const ResponsesScript.error(503, '{"detail":"down"}'),
    );
    final (response, text) = await _send(
      client,
      'POST',
      '${fake.apiBase}/responses',
      body: '{}',
    );
    expect(response.statusCode, 503);
    expect(jsonDecode(text), {'detail': 'down'});
    final (models, body) = await _send(client, 'GET', '${fake.apiBase}/models');
    expect(models.statusCode, 200);
    expect(jsonDecode(body)['models'], hasLength(1));
  });

  test(
    'discovery and JWKS serve a key that verifies a signed ID token',
    () async {
      final (_, discovery) = await _send(
        client,
        'GET',
        '${fake.issuer}/.well-known/openid-configuration',
      );
      final config = jsonDecode(discovery) as Map<String, Object?>;
      expect(config['issuer'], fake.issuer);
      final (_, jwksText) = await _send(
        client,
        'GET',
        config['jwks_uri']! as String,
      );
      final jwk = ((jsonDecode(jwksText) as Map)['keys'] as List).single as Map;
      expect(jwk['kty'], 'RSA');
      expect(jwk['alg'], 'RS256');
      expect(jwk['n'], fake.key.jwk['n']);

      final token = fake.signIdToken(nonce: 'n1');
      final parts = token.split('.');
      final header = jsonDecode(
        utf8.decode(base64Url.decode(base64.normalize(parts[0]))),
      );
      expect(header['kid'], jwk['kid']);
      final signature = base64Url.decode(base64.normalize(parts[2]));
      expect(
        fake.key.verify(utf8.encode('${parts[0]}.${parts[1]}'), signature),
        isTrue,
      );

      final wrong = fake.signIdToken(
        wrongKey: FakeRsaKey.generate(kid: 'other'),
      );
      final wrongParts = wrong.split('.');
      expect(
        fake.key.verify(
          utf8.encode('${wrongParts[0]}.${wrongParts[1]}'),
          base64Url.decode(base64.normalize(wrongParts[2])),
        ),
        isFalse,
      );
    },
  );

  test('authorize redirects and the code grant returns tokens', () async {
    const verifier = 'verifier-verifier-verifier-verifier-verifier-verifier-xx';
    final challenge = base64UrlNoPad(
      sha256.convert(utf8.encode(verifier)).bytes,
    );
    final (redirect, _) = await _send(
      client,
      'GET',
      '${fake.issuer}/api/accounts/authorize?client_id=dynamic_agent_client'
          '&redirect_uri=${Uri.encodeComponent('http://127.0.0.1:1455/auth/callback')}'
          '&state=s1&nonce=n1&code_challenge=$challenge&prompt=consent',
    );
    expect(redirect.statusCode, 302);
    final location = Uri.parse(redirect.headers.value('location')!);
    expect(location.queryParameters['state'], 's1');
    expect(location.queryParameters['client_id'], 'oaiapp_fake');
    expect(fake.authorizeRequests.single.query['prompt'], 'consent');

    final (token, text) = await _send(
      client,
      'POST',
      '${fake.issuer}/api/accounts/oauth/token',
      body: Uri(
        queryParameters: {
          'grant_type': 'authorization_code',
          'code': location.queryParameters['code']!,
          'code_verifier': verifier,
        },
      ).query,
      headers: {'content-type': 'application/x-www-form-urlencoded'},
    );
    expect(token.statusCode, 200);
    final body = jsonDecode(text) as Map<String, Object?>;
    expect(body['scope'], fake.grantedScope);
    expect(body['id_token'], isA<String>());
    expect(fake.tokenRequests.single.form['grant_type'], 'authorization_code');
  });

  test('tool placement assertion accepts and rejects shapes', () {
    expectAdditionalToolsOnly({
      'input': [
        {'type': 'additional_tools', 'role': 'developer', 'tools': <Object>[]},
        {'type': 'message', 'role': 'user'},
      ],
    });
    expect(
      () =>
          expectAdditionalToolsOnly({'tools': <Object>[], 'input': <Object>[]}),
      throwsA(isA<TestFailure>()),
    );
  });
}
