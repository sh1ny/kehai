import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/reference_model.dart';

/// How many seeded histories the replay check runs.
final int runs =
    int.tryParse(Platform.environment['KEHAI_PROPERTY_RUNS'] ?? '') ?? 500;

/// The seed of history 0; history `i` uses `baseSeed + i`.
final int baseSeed =
    int.tryParse(Platform.environment['KEHAI_PROPERTY_SEED'] ?? '') ?? 20260101;

const _roots = ['body', 'scratch', 'checkpoints', 'jobs', 'collectors'];
const _levels = [
  ['a', 'b', 'c', 'd'],
  ['x', 'y', 'z'],
  ['a', 'b'],
];
// No structural JSON characters, so a byte flip on one is never inside a
// string value.
const _strings = ['', 'alpha', 'héllo', '日本語', 'x y', '😀 ok'];

/// A replay check that failed; names the seed and index of the history.
final class ReplayMismatch implements Exception {
  ReplayMismatch(this.seed, this.index, this.detail, this.log);

  final int seed;
  final int index;
  final String detail;

  /// The operations of the history, which depend only on the seed.
  final List<String> log;

  @override
  String toString() {
    final tail = log.length > 12 ? log.sublist(log.length - 12) : log;
    return 'replay mismatch at seed=$seed index=$index: $detail\n'
        'reproduce: KEHAI_PROPERTY_SEED=$seed KEHAI_PROPERTY_RUNS=1\n'
        'last operations:\n  ${tail.join('\n  ')}';
  }
}

final class _Fail implements Exception {
  const _Fail(this.message);
  final String message;
  @override
  String toString() => message;
}

void _check(bool condition, String message) {
  if (!condition) throw _Fail(message);
}

/// Skips the real flush, to keep hundreds of histories fast.
final class _NoFlushIo implements JournalIo {
  _NoFlushIo(this.inner);
  final JournalIo inner;

  @override
  Future<void> writeFrom(List<int> bytes) => inner.writeFrom(bytes);

  @override
  Future<void> flush() async {}

  @override
  Future<void> close() => inner.close();
}

JournalIo noFlush(JournalIo inner) => _NoFlushIo(inner);

Object? genValue(Random r, [int depth = 0]) {
  switch (r.nextInt(depth >= 2 ? 6 : 8)) {
    case 0:
      return null;
    case 1:
      return r.nextBool();
    case 2:
      return r.nextInt(2000) - 500;
    case 3:
      return (r.nextInt(400) - 200) / 8;
    case 4 || 5:
      return _strings[r.nextInt(_strings.length)];
    case 6:
      return [for (var i = r.nextInt(4); i > 0; i--) genValue(r, depth + 1)];
    default:
      return genMap(r, depth + 1);
  }
}

Map<String, Object?> genMap(Random r, [int depth = 0]) => {
  for (var i = r.nextInt(4); i > 0; i--)
    'k${1 + r.nextInt(3)}': genValue(r, depth + 1),
};

String _pick(Random r, List<String> from) => from[r.nextInt(from.length)];

/// Drives one writer and one reference model with the same random operations.
final class _Runner {
  _Runner(
    this.writer,
    this.model,
    this.random,
    this.log,
    this.stats, [
    this.tag = '',
  ]) {
    for (var i = 0; i < 5; i++) {
      _payloads.add([
        for (var n = random.nextInt(40); n > 0; n--)
          random.nextInt(8) == 0 ? 10 : 97 + random.nextInt(26),
      ]);
    }
  }

  final SessionWriter writer;
  final ReferenceModel model;
  final Random random;
  final List<String> log;
  final Map<String, int> stats;
  final String tag;
  final List<List<int>> _payloads = [];
  int forksLeft = 0;

  void _note(String kind, String text) {
    stats.update(kind, (n) => n + 1, ifAbsent: () => 1);
    log.add('$tag${log.length} $kind $text');
  }

  int _turnForRecord() =>
      random.nextInt(100) < 25 ? model.turn + 1 : model.turn;

  String _genPath() {
    final meta = random.nextInt(8) == 0;
    final base = meta ? ['meta', 'notes'] : [_pick(random, _roots)];
    final extra = random.nextInt(meta ? 3 : 4);
    return [
      ...base,
      for (var i = 0; i < extra; i++) _pick(random, _levels[i]),
    ].join('/');
  }

