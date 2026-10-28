import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:kehai/kehai.dart';
import 'package:kehai/src/session/ownership.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/session_support.dart';

const _slow = Timeout(Duration(minutes: 3));

/// A collection of messages that tests can wait on.
final class Mailbox<T> {
  final List<T> seen = [];
  bool closed = false;
  final StreamController<void> _signal = StreamController.broadcast();

  void add(T message) {
    seen.add(message);
    _signal.add(null);
  }

  void close() {
    closed = true;
    _signal.add(null);
  }

  Future<T> waitFor(bool Function(T) test) async {
    while (true) {
      for (final message in seen) {
        if (test(message)) return message;
      }
      if (closed) throw StateError('mailbox closed; saw $seen');
      await _signal.stream.first;
    }
  }
}

/// A helper process running `test/fixtures/hold_session.dart`.
final class Fixture {
  Fixture._(this.process);

  final Process process;
  final Mailbox<String> out = Mailbox();
  int childPid = 0;

  static Future<Fixture> start(Directory dir, [String mode = 'hold']) async {
    final process = await Process.start(Platform.resolvedExecutable, [
      'run',
      'test/fixtures/hold_session.dart',
      dir.path,
      mode,
    ]);
    final fixture = Fixture._(process);
    addTearDown(fixture.kill);
    unawaited(process.stderr.drain<void>());
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(fixture.out.add, onDone: fixture.out.close);
    return fixture;
  }

  /// Waits for a line starting with [prefix] and returns the rest of it.
  Future<String> waitFor(String prefix) async {
    final line = await out.waitFor((l) => l.startsWith(prefix));
    return line.substring(prefix.length).trim();
  }

  Future<void> held() async {
    childPid = int.parse(await waitFor('HELD '));
  }

  void send(String line) => process.stdin.writeln(line);

  /// Kills the wrapper and the VM it started, then waits until both are gone.
  Future<void> kill() async {
    process.kill();
    if (childPid != 0) {
      for (var i = 0; i < 200 && Process.killPid(childPid); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
    await process.exitCode;
  }
}

/// An isolate that holds a [SessionWriter] on request.
final class Worker {
  Worker._(this._commands, this.inbox);

  final SendPort _commands;
  final Mailbox<List<Object?>> inbox;
  int _next = 0;

  static Future<Worker> spawn() async {
    final port = ReceivePort();
    final inbox = Mailbox<List<Object?>>();
    final ready = Completer<SendPort>();
    port.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
      } else {
        inbox.add(message as List<Object?>);
      }
    });
    final isolate = await Isolate.spawn(_workerMain, port.sendPort);
    final worker = Worker._(await ready.future, inbox);
    addTearDown(() async {
      await worker.request('close');
      isolate.kill(priority: Isolate.immediate);
      port.close();
    });
    return worker;
  }

  Future<String> request(
    String command, [
    List<Object?> args = const [],
  ]) async {
    final id = _next++;
    _commands.send([command, id, ...args]);
    final reply = await inbox.waitFor((m) => m[0] == 'result' && m[1] == id);
    return reply[2] as String;
  }

  /// Opens [dir] for writing, pausing at the named [points] once each.
  Future<String> open(Directory dir, {List<String> points = const []}) =>
      request('open', [dir.path, points]);

  Future<void> waitPaused(String point) =>
      inbox.waitFor((m) => m[0] == 'paused' && m[1] == point);

  void resume(String point) => _commands.send(['resume', -1, point]);
}

void _workerMain(SendPort toMain) {
  final commands = ReceivePort();
  toMain.send(commands.sendPort);
  SessionWriter? writer;
  final pauseAt = <String>{};
  final resumes = <String, Completer<void>>{};

  Future<String> run(String command, List<Object?> args) async {
    switch (command) {
      case 'open':
        pauseAt.addAll((args[1] as List).cast<String>());
        final hooks = OwnershipHooks(
          pause: (point) async {
            if (!pauseAt.remove(point)) return;
            final gone = resumes[point] = Completer<void>();
            toMain.send(['paused', point]);
            await gone.future;
          },
        );
        try {
          final opened = await SessionWriter.open(
            Directory(args[0] as String),
            hooks: hooks,
          );
          writer = opened;
          final takeover = opened.takeover;
          return takeover == null
              ? 'HELD'
              : 'HELD TAKEOVER ${takeover.previousPid}';
        } on SessionError catch (e) {
          return 'REFUSED ${e.message}';
        }
      case 'append':
        await writer!.apply(rec(1, 'body/worker', Op.set, 'w'));
        return 'APPENDED';
      case 'close':
        await writer?.close();
        return 'CLOSED';
    }
    return 'UNKNOWN';
  }

  commands.listen((message) {
    final [command as String, id as int, ...args] = message as List;
    if (command == 'resume') {
      resumes[args[0] as String]?.complete();
      return;
    }
    run(command, args).then(
      (result) => toMain.send(['result', id, result]),
      onError: (Object e) => toMain.send(['result', id, 'ERROR $e']),
    );
  });
}

/// A closed session directory with no owner, ready to be opened.
Future<Directory> _idleSession() async {
  final root = await tempDir();
  final writer = await SessionWriter.create(root);
  final dir = writer.sessionDir;
  await writer.close();
  return dir;
}

Map<String, Object?> _ownerOf(Directory dir) =>
    jsonDecode(File(p.join(dir.path, ownerFileName)).readAsStringSync())
        as Map<String, Object?>;

Matcher _lockedBy(Object pidValue, Directory dir) => allOf(
  contains('session locked'),
  contains(dir.path),
  contains('$pidValue'),
);

