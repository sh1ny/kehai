// A job whose spool write, seal or publish fails ends its bash call exactly
// as a result-store failure does (spec tool-calls: "Storage fails while
// output streams"; pre-ship review 5, F2).
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/bash_support.dart';
import '../support/job_support.dart' show waitFor;

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

  // A directory where a spool file belongs makes opening that spool fail.
  for (final (index, stream) in [(1, 'stdout'), (2, 'stderr'), (3, 'output')]) {
    test('creating spool $index ($stream) fails the call cleanly', () async {
      late BashHarness h;
      h = await BashHarness.create(
        jobHooks: JobHooks(
          afterPending: (id) async {
            final spool = (h.job(id)['spool']! as Map)[stream]! as String;
            Directory(p.join(h.writer.sessionDir.path, resultsDirName, spool))
                .createSync(recursive: true);
          },
        ),
      );

      final text = await h.call('bash', {'command': 'echo hi'});

      expectFailedCall(h, text, 0);
      expectFailedJob(h);
      final left = Directory(p.join(h.writer.sessionDir.path, resultsDirName))
          .listSync()
          .whereType<File>()
          .map((f) => p.basename(f.path));
      expect(
        left.where((n) => n.startsWith('.spool-') || n.startsWith('.tmp-')),
        isEmpty,
        reason: 'no spool or temp file leaks, so no handle stayed open',
      );
    }, skip: skip);
  }

  for (final fault in ['write', 'publish']) {
    test('a snapshot $fault failure at budget expiry fails the call and '
        'stops the job', () async {
      var armed = true;
      final h = await BashHarness.create(
        storeHooks: ResultStoreHooks(
          beforeWrite: (index, chunk) async {
            if (fault == 'write' && armed) {
              armed = false;
              throw const FileSystemException('disk full');
            }
          },
          beforeRename: () async {
            if (fault == 'publish' && armed) {
              armed = false;
              throw const FileSystemException('disk full');
            }
          },
        ),
      );

      final text = await h.call('bash', {
        'command': 'echo start; sleep 30',
        'timeout_s': 1,
      });

      expectFailedCall(h, text, fault == 'write' ? 0 : 6);
      final id = h.jobNodes.keys.single;
      await waitFor(
        () => const {
          'cancelled',
          'failed',
          'settled',
        }.contains(h.job(id)['state']),
        what: 'the job to be stopped',
      );
      expect(h.job(id)['state'], 'cancelled');
      expect(h.job(id)['reason'], startsWith('storage: '));
    }, skip: skip);
  }
}
