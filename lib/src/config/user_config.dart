/// The user configuration file (design D15).
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'effort.dart';

/// The file name inside the Kehai home.
const String configFileName = 'config.json';

/// The deadline of a hook that sets no `timeout_ms`.
const Duration defaultHookTimeout = Duration(seconds: 10);

/// The largest `timeout_ms` a hook may set.
const int maxHookTimeoutMs = 600000;

/// The maximum decoded UTF-8 size of a captured child policy.
const int maxCapturedPolicyBytes = 8 * 1024;

/// The tool names a rule or hook may refer to.
const Set<String> toolRoster = {
  'read',
  'edit',
  'write',
  'bash',
  'grep',
  'find',
  'ls',
  'ask',
  'job',
  'read_more',
  'search_result',
  'skill',
  'agent',
};

/// A configuration file that cannot be used.
///
/// The engine refuses to start and prints [message].
final class ConfigError implements Exception {
  /// Creates an error for the file at [path] with the first [problem] found.
  const ConfigError(this.path, this.problem);

  /// The configuration file path.
  final String path;

  /// What was wrong, naming the JSON location when it is nested.
  final String problem;

  /// The line to print: `<path>: <problem>`.
  String get message => '$path: $problem';

  @override
  String toString() => 'ConfigError: $message';
}

/// What a hook does when it cannot give an answer.
enum HookPolicy {
  /// A failed hook is ignored.
  optional,

  /// A failed hook denies the tool call.
  deny,
}

/// A user allow rule: a tool, optionally narrowed to an argv prefix.
final class AllowRule {
  /// Creates a rule.
  const AllowRule(this.tool, [this.argv]);

  /// The tool the rule allows.
  final String tool;

  /// The argv prefix a call must start with, or null for any call.
  final List<String>? argv;

  /// The label decisions record, such as `bash:jj status`.
  String get label {
    final prefix = argv;
    return prefix == null ? tool : '$tool:${prefix.join(' ')}';
  }
}

/// A hook declared by the user.
final class HookConfig {
  /// Creates a hook.
  const HookConfig({
    required this.name,
    required this.argv,
    required this.tools,
    required this.policy,
    required this.timeout,
  });

  /// The unique hook name.
  final String name;

  /// The command and its arguments.
  final List<String> argv;

  /// The tools the hook applies to.
  final List<String> tools;

  /// What a failure of the hook means.
  final HookPolicy policy;

  /// The deadline for one run.
  final Duration timeout;
}

/// Supported policy vocabulary. Local summaries are reserved, not implemented.
enum CompactionStrategy {
  providerNative('provider_native'),
  localSummary('local_summary'),
  off('off');

  const CompactionStrategy(this.wireName);
  final String wireName;
}

/// A partial policy; omitted fields inherit independently.
final class CompactionSettings {
  const CompactionSettings({this.strategy, this.threshold});
  final CompactionStrategy? strategy;
  final int? threshold;
}

/// Fully resolved policy and the source of each field.
final class EffectiveCompactionPolicy {
  const EffectiveCompactionPolicy({
    required this.strategy,
    required this.threshold,
    required this.strategySource,
    required this.thresholdSource,
  });
  final CompactionStrategy strategy;
  final int threshold;
  final String strategySource;
  final String thresholdSource;
}

/// Provider defaults and route-specific overrides captured at startup.
final class ProviderConfig {
  const ProviderConfig({this.compaction, this.routes = const {}});
  final CompactionSettings? compaction;
  final Map<String, RouteConfig> routes;
}

/// Route defaults and model-specific overrides.
final class RouteConfig {
  const RouteConfig({this.compaction, this.models = const {}});
  final CompactionSettings? compaction;
  final Map<String, RouteModelConfig> models;
}

/// A model's route-qualified settings, never generic backend metadata.
final class RouteModelConfig {
  const RouteModelConfig({this.compaction, this.contextWindow});
  final CompactionSettings? compaction;
  final int? contextWindow;
}

/// Capacity evidence with raw metadata and legacy hints kept distinct.
final class RouteCapacity {
  const RouteCapacity({
    required this.contextWindow,
    required this.source,
    this.configPath,
    this.backendContextWindow,
    this.legacyHint,
    this.migrationNotice,
  });
  final int? contextWindow;
  final String source;
  final String? configPath;
  final int? backendContextWindow;
  final int? legacyHint;
  final String? migrationNotice;
}

