# Tasks

## Test map

Platform-tagged tests are marked in the test name and run on the platform named:
- `[unix]` tests are skipped on Windows and run on the Linux (WSL) runner;
- `[windows]` tests run on native Windows only;
- `[slow]` tests (multi-GiB files) run in the group's verification and in `mise run check`, not in the inner loop.

Race and crash scenarios are made deterministic through the pause seams design D8 names (launch hooks, handoff hooks) and through a killed fixture process (`test/fixtures/`), as the session crash tests already do. They never rely on sleeps.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| tool-calls → Fixed versioned tool roster | Roster exposed as tool specs | test/tools/runtime_test.dart | specs list the eleven tools with versioned names and JSON schemas | green |
| tool-calls → Fixed versioned tool roster | Unknown tool | test/tools/runtime_test.dart | unknown tool settles failed with envelope error and a stored result | green |
| tool-calls → Arguments validated before anything runs | Valid arguments proceed | test/tools/runtime_test.dart | valid arguments reach the tool unchanged | green |
| tool-calls → Arguments validated before anything runs | Malformed or invalid arguments | test/tools/runtime_test.dart | malformed JSON and schema violations fail before any effect | green |
| tool-calls → Call node lifecycle in the tree | Successful call records its lifecycle | test/tools/runtime_test.dart | call node goes pending, running, settled with input and result reference | green |
| tool-calls → Call node lifecycle in the tree | Provider call id unsafe as a path segment | test/tools/runtime_test.dart | unsafe call id is keyed c- plus 12 hex of its SHA-256 | green |
| tool-calls → Call node lifecycle in the tree | Cancelled call still answers the model | test/tools/runtime_test.dart | cancelled call composes an error envelope with a handle | green |
| tool-calls → Call node lifecycle in the tree | Terminal status is final | test/tools/runtime_test.dart | late update to a settled call returns stale and appends nothing | green |
| tool-calls → Full output stored, composed only centrally | Large output stored whole, cut once | test/tools/central_truncation_test.dart | every tool's full bytes are stored and only the composer cuts | red |
| tool-calls → Full output stored, composed only centrally | Rewind between storing a result and settling | test/tools/runtime_test.dart | settle waits for re-registered descriptor after rewind and resolves in a fork | green |
| tool-calls → Full output stored, composed only centrally | Storage fails while output streams | test/tools/runtime_test.dart | storage failure records failed with accepted bytes and a handle-less envelope | green |
| tool-calls → Full output stored, composed only centrally | Journal unusable | test/tools/runtime_test.dart | broken writer fails the run and refuses further calls | green |
| tool-calls → Bounded parallel calls | Parallel calls overlap | test/tools/runtime_test.dart | two calls run concurrently and settle independently | green |
| tool-calls → Bounded parallel calls | Admission over the bound | test/tools/runtime_test.dart | 41st call over 8 running plus 32 queued fails tool busy | green |
| tool-calls → Turn cancellation | Ctrl-C cancels running and queued calls | test/tools/runtime_test.dart | cancelTurn cancels queued then running calls with reason user | green |
| tool-calls → Turn cancellation | Cancellation after settlement | test/tools/runtime_test.dart | cancelTurn after settle changes nothing | green |
| file-tools → Numbered read with block anchors | Read a 40-line file | test/tools/read_tool_test.dart | 40-line file anchors lines 1, 17 and 33 | green |
| file-tools → Numbered read with block anchors | Empty file | test/tools/read_tool_test.dart | empty file reads 0 lines ok | green |
| file-tools → Numbered read with block anchors | Path is not a readable text file | test/tools/read_tool_test.dart | missing, directory and NUL-in-8-KiB paths give their errors | green |
| file-tools → Anchor hash definition | Hash matches the reference vectors | test/tools/xxhash32_test.dart | xxHash32 matches published vectors; whitespace and CRLF variants hash equal | green |
| file-tools → Anchor hash definition | Streamed hash equals the definition | test/tools/block_hash_test.dart | streamed hash equals whole-block hash for mixed runs across chunk sizes | green |
| file-tools → Anchor hash definition | Content change in one block | test/tools/block_hash_test.dart | recorded vector block 17 changes only its own hash | green |
| file-tools → Read window snaps to blocks | Offset inside a block | test/tools/read_tool_test.dart | offset 20 limit 10 renders lines 17–32 of 100 | green |
| file-tools → Read window snaps to blocks | Offset beyond the file or oversized file | test/tools/read_tool_test.dart | offset past end and 70 MiB without limit are refused | green |
| file-tools → Read window snaps to blocks | One huge line | test/tools/read_tool_test.dart | [slow] 2 GiB single line reads whole with working set under 1 MiB | green |
| file-tools → Read window snaps to blocks | Newline-dense file | test/tools/read_tool_test.dart | [slow] 64 MiB of newlines reads with working set under 1 MiB at any limit | green |
| file-tools → Read window snaps to blocks | File changes during a read | test/tools/read_tool_test.dart | size or mtime change between passes fails file changed during read | green |
| file-tools → Anchored edit operations | Replace and insert in one edit | test/tools/edit_tool_test.dart | replace and insert apply on original numbering in one rename | green |
| file-tools → Anchored edit operations | Overlapping or out-of-range operations | test/tools/edit_tool_test.dart | overlapping and out-of-range ops are rejected unchanged | green |
| file-tools → Anchored edit operations | Edit that changes nothing | test/tools/edit_tool_test.dart | no-op edit is rejected and the file is not rewritten | green |
| file-tools → Stale and moved anchors rejected loudly | Line inserted above a block | test/tools/edit_tool_test.dart | moved block reports stale anchor with its new hash | green |
| file-tools → Stale and moved anchors rejected loudly | Several stale anchors reported together | test/tools/edit_tool_test.dart | every stale anchor is listed in one rejection | green |
| file-tools → Stale and moved anchors rejected loudly | Missing or malformed anchor | test/tools/edit_tool_test.dart | unnamed touched block and non-block anchor are rejected | green |
| file-tools → Edit preserves untouched bytes | CRLF file with one LF line | test/tools/edit_tool_test.dart | BOM and per-line endings survive an edit byte for byte | green |
| file-tools → Edit preserves untouched bytes | Invalid UTF-8 | test/tools/edit_tool_test.dart | invalid UTF-8 file is refused unchanged | green |
| file-tools → Edit preserves untouched bytes | File too large to edit | test/tools/edit_tool_test.dart | 20 MiB file is refused with the 16 MiB limit | green |
| file-tools → Atomic file replacement | Write a new file | test/tools/write_tool_test.dart | write creates missing directories and reports created | green |
| file-tools → Atomic file replacement | Rename fails | test/tools/write_tool_test.dart | failed rename leaves the target and no temporary file | green |
| workspace-search → Ripgrep resolution | rg found on PATH | test/tools/search_tools_test.dart | rg resolves from rgPath or PATH and passes --version | green |
| workspace-search → Ripgrep resolution | rg missing | test/tools/search_tools_test.dart | missing rg fails with the install hint naming the config path | green |
| workspace-search → Content search | Matches rendered per line | test/tools/search_tools_test.dart | grep renders path:line: text from --null output | green |
| workspace-search → Content search | No matches or invalid pattern | test/tools/search_tools_test.dart | rg exit 1 is ok and exit 2 is error with stderr | green |
| workspace-search → File finding | Find Dart tests | test/tools/search_tools_test.dart | find lists test files through rg --files | green |
| workspace-search → File finding | Missing search path | test/tools/search_tools_test.dart | missing search path is an error | green |
| workspace-search → Directory listing | List a directory | test/tools/search_tools_test.dart | ls sorts entries with / and @ suffixes | green |
| workspace-search → Directory listing | Not a directory | test/tools/search_tools_test.dart | ls on a file is an error | green |
| shell-tool → Real shell detection | Windows with Git Bash installed | test/shell/detect_test.dart | Git Bash beside git.exe wins and System32 bash is never chosen | green |
| shell-tool → Real shell detection | No usable shell | test/shell/detect_test.dart | no shell found fails attach-time detection with a hint | green |
| shell-tool → Command execution and status | Failing command | test/shell/bash_tool_test.dart | non-zero exit settles error with exit status in the summary | green |
| shell-tool → Command execution and status | Command reads stdin | test/shell/bash_tool_test.dart | stdin is closed at once so a reader sees EOF | green |
| shell-tool → Streamed output persistence | Interleaved streams kept in order | test/shell/bash_tool_test.dart | stdout, stderr and combined output keep arrival order | green |
| shell-tool → Streamed output persistence | Output larger than memory budgets | test/shell/bash_tool_test.dart | [slow] 1 GiB of output streams to disk with bounded memory | green |
| shell-tool → Credential-free child environment | API key not inherited | test/shell/env_test.dart | provider and KEHAI_ secret variables are absent in the child | green |
| shell-tool → Credential-free child environment | User passthrough exception | test/shell/env_test.dart | configured passthrough variable reaches the child | green |
| shell-tool → Foreground budget hands off to a job | Long command becomes a job | test/shell/bash_tool_test.dart | budget expiry settles partial with the job id while the job runs | green |
| shell-tool → Foreground budget hands off to a job | Budget out of range | test/shell/bash_tool_test.dart | timeout_s outside 1–600 fails validation | green |
| user-ask → Structured question | Choice answered | test/tools/ask_tool_test.dart | chosen answer returns {"choice":...} | green |
| user-ask → Structured question | Invalid question | test/tools/ask_tool_test.dart | more than 10 choices fails validation | green |
| user-ask → Answerer channel | Answer outside the choices | test/tools/ask_tool_test.dart | out-of-choice answer is re-asked with the allowed list | green |
| user-ask → Answerer channel | Headless session | test/tools/ask_tool_test.dart | no answerer settles error no user attached | green |
| user-ask → Answerer channel | Question cancelled | test/tools/ask_tool_test.dart | cancelled ask withdraws the prompt | green |
| tool-permissions → Built-in read-only allowlist | Read inside the workspace | test/permissions/gate_test.dart | workspace read is autoapproved | green |
| tool-permissions → Built-in read-only allowlist | Path escapes the workspace | test/permissions/gate_test.dart | path outside the workspace goes to the prompt | green |
| tool-permissions → Whole-command read-only proof | Plain read-only command | test/permissions/proof_test.dart | listed program with listed options inside the workspace is proven | green |
| tool-permissions → Whole-command read-only proof | Mixed or substituted command | test/permissions/proof_test.dart | separators, substitution, redirection, --pre and escapes are not proven | green |
| tool-permissions → Whole-command read-only proof | Path hidden in an option or the working directory | test/permissions/proof_test.dart | option operands, unlisted options and outside cwd are not proven | green |
| tool-permissions → Autoapproved commands run without shell startup | Repository startup script | test/permissions/direct_exec_test.dart | BASH_ENV script does not run for autoapproved pwd | green |
| tool-permissions → Autoapproved commands run without shell startup | Program shadowed in the workspace | test/permissions/direct_exec_test.dart | workspace cat on PATH is skipped or the call is prompted | green |
| tool-permissions → User-owned allowlist | Allowlisted jj status | test/permissions/gate_test.dart | user rule autoapproves jj status | green |
| tool-permissions → User-owned allowlist | Repository tries to allowlist | test/permissions/gate_test.dart | rules in repository files are ignored | green |
| tool-permissions → User-owned allowlist | Prefix rule with appended command | test/permissions/gate_test.dart | prefix rule does not approve an appended command | green |
| tool-permissions → Ask otherwise, or explicit yolo | User denies an edit | test/permissions/gate_test.dart | denied prompt settles denied without effect | green |
| tool-permissions → Ask otherwise, or explicit yolo | Yolo run | test/permissions/gate_test.dart | yolo approves without prompting except credential paths | green |
| tool-permissions → Ask otherwise, or explicit yolo | No answerer, not yolo | test/permissions/gate_test.dart | headless unapproved call settles denied | green |
| tool-permissions → Credential files never exposed | Read the credential file | test/permissions/credentials_test.dart | file tools refuse every auth.* in the Kehai home even under yolo | green |
| tool-permissions → Credential files never exposed | Grep that would cover the home | test/permissions/credentials_test.dart | grep over the home excludes auth.* and says so | green |
| tool-permissions → Credential files never exposed | Search during a credential write | test/permissions/credentials_test.dart | paused credential temp file is never matched or stored | green |
| tool-permissions → User configuration file | Missing configuration | test/config/config_test.dart | missing config.json uses defaults | green |
| tool-permissions → User configuration file | Invalid configuration | test/config/config_test.dart | unknown key or bad type refuses to start naming the path | green |
| job-supervisor → One job node shape | Shell job recorded | test/jobs/supervisor_test.dart | echo hi job node holds no pid and resolves its outputs | green |
| job-supervisor → One job node shape | Launch failure | test/jobs/supervisor_test.dart | vanished shell fails the job pending to failed and clears its launch record | green |
| job-supervisor → Bounded live jobs | Background jobs fill the bound | test/jobs/supervisor_test.dart | 17th live job is refused until one is cancelled | green |
| job-supervisor → Bounded live jobs | Bound frees on exit | test/jobs/supervisor_test.dart | exit frees the slot before the next admission | green |
| job-supervisor → Job deadline | Background job reaches its deadline | test/jobs/cancel_test.dart | deadline_s 2 cancels with reason deadline and keeps output | green |
| job-supervisor → Job deadline | Process ignores termination | test/jobs/cancel_test.dart | [unix] SIGTERM-trapping job is killed after the 2 s grace | green |
| job-supervisor → Cancellation terminates the process tree | Child processes die with the job | test/jobs/cancel_test.dart | [unix] cancel kills the shell and both children with cleanup confirmed | green |
| job-supervisor → Cancellation terminates the process tree | Cleanup cannot be proven | test/jobs/cancel_test.dart | [windows] tree kill records cleanup uncertain; surviving probe does too | green |
| job-supervisor → Bounded output drain | Escaped descendant holds the output pipe | test/jobs/drain_test.dart | [unix] held pipe is force-closed within the bound on exit, cancel and rewind | green |
| job-supervisor → Bounded output drain | Hook whose descendant holds the pipe | test/jobs/drain_test.dart | [unix] hook with held pipe meets its deadline and frees its slot | green |
| job-supervisor → Job tool | Follow a backgrounded command | test/tools/job_tool_test.dart | output snapshot is incomplete while running and wait returns exit | green |
| job-supervisor → Job tool | Unknown or finished job | test/tools/job_tool_test.dart | unknown id errors and cancel of a settled job is a no-op | green |
| job-supervisor → Generic rewind reconciliation | Rewind past a job's start | test/jobs/reconcile_test.dart | rewind before start kills the process and records the orphan | red |
| job-supervisor → Generic rewind reconciliation | Rewind restores a finished job as running | test/jobs/reconcile_test.dart | restored running node without runtime is cancelled rewound | red |
| job-supervisor → Generic rewind reconciliation | Rewind leaves a live job's start in place | test/jobs/reconcile_test.dart | rewind after start leaves the job running to its settle | red |
| job-supervisor → Stale callbacks rejected | Output arrives after rewind removed the job | test/jobs/reconcile_test.dart | exit after removal returns stale and appends nothing | red |
| job-supervisor → Stale callbacks rejected | Race between settle and cancel | test/jobs/reconcile_test.dart | concurrent exit and cancel record exactly one terminal state | red |
| job-supervisor → Stale callbacks rejected | Stale update from a live process | test/jobs/reconcile_test.dart | stale update for a live process terminates it and records the orphan | red |
| job-supervisor → Launch ownership | Rewind between pending and process start | test/jobs/launch_test.dart | rewind during launch kills the started process and never records running | green |
| job-supervisor → Launch ownership | Cancel while launching | test/jobs/launch_test.dart | cancel during launch records cancelled user and never running | green |
| job-supervisor → Resume finalizes tool and job nodes | Crash during a running command | test/jobs/resume_test.dart | killed engine reopens with call and job cancelled interrupted, not rerun | red |
| job-supervisor → Resume finalizes tool and job nodes | Crash before any output existed | test/jobs/resume_test.dart | pending call gets an interrupted result with complete false | red |
| job-supervisor → Resume finalizes tool and job nodes | Crash with output already spooled | test/jobs/resume_test.dart | spooled 300 lines are adopted complete false and the spool is gone | red |
| job-supervisor → Resume finalizes tool and job nodes | Fork child with live jobs | test/jobs/resume_test.dart | fork child finalizes its copy while the parent job runs on | red |
| job-supervisor → Resume finalizes tool and job nodes | Finalization append fails | test/jobs/resume_test.dart | storage error during finalization fails attach and admits nothing | red |
| job-supervisor → Crash-safe result handoff | Crash during the result handoff | test/jobs/handoff_test.dart | crash at each handoff step recovers every stream on attach | red |
| job-supervisor → Crash-safe result handoff | Crash during attach | test/jobs/handoff_test.dart | second attach registers and settles once | red |
| job-supervisor → Crash-safe result handoff | Rewind between registration and settling | test/jobs/handoff_test.dart | settle waits for re-registered descriptors after rewind | red |
| job-supervisor → Crash-safe result handoff | Rewind, then crash, during the handoff | test/jobs/handoff_test.dart | rewind then crash still settles with all three streams | red |
| job-supervisor → Crash-safe result handoff | Reopen right after settling | test/jobs/handoff_test.dart | attach only clears the leftover launch record | red |
| job-supervisor → Crash-safe result handoff | Intent cleanup for every owner state | test/jobs/handoff_test.dart | clear succeeds for settled, absent and superseded jobs and repeats harmlessly | red |
| job-supervisor → Crash-safe result handoff | Crash during the orphan transfer | test/jobs/handoff_test.dart | crash around the orphan record keeps the mapping and clears once | red |
| job-supervisor → Crash-safe result handoff | Rewind before the intent | test/jobs/handoff_test.dart | rewind before or during sealing lists spools under meta/orphans | red |
| job-supervisor → Crash-safe result handoff | Cancel or rewind a running job before its intent | test/jobs/handoff_test.dart | running job without intent is killed within the grace on cancel and rewind | red |
| job-supervisor → Crash-safe result handoff | Rewind between settling and clearing | test/jobs/handoff_test.dart | clear is refused while running and the settle repeats | red |
| job-supervisor → Crash-safe result handoff | Cancelled or timed-out output stays incomplete after a crash | test/jobs/handoff_test.dart | cancelled and deadline intents recover complete false | red |
| job-supervisor → Crash-safe result handoff | Fork child inherits a handoff intent | test/jobs/handoff_test.dart | inherited intent settles cancelled interrupted in the child only | red |
| job-supervisor → Crash-safe result handoff | Consumer during the handoff | test/jobs/handoff_test.dart | subscriber, job tool and fork see no unresolvable handle at each pause | red |
| hook-deadlines → User-configured pre-tool hooks | Hook sees the call | test/hooks/hooks_test.dart | hook stdin carries the call JSON | red |
| hook-deadlines → User-configured pre-tool hooks | Hooks in repository files | test/hooks/hooks_test.dart | hooks declared in the repository are never run | red |
| hook-deadlines → Hook outcome | Deny-class hook refuses | test/hooks/hooks_test.dart | exit 2 denies the call before any effect | red |
| hook-deadlines → Hook outcome | Optional hook crashes | test/hooks/hooks_test.dart | optional hook crash adds a diag line and the call runs | red |
| hook-deadlines → Engine-enforced hook deadline | Hung optional hook | test/hooks/hooks_test.dart | hung optional hook with timeout_ms 500 lets the call proceed within 3 s | red |
| hook-deadlines → Engine-enforced hook deadline | Hung deny-class hook | test/hooks/hooks_test.dart | hung deny-class hook denies within 3 s | red |
| hook-deadlines → Default hook deadline above shell startup | Startup measured and default checked | test/hooks/hook_default_test.dart | default deadline is at least 3x the recorded p95 and at least 2 s | red |
| hook-deadlines → Default hook deadline above shell startup | Invalid timeout configured | test/config/config_test.dart | invalid timeout_ms refuses to start | green |