  List<String> _existing() => [
    for (final root in _roots) ...model.pathsUnder(root, maxDepth: 5),
    ...model
        .pathsUnder('meta', maxDepth: 5)
        .where(
          (path) => path == 'meta/notes' || path.startsWith('meta/notes/'),
        ),
  ];

  Future<void> _write(String kind, String path, Op op, Object? value) async {
    final turn = _turnForRecord();
    await writer.apply(
      JournalRecord(turn: turn, path: path, op: op, value: value),
    );
    model.apply(turn, path, op.wire, value);
    _note(kind, 't=$turn $path ${jsonEncode(value)}');
  }

  /// Runs one random operation.
  Future<void> step({bool allowFork = false}) async {
    final roll = random.nextInt(100);
    if (roll < 28) return _set();
    if (roll < 40) return _merge();
    if (roll < 50) return _del();
    if (roll < 58) return _rewind();
    if (roll < 66) return _admit(false);
    if (roll < 69) return _admit(true);
    if (roll < 75) return _settle();
    if (roll < 83) return _result();
    if (roll < 87 && allowFork && forksLeft > 0) return _fork();
    return _set();
  }

  Future<void> _set() async {
    var path = _genPath();
    if (!model.canWrite(path)) path = _pick(random, _roots);
    await _write('set', path, Op.set, genValue(random));
  }

  Future<void> _merge() async {
    final maps = _existing().where(model.isMap).toList();
    var path = maps.isNotEmpty && random.nextBool()
        ? _pick(random, maps)
        : _genPath();
    if (!model.canWrite(path) || model.exists(path) && !model.isMap(path)) {
      path = _pick(random, _roots);
      if (model.exists(path) && !model.isMap(path)) return _set();
    }
    await _write('merge', path, Op.merge, genMap(random));
  }

  Future<void> _del() async {
    final paths = _existing();
    if (paths.isEmpty) return _set();
    await _write('del', _pick(random, paths), Op.del, null);
  }

  Future<void> _rewind() async {
    if (model.turn == model.originTurn) return _set();
    final target =
        model.originTurn + random.nextInt(model.turn - model.originTurn);
    await writer.rewind(target);
    model.apply(model.turn, '', 'rewind', target);
    _note('rewind', 'to $target');
  }

  List<String> _admittedIds() {
    final requests = model.valueAt('meta/requests');
    if (requests is! Map<String, Object?>) return [];
    return [
      for (final MapEntry(:key, :value) in requests.entries)
        if (value is Map<String, Object?> && value['state'] == 'admitted') key,
    ];
  }

  Future<void> _admit(bool collide) async {
    final id = 'r${1 + random.nextInt(4)}';
    var fingerprint = 'f${1 + random.nextInt(2)}';
    final path = 'meta/requests/$id';
    final node = model.valueAt(path);
    if (node is! Map<String, Object?>) {
      final admission = await writer.admit(id, fingerprint);
      _check(admission.isNew, 'admit $id should be new');
      model.apply(model.turn, path, 'set', {
        'fingerprint': fingerprint,
        'state': 'admitted',
        'turn': model.turn,
      });
      return _note('admit', '$id $fingerprint');
    }
    if (collide) {
      fingerprint = '${node['fingerprint']}-other';
      try {
        await writer.admit(id, fingerprint);
      } on RequestCollision {
        return _note('collision', '$id $fingerprint');
      }
      throw _Fail('admit $id with another fingerprint did not collide');
    }
    fingerprint = node['fingerprint']! as String;
    final admission = await writer.admit(id, fingerprint);
    _check(!admission.isNew, 'duplicate admit $id should not be new');
    _check(
      canonicalJson(admission.node) == canonicalJson(node),
      'duplicate admit $id returned ${admission.node}, expected $node',
    );
    _note('duplicate', '$id $fingerprint');
  }

  Future<void> _settle() async {
    final ids = _admittedIds();
    if (ids.isEmpty) return _admit(false);
    final id = _pick(random, ids);
    final path = 'meta/requests/$id';
    final outcome = random.nextInt(4) == 0 ? null : genValue(random);
    final Map<String, Object?> change;
    if (random.nextBool()) {
      await writer.complete(id, outcome);
      change = {'state': 'completed', 'outcome': outcome};
    } else {
      final reason = random.nextBool() ? 'boom' : null;
      await writer.fail(id, reason: reason, outcome: outcome);
      change = {'state': 'failed', 'reason': ?reason, 'outcome': ?outcome};
    }
    model.apply(model.turn, path, 'merge', change);
    _note('settle', '$id ${jsonEncode(change)}');
  }

