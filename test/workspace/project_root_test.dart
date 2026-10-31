import 'dart:io';

import 'package:kehai/src/workspace/project_root.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('kehai_root_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('the nearest ancestor with .git or .jj is the root', () {
    final repo = Directory(p.join(tmp.path, 'repo'))..createSync();
    Directory(p.join(repo.path, '.jj')).createSync();
    final app = Directory(p.join(repo.path, 'pkg', 'app'))
      ..createSync(recursive: true);
    expect(projectRoot(app.path), File(repo.path).resolveSymbolicLinksSync());
  });

  test('a .git file counts and the workspace itself is checked', () {
    File(p.join(tmp.path, '.git')).writeAsStringSync('gitdir: x');
    expect(projectRoot(tmp.path), tmp.resolveSymbolicLinksSync());
  });

  test('without a marker the root is the workspace', () {
    final ws = Directory(p.join(tmp.path, 'a', 'b'))
      ..createSync(recursive: true);
    // The temp folder itself may sit inside a repository on a dev machine.
    final root = projectRoot(ws.path);
    expect(p.isWithin(root, ws.path) || p.equals(root, ws.path), isTrue);
  });
}
