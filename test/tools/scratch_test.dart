import 'dart:async';
import 'dart:convert';

import 'package:kehai/kehai.dart';
import 'package:kehai/src/workspace/roles.dart';
import 'package:test/test.dart';

import '../support/session_support.dart';

// These tests deliberately dispatch names through the existing runtime. They
// must fail as unknown tools before scratch is implemented, not fail to import
// a future ScratchTool or a future mutation capability.
final class _ScratchHarness {
  _ScratchHarness(this.writer, this.io, this.runtime);

  final SessionWriter writer;
  final HookedIo io;
  final ToolRuntime runtime;
  int _nextId = 0;

  static Future<_ScratchHarness> create({
    bool yolo = true,
    Set<String>? roster,
    CallStage? hooks,
    Map<String, Object?> lineage = const {'parent': null},
  }) async {
    final root = await tempDir();
    final home = await tempDir();
    late HookedIo io;
    final writer = await SessionWriter.create(
      root,
      lineage: lineage,
      decorate: (inner) => io = HookedIo(inner),
    );
    addTearDown(writer.close);
    final runtime = await ToolRuntime.attach(
      writer,
      ResultStore(writer.sessionDir),
      workspace: root,
      kehaiHome: home,
      yolo: yolo,
      roster: roster,
      hooks: hooks,
    );
    addTearDown(runtime.close);
    return _ScratchHarness(writer, io, runtime);
  }

  Future<_ScratchHarness> reattach({
    bool yolo = true,
    Set<String>? roster,
  }) async {
    await runtime.close();
    final attached = await ToolRuntime.attach(
      writer,
      ResultStore(writer.sessionDir),
      workspace: runtime.workspace,
      kehaiHome: runtime.kehaiHome,
      yolo: yolo,
      roster: roster,
    );
    addTearDown(attached.close);
    return _ScratchHarness(writer, io, attached).._nextId = _nextId;
  }

  Map<String, Object?> get scratch {
    final node = writer.tree.get(SessionPath.parse('scratch'));
    return node == null
        ? <String, Object?>{}
        : Map<String, Object?>.from(node as Map<String, Object?>);
  }

  Map<String, Object?> node(String id) =>
      writer.tree.get(SessionPath.parse('body/calls/${callKey(id)}'))!
          as Map<String, Object?>;

  List<JournalRecord> get records => [
    for (final line in journalOf(writer.sessionDir).readAsLinesSync())
      JournalRecord.parse(line),
  ];

  List<JournalRecord> get mutations => [
    for (final record in records)
      if (record.path == 'scratch' || record.path.startsWith('scratch/'))
        record,
  ];

  String stored(String id) {
    final reference = node(id)['result']! as Map<String, Object?>;
    final resolved = resolveHandle(
      writer.tree,
      writer.sessionDir,
      reference['handle']! as String,
    );
    return utf8.decode(resolved.file.readAsBytesSync());
  }

  Future<ToolOutputItem> call(
    String name,
    Map<String, Object?> input, {
    String? id,
    CancelToken? cancel,
  }) => runtime.run(
    ToolCall(
      callId: id ?? 'scratch-${_nextId++}',
      name: name,
      argumentsJson: jsonEncode(input),
    ),
    cancel: cancel,
  );

  Future<ToolOutputItem> set(String key, String value, {String? id}) =>
      call('scratch_set', {'key': key, 'value': value}, id: id);

  Future<ToolOutputItem> del(String key, {String? id}) =>
      call('scratch_del', {'key': key}, id: id);

  void expectOk(ToolOutputItem item) {
    expect(item.output, isNot(contains('unknown tool')), reason: item.output);
    expect(node(item.callId)['envelope'], 'ok', reason: item.output);
    expect(node(item.callId)['status'], 'settled', reason: item.output);
    // Resolve through the real descriptor/tree path even for empty output.
    stored(item.callId);
  }

  Future<void> seed(String key, String value) async =>
      expectOk(await set(key, value));

