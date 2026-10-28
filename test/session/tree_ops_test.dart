import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

JournalRecord rec(String path, Op op, [Object? value]) =>
    JournalRecord(turn: 1, path: path, op: op, value: value);

Matcher treeError(String reason, {String? op, String? path}) =>
    isA<SessionError>()
        .having((e) => e.reason, 'reason', reason)
        .having((e) => e.message, 'message', contains(op ?? ''))
        .having((e) => e.message, 'message', contains(path ?? ''));

void main() {
  group('SessionTree operations', () {
    test('set, merge and del update the tree', () {
      final tree = SessionTree()
        ..apply(rec('body/a', Op.set, {'x': 1}))
        ..apply(rec('body/a', Op.merge, {'y': 2}))
        ..apply(rec('body/a/x', Op.del));

      expect(tree.get(SessionPath.parse('body/a')), {'y': 2});
      expect(tree.canonical(), '{"body":{"a":{"y":2}}}');
    });

    test('set creates missing parents and replaces existing values', () {
      final tree = SessionTree()
        ..apply(rec('scratch/a/b/c', Op.set, [1]))
        ..apply(rec('scratch/a', Op.set, 'flat'));
      expect(tree.canonical(), '{"scratch":{"a":"flat"}}');
    });

    test('merge creates an absent map and overwrites given keys', () {
      final tree = SessionTree()
        ..apply(rec('jobs/j1', Op.merge, {'b': 1, 'a': 2}))
        ..apply(rec('jobs/j1', Op.merge, {'b': 3}));
      expect(tree.canonical(), '{"jobs":{"j1":{"a":2,"b":3}}}');
    });

    test('del removes a subtree', () {
      final tree = SessionTree()
        ..apply(rec('body/a/b', Op.set, 1))
        ..apply(rec('body/a', Op.del));
      expect(tree.canonical(), '{"body":{}}');
    });

    test('origin record replaces the whole tree', () {
      final tree = SessionTree()
        ..apply(rec('body/old', Op.set, 1))
        ..apply(
          rec('', Op.set, {
            'meta': {'v': 1},
          }),
          isOrigin: true,
        );
      expect(tree.canonical(), '{"meta":{"v":1}}');
    });

    test('errors name the op and path and leave the tree unchanged', () {
      final tree = SessionTree()
        ..apply(rec('body/a', Op.set, {'x': 1}))
        ..apply(rec('body/s', Op.set, 'str'));
      final before = tree.canonical();

      final failures = <(JournalRecord, Matcher)>[
        (
          rec('body/missing', Op.del),
          treeError('path not found', op: 'del', path: 'body/missing'),
        ),
        (
          rec('body/a/zz', Op.del),
          treeError('path not found', op: 'del', path: 'body/a/zz'),
        ),
        (
          rec('body/s/deeper', Op.del),
          treeError('path not found', op: 'del', path: 'body/s/deeper'),
        ),
        (
          rec('body/s', Op.merge, {'k': 1}),
          treeError('not a map', op: 'merge', path: 'body/s'),
        ),
        (
          rec('body/a', Op.merge, 5),
          treeError('not a map', op: 'merge', path: 'body/a'),
        ),
        (
          rec('body/s/child', Op.set, 1),
          treeError('not a map', op: 'set', path: 'body/s/child'),
        ),
        (
          rec('body/s/child/x', Op.merge, {'k': 1}),
          treeError('not a map', op: 'merge', path: 'body/s/child/x'),
        ),
        (
          rec('nope/x', Op.set, 1),
          treeError('invalid path', op: 'set', path: 'nope/x'),
        ),
        (rec('', Op.set, {}), treeError('invalid path', op: 'set')),
        (rec('', Op.rewind, 1), treeError('unsupported op', op: 'rewind')),
      ];
      for (final (record, matcher) in failures) {
        expect(
          () => tree.apply(record),
          throwsA(matcher),
          reason: record.encode(),
        );
        expect(tree.canonical(), before, reason: record.encode());
      }
    });

    test('origin must be a set of a map', () {
      expect(
        () => SessionTree().apply(rec('', Op.set, 1), isOrigin: true),
        throwsA(treeError('not a map', op: 'set')),
      );
    });

    test('values are deep-copied in and out', () {
      final input = <String, Object?>{
        'list': [1],
      };
      final tree = SessionTree()..apply(rec('body/a', Op.set, input));
      (input['list']! as List<Object?>).add(2);
      expect(tree.canonical(), '{"body":{"a":{"list":[1]}}}');

      final out =
          tree.get(SessionPath.parse('body/a'))! as Map<String, Object?>;
      out['x'] = 1;
      tree.toJson()['body'] = 'gone';
      expect(tree.canonical(), '{"body":{"a":{"list":[1]}}}');
    });

    test('copy is independent and canonical output sorts keys', () {
      final tree = SessionTree()
        ..apply(rec('body/z', Op.set, {'b': 1, 'a': 2}))
        ..apply(rec('body/a', Op.set, null));
      final copy = tree.copy();
      tree.apply(rec('body/z', Op.del));

      expect(copy.canonical(), '{"body":{"a":null,"z":{"a":2,"b":1}}}');
      expect(tree.canonical(), '{"body":{"a":null}}');
    });

    test('rejects non-JSON values', () {
      final tree = SessionTree();
      final badValues = <Object?>[
        Object(),
        {1: 2},
        DateTime(2020),
        double.nan,
      ];
      for (final bad in badValues) {
        expect(
          () => tree.apply(rec('body/a', Op.set, bad)),
          throwsA(treeError('invalid record')),
        );
      }
      expect(tree.canonical(), '{}');
    });
  });
}
