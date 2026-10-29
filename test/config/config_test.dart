import 'dart:convert';
import 'dart:io';

import 'package:kehai/src/config/user_config.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() {
    home = Directory.systemTemp.createTempSync('kehai_config_');
  });

  tearDown(() {
    if (home.existsSync()) home.deleteSync(recursive: true);
  });

  String path() => p.join(home.path, 'config.json');

  void write(Object? json) =>
      File(path()).writeAsStringSync(json is String ? json : jsonEncode(json));

  ConfigError refused() {
    try {
      UserConfig.load(home.path);
    } on ConfigError catch (e) {
      return e;
    }
    fail('expected a ConfigError');
  }

  group('config', () {
    test('missing config.json uses defaults', () {
      final config = UserConfig.load(home.path);

      expect(config.allow, isEmpty);
      expect(config.hooks, isEmpty);
      expect(config.rgPath, isNull);
      expect(config.envPassthrough, isEmpty);
    });

    test('unknown key or bad type refuses to start naming the path', () {
      write('{"allow": [], "allwo": []}');
      expect(refused().message, '${path()}: unknown key allwo');

      write('{"allow": [], ');
      expect(refused().message, startsWith('${path()}: invalid JSON at line '));

      write('{\n"allow": [],\n\n"hooks": [}');
      expect(refused().message, '${path()}: invalid JSON at line 4');

      write('[]');
      expect(refused().message, '${path()}: must be a JSON object');

      write({'allow': 'bash'});
      expect(refused().message, '${path()}: allow: must be a list');

      write({'rgPath': 3});
      expect(refused().message, '${path()}: rgPath: must be a string');

      write({
        'allow': [
          {'tool': 'bash', 'argc': <String>[]},
        ],
      });
      expect(refused().message, '${path()}: allow[0]: unknown key argc');

      write({
        'allow': [
          {'tool': 'nope'},
        ],
      });
      expect(refused().message, contains('${path()}: allow[0].tool: '));
    });

    test('an unreadable config path refuses to start naming the path', () {
      Directory(path()).createSync();

      expect(refused().message, startsWith('${path()}: '));
    });

    test('invalid timeout_ms refuses to start', () {
      for (final bad in <Object>[0, -1, 600001, 1.5, '10']) {
        write({
          'hooks': [
            {
              'name': 'guard',
              'argv': ['/usr/bin/guard'],
              'tools': ['bash'],
              'policy': 'deny',
              'timeout_ms': bad,
            },
          ],
        });
        expect(
          refused().message,
          '${path()}: hooks[0].timeout_ms: must be 1..600000 (hook guard)',
          reason: '$bad',
        );
      }
    });

    test('a full configuration parses', () {
      write({
        'allow': [
          {
            'tool': 'bash',
            'argv': ['jj', 'status'],
          },
          {'tool': 'edit'},
        ],
        'hooks': [
          {
            'name': 'guard',
            'argv': ['/usr/bin/guard'],
            'tools': ['bash'],
            'policy': 'deny',
            'timeout_ms': 5000,
          },
          {
            'name': 'note',
            'argv': ['note'],
            'tools': ['edit', 'write'],
            'policy': 'optional',
          },
        ],
        'rgPath': '/opt/rg',
        'env': {
          'passthrough': ['OPENAI_API_KEY'],
        },
      });

      final config = UserConfig.load(home.path);

      expect(config.allow.map((r) => r.label), ['bash:jj status', 'edit']);
      expect(config.allow[0].tool, 'bash');
      expect(config.allow[0].argv, ['jj', 'status']);
      expect(config.allow[1].argv, isNull);
      expect(config.hooks[0].name, 'guard');
      expect(config.hooks[0].policy, HookPolicy.deny);
      expect(config.hooks[0].tools, ['bash']);
      expect(config.hooks[0].timeout, const Duration(seconds: 5));
      expect(config.hooks[1].policy, HookPolicy.optional);
      expect(config.hooks[1].timeout, defaultHookTimeout);
      expect(config.rgPath, '/opt/rg');
      expect(config.envPassthrough, ['OPENAI_API_KEY']);
    });

    test('hook shape problems name the path and the hook', () {
      Map<String, Object?> hook(Map<String, Object?> over) => {
        'name': 'guard',
        'argv': ['x'],
        'tools': ['bash'],
        'policy': 'deny',
        ...over,
      };
      void expectProblem(Map<String, Object?> over, String problem) {
        write({
          'hooks': [hook(over)],
        });
        expect(refused().message, '${path()}: $problem');
      }

      expectProblem({'name': ''}, 'hooks[0].name: must be a non-empty string');
      expectProblem({'argv': []}, 'hooks[0].argv: must be a non-empty list');
      expectProblem({
        'argv': [1],
      }, 'hooks[0].argv[0]: must be a string');
      expectProblem({'tools': []}, 'hooks[0].tools: must be a non-empty list');
      expectProblem({
        'policy': 'warn',
      }, 'hooks[0].policy: must be "optional" or "deny"');
      expectProblem({'extra': 1}, 'hooks[0]: unknown key extra');

      write({
        'hooks': [hook({}), hook({})],
      });
      expect(
        refused().message,
        '${path()}: hooks[1].name: duplicate hook guard',
      );
    });

    test('env passthrough names must be variable names', () {
      write({
        'env': {
          'passthrough': ['A=B'],
        },
      });
      expect(
        refused().message,
        '${path()}: env.passthrough[0]: must be an environment variable name',
      );

      write({
        'env': {'other': <String>[]},
      });
      expect(refused().message, '${path()}: env: unknown key other');
    });
  });
}
