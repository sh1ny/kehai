import 'dart:convert';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/loop_support.dart';
import '../support/session_support.dart';

/// Sizes items by characters; a sensorium block is always 40 tokens and
/// calls and reasoning items 5,000, so counting one by mistake shows.
int _estimate(ConversationItem item) => switch (item) {
  UserMessage(:final text) when text.startsWith('<sensorium>') => 40,
  UserMessage(:final text) || AssistantMessage(:final text) => text.length,
  ToolOutputItem(:final output) => output.length,
  ToolCallItem() || OpaqueReasoningItem() => 5000,
};

RequestBuilder _builder(
  SessionWriter writer, {
  int? window = 200000,
  int Function(ModelRequest)? estimateRequest,
}) => RequestBuilder(
  sessionDir: writer.sessionDir,
  model: 'gpt-5.5',
  workspaceName: 'proj',
  tools: const [],
  estimateRequest: estimateRequest ?? (_) => 0,
  estimate: _estimate,
  window: window,
  clock: () => DateTime(2026, 10, 30, 9, 5),
);

Future<(SessionWriter, ResultStore)> _session() async {
  final writer = await createWriter(await tempDir());
  return (writer, ResultStore(writer.sessionDir));
}

Map<String, Object?> _usage(int input, int output) => {
  'input': input,
  'output': output,
};

Map<String, Object?> _context(int block) => {
  'used': 0,
  'block': block,
  'estimated': true,
};

String _budgetLine(BuiltRequest built) =>
    built.blockText.split('\n').singleWhere((l) => l.startsWith('budget:'));