/// The settings read once from `<kehai home>/config.json`.
final class UserConfig {
  /// Creates a configuration. With no arguments it is the defaults.
  const UserConfig({
    this.allow = const [],
    this.hooks = const [],
    this.rgPath,
    this.envPassthrough = const [],
    this.model,
    this.effort,
    this.contextWindows = const {},
    this.agentModels = const {},
    this.providers = const {},
  });

  /// Reads `config.json` from [home].
  ///
  /// A missing file gives the defaults. Throws a [ConfigError] naming the file
  /// and the first problem when the file is unreadable, is not valid JSON, has
  /// an unknown key, or holds a wrong type or an out-of-range value.
  factory UserConfig.load(String home) {
    final path = p.join(home, configFileName);
    final String text;
    try {
      if (FileSystemEntity.typeSync(path) == FileSystemEntityType.notFound) {
        return const UserConfig();
      }
      text = File(path).readAsStringSync();
    } on FileSystemException catch (e) {
      throw ConfigError(path, 'unreadable: ${e.message}');
    }
    final Object? json;
    try {
      json = jsonDecode(text);
    } on FormatException catch (e) {
      final offset = (e.offset ?? 0).clamp(0, text.length);
      final line = '\n'.allMatches(text.substring(0, offset)).length + 1;
      throw ConfigError(path, 'invalid JSON at line $line');
    }
    return _parse(path, json);
  }

  /// The allow rules.
  final List<AllowRule> allow;

  /// The hooks, in file order.
  final List<HookConfig> hooks;

  /// The `rg` executable, or null to find `rg` on `PATH`.
  final String? rgPath;

  /// The environment variable names a shell child may inherit.
  final List<String> envPassthrough;

  /// The default model id, or null when the file sets none.
  final String? model;

  /// The selected reasoning effort, or null for the provider default.
  final String? effort;

  /// The `models.<id>.contextWindow` overrides, by model id.
  final Map<String, int> contextWindows;

  /// The `agents.models` map from a role's model alias to a model id.
  final Map<String, String> agentModels;

  /// Captured provider/route/model settings, independent of backend metadata.
  final Map<String, ProviderConfig> providers;

  /// Encodes only validated provider policy for an internal child launch.
  ///
  /// Throws [ConfigError] rather than omitting fields above the 8 KiB limit.
  String captureProviderPolicy() {
    Map<String, Object?> settings(CompactionSettings value) => {
      if (value.strategy case final strategy?) 'strategy': strategy.wireName,
      'threshold': ?value.threshold,
    };
    final json = <String, Object?>{
      'providers': {
        for (final MapEntry(key: id, value: provider) in providers.entries)
          id: {
            if (provider.compaction case final policy?)
              'compaction': settings(policy),
            'routes': {
              for (final MapEntry(key: id, value: route)
                  in provider.routes.entries)
                id: {
                  if (route.compaction case final policy?)
                    'compaction': settings(policy),
                  'models': {
                    for (final MapEntry(key: id, value: model)
                        in route.models.entries)
                      id: {
                        if (model.compaction case final policy?)
                          'compaction': settings(policy),
                        'contextWindow': ?model.contextWindow,
                      },
                  },
                },
            },
          },
      },
    };
    final bytes = utf8.encode(jsonEncode(json));
    if (bytes.length > maxCapturedPolicyBytes) {
      throw const ConfigError(
        'compaction-policy',
        'captured policy exceeds 8 KiB',
      );
    }
    final encoded = base64Encode(bytes);
    decodeProviderPolicy(encoded);
    return encoded;
  }

  /// Validates a bounded, provider-only internal policy payload.
  ///
  /// Malformed encodings, unknown keys and invalid settings fail closed.
  static UserConfig decodeProviderPolicy(String encoded) {
    const path = 'compaction-policy';
    if (encoded.length > ((maxCapturedPolicyBytes + 2) ~/ 3) * 4) {
      throw const ConfigError(path, 'captured policy exceeds 8 KiB');
    }
    try {
      final bytes = base64Decode(encoded);
      if (bytes.length > maxCapturedPolicyBytes) {
        throw const ConfigError(path, 'captured policy exceeds 8 KiB');
      }
      final json = jsonDecode(utf8.decode(bytes));
      if (json case {'providers': final Map<String, Object?> _}) {
        if (json.length == 1) return _parse(path, json);
      }
      throw const ConfigError(path, 'expected provider-policy object');
    } on FormatException {
      throw const ConfigError(path, 'invalid captured policy encoding');
    }
  }