  Future<void> _result() async {
    final bytes = _payloads[random.nextInt(_payloads.length)];
    final stored = await ResultStore(writer.sessionDir)
        .storeResult(Stream.value(bytes));
    final descriptor = (stored as ResultComplete).descriptor;
    final path = 'results/${descriptor.handle.substring(2)}';
    final known = model.valueAt(path);
    final update = await writer.recordResult(descriptor);
    if (known != null) {
      _check(update == null, 'recording $path again should append nothing');
      return _note('result-again', path);
    }
    _check(update != null, 'recording $path should append a record');
    model.apply(model.turn, path, 'set', descriptor.toJson());
    _note('result', path);
  }

  Future<void> _fork() async {
    forksLeft--;
    final target =
        model.originTurn + random.nextInt(model.turn - model.originTurn + 1);
    final parentSession =
        (writer.tree.toJson()['meta']! as Map<String, Object?>)['session'];
    final fork = await writer.fork(target);
    _check(fork.childId != parentSession, 'the child reuses the parent id');
    _check(p.basename(fork.childDir.path) == fork.childId, 'child dir name');
    final expectedTree = model.forkTree(target, fork.childId);
    final child = ReferenceModel.fromOrigin(expectedTree, target);
    final onDisk = materialize(fork.childDir).tree;
    _check(
      onDisk.canonical() == child.canonical(),
      'fork at $target: child ${onDisk.canonical()} != ${child.canonical()}',
    );
    _note('fork', 'at $target');
    if (random.nextInt(100) < 40) {
      final opened = await SessionWriter.open(fork.childDir, decorate: noFlush);
      final runner = _Runner(opened, child, random, log, stats, '$tag  child ');
      try {
        for (var i = 3 + random.nextInt(6); i > 0; i--) {
          await runner.step();
          _check(
            opened.tree.canonical() == child.canonical(),
            'child diverged after ${log.last}',
          );
        }
        await verifyDisk(opened, child, 'child');
      } finally {
        await opened.close();
      }
    }
  }
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// Compares the live tree, two disk materializations and the model.
///
/// Closes [writer]. [corrupt] may change the model's tree before comparing.
Future<void> verifyDisk(
  SessionWriter writer,
  ReferenceModel model,
  String label, {
  Map<String, Object?> Function(Map<String, Object?> tree)? corrupt,
}) async {
  final live = writer.tree;
  final turn = writer.currentTurn;
  final first = materialize(writer.sessionDir);
  await writer.close();
  final second = materialize(writer.sessionDir);
  final expected = corrupt?.call(model.toJson()) ?? model.toJson();
  final canon = {
    'live': live.canonical(),
    'first disk': first.tree.canonical(),
    'second disk': second.tree.canonical(),
    'model': canonicalJson(expected),
  };
  for (final MapEntry(:key, :value) in canon.entries) {
    _check(
      _sameBytes(utf8.encode(value), utf8.encode(canon['model']!)),
      '$label: $key tree differs from the model\n  $key: $value\n'
      '  model: ${canon['model']}',
    );
    _check(
      equals(expected).matches(jsonDecode(value), {}),
      '$label: $key tree is not equal to the model',
    );
  }
  _check(
    first.currentTurn == turn &&
        second.currentTurn == turn &&
        model.turn == turn,
    '$label: turns differ: live $turn, disk ${first.currentTurn}/'
    '${second.currentTurn}, model ${model.turn}',
  );
  _check(first.observed, '$label: a live session should read as observed');
  _check(!second.observed, '$label: a closed session should not be observed');
}

/// Runs the history with [seed] and returns its operation log.
///
/// Throws [ReplayMismatch] naming [seed] and [index] on any disagreement.
/// [corrupt] changes the model's final tree, to prove failures are reported.
Future<List<String>> runHistory(
  int seed,
  int index, {
  Map<String, Object?> Function(int index, Map<String, Object?> tree)? corrupt,
  Map<String, int>? stats,
}) async {
  final random = Random(seed);
  final log = <String>[];
  final root = await Directory.systemTemp.createTemp('kehai_prop_');
  SessionWriter? writer;
  try {
    writer = await SessionWriter.create(root, decorate: noFlush);
    final tree = writer.tree.toJson();
    final model = ReferenceModel.fromOrigin(tree, 0);
    final runner = _Runner(writer, model, random, log, stats ?? {})
      ..forksLeft = 2;
    for (var i = 5 + random.nextInt(26); i > 0; i--) {
      await runner.step(allowFork: true);
      _check(
        writer.tree.canonical() == model.canonical(),
        'the live tree diverged from the model after ${log.last}',
      );
    }
    await verifyDisk(
      writer,
      model,
      'history',
      corrupt: corrupt == null ? null : (tree) => corrupt(index, tree),
    );
    return log;
  } on ReplayMismatch {
    rethrow;
  } on Object catch (e, stack) {
    throw ReplayMismatch(seed, index, '$e\n$stack', log);
  } finally {
    await writer?.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }
}

/// A closed generated session kept for the journal damage tests.
typedef Fixture = ({Directory dir, List<int> bytes});

Future<Fixture> buildFixture(Directory root, int seed) async {
  final random = Random(seed);
  final fixtureRoot = Directory(p.join(root.path, 'f$seed'))..createSync();
  final writer = await SessionWriter.create(fixtureRoot, decorate: noFlush);
  final model = ReferenceModel.fromOrigin(writer.tree.toJson(), 0);
  final runner = _Runner(writer, model, random, [], {});
  for (var i = 6 + random.nextInt(24); i > 0; i--) {
    await runner.step();
  }
  await writer.close();
  final bytes = File(p.join(writer.sessionDir.path, journalFileName))
      .readAsBytesSync();
  return (dir: writer.sessionDir, bytes: bytes);
}

List<Map<String, Object?>> decodeLines(List<int> bytes) => [
  for (final line in const LineSplitter().convert(utf8.decode(bytes)))
    (jsonDecode(line) as Map<Object?, Object?>).cast<String, Object?>(),
];

Directory trialDir(Directory root, List<int> journal) {
  final dir = Directory(p.join(root.path, 'trial'));
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync();
  File(p.join(dir.path, journalFileName)).writeAsBytesSync(journal);
  return dir;
}

void main() {
  test('random histories replay to identical trees', () async {
    final stats = <String, int>{};
    for (var i = 0; i < runs; i++) {
      await runHistory(baseSeed + i, i, stats: stats);
    }
    if (runs >= 50) {
      for (final kind in [
        'set',
        'merge',
        'del',
        'rewind',
        'admit',
        'duplicate',
        'collision',
        'settle',
        'result',
        'result-again',
        'fork',
      ]) {
        expect(stats[kind] ?? 0, greaterThan(0), reason: 'no $kind generated');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('failing seed is reported and reproducible', () async {
    const seed = 4242;
    ReplayMismatch? caught;
    try {
      for (var i = 0; i < 6; i++) {
        await runHistory(
          seed + i,
          i,
          corrupt: (index, tree) =>
              index == 3 ? {...tree, 'body': 'injected'} : tree,
        );
      }
    } on ReplayMismatch catch (e) {
      caught = e;
    }
    expect(caught, isNotNull, reason: 'the injected fault must be caught');
    expect(caught!.seed, seed + 3);
    expect(caught.index, 3);
    final message = caught.toString();
    expect(message, contains('seed=${seed + 3}'));
    expect(message, contains('index=3'));
    expect(message, contains('KEHAI_PROPERTY_SEED=${seed + 3}'));
    // The same seed regenerates the same operations, with or without the fault.
    expect(await runHistory(seed + 3, 0), caught.log);
    expect(await runHistory(seed + 3, 0), caught.log);
    expect(caught.log, isNotEmpty);
  });

  group('journal damage', () {
    late Directory root;
    late List<Fixture> fixtures;

    setUpAll(() async {
      root = await Directory.systemTemp.createTemp('kehai_prop_files_');
      fixtures = [
        for (var i = 0; i < 25; i++)
          await buildFixture(root, baseSeed + 9000 + i),
      ];
    });
    tearDownAll(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('torn tails recover to the last complete record', () async {
      final random = Random(baseSeed + 1);
      var recovered = 0;
      for (final fixture in fixtures) {
        for (var trial = 0; trial < 6; trial++) {
          final cut = random.nextInt(fixture.bytes.length + 1);
          final bytes = fixture.bytes.sublist(0, cut);
          final dir = trialDir(root, bytes);
          final committed = bytes.lastIndexOf(0x0A) + 1;
          final reason = 'cut at byte $cut of ${fixture.bytes.length}';
          if (committed == 0) {
            expect(
              () => materialize(dir),
              throwsA(isA<JournalCorruption>()),
              reason: reason,
            );
            await expectLater(
              SessionWriter.open(dir),
              throwsA(isA<JournalCorruption>()),
              reason: reason,
            );
            continue;
          }
          final records = decodeLines(bytes.sublist(0, committed));
          final model = ReferenceModel.replay(records);
          final disk = materialize(dir);
          expect(disk.tree.canonical(), model.canonical(), reason: reason);
          expect(disk.recordCount, records.length, reason: reason);
          expect(disk.trailingBytes, cut - committed, reason: reason);
          expect(
            File(p.join(dir.path, journalFileName)).readAsBytesSync(),
            bytes,
          );

          final interrupted = model.interruptAdmitted();
          final writer = await SessionWriter.open(dir, decorate: noFlush);
          try {
            expect(
              writer.tornTail?.bytes,
              cut > committed ? cut - committed : null,
              reason: reason,
            );
            if (cut > committed) {
              expect(
                File(writer.tornTail!.recoveryPath!).readAsBytesSync(),
                bytes.sublist(committed),
                reason: reason,
              );
            }
            expect(writer.interruptedRequests, interrupted, reason: reason);
            expect(writer.tree.canonical(), model.canonical(), reason: reason);
          } finally {
            await writer.close();
          }
          final after = File(p.join(dir.path, journalFileName))
              .readAsBytesSync();
          expect(
            after.sublist(0, committed),
            bytes.sublist(0, committed),
            reason: reason,
          );
          expect(
            materialize(dir).tree.canonical(),
            model.canonical(),
            reason: reason,
          );
          recovered++;
        }
      }
      expect(recovered, greaterThan(100));
    });

    // A flip is only guaranteed to be detected when it breaks the line's JSON:
    // the generated strings contain no `{ } [ ] : "`, so each such byte is a
    // JSON delimiter, and replacing it leaves an unparsable line. A newline
    // turned into a space glues two objects into one unparsable line. A flip
    // of an ordinary value byte can leave a valid record, so it is not
    // asserted here.
    test('interior corruption fails naming the line and offset', () async {
      final random = Random(baseSeed + 2);
      const swap = {
        0x7B: 0x28,
        0x7D: 0x29,
        0x5B: 0x28,
        0x5D: 0x29,
        0x3A: 0x3B,
        0x22: 0x27,
      };
      var corrupted = 0;
      for (final fixture in fixtures) {
        final starts = [0];
        for (var i = 0; i < fixture.bytes.length; i++) {
          if (fixture.bytes[i] == 0x0A && i + 1 < fixture.bytes.length) {
            starts.add(i + 1);
          }
        }
        if (starts.length < 2) continue;
        for (var trial = 0; trial < 6; trial++) {
          final line = random.nextInt(starts.length - 1);
          final end = fixture.bytes.indexOf(0x0A, starts[line]);
          final bytes = List<int>.of(fixture.bytes);
          if (random.nextInt(4) == 0) {
            bytes[end] = 0x20;
          } else {
            final spots = [
              for (var i = starts[line]; i < end; i++)
                if (swap.containsKey(bytes[i])) i,
            ];
            final spot = spots[random.nextInt(spots.length)];
            bytes[spot] = swap[bytes[spot]]!;
          }
          final dir = trialDir(root, bytes);
          final matcher = throwsA(
            isA<JournalCorruption>()
                .having((e) => e.line, 'line', line + 1)
                .having((e) => e.offset, 'offset', starts[line]),
          );
          expect(() => materialize(dir), matcher);
          await expectLater(SessionWriter.open(dir), matcher);
          expect(
            File(p.join(dir.path, journalFileName)).readAsBytesSync(),
            bytes,
          );
          corrupted++;
        }
      }
      expect(corrupted, greaterThan(100));
    });
  });
}
