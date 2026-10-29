import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/session_support.dart';

typedef _Body = Future<ToolOutcome> Function(
  ToolContext context,
  Map<String, Object?> in_,
);

/// A tool whose behavior the test supplies, recording what it was given.
final class _FakeTool implements Tool {
  _FakeTool(this.body);

  final _Body body;
  final List<Map<String, Object?>> inputs = [];
  final List<String> started = [];

  @override
  Future<ToolOutcome> run(ToolContext context, Map<String, Object?> input) {
    inputs.add(input);
    started.add(context.callId);
    return body(context, input);
  }
}

/// A stage that records its calls and optionally blocks one call id.
final class _Stage implements CallStage {
  _Stage(this.name, this.log, {this.block});

  final String name;
  final List<String> log;
  final String? block;
  final Completer<void> blocked = Completer<void>();
  final Completer<void> release = Completer<void>();

  @override
  Future<StageOutcome> check(StageCall call, CancelToken cancel) async {
    log.add(name);
    if (call.callId == block) {
      blocked.complete();
      await Future.any([release.future, cancel.whenCancelled]);
    }
    return const StageOutcome.proceed();
  }
}

ToolCall _call(String id, String name, [String args = '{"command":"x"}']) =>
    ToolCall(callId: id, name: name, argumentsJson: args);

String _keyOf(String callId) =>
    'c-${sha256.convert(utf8.encode(callId)).toString().substring(0, 12)}';

final class _Harness {
  _Harness(this.writer, this.store, this.runtime);

  final SessionWriter writer;
  final ResultStore store;
  final ToolRuntime runtime;

  Directory get dir => writer.sessionDir;

  Map<String, Object?> node(String callId) =>
      writer.tree.get(SessionPath.parse('body/calls/${_keyOf(callId)}'))!
          as Map<String, Object?>;

  List<JournalRecord> records() => [
    for (final line in journalOf(dir).readAsLinesSync())
      JournalRecord.parse(line),
  ];

  /// The statuses the journal recorded for [callId], in order.
  List<String> statuses(String callId) => [
    for (final r in records())
      if (r.path == 'body/calls/${_keyOf(callId)}' &&
          r.value is Map<String, Object?> &&
          (r.value! as Map<String, Object?>)['status'] is String)
        (r.value! as Map<String, Object?>)['status']! as String,
  ];

  /// The node paths in the order their `settled` records were appended.
  List<String> settledOrder() => [
    for (final r in records())
      if (r.value is Map<String, Object?> &&
          (r.value! as Map<String, Object?>)['status'] == 'settled')
        r.path,
  ];

  int get journalLines => journalOf(dir).readAsLinesSync().length;

  /// The bytes a call's result handle resolves to through the tree.
  String stored(Map<String, Object?> node) {
    final handle =
        (node['result']! as Map<String, Object?>)['handle']! as String;
    final resolved = resolveHandle(writer.tree, dir, handle);
    return utf8.decode(resolved.file.readAsBytesSync());
  }
}

Future<_Harness> _attach(
  Directory root, {
  Map<String, Tool> tools = const {},
  CallStage? hooks,
  CallStage? gate,
  ToolRuntimeSeams seams = const ToolRuntimeSeams(),
  ResultStoreHooks storeHooks = const ResultStoreHooks(),
  (SessionWriter, HookedIo)? hooked,
}) async {
  final writer = hooked?.$1 ?? await createWriter(root);
  final store = ResultStore(writer.sessionDir, hooks: storeHooks);
  final runtime = await ToolRuntime.attach(
    writer,
    store,
    workspace: root,
    tools: tools,
    hooks: hooks,
    gate: gate ?? const AllowAllStage(),
    seams: seams,
  );
  addTearDown(runtime.close);
  return _Harness(writer, store, runtime);
}

Future<ToolOutcome> _writes(ToolContext c, String text) async {
  await c.output.writeText(text);
  return const ToolOutcome(summary: 'done');
}

