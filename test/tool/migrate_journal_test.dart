import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/session_support.dart';

/// The fixture `0 -> 1` migration: moves `notes/...` to `scratch/...`.
MigrationRegistry fixtureRegistry() =>
    MigrationRegistry()..register(0, (record) {
      final path = record.path.startsWith('notes/')
          ? 'scratch/${record.path.substring('notes/'.length)}'
          : record.path;
      return [
        JournalRecord(
          turn: record.turn,
          path: path,
          op: record.op,
          value: record.value,
        ),
      ];
    });

String v0Origin({int format = 0}) => rec(0, '', Op.set, {
  'meta': {
    'format': format,
    'session': 's1',
    'lineage': {'parent': null},
  },
}).encode();

List<String> v0Lines() => [
  v0Origin(),
  rec(1, 'notes/a', Op.set, 'one').encode(),
  rec(1, 'body/m', Op.set, 'keep').encode(),
  rec(2, 'notes/b', Op.set, 'two').encode(),
];

const _transient = {'session.owner', 'session.gate', 'session.lock'};

/// Every file under [dir] except the transient ownership files.
Map<String, List<int>> snapshot(Directory dir) => {
  for (final f in dir.listSync(recursive: true).whereType<File>())
    if (!_transient.contains(p.basename(f.path)))
      p.relative(f.path, from: dir.path): f.readAsBytesSync(),
};

File fileIn(Directory dir, String name) => File(p.join(dir.path, name));

Matcher sessionErrorWith(Object text) =>
    throwsA(isA<SessionError>().having((e) => e.message, 'message', text));

void main() {
  test('migration preserves the original', () async {
    final root = await tempDir();
    final original = bytesOf(v0Lines());
    final dir = writeSession(root, original);
    final results = Directory(p.join(dir.path, 'results'))..createSync();
    fileIn(results, 'r1.bin').writeAsBytesSync([1, 2, 3]);

    final out = StringBuffer();
    final code = await runMigrateJournal(
      ['--session', dir.path],
      fixtureRegistry(),
      out: out,
    );

    expect(code, 0, reason: '$out');
    expect(fileIn(dir, 'journal.v0.jsonl').readAsBytesSync(), original);
    expect(fileIn(dir, 'journal.jsonl.migrating').existsSync(), isFalse);
    expect(fileIn(results, 'r1.bin').readAsBytesSync(), [1, 2, 3]);
    expect(out.toString(), contains('records: 4 -> 4'));

    final writer = await SessionWriter.open(dir);
    addTearDown(writer.close);
    final tree = writer.tree;
    expect(tree.get(SessionPath.parse('meta/format')), 1);
    expect(tree.get(SessionPath.parse('scratch/a')), 'one');
    expect(tree.get(SessionPath.parse('scratch/b')), 'two');
    expect(tree.get(SessionPath.parse('body/m')), 'keep');
  });

  test('outdated format with a torn tail migrates complete records', () async {
    final root = await tempDir();
    final torn = List<int>.filled(20, 0x41);
    final original = [...bytesOf(v0Lines()), ...torn];
    final dir = writeSession(root, original);

    final out = StringBuffer();
    final code = await runMigrateJournal(
      ['--session', dir.path],
      fixtureRegistry(),
      out: out,
    );

    expect(code, 0, reason: '$out');
    expect(fileIn(dir, 'journal.v0.jsonl').readAsBytesSync(), original);
    final recovered = Directory(p.join(dir.path, 'recovery'))
        .listSync()
        .whereType<File>()
        .toList();
    expect(recovered, hasLength(1));
    expect(recovered.single.readAsBytesSync(), torn);
    expect(out.toString(), contains('torn tail: 20 bytes saved to'));

    final journal = journalOf(dir).readAsBytesSync();
    expect(journal.last, 0x0A);
    expect(utf8.decode(journal).split('\n'), hasLength(5));
    final read = materialize(dir);
    expect(read.recordCount, 4);
    expect(read.trailingBytes, 0);
    expect(read.tree.get(SessionPath.parse('scratch/b')), 'two');
  });

  test('outdated open and unregistered migration change no file', () async {
    final root = await tempDir();
    final original = [...bytesOf(v0Lines()), ...List<int>.filled(20, 0x41)];
    final dir = writeSession(root, original);
    final before = snapshot(dir);

    await expectLater(
      SessionWriter.open(dir),
      sessionErrorWith(
        allOf(
          contains('format 0 requires migration'),
          contains('tool/migrate_journal.dart'),
        ),
      ),
    );
    expect(
      () => materialize(dir),
      sessionErrorWith(contains('format 0 requires migration')),
    );
    expect(snapshot(dir), before);
    expect(fileIn(dir, 'session.owner').existsSync(), isFalse);
    expect(fileIn(dir, 'session.gate').existsSync(), isFalse);

    final err = StringBuffer();
    final code = await runMigrateJournal(
      ['--session', dir.path],
      MigrationRegistry(),
      err: err,
    );
    expect(code, isNot(0));
    expect(err.toString(), contains('no migration from 0 to 1'));
    expect(snapshot(dir), before);
    expect(fileIn(dir, 'session.owner').existsSync(), isFalse);
    expect(fileIn(dir, 'session.gate').existsSync(), isFalse);
  });

  test('a newer format fails naming the format', () async {
    final root = await tempDir();
    final dir = writeSession(root, bytesOf([v0Origin(format: 9)]));
    await expectLater(
      SessionWriter.open(dir),
      sessionErrorWith(contains('format 9 is newer than this kehai')),
    );
  });

  test('check changes no file and reports the plan', () async {
    final root = await tempDir();
    final dir = writeSession(root, [
      ...bytesOf(v0Lines()),
      ...List<int>.filled(20, 0x41),
    ]);
    final before = snapshot(dir);
    final out = StringBuffer();
    final code = await runMigrateJournal(
      ['--session', dir.path, '--check'],
      fixtureRegistry(),
      out: out,
    );
    expect(code, 0);
    expect(out.toString(), allOf(contains('records: 4 -> 4'), contains('20')));
    expect(snapshot(dir), before);
  });

  test('usage errors exit 64', () async {
    final err = StringBuffer();
    expect(await runMigrateJournal([], MigrationRegistry(), err: err), 64);
    expect(err.toString(), contains('--session'));
    expect(
      await runMigrateJournal(['--bogus'], MigrationRegistry(), err: err),
      64,
    );
  });

  test(
    'interrupted migration is reported on open and completed by rerun',
    () async {
      final root = await tempDir();
      final original = bytesOf(v0Lines());
      final dir = writeSession(root, original);
      // The crash left the backup and a .migrating file, but no journal.
      journalOf(dir).renameSync(p.join(dir.path, 'journal.v0.jsonl'));
      fileIn(dir, 'journal.jsonl.migrating').writeAsStringSync('partial');

      await expectLater(
        SessionWriter.open(dir),
        sessionErrorWith(
          contains('incomplete migration; rerun migrate_journal'),
        ),
      );
      expect(journalOf(dir).existsSync(), isFalse);

      final out = StringBuffer();
      final code = await runMigrateJournal(
        ['--session', dir.path],
        fixtureRegistry(),
        out: out,
      );
      expect(code, 0, reason: '$out');
      expect(fileIn(dir, 'journal.v0.jsonl').readAsBytesSync(), original);
      expect(fileIn(dir, 'journal.jsonl.migrating').existsSync(), isFalse);
      final read = materialize(dir);
      expect(read.tree.get(SessionPath.parse('scratch/a')), 'one');
      expect(read.tree.get(SessionPath.parse('meta/format')), 1);
    },
  );
}
