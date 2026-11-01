import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:kehai/kehai.dart';
import 'package:kehai/src/workspace/inventory.dart';
import 'package:kehai/src/workspace/substitution.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/fake_provider.dart';
import '../support/loop_support.dart';
import '../support/session_support.dart';

const _endTurn = Completed(StopReason.endTurn);

final class _Rig {
  _Rig(this.writer, this.driver, this.ws, this.home, this.provider);

  final SessionWriter writer;
  final ExchangeDriver driver;
  final Directory ws;
  final Directory home;
  final FakeProvider provider;

  Object? at(String path) => writer.tree.get(SessionPath.parse(path));

  Map<String, Object?> exchange(int turn) =>
      at('body/exchanges/x-${pad8(turn)}')! as Map<String, Object?>;

  void skill(String name, String body, {String extra = ''}) {
    final file = File(p.join(ws.path, '.claude', 'skills', name, 'SKILL.md'));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
      '---\nname: $name\ndescription: About $name\n$extra---\n$body',
    );
  }

  File command(String name, String text) {
    final file = File(
      p.join(ws.path, '.claude', 'commands', '${name.replaceAll(':', '/')}.md'),
    );
    file.parent.createSync(recursive: true);
    return file..writeAsStringSync(text);
  }

  Future<SubmitOutcome> submit(String text, {String id = 'r1'}) =>
      driver.submit(id: id, text: text, turn: writer.currentTurn);

  /// Submits [text] and waits for the exchange to end.
  Future<ExchangeResult> run(String text, {String id = 'r1'}) async =>
      (await submit(text, id: id) as SubmitAdmitted).done;
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
  final provider = FakeProvider((request, cancel, call) {
    return Stream.fromIterable([const TextDelta('ok'), _endTurn]);
  });
  final driver = ExchangeDriver(
    writer: writer,
    runtime: runtime,
    provider: provider,
    model: 'gpt-5.5',
    clock: () => DateTime(2026, 10, 30, 9, 5),
  );
  return _Rig(writer, driver, ws, home, provider);
}

void main() {
  test('/specwright-roadmap next expands to the skill load text', () async {
    final rig = await _rig();
    rig.skill(
      'specwright-roadmap',
      r'Plan with ${CLAUDE_SKILL_DIR}/scripts and $HOME.'
          '\n',
    );
    final dir = loadWorkspace(
      workspace: rig.ws.path,
      kehaiHome: rig.home,
    ).skill('specwright-roadmap')!.directory;

    final result = await rig.run('/specwright-roadmap next');

    expect(result.state, 'done');
    final expected = renderLoaded(
      r'Plan with ${CLAUDE_SKILL_DIR}/scripts and $HOME.'
      '\n',
      baseDir: dir,
      arguments: 'next',
    );
    expect(rig.exchange(1)['prompt'], expected);
    expect(expected, startsWith('Base directory for this skill: '));
    expect(expected, endsWith('ARGUMENTS: next'));
    final sent = rig.provider.requests.single.items.first;
    expect(sent, isA<UserMessage>());
    expect((sent as UserMessage).text, expected);
  });

  test(
    'user-invocable false refuses the submit with nothing admitted',
    () async {
      final rig = await _rig();
      rig.skill(
        'specwright-commit',
        'Commit.\n',
        extra: 'user-invocable: false\n',
      );
      final turn = rig.writer.currentTurn;

      final outcome = await rig.submit('/specwright-commit');

      expect(outcome, isA<SubmitRefused>());
      expect(
        (outcome as SubmitRefused).message,
        'specwright-commit is not a user command',
      );
      expect(rig.at('meta/requests/r1'), isNull);
      expect(rig.at('body/exchanges'), isNull);
      expect(rig.writer.currentTurn, turn);
      expect(rig.driver.busy, isFalse);
      expect(rig.provider.requests, isEmpty);
      // The driver is free for the next prompt.
      expect((await rig.run('plain', id: 'r2')).state, 'done');
    },
  );

  test('an unknown name is refused with the // hint', () async {
    final rig = await _rig();

    final outcome = await rig.submit('/usr/bin/env');

    expect(
      (outcome as SubmitRefused).message,
      'unknown command /usr/bin/env; start with // to send it as text',
    );
    expect(rig.at('meta/requests/r1'), isNull);
    expect(rig.at('body/exchanges'), isNull);
  });

  test('/opsx:propose add-dark-mode becomes the body plus ARGUMENTS', () async {
    final rig = await _rig();
    rig.command(
      'opsx:propose',
      '---\nname: "OPSX: Propose"\n---\nPropose a change.\n',
    );

    await rig.run('/opsx:propose   add-dark-mode  ');

    expect(
      rig.exchange(1)['prompt'],
      'Propose a change.\n\nARGUMENTS: add-dark-mode',
    );
  });

  test('the arguments run over the following lines', () async {
    final rig = await _rig();
    rig.command('opsx:propose', 'Body\n');

    await rig.run('/opsx:propose first \nsecond\nthird');

    expect(
      (rig.exchange(1)['command']! as Map<String, Object?>)['args'],
      'first\nsecond\nthird',
    );
    expect(
      rig.exchange(1)['prompt'],
      endsWith('ARGUMENTS: first\nsecond\nthird'),
    );
  });

  test('a leading // sends the text with one slash removed', () async {
    final rig = await _rig();

    await rig.run('//usr/bin/env is missing');

    expect(rig.exchange(1)['prompt'], '/usr/bin/env is missing');
    expect(rig.exchange(1).containsKey('command'), isFalse);
    final sent = rig.provider.requests.single.items.first as UserMessage;
    expect(sent.text, '/usr/bin/env is missing');
  });

  test('the exchange records command name, args, source and digest', () async {
    final rig = await _rig();
    rig.command('opsx:apply', 'Apply it.\n');

    await rig.run('/opsx:apply');

    final prompt = rig.exchange(1)['prompt']! as String;
    expect(prompt, 'Apply it.\n');
    expect(rig.exchange(1)['command'], {
      'name': 'opsx:apply',
      'args': '',
      'source': '.claude/commands/opsx/apply.md',
      'sha256': sha256.convert(utf8.encode(prompt)).toString(),
    });
  });

  test('a duplicate submit after the file changed reports the first '
      'expansion', () async {
    final rig = await _rig();
    final file = rig.command('opsx:apply', 'First text.\n');
    await rig.run('/opsx:apply');
    file.writeAsStringSync('Second text.\n');

    final again = await rig.submit('/opsx:apply');

    expect(again, isA<SubmitDuplicate>());
    expect(rig.exchange(1)['prompt'], 'First text.\n');
    expect(rig.at('body/exchanges'), hasLength(1));
    expect(rig.provider.requests, hasLength(1));
  });
}