  Future<void> turn(int turn) async {
    while (writer.currentTurn < turn) {
      final next = writer.currentTurn + 1;
      await writer.apply(rec(next, 'body/scratch-test-turn', Op.set, next));
    }
  }

  Future<void> drain() async {
    await writer.applyGuarded((_) => const GuardedRefusal('test drain'));
  }

  // onWrite sees the actual decided journal record. Holding beforeFlush leaves
  // the queue occupied but does not change the successful decision cutoff.
  _FlushHold hold(bool Function(JournalRecord) matches) {
    final hold = _FlushHold();
    var armed = false;
    io.onWrite = (bytes) async {
      final record = JournalRecord.parse(utf8.decode(bytes));
      if (!hold.triggered && matches(record)) {
        hold.triggered = true;
        armed = true;
      }
    };
    io.beforeFlush = () async {
      if (!armed) return;
      armed = false;
      hold.entered.complete();
      await hold.release.future;
    };
    addTearDown(hold.open);
    return hold;
  }
}

final class _FlushHold {
  final entered = Completer<void>();
  final release = Completer<void>();
  bool triggered = false;

  void open() {
    if (!release.isCompleted) release.complete();
  }
}

// Synchronize at the ordinary hook boundary: both real calls must be admitted
// and validated before either is released toward the real permission gate.
final class _PairBarrier implements CallStage {
  final arrived = Completer<void>();
  final release = Completer<void>();
  final _seen = <String>{};

  @override
  Future<StageOutcome> check(StageCall call, CancelToken cancel) async {
    if (call.callId == 'left' || call.callId == 'right') {
      _seen.add(call.callId);
      if (_seen.length == 2 && !arrived.isCompleted) arrived.complete();
      await release.future;
    }
    return const StageOutcome.proceed();
  }

  void open() {
    if (!release.isCompleted) release.complete();
  }
}

Future<List<ToolOutputItem>> _pair(
  _ScratchHarness h,
  _PairBarrier barrier,
  String leftKey,
  String rightKey,
) async {
  final answers = Future.wait([
    h.set(leftKey, 'left', id: 'left'),
    h.set(rightKey, 'right', id: 'right'),
  ]);
  try {
    await _reach(
      barrier.arrived.future,
      answers.then<Object>((items) => items),
    );
    barrier.open();
    return await answers;
  } finally {
    barrier.open();
    await answers;
  }
}

Role _role({List<String>? tools}) => Role(
  name: 'scratch-test',
  description: 'Exercise the production child roster',
  model: null,
  tools: tools,
  unmapped: const [],
  body: 'Work only in the child session.',
  path: 'unused',
  source: 'unused',
  digest: 'scratch-test-role',
);

bool _running(JournalRecord record, String id) =>
    record.path == 'body/calls/${callKey(id)}' &&
    record.value is Map<String, Object?> &&
    (record.value! as Map<String, Object?>)['status'] == 'running';

// Make failure-to-reach a barrier an assertion with the actual tool result,
// rather than a timeout when an unknown tool never reaches its execution seam.
Future<void> _reach(Future<void> barrier, Future<Object> answer) async {
  final entered = await Future.any([
    barrier.then((_) => true),
    answer.then((_) => false),
  ]);
  if (!entered) {
    final result = await answer;
    fail(
      'call ended before the real writer barrier: '
      '${result is ToolOutputItem ? result.output : result}',
    );
  }
}

Future<Object> _capture(Future<ToolOutputItem> answer) => answer.then<Object>(
  (item) => item,
  onError: (Object error, StackTrace _) => error,
);

int _tokens(String value) => (utf8.encode(value).length + 2) ~/ 3;

// An admission-size oracle, not a copied sensorium block. The contract counts
// header, key lines, inter-entry newlines and four spaces after EVERY boundary.
// Cases on the ceiling leave one byte for an optional final section newline.
String _section(Map<String, String> values) {
  final keys = values.keys.toList()..sort();
  final boundaries = RegExp(r'\r\n|[\n\r\x0b\x0c\u0085\u2028\u2029]');
  return 'scratch:\n${keys.map((key) {
    final value = values[key]!.replaceAllMapped(boundaries, (match) => '${match[0]}    ');
    return '  $key:\n    $value';
  }).join('\n')}';
}

