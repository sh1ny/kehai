// The `rg --version` probe is a supervised job: a hung executable cannot hang
// grep or find, and closing the runtime terminates it (pre-ship review 11).
import 'dart:async';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/bash_support.dart';
import '../support/session_support.dart';

bool _alive(int pid) {
  if (Platform.isWindows) {
    final out = Process.runSync('tasklist', [
      '/FI',
      'PID eq $pid',
      '/NH',
      '/FO',
      'CSV',
    ]).stdout.toString();
    return out.contains('"$pid"');
  }
  return Process.runSync('kill', ['-0', '$pid']).exitCode == 0;
}

/// An executable that runs the never-ending fixture, which writes its pid to
/// [pidFile] first.
Future<String> _hangingRg(String pidFile) async {
  final dir = await tempDir();
  final fixture = p.absolute('test', 'fixtures', 'hang_forever.dart');
  final dart = Platform.resolvedExecutable;
  if (Platform.isWindows) {
    final shim = File(p.join(dir.path, 'rg-shim.bat'))
      ..writeAsStringSync('@"$dart" "$fixture" "$pidFile"\r\n');
    return shim.path;
  }
  final shim = File(p.join(dir.path, 'rg-shim'))
    ..writeAsStringSync('#!/bin/sh\nexec "$dart" "$fixture" "$pidFile"\n');
  Process.runSync('chmod', ['755', shim.path]);
  return shim.path;
}

void main() {
  const probe = Duration(seconds: 1);

  test('a probe that never exits ends grep failed within the deadline', () async {
    final pidFile = p.join((await tempDir()).path, 'probe.pid');
    final h = await BashHarness.create(
      config: UserConfig(rgPath: await _hangingRg(pidFile)),
      seams: const ToolRuntimeSeams(rgProbeTimeout: probe),
    );

    final clock = Stopwatch()..start();
    final text = await h.call('grep', {'pattern': 'x'});
    clock.stop();

    expect(clock.elapsed, lessThan(const Duration(seconds: 15)));
    final node = h.lastCall;
    expect(node['status'], 'failed');
    expect(node['reason'], contains('rg --version timed out'));
    expect(text, contains('timed out'));
    final job = h.jobNodes.values.single;
    expect(job['state'], 'cancelled');
    expect(job['reason'], 'deadline');
    expect(job.containsKey('call'), isFalse);
    expect(job['shell'], isNull);
    if (File(pidFile).existsSync()) {
      expect(
        _alive(int.parse(File(pidFile).readAsStringSync().trim())),
        isFalse,
      );
    }

    // The outcome is cached: a second call fails at once, without a new probe.
    final again = Stopwatch()..start();
    await h.call('find', {'glob': '*'});
    expect(again.elapsed, lessThan(const Duration(seconds: 1)));
    expect(h.jobNodes, hasLength(1));
    expect(h.lastCall['status'], 'failed');
  });

  test('a missing search path fails before rg is probed', () async {
    final pidFile = p.join((await tempDir()).path, 'probe.pid');
    final h = await BashHarness.create(
      config: UserConfig(rgPath: await _hangingRg(pidFile)),
      seams: const ToolRuntimeSeams(rgProbeTimeout: Duration(minutes: 5)),
    );

    for (final (tool, input) in [
      ('find', {'glob': '*', 'path': 'nope'}),
      ('grep', {'pattern': 'x', 'path': 'nope'}),
    ]) {
      final text = await h
          .call(tool, input)
          .timeout(const Duration(seconds: 20));
      expect(text, contains('no such directory nope'), reason: tool);
    }
    expect(h.jobNodes, isEmpty, reason: 'no probe job started');
    expect(File(pidFile).existsSync(), isFalse);
  });

  test('close terminates the probe and the waiting call ends', () async {
    final pidFile = p.join((await tempDir()).path, 'probe.pid');
    final h = await BashHarness.create(
      config: UserConfig(rgPath: await _hangingRg(pidFile)),
      seams: const ToolRuntimeSeams(rgProbeTimeout: Duration(minutes: 5)),
    );

    final call = h.call('grep', {'pattern': 'x'});
    final clock = Stopwatch()..start();
    while (!File(pidFile).existsSync()) {
      if (clock.elapsed > const Duration(seconds: 20)) {
        fail('probe not started');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    final pid = int.parse(File(pidFile).readAsStringSync().trim());
    expect(_alive(pid), isTrue);

    await h.runtime.close();

    expect(_alive(pid), isFalse);
    await call.timeout(const Duration(seconds: 20));
    // The call stopped waiting for the probe and ended cancelled.
    expect(h.lastCall['status'], 'cancelled');
    expect(h.lastCall['reason'], 'shutdown');
    expect(h.lastCall['summary'], 'cancelled: shutdown');
    expect(h.jobNodes.values.single['state'], 'cancelled');
  });

  test('the real rg still resolves through the supervised probe', () async {
    final h = await BashHarness.create();
    File(p.join(h.workspace.path, 'a.txt')).writeAsStringSync('needle\n');

    final text = await h.call('grep', {'pattern': 'needle'});

    expect(text, contains('a.txt'));
    expect(h.lastCall['status'], 'settled');
    final probes = h.jobNodes.values.where((j) => j['cmd'] == 'rg --version');
    expect(probes, hasLength(1));
    expect(probes.single['state'], 'settled');
  });
}
