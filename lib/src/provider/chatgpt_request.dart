/// The ChatGPT plan adapter's Responses request body (design D7).
///
/// The body is built from an explicit allowlist of keys, so a forbidden field
/// can never be constructed by accident.
library;

import 'dart:convert';

import '../auth/openai_constants.dart';
import 'provider.dart';

/// The package version sent in the `User-Agent` header.
const String kehaiVersion = '0.0.1';

/// The only top-level keys of a Responses request body (design D7).
const Set<String> chatGptBodyKeys = {
  'model',
  'instructions',
  'input',
  'tool_choice',
  'parallel_tool_calls',
  'reasoning',
  'include',
  'store',
  'stream',
  'prompt_cache_key',
};

/// Builds the request body for [request].
///
/// There is no top-level `tools` key. Tools travel in one `additional_tools`
/// item at the head of `input`, rebuilt on every call.
Map<String, Object?> buildChatGptBody(ModelRequest request) {
  final input = <Object?>[
    if (request.tools.isNotEmpty)
      {
        'type': 'additional_tools',
        'role': 'developer',
        'tools': [
          for (final tool in request.tools)
            {
              'type': 'function',
              'name': tool.name,
              'description': tool.description,
              'parameters': tool.parametersJsonSchema,
              'strict': false,
            },
        ],
      },
    for (final item in request.items) _inputItem(item),
  ];
  return {
    'model': request.model,
    'instructions': request.instructions,
    'input': input,
    'tool_choice': 'auto',
    'parallel_tool_calls': true,
    'reasoning': {'effort': ?request.reasoningEffort, 'summary': 'auto'},
    'include': const ['reasoning.encrypted_content'],
    'store': false,
    'stream': true,
    'prompt_cache_key': request.sessionId,
  };
}

Object? _inputItem(ConversationItem item) => switch (item) {
  UserMessage(:final text) => {
    'type': 'message',
    'role': 'user',
    'content': [
      {'type': 'input_text', 'text': text},
    ],
  },
  AssistantMessage(:final text) => {
    'type': 'message',
    'role': 'assistant',
    'content': [
      {'type': 'output_text', 'text': text},
    ],
  },
  ToolCallItem(:final callId, :final name, :final argumentsJson) => {
    'type': 'function_call',
    'call_id': callId,
    'name': name,
    'arguments': argumentsJson,
  },
  ToolOutputItem(:final callId, :final output) => {
    'type': 'function_call_output',
    'call_id': callId,
    'output': output,
  },
  OpaqueReasoningItem(:final json) => json,
};

/// Serializes [body] to UTF-8 JSON, or returns `null` when it exceeds
/// [openAiMaxRequestBodyBytes].
List<int>? encodeChatGptBody(Map<String, Object?> body) {
  final bytes = utf8.encode(jsonEncode(body));
  return bytes.length > openAiMaxRequestBodyBytes ? null : bytes;
}