## 1. ADR and architecture index

- [x] 1.1 Write `docs/adr/0010-tool-call-and-job-tree-layout.md` (`Status: accepted`, today's date, `Supersedes: none`). It records, per design D2, D4, D8, D9 and D11:
  - `body/calls/<key>` with the `c-` + 12-hex SHA-256 key derivation and the node fields;
  - the `jobs/<id>` shape, with no PIDs;
  - `meta/handoffs/<launch>` (launch record and intent) and `meta/orphans/<id>`, including `outputs/<launch>`, as rewind-exempt session records;
  - the guarded-append rule: ownership, intent and cleanup guards, the descriptor check and its retry;
  - the block-anchor contract (16-line blocks, xxHash32 seed 0, low 16 bits).

  Add its row to the in-force index in `openspec/architecture.md`, plus source-map rows for the hashline reference at its pinned revision. Verify with `mise run openspec:validate`, and confirm the index lists 0010.

## 2. Writer and result-store seams

- [x] 2.1 Write failing tests in `test/session/writer_guarded_test.dart`:
  - `applyGuarded(build)` appends the built record;
  - it returns `stale` when the ownership guard fails at the queue head, even with a rewind queued just before;
  - it returns `descriptors missing` (listing the handles) for any record referencing an unregistered handle;
  - a refusal appends nothing.

  Also write failing tests in `test/results/live_result_test.dart` for `ResultStore.begin(spoolName)`: `snapshot`, `seal` without a rename, `publish` (including the existing same-size rule) and `adopt`, all against real files.
- [x] 2.2 Implement `SessionWriter.applyGuarded` inside `decide` (`writer.dart:650`), with the result-reference scan, and the live writer in `lib/src/results/`. The journal format is unchanged. Verify that both test files pass, and that `mise run test -- test/session test/results` stays green.

## 3. User configuration

- [x] 3.1 Write failing `test/config/config_test.dart` rows: missing configuration, invalid configuration, invalid `timeout_ms`, plus extra cases for `rgPath`, `env.passthrough`, `allow` and `hooks` parsing. All read only `<kehai home>/config.json`.
- [x] 3.2 Implement `lib/src/config/` per design D15. The parser is strict: an unknown key, a wrong type or an out-of-range value refuses to start, and the message names the path. Verify that `config_test.dart` passes and flip its rows green.

## 4. Tool runtime and call lifecycle

- [x] 4.1 Write the failing `test/tools/runtime_test.dart` rows (tool-calls, except the central-truncation row), using a fake tool that exposes pause seams.
- [x] 4.2 Implement `lib/src/tools/runtime.dart`:
  - `ToolRuntime.attach`, the roster and `ToolSpec` schemas, and argument validation;
  - call keys, and the lifecycle through `applyGuarded` with the descriptor check;
  - the 8 running / 32 queued admission bound;
  - `cancelTurn`;
  - `composeStorageFailure` beside the composer.

  Verify that `runtime_test.dart` passes and flip its rows green.

## 5. Ask and the permission gate

- [x] 5.1 Write the failing `test/tools/ask_tool_test.dart` rows and the `test/permissions/gate_test.dart` rows (built-in allowlist, user rules, ask or yolo).
- [x] 5.2 Implement `lib/src/tools/ask.dart` with the answerer interface, and `lib/src/permissions/` gate ordering per design D13 (validate → hooks → credential refusal → builtin → user rules → yolo → prompt). Verify that both files pass and flip their rows green.
- [x] 5.3 Write the failing `test/permissions/proof_test.dart` rows. Then implement the tokenizer and the per-program option tables from design D13 in `lib/src/shell/proof.dart`, resolving operands from the effective `cwd`. Verify that `proof_test.dart` passes and flip its rows green.

## 6. File tools

- [x] 6.1 Write the failing `test/tools/xxhash32_test.dart` and `test/tools/block_hash_test.dart` rows. Record the published reference vectors, and a 40-line block-17 vector before and after the one-character change, in `test/fixtures/anchors/`.
- [x] 6.2 Implement `lib/src/tools/xxhash32.dart` and the streaming block hasher, with committed and speculative states, per design D4. Verify that both files pass at chunk sizes 1, 7 and 65536, and flip their rows green.
- [x] 6.3 Write the failing `test/tools/read_tool_test.dart` rows. Implement `read` as two passes per block, with the window snap, the 64 MiB rule, the change check and the binary sniff. Measure the working set through a counting reader seam. Verify that `read_tool_test.dart` passes (with `[slow]` included) and flip its rows green.
- [x] 6.4 Write the failing `test/tools/edit_tool_test.dart` and `test/tools/write_tool_test.dart` rows. Implement `edit` (op validation, anchor coverage, bottom-up apply, per-line endings, the BOM, the UTF-8 and 16 MiB refusals, the pre-rename recheck, `later anchors:`) and `write` with atomic replacement per design D5. Use an injected rename seam for the failing-rename row. Verify that both files pass and flip their rows green.
- [x] 6.5 Write the failing `test/permissions/credentials_test.dart` row *Read the credential file*. Implement the resolved-path `auth.*` refusal shared by the file tools. Verify that it passes, under `--yolo` too, and flip the row green.

## 7. Workspace search

- [x] 7.1 Write the failing `test/tools/search_tools_test.dart` rows, and the credential rows *Grep that would cover the home* and *Search during a credential write*. The second uses the credential store's existing pause seam to hold a temporary file open.
- [x] 7.2 Implement `rg` resolution at attach, `grep` (the `--null` transformer, the `auth.*` exclusion glob, `--no-config`, no `RIPGREP_CONFIG_PATH`), `find` and in-process `ls` per design D6. They run as shell-less jobs once group 9 lands; until then they run through the launcher directly. Verify that the search and credential rows pass and flip them green.

## 8. Shell detection, environment and direct execution

- [x] 8.1 Write the failing `test/shell/detect_test.dart` rows against an injected filesystem and `PATH` seam, plus one real detection test per platform. Then write the `test/shell/env_test.dart` rows and the `test/permissions/direct_exec_test.dart` rows.
- [x] 8.2 Implement `lib/src/shell/`:
  - detection per design D7: Git Bash beside `git.exe`, then `%ProgramFiles%`, never System32 `bash.exe`, then `pwsh`, then `powershell`; `bash` on POSIX;
  - the launcher: `setsid` on POSIX, stdin closed;
  - the credential-free environment filter with passthrough;
  - direct exec for autoapproved commands: absolute `PATH` entries outside the workspace, and the startup variables stripped.

  Verify that the three files pass on Windows and through the WSL runner, and flip their rows green.

## 9. Job supervisor and the bash and job tools

- [x] 9.1 Write the failing `test/jobs/supervisor_test.dart`, `test/jobs/launch_test.dart` and `test/jobs/cancel_test.dart` rows, using the launch pause seam.
- [x] 9.2 Implement `lib/src/jobs/supervisor.dart` per design D8 and D10:
  - the reservation, the launch record, `pending`, spool creation and `running`;
  - the 16-job live bound; the `launching`/`running`/`handoff` phases;
  - deadlines; cancellation through FFI `kill(-pgid)` with the 2 s grace and the probe, and `taskkill /T /F` on Windows.

  Verify that the three files pass and flip their rows green.
- [x] 9.3 Write the failing `test/jobs/drain_test.dart` rows (a fixture that `setsid`s a descendant holding stdout). Implement the bounded drain and the forced close. Verify that both rows pass through the WSL runner and flip them green.
- [x] 9.4 Write the failing `test/shell/bash_tool_test.dart` and `test/tools/job_tool_test.dart` rows. Implement `bash` (the foreground budget handing off to a job, `timeout_s` and `deadline_s` validation, streamed stdout/stderr/output with backpressure) and `job` (`status`, `wait`, `output` snapshot, `cancel`). Verify that both files pass (with `[slow]` included) and flip their rows green.
- [x] 9.5 Route group 7's `rg` invocations through the supervisor as shell-less jobs. Verify that `search_tools_test.dart` stays green.

## 10. Handoff, reconciler and resume

- [ ] 10.1 Write the failing `test/jobs/handoff_test.dart` rows, using handoff pause seams and a killed-engine fixture (`test/fixtures/run_job_then_wait.dart`).
- [ ] 10.2 Implement the five-step handoff, including the intent, cleanup and descriptor guards, the orphan transfer and the stale paths, per design D8. Verify that every non-attach row of `handoff_test.dart` passes.
- [ ] 10.3 Write the failing `test/jobs/reconcile_test.dart` and `test/jobs/resume_test.dart` rows. Implement the D11 reconciler (on rewind and `ResyncRequired`, level-triggered, serialized) and the D12 attach finalization (launch records first, the per-stream table, the foreign-session rule, live calls, the leftover count). Verify that `reconcile_test.dart`, `resume_test.dart` and all of `handoff_test.dart` pass, on Windows and through the WSL runner, and flip their rows green.

## 11. Hooks

- [ ] 11.1 Write the failing `test/hooks/hooks_test.dart` rows, using a hung fixture `test/fixtures/hang_forever.dart` and a crashing fixture.
- [ ] 11.2 Implement `lib/src/hooks/` per design D14: hooks come only from user config, run as supervisor jobs with call JSON on stdin, have optional and deny outcomes, and use the engine-enforced deadline. Verify that `hooks_test.dart` passes and flip its rows green.
- [ ] 11.3 Measure shell startup: 50 runs each of `bash -c true` (Git Bash on Windows, bash on Linux) and `pwsh -NoProfile -Command exit`. Record the p50/p95 values per platform in `docs/measurements/hook-startup.md`. Set the default hook deadline to the larger of 10 s and 3× the highest p95. Write and pass `test/hooks/hook_default_test.dart`, which parses that file, and flip its row green.

## 12. Integration and acceptance

- [ ] 12.1 Write `test/tools/central_truncation_test.dart`. For each of the eleven tools, it asserts that the stored bytes equal the producer's full output and that only `composeResult` shortens it. It also greps `lib/src/tools` and `lib/src/jobs` for tool-local cuts (`substring`, `take(`, `sublist` on output paths), with an explicit allowlist. Verify that it passes and flip its row green. This serves the exit criterion "Every tool result uses central truncation/full-result handles".
- [ ] 12.2 Agent acceptance run through the runtime on this repository, through a small driver `tool/tools_smoke.dart` with `--yolo` off and the answerer scripted:
  1. `read` then anchored `edit` of a scratch file;
  2. `bash` running `dart analyze`, `dart test test/smoke_test.dart` and `jj status` (or `git status` where jj is absent);
  3. `grep` and `find` over `lib/`;
  4. `ask` with two choices.

  Record the composed outputs in the task notes. Run it on Windows (Git Bash) and Linux (WSL). This serves the exit criterion "Read files, hash-anchor edit, run dart test/dart analyze/jj through bash, grep/find the tree, ask a structured question".
- [ ] 12.3 Hung-hook acceptance: with a user config whose hook runs `test/fixtures/hang_forever.dart` at `timeout_ms` 500, the 12.2 driver's next call proceeds within 3 s, and the hook job settles within the drain bound. This serves the exit criterion "A hung hook process (test fixture) cannot block turn progress".
- [ ] 12.4 Run `mise run check` and `mise run openspec:validate` on Windows, and `dart test` through the WSL runner. Verify that every test map row reads `green`.

## Workflow follow-up

- Pre-ship review, PR and merge follow `specwright-commit` and `specwright-pr` once all tasks are done.
- The three M1 exit criteria that this change serves are marked passed only at milestone close, from the 12.1–12.3 evidence.
