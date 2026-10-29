import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/answerer_support.dart';
import '../support/session_support.dart';

final class _Harness {
  _Harness(this.writer, this.runtime, this.answerer);

  final SessionWriter writer;
  final ToolRuntime runtime;
  final RecordingAnswerer? answerer;

  Map<String, Object?> node(String callId) =>
      writer.tree.get(SessionPath.parse('body/calls/${callKey(callId)}'))!
          as Map<String, Object?>;

  String stored(Map<String, Object?> node) {
    final handle =
        (node['result']! as Map<String, Object?>)['handle']! as String;
    final resolved = resolveHandle(writer.tree, writer.sessionDir, handle);
    return utf8.decode(resolved.file.readAsBytesSync());
  }
}

Future<_Harness> _attach(Directory root, {required bool headless}) async {
  final writer = await createWriter(root);
  final answerer = headless ? null : RecordingAnswerer();
  final runtime = await ToolRuntime.attach(
    writer,
    ResultStore(writer.sessionDir),
    workspace: root,
    kehaiHome: Directory('${root.path}/home')..createSync(),
    answerer: answerer,
    tools: {'ask': const AskTool()},
  );
  addTearDown(runtime.close);
  return _Harness(writer, runtime, answerer);
}

ToolCall _ask(String id, Map<String, Object?> args) =>
    ToolCall(callId: id, name: 'ask', argumentsJson: jsonEncode(args));

void main() {
  late Directory root;
  setUp(() async => root = await tempDir());

  test('chosen answer returns {"choice":...}', () async {
    final h = await _attach(root, headless: false);

    final done = h.runtime.run(
      _ask('a1', {
        'question': 'Which shell?',
        'choices': ['bash', 'pwsh'],
      }),
    );
    final item = await h.answerer!.item(0);
    expect(item.kind, PromptKind.question);
    expect(item.key, callKey('a1'));
    expect(item.tool, 'ask');
    expect(h.runtime.prompts.reply(item.key, 'pwsh'), isNull);
    await done;

    final node = h.node('a1');
    expect(node['status'], 'settled');
    expect(node['envelope'], 'ok');
    expect(h.stored(node), '{"choice":"pwsh"}');
  });

  test('more than 10 choices fails validation', () async {
    final h = await _attach(root, headless: false);

    final eleven = _ask('v1', {
      'question': 'q',
      'choices': [for (var i = 0; i < 11; i++) 'c$i'],
    });
    final repeated = _ask('v2', {
      'question': 'q',
      'choices': ['a', 'a'],
    });
    final nothing = _ask('v3', {'question': 'q', 'allow_text': false});

    final outputs = [
      (await h.runtime.run(eleven)).output,
      (await h.runtime.run(repeated)).output,
      (await h.runtime.run(nothing)).output,
    ];

    expect(outputs[0], contains('choices: maxItems 10'));
    expect(outputs[1], contains('choices: items must be distinct'));
    expect(outputs[2], contains('allow_text'));
    for (final id in ['v1', 'v2', 'v3']) {
      expect(h.node(id)['status'], 'failed', reason: id);
    }
    expect(h.answerer!.items, isEmpty, reason: 'no question reached the user');
  });

  test('out-of-choice answer is re-asked with the allowed list', () async {
    final h = await _attach(root, headless: false);

    final done = h.runtime.run(
      _ask('o1', {
        'question': 'q',
        'choices': ['a', 'b'],
        'allow_text': false,
      }),
    );
    final item = await h.answerer!.item(0);

    expect(
      h.runtime.prompts.reply(item.key, 'c'),
      'answer must be one of: a, b',
    );
    expect(h.node('o1')['status'], 'running');
    expect(h.runtime.prompts.reply(item.key, 'a'), isNull);
    await done;
    expect(h.node('o1')['status'], 'settled');
    expect(h.stored(h.node('o1')), '{"choice":"a"}');
  });

  test('free text is returned as {"text":...} when allowed', () async {
    final h = await _attach(root, headless: false);

    final done = h.runtime.run(_ask('t1', {'question': 'Name?'}));
    final item = await h.answerer!.item(0);
    expect(h.runtime.prompts.reply(item.key, 'kehai'), isNull);
    await done;

    expect(h.stored(h.node('t1')), '{"text":"kehai"}');
  });

  test('no answerer settles error no user attached', () async {
    final h = await _attach(root, headless: true);

    final item = await h.runtime.run(_ask('h1', {'question': 'q'}));

    final node = h.node('h1');
    expect(node['status'], 'settled');
    expect(node['envelope'], 'error');
    expect(node['summary'], 'no user attached');
    expect(item.output, contains('no user attached'));
  });

  test('cancelled ask withdraws the prompt', () async {
    final h = await _attach(root, headless: false);

    final done = h.runtime.run(_ask('x1', {'question': 'q'}));
    final item = await h.answerer!.item(0);
    expect(await h.runtime.cancelTurn(), 1);
    await done;

    final node = h.node('x1');
    expect(node['status'], 'cancelled');
    expect(node['reason'], 'user');
    expect(h.answerer!.withdrawn, [item.key]);
    expect(h.runtime.prompts.reply(item.key, 'late'), 'question withdrawn');
  });
}
