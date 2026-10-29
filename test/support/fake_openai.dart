/// A loopback fake of the OpenAI auth server and API, driven by per-test
/// scripts (design D11).
///
/// Start one with [FakeOpenAi.start], enqueue responses on the script queues
/// (`tokenScripts`, `responsesScripts`, ...), run the code under test against
/// [FakeOpenAi.issuer] and [FakeOpenAi.apiBase], then inspect the recorded
/// requests. An empty queue falls back to a sensible default, except for
/// `/v1/responses`, which answers `500` with code `fake_unscripted` so a
/// missing script fails loudly.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:pointycastle/export.dart';
import 'package:test/test.dart';

/// The default granted scope set returned in token responses.
const String fakeDefaultScope =
    'openid profile email offline_access resource.invoke '
    'chatgpt.tokens.use.direct';

/// An RSA key pair that signs and publishes RS256 JWTs.
final class FakeRsaKey {
  FakeRsaKey._(this.kid, this._public, this._private);

  /// Generates a fresh 2048-bit key with the key id [kid].
  factory FakeRsaKey.generate({String kid = 'fake-key-1'}) {
    final seed = Random.secure();
    final random = FortunaRandom()
      ..seed(
        KeyParameter(
          Uint8List.fromList(List<int>.generate(32, (_) => seed.nextInt(256))),
        ),
      );
    final generator = RSAKeyGenerator()
      ..init(
        ParametersWithRandom(
          RSAKeyGeneratorParameters(BigInt.from(65537), 2048, 64),
          random,
        ),
      );
    final pair = generator.generateKeyPair();
    return FakeRsaKey._(kid, pair.publicKey, pair.privateKey);
  }

  /// The key id placed in the JWT header and the JWKS.
  final String kid;

  final RSAPublicKey _public;
  final RSAPrivateKey _private;

  /// The public key as a JWKS entry.
  Map<String, Object?> get jwk => {
    'kty': 'RSA',
    'alg': 'RS256',
    'use': 'sig',
    'kid': kid,
    'n': base64UrlNoPad(_bigIntBytes(_public.modulus!)),
    'e': base64UrlNoPad(_bigIntBytes(_public.publicExponent!)),
  };

  /// Signs [message] with RSASSA-PKCS1-v1_5 and SHA-256.
  Uint8List sign(List<int> message) {
    final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(true, PrivateKeyParameter<RSAPrivateKey>(_private));
    return signer.generateSignature(Uint8List.fromList(message)).bytes;
  }

  /// Whether [signature] is a valid signature of [message] under this key.
  bool verify(List<int> message, List<int> signature) {
    final signer = RSASigner(SHA256Digest(), '0609608648016503040201')
      ..init(false, PublicKeyParameter<RSAPublicKey>(_public));
    try {
      return signer.verifySignature(
        Uint8List.fromList(message),
        RSASignature(Uint8List.fromList(signature)),
      );
    } on ArgumentError {
      return false;
    }
  }
}

/// Encodes [bytes] as base64url without padding.
String base64UrlNoPad(List<int> bytes) =>
    base64Url.encode(bytes).replaceAll('=', '');

