import 'dart:convert';

import 'package:kehai/src/auth/failure_text.dart';
import 'package:test/test.dart';

const _access = 'at_9f8e7d6c5b4a';
const _refresh = 'rt_1a2b3c4d5e6f';
const _idToken = 'eyjhbgcioijsuzi1niisimtpzci6imsxin0';
const _authCode = 'code_abcdef123456';
const _verifier = 'dbjftjez4cvp_mb92k27uhbuju1p1r_ww1gfwfoejxk';
const _state = 'state_0011223344';
const _nonce = 'nonce_5566778899';

const _secrets = [
  _access,
  _refresh,
  _idToken,
  _authCode,
  _verifier,
  _state,
  _nonce,
];

List<int> _json(Object? value) => utf8.encode(jsonEncode(value));

void main() {
  final text = FailureText(secrets: _secrets);

  test('echoed secrets in message, code or param never surface', () {
    for (final secret in _secrets) {
      final body = _json({
        'error': {
          'code': 'x_${secret}_y',
          'param': 'input[$secret]',
          'message': 'bad credential $secret',
        },
        'error_description': 'echo $secret',
        'detail': 'echo $secret',
      });
      final fields = text.parseErrorBody(body);
      final failure = text.compose(
        FailureKind.refreshFailed,
        status: 400,
        code: fields.code,
        param: fields.param,
      );
      expect(failure.code, 'unrecognized', reason: secret);
      expect(failure.param, isNull, reason: secret);
      for (final other in _secrets) {
        expect(failure.message, isNot(contains(other)));
      }
      expect(failure.message, contains('HTTP 400'));
      expect(failure.message, contains('(unrecognized)'));
    }
    // A string-valued `error` that equals a secret is also rejected.
    final flat = text.parseErrorBody(_json({'error': _refresh}));
    final failure = text.compose(FailureKind.refreshFailed, code: flat.code);
    expect(failure.code, 'unrecognized');
    expect(failure.message, isNot(contains(_refresh)));
  });

  test('server message and detail fields are dropped', () {
    final body = _json({
      'error': {
        'code': 'context_length_exceeded',
        'param': 'input[0].tools[0]',
        'message': 'Please contact evil@example.test about your quota',
      },
      'error_description': 'visit http://evil.example.test',
      'detail': 'secret internal detail',
    });
    final fields = text.parseErrorBody(body);
    expect(fields.code, 'context_length_exceeded');
    expect(fields.param, 'input[0].tools[0]');

    final failure = text.compose(
      FailureKind.contextOverflow,
      status: 400,
      code: fields.code,
      param: fields.param,
    );
    expect(failure.code, 'context_length_exceeded');
    expect(failure.param, 'input[0].tools[0]');
    expect(failure.message, contains('context_length_exceeded'));
    expect(failure.message, contains('input[0].tools[0]'));
    for (final leaked in ['evil', 'quota', 'internal detail', 'visit']) {
      expect(failure.message, isNot(contains(leaked)));
    }
    expect(failure.message.length, lessThanOrEqualTo(500));

    // A `detail` body, an HTML body and a non-JSON body yield no code.
    expect(text.parseErrorBody(_json({'detail': 'oops'})).code, isNull);
    expect(text.parseErrorBody(utf8.encode('<html>500</html>')).code, isNull);
    expect(text.parseErrorBody(_json([1, 2])).code, isNull);
    final plain = text.compose(FailureKind.modelRequest, status: 500);
    expect(plain.message, 'model request failed: HTTP 500');
    expect(plain.code, isNull);

    // Oversized bodies are not parsed.
    final big = utf8.encode(
      jsonEncode({'error': 'invalid_grant', 'pad': 'x' * (64 * 1024)}),
    );
    expect(text.parseErrorBody(big).code, isNull);
  });

  test('uppercase, long or secret-bearing codes become unrecognized', () {
    String? codeOf(String raw) =>
        text.compose(FailureKind.modelRequest, status: 500, code: raw).code;

    expect(codeOf('Invalid_Grant'), 'unrecognized');
    expect(codeOf('a' * 65), 'unrecognized');
    expect(codeOf(''), 'unrecognized');
    expect(codeOf('has space'), 'unrecognized');
    expect(codeOf('has-dash'), 'unrecognized');
    expect(codeOf('pre_$_state'), 'unrecognized');
    expect(codeOf('a' * 64), 'a' * 64);
    expect(codeOf('subscription_sharing.v2_9'), 'subscription_sharing.v2_9');

    final failure = text.compose(
      FailureKind.modelRequest,
      status: 500,
      code: 'Bad',
    );
    expect(failure.message, 'model request failed: HTTP 500 (unrecognized)');

    // Parameters: pattern violations and secrets are dropped, not replaced.
    String? paramOf(String raw) =>
        text.compose(FailureKind.invalidRequest, param: raw).param;
    expect(paramOf('input[0].tools[0]'), 'input[0].tools[0]');
    expect(paramOf('bad param'), isNull);
    expect(paramOf('p' * 65), isNull);
    expect(paramOf('p' * 64), 'p' * 64);
  });
}
