/// The fixed, versioned roster of tools the model may call.
library;

import '../provider/provider.dart';

/// One tool of the roster: what the model is told and what is validated.
final class ToolDefinition {
  /// Creates a definition. [version] is recorded on every call node.
  const ToolDefinition({
    required this.name,
    required this.version,
    required this.description,
    required this.schema,
  });

  /// The tool name.
  final String name;

  /// The integer version of the tool's behavior and arguments, at least 1.
  final int version;

  /// What the tool does, shown to the model.
  final String description;

  /// The JSON Schema of the arguments.
  final Map<String, Object?> schema;

  /// The provider-facing form of this tool.
  ToolSpec get spec => ToolSpec(
    name: name,
    description: description,
    parametersJsonSchema: schema,
  );
}

Map<String, Object?> _object(
  Map<String, Object?> properties, {
  List<String> required = const [],
}) => {
  'type': 'object',
  'properties': properties,
  'required': required,
  'additionalProperties': false,
};

const Map<String, Object?> _string = {'type': 'string'};
const Map<String, Object?> _path = {'type': 'string', 'minLength': 1};
const Map<String, Object?> _bool = {'type': 'boolean'};
const Map<String, Object?> _line = {'type': 'integer', 'minimum': 1};

/// The eleven tools, in the order the model sees them.
final List<ToolDefinition> toolDefinitions = List.unmodifiable([
  ToolDefinition(
    name: 'read',
    version: 1,
    description:
        'Read a text file with line numbers. Every 16th line carries an '
        'anchor to name in edit. Use offset and limit to read a window.',
    schema: _object(
      {'path': _path, 'offset': _line, 'limit': _line},
      required: ['path'],
    ),
  ),
  ToolDefinition(
    name: 'edit',
    version: 1,
    description:
        'Edit a text file by line numbers as last read. Name the anchor of '
        'every 16-line block the operations touch.',
    schema: _object(
      {
        'path': _path,
        'anchors': {'type': 'array', 'items': _string},
        'ops': {
          'type': 'array',
          'minItems': 1,
          'items': _object(
            {
              'op': {
                'type': 'string',
                'enum': ['replace', 'insert', 'delete'],
              },
              'start': _line,
              'end': _line,
              'after': {'type': 'integer', 'minimum': 0},
              'text': _string,
            },
            required: ['op'],
          ),
        },
      },
      required: ['path', 'anchors', 'ops'],
    ),
  ),
  ToolDefinition(
    name: 'write',
    version: 1,
    description:
        'Write a whole file, creating missing directories. Replaces any '
        'existing file.',
    schema: _object(
      {'path': _path, 'content': _string},
      required: ['path', 'content'],
    ),
  ),
  ToolDefinition(
    name: 'bash',
    version: 1,
    description:
        'Run a shell command in the workspace. A command still running after '
        'timeout_s keeps running as a background job.',
    schema: _object(
      {
        'command': _path,
        'cwd': _path,
        'timeout_s': {'type': 'integer', 'minimum': 1, 'maximum': 600},
        'deadline_s': {'type': 'integer', 'minimum': 1, 'maximum': 86400},
      },
      required: ['command'],
    ),
  ),
  ToolDefinition(
    name: 'grep',
    version: 1,
    description:
        'Search file contents with a regular expression. Returns '
        'path:line: text for each match.',
    schema: _object(
      {
        'pattern': _path,
        'path': _path,
        'glob': _path,
        'ignore_case': _bool,
        'literal': _bool,
      },
      required: ['pattern'],
    ),
  ),
  ToolDefinition(
    name: 'find',
    version: 1,
    description: 'List workspace files whose path matches a glob.',
    schema: _object(
      {'glob': _path, 'path': _path, 'hidden': _bool, 'no_ignore': _bool},
      required: ['glob'],
    ),
  ),
  ToolDefinition(
    name: 'ls',
    version: 1,
    description: 'List one directory. Directories end in / and links in @.',
    schema: _object({'path': _path}),
  ),
  ToolDefinition(
    name: 'ask',
    version: 1,
    description:
        'Ask the user a question, with up to 10 choices or free text. The '
        'answer is returned as JSON.',
    schema: _object(
      {
        'question': _path,
        'choices': {
          'type': 'array',
          'maxItems': 10,
          'uniqueItems': true,
          'items': _path,
        },
        'allow_text': _bool,
      },
      required: ['question'],
    ),
  ),
  ToolDefinition(
    name: 'job',
    version: 1,
    description:
        'Inspect or cancel a background job: status, wait, output or cancel.',
    schema: _object(
      {
        'id': _path,
        'action': {
          'type': 'string',
          'enum': ['status', 'wait', 'output', 'cancel'],
        },
        'timeout_s': {'type': 'integer', 'minimum': 1, 'maximum': 600},
      },
      required: ['id', 'action'],
    ),
  ),
  ToolDefinition(
    name: 'read_more',
    version: 1,
    description:
        'Page through a stored result by its handle, starting at a line.',
    schema: _object(
      {
        'handle': _path,
        'from': _line,
        'lines': {'type': 'integer', 'minimum': 1, 'maximum': 400},
      },
      required: ['handle'],
    ),
  ),
  ToolDefinition(
    name: 'search_result',
    version: 1,
    description:
        'Search a stored result by its handle with a regular expression.',
    schema: _object(
      {'handle': _path, 'pattern': _path},
      required: ['handle', 'pattern'],
    ),
  ),
]);
