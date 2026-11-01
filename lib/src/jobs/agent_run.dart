/// The parent side of an agent job (design D8).
///
/// [AgentRun] is the [JobChannel] of an agent job: a complete RPC v1 state
/// consumer of the child engine. It frames the child's stdout into lines,
/// keeps a mirror of the child's tree, sends the one `submit`, and decides how
/// the child's exchange ended from the mirror alone. Stream events are
/// progress only and never decide anything.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../client/mirror.dart';
import '../client/render.dart' show agentProgressLine;
import '../session/record.dart';
import '../rpc/protocol.dart' show protocolVersion;
import 'supervisor.dart';

/// Called with a child's `prompt` item (the relay, design D10).
typedef AgentPromptHandler = void Function(Map<String, Object?> item);

/// Called with the key of a child's `withdraw`.
typedef AgentWithdrawHandler = void Function(String key);

/// Called with the one-line progress of a child call that settled (design
/// D13).
typedef AgentProgressHandler = void Function(String line);

/// The longest child output line the parent buffers: 64 MiB.
const int maxChildLineBytes = 64 * 1024 * 1024;

/// The id of the one `submit` sent to a child.
const String agentRequestId = 'agent';

/// The message of a line over [maxChildLineBytes].
const String childLineTooLong = 'child protocol line over 64 MiB';

/// A complete RPC v1 state consumer of one child engine (design D8).
final class AgentRun implements JobChannel {
  /// Creates the consumer of a child running [role] on [prompt].
  AgentRun({
    required this.role,
    required this.prompt,
    this.modelNote,
    this.lineLimit = maxChildLineBytes,
    this.onPrompt,
    this.onWithdraw,
    this.onProgress,
    this.onStop,
  });

  /// The role's name.
  final String role;

  /// The prompt the child's one exchange runs.
  final String prompt;

  /// The model note for the typed result, or `null`.
  final String? modelNote;

  /// The longest line buffered, in bytes.
  final int lineLimit;

  /// Where relayed prompts go (group 7).
  final AgentPromptHandler? onPrompt;

  /// Where relayed withdrawals go (group 7).
  final AgentWithdrawHandler? onWithdraw;

  /// Where the progress line of each settled child call goes.
  final AgentProgressHandler? onProgress;

  /// Called when the job is asked to stop (cancellation or deadline), before
  /// the child is, so the relay can stop taking prompts.
  final void Function()? onStop;

  final TreeMirror _mirror = TreeMirror();
  final Set<String> _reported = {};
  final BytesBuilder _line = BytesBuilder(copy: false);
  late JobHost _host;
  bool _dead = false;
  bool _stdinClosed = false;
  bool _submitted = false;
  bool _ended = false;
  bool _interrupted = false;
  String? _session;
  String? _model;
  String? _exchangeState;
  String? _exchangeReason;
  String? _startFailure;
  String? _fatal;
  String? _refused;

  /// The child's session id, once its `hello` arrived.
  String? get session => _session;

  /// Whether the child's exchange was seen to end in the mirror.
  bool get exchangeEnded => _ended;

  @override
  void attach(JobHost host) {
    _host = host;
    // A broken pipe surfaces here too; the exit is what the job reacts to.
    host.stdin.done.then<void>((_) {}, onError: (Object _) {});
  }

  /// Sends the parent's answer to the child's prompt [key].
  void answer(String key, String text) =>
      _send({'type': 'answer', 'key': key, 'text': text});

  /// Asks the child to end its exchange.
  ///
  /// A child with an exchange under way gets `interrupt` and keeps its stdin:
  /// an engine whose input ends stops serving at once, without sending the
  /// updates that record its cancelled exchange and the text it had so far.
  /// Stdin is closed when the mirror shows the exchange ended; the supervisor
  /// ends the process if that does not happen within its soft-stop window. A
  /// child with no exchange under way has nothing to finish, so its stdin is
  /// closed at once.
  @override
  Future<void> softStop() async {
    onStop?.call();
    if (_stdinClosed) return;
    if (!_submitted || _ended) {
      _closeStdin();
      return;
    }
    if (_interrupted) return;
    _interrupted = true;
    _send(const {'type': 'interrupt'});
  }

  // -- input ------------------------------------------------------------

