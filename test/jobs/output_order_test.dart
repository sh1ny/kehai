import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/job_support.dart';

void main() {
  test(
    'combined output keeps arrival order when the stdout spool write is slow',
    () async {
      final stderrCombined = Completer<void>();
      late final JobHarness h;
      h = await JobHarness.create(
        hooks: JobHooks(
          afterSpoolWrite: (id, stream, chunk) async {
            if (stream == 'stdout') {
              // The stdout chunk has arrived and is on its spool. Let the
              // command emit stderr, and hold the stdout side until the
              // combined output took the stderr chunk.
              File(h.marker('go')).writeAsStringSync('go');
              await stderrCombined.future;
            } else if (stream == 'output' && utf8.decode(chunk) == 'err\n') {
              stderrCombined.complete();
            }
          },
        ),
      );
      final go = h.marker('go');
      final handle = h.supervisor.start(
        h.request(
          'echo out; while [ ! -f "$go" ]; do sleep 0.05; done; echo err >&2',
        ),
      );
      final result = await handle.result;

      expect(result.state, 'settled');
      final node = h.node(handle.id)!;
      expect(h.stream(node, 'stdout'), 'out\n');
      expect(h.stream(node, 'stderr'), 'err\n');
      expect(h.stream(node, 'output'), 'out\nerr\n');
    },
    skip: skipWithoutShell(),
  );
}
