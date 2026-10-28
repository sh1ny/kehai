import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/session_support.dart';

void main() {
  test('acknowledged record survives a killed process', () async {
    final root = await tempDir();
    final process = await Process.start(Platform.resolvedExecutable, [
      'run',
      'test/fixtures/append_then_wait.dart',
      root.path,
    ]);
    var childPid = 0;
    addTearDown(() {
      process.kill();
      if (childPid != 0) Process.killPid(childPid);
    });
    unawaited(process.stderr.drain<void>());

    final marker = process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .firstWhere((line) => line.startsWith('ACKED '));
    final parts = (await marker).substring('ACKED '.length).split(' ');
    childPid = int.parse(parts.removeLast());
    final sessionDir = Directory(parts.join(' '));

    // The marker is printed only after the append future completed.
    process.kill();
    Process.killPid(childPid);
    await process.exitCode;

    final read = materialize(sessionDir);
    expect(read.tree.get(SessionPath.parse('body/crash')), 'acked');
    expect(read.recordCount, 2);

    // The killed process left its owner file; reopening must still work.
    final writer = await SessionWriter.open(sessionDir);
    addTearDown(writer.close);
    expect(writer.tree.get(SessionPath.parse('body/crash')), 'acked');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