void main() {
  group('One request-only sensorium block', () {
    test('only the last request item is a sensorium block and instructions '
        'are stable', () async {
      final (writer, _) = await _session();
      await seedExchange(writer, 1, 'hello', state: 'running');
      final first = await _builder(writer).build(writer.tree, turn: 1);

      await seedStep(
        writer,
        1,
        exchange: 1,
        output: [textEntry('hi')],
        usage: _usage(10, 2),
        context: _context(40),
      );
      await seedExchange(writer, 2, 'again', state: 'running');
      final second = await _builder(writer).build(writer.tree, turn: 2);

      final items = second.request.items;
      expect(items.last, isA<UserMessage>());
      expect((items.last as UserMessage).text, second.blockText);
      expect(second.blockText, startsWith('<sensorium>'));
      expect(
        items.whereType<UserMessage>().where(
          (m) => m.text.contains('<sensorium>'),
        ),
        hasLength(1),
      );
      expect(second.blockText, contains('turn: 2 ·'));
      expect(
        items.map((i) => i is UserMessage ? i.text : ''),
        isNot(contains(first.blockText)),
      );
      expect(second.request.instructions, first.request.instructions);
    });

    test('no tree item contains a sensorium block after a step', () async {
      final (writer, _) = await _session();
      await seedExchange(writer, 1, 'hello', state: 'running');
      final built = await _builder(writer).build(writer.tree, turn: 1);
      await seedStep(
        writer,
        1,
        exchange: 1,
        output: [textEntry('hi')],
        usage: _usage(10, 2),
        context: _context(built.block),
      );

      expect(built.blockText, startsWith('<sensorium>'));
      expect(jsonEncode(writer.tree.toJson()), isNot(contains('<sensorium>')));
    });
  });

  group('Turn and budget sections', () {
    test(
      'budget line with a known window shows used, window and percent',
      () async {
        final (writer, _) = await _session();
        await seedExchange(writer, 1, 'hello', state: 'running');
        await seedStep(
          writer,
          1,
          exchange: 1,
          output: [textEntry('hi')],
          usage: _usage(40000, 1200),
          context: _context(40),
        );

        final built = await _builder(writer).build(writer.tree, turn: 14);

        expect(built.used, 41200);
        expect(
          _budgetLine(built),
          'budget: 41k/200k ctx (21%) · model gpt-5.5',
        );
        expect(
          built.blockText,
          '<sensorium>\n'
          'turn: 14 · full · 09:05 · cwd proj\n'
          'budget: 41k/200k ctx (21%) · model gpt-5.5\n'
          '</sensorium>',
        );
      },
    );

    test('budget line with an unknown window shows ? and no percent', () async {
      final (writer, _) = await _session();
      await seedExchange(writer, 1, 'hello', state: 'running');
      await seedStep(
        writer,
        1,
        exchange: 1,
        output: [textEntry('hi')],
        usage: _usage(40000, 1200),
        context: _context(40),
      );

      final built = await _builder(
        writer,
        window: null,
      ).build(writer.tree, turn: 14);

      expect(_budgetLine(built), 'budget: 41k/? ctx · model gpt-5.5');
      expect(built.overflow, isFalse);
    });

    test('token counts render as k below a million and M above', () {
      expect(formatTokens(0), '0k');
      expect(formatTokens(41200), '41k');
      expect(formatTokens(200000), '200k');
      expect(formatTokens(1200000), '1.2M');
    });
  });

  group('Context in use', () {
    test('interleaved outputs of the baseline step are counted once by '
        'provenance', () async {
      final (writer, store) = await _session();
      await seedExchange(writer, 1, 'go', state: 'running');
      await seedStep(
        writer,
        1,
        exchange: 1,
        output: [
          textEntry('t' * 9000),
          callEntry('A', 'read'),
          callEntry('B', 'read'),
        ],
        usage: _usage(30000, 1000),
        context: _context(40),
      );
      await seedCall(writer, store, callId: 'A', modelText: 'a' * 6000);
      await seedCall(writer, store, callId: 'B', modelText: 'b' * 4000);

      final built = await _builder(writer).build(writer.tree, turn: 2);

      expect(
        built.request.items.map((i) => i.runtimeType.toString()),
        containsAllInOrder([
          'ToolCallItem',
          'ToolOutputItem',
          'ToolCallItem',
          'ToolOutputItem',
        ]),
      );
      // 30,000 + 1,000 - 40 + 6,000 + 4,000, plus the new block (40).
      expect(built.used, 41000);
    });

    test(
      'cancelled step without usage falls back to the last completed step',
      () async {
        final (writer, _) = await _session();
        await seedExchange(writer, 1, 'go', state: 'cancelled');
        await seedStep(
          writer,
          1,
          exchange: 1,
          output: [textEntry('ok')],
          usage: _usage(20000, 1000),
          context: _context(40),
        );
        await seedStep(
          writer,
          2,
          exchange: 1,
          state: 'cancelled',
          partial: 'p' * 500,
        );
        await seedExchange(writer, 3, 'n' * 300, state: 'running');

        final built = await _builder(writer).build(writer.tree, turn: 3);

        // 21,000 - 40 + the 300-character prompt + the block (40).
        expect(built.used, 21300);
      },
    );

    test('with no completed step that reported usage the whole request is '
        'estimated', () async {
      final (writer, _) = await _session();
      await seedExchange(writer, 1, 'go', state: 'running');
      await seedStep(
        writer,
        1,
        exchange: 1,
        state: 'cancelled',
        usage: _usage(90000, 9000),
      );
      ModelRequest? sized;

      final built = await _builder(
        writer,
        estimateRequest: (request) {
          sized = request;
          return 5000;
        },
      ).build(writer.tree, turn: 2);

      expect(built.used, 5000);
      expect(sized!.items.last, isA<UserMessage>());
    });

    test('incomplete step\'s usage is not the baseline and the request is '
        'sent', () async {
      final (writer, _) = await _session();
      await seedExchange(writer, 1, 'go', state: 'failed');
      await seedStep(
        writer,
        1,
        exchange: 1,
        output: [textEntry('ok')],
        usage: _usage(120000, 2000),
        context: _context(40),
      );
      await seedStep(
        writer,
        2,
        exchange: 1,
        state: 'failed',
        usage: _usage(180000, 50000),
        context: _context(40),
      );
      await seedExchange(writer, 3, 'n' * 200, state: 'running');

      final built = await _builder(writer).build(writer.tree, turn: 3);

      // 122,000 - 40 + the 200-character prompt + the block (40).
      expect(built.used, 122200);
      expect(built.overflow, isFalse);
    });
  });
}
