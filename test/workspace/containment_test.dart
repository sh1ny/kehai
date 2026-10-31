import 'dart:io';

import 'package:kehai/src/workspace/containment.dart';
import 'package:kehai/src/workspace/skills.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'link_support.dart';

void main() {
  late Directory tmp;
  late String root;
  late String outside;
  late Directory home;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kehai_contain_');
    root = p.join(tmp.path, 'repo');
    outside = p.join(tmp.path, 'notes');
    Directory(root).createSync();
    Directory(outside).createSync();
    home = Directory(p.join(tmp.path, 'home'))..createSync();
    Directory(p.join(root, '.git')).createSync();
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('a regular file inside the root is read', () {
    File(p.join(root, 'AGENTS.md')).writeAsStringSync('hello');
    final r = readContained(
      root: root,
      path: p.join(root, 'AGENTS.md'),
      kehaiHome: home,
    );
    expect(r.problem, isNull);
    expect(r.text, 'hello');
    expect(r.size, 5);
  });

  test('a link or junction outside the root is not read and records '
      'outside the project root', () {
    File(p.join(outside, 'private.md')).writeAsStringSync('SECRET');
    linkDirectory(p.join(root, 'ext'), outside);
    final r = readContained(
      root: root,
      path: p.join(root, 'ext', 'private.md'),
      kehaiHome: home,
    );
    expect(r.text, isNull);
    expect(r.problem!.toString(), 'ext/private.md: outside the project root');
  });

  test('a link to a Kehai credential file is refused as credential file', () {
    File(p.join(home.path, 'auth.json')).writeAsStringSync('TOKEN');
    linkDirectory(p.join(root, 'homelink'), home.path);
    final r = readContained(
      root: root,
      path: p.join(root, 'homelink', 'auth.json'),
      kehaiHome: home,
    );
    expect(r.text, isNull);
    expect(r.problem!.reason, 'credential file');
  });

  test('a junctioned skill folder outside the root is not a skill', () {
    final skill = Directory(p.join(outside, 'x'))..createSync();
    File(p.join(skill.path, 'SKILL.md'))
        .writeAsStringSync('---\nname: x\ndescription: d\n---\nbody\n');
    Directory(p.join(root, '.claude', 'skills')).createSync(recursive: true);
    linkDirectory(p.join(root, '.claude', 'skills', 'x'), skill.path);
    final found = discoverSkills(root: root, kehaiHome: home);
    expect(found.skills, isEmpty);
    expect(found.problems.map((e) => e.toString()), [
      '.claude/skills/x: outside the project root',
    ]);
  });
}
