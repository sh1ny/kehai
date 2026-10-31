import 'dart:convert';

import 'package:kehai/kehai.dart';

import 'session_support.dart';

/// A journal turn as the 8 digits used in exchange and step keys.
String pad8(int turn) => turn.toString().padLeft(8, '0');

/// Writes exchange `x-<turn>` with [prompt] at journal [turn].
Future<void> seedExchange(
  SessionWriter writer,
  int turn,
  String prompt, {
  String state = 'done',
}) async {
  await writer.apply(
    rec(turn, 'body/exchanges/x-${pad8(turn)}', Op.set, {
      'request': 'r$turn',
      'prompt': prompt,
      'state': state,
      'first': turn,
    }),
  );
}

/// Writes step `s-<turn>` of the exchange that began at [exchange].
Future<void> seedStep(
  SessionWriter writer,
  int turn, {
  required int exchange,
  String state = 'completed',
  List<Map<String, Object?>> output = const [],
  Map<String, Object?>? usage,
  Map<String, Object?>? context,
  String? partial,
}) async {
  await writer.apply(
    rec(turn, 'body/steps/s-${pad8(turn)}', Op.set, {
      'exchange': 'x-${pad8(exchange)}',
      'model': 'gpt-5.5',
      'instructions': 'kehai-1',
      'state': state,
      'attempts': 1,
      'output': output,
      'usage': ?usage,
      'context': ?context,
      'partial': ?partial,
    }),
  );
}

/// The `call` entry of a step's `output`.
Map<String, Object?> callEntry(
  String callId,
  String name, [
  String arguments = '{}',
]) => {
  'type': 'call',
  'call': callKey(callId),
  'callId': callId,
  'name': name,
  'arguments': arguments,
};

/// The `text` entry of a step's `output`.
Map<String, Object?> textEntry(String text) => {'type': 'text', 'text': text};

/// Stores [text] as a result and registers its descriptor in the tree.
Future<Map<String, Object?>> seedResult(
  SessionWriter writer,
  ResultStore store,
  String text,
) async {
  final write = await store.storeResult(Stream.value(utf8.encode(text)));
  final descriptor = (write as ResultComplete).descriptor;
  await writer.recordResult(descriptor);
  return {'handle': descriptor.handle, 'complete': true};
}

/// Writes the call node of [callId] at the current turn.
///
/// With [modelText] the node carries a `model` reference; with [resultText] a
/// `result` reference. Without either it is a storage failure.
Future<void> seedCall(
  SessionWriter writer,
  ResultStore store, {
  required String callId,
  String tool = 'bash',
  String status = 'settled',
  String envelope = 'ok',
  String summary = 'done',
  String? modelText,
  String? resultText,
  Map<String, Object?> extra = const {},
}) async {
  final model = modelText == null
      ? null
      : await seedResult(writer, store, modelText);
  final result = resultText == null
      ? null
      : await seedResult(writer, store, resultText);
  await writer.apply(
    rec(writer.currentTurn, 'body/calls/${callKey(callId)}', Op.set, {
      'tool': tool,
      'version': 1,
      'callId': callId,
      'attempt': 'a',
      'input': <String, Object?>{},
      'status': status,
      'envelope': envelope,
      'summary': summary,
      'result': ?result,
      'model': ?model,
      ...extra,
    }),
  );
}
