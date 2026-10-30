import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/loop_support.dart';
import '../support/session_support.dart';

RequestBuilder _builder(SessionWriter writer, {int? window}) => RequestBuilder(
  sessionDir: writer.sessionDir,
  model: 'gpt-5.5',
  workspaceName: 'proj',
  tools: const [],
  estimateRequest: (_) => 0,
  window: window,
  clock: () => DateTime(2026, 10, 30, 9, 5),
);

/// One short line per item, leaving out the final sensorium block.
List<String> _describe(ModelRequest request) => [
  for (final item in request.items.take(request.items.length - 1))
    switch (item) {
      UserMessage(:final text) => 'user:$text',
      AssistantMessage(:final text) => 'assistant:$text',
      ToolCallItem(:final callId, :final name) => 'call:$callId:$name',
      ToolOutputItem(:final callId, :final output) => 'output:$callId:$output',
      OpaqueReasoningItem(:final json) => 'reasoning:${json['id']}',
    },
];

Future<(SessionWriter, ResultStore)> _session() async {
  final writer = await createWriter(await tempDir());
  return (writer, ResultStore(writer.sessionDir));
}

void main() {
  test(
    'rewind to an exchange\'s first turn drops later steps from the request',
    () async {
      final (writer, store) = await _session();
      await seedExchange(writer, 1, 'go', state: 'running');
      await seedStep(
        writer,
        1,
        exchange: 1,
        output: [textEntry('First'), callEntry('c1', 'ls')],
      );
      await seedCall(writer, store, callId: 'c1', modelText: 'out-1');
      await seedStep(
        writer,
        2,
        exchange: 1,
        output: [textEntry('Second'), callEntry('c2', 'ls')],
      );
      await seedCall(writer, store, callId: 'c2', modelText: 'out-2');
      await seedStep(writer, 3, exchange: 1, output: [textEntry('Third')]);

      final before = await _builder(writer).build(writer.tree, turn: 4);
      expect(_describe(before.request), contains('assistant:Third'));

      await writer.rewind(1);
      final built = await _builder(writer).build(writer.tree, turn: 2);

      expect(_describe(built.request), [
        'user:go',
        'assistant:First',
        'call:c1:ls',
        'output:c1:out-1',
      ]);
    },
  );

  test('tool output is the stored model text byte for byte', () async {
    final (writer, store) = await _session();
    const modelText =
        '[bash ok] 50000 lines\r\nline 1\n✓ café\n'
        '[truncated: lines 2-49999 omitted; r/aaaaaaaaaaaa next 50000]\n';
    await seedExchange(writer, 1, 'run it', state: 'running');
    await seedStep(
      writer,
      1,
      exchange: 1,
      output: [callEntry('c1', 'bash', '{"command":"seq 50000"}')],
    );
    await seedCall(
      writer,
      store,
      callId: 'c1',
      modelText: modelText,
      resultText: 'different stored result bytes\n',
    );

    final built = await _builder(writer).build(writer.tree, turn: 2);

    final output = built.request.items.whereType<ToolOutputItem>().single;
    expect(output.callId, 'c1');
    expect(output.output, modelText);
    final call = built.request.items.whereType<ToolCallItem>().single;
    expect(call.argumentsJson, '{"command":"seq 50000"}');
  });

  test('resumed session request holds earlier items and cancelled calls\''
      ' outputs', () async {
    final (writer, store) = await _session();
    await seedExchange(writer, 1, 'first prompt', state: 'cancelled');
    await seedStep(
      writer,
      1,
      exchange: 1,
      output: [
        textEntry('Working'),
        callEntry('c1', 'bash'),
        callEntry('c2', 'bash'),
      ],
    );
    await seedCall(writer, store, callId: 'c1', modelText: 'ok-1');
    await seedCall(
      writer,
      store,
      callId: 'c2',
      status: 'cancelled',
      envelope: 'error',
      modelText: '[bash error] cancelled: interrupted\n',
    );
    // The interrupted step produced text that is display-only.
    await seedStep(
      writer,
      2,
      exchange: 1,
      state: 'cancelled',
      output: const [],
      partial: 'half a thought',
    );
    await seedExchange(writer, 3, 'second prompt', state: 'running');
    await seedStep(writer, 3, exchange: 3, state: 'running', output: const []);

    final built = await _builder(writer).build(writer.tree, turn: 3);

    expect(_describe(built.request), [
      'user:first prompt',
      'assistant:Working',
      'call:c1:bash',
      'output:c1:ok-1',
      'call:c2:bash',
      'output:c2:[bash error] cancelled: interrupted\n',
      'user:second prompt',
    ]);
  });

  test('a call without a terminal node is left out with its output', () async {
    final (writer, store) = await _session();
    await seedExchange(writer, 1, 'go', state: 'running');
    await seedStep(
      writer,
      1,
      exchange: 1,
      output: [
        callEntry('missing', 'ls'),
        callEntry('pending', 'ls'),
        callEntry('done', 'ls'),
      ],
    );
    await seedCall(writer, store, callId: 'pending', status: 'pending');
    await seedCall(writer, store, callId: 'done', modelText: 'listing');

    final built = await _builder(writer).build(writer.tree, turn: 2);

    expect(_describe(built.request), [
      'user:go',
      'call:done:ls',
      'output:done:listing',
    ]);
  });

  test('items follow the step output order with reasoning unchanged', () async {
    final (writer, store) = await _session();
    await seedExchange(writer, 1, 'go', state: 'running');
    await seedStep(
      writer,
      1,
      exchange: 1,
      output: [
        {
          'type': 'reasoning',
          'item': {'id': 'rs_1', 'type': 'reasoning', 'x': 1},
        },
        callEntry('c1', 'ls'),
        textEntry('after'),
      ],
    );
    await seedCall(writer, store, callId: 'c1', modelText: 'o');

    final built = await _builder(writer).build(writer.tree, turn: 2);

    expect(_describe(built.request), [
      'user:go',
      'reasoning:rs_1',
      'call:c1:ls',
      'output:c1:o',
      'assistant:after',
    ]);
    final reasoning = built.request.items.whereType<OpaqueReasoningItem>();
    expect(reasoning.single.json, {'id': 'rs_1', 'type': 'reasoning', 'x': 1});
    expect(built.request.instructions, builtInInstructions);
  });

  group('fallbacks without a stored model text', () {
    test('a node with a result is recomposed with its diag lines', () async {
      final (writer, store) = await _session();
      await seedExchange(writer, 1, 'go', state: 'running');
      await seedStep(writer, 1, exchange: 1, output: [callEntry('c1', 'bash')]);
      await seedCall(
        writer,
        store,
        callId: 'c1',
        resultText: 'hello\n',
        summary: 'ran',
        extra: {
          'diag': [
            {'source': 'hooks', 'text': 'heads up'},
          ],
        },
      );

      final built = await _builder(writer).build(writer.tree, turn: 2);

      final output = built.request.items.whereType<ToolOutputItem>().single;
      expect(output.output, startsWith('[bash ok] ran'));
      expect(output.output, contains('hello'));
      expect(output.output, endsWith('\n[diag hooks] heads up'));
    });

    test('a storage failure is rebuilt from reason and accepted', () async {
      final (writer, store) = await _session();
      await seedExchange(writer, 1, 'go', state: 'running');
      await seedStep(writer, 1, exchange: 1, output: [callEntry('c1', 'bash')]);
      await seedCall(
        writer,
        store,
        callId: 'c1',
        status: 'failed',
        envelope: 'error',
        extra: {'reason': 'storage: disk full', 'accepted': 12},
      );

      final built = await _builder(writer).build(writer.tree, turn: 2);

      final output = built.request.items.whereType<ToolOutputItem>().single;
      expect(output.output, composeStorageFailure('bash', 'disk full', 12));
    });
  });
}
