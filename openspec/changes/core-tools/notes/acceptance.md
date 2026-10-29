# Acceptance notes: core-tools group 12

Recorded by the group 12 implementer. Driver: `tool/tools_smoke.dart`
(`dart run tool/tools_smoke.dart [--hung-hook]`, run from the repository root).
Both modes drive a real `ToolRuntime` over this repository with `yolo: false`,
the real permission gate, and a scripted answerer. The answerer approves every
permission prompt and picks the last choice of a question. Every prompt is
printed as an `asked` line. The repository is not modified: the edited file,
the session and the Kehai home are in a scratch directory that the driver
deletes. Bodies longer than 8 lines are trimmed here (`... (body trimmed)`);
every call header, `asked` line, envelope line, `[diag ...]` line and timing is
kept as printed.

## 12.2 Agent acceptance run

Steps: `read` then anchored `edit` of a scratch file; `bash` with
`dart analyze`, `dart test test/smoke_test.dart` and the VCS status; `grep` and
`find` over `lib/`; `ask` with two choices.

Notes on the run:

- The VCS status is `jj status` when `jj` is on `PATH` and the checkout has a
  `.jj` directory, else `git status --short`. This checkout is a git repository
  with no jj repository (`jj status` answers `There is no jj repo in "."`), so
  both platforms ran `git status --short`.
- On WSL the working tree is a scratch copy without VCS metadata, so the copy
  was given a throwaway `git init` and commit before the run (in the temporary
  copy of the runner script only). Its `git status --short` is therefore empty.
- The editing target is outside the workspace, so `read` of it also prompted.
  The gate prompted for that `read`, the `edit` and the three `bash` calls.
  `grep` and `find` are read-only inside the workspace and were allowed
  without a prompt. `ask` went to the answerer as a `question`.