void main() {
  late Directory root;
  setUp(() async {
    root = await tempDir();
  });

  group('roster', () {
    test(
      'specs list the eleven tools with versioned names and JSON schemas',
      () async {
        final h = await _attach(root);

        final names = h.runtime.specs.map((s) => s.name).toList();
        expect(names, [
          'read',
          'edit',
          'write',
          'bash',
          'grep',
          'find',
          'ls',
          'ask',
          'job',
          'read_more',
          'search_result',
        ]);
        for (final spec in h.runtime.specs) {
          expect(spec.description, isNotEmpty, reason: spec.name);
          expect(
            spec.parametersJsonSchema['type'],
            'object',
            reason: spec.name,
          );
        }
        for (final d in toolDefinitions) {
          expect(d.version, greaterThanOrEqualTo(1), reason: d.name);
        }
        expect(toolDefinitions.map((d) => d.name).toSet().length, 11);
      },
    );

    test(
      'unknown tool settles failed with envelope error and a stored result',
      () async {
        final tool = _FakeTool((c, i) => _writes(c, 'x'));
        final h = await _attach(root, tools: {'bash': tool});

        final item = await h.runtime.run(_call('u1', 'rm_rf', '{}'));

        expect(item.callId, 'u1');
        expect(item.output, startsWith('[rm_rf error]'));
        expect(item.output, contains('unknown tool rm_rf'));
        final node = h.node('u1');
        expect(node['status'], 'failed');
        expect(node['envelope'], 'error');
        expect(node['tool'], 'rm_rf');
        expect(h.stored(node), contains('unknown tool rm_rf'));
        expect(h.statuses('u1'), ['pending', 'failed']);
        expect(tool.inputs, isEmpty);
      },
    );

    test(
      'read_more and search_result answer with the composer page of a handle',
      () async {
        final big = [for (var n = 1; n <= 2310; n++) 'line $n\n'].join();
        final h = await _attach(
          root,
          tools: {'bash': _FakeTool((c, i) => _writes(c, big))},
        );
        await h.runtime.run(_call('b1', 'bash', '{"command":"x"}'));
        final handle =
            (h.node('b1')['result']! as Map<String, Object?>)['handle']!
                as String;
        final stored = resolveHandle(h.writer.tree, h.store.sessionDir, handle);

        final page = await h.runtime.run(
          _call(
            'm1',
            'read_more',
            jsonEncode({'handle': handle, 'from': 401, 'lines': 100}),
          ),
        );
        final found = await h.runtime.run(
          _call(
            's1',
            'search_result',
            jsonEncode({'handle': handle, 'pattern': r'^line 7\d\d$'}),
          ),
        );
        final unknown = await h.runtime.run(
          _call('m2', 'read_more', '{"handle":"r/000000000000"}'),
        );

        expect(
          page.output,
          await readMore(stored.file, stored.descriptor, from: 401, lines: 100),
        );
        expect(page.output, contains('read_more($handle, from=501)'));
        expect(
          found.output,
          await ResultSearcher().searchResult(
            stored.file,
            stored.descriptor,
            r'^line 7\d\d$',
          ),
        );
        for (final id in ['m1', 's1']) {
          expect(h.node(id)['status'], 'settled', reason: id);
          expect(h.node(id)['envelope'], 'ok', reason: id);
        }
        expect(unknown.output, startsWith('[read_more error]'));
        expect(unknown.output, contains('unknown handle r/000000000000'));
        expect(h.node('m2')['status'], 'settled');
      },
    );

    test(
      'ask is wired in by default; headless it settles no user attached',
      () async {
        final h = await _attach(root);

        final item = await h.runtime.run(
          _call('a1', 'ask', '{"question":"Which one?","choices":["a","b"]}'),
        );

        expect(item.output, isNot(contains('not available')));
        expect(item.output, startsWith('[ask error] no user attached'));
        expect(h.node('a1')['status'], 'settled');
      },
    );
  });

  group('arguments', () {
    test('valid arguments reach the tool unchanged', () async {
      final order = <String>[];
      final tool = _FakeTool((c, i) {
        order.add('tool');
        return _writes(c, 'ok\n');
      });
      final h = await _attach(
        root,
        tools: {'read': tool},
        hooks: _Stage('hooks', order),
        gate: _Stage('gate', order),
      );

      await h.runtime.run(_call('v1', 'read', '{"path":"lib/kehai.dart"}'));

      expect(tool.inputs, [
        {'path': 'lib/kehai.dart'},
      ]);
      expect(order, ['hooks', 'gate', 'tool']);
    });

    test(
      'malformed JSON and schema violations fail before any effect',
      () async {
        final order = <String>[];
        final tool = _FakeTool((c, i) => _writes(c, 'x'));
        final h = await _attach(
          root,
          tools: {'read': tool},
          hooks: _Stage('hooks', order),
          gate: _Stage('gate', order),
        );

        final bad = await h.runtime.run(_call('m1', 'read', '{"path":'));
        final wrong = await h.runtime.run(
          _call('m2', 'read', '{"path":3,"limit":-1}'),
        );

        expect(bad.output, startsWith('[read error]'));
        expect(bad.output, contains('arguments are not a JSON object'));
        expect(wrong.output, contains('path: expected string'));
        expect(wrong.output, contains('limit: minimum 1'));
        for (final id in ['m1', 'm2']) {
          expect(h.node(id)['status'], 'failed', reason: id);
          expect(h.node(id)['envelope'], 'error', reason: id);
          expect(h.statuses(id), ['pending', 'failed'], reason: id);
          expect(h.stored(h.node(id)), isNotEmpty, reason: id);
        }
        expect(tool.inputs, isEmpty);
        expect(order, isEmpty, reason: 'no hook or gate ran');
      },
    );
  });

  group('call node', () {
    test('call node goes pending, running, settled with input and result reference', () async {
      final tool = _FakeTool((c, i) async {
        await c.output.writeText('a\n');
        await c.output.writeText('b\n');
        return const ToolOutcome(summary: '2 lines');
      });
      final h = await _attach(root, tools: {'read': tool});

      final item = await h.runtime.run(
        _call('s1', 'read', '{"path":"lib/kehai.dart"}'),
      );

      expect(h.statuses('s1'), ['pending', 'running', 'settled']);
      final node = h.node('s1');
      expect(node['tool'], 'read');
      expect(node['version'], 1);
      expect(node['callId'], 's1');
      expect(node['attempt'], isA<String>());
      expect(node['input'], {'path': 'lib/kehai.dart'});
      expect(node['envelope'], 'ok');
      expect(node['summary'], '2 lines');
      final result = node['result']! as Map<String, Object?>;
      expect(result['complete'], isTrue);
      expect(h.stored(node), 'a\nb\n');
      expect(item.output, '[read ok] 2 lines\na\nb');
      expect(item.callId, 's1');
    });

    test('unsafe call id is keyed c- plus 12 hex of its SHA-256', () async {
      final tool = _FakeTool((c, i) => _writes(c, 'x'));
      final h = await _attach(root, tools: {'bash': tool});

      final item = await h.runtime.run(_call('call/7 x', 'bash'));

      final key = callKey('call/7 x');
      expect(key, matches(RegExp(r'^c-[0-9a-f]{12}$')));
      expect(key, _keyOf('call/7 x'));
      final node = h.writer.tree.get(SessionPath.parse('body/calls/$key'));
      expect((node! as Map<String, Object?>)['callId'], 'call/7 x');
      expect(item.callId, 'call/7 x');
    });

    test('cancelled call composes an error envelope with a handle', () async {
      final started = Completer<void>();
      final hold = Completer<void>();
      addTearDown(() => hold.isCompleted ? null : hold.complete());
      final tool = _FakeTool((c, i) async {
        await c.output.writeText('one\ntwo\nthree\n');
        started.complete();
        await hold.future;
        return const ToolOutcome(summary: 'late');
      });
      final h = await _attach(root, tools: {'bash': tool});

      final run = h.runtime.run(_call('k1', 'bash'));
      await started.future;
      final cancelled = await h.runtime.cancelTurn();
      final item = await run;

      expect(cancelled, 1);
      final node = h.node('k1');
      expect(node['status'], 'cancelled');
      expect(node['envelope'], 'error');
      expect(node['summary'], 'cancelled: user');
      expect(node['reason'], 'user');
      expect((node['result']! as Map<String, Object?>)['complete'], isFalse);
      expect(h.stored(node), 'one\ntwo\nthree\n');
      expect(item.output, startsWith('[bash error] cancelled: user'));
      expect(item.output, contains('three'));
    });

    test(
      'late update to a settled call returns stale and appends nothing',
      () async {
        final started = Completer<void>();
        final hold = Completer<void>();
        final stale = Completer<String>();
        addTearDown(() => hold.isCompleted ? null : hold.complete());
        final tool = _FakeTool((c, i) async {
          started.complete();
          await hold.future;
          return const ToolOutcome(summary: 'finished anyway');
        });
        final h = await _attach(
          root,
          tools: {'bash': tool},
          seams: ToolRuntimeSeams(onStale: stale.complete),
        );

        final run = h.runtime.run(_call('l1', 'bash'));
        await started.future;
        await h.runtime.cancelTurn();
        await run;
        final lines = h.journalLines;

        hold.complete();
        expect(await stale.future, _keyOf('l1'));

        expect(h.journalLines, lines);
        expect(h.node('l1')['status'], 'cancelled');
        expect(h.statuses('l1'), ['pending', 'running', 'cancelled']);
      },
    );
  });

  group('stored output', () {
    test('settle waits for re-registered descriptor after rewind and resolves in a fork', () async {
      final atSettle = Completer<void>();
      final resume = Completer<void>();
      final started = Completer<void>();
      final release = Completer<void>();
      final tool = _FakeTool((c, i) async {
        started.complete();
        await release.future;
        return _writes(c, 'result\n');
      });
      final h = await _attach(
        root,
        tools: {'bash': tool},
        seams: ToolRuntimeSeams(
          beforeSettle: (key) async {
            atSettle.complete();
            await resume.future;
          },
        ),
      );
      for (var turn = 1; turn <= 3; turn++) {
        await h.writer.apply(rec(turn, 'body/marker', Op.set, turn));
      }

      final run = h.runtime.run(_call('r1', 'bash'));
      await started.future;
      for (var turn = 4; turn <= 5; turn++) {
        await h.writer.apply(rec(turn, 'body/marker', Op.set, turn));
      }
      release.complete();
      await atSettle.future;
      final digest = sha256.convert(utf8.encode('result\n')).toString();
      final descriptorPath = SessionPath.parse(
        'results/${digest.substring(0, 12)}',
      );
      expect(h.writer.tree.contains(descriptorPath), isTrue);

      await h.writer.rewind(4);
      expect(h.writer.tree.contains(descriptorPath), isFalse);
      expect(h.node('r1')['status'], 'running', reason: 'the call is kept');
      resume.complete();
      await run;

      final node = h.node('r1');
      expect(node['status'], 'settled');
      expect(h.writer.tree.contains(descriptorPath), isTrue);
      expect(h.stored(node), 'result\n');
      final forked = await h.writer.fork(h.writer.currentTurn);
      final child = materialize(forked.childDir).tree;
      final handle = (node['result']! as Map<String, Object?>)['handle']!;
      expect(
        resolveHandle(
          child,
          forked.childDir,
          handle as String,
        ).descriptor.bytes,
        7,
      );
    });

    test('storage failure records failed with accepted bytes and a handle-less envelope', () async {
      final sawCancel = Completer<bool>();
      final tool = _FakeTool((c, i) async {
        await c.output.writeText('aaaa\n');
        await c.output.writeText('bbbb\n');
        await c.cancel.whenCancelled;
        sawCancel.complete(c.output.isClosed);
        return const ToolOutcome(summary: 'never recorded');
      });
      final h = await _attach(
        root,
        tools: {'bash': tool},
        storeHooks: ResultStoreHooks(
          beforeWrite: (index, chunk) async {
            if (index == 1) throw const FileSystemException('disk full');
          },
        ),
      );

      final item = await h.runtime.run(_call('f1', 'bash'));

      expect(
        await sawCancel.future,
        isTrue,
        reason: 'the producer was stopped',
      );
      final node = h.node('f1');
      expect(node['status'], 'failed');
      expect(node['reason'], startsWith('storage: '));
      expect(node['accepted'], 5);
      expect(node.containsKey('result'), isFalse);
      expect(node['envelope'], 'error');
      final error = (node['reason']! as String).substring('storage: '.length);
      expect(
        item.output,
        '[bash error] storage failure: $error; 5 bytes accepted, not stored',
      );
      expect(item.output, isNot(contains('r/')));
      expect(h.statuses('f1'), ['pending', 'running', 'failed']);
    });

    test('broken writer fails the run and refuses further calls', () async {
      final root2 = await tempDir();
      final hooked = await createHooked(root2);
      final tool = _FakeTool((c, i) => _writes(c, 'x\n'));
      final h = await _attach(root, tools: {'bash': tool}, hooked: hooked);
      hooked.$2.onWrite = (bytes) async {
        if (utf8.decode(bytes).contains('"settled"')) {
          throw const FileSystemException('journal gone');
        }
      };

      await expectLater(
        h.runtime.run(_call('b1', 'bash')),
        throwsA(isA<StorageError>()),
      );
      final lines = h.journalLines;
      final calls = tool.started.length;

      await expectLater(
        h.runtime.run(_call('b2', 'bash')),
        throwsA(isA<StorageError>()),
      );

      expect(h.journalLines, lines, reason: 'nothing more was appended');
      expect(
        tool.started.length,
        calls,
        reason: 'no further call was admitted',
      );
      expect(hooked.$1.state, WriterState.broken);
    });
  });

  group('parallel calls', () {
    test('two calls run concurrently and settle independently', () async {
      final gates = {
        for (final id in ['p1', 'p2']) id: Completer<void>(),
      };
      final bothRunning = Completer<void>();
      final live = <String>[];
      final tool = _FakeTool((c, i) async {
        live.add(c.callId);
        if (live.length == 2) bothRunning.complete();
        await gates[c.callId]!.future;
        return _writes(c, '${c.callId}\n');
      });
      final h = await _attach(root, tools: {'bash': tool});

      final first = h.runtime.run(_call('p1', 'bash'));
      final second = h.runtime.run(_call('p2', 'bash'));
      await bothRunning.future;

      expect(h.node('p1')['status'], 'running');
      expect(h.node('p2')['status'], 'running');
      gates['p2']!.complete();
      final secondItem = await second;
      expect(h.node('p2')['status'], 'settled');
      expect(h.node('p1')['status'], 'running', reason: 'p1 is still going');
      gates['p1']!.complete();
      final firstItem = await first;

      expect(firstItem.output, contains('p1'));
      expect(secondItem.output, contains('p2'));
      expect(h.settledOrder(), [
        'body/calls/${_keyOf('p2')}',
        'body/calls/${_keyOf('p1')}',
      ], reason: 'recorded as each settled, not in submission order');
    });

    test('41st call over 8 running plus 32 queued fails tool busy', () async {
      final ids = [for (var n = 1; n <= 41; n++) 'q$n'];
      final gates = {for (final id in ids) id: Completer<void>()};
      final order = <String>[];
      final eight = Completer<void>();
      final ninth = Completer<void>();
      final tool = _FakeTool((c, i) async {
        order.add(c.callId);
        if (order.length == 8) eight.complete();
        if (order.length == 9) ninth.complete();
        await gates[c.callId]!.future;
        return _writes(c, 'x\n');
      });
      final h = await _attach(root, tools: {'bash': tool});

      final runs = {for (final id in ids) id: h.runtime.run(_call(id, 'bash'))};
      final busy = await runs['q41']!;
      await eight.future;

      expect(busy.output, contains('tool busy'));
      expect(h.node('q41')['status'], 'failed');
      expect(h.node('q41')['summary'], 'tool busy');
      final byStatus = <String, int>{};
      for (final id in ids) {
        byStatus.update(
          h.node(id)['status']! as String,
          (n) => n + 1,
          ifAbsent: () => 1,
        );
      }
      expect(byStatus, {'running': 8, 'pending': 32, 'failed': 1});
      expect(order, ids.take(8).toList());

      gates['q1']!.complete();
      await ninth.future;
      expect(order[8], 'q9', reason: 'the queue is served in arrival order');

      for (final gate in gates.values) {
        if (!gate.isCompleted) gate.complete();
      }
      await Future.wait(runs.values);
      expect(order, ids.take(40).toList());
      expect(h.node('q40')['status'], 'settled');
    });
  });

  group('turn cancellation', () {
    test(
      'cancelTurn cancels queued then running calls with reason user',
      () async {
        final log = <String>[];
        final gate = _Stage('gate', log, block: 'gated');
        final hold = Completer<void>();
        addTearDown(() => hold.isCompleted ? null : hold.complete());
        final seven = Completer<void>();
        var running = 0;
        final tool = _FakeTool((c, i) async {
          if (++running == 7) seven.complete();
          await hold.future;
          return const ToolOutcome(summary: 'released');
        });
        final h = await _attach(root, tools: {'bash': tool}, gate: gate);

        final ids = [for (var n = 1; n <= 7; n++) 'run$n', 'gated', 'queued'];
        final runs = [for (final id in ids) h.runtime.run(_call(id, 'bash'))];
        await seven.future;
        await gate.blocked.future;

        final cancelled = await h.runtime.cancelTurn();
        await Future.wait(runs);

        expect(cancelled, 9);
        for (final id in ids) {
          final node = h.node(id);
          expect(node['status'], 'cancelled', reason: id);
          expect(node['reason'], 'user', reason: id);
          expect(node['summary'], 'cancelled: user', reason: id);
        }
        final order = [
          for (final r in h.records())
            if (r.value is Map<String, Object?> &&
                (r.value! as Map<String, Object?>)['status'] == 'cancelled')
              r.path,
        ];
        final pendingKeys = [
          'gated',
          'queued',
        ].map((id) => 'body/calls/${_keyOf(id)}');
        expect(
          order.take(2).toSet(),
          pendingKeys.toSet(),
          reason: 'pending calls are cancelled before running ones',
        );
        expect(tool.started, isNot(contains('queued')));
      },
    );

    test('cancelTurn after settle changes nothing', () async {
      final tool = _FakeTool((c, i) => _writes(c, 'x\n'));
      final h = await _attach(root, tools: {'bash': tool});
      await h.runtime.run(_call('d1', 'bash'));
      final lines = h.journalLines;

      final cancelled = await h.runtime.cancelTurn();

      expect(cancelled, 0);
      expect(h.journalLines, lines);
      expect(h.node('d1')['status'], 'settled');
    });
  });
}
