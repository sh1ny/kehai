import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:kehai/src/workspace/inventory.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/loop_support.dart';
import '../support/session_support.dart';

final class _Rig {
  _Rig(this.ws, this.home, this.writer, this.runtime);

  final Directory ws;
  final Directory home;
  final SessionWriter writer;
  final ToolRuntime runtime;

  void skill(String name, String body, {String extra = ''}) {
    final file = File(p.join(ws.path, '.claude', 'skills', name, 'SKILL.md'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '---\nname: $name\ndescription: About $name\n$extra---\n$body',
    );
  }

  void command(String name, String body) {
    final file = File(
      p.join(ws.path, '.claude', 'commands', '${name.replaceAll(':', '/')}.md'),
    );
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(body);
  }

  Workspace load() => loadWorkspace(workspace: ws.path, kehaiHome: home);

  /// Records a completed step holding call `c1` with [used] tokens in use of
  /// [window] (or of an unknown window).
  Future<void> step({required int used, int? window}) => seedStep(
    writer,
    1,
    exchange: 1,
    output: [callEntry('c1', 'skill')],
    context: {'used': used, 'window': ?window, 'estimated': true},
  );

  Future<ToolOutputItem> load1(String name, {String? args}) => runtime.run(
    ToolCall(
      callId: 'c1',
      name: 'skill',
      argumentsJson: jsonEncode({'name': name, 'args': ?args}),
    ),
  );

  Map<String, Object?> node() =>
      writer.tree.get(SessionPath.parse('body/calls/${callKey('c1')}'))!
          as Map<String, Object?>;
}

Future<_Rig> _rig() async {
  final root = await tempDir();
  final ws = Directory(p.join(root.path, 'ws'))..createSync();
  Directory(p.join(ws.path, '.git')).createSync();
  final home = Directory(p.join(root.path, 'home'))..createSync();
  final writer = await createWriter(Directory(p.join(root.path, 's')));
  final runtime = await ToolRuntime.attach(
    writer,
    ResultStore(writer.sessionDir),
    workspace: ws,
    kehaiHome: home,
    gate: const AllowAllStage(),
  );
  addTearDown(runtime.close);
  return _Rig(ws, home, writer, runtime);
}

String _lines(int count) {
  final body = [for (var i = 1; i <= count; i++) 'line $i of the skill body'];
  return '${body.join('\n')}\n';
}

void main() {
  test("disable-model-invocation refuses the model's load", () async {
    final rig = await _rig();
    rig.skill('secret', 'Hidden\n', extra: 'disable-model-invocation: true\n');

    final item = await rig.load1('secret');

    expect(item.output, startsWith('[skill error]'));
    expect(item.output, contains('skill secret cannot be loaded by the model'));
    expect(item.output, isNot(contains('Hidden')));
    expect(rig.node()['envelope'], 'error');
  });

  test(
    'skill result has the base directory line, body and ARGUMENTS line',
    () async {
      final rig = await _rig();
      rig.skill(
        'specwright-roadmap',
        'Run \${CLAUDE_SKILL_DIR}/scripts/go.sh and \$HOME\n',
      );
      final dir = rig
          .load()
          .skill('specwright-roadmap')!
          .directory
          .replaceAll(r'\', '/');

      final item = await rig.load1('specwright-roadmap', args: 'next');

      expect(item.output, startsWith('[skill ok]'));
      expect(
        item.output,
        contains(
          'Base directory for this skill: $dir\n\n'
          'Run $dir/scripts/go.sh and \$HOME\n\nARGUMENTS: next',
        ),
      );
      expect(item.output, endsWith('ARGUMENTS: next'));
      expect(rig.node()['envelope'], 'ok');
    },
  );

  test('skill resolves opsx:propose as a command', () async {
    final rig = await _rig();
    rig.command(
      'opsx:propose',
      '---\nname: "OPSX: Propose"\nallowed-tools: Bash(openspec:*)\n---\n'
          'Propose \$ARGUMENTS now\n',
    );

    final item = await rig.load1('opsx:propose', args: 'add-thing');

    expect(item.output, contains('Propose add-thing now'));
    expect(item.output, isNot(contains('Base directory')));
    expect(item.output, isNot(contains('ARGUMENTS:')));
    expect(item.output, isNot(contains('allowed-tools')));
    expect(rig.node()['envelope'], 'ok');
  });

  test('an unknown name lists up to five close names', () async {
    final rig = await _rig();
    for (final name in [
      'spec-a',
      'spec-b',
      'spec-c',
      'spec-d',
      'spec-e',
      'spec-f',
      'zzzzzzzzzzzz',
    ]) {
      rig.skill(name, 'x\n');
    }
    rig.skill('spec-hidden', 'x\n', extra: 'disable-model-invocation: true\n');

    final item = await rig.load1('spec-x');

    expect(item.output, startsWith('[skill error]'));
    expect(item.output, contains('unknown skill or command spec-x'));
    final listed = item.output
        .split('\n')
        .first
        .split('closest: ')
        .last
        .split(', ');
    expect(listed, hasLength(5));
    expect(listed, everyElement(startsWith('spec-')));
    expect(listed, isNot(contains('spec-hidden')));
    expect(rig.node()['envelope'], 'error');
  });

  test('a 55 KiB skill is delivered with no truncation line', () async {
    final rig = await _rig();
    final body = _lines(2000);
    rig.skill('big', body);
    expect(body.length, greaterThan(50 * 1024));
    await rig.step(used: 5000, window: 1000000);

    final item = await rig.load1('big');

    expect(item.output, startsWith('[skill ok]'));
    for (final n in [1, 777]) {
      expect(item.output, contains('line $n of the skill body\n'));
    }
    expect(item.output, isNot(contains('truncated')));
    expect(item.output, isNot(contains('read_more')));
    expect(RegExp('line \\d+ of the').allMatches(item.output), hasLength(2000));
  });

  test('a 300 KiB SKILL.md is refused with the read hint', () async {
    final rig = await _rig();
    const header = '---\nname: huge\ndescription: About huge\n---\n';
    rig.skill('huge', 'x' * (300 * 1024 - header.length));
    await rig.step(used: 5000, window: 1000000);

    final item = await rig.load1('huge');

    expect(item.output, startsWith('[skill error]'));
    expect(
      item.output,
      contains(
        'skill file is 300 KiB, over the 256 KiB limit; read '
        '.claude/skills/huge/SKILL.md instead',
      ),
    );
    expect(item.output, isNot(contains('xxxxxxxx')));
    expect(rig.node()['envelope'], 'error');
  });

  test('a skill over the remaining capacity settles error uncut', () async {
    final rig = await _rig();
    rig.skill('mid', _lines(60));
    await rig.step(used: 900, window: 1000);

    final item = await rig.load1('mid');

    expect(item.output, startsWith('[skill error]'));
    expect(
      item.output,
      matches(RegExp(r'notrunc result of \d+ tokens exceeds capacity 100')),
    );
    expect(item.output, isNot(contains('line 1 of the skill body')));
    expect(rig.node()['envelope'], 'error');
  });

  test('with an unknown window a skill is delivered whole and the request is '
      'sent', () async {
    final rig = await _rig();
    rig.skill('big', _lines(2000));
    await rig.step(used: 999999999);

    final item = await rig.load1('big');

    expect(item.output, startsWith('[skill ok]'));
    expect(item.output, endsWith('line 2000 of the skill body'));
    expect(item.output, isNot(contains('truncated')));
    expect(rig.node()['envelope'], 'ok');
  });
}
