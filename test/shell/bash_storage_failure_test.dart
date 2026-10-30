// A job whose spool write, seal or publish fails ends its bash call exactly
// as a result-store failure does (spec tool-calls: "Storage fails while
// output streams"; pre-ship review 5, F2).
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/bash_support.dart';

void main() {
  final skip = skipBash();

  /// The text the model gets for a storage failure with [accepted] bytes.
  Matcher storageText(int accepted) => allOf(
    startsWith('[bash error] storage failure: '),
    endsWith('; $accepted bytes accepted, not stored'),
    isNot(contains('r/')),
  );

  void expectFailedCall(BashHarness h, String text, int accepted) {
    final node = h.lastCall;
    expect(node['status'], 'failed');
    expect(node['envelope'], 'error');
    expect(node['reason'], startsWith('storage: '));
    expect(node['accepted'], accepted);
    expect(node.containsKey('result'), isFalse);
    expect(text, storageText(accepted));
    final error = (node['reason']! as String).substring('storage: '.length);
    expect(text, contains('storage failure: $error;'));
  }

  void expectFailedJob(BashHarness h) {
    final job = h.jobNodes.values.single;
    expect(job['state'], 'failed');
    expect(job['reason'], startsWith('storage: '));
    final handoffs = h.writer.tree.get(SessionPath.parse('meta/handoffs'));
    expect(handoffs is Map && handoffs.isNotEmpty, isFalse);
  }

  test('a spool write failure fails the call with accepted bytes', () async {
    final h = await BashHarness.create(
      jobHooks: JobHooks(
        afterSpoolWrite: (id, stream, chunk) async {
          if (stream == 'output') throw const FileSystemException('disk full');
        },
      ),
    );

    final text = await h.call('bash', {
      'command': 'echo hi; sleep 30',
      'timeout_s': 60,
    });

    expectFailedCall(h, text, 3);
    expectFailedJob(h);
  }, skip: skip);

  test('a seal failure fails the call', () async {
    final h = await BashHarness.create(
      jobHooks: JobHooks(
        beforeSeal: (id, stream) async {
          if (stream == 'stdout') throw const FileSystemException('seal');
        },
      ),
    );

    final text = await h.call('bash', {'command': 'echo hi'});

    expectFailedCall(h, text, 3);
    expectFailedJob(h);
  }, skip: skip);

  test('a publish failure fails the call', () async {
    late BashHarness h;
    h = await BashHarness.create(
      jobHooks: JobHooks(
        beforeIntent: (id) async {
          // The spool of stderr vanishes before it can be renamed.
          final spool = (h.job(id)['spool']! as Map)['stderr']! as String;
          File(p.join(h.writer.sessionDir.path, resultsDirName, spool))
              .deleteSync();
        },
      ),
    );

    final text = await h.call('bash', {'command': 'echo hi'});

    expectFailedCall(h, text, 3);
    expectFailedJob(h);
  }, skip: skip);
}
