import 'dart:io';

import 'package:kehai/src/cli/doctor.dart';
import 'package:kehai/src/config/user_config.dart';
import 'package:kehai/src/workspace/inventory.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_openai.dart';
import '../support/login_support.dart';

void main() {
  late Directory tmp;
  late TestHome home;
  late FakeOpenAi fake;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('kehai_doctor_inv_');
    addTearDown(() => tmp.deleteSync(recursive: true));
    home = TestHome();
    fake = await FakeOpenAi.start();
    home.store.replace(loggedInRecord());
  });

  void write(String relative, String text) {
    final f = File(p.join(tmp.path, relative));
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(text);
  }

  Future<({int code, String out})> doctor({
    Workspace? workspace,
    UserConfig config = const UserConfig(),
  }) async {
    final out = StringBuffer();
    final code = await runDoctor(
      store: home.store,
      backendName: 'test',
      path: home.path,
      out: out,
      err: StringBuffer(),
      issuer: fake.issuer,
      apiBase: fake.apiBase,
      workspace: workspace,
      config: config,
    );
    return (code: code, out: out.toString());
  }

  Workspace load() =>
      loadWorkspace(workspace: tmp.path, kehaiHome: Directory(home.path));

  test('a broken SKILL.md is listed under problems and doctor\'s exit code is '
      'unchanged', () async {
    write('.git/HEAD', 'ref');
    write('AGENTS.md', 'rules\n');
    write(
      '.claude/skills/good/SKILL.md',
      '---\nname: good\ndescription: G\n---\n',
    );
    write('.claude/skills/bad/SKILL.md', '---\nname: [oops\n---\n');
    write('.claude/commands/opsx/go.md', 'go\n');
    write(
      '.claude/agents/impl.md',
      '---\nname: impl\ndescription: I\nmodel: sonnet\n'
          'tools: Read, Bash, Nope\n---\nbody\n',
    );
    write(
      '.claude/agents/rev.md',
      '---\nname: rev\ndescription: R\nmodel: haiku\n---\nbody\n',
    );
    write(
      '.claude/agents/inh.md',
      '---\nname: inh\ndescription: R\nmodel: inherit\n---\nbody\n',
    );

    final plain = await doctor();
    final listed = await doctor(
      workspace: load(),
      config: const UserConfig(agentModels: {'sonnet': 'gpt-6.1-mini'}),
    );

    expect(plain.code, 0);
    expect(listed.code, plain.code);
    final out = listed.out;
    expect(out, contains('root: ${load().root}'));
    expect(out, contains('AGENTS.md'));
    expect(out, contains('good  .claude/skills'));
    expect(out, contains('/opsx:go'));
    expect(out, contains('impl  model sonnet -> gpt-6.1-mini'));
    expect(out, contains('tools read, bash, job, read_more, search_result'));
    expect(
      out,
      contains('rev  model haiku is not configured; uses the parent model'),
    );
    expect(out, contains('inh  model inherit'));
    expect(out, contains('problems: '));
    expect(out, contains('.claude/skills/bad/SKILL.md: '));
    expect(out, contains('tool Nope is unmapped'));
    expect(RegExp(r'bad/SKILL.md: .*line \d+').hasMatch(out), isTrue);
  });
}
