import 'dart:convert';
import 'dart:io';

import 'package:kehai/src/workspace/agents_md.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String repo;
  late Directory home;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kehai_agents_');
    repo = p.join(tmp.path, 'repo');
    Directory(repo).createSync();
    home = Directory(p.join(tmp.path, 'home'))..createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  void write(String relative, String text) {
    final f = File(p.join(repo, relative));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text);
  }

  AgentsMd load(String workspaceRelative) => loadAgentsMd(
    root: repo,
    workspace: p.join(repo, workspaceRelative),
    kehaiHome: home,
  );

  test('applicable AGENTS.md files run from the project root to the '
      'workspace', () {
    Directory(p.join(repo, '.git')).createSync();
    write('AGENTS.md', 'root');
    write('pkg/app/AGENTS.md', 'app');
    write('pkg/app/deeper/AGENTS.md', 'below the workspace');
    Directory(p.join(repo, 'pkg')).createSync(recursive: true);
    final r = load(p.join('pkg', 'app'));
    expect(r.files.map((f) => f.path), ['AGENTS.md', 'pkg/app/AGENTS.md']);
    expect(r.files.map((f) => f.text), ['root', 'app']);
    expect(r.problems, isEmpty);
  });

  test('without .git or .jj the workspace is the root and nothing applies', () {
    final r = load('.');
    expect(r.files, isEmpty);
    expect(r.problems, isEmpty);
  });

  test('an unreadable or non-UTF-8 AGENTS.md is left out with a problem', () {
    File(p.join(repo, 'AGENTS.md')).writeAsBytesSync([0xff, 0xfe, 0x41]);
    write('sub/AGENTS.md', 'fine');
    final r = load('sub');
    expect(r.files.map((f) => f.path), ['sub/AGENTS.md']);
    expect(r.problems.map((e) => e.toString()), ['AGENTS.md: not valid UTF-8']);
  });

  test('a 50 KiB AGENTS.md is cut at a line within 32 KiB with the note', () {
    final line = '${'x' * 99}\n';
    write('AGENTS.md', line * (50 * 1024 ~/ 100 + 1));
    final size = File(p.join(repo, 'AGENTS.md')).lengthSync();
    expect(size, greaterThan(50 * 1024));
    final r = load('.');
    final f = r.files.single;
    expect(f.truncated, isTrue);
    final note =
        '[AGENTS.md truncated at 32 KiB of 50 KiB; '
        'read the file for the rest]';
    expect(f.text, endsWith(note));
    final kept = f.text.substring(0, f.text.length - note.length);
    expect(utf8.encode(kept).length, lessThanOrEqualTo(32 * 1024));
    expect(kept, endsWith('\n'));
    expect(
      kept.split('\n').where((l) => l.isNotEmpty).every((l) => l.length == 99),
      isTrue,
    );
  });

  test('only the 8 files nearest the workspace apply and the rest are '
      'named', () {
    var dir = '';
    write('AGENTS.md', 'd0');
    for (var i = 1; i < 10; i++) {
      dir = p.join(dir, 'd$i');
      write(p.join(dir, 'AGENTS.md'), 'd$i');
    }
    final r = load(dir);
    expect(r.files.length, 8);
    expect(r.files.first.path, 'd1/d2/AGENTS.md');
    expect(r.files.last.path, 'd1/d2/d3/d4/d5/d6/d7/d8/d9/AGENTS.md');
    expect(r.problems.length, 1);
    expect(
      r.problems.single.toString(),
      allOf(contains('AGENTS.md'), contains('d1/AGENTS.md')),
    );
  });
}