void _expectLimit(
  _ScratchHarness h,
  ToolOutputItem item, {
  required String kind,
  required int current,
  required int proposed,
  required int limit,
}) {
  expect(h.node(item.callId)['envelope'], 'error', reason: item.output);
  final text = '${item.output}\n${h.stored(item.callId)}'.toLowerCase();
  expect(text, isNot(contains('unknown tool')), reason: text);
  expect(text, contains(kind));
  expect(text, contains('current'));
  expect(text, contains('propos'));
  for (final size in {current, proposed, limit}) {
    expect(text, matches(RegExp('\\b$size\\b')), reason: text);
  }
}

void main() {
  test('set and overwrite preserve verbatim current value', () async {
    final h = await _ScratchHarness.create();
    await h.turn(2);
    const original = '  first\r\nsecond\n';
    const replacement =
        ' \t\u00e9\r\n</sensorium>\nnotices:\rnext\u000bvt\u000cff'
        '\u0085nel\u2028ls\u2029ps\r\n';
    final created = await h.set('goal', original);
    h.expectOk(created);
    expect(h.scratch, {
      'goal': {'value': original},
    });
    final overwritten = await h.set('goal', replacement);
    h.expectOk(overwritten);
    expect(h.scratch, {
      'goal': {'value': replacement},
    });
    expect(h.mutations, hasLength(2));
    for (final record in h.mutations) {
      expect(record.path, 'scratch/goal');
      expect(record.op, Op.set);
      expect(record.turn, 2);
    }
    // Results from before the overwrite remain separately addressable.
    expect(h.node(created.callId)['result'], isA<Map<String, Object?>>());
    h.stored(created.callId);
  });

  group('key, value and rendered-section limits refuse atomically', () {
    test('20 keys admit overwrite but refuse key 21', () async {
      final h = await _ScratchHarness.create();
      for (var n = 0; n < 20; n++) {
        await h.seed('k${n.toString().padLeft(2, '0')}', 'x');
      }
      await h.seed('k00', 'replacement');
      final before = h.scratch;
      final count = h.mutations.length;
      final item = await h.set('overflow', 'x');
      _expectLimit(h, item, kind: 'key', current: 20, proposed: 21, limit: 20);
      expect(h.scratch, before);
      expect(h.mutations, hasLength(count));
    });

    for (final example in <String, String>{
      'ASCII': 'x' * 240,
      'two-byte UTF-8': '\u00e9' * 120,
      'four-byte UTF-8': '\u{1f989}' * 60,
    }.entries) {
      test('80 value tokens admit and 81 refuse (${example.key})', () async {
        final h = await _ScratchHarness.create();
        expect(_tokens(example.value), 80);
        await h.seed('goal', example.value);
        final before = h.scratch;
        final count = h.mutations.length;
        final item = await h.set('goal', '${example.value}x');
        _expectLimit(
          h,
          item,
          kind: 'value',
          current: 80,
          proposed: 81,
          limit: 80,
        );
        expect(h.scratch, before);
        expect(h.mutations, hasLength(count));
      });
    }

    test(
      '400 section tokens include header keys indentation and separators',
      () async {
        final h = await _ScratchHarness.create();
        final values = {
          'a': 'x' * 240,
          'b': 'x' * 240,
          'c': 'x' * 240,
          'd': 'x' * 240,
          'e': 'x' * 181,
        };
        expect(utf8.encode(_section(values)), hasLength(1199));
        expect(_tokens(_section(values)), 400);
        // Deliberately insert out of lexical order; accounting must not depend
        // on insertion order or just sum the (381) unframed value tokens.
        for (final key in ['e', 'd', 'c', 'b', 'a']) {
          await h.seed(key, values[key]!);
        }
        final before = h.scratch;
        final count = h.mutations.length;
        final proposed = {...values, 'e': 'x' * 184};
        expect(_tokens(_section(proposed)), 401);
        final item = await h.set('e', proposed['e']!);
        _expectLimit(
          h,
          item,
          kind: 'section',
          current: 400,
          proposed: 401,
          limit: 400,
        );
        expect(h.scratch, before);
        expect(h.mutations, hasLength(count));
      },
    );

    test('long legal keys count toward the section cap', () async {
      final h = await _ScratchHarness.create();
      final values = <String, String>{};
      for (var n = 0; n < 8; n++) {
        final key = '${'k' * 127}$n';
        final value = n == 0 ? 'xx' : '';
        values[key] = value;
        await h.seed(key, value);
      }
      final before = h.scratch;
      final count = h.mutations.length;
      final key = '${'k' * 127}8';
      final proposed = {...values, key: ''};
      expect(_tokens(_section(values)), lessThanOrEqualTo(400));
      expect(_tokens(_section(proposed)), greaterThan(400));
      final item = await h.set(key, '');
      _expectLimit(
        h,
        item,
        kind: 'section',
        current: _tokens(_section(values)),
        proposed: _tokens(_section(proposed)),
        limit: 400,
      );
      expect(h.scratch, before);
      expect(h.mutations, hasLength(count));
    });

    for (final boundary in <String, String>{
      'CRLF': '\r\n',
      'LF': '\n',
      'CR': '\r',
      'VT': '\u000b',
      'FF': '\u000c',
      'NEL': '\u0085',
      'LS': '\u2028',
      'PS': '\u2029',
    }.entries) {
      test(
        'every ${boundary.key} boundary and trailing empty line counts',
        () async {
          final h = await _ScratchHarness.create();
          final value = 'x${boundary.value}' * 39;
          expect(_tokens(value), lessThanOrEqualTo(80));
          final values = <String, String>{};
          var index = 0;
          String keyAt(int n) => 'k${n.toString().padLeft(2, '0')}';
          while (_tokens(_section({...values, keyAt(index): value})) <= 400) {
            final key = keyAt(index++);
            values[key] = value;
            await h.seed(key, value);
          }
          expect(values.length, lessThan(20));
          final before = h.scratch;
          final count = h.mutations.length;
          final proposed = {...values, keyAt(index): value};
          final item = await h.set(keyAt(index), value);
          _expectLimit(
            h,
            item,
            kind: 'section',
            current: _tokens(_section(values)),
            proposed: _tokens(_section(proposed)),
            limit: 400,
          );
          expect(h.scratch, before);
          expect(h.mutations, hasLength(count));
        },
      );
    }
  });

  test('invalid path-segment key cannot mutate scratch', () async {
    final h = await _ScratchHarness.create();
    await h.seed('safe_A-0.:', 'untouched');
    final before = h.scratch;
    final count = h.mutations.length;
    for (final key in [
      '',
      'a/b',
      'a\\b',
      'two words',
      '\n',
      '\u00e9',
      'k' * 129,
    ]) {
      for (final tool in ['scratch_set', 'scratch_del']) {
        final item = await h.call(tool, {
          'key': key,
          if (tool == 'scratch_set') 'value': 'bad',
        });
        expect(h.node(item.callId)['envelope'], 'error', reason: item.output);
        final text = '${item.output}\n${h.stored(item.callId)}'.toLowerCase();
        expect(text, isNot(contains('unknown tool')));
        expect(text, matches(RegExp(r'key|segment|path|argument')));
        expect(h.scratch, before, reason: '$tool with ${jsonEncode(key)}');
        expect(h.mutations, hasLength(count));
      }
    }
  });

  test('repeated delete reports already absent', () async {
    final h = await _ScratchHarness.create();
    await h.seed('goal', 'remove me');
    final removed = await h.del('goal');
    h.expectOk(removed);
    expect(h.scratch, isEmpty);
    expect(h.mutations.last.path, 'scratch/goal');
    expect(h.mutations.last.op, Op.del);
    final count = h.mutations.length;
    final repeated = await h.del('goal');
    h.expectOk(repeated);
    expect(
      '${repeated.output}\n${h.stored(repeated.callId)}'.toLowerCase(),
      matches(
        RegExp(
          r'already\s+(absent|missing)|not\s+(present|found)|does not exist|no[- ]op',
        ),
      ),
    );
    expect(h.scratch, isEmpty);
    expect(h.mutations, hasLength(count), reason: 'absent delete is a no-op');
  });

  test('concurrent last-slot sets validate at queue head', () async {
    final barrier = _PairBarrier();
    addTearDown(barrier.open);
    final h = await _ScratchHarness.create(hooks: barrier);
    for (var n = 0; n < 19; n++) {
      await h.seed('k$n', 'x');
    }
    final observedSizes = <int>[];
    final subscription = h.writer.subscribe().listen((update) {
      if (update.record.path.startsWith('scratch/')) {
        observedSizes.add(h.scratch.length);
      }
    });
    addTearDown(subscription.cancel);
    final before = h.mutations.length;
    final answers = await _pair(h, barrier, 'left', 'right');
    final accepted = answers
        .where((item) => h.node(item.callId)['envelope'] == 'ok')
        .toList();
    final refused = answers
        .where((item) => h.node(item.callId)['envelope'] == 'error')
        .toList();
    expect(
      accepted,
      hasLength(1),
      reason: answers.map((item) => item.output).join('\n'),
    );
    expect(refused, hasLength(1));
    h.expectOk(accepted.single);
    _expectLimit(
      h,
      refused.single,
      kind: 'key',
      current: 20,
      proposed: 21,
      limit: 20,
    );
    expect(h.scratch, hasLength(20));
    expect(
      h.scratch.containsKey('left') != h.scratch.containsKey('right'),
      isTrue,
    );
    expect(h.mutations, hasLength(before + 1));
    expect(observedSizes, everyElement(lessThanOrEqualTo(20)));
  });

  test('same-key concurrent sets use last committed value', () async {
    final barrier = _PairBarrier();
    addTearDown(barrier.open);
    final h = await _ScratchHarness.create(hooks: barrier);
    await h.seed('goal', 'original');
    final before = h.mutations.length;
    final answers = await _pair(h, barrier, 'goal', 'goal');
    for (final item in answers) {
      h.expectOk(item);
    }
    final committed = h.mutations.skip(before).toList();
    expect(committed, hasLength(2));
    expect(
      committed.map((record) => record.value),
      unorderedEquals([
        {'value': 'left'},
        {'value': 'right'},
      ]),
    );
    expect(h.scratch, {'goal': committed.last.value});
  });

  group('cancellation or rewind before decision blocks late mutation', () {
    for (final interruption in ['cancel', 'rewind']) {
      for (final operation in ['create', 'replace', 'delete']) {
        test('$interruption prevents late $operation', () async {
          final h = await _ScratchHarness.create();
          await h.turn(1);
          await h.seed('anchor', 'survives');
          if (operation != 'create') await h.seed('goal', 'original');
          final before = h.scratch;
          final count = h.mutations.length;
          await h.turn(2);
          const id = 'late';
          final hold = h.hold((record) => _running(record, id));
          final cancel = CancelToken();
          final answer = _capture(
            h.call(
              operation == 'delete' ? 'scratch_del' : 'scratch_set',
              {'key': 'goal', if (operation != 'delete') 'value': 'late value'},
              id: id,
              cancel: cancel,
            ),
          );
          Object? result;
          try {
            await _reach(hold.entered.future, answer);
            // The call's running record has been decided, but not acknowledged.
            // _execute is waiting for that acknowledgement before invoking the
            // tool. Rewind is queued NOW, ahead of any mutation it can enqueue.
            if (interruption == 'cancel') {
              cancel.cancel();
              hold.open();
            } else {
              final rewound = h.writer.rewind(1);
              hold.open();
              await rewound;
            }
            result = await answer;
            await h.drain();
          } finally {
            hold.open();
            await answer;
          }
          if (interruption == 'cancel') {
            expect(result, isA<ToolOutputItem>());
            expect(h.node(id)['status'], 'cancelled');
            expect(h.node(id)['envelope'], 'error');
            h.stored(id);
          } else {
            expect(result, isA<StaleCallError>());
            expect(
              h.writer.tree.get(SessionPath.parse('body/calls/${callKey(id)}')),
              isNull,
            );
          }
          expect(h.scratch, before);
          expect(
            h.mutations,
            hasLength(count),
            reason: 'no late scratch record',
          );
        });
      }
    }
  });

  test('held flush cancellation preserves committed scratch on reopen without replay', () async {
    final h = await _ScratchHarness.create();
    await h.turn(1);
    await h.seed('anchor', 'unchanged');
    const value = '  committed\r\n\u00e9\u2028</sensorium>\r';
    const id = 'held-flush';
    final hold = h.hold(
      (record) => record.path == 'scratch/goal' && record.op == Op.set,
    );
    final cancel = CancelToken();
    final answer = _capture(
      h.call(
        'scratch_set',
        {'key': 'goal', 'value': value},
        id: id,
        cancel: cancel,
      ),
    );
    try {
      await _reach(hold.entered.future, answer);
      expect(
        h.scratch.containsKey('goal'),
        isFalse,
        reason: 'the public tree contains acknowledged records only',
      );
      cancel.cancel();
      hold.open();
      expect(await answer, isA<ToolOutputItem>());
      await h.drain();
      expect(h.scratch['goal'], {'value': value});
      expect(h.node(id)['status'], 'cancelled');
      expect(h.node(id)['envelope'], 'error');
      h.stored(id);
    } finally {
      hold.open();
      await answer;
    }
    final committed = h.mutations
        .where((record) => record.path == 'scratch/goal')
        .toList();
    expect(committed, hasLength(1));
    expect(committed.single.value, {'value': value});
    final sessionDir = h.writer.sessionDir;
    await h.runtime.close();
    await h.writer.close();
    final reopened = await SessionWriter.open(sessionDir);
    addTearDown(reopened.close);
    final resumed = await ToolRuntime.attach(
      reopened,
      ResultStore(sessionDir),
      workspace: sessionDir.parent,
      kehaiHome: await tempDir(),
      yolo: true,
    );
    addTearDown(resumed.close);
    expect(reopened.tree.get(SessionPath.parse('scratch/goal')), {
      'value': value,
    });
    final recovered =
        reopened.tree.get(SessionPath.parse('body/calls/${callKey(id)}'))!
            as Map<String, Object?>;
    expect(recovered['status'], anyOf('cancelled', 'failed'));
    expect(recovered['envelope'], 'error');
    final afterReopen = [
      for (final line in journalOf(sessionDir).readAsLinesSync())
        JournalRecord.parse(line),
    ];
    expect(
      afterReopen.where((record) => record.path == 'scratch/goal'),
      hasLength(1),
      reason: 'runtime recovery must not replay an uncertain effect',
    );
    final reference = recovered['result']! as Map<String, Object?>;
    resolveHandle(reopened.tree, sessionDir, reference['handle']! as String);
  });

  test('rewind restores value before overwrite and deletion', () async {
    final h = await _ScratchHarness.create();
    await h.turn(2);
    await h.seed('goal', 'original\r\n');
    await h.turn(3);
    await h.seed('goal', 'overwritten\u2028');
    expect(h.scratch['goal'], {'value': 'overwritten\u2028'});
    await h.turn(4);
    h.expectOk(await h.del('goal'));
    expect(h.scratch, isEmpty);
    await h.writer.rewind(3);
    expect(h.scratch['goal'], {'value': 'overwritten\u2028'});
    await h.writer.rewind(2);
    expect(h.scratch, {
      'goal': {'value': 'original\r\n'},
    });
    expect(h.mutations.map((record) => record.turn), [2, 3, 4]);
  });

  test('permission denied scratch calls cannot mutate state', () async {
    final prepared = await _ScratchHarness.create();
    await prepared.seed('goal', 'must survive denial');
    final h = await prepared.reattach(yolo: false);
    final before = h.scratch;
    final count = h.mutations.length;
    // Reattach with the real headless PermissionGate, not a denying stub.
    for (final input in [
      ('scratch_set', {'key': 'new', 'value': 'denied'}),
      ('scratch_set', {'key': 'goal', 'value': 'denied'}),
      ('scratch_del', {'key': 'goal'}),
    ]) {
      final item = await h.call(input.$1, input.$2);
      expect(h.node(item.callId)['envelope'], 'denied', reason: item.output);
      expect(
        h.node(item.callId)['permission'],
        containsPair('decision', 'deny'),
      );
      expect(h.scratch, before);
      expect(h.mutations, hasLength(count));
      h.stored(item.callId);
    }
  });

  test('restricted child cannot mutate its or parent scratch through excluded tool', () async {
    final parent = await _ScratchHarness.create();
    await parent.seed('goal', 'parent value');
    final parentBefore = parent.scratch;
    final parentJournal = journalOf(parent.writer.sessionDir).readAsBytesSync();
    final roster = roleRoster(
      _role(tools: ['Read']),
      toolDefinitions.map((tool) => tool.name),
    );
    final prepared = await _ScratchHarness.create(
      lineage: {
        'parent': parent.writer.tree.get(SessionPath.parse('meta/session')),
        'job': 'j-scratch-test',
      },
    );
    await prepared.seed('goal', 'existing child value');
    final childBefore = prepared.scratch;
    final childCount = prepared.mutations.length;
    final child = await prepared.reattach(roster: roster);
    expect(
      child.runtime.specs.map((spec) => spec.name),
      isNot(contains('scratch_set')),
    );
    expect(
      child.runtime.specs.map((spec) => spec.name),
      isNot(contains('scratch_del')),
    );
    for (final tool in ['scratch_set', 'scratch_del']) {
      final item = await child.call(tool, {
        'key': 'goal',
        if (tool == 'scratch_set') 'value': 'child value',
      });
      expect(item.output, contains('unknown tool $tool'));
      expect(child.node(item.callId)['envelope'], 'error');
      expect(child.node(item.callId)['status'], 'failed');
      expect(child.stored(item.callId), contains('unknown tool $tool'));
    }
    expect(child.scratch, childBefore);
    expect(child.mutations, hasLength(childCount));
    expect(parent.scratch, parentBefore);
    expect(
      journalOf(parent.writer.sessionDir).readAsBytesSync(),
      parentJournal,
    );
  });

  test('permitted child writes only its independent session scratch', () async {
    final parent = await _ScratchHarness.create();
    await parent.seed('goal', 'parent value');
    final parentBefore = parent.scratch;
    final parentJournal = journalOf(parent.writer.sessionDir).readAsBytesSync();
    final roster = roleRoster(
      _role(),
      toolDefinitions.map((tool) => tool.name),
    );
    final child = await _ScratchHarness.create(
      roster: roster,
      lineage: {
        'parent': parent.writer.tree.get(SessionPath.parse('meta/session')),
        'job': 'j-scratch-test',
      },
    );
    expect(
      child.runtime.specs.map((spec) => spec.name),
      containsAll(['scratch_set', 'scratch_del']),
    );
    await child.seed('goal', 'child\r\nvalue');
    expect(child.scratch, {
      'goal': {'value': 'child\r\nvalue'},
    });
    expect(parent.scratch, parentBefore);
    child.expectOk(await child.del('goal'));
    expect(child.scratch, isEmpty);
    expect(parent.scratch, parentBefore);
    expect(
      journalOf(parent.writer.sessionDir).readAsBytesSync(),
      parentJournal,
    );
    expect(child.writer.sessionDir.path, isNot(parent.writer.sessionDir.path));
  });
}
