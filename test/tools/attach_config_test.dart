import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/session_support.dart';

/// A tool that counts its runs.
final class _Counting implements Tool {
  int runs = 0;

  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    runs++;
    return const ToolOutcome(summary: 'done');
  }
}

void main() {
  late Directory root;
  late Directory home;
  late SessionWriter writer;
  setUp(() async {
    root = await tempDir();
    home = await tempDir();
    writer = await createWriter(await tempDir());
  });

  String configPath() => p.join(home.path, configFileName);

  Future<ToolRuntime> attach(_Counting tool, {UserConfig? config}) async {
    final runtime = await ToolRuntime.attach(
      writer,
      ResultStore(writer.sessionDir),
      workspace: root,
      kehaiHome: home,
      config: config,
      yolo: true,
      tools: {'read': tool},
    );
    addTearDown(runtime.close);
    return runtime;
  }

  const call = ToolCall(
    callId: 'r1',
    name: 'read',
    argumentsJson: '{"path":"x"}',
  );

  test(
    'attach loads config.json from the home: its deny hook denies',
    () async {
      File(configPath()).writeAsStringSync(
        jsonEncode({
          'hooks': [
            {
              'name': 'guard',
              'argv': [
                Platform.resolvedExecutable,
                p.absolute('test', 'fixtures', 'crash_hook.dart'),
                '2',
                'no reads',
              ],
              'tools': ['read'],
              'policy': 'deny',
            },
          ],
        }),
      );
      final tool = _Counting();

      final runtime = await attach(tool);
      final item = await runtime.run(call);

      expect(runtime.config.hooks.map((h) => h.name), ['guard']);
      expect(tool.runs, 0);
      expect(item.output, contains('hook guard: no reads'));
    },
  );

  test('an explicit config wins over the file', () async {
    File(configPath()).writeAsStringSync('{ not json');
    final tool = _Counting();

    final runtime = await attach(tool, config: const UserConfig());

    expect(runtime.config.hooks, isEmpty);
    expect((await runtime.run(call)).output, isNot(contains('denied')));
    expect(tool.runs, 1);
  });

  test('an invalid file stops attach, naming it, and starts nothing', () async {
    File(configPath()).writeAsStringSync('{"hooks": [], "bogus": 1}');
    final tool = _Counting();

    await expectLater(
      attach(tool),
      throwsA(
        isA<ConfigError>()
            .having((e) => e.path, 'path', configPath())
            .having((e) => e.problem, 'problem', 'unknown key bogus'),
      ),
    );

    expect(tool.runs, 0);
    expect(writer.tree.get(SessionPath.parse('jobs')), isNull);
    expect(writer.tree.get(SessionPath.parse('body/calls')), isNull);
  });

  test('a missing file gives the defaults', () async {
    final tool = _Counting();

    final runtime = await attach(tool);

    expect(runtime.config.hooks, isEmpty);
    expect(runtime.config.allow, isEmpty);
    expect(tool.runs, 0);
    await runtime.run(call);
    expect(tool.runs, 1);
  });
}
