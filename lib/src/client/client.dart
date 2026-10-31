/// The line client (design D1, D14).
///
/// It reads prompts in cooked line mode, sends them to the engine, and prints
/// what the engine reports. It holds no state the protocol does not carry:
/// the tree mirror is rebuilt from every `snapshot`.
library;

import 'dart:async';
import 'dart:io';

import '../session/record.dart';
import 'engine_process.dart';
import 'mirror.dart';
import 'prompt_state.dart';
import 'render.dart';

/// The note printed for input typed while an exchange runs.
const String busyNote = 'busy: wait for the reply or press Ctrl-C';

const Set<String> _allowWords = {'1', 'y', 'yes', 'allow'};
const Set<String> _denyWords = {'2', 'n', 'no', 'deny'};

/// Reads prompts line by line and renders what the engine sends.
final class LineClient {
  /// Creates a client over [engine].
  ///
  /// With [interactive] false (input is a pipe) the next line is read only
  /// when no exchange is running, so each prompt gets its own reply.
  LineClient({
    required this.engine,
    required this.input,
    required this.out,
    required this.err,
    this.interactive = true,
    this.interrupts,
    this.exitGrace = const Duration(seconds: 5),
  });

  /// The engine.
  final EngineLink engine;

  /// The user's input lines.
  final Stream<String> input;

  /// Where the conversation is printed.
  final StringSink out;

  /// Where failures and notices are printed.
  final StringSink err;

  /// Whether input comes from a terminal.
  final bool interactive;

  /// Ctrl-C events.
  final Stream<Object?>? interrupts;

  /// How long the engine gets to exit after its input closed.
  final Duration exitGrace;

  final TreeMirror _mirror = TreeMirror();
  final PromptState _prompts = PromptState();
  final Completer<int> _result = Completer<int>();
  final Map<int, String> _shown = {};
  final Set<String> _finishedSteps = {};
  final Set<String> _printedCalls = {};
  final List<String> _continued = [];
  final String _idBase = DateTime.now().microsecondsSinceEpoch.toRadixString(
    36,
  );

  StreamSubscription<Map<String, Object?>>? _events;
  StreamSubscription<String>? _lines;
  StreamSubscription<Object?>? _interruptEvents;
  Timer? _killTimer;
  bool _paused = false;
  bool _ready = false;
  bool _midLine = false;
  bool _inputEnded = false;
  bool _exiting = false;
  bool _fatalSeen = false;
  bool _interruptSent = false;
  String? _requestId;
  int _requests = 0;

  /// Runs until the user exits or the engine ends; returns the exit code.
  Future<int> run() {
    _events = engine.events.listen(_onEvent, onDone: _onEngineDone);
    _lines = input.listen(_onLine, onDone: _onInputDone);
    _lines!.pause();
    _paused = true;
    _interruptEvents = interrupts?.listen((_) => _onInterrupt());
    return _result.future;
  }

  bool get _running => _requestId != null;

  // Output.

  void _write(String text) {
    if (text.isEmpty) return;
    out.write(text);
    _midLine = !text.endsWith('\n');
  }

  void _line(String text) {
    if (_midLine) out.write('\n');
    out.writeln(text);
    _midLine = false;
  }

  void _showPrompt() {
    if (!_ready || _running || _prompts.active != null || _exiting) return;
    if (_midLine) out.write('\n');
    out.write('> ');
    _midLine = false;
  }

  // Input.

  void _gate() {
    final shouldPause =
        !_ready || (!interactive && _running && _prompts.active == null);
    final lines = _lines;
    if (lines == null || shouldPause == _paused) return;
    _paused = shouldPause;
    shouldPause ? lines.pause() : lines.resume();
  }

  void _onLine(String line) {
    if (_exiting) return;
    if (_prompts.active != null) {
      _answer(line);
    } else if (_running) {
      _line(busyNote);
    } else {
      _idleLine(line);
    }
    _gate();
  }