  /// Replaces provider settings with the parent's validated captured snapshot.
  ///
  /// Other startup settings retain their existing semantics, including effort.
  UserConfig withProviderPolicy(String encoded) => UserConfig(
    allow: allow,
    hooks: hooks,
    rgPath: rgPath,
    envPassthrough: envPassthrough,
    model: model,
    effort: effort,
    contextWindows: contextWindows,
    agentModels: agentModels,
    providers: decodeProviderPolicy(encoded).providers,
  );

  /// Resolves each field separately, retaining its exact source setting.
  EffectiveCompactionPolicy effectiveCompaction(
    String provider,
    String route,
    String model,
  ) {
    final providerConfig = providers[provider];
    final routeConfig = providerConfig?.routes[route];
    final base = 'providers.$provider';
    final routePath = '$base.routes.$route';
    var strategy = provider == 'openai' && route == 'chatgpt-account'
        ? CompactionStrategy.providerNative
        : CompactionStrategy.off;
    var threshold = 100000;
    var strategySource = 'built-in';
    var thresholdSource = 'built-in';
    for (final (settings, at) in [
      (providerConfig?.compaction, '$base.compaction'),
      (routeConfig?.compaction, '$routePath.compaction'),
      (
        routeConfig?.models[model]?.compaction,
        '$routePath.models.$model.compaction',
      ),
    ]) {
      if (settings?.strategy case final value?) {
        strategy = value;
        strategySource = '$at.strategy';
      }
      if (settings?.threshold case final value?) {
        threshold = value;
        thresholdSource = '$at.threshold';
      }
    }
    return EffectiveCompactionPolicy(
      strategy: strategy,
      threshold: threshold,
      strategySource: strategySource,
      thresholdSource: thresholdSource,
    );
  }

  /// Keeps raw metadata and legacy hints separate from route-qualified capacity.
  /// Callers must surface [RouteCapacity.migrationNotice] when present.
  RouteCapacity resolveCapacity(
    String provider,
    String route,
    String model, {
    int? backendContextWindow,
  }) {
    final at = 'providers.$provider.routes.$route.models.$model.contextWindow';
    final qualified =
        providers[provider]?.routes[route]?.models[model]?.contextWindow;
    final legacy = contextWindows[model];
    final chatgpt = provider == 'openai' && route == 'chatgpt-account';
    final effective =
        qualified ?? (chatgpt ? null : legacy ?? backendContextWindow);
    return RouteCapacity(
      contextWindow: effective,
      source: qualified != null
          ? 'user-configured estimate'
          : chatgpt || effective == null
          ? 'unknown'
          : legacy != null
          ? 'legacy model override'
          : 'backend metadata',
      configPath: qualified != null ? at : null,
      backendContextWindow: backendContextWindow,
      legacyHint: legacy,
      migrationNotice: chatgpt && legacy != null
          ? 'models.$model.contextWindow is an unqualified hint, not a '
                'ChatGPT-account capacity. Migrate it to $at.'
          : null,
    );
  }
}

UserConfig _parse(String path, Object? json) {
  if (json is! Map<String, Object?>) {
    throw ConfigError(path, 'must be a JSON object');
  }
  _noUnknown(path, '', json, const {
    'allow',
    'hooks',
    'rgPath',
    'env',
    'model',
    'effort',
    'models',
    'agents',
    'providers',
  });
  final rgPath = json['rgPath'];
  if (json.containsKey('rgPath') && (rgPath is! String || rgPath.isEmpty)) {
    throw ConfigError(
      path,
      'rgPath: must ${rgPath is String ? 'not be empty' : 'be a string'}',
    );
  }
  final model = json['model'];
  if (json.containsKey('model') && (model is! String || model.isEmpty)) {
    throw ConfigError(path, 'model: must be a non-empty string');
  }
  final effort = json['effort'];
  if (json.containsKey('effort') && !isValidEffort(effort)) {
    throw ConfigError(
      path,
      'effort: must be one of ${effortValues.join(', ')}',
    );
  }
  final rules = _list(
    path,
    'allow',
    json['allow'],
    absent: !json.containsKey('allow'),
  );
  final allow = [
    for (var i = 0; i < rules.length; i++) _rule(path, 'allow[$i]', rules[i]),
  ];
  final hooks = <HookConfig>[];
  final seen = <String>{};
  final raw = _list(
    path,
    'hooks',
    json['hooks'],
    absent: !json.containsKey('hooks'),
  );
  for (var i = 0; i < raw.length; i++) {
    final hook = _hook(path, 'hooks[$i]', raw[i]);
    if (!seen.add(hook.name)) {
      throw ConfigError(path, 'hooks[$i].name: duplicate hook ${hook.name}');
    }
    hooks.add(hook);
  }
  return UserConfig(
    allow: allow,
    hooks: hooks,
    rgPath: rgPath as String?,
    envPassthrough: _env(path, json),
    model: model as String?,
    effort: effort as String?,
    contextWindows: _models(path, json),
    agentModels: _agents(path, json),
    providers: _providers(path, json),
  );
}

