import 'dart:async';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/bash_support.dart';
import '../support/job_support.dart';

void main() {
  final skip = skipBash();

  group('bash', () {
    test(
      'non-zero exit settles error with exit status in the summary',
      () async {
        final h = await BashHarness.create();

        final text = await h.call('bash', {
          'command': 'echo analyzer output; exit 3',
        });

        // The spec settles a non-zero exit `error` with `exit <code>`; the
        // row name's "ok" is its label only.
        final node = h.lastCall;
        expect(node['envelope'], 'error');
        expect(node['summary'] as String, startsWith('exit 3'));
        expect(h.resultOf(node), contains('analyzer output'));
        expect(text, contains('exit 3'));
        expect(text, contains('analyzer output'));
        expect(text, contains(RegExp(r'bash|git-bash|powershell|pwsh')));
      },
      skip: skip,
    );

    test('exit 0 settles ok with exit 0', () async {
      final h = await BashHarness.create();

      await h.call('bash', {'command': 'echo fine'});

      final node = h.lastCall;
      expect(node['envelope'], 'ok');
      expect(node['summary'] as String, startsWith('exit 0'));
    }, skip: skip);

    test('stdin is closed at once so a reader sees EOF', () async {
      final h = await BashHarness.create();

      final text = await h.call('bash', {
        'command': 'cat; echo reached-eof',
        'timeout_s': 30,
      });

      expect(h.lastCall['envelope'], 'ok');
      expect(text, contains('reached-eof'));
    }, skip: skip);

    test('stdout, stderr and combined output keep arrival order', () async {
      final h = await BashHarness.create();

      await h.call('bash', {
        'command':
            'echo a; sleep 0.05; echo b >&2; sleep 0.05; echo c; sleep 0.05',
      });

      final job = h.jobNodes.values.single;
      expect(h.stream(job, 'stdout'), 'a\nc\n');
      expect(h.stream(job, 'stderr'), 'b\n');
      expect(h.stream(job, 'output'), 'a\nb\nc\n');
      expect(h.resultOf(h.lastCall), 'a\nb\nc\n');
    }, skip: skip);

    test(
      '[slow] 1 GiB of output streams to disk with bounded memory',
      () async {
        final h = await BashHarness.create();
        const total = 1024 * 1024 * 1024;
        final baseline = ProcessInfo.currentRss;
        var peak = baseline;
        final sampler = Timer.periodic(const Duration(milliseconds: 200), (_) {
          if (ProcessInfo.currentRss > peak) peak = ProcessInfo.currentRss;
        });
        final clock = Stopwatch()..start();
        // A native generator writes straight to the job's pipe. Through
        // `yes | head` an msys shell on Windows delivers about 200 KB/s to a
        // Dart reader, which would turn this into a test of msys.
        final script = File(p.join(h.workspace.path, 'gen.dart'))
          ..writeAsStringSync(_generator);
        final dart = Platform.resolvedExecutable.replaceAll(r'\', '/');
        final path = script.path.replaceAll(r'\', '/');

        final text = await h.call('bash', {
          'command': 'exec "$dart" "$path" $total',
          'timeout_s': 600,
        });
        clock.stop();
        sampler.cancel();

        final node = h.lastCall;
        expect(node['envelope'], isNotNull);
        final result = node['result']! as Map<String, Object?>;
        final resolved = resolveHandle(
          h.writer.tree,
          h.writer.sessionDir,
          result['handle']! as String,
        );
        expect(resolved.descriptor.bytes, total);
        expect(result['complete'], isTrue);
        expect(text, contains('r/'));
        // ignore: avoid_print
        print(
          'slow: ${clock.elapsed}; rss baseline ${baseline >> 20} MiB, '
          'peak ${peak >> 20} MiB',
        );
        expect(peak - baseline, lessThan(256 * 1024 * 1024));
      },
      tags: 'slow',
      skip: skip,
    );

    test(
      'budget expiry settles partial with the job id while the job runs',
      () async {
        final h = await BashHarness.create();
        final clock = Stopwatch()..start();

        final text = await h.call('bash', {
          'command': 'echo start; sleep 4; echo end',
          'timeout_s': 1,
        });
        clock.stop();

        final node = h.lastCall;
        expect(node['envelope'], 'partial');
        final id = jobIdIn(node['summary']! as String);
        expect(
          node['summary'],
          startsWith('still running as job $id; use job($id)'),
        );
        expect(text, contains('job($id)'));
        expect(clock.elapsed, lessThan(const Duration(seconds: 4)));
        expect(h.job(id)['state'], anyOf('pending', 'running'));
        expect(h.resultOf(node), contains('start'));
        expect((node['result']! as Map)['complete'], isFalse);

        await waitFor(
          () => h.job(id)['state'] == 'settled',
          what: 'the job to settle',
        );
        final job = h.job(id);
        expect(job['exit'], 0);
        expect(
          h.stream(job, 'output'),
          allOf(contains('start'), contains('end')),
        );
      },
      skip: skip,
    );

    test('timeout_s outside 1–600 fails validation', () async {
      final h = await BashHarness.create();

      for (final bad in [0, 601]) {
        final text = await h.call('bash', {
          'command': 'echo should-not-run',
          'timeout_s': bad,
        });
        expect(text, contains('invalid arguments'));
        expect(h.lastCall['status'], 'failed');
      }
      expect(h.jobNodes, isEmpty);
      expect(h.runtime.jobs.liveCount, 0);
    });

    test('deadline_s outside 1-86400 fails validation', () async {
      final h = await BashHarness.create();

      for (final bad in [0, 86401]) {
        final text = await h.call('bash', {
          'command': 'echo should-not-run',
          'deadline_s': bad,
        });
        expect(text, contains('invalid arguments'));
      }
      expect(h.jobNodes, isEmpty);
    });

    test('an autoapproved command runs directly, without a shell', () async {
      final h = await BashHarness.create(
        permission: {'decision': 'allow', 'by': 'user', 'rule': 'bash'},
      );

      final text = await h.call('bash', {'command': 'rg --version'});

      expect(h.lastCall['envelope'], 'ok');
      expect(text, contains('ripgrep'));
      expect(h.jobNodes.values.single['shell'], isNull);
    }, skip: skip);

    test(
      'turn cancel stops the foreground job and spares earlier ones',
      () async {
        final h = await BashHarness.create();
        final earlier = jobIdIn(
          await h.call('bash', {
            'command': 'echo bg; sleep 30',
            'timeout_s': 1,
          }),
        );

        final running = h.call('bash', {'command': 'echo fg; sleep 30'});
        await waitFor(
          () =>
              h.jobNodes.length == 2 &&
              h.jobNodes.values.every((n) => n['state'] == 'running'),
          what: 'the foreground job to start',
        );
        expect(await h.runtime.cancelTurn(), 1);
        await running;

        final foreground = h.jobNodes.keys.singleWhere((id) => id != earlier);
        await waitFor(
          () => h.job(foreground)['state'] == 'cancelled',
          what: 'the foreground job to be cancelled',
        );
        expect(h.job(earlier)['state'], anyOf('pending', 'running'));
        expect(h.lastCall['status'], 'cancelled');
      },
      skip: skip,
    );

    test('the description and the summary name the shell', () async {
      final h = await BashHarness.create();
      final name = h.runtime.shell.shell!.name;

      await h.call('bash', {'command': 'echo hi'});

      final spec = h.runtime.specs.singleWhere((s) => s.name == 'bash');
      expect(spec.description, contains(name));
      expect(h.lastCall['summary'], contains(name));
    }, skip: skip);
  });
}

/// Writes the given number of bytes to stdout as 1 KiB lines.
const String _generator = r'''
import 'dart:io';

Future<void> main(List<String> arguments) async {
  var left = int.parse(arguments[0]);
  final line = List<int>.filled(1023, 0x78, growable: true)..add(0x0a);
  final block = <int>[for (var i = 0; i < 64; i++) ...line];
  while (left > 0) {
    final n = left < block.length ? left : block.length;
    stdout.add(n == block.length ? block : block.sublist(0, n));
    await stdout.flush();
    left -= n;
  }
}
''';
