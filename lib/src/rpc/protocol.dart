/// Protocol v1 of `kehai rpc`: commands and event builders (design D11,
/// ADR 0011).
library;

import 'dart:convert';

/// The protocol version named in `hello`.
const int protocolVersion = 1;

/// The longest input line in bytes, excluding its newline (1 MiB).
const int maxLineBytes = 1024 * 1024;

final RegExp _requestId = RegExp(r'^[A-Za-z0-9_.:-]{1,128}$');

/// Whether [id] is a valid request id: 1-128 characters of `A-Z a-z 0-9 _ . : -`.
bool isValidRequestId(String id) => _requestId.hasMatch(id);

/// A line that is not a valid command; [message] is the `error` text.
final class ProtocolError implements Exception {
  /// Creates an error; [to] is the request id when the line named a usable one.
  const ProtocolError(this.message, {this.to});

  /// The text of the `error` reply.
  final String message;

  /// The request id the error answers, or null.
  final String? to;

  @override
  String toString() => 'ProtocolError: $message';
}

/// A client command.
sealed class Command {
  const Command();
}

/// `submit {id, text, turn}`.
final class SubmitCommand extends Command {
  /// Creates the command.
  const SubmitCommand(this.id, this.text, this.turn);

  /// The request id.
  final String id;

  /// The prompt.
  final String text;

  /// The last journal turn the client saw.
  final int turn;
}

/// `interrupt`.
final class InterruptCommand extends Command {
  /// Creates the command.
  const InterruptCommand();
}

/// `answer {key, text}`.
final class AnswerCommand extends Command {
  /// Creates the command.
  const AnswerCommand(this.key, this.text);

  /// The call key of the open prompt.
  final String key;

  /// The answer.
  final String text;
}

/// `status {id}`.
final class StatusCommand extends Command {
  /// Creates the command.
  const StatusCommand(this.id);

  /// The request id asked about.
  final String id;
}

/// Parses one input [line] into a command.
///
/// Throws a [ProtocolError] naming the problem for invalid JSON, a value that
/// is not an object, a missing or unknown `type`, or a malformed command.
Command parseCommand(String line) {
  final Object? decoded;
  try {
    decoded = jsonDecode(line);
  } on FormatException {
    throw const ProtocolError('invalid JSON');
  }
  if (decoded is! Map<String, Object?>) {
    throw const ProtocolError('a command must be a JSON object');
  }
  final type = decoded['type'];
  if (type is! String) {
    throw const ProtocolError('missing command type');
  }
  switch (type) {
    case 'submit':
      final id = _requestIdOf(decoded, 'submit');
      final text = decoded['text'];
      final turn = decoded['turn'];
      if (text is! String) {
        throw ProtocolError('malformed submit: text must be a string', to: id);
      }
      if (turn is! int || turn < 0) {
        throw ProtocolError(
          'malformed submit: turn must be a non-negative integer',
          to: id,
        );
      }
      return SubmitCommand(id, text, turn);
    case 'interrupt':
      return const InterruptCommand();
    case 'answer':
      final key = decoded['key'];
      final text = decoded['text'];
      if (key is! String || key.isEmpty) {
        throw const ProtocolError('malformed answer: key must be a string');
      }
      if (text is! String) {
        throw const ProtocolError('malformed answer: text must be a string');
      }
      return AnswerCommand(key, text);
    case 'status':
      return StatusCommand(_requestIdOf(decoded, 'status'));
    default:
      throw ProtocolError('unknown command ${_shown(type)}');
  }
}

String _requestIdOf(Map<String, Object?> command, String type) {
  final id = command['id'];
  if (id is! String || !isValidRequestId(id)) {
    throw ProtocolError(
      'malformed $type: id must be 1-128 characters of A-Z a-z 0-9 _ . : -',
    );
  }
  return id;
}

/// [text] cut to 64 characters with control characters replaced, for an error.
String _shown(String text) {
  final clean = String.fromCharCodes([
    for (final unit in text.runes) unit < 0x20 || unit == 0x7f ? 0x3f : unit,
  ]);
  return clean.length <= 64 ? clean : '${clean.substring(0, 64)}...';
}

/// `hello`: the first line, after resume finalization.
Map<String, Object?> helloEvent({
  required String session,
  required String workspace,
  required String model,
  required int requests,
  required int calls,
  required int jobs,
  required int exchanges,
}) => {
  'type': 'hello',
  'protocol': protocolVersion,
  'session': session,
  'workspace': workspace,
  'model': model,
  'resumed': {
    'requests': requests,
    'calls': calls,
    'jobs': jobs,
    'exchanges': exchanges,
  },
};

/// `snapshot`: the acknowledged [tree] at journal [turn] and log [offset].
///
/// A client applies the `update` events whose offset is at least [offset].
Map<String, Object?> snapshotEvent({
  required int offset,
  required int turn,
  required Map<String, Object?> tree,
}) => {'type': 'snapshot', 'offset': offset, 'turn': turn, 'tree': tree};

/// `update`: one committed record at its log offset.
Map<String, Object?> updateEvent(int offset, Map<String, Object?> record) => {
  'type': 'update',
  'offset': offset,
  'record': record,
};

/// `stream`: an ephemeral text or reasoning delta of the step at [turn].
Map<String, Object?> streamEvent(int turn, String kind, String delta) => {
  'type': 'stream',
  'turn': turn,
  'kind': kind,
  'delta': delta,
};

/// `reply`: the answer to the command [to].
Map<String, Object?> replyEvent(String to, [Map<String, Object?>? fields]) => {
  'type': 'reply',
  'to': to,
  'ok': true,
  ...?fields,
};

/// `error`: a refused command or a bad line, optionally for request [to].
Map<String, Object?> errorEvent(String message, {String? to}) => {
  'type': 'error',
  'to': ?to,
  'message': message,
};

/// `fatal`: the engine cannot go on and will exit 1.
Map<String, Object?> fatalEvent(String message) => {
  'type': 'fatal',
  'message': message,
};
