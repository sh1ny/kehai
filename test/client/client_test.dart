/// The line client against an in-memory engine (specs *line-client*).
library;

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/client_support.dart';
import '../support/login_support.dart';

int _count(String text, String part) => part.allMatches(text).length;

void main() {
  group('Line input', () {
    test('backslash continuation submits one joined prompt', () async {
      final rig = clientRig();
      await rig.start(turn: 4);

      rig
        ..type(r'fix the test\')
        ..type('in lib/a.dart');
      await rig.settle();

      final submits = rig.engine.sentOfType('submit');
      expect(submits, hasLength(1));
      expect(submits.single['text'], 'fix the test\nin lib/a.dart');
      expect(submits.single['turn'], 4);
      expect(submits.single['id'], isA<String>());
    });

    test('input while running and no prompt prints busy and submits '
        'nothing', () async {
      final rig = clientRig();
      await rig.start();

      rig.type('first');
      await rig.settle();
      rig.type('second');
      await rig.settle();

      expect(
        rig.out.text,
        contains('busy: wait for the reply or press Ctrl-C'),
      );
      expect(rig.engine.sentOfType('submit'), hasLength(1));
    });
  });

  group('Non-terminal input', () {
    test('end of piped input waits for the running exchange after an '
        'answer', () async {
      final rig = clientRig(interactive: false);
      await rig.start();
      rig.type('run it');
      await rig.settle();
      final id = rig.engine.sentOfType('submit').single['id']! as String;
      await rig.prompt('c7', 'bash', {'command': 'dart analyze'});

      rig.type('1');
      await rig.endInput();

      expect(rig.engine.sentOfType('answer'), hasLength(1));
      expect(rig.engine.inputClosed, isFalse, reason: 'answer in flight');

      await rig.emit({'type': 'reply', 'to': 'answer', 'key': 'c7'});
      expect(rig.engine.inputClosed, isFalse, reason: 'exchange still runs');

      await rig.update('meta/requests/$id', 'merge', {'state': 'completed'});
      expect(rig.engine.inputClosed, isTrue);
    });

    test('end of piped input with a prompt open and nothing in flight '
        'exits', () async {
      final rig = clientRig(interactive: false);
      await rig.start();
      rig.type('run it');
      await rig.settle();
      await rig.prompt('c7', 'bash', {'command': 'dart analyze'});

      await rig.endInput();

      expect(rig.engine.inputClosed, isTrue);
    });
  });

  group('Streamed text', () {
    test(
      'deltas print as they arrive and the commit reprints nothing',
      () async {
        final rig = clientRig();
        await rig.start();
        rig.type('hi');
        await rig.settle();

        await rig.stream(3, 'Hel');
        expect(rig.out.text, endsWith('Hel'));
        await rig.stream(3, 'lo');
        expect(rig.out.text, endsWith('Hello'));
        await rig.update(stepPath(3), 'merge', committedText('Hello'), turn: 3);

        expect(_count(rig.out.text, 'Hello'), 1);
        expect(rig.out.text, isNot(contains('HelloHello')));
      },
    );

    test('resync mid-text prints only the unseen committed tail', () async {
      final rig = clientRig();
      await rig.start();
      rig.type('hi');
      await rig.settle();

      await rig.stream(3, 'Hel');
      await rig.emit({'type': 'resync'});
      await rig.resnapshot({
        'body': {
          'steps': {
            'x': {'state': 'running'},
          },
        },
      }, turn: 3);
      await rig.update(
        stepPath(3),
        'merge',
        committedText('Hello world'),
        turn: 3,
      );

      expect(rig.out.text, contains('Hello world'));
      expect(_count(rig.out.text, 'Hel'), 1);
      expect(rig.out.text, isNot(contains('Hello worldHello')));
    });
  });

  group('One line per tool call', () {
    Future<void> settleCall(
      ClientRig rig,
      String command, {
      String summary = 'exit 0',
    }) async {
      rig.type('run the tests');
      await rig.settle();
      await rig.update('body/calls/c1', 'set', {
        'tool': 'bash',
        'input': {'command': command},
        'status': 'pending',
      });
      await rig.update('body/calls/c1', 'merge', {
        'status': 'settled',
        'envelope': 'ok',
        'summary': summary,
      });
    }

    test('settled bash call prints one status line', () async {
      final rig = clientRig();
      await rig.start();

      await settleCall(rig, 'dart test');

      final lines = rig.out.lines.where((l) => l.startsWith('[bash'));
      expect(lines, ['[bash ok] exit 0: dart test']);
    });

    test(
      'long command line is cut to 160 characters with an ellipsis',
      () async {
        final rig = clientRig();
        await rig.start();

        await settleCall(rig, 'x' * 400);

        final line = rig.out.lines.singleWhere(
          (l) => l.startsWith('[bash ok]'),
        );
        expect(line.runes.length, lessThanOrEqualTo(160));
        expect(line, endsWith('…'));
      },
    );
  });

  group('Answering prompts', () {
    test('typing 1 at a permission prompt sends allow for its key', () async {
      final rig = clientRig();
      await rig.start();
      rig.type('run it');
      await rig.settle();

      await rig.prompt('c7', 'bash', {'command': 'dart analyze'});
      expect(rig.out.text, contains('dart analyze'));
      rig.type('1');
      await rig.settle();

      expect(rig.engine.sentOfType('answer'), [
        {'type': 'answer', 'key': 'c7', 'text': 'allow'},
      ]);
      expect(rig.engine.sentOfType('submit'), hasLength(1));
    });

    Future<ClientRig> runningRig() async {
      final rig = clientRig();
      await rig.start();
      rig.type('run it');
      await rig.settle();
      return rig;
    }

    test('second prompt is queued and each answer binds to one key', () async {
      final rig = await runningRig();

      await rig.prompt('cA', 'bash', {'command': 'dart analyze'});
      await rig.prompt('cB', 'write', {'path': 'lib/a.dart'});

      expect(rig.out.lines, contains('queued: write lib/a.dart'));
      expect(rig.out.text, isNot(contains('permission: write')));

      rig.type('1');
      await rig.settle();
      expect(rig.engine.sentOfType('answer'), [
        {'type': 'answer', 'key': 'cA', 'text': 'allow'},
      ]);

      await rig.emit({'type': 'reply', 'to': 'answer', 'key': 'cA'});
      expect(rig.out.lines, contains('permission: write lib/a.dart'));

      rig.type('2');
      await rig.settle();
      expect(rig.engine.sentOfType('answer'), [
        {'type': 'answer', 'key': 'cA', 'text': 'allow'},
        {'type': 'answer', 'key': 'cB', 'text': 'deny'},
      ]);
    });

    test('refused answer keeps the active prompt and the queue', () async {
      final rig = await runningRig();
      await rig.prompt('cA', 'bash', {'command': 'dart analyze'});
      await rig.prompt('cB', 'write', {'path': 'lib/a.dart'});

      rig.type('1');
      await rig.settle();
      await rig.emit({
        'type': 'error',
        'to': 'answer',
        'message': 'no open question cA',
      });

      expect(rig.out.lines, contains('no open question cA'));
      expect(rig.out.text, isNot(contains('permission: write')));
      rig.type('1');
      await rig.settle();
      expect(rig.engine.sentOfType('answer'), [
        {'type': 'answer', 'key': 'cA', 'text': 'allow'},
        {'type': 'answer', 'key': 'cA', 'text': 'allow'},
      ]);

      await rig.emit({'type': 'reply', 'to': 'answer', 'key': 'cA'});
      expect(rig.out.lines, contains('permission: write lib/a.dart'));
    });

    test('withdrawals remove queued keys and advance the active one', () async {
      final rig = await runningRig();
      await rig.prompt('cA', 'bash', {'command': 'dart analyze'});
      await rig.prompt('cB', 'write', {'path': 'lib/b.dart'});
      await rig.prompt('cC', 'write', {'path': 'lib/c.dart'});

      await rig.emit({'type': 'withdraw', 'key': 'cB'});
      expect(rig.out.text, isNot(contains('permission: write lib/b.dart')));

      await rig.emit({'type': 'withdraw', 'key': 'cA'});
      expect(rig.out.lines, contains('permission: write lib/c.dart'));
      expect(rig.out.text, isNot(contains('permission: write lib/b.dart')));

      rig.type('1');
      await rig.settle();
      expect(rig.engine.sentOfType('answer'), [
        {'type': 'answer', 'key': 'cC', 'text': 'allow'},
      ]);
    });

    test('invalid choice is refused locally and asked again', () async {
      final rig = await runningRig();
      await rig.prompt('q1', 'ask', {
        'question': 'Which shell?',
        'choices': ['bash', 'pwsh'],
        'allow_text': false,
      }, kind: 'question');

      rig.type('zsh');
      await rig.settle();

      expect(rig.out.lines, contains('answer must be one of: bash, pwsh'));
      expect(rig.out.text, endsWith('answer> '));
      expect(rig.engine.sentOfType('answer'), isEmpty);

      rig.type('2');
      await rig.settle();
      expect(rig.engine.sentOfType('answer'), [
        {'type': 'answer', 'key': 'q1', 'text': 'pwsh'},
      ]);
    });

    test('free text is sent as typed when the question allows it', () async {
      final rig = await runningRig();
      await rig.prompt('q1', 'ask', {
        'question': 'Which shell?',
        'choices': ['bash', 'pwsh'],
        'allow_text': true,
      }, kind: 'question');

      rig.type('zsh');
      await rig.settle();

      expect(rig.engine.sentOfType('answer'), [
        {'type': 'answer', 'key': 'q1', 'text': 'zsh'},
      ]);
    });
  });

  group('Ctrl-C', () {
    test('two Ctrl-C while running send exactly one interrupt', () async {
      final rig = clientRig();
      await rig.start();
      rig.type('run it');
      await rig.settle();
      final id = rig.engine.sentOfType('submit').single['id']! as String;
      await rig.update('body/calls/c1', 'set', {
        'tool': 'bash',
        'input': {'command': 'sleep 60'},
        'status': 'pending',
      });

      await rig.ctrlC();
      await rig.ctrlC();

      expect(rig.engine.sentOfType('interrupt'), hasLength(1));
      expect(rig.out.lines.where((l) => l == 'interrupting…'), hasLength(1));

      await rig.update('body/calls/c1', 'merge', {'status': 'cancelled'});
      await rig.update('meta/requests/$id', 'merge', {'state': 'interrupted'});
      expect(rig.out.lines, contains('[bash cancelled] sleep 60'));
      expect(rig.out.text, endsWith('> '));
      expect(rig.engine.inputClosed, isFalse);
    });

    test('Ctrl-C at an idle prompt exits the client', () async {
      final rig = clientRig();
      await rig.start();

      await rig.ctrlC();

      expect(rig.engine.sentOfType('interrupt'), isEmpty);
      expect(rig.engine.inputClosed, isTrue);
    });

    test('Ctrl-C with a prompt open sends one interrupt', () async {
      final rig = clientRig();
      await rig.start();
      rig.type('run it');
      await rig.settle();
      await rig.prompt('c7', 'bash', {'command': 'dart analyze'});

      await rig.ctrlC();

      expect(rig.engine.sentOfType('interrupt'), hasLength(1));
      expect(rig.engine.inputClosed, isFalse);
    });

    test('engine still alive 5 s after stdin closes is killed', () async {
      expect(
        LineClient(
          engine: FakeEngine(),
          input: const Stream<String>.empty(),
          out: TestSink(),
          err: TestSink(),
        ).exitGrace,
        const Duration(seconds: 5),
      );

      final rig = clientRig(exitGrace: const Duration(milliseconds: 200));
      await rig.start();

      rig.type('/exit');
      await rig.settle();
      expect(rig.engine.inputClosed, isTrue);
      expect(rig.engine.killed, isFalse, reason: 'still within the grace');

      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(rig.engine.killed, isTrue);
    });
  });
}
