import 'dart:convert';
import 'dart:io';

import 'package:kehai/src/config/user_config.dart';
import 'package:kehai/src/loop/sensorium.dart';
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
    group('sensorium configuration', () {
      test('absent and empty sensorium settings accept startup defaults', () {
        write({});
        expect(() => UserConfig.load(home.path), returnsNormally);
        write({'sensorium': <String, Object?>{}});
        expect(() => UserConfig.load(home.path), returnsNormally);
        expect(SensoriumAllocations.defaultMaxTokens, 1500);
        expect(
          SensoriumAllocations.defaultMaxTokens,
          greaterThanOrEqualTo(SensoriumAllocations.minimumMaxTokens),
        );
      });

      test(
        'valid sensorium minimum default and custom ceilings are accepted',
        () {
          for (final ceiling in [
            SensoriumAllocations.minimumMaxTokens,
            1500,
            2400,
          ]) {
            write({
              'sensorium': {'maxTokens': ceiling},
            });
            expect(
              () => UserConfig.load(home.path),
              returnsNormally,
              reason: 'valid startup ceiling $ceiling',
            );
          }
        },
      );

      test(
        'invalid sensorium maxTokens refuses configuration: below minimum',
        () {
          for (final ceiling in [-1, 0, 1, 1309]) {
            write({
              'sensorium': {'maxTokens': ceiling},
            });
            final error = refused();
            expect(error.path, path());
            expect(error.problem, startsWith('sensorium.maxTokens:'));
            expect(error.problem, contains('1310'));
          }
        },
      );

      test(
        'invalid sensorium maxTokens refuses configuration: non-integer',
        () {
          for (final ceiling in <Object?>[
            null,
            true,
            '1500',
            1500.0,
            1500.5,
            [],
            {},
          ]) {
            write({
              'sensorium': {'maxTokens': ceiling},
            });
            final error = refused();
            expect(error.path, path());
            expect(error.problem, startsWith('sensorium.maxTokens:'));
            expect(
              error.problem,
              contains('integer'),
              reason: jsonEncode(ceiling),
            );
          }
        },
      );

      test('sensorium rejects unknown nested settings', () {
        write({
          'sensorium': {'maxTokens': 1500, 'maxToken': 1600},
        });
        expect(refused().message, '${path()}: sensorium: unknown key maxToken');
      });

      test('sensorium requires an object rather than null or scalar', () {
        for (final value in <Object?>[null, true, '1500', 1500, []]) {
          write({'sensorium': value});
          expect(
            refused().message,
            '${path()}: sensorium: must be an object',
            reason: jsonEncode(value),
          );
        }
      });
    });
    group('collector deadline configuration', () {
      test('sensorium.collectorDeadlineMs accepts 100 through 10000 with VCS settings', () {
        for (final backend in ['auto', 'jj', 'git', 'none']) {
          for (final deadline in [100, 300, 10000]) {
            write({
              'vcs': {'backend': backend},
              'sensorium': {'collectorDeadlineMs': deadline},
            });
            final dynamic config = UserConfig.load(home.path);
            expect(config.vcs.backend, backend);
            expect(config.sensorium.collectorDeadlineMs, deadline);
          }
        }
      });

      test(
        'sensorium.collectorDeadlineMs outside 100–10000 refuses configuration',
        () {
          for (final deadline in [99, 10001, 0, -1]) {
            write({
              'sensorium': {'collectorDeadlineMs': deadline},
            });
            final error = refused();
            expect(error.path, path());
            expect(error.problem, startsWith('sensorium.collectorDeadlineMs:'));
          }
        },
      );

      test('sensorium.collectorDeadlineMs refuses non-integer values', () {
        for (final deadline in <Object?>[
          null,
          true,
          '300',
          300.0,
          300.5,
          [],
          {},
        ]) {
          write({
            'sensorium': {'collectorDeadlineMs': deadline},
          });
          final error = refused();
          expect(error.path, path());
          expect(error.problem, startsWith('sensorium.collectorDeadlineMs:'));
        }
      });
    });

    group('vcs configuration', () {
      test('vcs.backend defaults to auto and accepts supported values', () {
        write({});
        final dynamic defaults = UserConfig.load(home.path);
        expect(defaults.vcs.backend, 'auto');
        expect(defaults.sensorium.collectorDeadlineMs, 300);
        write({'vcs': <String, Object?>{}});
        final dynamic emptyVcs = UserConfig.load(home.path);
        expect(emptyVcs.vcs.backend, 'auto');

        for (final backend in ['auto', 'jj', 'git', 'none']) {
          write({
            'vcs': {'backend': backend},
          });
          final dynamic config = UserConfig.load(home.path);
          expect(config.vcs.backend, backend);
        }
      });

      test('invalid vcs.backend refuses configuration', () {
        for (final backend in <Object?>['svn', null, true, 1, [], {}]) {
          write({
            'vcs': {'backend': backend},
          });
          final error = refused();
          expect(error.path, path());
          expect(error.problem, startsWith('vcs.backend:'));
        }
      });

      test('vcs must be an object and rejects unknown nested keys', () {
        for (final vcs in <Object?>[null, true, 'git', 1, []]) {
          write({'vcs': vcs});
          final error = refused();
          expect(error.path, path());
          expect(error.problem, startsWith('vcs:'));
        }
        write({
          'vcs': {'backend': 'auto', 'branch': 'main'},
        });
        expect(refused().message, '${path()}: vcs: unknown key branch');
      });
    });

    for (final tool in ['scratch_set', 'scratch_del']) {
      test(
        '$tool explicit allow rule parses without autoapproval defaults',
        () {
          expect(UserConfig.load(home.path).allow, isEmpty);
          write({
            'allow': [
              {'tool': tool},
            ],
          });
          final config = UserConfig.load(home.path);
          expect(config.allow, hasLength(1));
          expect(config.allow.single.tool, tool);
          expect(config.allow.single.argv, isNull);
          expect(config.hooks, isEmpty);
        },
      );

      test('$tool hook selector parses with its configured policy', () {
        write({
          'hooks': [
            {
              'name': 'scratch-check',
              'argv': ['policy-check'],
              'tools': [tool],
              'policy': 'deny',
            },
          ],
        });
        final config = UserConfig.load(home.path);
        expect(config.allow, isEmpty);
        expect(config.hooks, hasLength(1));
        expect(config.hooks.single.tools, [tool]);
        expect(config.hooks.single.policy, HookPolicy.deny);
        expect(config.hooks.single.argv, ['policy-check']);
      });
    }

    test('scratch_pin remains unsupported in allow and hook rules', () {
      write({
        'allow': [
          {'tool': 'scratch_pin'},
        ],
      });
      expect(refused().message, contains('allow[0].tool: must be one of'));
      write({
        'hooks': [
          {
            'name': 'pin-check',
            'argv': ['policy-check'],
            'tools': ['scratch_pin'],
            'policy': 'deny',
          },
        ],
      });
      expect(refused().message, contains('hooks[0].tools[0]: must be one of'));
    });

    test('effort accepts every exact allowed value', () {
      for (final effort in [
        'none',
        'minimal',
        'low',
        'medium',
        'high',
        'xhigh',
      ]) {
        write({'effort': effort});
        final config = UserConfig.load(home.path);
        expect(config.effort, effort);
      }
    });

    test('missing effort defaults to null', () {
      final missing = UserConfig.load(home.path);
      expect(missing.effort, isNull);
      write(<String, Object?>{});
      final empty = UserConfig.load(home.path);
      expect(empty.effort, isNull);
    });

    test('invalid effort names config path even with valid flag', () {
      for (final bad in <Object?>[
        null,
        1,
        true,
        <Object?>[],
        <String, Object?>{},
        '',
        'turbo',
        'HIGH',
        ' high',
      ]) {
        write({'effort': bad});
        expect(
          refused().message,
          startsWith('${path()}: effort: must be one of '),
          reason: jsonEncode(bad),
        );
      }
    });

    test('missing config.json uses defaults', () {
      final config = UserConfig.load(home.path);

      expect(config.allow, isEmpty);
      expect(config.hooks, isEmpty);
      expect(config.rgPath, isNull);
      expect(config.envPassthrough, isEmpty);
      expect(config.model, isNull);
      expect(config.contextWindows, isEmpty);
      expect(config.agentModels, isEmpty);
    });

    test('agents.models aliases parse', () {
      write({
        'agents': {
          'models': {'sonnet': 'gpt-6.1-mini', 'haiku': 'gpt-6.1-nano'},
        },
      });

      expect(UserConfig.load(home.path).agentModels, {
        'sonnet': 'gpt-6.1-mini',
        'haiku': 'gpt-6.1-nano',
      });

      write({'agents': <String, Object?>{}});
      expect(UserConfig.load(home.path).agentModels, isEmpty);
    });

    test('bad agents settings refuse naming the path', () {
      write({
        'agents': {
          'models': {'sonnet': ''},
        },
      });
      expect(
        refused().message,
        '${path()}: agents.models.sonnet: must be a non-empty string',
      );

      write({
        'agents': {
          'models': {'sonnet': 3},
        },
      });
      expect(
        refused().message,
        '${path()}: agents.models.sonnet: must be a non-empty string',
      );

      write({
        'agents': {'roles': <String, Object?>{}},
      });
      expect(refused().message, '${path()}: agents: unknown key roles');

      write({'agents': <Object?>[]});
      expect(refused().message, '${path()}: agents: must be an object');

      write({
        'agents': {'models': <Object?>[]},
      });
      expect(refused().message, '${path()}: agents.models: must be an object');

      write({'agents': null});
      expect(refused().message, '${path()}: agents: must be an object');
    });

    test('model and models contextWindow parse', () {
      write({
        'model': 'gpt-5.5',
        'models': {
          'gpt-5.5': {'contextWindow': 200000},
          'other': <String, Object?>{},
        },
      });

      final config = UserConfig.load(home.path);

      expect(config.model, 'gpt-5.5');
      expect(config.contextWindows, {'gpt-5.5': 200000});
    });

    test('bad contextWindow or unknown model key refuses naming the path', () {
      for (final bad in <Object?>[0, -5, 1.5, '9', null]) {
        write({
          'models': {
            'gpt-5.5': {'contextWindow': bad},
          },
        });
        expect(
          refused().message,
          '${path()}: models.gpt-5.5.contextWindow: must be a positive integer',
          reason: '$bad',
        );
      }

      write({
        'models': {
          'gpt-5.5': {'window': 1},
        },
      });
      expect(
        refused().message,
        '${path()}: models.gpt-5.5: unknown key window',
      );

      write({'models': <Object?>[]});
      expect(refused().message, '${path()}: models: must be an object');

      write({
        'models': {'gpt-5.5': 3},
      });
      expect(refused().message, '${path()}: models.gpt-5.5: must be an object');

      write({'model': ''});
      expect(refused().message, '${path()}: model: must be a non-empty string');

      write({'model': 3});
      expect(refused().message, '${path()}: model: must be a non-empty string');
    });

    test('an explicit null is a wrong type, not an omitted field', () {
      const hook = {
        'name': 'h',
        'argv': ['x'],
        'tools': ['bash'],
        'policy': 'optional',
      };
      Map<String, Object?> withNull(String key) => {...hook, key: null};

      final cases = <(Object, String)>[
        ({'hooks': null}, 'hooks: must be a list'),
        ({'allow': null}, 'allow: must be a list'),
        ({'rgPath': null}, 'rgPath: must be a string'),
        ({'env': null}, 'env: must be an object'),
        (
          {
            'env': {'passthrough': null},
          },
          'env.passthrough: must be a list',
        ),
        (
          {
            'env': {
              'passthrough': [null],
            },
          },
          'env.passthrough[0]: must be an environment variable name',
        ),
        (
          {
            'allow': [
              {'tool': 'bash', 'argv': null},
            ],
          },
          'allow[0].argv: must be a list',
        ),
        (
          {
            'allow': [
              {'tool': null},
            ],
          },
          'allow[0].tool: must be one of',
        ),
        (
          {
            'allow': [null],
          },
          'allow[0]: must be an object',
        ),
        (
          {
            'hooks': [null],
          },
          'hooks[0]: must be an object',
        ),
        (
          {
            'hooks': [withNull('name')],
          },
          'hooks[0].name: must be',
        ),
        (
          {
            'hooks': [withNull('argv')],
          },
          'hooks[0].argv: must be a list',
        ),
        (
          {
            'hooks': [withNull('tools')],
          },
          'hooks[0].tools: must be a list',
        ),
        (
          {
            'hooks': [withNull('policy')],
          },
          'hooks[0].policy: must be',
        ),
        (
          {
            'hooks': [withNull('timeout_ms')],
          },
          'hooks[0].timeout_ms: must be',
        ),
      ];
      for (final (json, message) in cases) {
        write(json);
        expect(
          refused().message,
          startsWith('${path()}: $message'),
          reason: jsonEncode(json),
        );
      }

      // Omitted is still fine.
      write({
        'hooks': [hook],
        'env': <String, Object?>{},
        'allow': <Object?>[],
      });
      expect(UserConfig.load(home.path).hooks, hasLength(1));
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

    test('allow rules and hook tool lists accept skill and agent', () {
      write({
        'allow': [
          {'tool': 'skill'},
          {'tool': 'agent'},
        ],
        'hooks': [
          {
            'name': 'guard',
            'argv': ['guard'],
            'tools': ['skill', 'agent'],
            'policy': 'deny',
          },
        ],
      });

      final config = UserConfig.load(home.path);

      expect(config.allow.map((r) => r.tool), ['skill', 'agent']);
      expect(config.hooks.single.tools, ['skill', 'agent']);
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
