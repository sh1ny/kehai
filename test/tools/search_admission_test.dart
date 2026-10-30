// A grep or find call that would start a 17th job ends `failed`, as a bash
// call does (spec job-supervisor: "Live job bound"; pre-ship review 10, F2).
import 'dart:io';

import 'package:kehai/kehai.dart';
import 'package:test/test.dart';

import '../support/bash_support.dart';
import '../support/job_support.dart';

void main() {
  for (final (tool, input) in [
    ('grep', {'pattern': 'needle'}),
    ('find', {'glob': '*.txt'}),
    ('bash', {'command': 'echo hi'}),
  ]) {
    test(
      '$tool at the 16-job bound ends failed with the bound message',
      () async {
        final h = await BashHarness.create();
        File('${h.workspace.path}/a.txt').writeAsStringSync('needle\n');
        final shell = posixShell()!;
        for (var i = 0; i < maxLiveJobs; i++) {
          h.runtime.jobs.start(
            JobRequest.shell(
              shell,
              'sleep 60',
              cwd: h.workspace.path,
              environment: Platform.environment,
            ),
          );
        }
        expect(h.runtime.jobs.liveCount, maxLiveJobs);

        final text = await h.call(tool, input);

        final node = h.lastCall;
        expect(node['status'], 'failed');
        expect(node['envelope'], 'error');
        expect(node['reason'], tooManyJobsMessage);
        expect(text, contains(tooManyJobsMessage));
        expect(
          h.runtime.jobs.liveCount,
          maxLiveJobs,
          reason: 'nothing started',
        );
      },
      skip: skipBash(),
    );
  }
}
