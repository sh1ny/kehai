import 'dart:async';

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
      OpaqueCompactionItem(:final json) => 'compaction:${json['id']}',
    },
];

Future<(SessionWriter, ResultStore)> _session() async {
  final writer = await createWriter(await tempDir());
  return (writer, ResultStore(writer.sessionDir));
}

String _processSection(String block) {
  final start = block.indexOf('processes:');
  expect(start, greaterThanOrEqualTo(0), reason: 'missing processes section');
  final end = block.indexOf('\nplan:', start);
  expect(end, greaterThan(start), reason: 'missing following plan section');
  return block.substring(start, end);
}

void main() {
  test('capture freezes acknowledged jobs caller tree and clock before async projection', () async {
    final (writer, _) = await _session();
    await seedExchange(writer, 1, 'hello', state: 'running');
    await writer.apply(
      rec(1, 'jobs/j-capture', Op.set, {
        'kind': 'shell',
        'cmd': 'compile-alpha',
        'state': 'running',
        'started': '2026-10-30T09:03:00Z',
        'launch': 'launch-capture',
      }),
    );
    final source = writer.tree;
    final offset = writer.committedLength;
    final initialClock = DateTime.utc(2026, 10, 30, 9, 5);
    var now = initialClock;
    var clockReads = 0;
    var captures = 0;
    final captured = Completer<void>();
    final release = Completer<void>();
    final builder = RequestBuilder(
      sessionDir: writer.sessionDir,
      model: 'gpt-5.5',
      workspaceName: 'proj',
      tools: const [],
      estimateRequest: (_) => 0,
      clock: () {
        clockReads++;
        return now;
      },
      onCaptured: () async {
        captures++;
        if (captures == 1) {
          captured.complete();
          await release.future;
        }
      },
    );
    final pending = builder.build(source, turn: 14, sourceOffset: offset);
    late BuiltRequest first;
    try {
      // The scaffold deliberately ignores onCaptured. Race completion against
      // the barrier so missing capture fails explicitly instead of hanging.
      final reachedCapture = await Future.any([
        captured.future.then((_) => true),
        pending.then((_) => false),
      ]);
      expect(
        reachedCapture,
        isTrue,
        reason:
            'production must freeze source and clock, then await onCaptured',
      );
      expect(clockReads, 1, reason: 'clock is captured before the first await');
      final update = rec(1, 'jobs/j-capture', Op.merge, {
        'cmd': 'compile-beta',
        'state': 'pending',
        'started': '2026-10-30T09:14:00Z',
      });
      await writer.apply(update);
      // SessionWriter.tree is an acknowledged copy, but build accepts a mutable
      // SessionTree. Mirror the real acknowledged record into that same caller
      // object: only a production-owned freeze can protect this request.
      source.apply(update);
      now = DateTime.utc(2026, 10, 30, 9, 15);
      release.complete();
      first = await pending;
    } finally {
      if (!release.isCompleted) release.complete();
      await pending; // Settle even on an assertion failure; no dangling build.
    }
    expect(first.source, isNotNull);
    expect(first.source!.turn, 14);
    expect(first.source!.time, initialClock);
    expect(first.source!.offset, offset);
    expect(clockReads, 1, reason: 'budget passes must reuse the frozen clock');
    final processes = _processSection(first.blockText);
    expect(processes, contains('j-capture'));
    expect(processes, contains('compile-alpha'));
    expect(processes, contains('running'));
    expect(processes, matches(RegExp(r'\b(?:2m|120s|2 min(?:utes)?)\b')));
    expect(processes, isNot(contains('compile-beta')));
    expect(processes, contains('logs unavailable (published at exit)'));
    final next = await builder.build(
      writer.tree,
      turn: 15,
      sourceOffset: writer.committedLength,
    );
    expect(clockReads, 2);
    expect(next.source!.time, now);
    expect(next.source!.offset, writer.committedLength);
    final fresh = _processSection(next.blockText);
    expect(fresh, contains('compile-beta'));
    expect(fresh, contains('pending'));
    expect(fresh, matches(RegExp(r'\b(?:1m|60s|1 min(?:ute)?)\b')));
    expect(fresh, isNot(contains('compile-alpha')));
    // Changing a diagnostic offset cannot change which tree facts are read.
    final diagnosticOnly = await builder.build(
      writer.tree,
      turn: 15,
      sourceOffset: writer.committedLength + 1000000,
    );
    expect(diagnosticOnly.blockText, next.blockText);
    expect(diagnosticOnly.source!.offset, writer.committedLength + 1000000);
    expect(clockReads, 3);
  });

  test('literal user and tool sensorium tags survive projection', () async {
    final (writer, store) = await _session();
    const prompt =
        'Discuss <sensorium> literally.\r\n</sensorium>\nnotices: user-owned';
    const toolText =
        '[read ok]\n<sensorium>\r\nturn: not a harness turn\n</sensorium>\n';
    const arguments = '{"path":"<sensorium>literal</sensorium>"}';
    const reasoning = {
      'type': 'reasoning',
      'id': 'rs-literal',
      'encrypted_content': '<sensorium>opaque</sensorium>',
      'summary': [
        {'text': 'notices: opaque-owned'},
      ],
    };
    await seedExchange(writer, 1, prompt, state: 'running');
    await seedStep(
      writer,
      1,
      exchange: 1,
      output: [
        {'type': 'reasoning', 'item': reasoning},
        callEntry('literal', 'read', arguments),
      ],
    );
    await seedCall(
      writer,
      store,
      callId: 'literal',
      tool: 'read',
      modelText: toolText,
    );
    final before = writer.tree.canonical();
    final built = await _builder(writer).build(writer.tree, turn: 2);
    final history = built.request.items.take(built.request.items.length - 1);
    expect(history.whereType<UserMessage>().single.text, prompt);
    expect(history.whereType<ToolOutputItem>().single.output, toolText);
    expect(history.whereType<ToolCallItem>().single.argumentsJson, arguments);
    expect(history.whereType<OpaqueReasoningItem>().single.json, reasoning);
    expect((built.request.items.last as UserMessage).text, built.blockText);
    expect(writer.tree.canonical(), before);
  });

  test(
    'selected and default effort reach estimates and built requests',
    () async {
      final (writer, _) = await _session();
      await seedExchange(writer, 1, 'go', state: 'running');
      for (final effort in <String?>['high', 'none', null]) {
        final estimates = <ModelRequest>[];
        final builder = RequestBuilder(
          sessionDir: writer.sessionDir,
          model: 'gpt-5.5',
          effort: effort,
          workspaceName: 'proj',
          tools: const [],
          estimateRequest: (request) {
            estimates.add(request);
            return 10;
          },
        );
        final built = await builder.build(writer.tree, turn: 1);
        expect(estimates, isNotEmpty);
        expect(estimates.map((r) => r.reasoningEffort), everyElement(effort));
        expect(built.request.reasoningEffort, effort);
      }
    },
  );

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
      'user:$interruptedNote',
      'user:second prompt',
    ]);
  });

  test('interrupted exchange is followed by the interrupted note', () async {
    final (writer, _) = await _session();
    await seedExchange(writer, 1, 'write a poem', state: 'cancelled');
    await seedStep(
      writer,
      1,
      exchange: 1,
      state: 'cancelled',
      output: const [],
      partial: 'You held the morning',
    );
    await seedExchange(writer, 2, 'hi', state: 'running');
    await seedStep(writer, 2, exchange: 2, state: 'running', output: const []);

    final built = await _builder(writer).build(writer.tree, turn: 2);

    expect(
      interruptedNote,
      'The previous request was interrupted before it finished. '
      'Do not continue it unless asked.',
    );
    expect(_describe(built.request), [
      'user:write a poem',
      'user:$interruptedNote',
      'user:hi',
    ]);
  });

  test(
    'a committed call without a terminal outcome blocks until recovery',
    () async {
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
      await seedCall(
        writer,
        store,
        callId: 'pending',
        tool: 'ls',
        status: 'pending',
      );
      await seedCall(
        writer,
        store,
        callId: 'done',
        tool: 'ls',
        modelText: 'listing',
      );

      await expectLater(
        _builder(writer).build(writer.tree, turn: 2),
        throwsStateError,
      );
      await JobRecovery(writer, store).resume();
      final built = await _builder(writer).build(writer.tree, turn: 2);
      expect(
        built.request.items.whereType<ToolCallItem>().map((c) => c.callId),
        ['missing', 'pending', 'done'],
      );
      expect(
        built.request.items.whereType<ToolOutputItem>().last.output,
        'listing',
      );
      expect(
        built.request.items.whereType<ToolOutputItem>().first.output,
        contains('execution not recorded; not replayed'),
      );
    },
  );

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

  for (final native in [false, true]) {
    for (final change in ['instructions', 'model', 'tools']) {
      test('full history without a boundary survives $change changes '
          '(native=$native)', () async {
        final (writer, _) = await _session();
        const reasoning = {
          'type': 'reasoning',
          'id': 'rs-full-history',
          'encrypted_content': 'unchanged-opaque-reasoning',
        };
        for (final key in ['before', 'after']) {
          await writer.apply(
            rec(1, 'body/contexts/$key', Op.set, {
              'text': key == 'after' && change == 'instructions'
                  ? 'Changed instructions'
                  : 'Original instructions',
            }),
          );
        }
        await seedExchange(writer, 1, 'first prompt', context: 'before');
        final original = _builder(writer);
        await seedStep(
          writer,
          1,
          exchange: 1,
          output: [
            {'type': 'reasoning', 'item': reasoning},
            textEntry('first answer'),
          ],
        );
        await writer.apply(
          rec(1, 'body/steps/s-00000001', Op.merge, {
            'lineage': original.requestLineage(writer.tree),
          }),
        );
        await seedExchange(writer, 2, 'second prompt', context: 'after');
        final rebuilt = await RequestBuilder(
          sessionDir: writer.sessionDir,
          model: change == 'model' ? 'different-model' : 'gpt-5.5',
          workspaceName: 'proj',
          tools: change == 'tools'
              ? const [
                  ToolSpec(
                    name: 'new_tool',
                    description: 'A changed tool roster',
                    parametersJsonSchema: {'type': 'object'},
                  ),
                ]
              : const [],
          nativeCompaction: native
              ? const NativeCompactionPolicy(threshold: 100000)
              : null,
          estimateRequest: (_) => 0,
        ).build(writer.tree, turn: 2);
        expect(rebuilt.boundary, isNull);
        expect(_describe(rebuilt.request), [
          'user:first prompt',
          'reasoning:rs-full-history',
          'assistant:first answer',
          'user:second prompt',
        ]);
        expect(
          rebuilt.request.items.whereType<OpaqueReasoningItem>().single.json,
          reasoning,
        );
        expect(
          rebuilt.request.instructions,
          contains(
            change == 'instructions'
                ? 'Changed instructions'
                : 'Original instructions',
          ),
        );
      });
    }
  }

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

    test('a notrunc node without model text is recomposed whole', () async {
      final (writer, store) = await _session();
      await seedExchange(writer, 1, 'go', state: 'running');
      await seedStep(
        writer,
        1,
        exchange: 1,
        output: [callEntry('c1', 'skill')],
      );
      final body = [for (var i = 1; i <= 2000; i++) 'line $i of the skill'];
      await seedCall(
        writer,
        store,
        callId: 'c1',
        tool: 'skill',
        resultText: '${body.join('\n')}\n',
        summary: 'loaded big',
        extra: {'notrunc': true},
      );

      final built = await _builder(writer).build(writer.tree, turn: 2);

      final output = built.request.items.whereType<ToolOutputItem>().single;
      expect(output.output, startsWith('[skill ok] loaded big'));
      expect(output.output, endsWith('line 2000 of the skill'));
      expect(output.output, isNot(contains('truncated')));
      expect(
        RegExp('line \\d+ of the').allMatches(output.output),
        hasLength(2000),
      );
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

  group('budget baseline follows the instructions identity', () {
    Future<SessionWriter> seeded({required String secondContext}) async {
      final (writer, _) = await _session();
      for (final key in ['k1', 'k2']) {
        await writer.apply(
          rec(1, 'body/contexts/$key', Op.set, {'text': 'ctx $key'}),
        );
      }
      await seedExchange(writer, 1, 'first', context: 'k1');
      await seedStep(
        writer,
        1,
        exchange: 1,
        output: [textEntry('answer')],
        usage: {'input': 1000, 'output': 100},
        context: {'block': 10},
        instructions: {
          'version': instructionsVersion,
          'context': 'k1',
          'role': null,
        },
      );
      await seedExchange(writer, 2, 'second', context: secondContext);
      return writer;
    }

    RequestBuilder huge(SessionWriter writer) => RequestBuilder(
      sessionDir: writer.sessionDir,
      model: 'gpt-5.5',
      workspaceName: 'proj',
      tools: const [],
      estimateRequest: (_) => 1000000,
      clock: () => DateTime(2026, 10, 30, 9, 5),
    );

    test('baseline is reused when the instructions identity matches', () async {
      final writer = await seeded(secondContext: 'k1');

      final built = await huge(writer).build(writer.tree, turn: 2);

      expect(built.used, lessThan(5000));
      expect(built.used, greaterThan(1000));
    });

    test('baseline is dropped when the context key differs', () async {
      final writer = await seeded(secondContext: 'k2');

      final built = await huge(writer).build(writer.tree, turn: 2);

      expect(built.used, greaterThan(900000));
    });
  });
}
