/// Journal records: the four-field line format and its shape rules.
library;

import 'dart:convert';

import 'errors.dart';
import 'path.dart';

/// The operations a journal record can carry.
enum Op {
  /// Replaces the value at a path, creating missing parent maps.
  set('set'),

  /// Sets the given keys on the map at a path, creating it when absent.
  merge('merge'),

  /// Removes an existing path and its subtree.
  del('del'),

  /// Restores turn-anchored state to the end of an earlier turn.
  rewind('rewind');

  const Op(this.wire);

  /// The name of this operation in the journal.
  final String wire;

  /// Returns the operation named [name], or `null` when there is none.
  static Op? fromWire(String name) {
    for (final op in values) {
      if (op.wire == name) return op;
    }
    return null;
  }
}

/// One journal line: `{"turn":..,"path":..,"op":..,"value":..}`.
final class JournalRecord {
  /// Creates a record. Use [validateRecordShape] to check its content.
  const JournalRecord({
    required this.turn,
    required this.path,
    required this.op,
    this.value,
  });

  /// Parses one journal [line], with or without its trailing newline.
  ///
  /// Throws a [SessionError] with reason `invalid record` when the line is
  /// not a JSON object with exactly the keys `turn`, `path`, `op` and
  /// `value`, or when `turn` is not a non-negative integer, `path` is not a
  /// string or `op` is not in the vocabulary. The path text itself is not
  /// validated here; see [validateRecordShape].
  factory JournalRecord.parse(String line) {
    final Object? decoded;
    try {
      decoded = jsonDecode(line);
    } on FormatException catch (e) {
      throw SessionError('invalid record', 'not valid JSON: ${e.message}');
    }
    if (decoded
        case {
          'turn': final int turn,
          'path': final String path,
          'op': final String opName,
          'value': final Object? value,
        }
        when decoded.length == 4 && turn >= 0) {
      final op = Op.fromWire(opName);
      if (op != null) {
        return JournalRecord(turn: turn, path: path, op: op, value: value);
      }
    }
    throw const SessionError(
      'invalid record',
      'expected an object with exactly turn (non-negative integer), '
          'path (string), op (set, merge, del or rewind) and value',
    );
  }

  /// Parses [line] like [JournalRecord.parse], returning `null` on failure.
  static JournalRecord? tryParse(String line) {
    try {
      return JournalRecord.parse(line);
    } on SessionError {
      return null;
    }
  }

  /// The turn the record belongs to, a non-negative integer.
  final int turn;

  /// The `/`-separated target path; empty for the root.
  final String path;

  /// The operation to apply.
  final Op op;

  /// The operation payload, any JSON value.
  final Object? value;

  /// Encodes the record as one journal line.
  ///
  /// Keys appear in the order `turn`, `path`, `op`, `value`, with no
  /// whitespace, and a single trailing newline that marks the line committed.
  String encode() =>
      '${jsonEncode({'turn': turn, 'path': path, 'op': op.wire, 'value': value})}'
      '\n';
}

/// Checks that [record] is well formed, throwing a [SessionError] if not.
///
/// The turn must be non-negative, the value plain JSON and the path valid
/// ([SessionPath.parse]). The empty path is accepted only for the origin
/// record, which must be a `set` ([isOrigin] true), and for `rewind`, which
/// must use the empty path.
void validateRecordShape(JournalRecord record, {required bool isOrigin}) {
  final JournalRecord(:turn, :path, :op, :value) = record;
  try {
    if (turn < 0) {
      throw const SessionError('invalid record', 'turn must be non-negative');
    }
    if (!isJson(value)) {
      throw const SessionError('invalid record', 'value is not plain JSON');
    }
    final parsed = SessionPath.parse(path);
    if (op == Op.rewind) {
      if (!parsed.isEmpty) {
        throw const SessionError(
          'invalid path',
          'rewind must use the empty path',
        );
      }
    } else if (parsed.isEmpty && !isOrigin) {
      throw SessionError(
        'invalid path',
        'empty path is valid only for the origin record and rewind',
      );
    } else if (isOrigin && (op != Op.set || !parsed.isEmpty)) {
      throw const SessionError(
        'invalid path',
        'the origin record must be a set at the empty path',
      );
    }
  } on SessionError catch (e) {
    throw e.at(op.wire, path);
  }
}

/// Whether [value] is plain JSON: `null`, `bool`, finite `num`, `String`,
/// `List<Object?>` or `Map<String, Object?>`, nested to any depth.
bool isJson(Object? value) => switch (value) {
  null || bool() || String() => true,
  final num n => n.isFinite,
  final List<Object?> list => list.every(isJson),
  final Map<Object?, Object?> map =>
    map.keys.every((key) => key is String) && map.values.every(isJson),
  _ => false,
};