  @override
  Future<void> onChunk(List<int> chunk) async {
    var start = 0;
    while (start < chunk.length && !_dead) {
      final newline = chunk.indexOf(0x0a, start);
      final end = newline < 0 ? chunk.length : newline;
      if (_line.length + (end - start) > lineLimit) {
        _protocolFailure(childLineTooLong, whole: true);
        return;
      }
      _line.add(
        chunk is Uint8List
            ? Uint8List.sublistView(chunk, start, end)
            : chunk.sublist(start, end),
      );
      if (newline < 0) return;
      final bytes = _line.takeBytes();
      start = newline + 1;
      await _handleLine(bytes);
    }
  }

  Future<void> _handleLine(Uint8List bytes) async {
    final end = bytes.isNotEmpty && bytes.last == 0x0d
        ? bytes.length - 1
        : bytes.length;
    if (end == 0) return;
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(Uint8List.sublistView(bytes, 0, end)));
    } on FormatException catch (e) {
      _protocolFailure('invalid line: ${e.message}');
      return;
    }
    if (decoded is! Map<String, Object?> || decoded['type'] is! String) {
      _protocolFailure('a line must be a JSON object with a type');
      return;
    }
    try {
      await _handle(decoded['type']! as String, decoded);
    } on Object catch (e) {
      _protocolFailure('cannot apply ${decoded['type']}: $e');
    }
  }

  Future<void> _handle(String type, Map<String, Object?> event) async {
    switch (type) {
      case 'hello':
        final protocol = event['protocol'];
        if (protocol != protocolVersion) {
          _protocolFailure('unsupported protocol $protocol');
          return;
        }
        _session = event['session'] as String?;
        _model = event['model'] as String?;
        await _host.merge({'agent': _identity()});
      case 'snapshot':
        final offset = event['offset'];
        final turn = event['turn'];
        final tree = event['tree'];
        if (offset is! int || turn is! int || tree is! Map<String, Object?>) {
          _protocolFailure('malformed snapshot');
          return;
        }
        _mirror.applySnapshot(offset, turn, tree);
        _check();
        if (!_submitted && !_ended) {
          _submitted = true;
          _send({
            'type': 'submit',
            'id': agentRequestId,
            'text': prompt,
            'turn': _mirror.turn,
          });
        }
      case 'update':
        final offset = event['offset'];
        final raw = event['record'];
        if (offset is! int || raw is! Map<String, Object?>) {
          _protocolFailure('malformed update');
          return;
        }
        final op = raw['op'] is String
            ? Op.fromWire(raw['op']! as String)
            : null;
        final turn = raw['turn'];
        final path = raw['path'];
        if (op == null || turn is! int || path is! String) {
          _protocolFailure('malformed update record');
          return;
        }
        _mirror.applyUpdate(
          offset,
          JournalRecord(turn: turn, path: path, op: op, value: raw['value']),
        );
        _check();
      case 'resync':
        _mirror.invalidate();
      case 'prompt':
        if (event['item'] case final Map<String, Object?> item) {
          onPrompt?.call(item);
        }
      case 'withdraw':
        if (event['key'] case final String key) onWithdraw?.call(key);
      case 'error':
        if (event['to'] == agentRequestId && !_ended) {
          _refused = '${event['message']}';
          _closeStdin();
        }
      case 'fatal':
        final message = '${event['message']}';
        if (_submitted) {
          _fatal = message;
        } else {
          _startFailure = message;
          _host.fail('agent failed to start: $message');
        }
      default:
      // `stream` is progress (design D13), `reply` needs no action, and
      // unknown types are additive protocol fields.
    }
  }

  void _protocolFailure(String detail, {bool whole = false}) {
    if (_dead) return;
    _dead = true;
    _line.clear();
    _host.fail(whole ? detail : 'child protocol error: $detail');
  }

  Map<String, Object?> _identity() => {
    'role': role,
    'model': ?_model,
    'session': ?_session,
    'note': ?modelNote,
  };

  // -- the mirror -------------------------------------------------------

  /// Decides from the mirror whether the exchange ended; closes the child's
  /// stdin when it did, so the child exits.
  void _check() {
    if (!_mirror.isValid) return;
    _reportCalls();
    if (_ended) return;
    final exchanges = _mirror.get('body/exchanges');
    if (exchanges is! Map<String, Object?>) return;
    for (final exchange in exchanges.values) {
      if (exchange is! Map<String, Object?> ||
          exchange['request'] != agentRequestId) {
        continue;
      }
      final state = exchange['state'];
      if (state is String && state != 'running') {
        _ended = true;
        _exchangeState = state;
        _exchangeReason = exchange['reason'] as String?;
        _closeStdin();
      }
    }
  }

  /// Reports each child call that settled, once, in call order.
  void _reportCalls() {
    final report = onProgress;
    final calls = _mirror.get('body/calls');
    if (report == null || calls is! Map<String, Object?>) return;
    for (final key in calls.keys.toList()..sort()) {
      final node = calls[key];
      if (node is! Map<String, Object?> || _reported.contains(key)) continue;
      if (node['status'] case 'settled' || 'failed' || 'cancelled') {
        _reported.add(key);
        report(agentProgressLine(role, node));
      }
    }
  }

  /// The child's steps in order. The child's session holds one exchange, so
  /// every step is that exchange's.
  List<Map<String, Object?>> _steps() {
    final steps = _mirror.get('body/steps');
    if (steps is! Map<String, Object?>) return const [];
    return [
      for (final key in steps.keys.toList()..sort())
        if (steps[key] case final Map<String, Object?> step) step,
    ];
  }

  Map<String, Object?> _usage(List<Map<String, Object?>> steps) {
    final total = <String, int>{};
    for (final step in steps) {
      if (step['usage'] case final Map<String, Object?> usage) {
        for (final MapEntry(:key, :value) in usage.entries) {
          if (value is int) total[key] = (total[key] ?? 0) + value;
        }
      }
    }
    return total;
  }

  /// The text of the last step that produced any; an unfinished step's
  /// `partial` text when none did.
  String _finalText(List<Map<String, Object?>> steps) {
    for (final step in steps.reversed) {
      final output = step['output'];
      if (output is! List<Object?>) continue;
      final text = StringBuffer();
      for (final item in output) {
        if (item case {'type': 'text', 'text': final String part}) {
          text.write(part);
        }
      }
      if (text.isNotEmpty) return text.toString();
    }
    for (final step in steps.reversed) {
      if (step['partial'] case final String partial when partial.isNotEmpty) {
        return partial;
      }
    }
    return '';
  }

  // -- output -----------------------------------------------------------

  void _send(Map<String, Object?> command) {
    if (_stdinClosed) return;
    try {
      _host.stdin.add(utf8.encode('${jsonEncode(command)}\n'));
    } on Object {
      // The child is gone; its exit is what the job reacts to.
    }
  }

  void _closeStdin() {
    if (_stdinClosed) return;
    _stdinClosed = true;
    try {
      _host.stdin.close().then<void>((_) {}, onError: (Object _) {});
    } on Object {
      // Already closed.
    }
  }

  // -- the typed result -------------------------------------------------

  @override
  Future<ChannelEnd> finish(JobEnd end) async {
    final steps = _steps();
    final text = _finalText(steps);
    final cancelReason = end.cancelReason;

    String status;
    String? reasonLine;
    if (_startFailure case final message?) {
      return ChannelEnd(
        'agent failed to start: $message',
        _fields('failed', steps),
      );
    } else if (_ended) {
      final state = _exchangeState!;
      status = switch (state) {
        'done' => 'done',
        'cancelled' => cancelReason == 'deadline' ? 'timeout' : 'cancelled',
        _ => 'failed',
      };
      if (status == 'failed') {
        final reason = _exchangeReason;
        reasonLine =
            'child exchange $state${reason == null ? '' : ': $reason'}';
      }
    } else if (end.failReason case final reason?) {
      status = 'failed';
      reasonLine = reason;
    } else if (_refused case final message?) {
      status = 'failed';
      reasonLine = 'child refused the prompt: $message';
    } else if (cancelReason != null) {
      status = cancelReason == 'deadline' ? 'timeout' : 'cancelled';
    } else if (!_submitted) {
      final fatal = _fatal;
      return ChannelEnd(
        'agent failed to start: ${fatal ?? 'child exited (${end.exit ?? 'unknown'}) before its first exchange'}',
        _fields('failed', steps),
      );
    } else {
      status = 'failed';
      final fatal = _fatal;
      reasonLine =
          'child exited (${end.exit ?? 'unknown'}) before its exchange ended'
          '${fatal == null ? '' : ': $fatal'}';
    }

    final header =
        'agent $role $status (${steps.length} steps, session ${_session ?? '-'})';
    return ChannelEnd(
      [header, ?modelNote, ?reasonLine, if (text.isNotEmpty) text].join('\n'),
      _fields(status, steps),
    );
  }

  Map<String, Object?> _fields(
    String status,
    List<Map<String, Object?>> steps,
  ) => {
    ..._identity(),
    'status': status,
    'steps': steps.length,
    'usage': _usage(steps),
  };
}
