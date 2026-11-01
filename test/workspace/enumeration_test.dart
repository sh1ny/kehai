import 'dart:io';

import 'package:kehai/src/workspace/inventory.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory tmp;
  late String root;
  late Directory home;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('kehai_enumeration_');
    root = p.join(tmp.path, 'repo');
    Directory(p.join(root, '.git')).createSync(recursive: true);
    home = Directory(p.join(tmp.path, 'home'))..createSync();
    void write(List<String> path, String text) {
      final file = File(p.joinAll([root, ...path]));
      file.parent.createSync(recursive: true);
      file.writeAsStringSync(text);
    }

    for (final source in ['.claude', '.agents']) {
      write([
        source,
        'skills',
        'sample',
        'SKILL.md',
      ], '---\nname: sample\ndescription: A skill\n---\nSkill body\n');
    }
    write(['.claude', 'commands', 'alpha.md'], 'Alpha command\n');
    write(['.claude', 'commands', 'blocked', 'hidden.md'], 'Hidden command\n');
    write(['.claude', 'commands', 'readable', 'beta.md'], 'Beta command\n');
    write([
      '.claude',
      'agents',
      'helper.md',
    ], '---\nname: helper\ndescription: A role\n---\nRole body\n');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  for (final failure in ['permission denied', 'directory disappeared']) {
    for (final blocked in [
      '.claude/skills',
      '.agents/skills',
      '.claude/commands',
      '.claude/commands/blocked',
      '.claude/agents',
    ]) {
      test('$blocked enumeration $failure preserves readable inventory', () {
        final overrides = _EnumerationFailure(
          p.joinAll([root, ...p.posix.split(blocked)]),
          failure,
        );
        final view = IOOverrides.runWithIOOverrides(
          () => loadWorkspace(workspace: root, kehaiHome: home),
          overrides,
        );

        expect(overrides.attempts, 1);
        final problem = view.problems.where((p) => p.path == blocked).single;
        expect(problem.reason, 'cannot be listed: $failure');
        expect(view.skills.map((s) => s.name), ['sample']);
        expect(
          view.skills.single.rootDir,
          blocked == '.claude/skills' ? '.agents/skills' : '.claude/skills',
        );
        expect(
          view.commands.map((c) => c.name),
          blocked == '.claude/commands'
              ? isEmpty
              : blocked == '.claude/commands/blocked'
              ? ['alpha', 'readable:beta']
              : ['alpha', 'blocked:hidden', 'readable:beta'],
        );
        expect(
          view.roles.map((r) => r.name),
          blocked == '.claude/agents' ? isEmpty : ['helper'],
        );
      });
    }
  }
}

// Override only enumeration: existence and containment still use the real
// filesystem. This models a failure after those checks without OS permissions
// or a timing-dependent deletion race.
final class _EnumerationFailure extends IOOverrides {
  _EnumerationFailure(this.blocked, this.failure);

  final String blocked;
  final String failure;
  int attempts = 0;

  @override
  Directory createDirectory(String path) =>
      _Directory(super.createDirectory(path), this);
}

class _Directory implements Directory {
  _Directory(this.delegate, this.overrides);

  final Directory delegate;
  final _EnumerationFailure overrides;

  @override
  String get path => delegate.path;

  @override
  String resolveSymbolicLinksSync() => delegate.resolveSymbolicLinksSync();

  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) {
    if (p.equals(path, overrides.blocked)) {
      overrides.attempts++;
      throw FileSystemException(overrides.failure, path);
    }
    return delegate.listSync(recursive: recursive, followLinks: followLinks);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