- Wiring defect found by this run and fixed: `ask` was not in the runtime's
  default tool map, so the first run answered `[ask error] tool unavailable`.
  `lib/src/tools/runtime.dart` now registers `AskTool` by default (test:
  `test/tools/runtime_test.dart`, "ask is wired in by default; headless it
  settles no user attached").
- Wiring gap found at review and fixed after these runs: `read_more` and
  `search_result` were in the roster but had no runtime tool, so a call
  answered `not available`. They are now `ReadMoreTool` and
  `SearchResultTool`. Each stores the composer's page and answers with it
  unchanged. The writer's descriptor check now counts only `{handle, complete}`
  references, so a call input naming a handle is recorded even when the handle
  is unknown (test: `test/tools/runtime_test.dart`, "read_more and
  search_result answer with the composer page of a handle"). The smoke driver
  runs below predate this and do not call them.

### Windows 11 (Git Bash, `mise exec -- dart run tool/tools_smoke.dart`): PASSED

```text
platform: windows
repository: F:\Dev\Orca\Workspace\kehai
shell: git-bash; yolo: off; hooks: 0

=== call smoke-1 read {"path":"C:\\Users\\bgshi\\AppData\\Local\\Temp\\kehai_tools_smoke_eb5016ab\\scratch.txt"}
asked  permission read {"path":"C:\\Users\\bgshi\\AppData\\Local\\Temp\\kehai_tools_smoke_eb5016ab\\scratch.txt"} -> answered allow
[read ok] C:\Users\bgshi\AppData\Local\Temp\kehai_tools_smoke_eb5016ab\scratch.txt: 20 lines, LF
1#0B10:line 1
2:line 2
3:line 3
4:line 4
5:line 5
6:line 6
7:line 7
8:line 8
... (body trimmed)
--- 432 ms
check ok   read settles ok
check ok   read shows the anchor of block 1 (1#0B10)

=== call smoke-2 edit {"path":"C:\\Users\\bgshi\\AppData\\Local\\Temp\\kehai_tools_smoke_eb5016ab\\scratch.txt","anchors":["1#0B10","17#9FB0"],"ops":[{"op":"replace","start":3,"end":3,"text":"line 3 (edited)"}]}
asked  permission edit {"path":"C:\\Users\\bgshi\\AppData\\Local\\Temp\\kehai_tools_smoke_eb5016ab\\scratch.txt","anchors":["1#0B10","17#9FB0"],"ops":[{"op":"replace","start":3,"end":3,"text":"line 3 (edited)"}]} -> answered al...
[edit ok] edited C:\Users\bgshi\AppData\Local\Temp\kehai_tools_smoke_eb5016ab\scratch.txt: 1 operation, 20 → 20 lines
1#D367:line 1
2:line 2
3:line 3 (edited)
4:line 4
5:line 5
6:line 6
7:line 7
8:line 8
... (body trimmed)
--- 50 ms
check ok   edit settles ok
check ok   the scratch file changed on disk

=== call smoke-3 bash {"command":"dart analyze","timeout_s":300}
asked  permission bash {"command":"dart analyze","timeout_s":300} -> answered allow
[bash ok] exit 0 (git-bash)
Analyzing kehai...
No issues found!
--- 4371 ms
check ok   dart analyze settles ok

=== call smoke-4 bash {"command":"dart test test/smoke_test.dart","timeout_s":300}
asked  permission bash {"command":"dart test test/smoke_test.dart","timeout_s":300} -> answered allow
[bash ok] exit 0 (git-bash)
00:00 +0: loading test/smoke_test.dart
00:00 +0: package loads
00:00 +1: All tests passed!
--- 3076 ms
check ok   dart test settles ok

=== call smoke-5 bash {"command":"git status --short","timeout_s":60}
asked  permission bash {"command":"git status --short","timeout_s":60} -> answered allow
[bash ok] exit 0 (git-bash)
 M lib/src/tools/runtime.dart
 M test/jobs/cancel_test.dart
 M test/tools/runtime_test.dart
?? test/tools/central_truncation_test.dart
?? tool/tools_smoke.dart
--- 1210 ms
check ok   git status --short settles ok

=== call smoke-6 grep {"pattern":"composeResult","path":"lib"}
[grep ok] 6 matches in 3 files (rg 15.2.0)
lib/src/results/composer.dart:103: Future<String> composeResult(
lib/src/results/composer.dart:116:   await composeResultTo(
lib/src/results/composer.dart:132: /// Like [composeResult], but writes to [sink] as lines are scanned.
lib/src/results/composer.dart:135: Future<void> composeResultTo(
lib/src/results/reader.dart:33:   return await composeResult(
lib/src/tools/runtime.dart:694:     final text = await composeResult(
--- 108 ms
check ok   grep settles ok
check ok   grep finds composer

=== call smoke-7 find {"glob":"src/tools/*.dart","path":"lib"}
[find ok] 18 files
lib/src/tools/xxhash32.dart
lib/src/tools/write.dart
lib/src/tools/tool.dart
lib/src/tools/search.dart
lib/src/tools/schema.dart
lib/src/tools/runtime.dart
lib/src/tools/roster.dart
lib/src/tools/read.dart
... (body trimmed)
--- 142 ms
check ok   find settles ok
check ok   find lists the roster

=== call smoke-8 ask {"question":"Which one do you want?","choices":["first","second"]}
asked  question ask {"question":"Which one do you want?","choices":["first","second"]} -> answered second
[ask ok] answered
{"choice":"second"}
--- 15 ms
check ok   ask settles ok
check ok   ask returns the second choice
check ok   the gate prompted for the edit
check ok   the question reached the answerer
PASSED
```

### Linux (WSL Ubuntu, ext4 copy, `dart run tool/tools_smoke.dart`): PASSED

```text
platform: linux
repository: /home/bgshi/kehai-run-TJhEUy/tree
shell: bash; yolo: off; hooks: 0

=== call smoke-1 read {"path":"/home/bgshi/kehai-run-TJhEUy/tmp/kehai_tools_smoke_PZJZHU/scratch.txt"}
asked  permission read {"path":"/home/bgshi/kehai-run-TJhEUy/tmp/kehai_tools_smoke_PZJZHU/scratch.txt"} -> answered allow
[read ok] /home/bgshi/kehai-run-TJhEUy/tmp/kehai_tools_smoke_PZJZHU/scratch.txt: 20 lines, LF
1#0B10:line 1
2:line 2
3:line 3
4:line 4
5:line 5
6:line 6
7:line 7
8:line 8
... (body trimmed)
--- 72 ms
check ok   read settles ok
check ok   read shows the anchor of block 1 (1#0B10)

=== call smoke-2 edit {"path":"/home/bgshi/kehai-run-TJhEUy/tmp/kehai_tools_smoke_PZJZHU/scratch.txt","anchors":["1#0B10","17#9FB0"],"ops":[{"op":"replace","start":3,"end":3,"text":"line 3 (edited)"}]}
asked  permission edit {"path":"/home/bgshi/kehai-run-TJhEUy/tmp/kehai_tools_smoke_PZJZHU/scratch.txt","anchors":["1#0B10","17#9FB0"],"ops":[{"op":"replace","start":3,"end":3,"text":"line 3 (edited)"}]} -> answered allow
[edit ok] edited /home/bgshi/kehai-run-TJhEUy/tmp/kehai_tools_smoke_PZJZHU/scratch.txt: 1 operation, 20 → 20 lines
1#D367:line 1
2:line 2
3:line 3 (edited)
4:line 4
5:line 5
6:line 6
7:line 7
8:line 8
... (body trimmed)
--- 35 ms
check ok   edit settles ok
check ok   the scratch file changed on disk

=== call smoke-3 bash {"command":"dart analyze","timeout_s":300}
asked  permission bash {"command":"dart analyze","timeout_s":300} -> answered allow
[bash ok] exit 0 (bash)
Analyzing tree...
No issues found!
--- 2195 ms
check ok   dart analyze settles ok

=== call smoke-4 bash {"command":"dart test test/smoke_test.dart","timeout_s":300}
asked  permission bash {"command":"dart test test/smoke_test.dart","timeout_s":300} -> answered allow
[bash ok] exit 0 (bash)
00:00 +0: loading test/smoke_test.dart
00:00 +0: package loads
00:00 +1: All tests passed!
--- 4215 ms
check ok   dart test settles ok

=== call smoke-5 bash {"command":"git status --short","timeout_s":60}
asked  permission bash {"command":"git status --short","timeout_s":60} -> answered allow
[bash ok] exit 0 (bash)
--- 57 ms
check ok   git status --short settles ok

=== call smoke-6 grep {"pattern":"composeResult","path":"lib"}
[grep ok] 6 matches in 3 files (rg 14.1.0)
lib/src/results/reader.dart:33:   return await composeResult(
lib/src/results/composer.dart:103: Future<String> composeResult(
lib/src/results/composer.dart:116:   await composeResultTo(
lib/src/results/composer.dart:132: /// Like [composeResult], but writes to [sink] as lines are scanned.
lib/src/results/composer.dart:135: Future<void> composeResultTo(
lib/src/tools/runtime.dart:694:     final text = await composeResult(
--- 67 ms
check ok   grep settles ok
check ok   grep finds composer

=== call smoke-7 find {"glob":"src/tools/*.dart","path":"lib"}
[find ok] 18 files
lib/src/tools/block_hash.dart
lib/src/tools/xxhash32.dart
lib/src/tools/schema.dart
lib/src/tools/line_segmenter.dart
lib/src/tools/glob_match.dart
lib/src/tools/bash.dart
lib/src/tools/child_env.dart
lib/src/tools/runtime.dart
... (body trimmed)
--- 62 ms
check ok   find settles ok
check ok   find lists the roster

=== call smoke-8 ask {"question":"Which one do you want?","choices":["first","second"]}
asked  question ask {"question":"Which one do you want?","choices":["first","second"]} -> answered second
[ask ok] answered
{"choice":"second"}
--- 20 ms
check ok   ask settles ok
check ok   ask returns the second choice
check ok   the gate prompted for the edit
check ok   the question reached the answerer
PASSED
```

## 12.3 Hung-hook acceptance

User config: one hook, `slow`, policy `optional`, `timeout_ms` 500, on tool
`read`, with argv `dart test/fixtures/hang_forever.dart <pidfile>` (the fixture
never exits and ignores SIGTERM). The driver (`--hung-hook`) then runs the
next call (`ls lib`) and waits for the hook job to settle.

Criteria and how they are measured:

- The call that carries the hook proceeds within 3 s (`_proceedBound`): wall
  time of `runtime.run` for the `read`.
- The next call proceeds within 3 s: wall time of the `ls`.
- The hook job settles within the drain bound: the time until
  `runtime.jobs.liveCount` is 0, measured from the start of the first call, is
  at most the hook deadline plus the drain bound, 500 ms + 5 s. The 5 s is
  D8's 2 s drain, 2 s more, and D10's 1 s probe. Then the job node must read
  `cancelled` with reason `deadline`, and the fixture's pid (written by the
  fixture) must be gone.

### Windows (Git Bash): PASSED (this run)

```text
platform: windows
repository: F:\Dev\Orca\Workspace\kehai
shell: git-bash; yolo: off; hooks: 1

=== call smoke-1 read {"path":"pubspec.yaml"}
[read ok] pubspec.yaml: 20 lines, CRLF
1#D254:name: kehai
2:description: Kehai headless coding-agent engine.
3:version: 0.0.1
4:publish_to: none
5:
6:environment:
7:  sdk: ^3.13.0
8:dependencies:
9:  args: ^2.7.0
10:  crypto: ^3.0.8
11:  ffi: ^2.2.0
12:  path: ^1.9.1
13:  pointycastle: ^4.0.0
14:  win32: ^6.4.0
15:dev_dependencies:
16:  lints: ^6.1.0
17#6C00:  test: ^1.33.0
18:
19:executables:
20:  kehai:
[diag hook:slow] timed out after 500 ms; ignored
--- 2790 ms
check ok   the call proceeded
check ok   the hook is reported as timed out and ignored
check ok   the hung hook call took 2790 ms (bound 3000 ms)

=== call smoke-2 ls {"path":"lib"}
[ls ok] lib: 2 entries
kehai.dart
src/
--- 23 ms
check ok   the next call proceeded
check ok   the next call took 23 ms (bound 3000 ms)

hook job settled 2815 ms after the first call started (deadline 500 ms, bound 5500 ms)
check ok   no job is live
check ok   the hook job settled within the drain bound
hook job node: kind hook, state cancelled, reason deadline, cleanup uncertain: descendants not verifiable
check ok   the hook job ended cancelled by its deadline
hook process 18656 alive after settle: false
check ok   the hook process tree is gone
PASSED
```

Windows timings over the runs made while developing the driver (the 3 s bound
is for the call that carries the hook):

| Run | Hook call | Hook job settled after |
| --- | --- | --- |
| 1 (recorded above) | 2790 ms | 2815 ms |
| 2 | 1730 ms | 1756 ms |
| 3 | 1465 ms | 1491 ms |
| 4 | 3175 ms (check FAIL) | 3201 ms |

Run 4 exceeded 3 s. The job itself ran from `started` to `ended` in 1.14 s as
in every run (500 ms deadline plus the tree kill); the extra time was before
the process started: in a probe, the gap between the job reservation and
`afterStart` varied from 20 ms to 1.2 s, and the journal appends before it
stalled by up to 1.1 s on this host, which was loaded by other agents' work.
The stage waits at most `timeout_ms` + the 2 s kill grace (2.5 s) from the
moment the hook job was started, so a stall before that point is added on top.
Nothing in the engine is wrong; the 3 s criterion has a margin of 0.5 s on
Linux and around 1.5 s in a quiet Windows run, and a loaded Windows host can
exceed it. See the report for the decision this leaves to the orchestrator.

### Linux (WSL): PASSED

The hook ignores SIGTERM, so the supervisor waits the 2 s grace, then
SIGKILL: 500 ms + 2 s. Two WSL runs gave 2581 ms and 2581 ms for the hook
call, 2627 ms and 2626 ms until the job settled, cleanup `confirmed`, and the
fixture's pid gone.

```text
platform: linux
repository: /home/bgshi/kehai-run-O49A52/tree
shell: bash; yolo: off; hooks: 1

=== call smoke-1 read {"path":"pubspec.yaml"}
[read ok] pubspec.yaml: 20 lines, CRLF
1#D254:name: kehai
2:description: Kehai headless coding-agent engine.
3:version: 0.0.1
4:publish_to: none
5:
6:environment:
7:  sdk: ^3.13.0
8:dependencies:
9:  args: ^2.7.0
10:  crypto: ^3.0.8
11:  ffi: ^2.2.0
12:  path: ^1.9.1
13:  pointycastle: ^4.0.0
14:  win32: ^6.4.0
15:dev_dependencies:
16:  lints: ^6.1.0
17#6C00:  test: ^1.33.0
18:
19:executables:
20:  kehai:
[diag hook:slow] timed out after 500 ms; ignored
--- 2581 ms
check ok   the call proceeded
check ok   the hook is reported as timed out and ignored
check ok   the hung hook call took 2581 ms (bound 3000 ms)

=== call smoke-2 ls {"path":"lib"}
[ls ok] lib: 2 entries
kehai.dart
src/
--- 22 ms
check ok   the next call proceeded
check ok   the next call took 22 ms (bound 3000 ms)

hook job settled 2627 ms after the first call started (deadline 500 ms, bound 5500 ms)
check ok   no job is live
check ok   the hook job settled within the drain bound
hook job node: kind hook, state cancelled, reason deadline, cleanup confirmed, started 2026-10-29T19:13:27.231710Z, ended 2026-10-29T19:13:29.770322Z
check ok   the hook job ended cancelled by its deadline
hook process 227722 alive after settle: false
check ok   the hook process tree is gone
PASSED
```