  void _idleLine(String line) {
    if (_continued.isEmpty && line.trim() == '/exit') {
      _shutdown();
      return;
    }
    if (line.endsWith(r'\')) {
      _continued.add(line.substring(0, line.length - 1));
      _showPrompt();
      return;
    }
    final text = [..._continued, line].join('\n');
    _continued.clear();
    if (text.trim().isEmpty) {
      _showPrompt();
      return;
    }
    _submit(text);
  }

  void _submit(String text) {
    // A terminal echoed the line and its newline; a pipe did not.
    if (!interactive) _write('\n');
    final id = 'r${_idBase}_${++_requests}';
    _requestId = id;
    engine.send({
      'type': 'submit',
      'id': id,
      'text': text,
      'turn': _mirror.turn,
    });
  }

  void _answer(String line) {
    final prompt = _prompts.active!;
    if (_prompts.inFlight != null) {
      _line('waiting for the previous answer');
      return;
    }
    final String? text;
    if (prompt.kind == 'permission') {
      final word = line.trim().toLowerCase();
      text = _allowWords.contains(word)
          ? 'allow'
          : _denyWords.contains(word)
          ? 'deny'
          : null;
      if (text == null) {
        _line('answer 1 (allow) or 2 (deny)');
        _write('answer> ');
        return;
      }
    } else {
      text = _questionAnswer(prompt, line);
      if (text == null) {
        _line('answer must be one of: ${_choicesOf(prompt).join(', ')}');
        _write('answer> ');
        return;
      }
    }
    _prompts.markSent();
    engine.send({'type': 'answer', 'key': prompt.key, 'text': text});
  }

  /// The text to send for [line] at the question [prompt], or null when the
  /// question offers only its choices and [line] is none of them.
  ///
  /// A number picks the choice with that number, a choice is sent as itself,
  /// and anything else is free text when the question allows it.
  String? _questionAnswer(OpenPrompt prompt, String line) {
    final choices = _choicesOf(prompt);
    final number = int.tryParse(line.trim());
    if (number != null && number >= 1 && number <= choices.length) {
      return choices[number - 1];
    }
    if (choices.contains(line)) return line;
    final allowText = prompt.input['allow_text'];
    return (allowText is bool ? allowText : choices.isEmpty) ? line : null;
  }

  void _onInputDone() {
    _inputEnded = true;
    _maybeFinishInput();
  }

  /// Exits at end of input once nothing is left that input could still serve.
  void _maybeFinishInput() {
    if (!_inputEnded || _exiting) return;
    if (!_running) {
      _shutdown();
    } else if (_prompts.active != null && _prompts.inFlight == null) {
      // A prompt is open and no input is left to answer it.
      _shutdown();
    }
  }

  // Engine events.

  void _onEvent(Map<String, Object?> event) {
    switch (event['type']) {
      case 'hello':
        _line('session ${event['session']}  model ${event['model']}');
      case 'snapshot':
        _onSnapshot(event);
      case 'resync':
        _mirror.invalidate();
        err.writeln('resynced');
      case 'update':
        _onUpdate(event);
      case 'stream':
        _onStream(event);
      case 'prompt':
        final prompt = OpenPrompt.fromJson(event['item']);
        if (prompt != null) {
          final known = _prompts.contains(prompt.key);
          if (_prompts.offer(prompt)) {
            _showActive();
          } else if (!known) {
            _line(cutTo('queued: ${_describe(prompt)}', maxLineLength));
          }
        }
        _gate();
      case 'withdraw':
        final key = event['key'];
        if (key is String && _prompts.remove(key)) _afterActiveChange();
        _gate();
      case 'reply':
        _onReply(event);
      case 'error':
        _onError(event);
      case 'fatal':
        _fatalSeen = true;
        if (_midLine) out.write('\n');
        _midLine = false;
        err.writeln('${event['message']}');
    }
  }

  void _onSnapshot(Map<String, Object?> event) {
    final offset = event['offset'];
    final turn = event['turn'];
    final tree = event['tree'];
    if (offset is! int || turn is! int || tree is! Map<String, Object?>) return;
    _mirror.applySnapshot(offset, turn, tree);
    _reconcile(first: !_ready);
    if (!_ready) {
      _ready = true;
      _showPrompt();
    }
    _gate();
  }

  void _onUpdate(Map<String, Object?> event) {
    final offset = event['offset'];
    final raw = event['record'];
    if (offset is! int || raw is! Map<String, Object?>) return;
    final turn = raw['turn'];
    final path = raw['path'];
    final op = raw['op'];
    if (turn is! int || path is! String || op is! String) return;
    final wire = Op.fromWire(op);
    if (wire == null) return;
    try {
      final record = JournalRecord(
        turn: turn,
        path: path,
        op: wire,
        value: raw['value'],
      );
      if (!_mirror.applyUpdate(offset, record)) return;
    } on Object catch (e) {
      err.writeln('warning: cannot apply an update to $path: $e');
      return;
    }
    _afterUpdate(path);
  }

  void _afterUpdate(String path) {
    final segments = path.split('/');
    if (segments.length != 3) return;
    switch ((segments[0], segments[1])) {
      case ('body', 'steps'):
        _commitStep(segments[2]);
      case ('body', 'calls'):
        _printCall(segments[2]);
      case ('body', 'exchanges'):
        _noteExchange(segments[2]);
      case ('meta', 'requests') when segments[2] == _requestId:
        final node = _mirror.get(path);
        if (node is Map<String, Object?> && node['state'] != 'admitted') {
          _endExchange();
        }
    }
  }

  void _onStream(Map<String, Object?> event) {
    if (event['kind'] != 'text') return;
    final turn = event['turn'];
    final delta = event['delta'];
    if (turn is! int || delta is! String) return;
    if (_finishedSteps.contains(_stepKey(turn))) return;
    _shown[turn] = '${_shown[turn] ?? ''}$delta';
    _write(delta);
  }

  void _onReply(Map<String, Object?> event) {
    final to = event['to'];
    if (to == 'answer') {
      final key = event['key'];
      if (key is String && _prompts.remove(key)) _afterActiveChange();
      _gate();
    } else if (to is String && to == _requestId) {
      final state = event['state'];
      if (state == 'completed' || state == 'failed' || state == 'interrupted') {
        _endExchange();
      }
    }
  }

  void _onError(Map<String, Object?> event) {
    final to = event['to'];
    final message = '${event['message']}';
    if (to == 'answer') {
      _prompts.refused();
      _line(message);
      _write('answer> ');
      _maybeFinishInput();
    } else if (to is String && to == _requestId) {
      _line('error: $message');
      _endExchange();
    } else {
      _line('error: $message');
    }
  }

  // Rendering of the tree.

  void _reconcile({required bool first}) {
    final steps = _mirror.get('body/steps');
    if (steps is Map<String, Object?>) {
      for (final key in steps.keys.toList()..sort()) {
        if (first) {
          _finishedSteps.add(key);
        } else {
          _commitStep(key);
        }
      }
    }
    final calls = _mirror.get('body/calls');
    if (calls is Map<String, Object?>) {
      for (final key in calls.keys.toList()..sort()) {
        if (first) {
          _printedCalls.add(key);
        } else {
          _printCall(key);
        }
      }
    }
    // The update that ended the running request may have been dropped with
    // the overflow; the snapshot still holds its state.
    final id = _requestId;
    if (id != null) {
      final request = _mirror.get('meta/requests/$id');
      if (request is Map<String, Object?> && request['state'] != 'admitted') {
        _endExchange();
      }
    }
  }

  /// Prints the part of a completed step's text that was not shown live.
  void _commitStep(String key) {
    if (_finishedSteps.contains(key)) return;
    final node = _mirror.get('body/steps/$key');
    if (node is! Map<String, Object?> || node['state'] != 'completed') return;
    _finishedSteps.add(key);
    final turn = int.tryParse(key.startsWith('s-') ? key.substring(2) : '');
    final shown = (turn == null ? null : _shown.remove(turn)) ?? '';
    final output = node['output'];
    final committed = output is List<Object?>
        ? output
              .whereType<Map<String, Object?>>()
              .where((entry) => entry['type'] == 'text')
              .map((entry) => '${entry['text']}')
              .join()
        : '';
    if (committed.startsWith(shown)) {
      _write(committed.substring(shown.length));
    } else {
      // The live text does not match the commit: show the commit whole.
      if (_midLine) _write('\n');
      _write(committed);
    }
    if (_midLine) _write('\n');
  }

  void _printCall(String key) {
    if (_printedCalls.contains(key)) return;
    final node = _mirror.get('body/calls/$key');
    if (node is! Map<String, Object?>) return;
    final status = node['status'];
    if (status != 'settled' && status != 'failed' && status != 'cancelled') {
      return;
    }
    _printedCalls.add(key);
    final envelope = node['envelope'];
    final summary = node['summary'];
    _line(
      callLine(
        tool: '${node['tool']}',
        label: envelope is String ? envelope : '$status',
        summary: summary is String ? summary : null,
        input: node['input'],
      ),
    );
  }

  void _noteExchange(String key) {
    final node = _mirror.get('body/exchanges/$key');
    if (node is! Map<String, Object?>) return;
    final state = node['state'];
    if (state == 'failed' || state == 'stopped') {
      final reason = node['reason'];
      _line(
        '[exchange $state]${reason is String ? ' ${oneLine(reason)}' : ''}',
      );
    }
  }

  // Prompts.

  /// What [prompt] asks, on one line: the tool and its argument, or the
  /// question.
  String _describe(OpenPrompt prompt) {
    if (prompt.kind == 'permission') {
      final argument = argumentSummary(prompt.input);
      return '${oneLine(prompt.tool)}${argument.isEmpty ? '' : ' $argument'}';
    }
    final question = prompt.input['question'];
    return question is String ? oneLine(question) : oneLine(prompt.tool);
  }

  void _showActive() {
    final prompt = _prompts.active;
    if (prompt == null) return;
    if (prompt.kind == 'permission') {
      _line(cutTo('permission: ${_describe(prompt)}', maxLineLength));
      _line('1) allow  2) deny');
    } else {
      _line('question: ${_describe(prompt)}');
      final choices = _choicesOf(prompt);
      for (var i = 0; i < choices.length; i++) {
        _line('${i + 1}) ${oneLine(choices[i])}');
      }
    }
    _write('answer> ');
  }

  void _afterActiveChange() {
    if (_prompts.active != null) {
      _showActive();
    } else {
      _showPrompt();
    }
    _maybeFinishInput();
  }

  // Exchange and process lifecycle.

  /// Ctrl-C: interrupts a running exchange or an open prompt once, and exits
  /// at an idle prompt.
  void _onInterrupt() {
    if (_exiting) return;
    if (_running || _prompts.active != null) {
      if (_interruptSent) return;
      _interruptSent = true;
      engine.send({'type': 'interrupt'});
      _line('interrupting…');
    } else {
      _shutdown();
    }
  }

  void _endExchange() {
    if (!_running) return;
    _requestId = null;
    _interruptSent = false;
    if (_midLine) _write('\n');
    _showPrompt();
    _gate();
    _maybeFinishInput();
  }

  void _shutdown() {
    if (_exiting) return;
    _exiting = true;
    unawaited(_lines?.cancel());
    unawaited(engine.closeInput());
    _killTimer = Timer(exitGrace, engine.kill);
  }

  Future<void> _onEngineDone() async {
    final code = await engine.exitCode;
    if (!_exiting && !_fatalSeen) {
      err.writeln('engine exited ($code)');
    }
    _killTimer?.cancel();
    unawaited(_lines?.cancel());
    unawaited(_events?.cancel());
    unawaited(_interruptEvents?.cancel());
    if (!_result.isCompleted) _result.complete(_exiting ? 0 : 1);
  }
}

/// The choices a question offers, as text.
List<String> _choicesOf(OpenPrompt prompt) {
  final choices = prompt.input['choices'];
  return choices is List<Object?> ? [for (final c in choices) '$c'] : const [];
}

String _stepKey(int turn) => 's-${turn.toString().padLeft(8, '0')}';

/// Starts the engine with [engineArgs] and runs a [LineClient] over it.
Future<int> runLineClient({
  required List<String> engineArgs,
  required Stream<String> input,
  required StringSink out,
  required StringSink err,
  required bool interactive,
  EngineStarter starter = startEngineProcess,
  Stream<Object?>? interrupts,
}) async {
  final EngineLink engine;
  try {
    engine = await starter(engineArgs);
  } on ProcessException catch (e) {
    err.writeln('cannot start the engine: ${e.message}');
    return 1;
  }
  return LineClient(
    engine: engine,
    input: input,
    out: out,
    err: err,
    interactive: interactive,
    interrupts: interrupts,
  ).run();
}
