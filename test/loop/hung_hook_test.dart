import 'dart:async';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_provider.dart';
import '../support/session_support.dart';

const _deadline = Duration(seconds: 2);
const _nextStepBudget = Duration(seconds: 5);

/// A `bash` that would leave [marker] behind if it ran.
final class _Marker implements Tool {
  const _Marker(this.marker);

  final File marker;

  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    marker.writeAsStringSync('ran');
    return const ToolOutcome(summary: 'ran');
  }
}

/// Whether the process [pid] exists, asked without signalling it.
bool _alive(int pid) {
  if (Platform.isWindows) {
    final out = Process.runSync('tasklist', [
      '/FI',
      'PID eq $pid',
      '/NH',
      '/FO',
      'CSV',
    ]).stdout.toString();
    return out.contains('"$pid"');
  }
  return Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
}

/// Waits for the fixture of [pidFile], if it got far enough to write its pid,
/// to be gone.
Future<void> _expectFixtureGone(File pidFile) async {
  if (!pidFile.existsSync()) return;
  final pid = int.parse(pidFile.readAsStringSync().trim());
  final clock = Stopwatch()..start();
  while (_alive(pid)) {
    if (clock.elapsed > const Duration(seconds: 5)) {
      fail('hook process $pid is still alive');
    }
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

/// A model that calls [tool] on step one, then ends the turn; it stamps the
/// time each request arrives on [clock].
(FakeProvider, List<Duration>) _model(
  String tool,
  String arguments,
  Stopwatch clock,
) {
  final starts = <Duration>[];
  final provider = FakeProvider((request, cancel, call) {
    starts.add(clock.elapsed);
    return Stream.fromIterable(
      call == 0
          ? [
              ToolCall(callId: 'c1', name: tool, argumentsJson: arguments),
              const Completed(StopReason.toolUse),
            ]
          : [const TextDelta('Done.'), const Completed(StopReason.endTurn)],
    );
  });
  return (provider, starts);
}

/// Attaches the real runtime, with the hook from the user configuration, and
/// runs the exchange to its end.
Future<(ExchangeResult, SessionWriter)> _run(
  FakeProvider provider,
  HookConfig hook, {
  required Directory ws,
  Map<String, Tool> tools = const {},
}) async {
  final root = await tempDir();
  final (writer, _) = await createHooked(Directory(p.join(root.path, 's')));
  final runtime = await ToolRuntime.attach(
    writer,
    ResultStore(writer.sessionDir),
    workspace: ws,
    config: UserConfig(hooks: [hook]),
    tools: tools,
    kehaiHome: await tempDir(),
    gate: const AllowAllStage(),
  );
  addTearDown(runtime.close);
  final driver = ExchangeDriver(
    writer: writer,
    runtime: runtime,
    provider: provider,
    model: 'gpt-5.5',
  );
  final outcome = await driver.submit(
    id: 'r1',
    text: 'go',
    turn: writer.currentTurn,
  );
  final result = await (outcome as SubmitAdmitted).done;
  return (result, writer);
}

Map<String, Object?> _call(SessionWriter writer, String callId) =>
    writer.tree.get(SessionPath.parse('body/calls/${callKey(callId)}'))!
        as Map<String, Object?>;

/// The output the model saw for the call of the step-two request.
String _seenOutput(FakeProvider provider) =>
    provider.requests[1].items.whereType<ToolOutputItem>().single.output;

void main() {
  late Directory ws;
  late File pidFile;

  setUp(() async {
    final dir = await tempDir();
    ws = Directory(p.join(dir.path, 'ws'))..createSync();
    File(p.join(ws.path, 'a.txt')).writeAsStringSync('hello\n');
    pidFile = File(p.join(dir.path, 'hang.pid'));
  });

  HookConfig hook(String name, String tool, HookPolicy policy) => HookConfig(
    name: name,
    argv: [
      Platform.resolvedExecutable,
      p.absolute('test', 'fixtures', 'hang_forever.dart'),
      pidFile.path,
    ],
    tools: [tool],
    policy: policy,
    timeout: _deadline,
  );

  test('hung optional read hook is killed and the next step starts', () async {
    final clock = Stopwatch()..start();
    final (provider, starts) = _model('read', '{"path":"a.txt"}', clock);

    final (result, writer) = await _run(
      provider,
      hook('slow', 'read', HookPolicy.optional),
      ws: ws,
    );

    expect(result.state, 'done');
    expect(starts, hasLength(2));
    expect(starts[1], greaterThanOrEqualTo(_deadline));
    expect(starts[1], lessThan(_nextStepBudget));
    expect(_call(writer, 'c1')['status'], 'settled');
    expect(_call(writer, 'c1')['envelope'], 'ok');
    expect(
      _seenOutput(provider),
      contains('[diag hook:slow] timed out after 2000 ms; ignored'),
    );
    expect(_seenOutput(provider), contains('hello'));
    await _expectFixtureGone(pidFile);
  });

  test(
    'hung deny bash hook denies the call and the exchange continues',
    () async {
      final marker = File(p.join(ws.path, 'bash.ran'));
      final clock = Stopwatch()..start();
      final (provider, starts) = _model('bash', '{"command":"ls"}', clock);

      final (result, writer) = await _run(
        provider,
        hook('gate', 'bash', HookPolicy.deny),
        ws: ws,
        tools: {'bash': _Marker(marker)},
      );

      expect(result.state, 'done');
      expect(starts, hasLength(2));
      expect(starts[1], greaterThanOrEqualTo(_deadline));
      expect(starts[1], lessThan(_nextStepBudget));
      expect(_call(writer, 'c1')['envelope'], 'denied');
      expect(marker.existsSync(), isFalse, reason: 'bash never ran');
      expect(
        _seenOutput(provider),
        contains('hook gate timed out after 2000 ms'),
      );
      await _expectFixtureGone(pidFile);
    },
  );
}
