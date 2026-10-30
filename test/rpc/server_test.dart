import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/fake_provider.dart';
import '../support/rpc_support.dart';
import '../support/session_support.dart';

/// A tool that records that it ran and settles `ok`.
final class _Flag implements Tool {
  _Flag();

  int runs = 0;

  @override
  Future<ToolOutcome> run(
    ToolContext context,
    Map<String, Object?> input,
  ) async {
    runs++;
    return const ToolOutcome(summary: 'ok');
  }
}

ToolCall _call(String id, String name, String args) =>
    ToolCall(callId: id, name: name, argumentsJson: args);

const _toolUse = Completed(StopReason.toolUse);

/// A provider whose first response waits for [release], then streams [steps].
FakeProvider _gated(Completer<void> release, List<List<ProviderEvent>> steps) =>
    FakeProvider((request, cancel, call) async* {
      if (call == 0) await release.future;
      yield* Stream.fromIterable(steps[call]);
    });

Map<String, Object?> _record(Map<String, Object?> update) =>
    update['record']! as Map<String, Object?>;

/// Waits until the engine's tree records request [id] as no longer admitted.
Future<void> _untilSettled(RpcRig rig, String id) async {
  final deadline = DateTime.now().add(const Duration(seconds: 8));
  while (true) {
    final node = rig.writer.tree.get(SessionPath.parse('meta/requests/$id'));
    if (node is Map<String, Object?> && node['state'] != 'admitted') return;
    if (DateTime.now().isAfter(deadline)) fail('request $id never settled');
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

void main() {
  group('Materialization then ordered updates', () {
    test(
      'snapshot plus updates equals the engine tree through one exchange',
      () async {
        final rig = await rpcRig(
          FakeProvider.steps([
            textStep(['Hi']),
          ]),
        );
        final hello = await rig.nextOfType('hello');
        expect(hello['protocol'], 1);
        final snapshot = await rig.nextOfType('snapshot');
        expect(
          rig.events.indexOf(hello),
          lessThan(rig.events.indexOf(snapshot)),
        );
        expect(snapshot['offset'], rig.writer.committedLength);

        rig.send({'type': 'submit', 'id': 'r1', 'text': 'hi', 'turn': 0});
        await rig.requestSettled('r1');

        final mirror = SessionTree.fromJson(
          snapshot['tree']! as Map<Object?, Object?>,
        );
        final updates = rig.ofType('update');
        expect(updates.first['offset'], snapshot['offset']);
        var last = -1;
        for (final update in updates) {
          final offset = update['offset']! as int;
          expect(offset, greaterThan(last), reason: 'updates arrive in order');
          last = offset;
          final record = _record(update);
          mirror.apply(
            JournalRecord(
              turn: record['turn']! as int,
              path: record['path']! as String,
              op: Op.fromWire(record['op']! as String)!,
              value: record['value'],
            ),
          );
        }
        expect(mirror.toJson(), rig.writer.tree.toJson());
        expect(rig.ofType('resync'), isEmpty);
      },
    );

    test(
      'rewind update is followed by resync and the rewound snapshot',
      () async {
        final rig = await rpcRig(FakeProvider.steps(const []));
        await rig.nextOfType('snapshot');
        await rig.writer.apply(rec(1, 'body/a', Op.set, 1));
        await rig.writer.apply(rec(2, 'body/b', Op.set, 2));

        final rewind = await rig.writer.rewind(1);

        final resync = await rig.nextOfType('resync');
        final at = rig.events.indexOf(resync);
        expect(rig.events[at - 1]['type'], 'update');
        expect(rig.events[at - 1]['offset'], rewind.offset);
        expect(_record(rig.events[at - 1])['op'], 'rewind');
        final snapshot = await rig.nextOfType('snapshot', from: at + 1);
        expect(rig.events[at + 1], same(snapshot));
        expect(snapshot['tree'], rig.writer.tree.toJson());
        expect(snapshot['offset'], rig.writer.committedLength);
        final body = (snapshot['tree']! as Map<String, Object?>)['body'];
        expect(body, {'a': 1});
        await expectConverges(rig);
      },
    );

    test('snapshot offset after a cut torn tail is the cut length', () async {
      final root = await tempDir();
      final first = await SessionWriter.create(Directory(root.path));
      await first.apply(rec(1, 'body/a', Op.set, 1));
      final committed = first.committedLength;
      await first.close();
      final journal = journalOf(first.sessionDir);
      journal.writeAsBytesSync(
        utf8.encode('{"turn":2,"pa'),
        mode: FileMode.append,
      );
      expect(journal.lengthSync(), greaterThan(committed));

      final rig = await rpcRig(
        FakeProvider.steps(const []),
        resumeSession: first.sessionDir,
      );
      final snapshot = await rig.nextOfType('snapshot');

      expect(rig.writer.tornTail, isNotNull);
      expect(journal.lengthSync(), committed);
      expect(snapshot['offset'], committed);
      expect(snapshot['offset'], rig.writer.committedLength);
    });
  });

  group('Ephemeral stream events', () {
    test('two stream events then the committed Hello update', () async {
      final rig = await rpcRig(
        FakeProvider.steps([
          textStep(['Hel', 'lo']),
        ]),
      );
      await rig.nextOfType('snapshot');

      rig.send({'type': 'submit', 'id': 'r1', 'text': 'hi', 'turn': 0});
      await rig.requestSettled('r1');

      final streams = rig.ofType('stream');
      expect(streams.map((e) => e['delta']), ['Hel', 'lo']);
      expect(streams.map((e) => e['kind']).toSet(), {'text'});
      expect(streams.first['turn'], 1);
      final commit = rig.events.indexWhere(
        (e) =>
            e['type'] == 'update' &&
            (_record(e)['value'] as Map?)?['output'] != null,
      );
      expect(commit, greaterThan(rig.events.indexOf(streams.last)));
      final output =
          (_record(rig.events[commit])['value']!
              as Map<String, Object?>)['output'];
      expect(output, [
        {'type': 'text', 'text': 'Hello'},
      ]);
    });
  });

  group('Ephemeral stream events', () {
    test('dropped deltas leave the whole text in snapshot or update', () async {
      final provider = FakeProvider((request, cancel, call) async* {
        for (var i = 0; i < 300; i++) {
          yield const TextDelta('x');
        }
        yield const Completed(StopReason.endTurn);
      });
      final rig = await rpcRig(
        provider,
        limits: const PumpLimits(droppable: 2048, batch: 1024),
      );
      await rig.nextOfType('snapshot');
      rig.stallOutput();

      rig.send({'type': 'submit', 'id': 'r1', 'text': 'go', 'turn': 0});
      await _untilSettled(rig, 'r1');
      rig.resumeOutput();

      await expectConverges(rig);
      expect(rig.ofType('resync'), isNotEmpty);
      expect(rig.ofType('stream').length, lessThan(300));
      final mirror = mirrorOf(rig.events)!;
      expect(jsonEncode(mirror.toJson()), contains('x' * 300));
    });
  });

  group('Commands correlated by request id', () {
    test('duplicate submit reports the recorded state and runs once', () async {
      final release = Completer<void>();
      final rig = await rpcRig(
        _gated(release, [
          textStep(['ok']),
        ]),
      );
      await rig.nextOfType('snapshot');

      rig.send({'type': 'submit', 'id': 'r7', 'text': 'same', 'turn': 0});
      final first = await rig.answerTo('r7');
      final at = rig.events.indexOf(first) + 1;
      rig.send({'type': 'submit', 'id': 'r7', 'text': 'same', 'turn': 0});
      final second = await rig.answerTo('r7', from: at);

      expect(first['type'], 'reply');
      expect(second['type'], 'reply');
      expect(second['state'], 'admitted');
      release.complete();
      await rig.requestSettled('r7');
      expect(rig.provider.requests, hasLength(1));
      expect(
        (rig.writer.tree.get(
          SessionPath.parse('body/exchanges'),
        ) as Map<String, Object?>).keys,
        hasLength(1),
      );
    });

    test('reused id with other text is a request id collision', () async {
      final release = Completer<void>();
      final rig = await rpcRig(
        _gated(release, [
          textStep(['ok']),
        ]),
      );
      await rig.nextOfType('snapshot');
      rig.send({'type': 'submit', 'id': 'r7', 'text': 'one', 'turn': 0});
      final first = await rig.answerTo('r7');

      rig.send({'type': 'submit', 'id': 'r7', 'text': 'two', 'turn': 0});
      final second = await rig.answerTo(
        'r7',
        from: rig.events.indexOf(first) + 1,
      );

      expect(second['type'], 'error');
      expect(second['message'], 'request id collision');
      release.complete();
      await rig.requestSettled('r7');
      expect(rig.provider.requests, hasLength(1));
    });

    test('submit at an older turn is stale and not admitted', () async {
      final rig = await rpcRig(FakeProvider.steps(const []), seedTurn: 6);
      await rig.nextOfType('snapshot');

      rig.send({'type': 'submit', 'id': 'r1', 'text': 'hi', 'turn': 4});

      final reply = await rig.answerTo('r1');
      expect(reply['type'], 'error');
      expect(reply['message'], 'stale: session is at turn 6');
      expect(
        rig.writer.tree.get(SessionPath.parse('meta/requests/r1')),
        isNull,
      );
      expect(rig.provider.requests, isEmpty);
    });
  });

  group('Interrupt, answer and status', () {
    test('status of an unknown id is not-admitted', () async {
      final rig = await rpcRig(FakeProvider.steps(const []));
      await rig.nextOfType('snapshot');

      rig.send({'type': 'status', 'id': 'never'});

      final reply = await rig.answerTo('never');
      expect(reply['type'], 'reply');
      expect(reply['state'], 'not-admitted');
    });

    test(
      'answer outside the choices errors and the prompt stays open',
      () async {
        final rig = await rpcRig(
          FakeProvider.steps([
            [
              _call('q1', 'ask', '{"question":"pick","choices":["a","b"]}'),
              _toolUse,
            ],
            textStep(['thanks']),
          ]),
        );
        await rig.nextOfType('snapshot');
        rig.send({'type': 'submit', 'id': 'r1', 'text': 'ask me', 'turn': 0});
        final prompt = await rig.nextOfType('prompt');
        final key = (prompt['item']! as Map<String, Object?>)['key']! as String;

        rig.send({'type': 'answer', 'key': key, 'text': 'c'});
        final refused = await rig.answerTo('answer');
        expect(refused['type'], 'error');
        expect(refused['message'], 'answer must be one of: a, b');
        expect(rig.ofType('withdraw'), isEmpty);

        rig.send({'type': 'answer', 'key': key, 'text': 'a'});
        final accepted = await rig.next(
          (e) => e['type'] == 'reply' && e['to'] == 'answer',
        );
        expect(accepted['ok'], isTrue);
        await rig.requestSettled('r1');
      },
    );
  });

  group('Prompts reach the client', () {
    test(
      'non-autoapproved bash sends a permission prompt and allow runs it',
      () async {
        final bash = _Flag();
        final rig = await rpcRig(
          FakeProvider.steps([
            [_call('b1', 'bash', '{"command":"rm -rf build"}'), _toolUse],
            textStep(['removed']),
          ]),
          tools: {'bash': bash},
          kehaiHome: true,
        );
        await rig.nextOfType('snapshot');

        rig.send({'type': 'submit', 'id': 'r1', 'text': 'clean', 'turn': 0});
        final prompt = await rig.nextOfType('prompt');

        final item = prompt['item']! as Map<String, Object?>;
        expect(item['kind'], 'permission');
        expect(item['tool'], 'bash');
        expect(item['key'], callKey('b1'));
        expect((item['input']! as Map)['command'], 'rm -rf build');
        expect(bash.runs, 0);

        rig.send({'type': 'answer', 'key': item['key'], 'text': 'allow'});
        await rig.requestSettled('r1');
        expect(bash.runs, 1);
      },
    );

    test(
      'interrupt withdraws the open question and a late answer is refused',
      () async {
        final rig = await rpcRig(
          FakeProvider.steps([
            [
              _call('q1', 'ask', '{"question":"pick","choices":["a","b"]}'),
              _toolUse,
            ],
          ]),
        );
        await rig.nextOfType('snapshot');
        rig.send({'type': 'submit', 'id': 'r1', 'text': 'ask me', 'turn': 0});
        final prompt = await rig.nextOfType('prompt');
        final key = (prompt['item']! as Map<String, Object?>)['key']! as String;

        rig.send({'type': 'interrupt'});

        final reply = await rig.answerTo('interrupt');
        expect(reply['type'], 'reply');
        expect(reply['running'], isTrue);
        final withdraw = await rig.nextOfType('withdraw');
        expect(withdraw['key'], key);

        rig.send({'type': 'answer', 'key': key, 'text': 'a'});
        final late = await rig.answerTo('answer');
        expect(late['type'], 'error');
        expect(late['message'], 'question withdrawn');
      },
    );
  });
}
