import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/session_support.dart';

Object? at(SessionTree tree, String path) => tree.get(SessionPath.parse(path));

bool has(SessionTree tree, String path) =>
    tree.contains(SessionPath.parse(path));

Matcher rewindError(String reason, {Matcher? message}) => isA<SessionError>()
    .having((e) => e.reason, 'reason', reason)
    .having((e) => e.message, 'message', message ?? anything);

void main() {
  late Directory root;
  setUp(() async => root = await tempDir());

  group('rewind', () {
    test('rewind restores end-of-turn state and keeps meta', () async {
      final writer = await createWriter(root);
      await writer.apply(rec(1, 'body/t1/user', Op.set, 'hi'));
      await writer.apply(rec(2, 'scratch/goal', Op.set, 'two'));
      await writer.apply(rec(3, 'body/t3/user', Op.set, 'later'));
      await writer.apply(rec(3, 'scratch/goal', Op.set, 'three'));
      await writer.apply(
        rec(3, 'meta/requests/q1', Op.set, {
          'fingerprint': 'f',
          'state': 'admitted',
          'turn': 3,
        }),
      );
      final journal = journalOf(writer.sessionDir);
      final before = journal.readAsBytesSync();

      final update = await writer.apply(rec(3, '', Op.rewind, 2));

      final after = journal.readAsBytesSync();
      expect(after.sublist(0, before.length), before);
      expect(
        utf8.decode(after.sublist(before.length)),
        rec(3, '', Op.rewind, 2).encode(),
      );
      expect(update.line, '\n'.allMatches(utf8.decode(after)).length);
      final tree = writer.tree;
      expect(has(tree, 'body/t3'), isFalse);
      expect(at(tree, 'body/t1/user'), 'hi');
      expect(at(tree, 'scratch/goal'), 'two');
      expect(has(tree, 'meta/requests/q1'), isTrue);
      expect(writer.currentTurn, 2);
    });

    test('invalid rewind target is rejected', () async {
      final writer = await createWriter(root);
      await writer.apply(rec(1, 'body/a', Op.set, 1));
      await writer.apply(rec(2, 'body/b', Op.set, 2));
      await writer.apply(rec(3, 'body/c', Op.set, 3));
      final journal = journalOf(writer.sessionDir);
      final length = journal.lengthSync();

      for (final target in <Object?>[3, 4, 99, -1, 1.5, '1', null]) {
        await expectLater(
          writer.apply(rec(3, '', Op.rewind, target)),
          throwsA(rewindError('invalid rewind target', message: contains('0'))),
        );
      }
      await expectLater(
        writer.apply(rec(2, '', Op.rewind, 1)),
        throwsA(rewindError('invalid turn')),
      );
      expect(journal.lengthSync(), length);
      expect(writer.currentTurn, 3);

      // A fork's origin turn bounds the target; forks come later, so the
      // origin record of this journal is written by hand.
      final forkRoot = await tempDir();
      final dir = writeSession(
        forkRoot,
        bytesOf([
          rec(2, '', Op.set, {
            'meta': {'format': 1},
          }).encode(),
          rec(3, 'body/x', Op.set, 1).encode(),
        ]),
      );
      final forked = await SessionWriter.open(dir);
      addTearDown(forked.close);
      final forkLength = journalOf(dir).lengthSync();
      await expectLater(
        forked.apply(rec(3, '', Op.rewind, 1)),
        throwsA(rewindError('invalid rewind target', message: contains('2'))),
      );
      expect(journalOf(dir).lengthSync(), forkLength);
      await forked.apply(rec(3, '', Op.rewind, 2));
      expect(forked.currentTurn, 2);
      expect(has(forked.tree, 'body/x'), isFalse);
    });

    test('two rewinds survive replay', () async {
      final writer = await createWriter(root);
      await writer.apply(rec(1, 'body/a', Op.set, 'a1'));
      await writer.apply(rec(2, 'body/b', Op.set, 'b2'));
      await writer.apply(rec(2, 'scratch/s', Op.set, {'n': 1}));
      await writer.apply(rec(3, 'body/c', Op.set, 'c3'));
      await writer.apply(rec(3, 'scratch/s', Op.merge, {'n': 3}));
      await writer.apply(rec(3, '', Op.rewind, 1));
      await writer.apply(rec(1, 'scratch/s', Op.set, 'back'));
      await writer.apply(rec(2, 'body/d', Op.set, 'd2'));
      await writer.apply(rec(3, 'body/e', Op.set, 'e3'));
      await writer.apply(rec(3, '', Op.rewind, 2));
      await writer.apply(rec(3, 'body/f', Op.set, 'f3'));
      await writer.apply(rec(3, 'meta/note', Op.set, 'kept'));
      final expected = writer.tree.canonical();
      final dir = writer.sessionDir;
      await writer.close();

      expect(materialize(dir).tree.canonical(), expected);
      final reopened = await SessionWriter.open(dir);
      addTearDown(reopened.close);
      expect(reopened.tree.canonical(), expected);
      expect(reopened.currentTurn, 3);
      expect(has(reopened.tree, 'body/e'), isFalse);
      expect(at(reopened.tree, 'body/d'), 'd2');
      expect(at(reopened.tree, 'scratch/s'), 'back');
    });
  });
}