Map<String, String> _agents(String path, Map<String, Object?> root) {
  if (!root.containsKey('agents')) return const {};
  final agents = _object(path, 'agents', root['agents']);
  _noUnknown(path, 'agents', agents, const {'models'});
  if (!agents.containsKey('models')) return const {};
  final map = _object(path, 'agents.models', agents['models']);
  return {
    for (final MapEntry(:key, :value) in map.entries)
      key: switch (value) {
        final String s when s.isNotEmpty => s,
        _ => throw ConfigError(
          path,
          'agents.models.$key: must be a non-empty string',
        ),
      },
  };
}

Map<String, int> _models(String path, Map<String, Object?> root) {
  if (!root.containsKey('models')) return const {};
  final map = _object(path, 'models', root['models']);
  final windows = <String, int>{};
  for (final MapEntry(:key, :value) in map.entries) {
    final at = 'models.$key';
    final entry = _object(path, at, value);
    _noUnknown(path, at, entry, const {'contextWindow'});
    if (!entry.containsKey('contextWindow')) continue;
    final window = entry['contextWindow'];
    if (window is! int || window < 1) {
      throw ConfigError(path, '$at.contextWindow: must be a positive integer');
    }
    windows[key] = window;
  }
  return windows;
}

AllowRule _rule(String path, String at, Object? json) {
  final map = _object(path, at, json);
  _noUnknown(path, at, map, const {'tool', 'argv'});
  final tool = _tool(path, '$at.tool', map['tool']);
  if (!map.containsKey('argv')) return AllowRule(tool);
  return AllowRule(tool, _strings(path, '$at.argv', map['argv']));
}

HookConfig _hook(String path, String at, Object? json) {
  final map = _object(path, at, json);
  _noUnknown(path, at, map, const {
    'name',
    'argv',
    'tools',
    'policy',
    'timeout_ms',
  });
  final name = map['name'];
  if (name is! String || name.isEmpty) {
    throw ConfigError(path, '$at.name: must be a non-empty string');
  }
  final argv = _strings(path, '$at.argv', map['argv']);
  final toolList = _list(path, '$at.tools', map['tools']);
  if (toolList.isEmpty) {
    throw ConfigError(path, '$at.tools: must be a non-empty list');
  }
  final tools = [
    for (var i = 0; i < toolList.length; i++)
      _tool(path, '$at.tools[$i]', toolList[i]),
  ];
  final policy = switch (map['policy']) {
    'optional' => HookPolicy.optional,
    'deny' => HookPolicy.deny,
    _ => throw ConfigError(path, '$at.policy: must be "optional" or "deny"'),
  };
  var timeout = defaultHookTimeout;
  if (map.containsKey('timeout_ms')) {
    final ms = map['timeout_ms'];
    if (ms is! int || ms < 1 || ms > maxHookTimeoutMs) {
      throw ConfigError(
        path,
        '$at.timeout_ms: must be 1..$maxHookTimeoutMs (hook $name)',
      );
    }
    timeout = Duration(milliseconds: ms);
  }
  return HookConfig(
    name: name,
    argv: argv,
    tools: tools,
    policy: policy,
    timeout: timeout,
  );
}

List<String> _env(String path, Map<String, Object?> root) {
  if (!root.containsKey('env')) return const [];
  final map = _object(path, 'env', root['env']);
  _noUnknown(path, 'env', map, const {'passthrough'});
  final names = _list(
    path,
    'env.passthrough',
    map['passthrough'],
    absent: !map.containsKey('passthrough'),
  );
  final valid = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
  return [
    for (var i = 0; i < names.length; i++)
      switch (names[i]) {
        final String s when valid.hasMatch(s) => s,
        _ => throw ConfigError(
          path,
          'env.passthrough[$i]: must be an environment variable name',
        ),
      },
  ];
}

