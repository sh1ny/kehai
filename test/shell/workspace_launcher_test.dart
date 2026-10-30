// Pre-ship round 9, F1: a `setsid` (or shell) supplied by the repository is
// never a launcher, whether it sits in an absolute PATH entry inside the
// workspace or is reached through a symlink that points into it.
@TestOn('!windows')
library;

import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/job_support.dart';
import '../support/session_support.dart';

void main() {
  late Directory root;
  late Directory ws;
  late String marker;
  late String realPathEnv;

  /// A `setsid` that records it ran, then does what setsid does.
  File plant(String path) {
    File(path)
      ..createSync(recursive: true)
      ..writeAsStringSync('#!/bin/sh\ntouch "$marker"\nexec "\$@"\n');
    Process.runSync('chmod', ['755', path]);
    return File(path);
  }

  setUp(() async {
    root = Directory((await tempDir()).resolveSymbolicLinksSync());
    ws = Directory(p.join(root.path, 'ws'))..createSync();
    marker = p.join(root.path, 'marker');
    realPathEnv = Platform.environment['PATH'] ?? '/usr/bin:/bin';
  });

  test('an absolute PATH entry inside the workspace is skipped', () {
    plant(p.join(ws.path, 'bin', 'setsid'));

    final found = detectShell(
      environment: {'PATH': '${p.join(ws.path, 'bin')}:$realPathEnv'},
      workspaceRoot: ws.path,
    );

    expect(found.shell, isNotNull);
    expect(found.shell!.setsid, isNot(startsWith(ws.path)));
  }, skip: skipWithoutShell());

  test('a symlink into the workspace is skipped', () {
    final real = plant(p.join(ws.path, 'real', 'setsid'));
    final outside = Directory(p.join(root.path, 'outside'))..createSync();
    Link(p.join(outside.path, 'setsid')).createSync(real.path);

    final found = detectShell(
      environment: {'PATH': '${outside.path}:$realPathEnv'},
      workspaceRoot: ws.path,
    );

    expect(found.shell!.setsid, isNot(p.join(outside.path, 'setsid')));
    expect(found.shell!.setsid, isNot(startsWith(ws.path)));
  }, skip: skipWithoutShell());

  test('a workspace bash is not the shell', () {
    final bin = Directory(p.join(ws.path, 'bin'))..createSync();
    File(p.join(bin.path, 'bash')).writeAsStringSync('#!/bin/sh\n');
    Process.runSync('chmod', ['755', p.join(bin.path, 'bash')]);

    final found = detectShell(
      environment: {'PATH': '${bin.path}:$realPathEnv'},
      workspaceRoot: ws.path,
    );

    expect(found.shell!.executable, isNot(startsWith(ws.path)));
  }, skip: skipWithoutShell());

  test('an autoapproved command never runs a workspace setsid', () async {
    plant(p.join(ws.path, 'bin', 'setsid'));
    final real = plant(p.join(ws.path, 'real', 'setsid'));
    final outside = Directory(p.join(root.path, 'outside'))..createSync();
    Link(p.join(outside.path, 'setsid')).createSync(real.path);
    final detection = detectShell(
      environment: {
        'PATH': [p.join(ws.path, 'bin'), outside.path, realPathEnv].join(':'),
      },
      workspaceRoot: ws.path,
    );
    final home = Directory(p.join(ws.path, '.kehai-home'))..createSync();
    final writer = await createWriter(ws);
    final runtime = await ToolRuntime.attach(
      writer,
      ResultStore(writer.sessionDir),
      workspace: ws,
      kehaiHome: home,
      shell: detection,
    );
    addTearDown(runtime.close);

    final item = await runtime.run(
      ToolCall(
        callId: 'c1',
        name: 'bash',
        argumentsJson: jsonEncode({'command': 'pwd'}),
      ),
    );

    expect(item.output, contains(ws.path));
    expect(File(marker).existsSync(), isFalse);
  }, skip: skipWithoutShell());
}
