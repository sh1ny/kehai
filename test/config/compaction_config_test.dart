import 'dart:convert';
import 'dart:io';

import 'package:kehai/src/config/user_config.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;
  setUp(() {
    home = Directory('test/.compaction-config-tmp');
    home.createSync();
  });
  tearDown(() => home.deleteSync(recursive: true));

  UserConfig load(Map<String, Object?> json) {
    File('${home.path}/config.json').writeAsStringSync(jsonEncode(json));
    return UserConfig.load(home.path);
  }

  Map<String, Object?> config({
    Map<String, Object?> provider = const {},
    Map<String, Object?> route = const {},
    Map<String, Object?> model = const {},
  }) => {
    'providers': {
      'openai': {
        ...provider,
        'routes': {
          'chatgpt-account': {
            ...route,
            'models': {'gpt-6.1-sol': model},
          },
        },
      },
    },
  };

  EffectiveCompactionPolicy policy(
    UserConfig value, {
    String route = 'chatgpt-account',
  }) => value.effectiveCompaction('openai', route, 'gpt-6.1-sol');
  RouteCapacity capacity(
    UserConfig value, {
    String route = 'chatgpt-account',
  }) => value.resolveCapacity(
    'openai',
    route,
    'gpt-6.1-sol',
    backendContextWindow: 500000,
  );

  void refuses(Map<String, Object?> json, String setting, [String? detail]) {
    expect(
      () => load(json),
      throwsA(
        isA<ConfigError>().having(
          (e) => e.message,
          'message',
          allOf([
            contains('config.json:'),
            contains(setting),
            if (detail != null) contains(detail),
          ]),
        ),
      ),
    );
  }

  test('context-compaction: Model override', () {
    final value = load(
      config(
        provider: {
          'compaction': {'strategy': 'off', 'threshold': 100000},
        },
        route: {
          'compaction': {'strategy': 'provider_native', 'threshold': 90000},
        },
        model: {
          'compaction': {'threshold': 80000},
        },
      ),
    );
    final effective = policy(value);
    expect(effective.threshold, 80000);
    expect(effective.strategy.name, 'providerNative');
    expect(
      effective.thresholdSource,
      'providers.openai.routes.chatgpt-account.models.gpt-6.1-sol.compaction.threshold',
    );
    expect(
      effective.strategySource,
      'providers.openai.routes.chatgpt-account.compaction.strategy',
    );
    final partial = policy(
      load(
        config(
          provider: {
            'compaction': {'threshold': 120000},
          },
          model: {
            'compaction': {'strategy': 'off'},
          },
        ),
      ),
    );
    expect(partial.threshold, 120000);
    expect(partial.thresholdSource, 'providers.openai.compaction.threshold');
    expect(partial.strategy.name, 'off');
    final defaults = policy(const UserConfig());
    expect(defaults.threshold, 100000);
    expect(defaults.strategy.name, 'providerNative');
    expect(defaults.strategySource, 'built-in');
    expect(defaults.thresholdSource, 'built-in');
    expect(policy(const UserConfig(), route: 'other').strategy.name, 'off');
  });

  test('context-compaction: Invalid or reserved configuration', () {
    for (final scope in ['provider', 'route', 'model']) {
      Map<String, Object?> at(Map<String, Object?> entry) => config(
        provider: scope == 'provider' ? entry : const {},
        route: scope == 'route' ? entry : const {},
        model: scope == 'model' ? entry : const {},
      );
      final prefix =
          'providers.openai${scope == 'provider' ? '' : '.routes.chatgpt-account'}'
          '${scope == 'model' ? '.models.gpt-6.1-sol' : ''}';
      for (final bad in [999, 0, -1, 1000.5, '1000', null, true]) {
        refuses(
          at({
            'compaction': {'threshold': bad},
          }),
          '$prefix.compaction.threshold',
          'integer',
        );
      }
      for (final bad in ['local_summary', 'native', '', null, 1]) {
        refuses(
          at({
            'compaction': {'strategy': bad},
          }),
          '$prefix.compaction.strategy',
          bad == 'local_summary' ? 'not implemented' : null,
        );
      }
      refuses(
        at({
          'compaction': {'typo': true},
        }),
        '$prefix.compaction',
        'unknown key typo',
      );
      refuses(at({'compaction': null}), '$prefix.compaction', 'object');
      refuses(at({'typo': true}), prefix, 'unknown key typo');
    }
    expect(
      policy(
        load(
          config(
            model: {
              'compaction': {'threshold': 1000},
            },
          ),
        ),
      ).threshold,
      1000,
    );
    refuses({'providers': []}, 'providers', 'object');
    refuses(
      {
        'providers': {'openai': null},
      },
      'providers.openai',
      'object',
    );
    refuses(
      {
        'providers': {
          'openai': {'routes': <Object?>[]},
        },
      },
      'providers.openai.routes',
      'object',
    );
  });

  test('context-compaction: Explicit off', () {
    final value = load(
      config(
        route: {
          'compaction': {'strategy': 'off'},
        },
      ),
    );
    final effective = policy(value);
    expect(effective.strategy.name, 'off');
    expect(effective.threshold, 100000);
    expect(
      effective.strategySource,
      'providers.openai.routes.chatgpt-account.compaction.strategy',
    );
  });

  test('model-provider: Qualified window', () {
    final value = load(config(model: {'contextWindow': 160000}));
    final resolved = capacity(value);
    expect(resolved.contextWindow, 160000);
    expect(resolved.source, 'user-configured estimate');
    expect(resolved.backendContextWindow, 500000);
    expect(resolved.migrationNotice, isNull);
    expect(
      resolved.configPath,
      'providers.openai.routes.chatgpt-account.models.gpt-6.1-sol.contextWindow',
    );
  });

  test('model-provider: Legacy misleading window', () {
    final value = load({
      ...config(),
      'models': {
        'gpt-6.1-sol': {'contextWindow': 500000},
      },
    });
    expect(value.contextWindows['gpt-6.1-sol'], 500000);
    final resolved = capacity(value);
    expect(resolved.contextWindow, isNull);
    expect(resolved.source, 'unknown');
    expect(resolved.backendContextWindow, 500000);
    expect(resolved.legacyHint, 500000);
    expect(
      resolved.migrationNotice,
      allOf(
        contains('models.gpt-6.1-sol.contextWindow'),
        contains(
          'providers.openai.routes.chatgpt-account.models.gpt-6.1-sol.contextWindow',
        ),
        contains('unqualified'),
      ),
    );
    expect(capacity(value, route: 'other').contextWindow, 500000);
    expect(capacity(const UserConfig()).contextWindow, isNull);
    expect(capacity(const UserConfig(), route: 'other').contextWindow, 500000);
    final qualified = capacity(
      load({
        ...config(model: {'contextWindow': 160000}),
        'models': {
          'gpt-6.1-sol': {'contextWindow': 500000},
        },
      }),
    );
    expect(qualified.contextWindow, 160000);
    expect(qualified.migrationNotice, isNotNull);
  });

  test('model-provider: Invalid qualified capacity', () {
    const at = 'providers.openai.routes.chatgpt-account.models.gpt-6.1-sol';
    for (final bad in [0, -1, 1.5, '160000', null, true, <Object?>[]]) {
      refuses(
        config(model: {'contextWindow': bad}),
        '$at.contextWindow',
        'positive integer',
      );
    }
    refuses(config(model: {'window': 160000}), at, 'unknown key window');
    refuses(
      config(route: {'contextWindow': 160000}),
      'providers.openai.routes.chatgpt-account',
      'unknown key contextWindow',
    );
    expect(
      capacity(load(config(model: {'contextWindow': 1}))).contextWindow,
      1,
    );
  });
}
