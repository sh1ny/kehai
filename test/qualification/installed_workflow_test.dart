import 'dart:io';

import 'package:kehai/src/cli/doctor.dart';
import 'package:kehai/src/workspace/frontmatter.dart';
import 'package:kehai/src/workspace/inventory.dart';
import 'package:kehai/src/workspace/load.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_openai.dart';
import '../support/login_support.dart';

// URI segments avoid retaining the backslash in a Windows drive root.
String _shown(String path) => p.isAbsolute(path) && Platform.isWindows
    ? p.toUri(path).pathSegments.join('/')
    : p.posix.joinAll(p.split(path));

void main() {
  test('doctor lists every installed command, skill and role with only shadowed problems', () async {
    final root = Directory.current;
    // A linked worktree has a .git file rather than a .git directory.
    expect(
      FileSystemEntity.typeSync(p.join(root.path, '.git')),
      isNot(FileSystemEntityType.notFound),
    );
    final home = TestHome();
    final fake = await FakeOpenAi.start();
    home.store.replace(loggedInRecord());
    final view = loadWorkspace(
      workspace: root.path,
      kehaiHome: Directory(home.path),
    );
    expect(p.equals(view.root, root.resolveSymbolicLinksSync()), isTrue);

    // Derive the expected catalog from disk, not from the loader under test.
    final skillFiles = <String, File>{};
    final duplicates = <String>[];
    for (final owner in ['.claude', '.agents']) {
      final base = Directory(p.join(root.path, owner, 'skills'));
      expect(base.existsSync(), isTrue);
      for (final dir in base.listSync().whereType<Directory>()) {
        final file = File(p.join(dir.path, 'SKILL.md'));
        if (!file.existsSync()) continue;
        final name = p.basename(dir.path);
        if (skillFiles.containsKey(name)) {
          duplicates.add(_shown(p.relative(file.path, from: root.path)));
        } else {
          skillFiles[name] = file;
        }
      }
    }
    final skillNames = skillFiles.keys.toList()..sort();
    expect(skillNames.where((n) => n.startsWith('specwright-')), isNotEmpty);
    expect(skillNames.where((n) => n.startsWith('openspec-')), isNotEmpty);
    expect(view.skills.map((s) => s.name), skillNames);
    expect(
      view.shadowedSkills.map(
        (s) => _shown(p.relative(s.file, from: root.path)),
      ),
      unorderedEquals(duplicates),
    );
    expect(duplicates, isNotEmpty);
    expect(
      view.problems.map((problem) => problem.path),
      unorderedEquals(duplicates),
    );
    for (final problem in view.problems) {
      final name = p.posix.basename(p.posix.dirname(problem.path));
      expect(problem.reason, 'shadowed by .claude/skills/$name/SKILL.md');
    }

    const arguments = 'qualification change with spaces';
    for (final skill in view.skills) {
      expect(p.equals(skill.file, skillFiles[skill.name]!.path), isTrue);
      final body = parseFrontmatter(skillFiles[skill.name]!.readAsStringSync())
          .body;
      final base = _shown(skill.directory);
      var expected = body.replaceAllMapped(
        RegExp(r'\$\{CLAUDE_SKILL_DIR\}|\$ARGUMENTS'),
        (match) => match[0] == r'$ARGUMENTS' ? arguments : base,
      );
      if (!body.contains(r'$ARGUMENTS')) {
        expected +=
            '${expected.endsWith('\n') ? '\n' : '\n\n'}ARGUMENTS: $arguments';
      }
      final loaded = loadFile(
        root: view.root,
        path: skill.file,
        kehaiHome: Directory(home.path),
        name: skill.name,
        kind: 'skill',
        arguments: arguments,
        baseDir: skill.directory,
      );
      expect(
        loaded.text,
        'Base directory for this skill: $base\n\n$expected',
        reason: skill.name,
      );
      expect(loaded.source, _shown(p.relative(skill.file, from: view.root)));
    }

    final commandBase = Directory(p.join(root.path, '.claude', 'commands'));
    final commands = <String, File>{
      for (final file
          in commandBase.listSync(recursive: true).whereType<File>())
        if (p.extension(file.path) == '.md')
          p
                  .split(
                    p.withoutExtension(
                      p.relative(file.path, from: commandBase.path),
                    ),
                  )
                  .join(':'):
              file,
    };
    final names = commands.keys.toList()..sort();
    expect(names.where((n) => n.startsWith('opsx:')), isNotEmpty);
    expect(view.commands.map((c) => c.name), names);
    for (final command in view.commands) {
      final body = parseFrontmatter(commands[command.name]!.readAsStringSync())
          .body;
      final loaded = loadFile(
        root: view.root,
        path: command.path,
        kehaiHome: Directory(home.path),
        name: command.name,
        kind: 'command',
        arguments: arguments,
      );
      var expected = body.replaceAll(r'$ARGUMENTS', arguments);
      if (!body.contains(r'$ARGUMENTS')) {
        expected +=
            '${expected.endsWith('\n') ? '\n' : '\n\n'}ARGUMENTS: $arguments';
      }
      expect(loaded.text, expected, reason: command.name);
      expect(view.slashCommands.any((c) => c.name == command.name), isTrue);
    }

    final roles =
        Directory(p.join(root.path, '.claude', 'agents'))
            .listSync()
            .whereType<File>()
            .where((f) => p.extension(f.path) == '.md')
            .map((f) => p.basenameWithoutExtension(f.path))
            .toList()
          ..sort();
    expect(
      roles,
      [
        'specwright-implementer',
        'specwright-implementer-light',
        'specwright-reviewer',
      ]..sort(),
    );
    expect(view.roles.map((r) => r.name), roles);
    for (final role in view.roles) {
      expect(view.role(role.name), same(role));
    }
    final slashNames = view.slashCommands.map((c) => c.name).toList();
    expect(slashNames, orderedEquals(slashNames.toList()..sort()));

    final out = StringBuffer();
    final err = StringBuffer();
    expect(
      await runDoctor(
        store: home.store,
        backendName: 'test',
        path: home.path,
        out: out,
        err: err,
        issuer: fake.issuer,
        apiBase: fake.apiBase,
        workspace: view,
      ),
      0,
    );
    expect(err.toString(), isEmpty);
    final report = out.toString();
    for (final skill in view.skills) {
      expect(report, contains('  ${skill.name}  ${skill.rootDir}\n'));
    }
    for (final name in slashNames) {
      expect(report, contains('  /$name\n'));
    }
    for (final name in roles) {
      expect(report, contains('  $name  model '));
    }
    expect(report, contains('problems: ${duplicates.length}\n'));
    for (final problem in view.problems) {
      expect(report, contains('  ${problem.path}: ${problem.reason}\n'));
    }
  });
}