String _tool(String path, String at, Object? json) {
  if (json is String && toolRoster.contains(json)) return json;
  throw ConfigError(
    path,
    '$at: must be one of ${(toolRoster.toList()..sort()).join(', ')}',
  );
}

List<String> _strings(String path, String at, Object? json) {
  final list = _list(path, at, json);
  if (list.isEmpty) throw ConfigError(path, '$at: must be a non-empty list');
  return [
    for (var i = 0; i < list.length; i++)
      switch (list[i]) {
        final String s => s,
        _ => throw ConfigError(path, '$at[$i]: must be a string'),
      },
  ];
}

List<Object?> _list(
  String path,
  String at,
  Object? json, {
  bool absent = false,
}) {
  // Only a key that is not in the file is optional; an explicit null is a
  // wrong type.
  if (absent) return const [];
  if (json is List<Object?>) return json;
  throw ConfigError(path, '$at: must be a list');
}

Map<String, Object?> _object(String path, String at, Object? json) {
  if (json is Map<String, Object?>) return json;
  throw ConfigError(path, '$at: must be an object');
}

void _noUnknown(
  String path,
  String at,
  Map<String, Object?> map,
  Set<String> known,
) {
  for (final key in map.keys) {
    if (!known.contains(key)) {
      throw ConfigError(
        path,
        at.isEmpty ? 'unknown key $key' : '$at: unknown key $key',
      );
    }
  }
}

Map<String, ProviderConfig> _providers(String path, Map<String, Object?> root) {
  if (!root.containsKey('providers')) return const {};
  final providers = _object(path, 'providers', root['providers']);
  return Map.unmodifiable({
    for (final MapEntry(:key, :value) in providers.entries)
      key: _provider(path, 'providers.$key', value),
  });
}

ProviderConfig _provider(String path, String at, Object? value) {
  final map = _object(path, at, value);
  _noUnknown(path, at, map, const {'compaction', 'routes'});
  final routes = map.containsKey('routes')
      ? _object(path, '$at.routes', map['routes'])
      : const <String, Object?>{};
  return ProviderConfig(
    compaction: _compaction(path, at, map),
    routes: Map.unmodifiable({
      for (final MapEntry(:key, :value) in routes.entries)
        key: _route(path, '$at.routes.$key', value),
    }),
  );
}

RouteConfig _route(String path, String at, Object? value) {
  final map = _object(path, at, value);
  _noUnknown(path, at, map, const {'compaction', 'models'});
  final models = map.containsKey('models')
      ? _object(path, '$at.models', map['models'])
      : const <String, Object?>{};
  return RouteConfig(
    compaction: _compaction(path, at, map),
    models: Map.unmodifiable({
      for (final MapEntry(:key, :value) in models.entries)
        key: _routeModel(path, '$at.models.$key', value),
    }),
  );
}

RouteModelConfig _routeModel(String path, String at, Object? value) {
  final map = _object(path, at, value);
  _noUnknown(path, at, map, const {'compaction', 'contextWindow'});
  int? window;
  if (map.containsKey('contextWindow')) {
    final raw = map['contextWindow'];
    if (raw is! int || raw < 1) {
      throw ConfigError(path, '$at.contextWindow: must be a positive integer');
    }
    window = raw;
  }
  return RouteModelConfig(
    compaction: _compaction(path, at, map),
    contextWindow: window,
  );
}

CompactionSettings? _compaction(
  String path,
  String parent,
  Map<String, Object?> map,
) {
  if (!map.containsKey('compaction')) return null;
  final at = '$parent.compaction';
  final settings = _object(path, at, map['compaction']);
  _noUnknown(path, at, settings, const {'strategy', 'threshold'});
  CompactionStrategy? strategy;
  if (settings.containsKey('strategy')) {
    strategy = switch (settings['strategy']) {
      'provider_native' => CompactionStrategy.providerNative,
      'off' => CompactionStrategy.off,
      'local_summary' => throw ConfigError(
        path,
        '$at.strategy: local_summary is reserved and not implemented',
      ),
      _ => throw ConfigError(
        path,
        '$at.strategy: must be provider_native, local_summary or off',
      ),
    };
  }
  int? threshold;
  if (settings.containsKey('threshold')) {
    final raw = settings['threshold'];
    if (raw is! int || raw < 1000) {
      throw ConfigError(
        path,
        '$at.threshold: must be an integer at least 1000',
      );
    }
    threshold = raw;
  }
  return CompactionSettings(strategy: strategy, threshold: threshold);
}