void main() {
  test(
    'second writer is refused from process, isolate and same isolate',
    () async {
      final root = await tempDir();
      final writer = await createWriter(root);
      final dir = writer.sessionDir;

      for (var i = 0; i < 2; i++) {
        await expectLater(
          SessionWriter.open(dir),
          throwsA(
            isA<SessionError>()
                .having((e) => e.reason, 'reason', 'session locked')
                .having((e) => e.message, 'message', _lockedBy(pid, dir)),
          ),
        );
      }

      final worker = await Worker.spawn();
      expect(
        await worker.open(dir),
        allOf(startsWith('REFUSED'), _lockedBy(pid, dir)),
      );

      final first = await Fixture.start(dir);
      expect(await first.waitFor('REFUSED '), _lockedBy(pid, dir));

      // The holder was not disturbed.
      await writer.apply(rec(1, 'body/still', Op.set, 'ok'));

      final third = await Fixture.start(dir);
      expect(await third.waitFor('REFUSED '), _lockedBy(pid, dir));
    },
    timeout: _slow,
  );

  test('concurrent openers race and exactly one wins', () async {
    final dir = await _idleSession();
    final a = await Worker.spawn();
    final b = await Worker.spawn();
    final foreign = await Fixture.start(dir, 'open-on-go');
    await foreign.waitFor('READY');

    final results = Future.wait([a.open(dir), b.open(dir)]);
    foreign.send('go');
    final foreignResult = await foreign.out.waitFor(
      (l) => l.startsWith('HELD') || l.startsWith('REFUSED'),
    );
    final all = [...await results, foreignResult];

    expect(
      all.where((r) => r.startsWith('HELD')),
      hasLength(1),
      reason: '$all',
    );
    expect(
      all.where((r) => r.startsWith('REFUSED')),
      allOf(hasLength(2), everyElement(contains('session locked'))),
    );
  }, timeout: _slow);

  test('takeover race inside one process yields one owner', () async {
    final dir = await _idleSession();
    File(p.join(dir.path, ownerFileName)).writeAsStringSync(
      jsonEncode({
        'pid': pid + 1000000,
        'nonce': 'deadbeef',
        'startedUtc': '2020-01-01T00:00:00.000Z',
      }),
    );
    final a = await Worker.spawn();
    final b = await Worker.spawn();

    final aResult = a.open(dir, points: ['owner-read']);
    await a.waitPaused('owner-read');
    final bResult = b.open(dir, points: ['gate-busy']);
    await b.waitPaused('gate-busy');

    a.resume('owner-read');
    expect(await aResult, 'HELD TAKEOVER ${pid + 1000000}');
    b.resume('gate-busy');
    expect(await bResult, allOf(startsWith('REFUSED'), _lockedBy(pid, dir)));

    expect(_ownerOf(dir)['pid'], pid);
    expect(await a.request('append'), 'APPENDED');
    expect(File(p.join(dir.path, gateFileName)).existsSync(), isFalse);
  }, timeout: _slow);

  test('close racing a reopen never yields two writers', () async {
    final root = await tempDir();
    final paused = Completer<void>();
    final resume = Completer<void>();
    final writer = await SessionWriter.create(
      root,
      hooks: OwnershipHooks(
        pause: (point) async {
          if (point != 'lock-closed') return;
          paused.complete();
          await resume.future;
        },
      ),
    );
    addTearDown(() async {
      if (!resume.isCompleted) resume.complete();
      await writer.close();
    });
    final dir = writer.sessionDir;

    final closing = writer.close();
    await paused.future;

    // Mid-close, the record still names this process: a sibling isolate is
    // refused.
    final sibling = await Worker.spawn();
    expect(
      await sibling.open(dir),
      allOf(startsWith('REFUSED'), _lockedBy(pid, dir)),
    );

    // The lock is already released, so a foreign process takes over.
    final foreign = await Fixture.start(dir);
    await foreign.held();
    expect(foreign.out.seen, contains(startsWith('TAKEOVER')));

    resume.complete();
    await closing;

    // The nonce check left the foreign record alone.
    expect(_ownerOf(dir)['pid'], foreign.childPid);
    final late = await Worker.spawn();
    expect(
      await late.open(dir),
      allOf(startsWith('REFUSED'), _lockedBy(foreign.childPid, dir)),
    );
  }, timeout: _slow);

  test('stale empty gate is refused with removal hint', () async {
    final dir = await _idleSession();
    final crashed = await Fixture.start(dir, 'gate');
    crashed.childPid = int.parse(await crashed.waitFor('GATE '));
    await crashed.kill();

    final gate = File(p.join(dir.path, gateFileName));
    expect(gate.existsSync(), isTrue);
    expect(gate.lengthSync(), 0);

    final clock = Stopwatch()..start();
    await expectLater(
      SessionWriter.open(dir),
      throwsA(
        isA<SessionError>()
            .having(
              (e) => e.reason,
              'reason',
              'session gate held by pid unknown',
            )
            .having((e) => e.detail, 'detail', contains(gate.path)),
      ),
    );
    expect(clock.elapsed, greaterThanOrEqualTo(const Duration(seconds: 2)));

    gate.deleteSync();
    final writer = await SessionWriter.open(dir);
    addTearDown(writer.close);
    expect(writer.state, WriterState.ready);
  }, timeout: _slow);

  test('dead owner process is taken over', () async {
    final dir = await _idleSession();
    final holder = await Fixture.start(dir);
    await holder.held();
    final deadPid = holder.childPid;
    await holder.kill();

    final writer = await SessionWriter.open(dir);
    addTearDown(writer.close);
    expect(writer.takeover, isNotNull);
    expect(writer.takeover!.previousPid, deadPid);
    expect(writer.takeover!.message, contains('$deadPid'));
    expect(_ownerOf(dir)['pid'], pid);
  }, timeout: _slow);
}
