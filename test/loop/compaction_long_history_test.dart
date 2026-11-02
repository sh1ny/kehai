import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/loop_support.dart';
import '../support/session_support.dart';
import 'compaction_test.dart' as support;

RequestBuilder _builder(SessionWriter w) => RequestBuilder(
  sessionDir: w.sessionDir,
  model: 'gpt-5.5',
  workspaceName: 'long-history',
  tools: const [],
  clock: () => DateTime(2026, 11, 2, 12),
  estimateRequest: (r) => r.items.fold(0, (n, i) => n + estimateItem(i)),
);

Object _projection(BuiltRequest b) => [
  b.boundary,
  b.used,
  b.quality,
  for (final item in b.request.items)
    switch (item) {
      OpaqueCompactionItem(:final json) => json,
      AssistantMessage(:final text) => ['assistant', text],
      UserMessage(:final text) => ['user', text],
      ToolCallItem(:final callId, :final name, :final argumentsJson) => [
        'call',
        callId,
        name,
        argumentsJson,
      ],
      ToolOutputItem(:final callId, :final output) => [
        'output',
        callId,
        output,
      ],
      _ => throw StateError('unexpected fixture item: $item'),
    },
];

// Only result resolution and stored-envelope reads are expected during builds.
// Counting file construction catches even attempted discarded-prefix reads.
class _CountedFile implements File {
  _CountedFile(this.inner, this.onRead);
  final File inner;
  final void Function() onRead;
  @override
  bool existsSync() => inner.existsSync();
  @override
  int lengthSync() => inner.lengthSync();
  @override
  String readAsStringSync({Encoding encoding = utf8}) {
    onRead();
    return inner.readAsStringSync(encoding: encoding);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected file operation: ${invocation.memberName}');
}

void main() {
  test('long history: repeated boundaries preserve replay, handles and recovery', () async {
    final w = await createWriter(await tempDir());
    final store = ResultStore(w.sessionDir);
    await seedExchange(w, 1, 'deterministic long change');
    const scratch = 'agent owned\r\n✓\n  keep whitespace\n';
    const correlation = {
      'request': 'r1',
      'child': 'child-1',
      'outcome': 'done',
    };
    await w.apply(rec(1, 'scratch', Op.set, {'text': scratch}));
    await w.apply(rec(1, 'meta/test-correlation', Op.set, correlation));
    final handles = <String, String>{};
    for (var turn = 1; turn <= 20; turn++) {
      final id = 'result-$turn';
      final envelope = '[bash ok] result $turn\r\n✓\n';
      await support.step(
        w,
        turn,
        [
          callEntry(id, 'bash'),
          support.cut('boundary-$turn'),
          textEntry('tail-$turn'),
        ],
        usage: {'input': 120000, 'output': 6000},
      );
      await seedCall(w, store, callId: id, modelText: envelope);
      final node =
          w.tree.get(SessionPath.parse('body/calls/${callKey(id)}')) as Map;
      handles[(node['model'] as Map)['handle'] as String] = envelope;
    }
    // A committed response dies before runtime admission on both sides of cut.
    await support.step(w, 21, [
      callEntry('cancel-pre', 'bash'),
      support.cut('final'),
      callEntry('cancel-post', 'bash'),
    ]);
    expect((await JobRecovery(w, store).resume()).calls, 2);
    expect((await JobRecovery(w, store).resume()).calls, 0);
    final expected = await _builder(w).build(w.tree, turn: 22);
    expect(expected.used, isNull);
    expect(expected.quality, 'unknown compacted usage');
    expect(expected.window, isNull);
    final items = support.content(expected);
    expect(items.whereType<ToolCallItem>().single.callId, 'cancel-post');
    expect(
      items.whereType<ToolOutputItem>().single.output,
      contains('execution not recorded; not replayed'),
    );
    expect(
      items.whereType<UserMessage>().single.text,
      contains('execution not recorded; not replayed'),
    );
    final calls = jsonEncode(w.tree.get(SessionPath.parse('body/calls')));
    final fork = await w.fork(w.currentTurn);
    final child = await SessionWriter.open(fork.childDir);
    addTearDown(child.close);
    final dir = w.sessionDir;
    await w.close();
    final resumed = await SessionWriter.open(dir);
    addTearDown(resumed.close);
    for (final session in [child, resumed]) {
      expect(
        (await JobRecovery(
          session,
          ResultStore(session.sessionDir),
        ).resume()).calls,
        0,
      );
      expect(
        _projection(await _builder(session).build(session.tree, turn: 22)),
        _projection(expected),
      );
      expect(
        jsonEncode(session.tree.get(SessionPath.parse('body/calls'))),
        calls,
      );
      expect(session.tree.get(SessionPath.parse('scratch')), {'text': scratch});
      expect(
        session.tree.get(SessionPath.parse('meta/test-correlation')),
        correlation,
      );
      for (final entry in handles.entries) {
        expect(
          resolveHandle(
            session.tree,
            session.sessionDir,
            entry.key,
          ).file.readAsStringSync(),
          entry.value,
        );
      }
    }
    // Rewind removes final boundary and cancellations, preserving the old result.
    await resumed.rewind(20);
    expect((await JobRecovery(resumed, ResultStore(dir)).resume()).calls, 0);
    final rewound = await _builder(resumed).build(resumed.tree, turn: 21);
    expect(rewound.boundary, 's-00000020:1:boundary-20');
    expect(
      support.content(rewound).whereType<UserMessage>().single.text,
      endsWith('[bash ok] result 20\r\n✓\n'),
    );
    expect(
      resumed.tree.get(
        SessionPath.parse('body/calls/${callKey('cancel-post')}'),
      ),
      isNull,
    );
    expect(
      (await _builder(child).build(child.tree, turn: 22)).boundary,
      expected.boundary,
    );
  });

  test('long history: 10x and 100x metadata with constant result composition', () async {
    final w = await createWriter(await tempDir());
    final store = ResultStore(w.sessionDir);
    await seedExchange(w, 1, 'prefix');
    await seedCall(w, store, callId: 'archived', modelText: 'discarded result');
    await seedCall(w, store, callId: 'retained', modelText: 'retained result');
    final files = <String, File>{};
    final labels = <String, String>{};
    for (final id in ['archived', 'retained']) {
      final node =
          w.tree.get(SessionPath.parse('body/calls/${callKey(id)}')) as Map;
      final file = resolveHandle(
        w.tree,
        w.sessionDir,
        (node['model'] as Map)['handle'] as String,
      ).file;
      files[file.path] = file;
      labels[file.path] = id;
    }
    final seed = w.tree.toJson();
    for (final count in [10, 100, 1000]) {
      final tree = SessionTree.fromJson(seed);
      for (var turn = 1; turn <= count; turn++) {
        tree.apply(
          rec(turn, 'body/steps/s-${pad8(turn)}', Op.set, {
            'exchange': 'x-00000001',
            'model': 'gpt-5.5',
            'state': 'completed',
            'lineage': support.lineage(),
            'output': [callEntry('archived', 'bash'), support.cut('old-$turn')],
          }),
        );
      }
      tree.apply(
        rec(count + 1, 'body/steps/s-${pad8(count + 1)}', Op.set, {
          'exchange': 'x-00000001',
          'model': 'gpt-5.5',
          'state': 'completed',
          'lineage': support.lineage(),
          'output': [support.cut('latest'), callEntry('retained', 'bash')],
        }),
      );
      // Logical metadata volume, not an instrumented production loop counter.
      final steps = tree.get(SessionPath.parse('body/steps')) as Map;
      final entries = steps.values.fold<int>(
        0,
        (n, s) => n + ((s as Map)['output'] as List).length,
      );
      expect(steps.length, count + 1);
      expect(entries, 2 * (count + 1));
      var archivedAttempts = 0;
      var retainedAttempts = 0;
      var reads = 0;
      final watch = Stopwatch()..start();
      await IOOverrides.runZoned(
        () async {
          for (var replay = 0; replay < 3; replay++) {
            final b = await _builder(w).build(tree, turn: count + 2);
            expect(b.boundary, 's-${pad8(count + 1)}:0:latest');
            expect(
              support.content(b).whereType<ToolOutputItem>().single.output,
              'retained result',
            );
          }
        },
        createFile: (path) {
          if (labels[path] == 'archived') archivedAttempts++;
          if (labels[path] == 'retained') retainedAttempts++;
          return _CountedFile(
            files[path] ?? (throw StateError('unexpected file: $path')),
            () => reads++,
          );
        },
      );
      watch.stop();
      expect(archivedAttempts, 0);
      expect(retainedAttempts, 3);
      expect(reads, 3);
      print(
        'prefix=$count metadataSteps=${steps.length} outputEntries=$entries builds=3 archivedFileAttempts=$archivedAttempts retainedReads=$reads elapsedUs=${watch.elapsedMicroseconds}',
      );
    }
  });
}
