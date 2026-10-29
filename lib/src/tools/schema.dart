/// Argument validation for tool calls against a small JSON Schema subset.
///
/// The subset is what the roster's schemas use: `type`, `required`,
/// `properties`, `additionalProperties: false`, `enum`, `minimum`, `maximum`,
/// `minLength`, `items`, `minItems`, `maxItems` and `uniqueItems`.
library;

import 'dart:convert';

/// The text of a call whose arguments are not a JSON object.
const String notAnObjectMessage = 'arguments are not a JSON object';

/// Parses [argumentsJson] as a JSON object.
///
/// Returns `null` when it is not valid JSON or not an object.
Map<String, Object?>? parseArguments(String argumentsJson) {
  try {
    final decoded = jsonDecode(argumentsJson);
    return decoded is Map<String, Object?> ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// Checks [value] against [schema] and returns every violation.
///
/// Each violation is `<field>: <rule>`, such as `path: expected string` or
/// `limit: minimum 1`; a nested field is named `ops[1].start`. The list is
/// empty when [value] is valid.
List<String> validateArguments(Map<String, Object?> schema, Object? value) {
  final out = <String>[];
  _check(schema, value, '', out);
  return out;
}

void _check(
  Map<String, Object?> schema,
  Object? value,
  String at,
  List<String> out,
) {
  final label = at.isEmpty ? 'arguments' : at;
  final type = schema['type'];
  if (type is String && !_isType(type, value)) {
    out.add('$label: expected $type');
    return;
  }
  final allowed = schema['enum'];
  if (allowed is List<Object?> && !allowed.contains(value)) {
    out.add('$label: must be one of ${allowed.join(', ')}');
    return;
  }
  if (value is num) {
    final min = schema['minimum'];
    if (min is num && value < min) out.add('$label: minimum $min');
    final max = schema['maximum'];
    if (max is num && value > max) out.add('$label: maximum $max');
  }
  if (value is String) {
    final min = schema['minLength'];
    if (min is int && value.length < min) out.add('$label: minLength $min');
  }
  if (value is Map<String, Object?>) {
    _checkObject(schema, value, at, out);
  }
  if (value is List<Object?>) {
    _checkArray(schema, value, at, label, out);
  }
}

void _checkObject(
  Map<String, Object?> schema,
  Map<String, Object?> value,
  String at,
  List<String> out,
) {
  String name(String key) => at.isEmpty ? key : '$at.$key';
  final properties = switch (schema['properties']) {
    final Map<String, Object?> map => map,
    _ => const <String, Object?>{},
  };
  final required = schema['required'];
  if (required is List<Object?>) {
    for (final key in required) {
      if (key is String && !value.containsKey(key)) {
        out.add('${name(key)}: required');
      }
    }
  }
  for (final MapEntry(:key, value: child) in value.entries) {
    final sub = properties[key];
    if (sub is Map<String, Object?>) {
      _check(sub, child, name(key), out);
    } else if (schema['additionalProperties'] == false) {
      out.add('${name(key)}: unknown field');
    }
  }
}

void _checkArray(
  Map<String, Object?> schema,
  List<Object?> value,
  String at,
  String label,
  List<String> out,
) {
  final min = schema['minItems'];
  if (min is int && value.length < min) out.add('$label: minItems $min');
  final max = schema['maxItems'];
  if (max is int && value.length > max) out.add('$label: maxItems $max');
  if (schema['uniqueItems'] == true && value.toSet().length != value.length) {
    out.add('$label: items must be distinct');
  }
  final items = schema['items'];
  if (items is Map<String, Object?>) {
    for (var i = 0; i < value.length; i++) {
      _check(items, value[i], '$at[$i]', out);
    }
  }
}

bool _isType(String type, Object? value) => switch (type) {
  'object' => value is Map<String, Object?>,
  'array' => value is List<Object?>,
  'string' => value is String,
  'integer' => value is int,
  'number' => value is num,
  'boolean' => value is bool,
  _ => true,
};
