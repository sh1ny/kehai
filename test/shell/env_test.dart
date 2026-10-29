import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:kehai/src/tools/child_env.dart';
import 'package:test/test.dart';

import '../support/session_support.dart';

/// Names the spec makes credentials: a provider prefix and KEY, TOKEN or
/// SECRET.
const List<String> _credentials = [
  'OPENAI_API_KEY',
  'ANTHROPIC_API_KEY',
  'ANTHROPIC_AUTH_TOKEN',
  'AZURE_OPENAI_API_KEY',
  'GEMINI_API_KEY',
  'GEMINI_ACCESS_TOKEN',
  'KEHAI_SECRET',
  'KEHAI_OAUTH_TOKEN',
  'KEHAI_PROVIDER_KEY',
  'openai_api_key',
];

/// Names that stay: no provider prefix, or no KEY, TOKEN or SECRET.
const List<String> _kept = [
  'PATH',
  'GH_TOKEN',
  'AWS_SECRET_ACCESS_KEY',
  'OPENAI_ORG_ID',
  'OPENAI_BASE_URL',
  'KEHAI_HOME',
  'ANTHROPIC_MODEL',
  'MONKEY',
  'HOME',
];

Map<String, String> _base() => {
  for (final name in [..._credentials, ..._kept]) name: 'v-$name',
};

/// The environment of a real shell child, or null when no POSIX shell exists.
Future<Map<String, String>?> _childSees(Map<String, String> environment) async {
  final shell = detectShell().shell;
  if (shell == null || !shell.isPosix) return null;
  final cwd = (await tempDir()).path;
  final started = await startShell(
    shell,
    'env',
    workingDirectory: cwd,
    environment: environment,
  );
  final out = await utf8.decodeStream(started.process.stdout);
  await started.process.stderr.drain<void>();
  await started.process.exitCode;
  return {
    for (final line in const LineSplitter().convert(out))
      if (line.contains('='))
        line.substring(0, line.indexOf('=')): line.substring(
          line.indexOf('=') + 1,
        ),
  };
}

void main() {
  group('credential variables', () {
    test(
      'provider and KEHAI_ secret variables are absent in the child',
      () async {
        // The function that builds every shell and hook environment.
        final filtered = shellEnvironment(_base());
        expect(filtered.keys.toSet(), _kept.toSet());
        for (final name in _credentials) {
          expect(isCredentialVariable(name), isTrue, reason: name);
        }
        for (final name in _kept) {
          expect(isCredentialVariable(name), isFalse, reason: name);
        }

        // The tool child (ripgrep) and the direct-exec child drop them too.
        expect(childEnvironment(_base()).keys.toSet(), _kept.toSet());
        expect(directEnvironment(_base()).keys.toSet(), _kept.toSet());

        // A real shell process: GH_TOKEN stays, the API key does not.
        final seen = await _childSees(
          {
            ...Platform.environment,
            'OPENAI_API_KEY': 'sk-x',
            'KEHAI_SECRET': 's',
            'GH_TOKEN': 'g',
          }.let(shellEnvironment),
        );
        if (seen == null) {
          markTestSkipped('no POSIX shell on this host');
          return;
        }
        expect(seen['GH_TOKEN'], 'g');
        expect(seen, isNot(contains('OPENAI_API_KEY')));
        expect(seen, isNot(contains('KEHAI_SECRET')));
      },
    );

    test('configured passthrough variable reaches the child', () async {
      final base = {
        ..._base(),
        'OPENAI_API_KEY': 'sk-x',
        'Anthropic_Api_Key': 'a',
      };
      final filtered = shellEnvironment(
        base,
        passthrough: const ['OPENAI_API_KEY', 'anthropic_api_key'],
      );

      expect(filtered['OPENAI_API_KEY'], 'sk-x');
      expect(filtered['Anthropic_Api_Key'], 'a');
      expect(filtered, isNot(contains('GEMINI_API_KEY')));
      expect(filtered, isNot(contains('KEHAI_SECRET')));
      expect(
        passedThrough(base, const ['OPENAI_API_KEY', 'GH_TOKEN', 'NOPE']),
        unorderedEquals(['OPENAI_API_KEY', 'openai_api_key']),
      );
      expect(passedThrough(base, const []), isEmpty);

      final seen = await _childSees(
        {
          ...Platform.environment,
          'OPENAI_API_KEY': 'sk-x',
          'GEMINI_API_KEY': 'gk',
        }.let(
          (env) => shellEnvironment(env, passthrough: const ['OPENAI_API_KEY']),
        ),
      );
      if (seen == null) {
        markTestSkipped('no POSIX shell on this host');
        return;
      }
      expect(seen['OPENAI_API_KEY'], 'sk-x');
      expect(seen, isNot(contains('GEMINI_API_KEY')));
    });
  });
}

extension<T> on T {
  R let<R>(R Function(T value) f) => f(this);
}