Uint8List _bigIntBytes(BigInt value) {
  var hex = value.toRadixString(16);
  if (hex.length.isOdd) hex = '0$hex';
  return Uint8List.fromList([
    for (var i = 0; i < hex.length; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ]);
}

/// Builds a JWT from [header] and [payload], signed by [key].
///
/// With a null [key] the signature part is empty, as for `alg: none`. Pass
/// [signature] to substitute raw signature bytes.
String signJwt(
  Map<String, Object?> header,
  Map<String, Object?> payload, {
  FakeRsaKey? key,
  List<int>? signature,
}) {
  final signingInput =
      '${base64UrlNoPad(utf8.encode(jsonEncode(header)))}.'
      '${base64UrlNoPad(utf8.encode(jsonEncode(payload)))}';
  final sig =
      signature ??
      (key == null ? <int>[] : key.sign(utf8.encode(signingInput)));
  return '$signingInput.${base64UrlNoPad(sig)}';
}

/// One request received by the fake, with its body decoded.
final class RecordedRequest {
  RecordedRequest._({
    required this.method,
    required this.path,
    required this.query,
    required this.headers,
    required this.bodyBytes,
  });

  /// The HTTP method.
  final String method;

  /// The request path, without the query.
  final String path;

  /// The query parameters.
  final Map<String, String> query;

  /// The headers, with lower-case names and multiple values joined by commas.
  final Map<String, String> headers;

  /// The raw request body.
  final Uint8List bodyBytes;

  /// The body decoded as UTF-8.
  late final String body = utf8.decode(bodyBytes, allowMalformed: true);

  /// The body parsed as a form, or an empty map for a non-form body.
  late final Map<String, String> form =
      (headers['content-type'] ?? '').contains('x-www-form-urlencoded')
      ? Uri.splitQueryString(body)
      : const {};

  /// The body parsed as a JSON object, or null if it is not one.
  late final Map<String, Object?>? json = () {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }();
}

/// A scripted response of the authorize endpoint.
///
/// By default the fake redirects with `code`, the echoed `state` and an issued
/// `client_id`.
final class AuthorizeScript {
  /// Creates a script. Fields left null use the default behaviour.
  const AuthorizeScript({
    this.clientId,
    this.omitClientId = false,
    this.error,
    this.omitCode = false,
    this.state,
    this.omitState = false,
  });

  /// Redirects with `error=access_denied`.
  const AuthorizeScript.accessDenied() : this(error: 'access_denied');

  /// Redirects with no `client_id`.
  const AuthorizeScript.withoutClientId() : this(omitClientId: true);

  /// Redirects with this `client_id` instead of the issued one.
  const AuthorizeScript.withClientId(String id) : this(clientId: id);

  /// The `client_id` to return instead of the issued one.
  final String? clientId;

  /// Whether to leave `client_id` out.
  final bool omitClientId;

  /// An `error` code to redirect with instead of a `code`.
  final String? error;

  /// Whether to leave `code` out of a success redirect.
  final bool omitCode;

  /// A `state` to return instead of the echoed one.
  final String? state;

  /// Whether to leave `state` out.
  final bool omitState;
}

/// A scripted response of the token endpoint.
final class TokenScript {
  TokenScript._(
    this._build, {
    this.status = 200,
    this.contentType = 'application/json',
    this.drop = false,
    this.delay = Duration.zero,
  });

  /// A success body. For the code grant it carries an ID token signed for the
  /// attempt's nonce and the issued client id.
  ///
  /// [omit] removes top-level fields, [overrides] replaces or adds them, and
  /// [idToken] builds a custom ID token from the attempt's nonce and client id.
  factory TokenScript.success({
    String? scope,
    int expiresIn = 3600,
    Set<String> omit = const {},
    Map<String, Object?> overrides = const {},
    String Function(String nonce, String clientId)? idToken,
    Duration delay = Duration.zero,
  }) => TokenScript._((fake, form) {
    final grant = form['grant_type'];
    final tokens = fake._nextTokens();
    final body = <String, Object?>{
      'access_token': tokens.$1,
      'refresh_token': tokens.$2,
      'token_type': 'Bearer',
      'expires_in': expiresIn,
      'scope': scope ?? fake.grantedScope,
    };
    if (grant == 'authorization_code') {
      final session = fake._codes[form['code']];
      if (session == null) {
        return _TokenFailure(400, {'error': 'invalid_grant'});
      }
      final challenge = base64UrlNoPad(
        sha256.convert(utf8.encode(form['code_verifier'] ?? '')).bytes,
      );
      if (challenge != session.codeChallenge) {
        return _TokenFailure(400, {'error': 'invalid_grant'});
      }
      body['id_token'] = idToken != null
          ? idToken(session.nonce, session.clientId)
          : fake.signIdToken(nonce: session.nonce, aud: session.clientId);
    } else if (idToken != null) {
      body['id_token'] = idToken('', form['client_id'] ?? '');
    }
    body.removeWhere((key, _) => omit.contains(key));
    body.addAll(overrides);
    return body;
  }, delay: delay);

  /// An error body `{"error": code}` with [status], sent after [delay].
  factory TokenScript.error(
    int status,
    String code, {
    Map<String, Object?> extra = const {},
    Duration delay = Duration.zero,
  }) => TokenScript._(
    (_, _) => {'error': code, ...extra},
    status: status,
    delay: delay,
  );

  /// A JSON [body] with [status].
  factory TokenScript.json(int status, Object? body) =>
      TokenScript._((_, _) => body ?? '', status: status);

  /// A raw text [body] with [status], for example HTML.
  factory TokenScript.raw(
    int status,
    String body, {
    String contentType = 'text/html',
  }) => TokenScript._((_, _) => body, status: status, contentType: contentType);

  /// Reads the request body, then destroys the connection with no response.
  factory TokenScript.drop() => TokenScript._((_, _) => '', drop: true);

  final Object Function(FakeOpenAi, Map<String, String>) _build;

  /// The HTTP status of the response.
  final int status;

  /// The response content type.
  final String contentType;

  /// Whether to destroy the connection instead of responding.
  final bool drop;

  /// How long to wait after reading the body before responding.
  final Duration delay;
}

final class _TokenFailure {
  _TokenFailure(this.status, this.body);
  final int status;
  final Object body;
}

/// A scripted response of the revocation endpoint.
final class RevocationScript {
  /// Responds with [status] and [body] (an empty `200` by default).
  const RevocationScript({
    this.status = 200,
    this.body = '',
    this.drop = false,
    this.delay = Duration.zero,
  });

  /// The HTTP status.
  final int status;

  /// The response body.
  final String body;

  /// Whether to destroy the connection instead of responding.
  final bool drop;

  /// How long to wait after reading the body before responding.
  final Duration delay;
}

/// One step of a scripted `/v1/responses` stream.
sealed class ScriptStep {
  const ScriptStep();
}

/// An SSE event frame.
final class SseEvent extends ScriptStep {
  /// A frame with an exact [event] name and raw [data] text.
  const SseEvent.raw({this.event, required this.data});

  /// A frame whose `data` is the JSON object [payload] with `type` set to
  /// [type], and whose `event:` line is [type].
  factory SseEvent.json(
    String type, [
    Map<String, Object?> payload = const {},
  ]) => SseEvent.raw(event: type, data: jsonEncode({'type': type, ...payload}));

  /// The `event:` line, or null to omit it.
  final String? event;

  /// The `data:` text. A newline starts another `data:` line.
  final String data;
}

/// An SSE comment line, which carries no event.
final class SseComment extends ScriptStep {
  /// Creates a comment with [text].
  const SseComment([this.text = 'keepalive']);

  /// The comment text.
  final String text;
}

/// A pause before the next step. Use a long duration to stall for the rest of
/// the test; closing the fake ends the wait.
final class Delay extends ScriptStep {
  /// Creates a pause of [duration].
  const Delay(this.duration);

  /// The pause length.
  final Duration duration;
}

/// Destroys the socket, so the client sees a truncated chunked body.
final class Drop extends ScriptStep {
  /// Creates a drop step.
  const Drop();
}

/// Bytes written to the stream unchanged, for malformed framing.
final class RawChunk extends ScriptStep {
  /// Creates a chunk of [text].
  const RawChunk(this.text);

  /// The text to write.
  final String text;
}

/// A scripted response of `POST /v1/responses`.
final class ResponsesScript {
  /// A streamed `200` event stream made of [steps], ended cleanly after the
  /// last step unless a [Drop] or a long [Delay] intervenes.
  ///
  /// [stallBeforeHeaders] waits after the request body is read and before
  /// the response headers are sent.
  const ResponsesScript.sse(
    this.steps, {
    this.stallBeforeHeaders = Duration.zero,
  }) : status = 200,
       errorBody = null,
       contentType = 'text/event-stream',
       headers = const {},
       dropBeforeHeaders = false;

  /// A plain error response with [status] and [body], for example
  /// `{"detail": "..."}` JSON or HTML.
  const ResponsesScript.error(
    this.status,
    String this.errorBody, {
    this.contentType = 'application/json',
    this.headers = const {},
    this.stallBeforeHeaders = Duration.zero,
  }) : steps = const [],
       dropBeforeHeaders = false;

  /// A JSON error response `{"error": {"code": code, "param": param}}`.
  factory ResponsesScript.errorCode(
    int status,
    String code, {
    String? param,
    Map<String, String> headers = const {},
  }) => ResponsesScript.error(
    status,
    jsonEncode({
      'error': {'code': code, 'message': 'fake', 'param': ?param},
    }),
    headers: headers,
  );

  /// Reads the body, then destroys the connection before any header.
  const ResponsesScript.dropBeforeHeaders()
    : status = 200,
      errorBody = null,
      contentType = 'text/event-stream',
      headers = const {},
      steps = const [],
      stallBeforeHeaders = Duration.zero,
      dropBeforeHeaders = true;

  /// The HTTP status.
  final int status;

  /// The error body, or null for an event stream.
  final String? errorBody;

  /// The response content type.
  final String contentType;

  /// Extra response headers, for example `retry-after`.
  final Map<String, String> headers;

  /// The event stream steps.
  final List<ScriptStep> steps;

  /// The wait between reading the request body and sending headers.
  final Duration stallBeforeHeaders;

  /// Whether to destroy the connection before sending headers.
  final bool dropBeforeHeaders;
}

/// A scripted response of `GET /v1/models`.
final class ModelsScript {
  /// A JSON [body] with [status].
  const ModelsScript.json(this.body, {this.status = 200})
    : contentType = 'application/json';

  /// A raw text [body] with [status].
  const ModelsScript.raw(
    String this.body,
    this.status, {
    this.contentType = 'text/html',
  });

  /// The body: a JSON-encodable value or a raw string.
  final Object body;

  /// The HTTP status.
  final int status;

  /// The response content type.
  final String contentType;
}

/// Returns the steps of a one-message text turn that ends with
/// `response.completed`.
List<ScriptStep> sseTextTurn(
  String text, {
  int inputTokens = 10,
  int outputTokens = 5,
}) => [
  SseEvent.json('response.created', {
    'response': {'id': 'resp_1'},
  }),
  SseEvent.json('response.output_text.delta', {'delta': text}),
  SseEvent.json('response.output_item.done', {
    'item': {
      'type': 'message',
      'role': 'assistant',
      'content': [
        {'type': 'output_text', 'text': text},
      ],
    },
  }),
  SseEvent.json('response.completed', {
    'response': {
      'id': 'resp_1',
      'usage': {'input_tokens': inputTokens, 'output_tokens': outputTokens},
    },
  }),
];

class _CodeSession {
  _CodeSession(this.nonce, this.clientId, this.codeChallenge);
  final String nonce;
  final String clientId;
  final String codeChallenge;
}

/// The fake OpenAI auth server and API on `127.0.0.1`.
final class FakeOpenAi {
  FakeOpenAi._(this._server, this.key, this.issuedClientId) {
    jwks = [key.jwk];
  }

  /// Starts a fake on an ephemeral loopback port.
  ///
  /// [key] is reused if given (key generation is slow), and [issuedClientId]
  /// is the id returned by the authorize endpoint. The server is closed by a
  /// test teardown.
  static Future<FakeOpenAi> start({
    FakeRsaKey? key,
    String issuedClientId = 'oaiapp_fake',
  }) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final fake = FakeOpenAi._(server, key ?? sharedKey, issuedClientId);
    server.listen(fake._handle, onError: (Object _) {});
    addTearDown(fake.close);
    return fake;
  }

  /// A key generated once per process and shared by fakes that do not ask for
  /// their own.
  static final FakeRsaKey sharedKey = FakeRsaKey.generate();

  final HttpServer _server;
  final Completer<void> _closing = Completer<void>();
  int _counter = 0;
  final Map<String, _CodeSession> _codes = {};

  /// The key that signs ID tokens and is published at the JWKS endpoint.
  final FakeRsaKey key;

  /// The client id the authorize endpoint issues for a new registration.
  String issuedClientId;

  /// The scope string returned in token responses.
  String grantedScope = fakeDefaultScope;

  /// The `sub` claim of ID tokens signed by default.
  String subject = 'user-123';

  /// The keys served at the JWKS endpoint.
  late List<Map<String, Object?>> jwks;

  /// Discovery document fields replaced or (with a null value) removed.
  final Map<String, Object?> discoveryOverrides = {};

  /// Status of the discovery endpoint; anything but 200 serves an empty body.
  int discoveryStatus = 200;

  /// Status of the JWKS endpoint; anything but 200 serves an empty body.
  int jwksStatus = 200;

  /// Scripted authorize responses, consumed first-in first-out.
  final Queue<AuthorizeScript> authorizeScripts = Queue();

  /// Scripted token responses, consumed first-in first-out.
  final Queue<TokenScript> tokenScripts = Queue();

  /// Scripted revocation responses, consumed first-in first-out.
  final Queue<RevocationScript> revocationScripts = Queue();

  /// Scripted `/v1/responses` responses, consumed first-in first-out.
  final Queue<ResponsesScript> responsesScripts = Queue();

  /// Scripted `/v1/models` responses, consumed first-in first-out.
  final Queue<ModelsScript> modelsScripts = Queue();

  /// The body served by `/v1/models` when no script is queued.
  Object defaultModels = {
    'models': [
      {
        'slug': 'gpt-fake',
        'display_name': 'GPT Fake',
        'visibility': 'list',
        'supported_in_api': true,
      },
    ],
  };

  /// Every request received, in order.
  final List<RecordedRequest> requests = [];

  /// Requests to the authorize endpoint (query holds all parameters).
  final List<RecordedRequest> authorizeRequests = [];

  /// Requests to the token endpoint (form holds the grant fields).
  final List<RecordedRequest> tokenRequests = [];

  /// Requests to the revocation endpoint (form holds the fields).
  final List<RecordedRequest> revocationRequests = [];

  /// Requests to discovery.
  final List<RecordedRequest> discoveryRequests = [];

  /// Requests to the JWKS endpoint.
  final List<RecordedRequest> jwksRequests = [];

  /// `POST /v1/responses` requests (`json` holds the decoded body).
  final List<RecordedRequest> responsesRequests = [];

  /// `GET /v1/models` requests.
  final List<RecordedRequest> modelsRequests = [];

  /// The base URL, for example `http://127.0.0.1:41234`.
  String get issuer => 'http://127.0.0.1:${_server.port}';

  /// The API base, `<issuer>/v1`, for the code's `apiBase` parameter.
  String get apiBase => '$issuer/v1';

  /// The loopback port.
  int get port => _server.port;

  /// The revocation endpoint advertised by discovery.
  String get revocationEndpoint => '$issuer/api/accounts/oauth/revoke';

  /// The JWKS URI advertised by discovery.
  String get jwksUri => '$issuer/.well-known/jwks.json';

  /// Stops the server, ends every stall and drops open connections.
  Future<void> close() async {
    if (!_closing.isCompleted) _closing.complete();
    await _server.close(force: true);
  }

  /// Signs an ID token with [key] (default: the served key).
  ///
  /// Claims default to a valid token for [issuer], the issued client id, one
  /// hour of lifetime and [subject]. A null [nonce] omits the claim, names in
  /// [omit] remove claims, and [extra] adds or replaces them. [alg] and [kid]
  /// set the header, so negative tests can use `none`, `HS256` or an unknown
  /// kid; pass [wrongKey] to sign with a key the JWKS does not hold.
  String signIdToken({
    String? iss,
    Object? aud,
    DateTime? exp,
    String? nonce,
    String? sub,
    String email = 'user@example.com',
    String? planType = 'plus',
    Set<String> omit = const {},
    Map<String, Object?> extra = const {},
    String alg = 'RS256',
    String? kid,
    FakeRsaKey? wrongKey,
  }) {
    final expiry = exp ?? DateTime.now().toUtc().add(const Duration(hours: 1));
    final claims = <String, Object?>{
      'iss': iss ?? issuer,
      'aud': aud ?? issuedClientId,
      'exp': expiry.millisecondsSinceEpoch ~/ 1000,
      'iat': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000,
      'sub': sub ?? subject,
      'email': email,
      'nonce': ?nonce,
      'https://api.openai.com/auth': {'chatgpt_plan_type': ?planType},
    };
    claims.removeWhere((name, _) => omit.contains(name));
    claims.addAll(extra);
    final signingKey = wrongKey ?? key;
    return signJwt(
      {'alg': alg, 'typ': 'JWT', 'kid': kid ?? signingKey.kid},
      claims,
      key: alg == 'none' ? null : signingKey,
    );
  }

  (String, String) _nextTokens() {
    _counter++;
    return ('access-$_counter', 'refresh-$_counter');
  }

  Future<void> _sleep(Duration duration) async {
    if (duration == Duration.zero || _closing.isCompleted) return;
    await Future.any([Future<void>.delayed(duration), _closing.future]);
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in request) {
        builder.add(chunk);
      }
      final headers = <String, String>{};
      request.headers.forEach((name, values) {
        headers[name] = values.join(',');
      });
      final recorded = RecordedRequest._(
        method: request.method,
        path: request.uri.path,
        query: request.uri.queryParameters,
        headers: headers,
        bodyBytes: builder.takeBytes(),
      );
      requests.add(recorded);
      switch ((request.method, request.uri.path)) {
        case ('GET', '/.well-known/openid-configuration'):
          discoveryRequests.add(recorded);
          await _discovery(request);
        case ('GET', '/.well-known/jwks.json'):
          jwksRequests.add(recorded);
          await _jwks(request);
        case ('GET', '/api/accounts/authorize'):
          authorizeRequests.add(recorded);
          await _authorize(request, recorded);
        case ('POST', '/api/accounts/oauth/token'):
          tokenRequests.add(recorded);
          await _token(request, recorded);
        case ('POST', '/api/accounts/oauth/revoke'):
          revocationRequests.add(recorded);
          await _revoke(request);
        case ('POST', '/v1/responses'):
          responsesRequests.add(recorded);
          await _responses(request);
        case ('GET', '/v1/models'):
          modelsRequests.add(recorded);
          await _models(request);
        default:
          await _plain(request, 404, 'not found', 'text/plain');
      }
    } on Object {
      // The client went away or the fake is closing; nothing to report.
    }
  }

  Future<void> _plain(
    HttpRequest request,
    int status,
    String body,
    String contentType, {
    Map<String, String> headers = const {},
  }) async {
    final response = request.response..statusCode = status;
    response.headers.set('content-type', contentType);
    headers.forEach(response.headers.set);
    response.write(body);
    await response.close();
  }

  Future<void> _discovery(HttpRequest request) async {
    if (discoveryStatus != 200) {
      return _plain(request, discoveryStatus, '', 'text/plain');
    }
    final document = <String, Object?>{
      'issuer': issuer,
      'authorization_endpoint': '$issuer/api/accounts/authorize',
      'token_endpoint': '$issuer/api/accounts/oauth/token',
      'jwks_uri': jwksUri,
      'revocation_endpoint': revocationEndpoint,
    };
    discoveryOverrides.forEach((name, value) {
      if (value == null) {
        document.remove(name);
      } else {
        document[name] = value;
      }
    });
    await _plain(request, 200, jsonEncode(document), 'application/json');
  }

  Future<void> _jwks(HttpRequest request) async {
    if (jwksStatus != 200) {
      return _plain(request, jwksStatus, '', 'text/plain');
    }
    await _plain(request, 200, jsonEncode({'keys': jwks}), 'application/json');
  }

  Future<void> _authorize(HttpRequest request, RecordedRequest recorded) async {
    final script = authorizeScripts.isEmpty
        ? const AuthorizeScript()
        : authorizeScripts.removeFirst();
    final query = recorded.query;
    final redirect = query['redirect_uri'];
    if (redirect == null) {
      return _plain(request, 400, 'missing redirect_uri', 'text/plain');
    }
    final requested = query['client_id'] ?? '';
    final issued =
        script.clientId ??
        (requested == 'dynamic_agent_client' || requested.isEmpty
            ? issuedClientId
            : requested);
    final state = script.omitState ? null : (script.state ?? query['state']);
    final params = <String, String>{'state': ?state};
    if (script.error != null) {
      params['error'] = script.error!;
    } else if (!script.omitCode) {
      final code = 'code-${++_counter}';
      _codes[code] = _CodeSession(
        query['nonce'] ?? '',
        issued,
        query['code_challenge'] ?? '',
      );
      params['code'] = code;
    }
    if (!script.omitClientId) params['client_id'] = issued;
    final location = Uri.parse(redirect).replace(
      queryParameters: {...Uri.parse(redirect).queryParameters, ...params},
    );
    request.response
      ..statusCode = HttpStatus.found
      ..headers.set('location', location.toString());
    await request.response.close();
  }

  Future<void> _destroy(HttpRequest request) async {
    final socket = await request.response.detachSocket(writeHeaders: false);
    socket.destroy();
  }

  Future<void> _token(HttpRequest request, RecordedRequest recorded) async {
    final script = tokenScripts.isEmpty
        ? TokenScript.success()
        : tokenScripts.removeFirst();
    await _sleep(script.delay);
    if (script.drop) return _destroy(request);
    final built = script._build(this, recorded.form);
    var status = script.status;
    var body = built;
    if (built is _TokenFailure) {
      status = built.status;
      body = built.body;
    }
    await _plain(
      request,
      status,
      body is String ? body : jsonEncode(body),
      script.contentType,
    );
  }

  Future<void> _revoke(HttpRequest request) async {
    final script = revocationScripts.isEmpty
        ? const RevocationScript()
        : revocationScripts.removeFirst();
    await _sleep(script.delay);
    if (script.drop) return _destroy(request);
    await _plain(request, script.status, script.body, 'text/plain');
  }

  Future<void> _models(HttpRequest request) async {
    final script = modelsScripts.isEmpty
        ? ModelsScript.json(defaultModels)
        : modelsScripts.removeFirst();
    final body = script.body;
    await _plain(
      request,
      script.status,
      body is String ? body : jsonEncode(body),
      script.contentType,
    );
  }

  Future<void> _responses(HttpRequest request) async {
    final script = responsesScripts.isEmpty
        ? ResponsesScript.errorCode(500, 'fake_unscripted')
        : responsesScripts.removeFirst();
    await _sleep(script.stallBeforeHeaders);
    if (_closing.isCompleted) return;
    if (script.dropBeforeHeaders) return _destroy(request);
    final errorBody = script.errorBody;
    if (errorBody != null) {
      return _plain(
        request,
        script.status,
        errorBody,
        script.contentType,
        headers: script.headers,
      );
    }
    // Write the response by hand so a step can destroy the socket after the
    // headers are out, which `HttpResponse` does not allow.
    final socket = await request.response.detachSocket(writeHeaders: false);
    void chunk(String text) {
      final bytes = utf8.encode(text);
      socket
        ..add(utf8.encode('${bytes.length.toRadixString(16)}\r\n'))
        ..add(bytes)
        ..add(utf8.encode('\r\n'));
    }

    socket.add(
      utf8.encode(
        'HTTP/1.1 200 OK\r\n'
        'content-type: ${script.contentType}\r\n'
        'cache-control: no-cache\r\n'
        'transfer-encoding: chunked\r\n\r\n',
      ),
    );
    await socket.flush();
    for (final step in script.steps) {
      if (_closing.isCompleted) break;
      switch (step) {
        case SseEvent(:final event, :final data):
          final lines = [
            if (event != null) 'event: $event',
            for (final line in data.split('\n')) 'data: $line',
          ];
          chunk('${lines.join('\n')}\n\n');
        case SseComment(:final text):
          chunk(': $text\n\n');
        case RawChunk(:final text):
          chunk(text);
        case Delay(:final duration):
          await socket.flush();
          await _sleep(duration);
        case Drop():
          socket.destroy();
          return;
      }
      await socket.flush();
    }
    if (_closing.isCompleted) {
      socket.destroy();
      return;
    }
    socket.add(utf8.encode('0\r\n\r\n'));
    await socket.flush();
    await socket.close();
  }
}

/// Asserts that [body] carries its tools only in a leading `additional_tools`
/// input item (design D7): `input[0]` has that type and the `developer` role,
/// no top-level `tools` key exists, and no other input item has that type.
///
/// A request with no tools has no such item; pass `expectTools: false` to
/// assert exactly that.
void expectAdditionalToolsOnly(
  Map<String, Object?> body, {
  bool expectTools = true,
}) {
  expect(body.containsKey('tools'), isFalse, reason: 'no top-level tools');
  final input = (body['input'] as List<Object?>).cast<Map<String, Object?>>();
  final extras = input.where((item) => item['type'] == 'additional_tools');
  if (!expectTools) {
    expect(extras, isEmpty);
    return;
  }
  expect(input, isNotEmpty);
  expect(input.first['type'], 'additional_tools');
  expect(input.first['role'], 'developer');
  expect(input.first['tools'], isA<List<Object?>>());
  expect(extras, hasLength(1), reason: 'exactly one additional_tools item');
}
