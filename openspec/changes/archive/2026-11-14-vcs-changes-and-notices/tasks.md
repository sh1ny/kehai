# Tasks

## Test map

`red` means new or changed behaviour awaiting executed green evidence. `green` rows ride along unchanged inside the MODIFIED turn-perception requirement and already pass; their task re-runs them. Files marked **new** are planned. Deadline, cancellation and held-rename cases use in-process fakes with controllable completion (a fake process runner, a held atomic-write rename, explicit barriers); no sleeps or wall-clock assertions (#28). Real `git`/`jj` process tests assert outcomes only and carry the `slow` tag when they spawn many processes. Run Dart tests through the official Dart MCP tool, one file at a time locally; the full suite runs on CI (ubuntu + windows).

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| vcs-observation → Backend detection prefers jj | Colocated repository | `test/workspace/vcs_backend_test.dart` (new) | colocated .jj and .git selects jj | green |
| vcs-observation → Backend detection prefers jj | Plain git repository | `test/workspace/vcs_backend_test.dart` (new) | .git without .jj selects git | green |
| vcs-observation → Backend detection prefers jj | No repository | `test/workspace/vcs_backend_test.dart` (new) | no repository reads unavailable (no repository) | green |
| vcs-observation → Backend detection prefers jj | Invalid backend setting | `test/config/config_test.dart` | invalid vcs.backend refuses configuration | green |
| vcs-observation → Backend detection prefers jj | Observation disabled | `test/workspace/vcs_backend_test.dart` (new) | vcs.backend none starts no process and reads disabled | green |
| vcs-observation → Backend detection prefers jj | Observation disabled | `test/loop/attribution_test.dart` | backend none disables both sections without a baseline | green |
| vcs-observation → Backend detection prefers jj | Observation disabled | `test/loop/attribution_test.dart` | backend none disables both sections and preserves admitted provenance | green |
| vcs-observation → Working-copy state is reported | Dirty jj working copy | `test/workspace/vcs_real_test.dart` (new) | real jj working copy renders change, description, parent and counts | green |
| vcs-observation → Working-copy state is reported | Many changed paths | `test/loop/sensorium_composition_test.dart` | vcs section lists 12 paths then … +N more | green |
| vcs-observation → Working-copy state is reported | Many changed paths through fresh admission and stale carry | `test/loop/attribution_test.dart` | display-limited omitted paths retain exact VCS counts | green |
| vcs-observation → Working-copy state is reported | Collector-capped path preview through fresh admission and stale carry | `test/loop/attribution_test.dart` | display-limited collector path preview retain exact VCS counts | green |
| vcs-observation → Working-copy state is reported | Conflicted files through fresh admission and stale carry | `test/loop/attribution_test.dart` | display-limited omitted conflicts retain exact VCS counts | green |
| vcs-observation → Working-copy state is reported | Clipped path label with exact counts | `test/loop/attribution_test.dart` | display-limited clipped path retain exact VCS counts | green |
| vcs-observation → Working-copy state is reported | Clipped conflict label with exact counts | `test/loop/attribution_test.dart` | display-limited clipped conflict retain exact VCS counts | green |
| vcs-observation → Working-copy state is reported | Conflicted files | `test/workspace/vcs_collector_test.dart` (new) | conflicted paths are listed for jj and git | green |
| vcs-observation → Working-copy state is reported | Unborn git branch | `test/workspace/vcs_real_test.dart` (new) | real git unborn branch reports branch without HEAD id | green |
| vcs-observation → Collection is bounded by a deadline | Collection within deadline | `test/workspace/vcs_collector_test.dart` (new) | completed fake collection returns available | green |
| vcs-observation → Collection is bounded by a deadline | Deadline exceeded with an earlier observation | `test/workspace/vcs_collector_test.dart` (new) | held fake process at deadline yields stale with timeout and earlier value | green |
| vcs-observation → Collection is bounded by a deadline | Deadline exceeded without an earlier observation | `test/workspace/vcs_collector_test.dart` (new) | held fake process at deadline yields unavailable (timeout) | green |
| vcs-observation → Collection is bounded by a deadline | Invalid deadline | `test/config/config_test.dart` | sensorium.collectorDeadlineMs outside 100–10000 refuses configuration | green |
| vcs-observation → Failures are named, never clean | jj not installed | `test/workspace/vcs_collector_test.dart` (new) | missing executable reads unavailable (jj not found) and (git not found) | green |
| vcs-observation → Failures are named, never clean | Command fails | `test/workspace/vcs_collector_test.dart` (new) | non-zero exit reads failed with clipped stderr reason | green |
| vcs-observation → Failures are named, never clean | Command fails | `test/loop/attribution_test.dart` (new) | typed failure ignores repository stderr: eight misleading reason variants | green |
| vcs-observation → Failures are named, never clean | Command fails | `test/loop/attribution_test.dart` (new) | stderr cannot invalidate the carried comparison baseline | green |
| vcs-observation → Failures are named, never clean | Output exceeds the read bound | `test/workspace/vcs_collector_test.dart` (new) | oversized output marks partial, never clean | green |
| vcs-observation → Failures are named, never clean | Output exceeds the read bound | `test/workspace/vcs_collector_test.dart` (new) | git and jj truncated comparison remains partial after collection | green |
| vcs-observation → Failures are named, never clean | Output exceeds the read bound repeatedly on a native process | `test/workspace/vcs_real_test.dart` | completed truncated native collections do not exhaust cleanup slots | green |
| vcs-observation → Failures are named, never clean | Status-only truncation | `test/loop/attribution_test.dart` (new) | status-only truncation does not make a complete comparison partial | green |
| vcs-observation → Observation does not alter the user's repository state | Git index untouched | `test/workspace/vcs_real_test.dart` (new) | git collection leaves .git/index bytes and refs unchanged | green |
| vcs-observation → Observation does not alter the user's repository state | Concurrent user git command | `test/workspace/vcs_real_test.dart` (new) | collection takes no index.lock and user git add succeeds | green |
| vcs-observation → Observation does not alter the user's repository state | Configured clean filter hangs | `test/workspace/vcs_collector_test.dart` (new) | hanging clean filter is bounded by the deadline and terminated | green |
| vcs-observation → Observation does not alter the user's repository state | Remote-touching subcommands never run | `test/workspace/vcs_collector_test.dart` (new) | recorded argv stays within the allowlist for jj and git | green |
| vcs-observation → Collections in one engine are serialized | Status during a request build | `test/workspace/vcs_collector_test.dart` (new) | status preview waits on the engine lock behind a build | green |
| vcs-observation → Collections in one engine are serialized | Wait exceeds the deadline | `test/workspace/vcs_collector_test.dart` (new) | lock wait past deadline returns stale without starting a process | green |
| vcs-observation → Collections in one engine are serialized | Ignored file becomes tracked | `test/workspace/vcs_real_test.dart` (new) | fresh private index sees a force-added ignored file | green |
| vcs-observation → Collections in one engine are serialized | File untracked by the user | `test/workspace/vcs_real_test.dart` (new) | fresh private index follows git rm --cached | green |
| vcs-observation → Timed-out collections are isolated | Termination cannot be verified | `test/workspace/vcs_cleanup_test.dart` (new) | unverifiable termination holds its slot until engine exit | green |
| vcs-observation → Timed-out collections are isolated | Termination stalls | `test/workspace/vcs_cleanup_test.dart` (new) | stalled termination returns at deadline and keeps the slot | green |
| vcs-observation → Timed-out collections are isolated | Cleanup limit reached with git | `test/workspace/vcs_cleanup_test.dart` (new) | 16 held git slots read cleanup pending and resume after release | green |
| vcs-observation → Timed-out collections are isolated | Repeated jj timeouts with termination that never completes | `test/workspace/vcs_cleanup_test.dart` (new) | 100 jj timeouts never exceed 16 slots and every build meets its deadline | green |
| vcs-observation → Repository text cannot forge block structure | Description with a fake closing tag | `test/loop/sensorium_test.dart` | vcs description with closing tag is escaped and indented | green |
| vcs-observation → Repository text cannot forge block structure | Path with a newline | `test/loop/sensorium_test.dart` | path with newline renders escaped on one row | green |
| workspace-change-attribution → Content-addressed baseline per admitted request | Baseline recorded on admission | `test/loop/attribution_test.dart` (new) | admitted step metadata carries backend, id, seq and jobsLive | green |
| workspace-change-attribution → Content-addressed baseline per admitted request | Collection failed | `test/loop/attribution_test.dart` (new) | failed collection carries the previous baseline forward | green |
| workspace-change-attribution → Content-addressed baseline per admitted request | Long run of failures | `test/loop/attribution_test.dart` (new) | 300 failed collections still find the carried baseline | green |
| workspace-change-attribution → Changes since the last baseline | One file edited | `test/workspace/vcs_real_test.dart` (new) | real jj and git diff report one edited file with counts | green |
| workspace-change-attribution → Changes since the last baseline | Nothing changed | `test/loop/attribution_test.dart` (new) | unchanged baseline renders changes none | green |
| workspace-change-attribution → Changes since the last baseline | First request of a session | `test/loop/attribution_test.dart` (new) | first request reads unavailable (no baseline) | green |
| workspace-change-attribution → Changes since the last baseline | Baseline lost | `test/loop/attribution_test.dart` (new) | unresolvable baseline id reads baseline lost and raises baseline_reset | green |
| workspace-change-attribution → Changes since the last baseline | Backend changed | `test/loop/attribution_test.dart` (new) | backend switch reads baseline lost | green |
| workspace-change-attribution → Changes since the last baseline | No admitted observation within the lookup bound | `test/loop/attribution_test.dart` (new) | 256 non-admitted steps exhaust the lookup and reset | green |
| workspace-change-attribution → Attribution interval | Edit in response to the baseline request | `test/loop/attribution_test.dart` (new) | edit linked from the baseline step output is in the interval | green |
| workspace-change-attribution → Attribution interval | Shell call in response to the baseline request | `test/loop/attribution_test.dart` (new) | bash in the baseline step makes rows unknown | green |
| workspace-change-attribution → Attribution interval | Hook run in the interval | `test/loop/attribution_test.dart` (new) | call with recorded hook run makes rows unknown | green |
| workspace-change-attribution → Attribution interval | Calls before the baseline | `test/loop/attribution_test.dart` (new) | calls before the capture turn are ignored | green |
| workspace-change-attribution → Attribution from recorded provenance | Agent edit | `test/loop/attribution_test.dart` (new) | matching pre and post hashes read by agent | green |
| workspace-change-attribution → Attribution from recorded provenance | User edit with no agent activity | `test/loop/attribution_test.dart` (new) | change with no interval activity reads by user and raises user_edits | green |
| workspace-change-attribution → Attribution from recorded provenance | File rewritten around the capture | `test/loop/attribution_test.dart` (new) | pre/post hash mismatch reads unknown | green |
| workspace-change-attribution → Attribution from recorded provenance | Content differs from the agent's effect | `test/loop/attribution_test.dart` (new) | bytes differing from effect read unknown | green |
| workspace-change-attribution → Attribution from recorded provenance | Change during a shell command | `test/loop/attribution_test.dart` (new) | interval bash makes unmatched rows unknown | green |
| workspace-change-attribution → Attribution from recorded provenance | Line-ending conversion on Windows | `test/workspace/vcs_real_test.dart` (new) | autocrlf true agent write still reads by agent | green |
| workspace-change-attribution → Successful effects have durable order | Concurrent same-path effects | `test/tools/mutation_provenance_test.dart` (new) | reversed completion stores increasing effect order and restored older bytes cannot claim agent | green |
| workspace-change-attribution → Successful effects have durable order | Delayed effect commit on a shared target | `test/tools/mutation_provenance_test.dart` (new) | delayed effect keeps the resolved-target slot and restored older bytes cannot claim agent | green |
| workspace-change-attribution → Case-variant targets are uncertain | Case-variant mutation targets | `test/tools/mutation_provenance_test.dart` (new) | case-variant writes followed by restoring earlier bytes read unknown | green |
| workspace-change-attribution → Case-variant targets are uncertain | Case-variant row spelling | `test/loop/attribution_test.dart` (new) | differently cased row cannot claim agent or user even on a case-sensitive filesystem | green |
| workspace-change-attribution → Unresolved mutations are uncertain provenance | Cancelled during rename | `test/tools/cancelled_mutation_test.dart` | cancelled write with held rename reads unknown | green |
| workspace-change-attribution → Unresolved mutations are uncertain provenance | Restart after rename | `test/loop/attribution_test.dart` (new) | interrupted write after restart reads unknown | green |
| workspace-change-attribution → Unresolved mutations are uncertain provenance | Later successful edit of the same path | `test/loop/attribution_test.dart` (new) | same-turn later successful effect proves agent after an unresolved earlier write | green |
| workspace-change-attribution → Unresolved attempts retain an effect-order boundary | Boundary recorded before mutation | `test/tools/mutation_provenance_test.dart` (new) | target boundary includes earlier durable effects before rename | green |
| workspace-change-attribution → Unresolved attempts retain an effect-order boundary | Unresolved write after a successful effect | `test/tools/cancelled_mutation_test.dart` | later cancelled rename prevents older effect proof after user restoration | green |
| workspace-change-attribution → Unresolved attempts retain an effect-order boundary | Legacy unresolved target without a boundary | `test/loop/attribution_test.dart` (new) | missing target boundary cannot claim agent | green |
| workspace-change-attribution → Mutation targets are recorded before mutation | Successful write through a symlink | `test/tools/mutation_provenance_test.dart` (new) | target records the resolved symlink destination | green |
| workspace-change-attribution → Mutation targets are recorded before mutation | Interrupted write through a symlink | `test/tools/mutation_provenance_test.dart` (new) | target is recorded before the rename starts | green |
| workspace-change-attribution → Mutation targets are recorded before mutation | Symlink retargeted before resume | `test/tools/mutation_provenance_test.dart` (new) | retargeted symlink does not redirect provenance | green |
| workspace-change-attribution → Mutation targets are recorded before mutation | Symlinked parent directory | `test/tools/mutation_provenance_test.dart` (new) | symlinked parent resolves to the real repo path | green |
| workspace-change-attribution → Mutation targets are recorded before mutation | Call without a recorded target | `test/loop/attribution_test.dart` (new) | edit without target counts as process-running activity | green |
| workspace-change-attribution → Open mutations stay uncertain across baselines | Rename finishes after the next baseline | `test/tools/cancelled_mutation_test.dart` | rename released after next baseline reads unknown without user_edits | green |
| workspace-change-attribution → Open mutations stay uncertain across baselines | Open mutation still pending | `test/tools/cancelled_mutation_test.dart` | unquiesced call keeps its target unknown | green |
| workspace-change-attribution → Open mutations stay uncertain across baselines | Engine dies with an open mutation | `test/jobs/recovery_mutation_test.dart` | resume quiesces a terminal cancelled write at the resume turn; resume quiesces a terminal cancelled edit at the resume turn | green |
| workspace-change-attribution → Open mutations stay uncertain across baselines | Late work fails without changing the file | `test/tools/cancelled_mutation_test.dart` | failed late work closes the target | green |
| workspace-change-attribution → Late finish records cannot touch removed or replaced calls | Call removed by rewind before the late finish | `test/tools/cancelled_mutation_test.dart` | late finish after rewind creates no call node and leaves an orphan record | green |
| workspace-change-attribution → Late finish records cannot touch removed or replaced calls | Call replaced before the late finish | `test/tools/cancelled_mutation_test.dart` | late finish does not close a re-admitted attempt | green |
| workspace-change-attribution → Removed live mutations stay uncertain | Held rename across a rewind and two later captures | `test/tools/orphaned_mutation_test.dart` (new) | rewound held rename stays unknown through two captures | green |
| workspace-change-attribution → Removed live mutations stay uncertain | Rename lands during the capture | `test/tools/orphaned_mutation_test.dart` (new) | finish during collection keeps the record applying next turn | green |
| workspace-change-attribution → Removed live mutations stay uncertain | Rewind past the baseline that captured the rename | `test/tools/orphaned_mutation_test.dart` (new) | restored older baseline re-applies the finished record | green |
| workspace-change-attribution → Removed live mutations stay uncertain | Engine dies with an orphaned mutation | `test/jobs/recovery_mutation_test.dart` (new) | recovery finishes own orphan records with a fresh seq | green |
| workspace-change-attribution → Removed live mutations stay uncertain | Orphaned records overflow | `test/tools/orphaned_mutation_test.dart` (new) | 65th finished record evicts oldest and raises the floor | green |
| workspace-change-attribution → Removed live mutations stay uncertain | Request built before post-rewind reconciliation | `test/tools/orphaned_mutation_test.dart` (new) | build frozen before reconciliation keeps held rename unknown | green |
| workspace-change-attribution → Removed live mutations stay uncertain | Engine dies after the rewind commit | `test/jobs/recovery_mutation_test.dart` | resume retains the pre-cut target after engine death and a late rename | green |
| workspace-change-attribution → Removed live mutations stay uncertain | Engine dies after preservation before the cut | `test/jobs/recovery_mutation_test.dart` | resume keeps call and orphan when the rewind append never commits | green |
| workspace-change-attribution → Removed live mutations stay uncertain | Rewind removes the target but retains the call | `test/tools/orphaned_mutation_test.dart` (new) | pre-cut preservation retains a live target recorded after the surviving call | green |
| workspace-change-attribution → Removed live mutations stay uncertain | Rewind removes the target but retains the call | `test/tools/orphaned_mutation_test.dart` (new) | surviving call's preserved record is finished when its run ends | green |
| workspace-change-attribution → Removed live mutations stay uncertain | Preservation does not advance the rewind turn | `test/tools/orphaned_mutation_test.dart` (new) | preservation and the validated rewind retain the original current turn and the cut commits | green |
| workspace-change-attribution → Forks do not finish the parent's mutations | Parent rename held through child recovery | `test/session/fork_mutation_test.dart` | child recovery leaves the parent held rename foreign and unfinished | green |
| workspace-change-attribution → Forks do not finish the parent's mutations | Parent mutation after the fork | `test/session/fork_mutation_test.dart` (new) | parent write after the fork is outside child provenance | green |
| workspace-change-attribution → Forks do not finish the parent's mutations | Foreign records overflow | `test/session/fork_mutation_test.dart` (new) | more than 16 foreign records set the overflow marker | green |
| workspace-change-attribution → Forks do not finish the parent's mutations | Fork before post-rewind reconciliation | `test/session/fork_mutation_test.dart` (new) | fork before reconciliation retains the live target as foreign | green |
| workspace-change-attribution → Forks do not finish the parent's mutations | Finished parent record copied | `test/session/fork_mutation_test.dart` (new) | finished parent orphan expires after the child admits its finish | green |
| workspace-change-attribution → Unfinished mutations are bounded | Repeated cancellations on a stalled filesystem | `test/tools/cancelled_mutation_test.dart` | 40 cancelled writes keep 16 unfinished and refuse the rest untouched | green |
| workspace-change-attribution → Unfinished mutations are bounded | Repeated cancellations on a stalled filesystem | `test/tools/cancelled_mutation_test.dart` | F2: same-path cancelled waiters retain capacity until their real futures finish | green |
| workspace-change-attribution → Unfinished mutations are bounded | Capacity returns | `test/tools/cancelled_mutation_test.dart` | finished held rename admits the next write | green |
| workspace-change-attribution → Baselines follow the session tree | Rewind | `test/loop/attribution_test.dart` (new) | rewind restores the earlier baseline | green |
| workspace-change-attribution → Baselines follow the session tree | Resume after engine restart | `test/loop/attribution_test.dart` (new) | resume reads the baseline from the journal | green |
| workspace-change-attribution → Attribution work is bounded | Oversized file | `test/loop/attribution_test.dart` (new) | file over 4 MiB reads unknown without hashing | green |
| workspace-change-attribution → Attribution work is bounded | Read never completes | `test/loop/attribution_test.dart` (new) | held read is abandoned within the overall deadline and its row reads unknown | green |
| workspace-change-attribution → Attribution work is bounded | Pre-capture read never completes | `test/loop/attribution_test.dart` (new) | nonzero lock wait reduces pre-hash budget; fresh capture has unknown row without vcs_timeout | green |
| workspace-change-attribution → Completed captures survive attribution limits | Post-capture read never completes | `test/loop/attribution_test.dart` (new) | post-hash expiry retains fresh capture and baseline with unknown row and vcs_timeout | green |
| workspace-change-attribution → Attribution work is bounded | More than 64 effect paths | `test/loop/attribution_test.dart` (new) | paths beyond 64 read unknown | green |
| workspace-change-attribution → Attribution work is bounded | Reads that never complete across many requests | `test/loop/attribution_test.dart` (new) | abandoned reads never exceed 64 engine-wide | green |
| turn-perception → Ordered self-contained perception | Unchanged memory after earlier block removal | `test/loop/sensorium_test.dart` | full follow-up retains unchanged scratch facts | green |
| turn-perception → Ordered self-contained perception | Known jobs but unavailable collectors | `test/loop/sensorium_test.dart` | live job plus collected vcs keeps diagnostics unavailable | green |
| turn-perception → Ordered self-contained perception | Unchanged VCS facts every request | `test/loop/sensorium_test.dart` | unchanged second request still carries full vcs and changes none | green |
| turn-perception → Ordered self-contained perception | Empty versus failed | `test/loop/sensorium_composition_test.dart` | typed supplied observations preserve section order and availability | green |
| turn-perception → Ordered self-contained perception | Concurrent recovery notices | `test/loop/sensorium_test.dart` | both notice codes fit while recovery message stays separate | green |
| turn-perception → Bounded notice vocabulary | Every code at once | `test/loop/sensorium_composition_test.dart` | all six notice codes fit 80 tokens in fixed order | green |
| turn-perception → Bounded notice vocabulary | No notice applies | `test/loop/sensorium_composition_test.dart` | no notice condition renders notices none | green |
| turn-perception → Bounded notice vocabulary | Repeated condition | `test/loop/attribution_test.dart` (new) | two user rows raise user_edits once | green |
| turn-perception → Collected observations are admitted, not recomputed | Reconnect after the working copy changed | `test/rpc/sensorium_test.dart` | reconnect exposes recorded M2 and baseline rather than current working copy | green |
| turn-perception → Collected observations are admitted, not recomputed | Status preview | `test/rpc/sensorium_test.dart` | status collects a preview without journal bytes or baseline | green |
| workspace-change-attribution → Atomic temporary paths share mutation uncertainty | Capture while the temporary file exists | `test/workspace/vcs_real_test.dart` | git/jj temporary-file deltas stay uncertain through cancellation | green |
| workspace-change-attribution → Atomic temporary paths share mutation uncertainty | Cleanup after an intervening baseline | `test/workspace/vcs_real_test.dart` | git/jj temporary-file deltas stay uncertain through cancellation | green |
| workspace-change-attribution → Atomic temporary paths share mutation uncertainty | Refused pre-mutation intent | `test/tools/mutation_provenance_test.dart` | refused atomic intent creates no file or parent | green |
| workspace-change-attribution → Atomic temporary paths share mutation uncertainty | Capture freezes around intent publication | `test/tools/mutation_provenance_test.dart` | temporary attribution freezes while the intent is flushing | green |
| workspace-change-attribution → Atomic temporary paths share mutation uncertainty | Temporary cleanup after rewind and restart | `test/jobs/recovery_mutation_test.dart` | rewound temporary footprint survives engine death, recovery and older-baseline restoration | green |
| workspace-change-attribution → Atomic temporary paths share mutation uncertainty | Parent cleanup after child recovery | `test/loop/attribution_test.dart` | temporary paths survive fork and rewind | green |
| workspace-change-attribution → Atomic temporary paths share mutation uncertainty | Unrelated user file resembles an atomic temporary | `test/loop/attribution_test.dart` | unrecorded temporary-looking user file remains a user edit | green |
| workspace-change-attribution → Atomic temporary paths share mutation uncertainty | Independent successful write to a temporary path | `test/loop/attribution_test.dart` | temporary paths cannot reuse another call's effect proof | green |
| workspace-change-attribution → Atomic temporary paths share mutation uncertainty | Legacy footprint lacks a temporary path | `test/loop/attribution_test.dart` | legacy temporary provenance uncertainty keeps its existing lifetime | green |
| workspace-change-attribution → Atomic temporary paths share mutation uncertainty | Legacy footprint lacks a temporary path | `test/jobs/recovery_mutation_test.dart` | resume quiesces a legacy unquiesced call without a temporary path whose step predates the baseline and the next comparison reads every row unknown | green |
| workspace-change-attribution → Atomic temporary paths share mutation uncertainty | Legacy footprint lacks a temporary path | `test/jobs/recovery_mutation_test.dart` | resume finishes a legacy owned orphan without a temporary path and the next comparison reads every row unknown | green |
| workspace-change-attribution → Atomic temporary paths share mutation uncertainty | Legacy footprint lacks a temporary path | `test/session/fork_mutation_test.dart` | fork carries a legacy unfinished record without a temporary path as foreign uncertainty | green |
| workspace-change-attribution → Atomic temporary paths share mutation uncertainty | Capture freezes around intent publication | `test/tools/mutation_provenance_test.dart` | readmitted untargeted runs cannot reuse an older run's footprint | green |
| workspace-change-attribution → Content-addressed baseline per admitted request; vcs-observation → Observation does not alter the user's repository state | Baseline recorded on admission; Git index untouched | `test/workspace/vcs_real_test.dart` | private-index capture includes sparse-checkout paths | green |
| workspace-change-attribution → Changes since the last baseline | Baseline lost | `test/workspace/vcs_real_test.dart` | missing jj baseline is replaced by the fresh capture | green |
| D11 → Malformed temporary footprints | Present empty, null or non-string field | `test/loop/attribution_test.dart` | malformed temporary provenance remains visible as unknown | green |
| D11 → Malformed temporary footprints | Present empty, null or non-string field | `test/jobs/recovery_mutation_test.dart` | malformed temporary footprint fails recovery | green |
| D11 → Malformed temporary footprints | Present empty, null or non-string field | `test/session/fork_mutation_test.dart` | fork rejects malformed temporary footprints | green |

## 1. Record the architecture

- [x] 1.1 Write ADR 0017 *VCS observation baselines and provenance attribution* as listed in design.md ADRs. It covers:
  - content-addressed baselines in step metadata, with `seq` and carry-forward;
  - the private git index and the filter policy;
  - the `target`, `effect.sha256` and identity-guarded `quiesced` call fields;
  - open mutations, plus session-owned orphaned-mutation records with the attribution floor and foreign copies at fork;
  - the unfinished-mutation cap and the step-output interval;
  - pre/post-capture verification and the attribution rules;
  - the serialized deadline contract and backend-independent cleanup slots.

  Update the ADR index in `openspec/architecture.md`, and the perception paragraph that says VCS producers are later work. Also record the apply attempt that Kehai orchestrates, and its unsupported steps, in the design's apply notes (D9). Verify that the ADR agrees with D1–D9 and that `openspec validate vcs-changes-and-notices --strict` passes.

## 2. Collect VCS observations

- [x] 2.1 Write failing tests for the `vcs_backend_test`, `vcs_collector_test`, `vcs_cleanup_test` and config rows, plus the vcs rows in `sensorium_test`/`sensorium_composition_test` (many paths, forged tags, newline paths). Use a fake process runner with held completion, held termination and recorded argv. Verify that each test fails for the missing behaviour, not because of a fixture or import error.
- [x] 2.2 Implement backend detection and the strict startup keys `vcs.backend` (`auto`/`jj`/`git`/`none`) and `sensorium.collectorDeadlineMs` (100–10000, default 300; the first collection of a run gets at least 3000 ms) in `config/user_config.dart`. Then implement the collector:
  - an engine lock;
  - one deadline per collection, with termination issued and not awaited;
  - 16 cleanup slots;
  - a private git index copy per collection, quarantined with its slot;
  - `GIT_OPTIONAL_LOCKS=0` and `GIT_TERMINAL_PROMPT=0`;
  - the argv allowlist;
  - `resolveProgram`;
  - bounded output and stderr.

  Extend `SensoriumVcs`/`SensoriumReason` and render the vcs section with escaping, indentation and clipping (D6, D8). Verify that the group-2 rows turn green, and that `sensoriumWithBudget` still finds `\nvcs:` after budget.
- [x] 2.3 Add `test/workspace/vcs_real_test.dart`, running real jj 0.46.0 and git in disposable repositories, for its collection rows, including the unborn branch and current-index membership. Tag it `slow` where it spawns many processes. Settle the open question about the jj diff template here: use `-T` stats, or fall back to `--git` parsing within the same bounds. Verify the collection rows pass on native Windows locally; task 4.2 verifies the real autocrlf attribution row after provenance and attribution exist, and tasks 6.1 and 6.3 retain Linux and Windows CI qualification after the implementation is committed and pushed. Add a collector test that skips a relative `PATH` (D9).
- [x] 2.4 Document the `vcs.backend` and `collectorDeadlineMs` settings, the backends, the filter policy (clean filters and fsmonitor run as for `git status`; no fetch, push or checkout) and the `unavailable`/`stale` reasons in `README.md`. Verify that the examples parse under the strict config tests.

## 3. Record mutation provenance

- [x] 3.1 Write failing tests for the durable provenance, open-mutation, late-finish, orphan/fork/recovery metadata and capacity portions of the rows in `mutation_provenance_test`, `cancelled_mutation_test`, `orphaned_mutation_test`, `fork_mutation_test` and `recovery_mutation_test`. Use a held atomic-write rename, real session writers, rewind and fork, and deterministic barriers. Verify that each test fails for the missing behaviour. Task 4.1 adds the final agent/user/unknown assertions in these same mapped files once attribution exists; no mapped scenario is removed or skipped.
- [x] 3.2 Implement the call fields on `edit` and `write`:
  - a `target` record (repo-relative realPath) under the ownership guard before mutating;
  - `effect: {sha256, seq}` on success, with sequence reserved at the writer queue head and seqHigh durable before the effect in the same queue operation;
  - existing resolved-target locks held through rename and effect commit or failure/quiescence, with cancelled waiters aborting before mutation;
  - `quiesced: true` under the identity guard when the future finishes;
  - an engine-wide cap of 16 unfinished runs, refused before mutating.

  Add and RED-confirm the newly discovered concurrent same-path, delayed-effect and case-variant regressions before implementing effect sequences. Reuse the existing `PathLocks` scope rather than adding another mutex. Hold A after its rename but before its effect commit, queue B on that target, and verify that effect order follows visible rename order. Case-variant targets are unestablished order, not agent proof. Derive the open-mutation set after resume and after every rewind, and extend recovery to terminal cancelled edit/write calls without `quiesced`. Verify target/effect ordering, restart high-water, quiescence, identity and capacity here. Task 4.2 adds the corresponding attribution labels end to end.
- [x] 3.3 Implement the orphaned-mutation records:
  - `meta/orphanedMutations/<runId> = {target, session}` durably before a valid rewind loses the target, within the same writer queue operation, including a surviving call whose target field would be removed; build and validate the rewind once before writing, stamp preservation with its current turn, and preserve existing records idempotently; invalid rewinds append nothing;
  - orphan preservation at supersession or identity-guard refusal;
  - every run's finish checks at the writer queue head for an owned unfinished orphan and records `finishedSeq` plus `seqHigh`, whether its call's quiescence merge was accepted or refused; retire the registry entry only after all required finish records are durable and before the queue advances; recovery finishes only records this session owns;
  - the `meta/vcs/seqHigh` counter and the `attributionFloor` eviction past 64 finished records;
  - foreign copies at fork inside the parent's writer (`session/writer.dart`), including the fork's live-run provider, at most 16, then `foreignOverflow`.

  Verify the orphan/fork record contents, write-ahead ordering and crash-window replay, successful commit of the once-built validated rewind with `currentTurn` unchanged by preservation, finish of a surviving call's preserved record, sequence/floor bounds, live-run provider and ownership guards, and that journal replay of the meta fold is unchanged for sessions without these keys. Task 4.2 verifies the resulting attribution labels for every mapped orphan/fork scenario.
- [x] 3.4 Document in `README.md` how cancelled, rewound and forked writes are attributed, and the error at the 16-run cap. Verify that the wording matches the spec scenarios.

## 4. Baselines and attribution

- [x] 4.1 Write failing `test/loop/attribution_test.dart` cases for the baseline, interval, attribution, rewind/resume, bound and repeated-condition rows, including same-turn unresolved/effect ordering and missing legacy boundaries. Also add the final agent/user/unknown assertions for every mapped mutation, cancellation, orphan, fork and recovery scenario in its existing test-map file. Use fake collectors and a held file reader, plus real tool calls recorded through the writer and deterministic held renames. Verify that each new attribution assertion fails for the missing behaviour.
- [x] 4.2 Implement the step-metadata shape `sensorium.vcs = {state, reason?, observed, value, baseline?:{backend, id, seq, jobsLive}}`. Then add:
  - carry-forward on failure;
  - the backward scan, skipping only non-admitted steps, up to 256;
  - the interval over step `call` output entries;
  - collector-owned pre/post hashing and returned per-path samples under the same lock/deadline, with pre-hash wait at most one third of the remaining post-lock budget and a completed-capture branch replacing unconditional timeout failure;
  - one injectable monotonic clock for both elapsed time and waits, replacing the wait-only scheduler; reserve capture sequence from the shared allocator after the lock and before pre-hashing;
  - the agent/user/unknown rules, including open, orphaned and foreign records and the floor;
  - `targetAfterSeq` in the first accepted pre-mutation target append, read from durable seqHigh at queue head without reserving a sequence or adding a flush; require greater effect sequences to override unresolved targets, with missing boundaries unknown;
  - a derived quiescence-turn/step-link index alongside open keys, rebuilt on resume/rewind and updated before queue advance, with one entry per surviving mutation call; freeze relevant keys with the request snapshot and verify late quiescence without per-request scans of all calls;
  - 64 paths of 4 MiB each, with 64 outstanding reads engine-wide and reads abandoned at the deadline.

  Extend `SensoriumChange` and render `changes_since_last_turn` with folds. Re-run affected group-2 deadline, lock-wait and cleanup rows after changing the clock seam. Verify every attribution row across `attribution_test.dart` and the mapped mutation, cancellation, orphan, fork and recovery files, including effect-order labels, plus the real one-file and autocrlf rows in `vcs_real_test.dart`. Keep autocrlf there and exercise real provenance against converted repository content. Do not mark a scenario green on metadata evidence alone.
  Apply the conservative case-alias rule across interval targets and applying open/orphan/foreign targets. Verify both case-variant writes on a case-insensitive volume and a differently cased row on a case-sensitive filesystem; unrelated user rows still raise `user_edits`.
- [x] 4.3 Document in `README.md` what `changes_since_last_turn` means, the meaning of `by: agent/user/unknown`, and the baseline reset. Verify that it agrees with ADR 0017.

## 5. Notices, admission and status

- [x] 5.1 Write failing tests for the notices rows (all six codes, none) and for the turn-perception rows: known jobs with collected vcs, unchanged VCS facts, reconnect, and status preview. Use the real writer and RPC framing, and compare journal bytes before and after status. Verify that each test fails for the missing behaviour.
- [x] 5.2 Implement:
  - the `vcs_timeout`, `vcs_failed`, `user_edits` and `baseline_reset` notice codes, in fixed order after the existing two, with `… +N more`;
  - a synchronous `WorkspaceObserver` call inside `RequestBuilder.build`, with the observation admitted by the guarded pre-stream merge;
  - a read-only status preview under the same lock and deadline.

  Verify that the group-5 rows turn green and that the three ride-along `green` rows still pass.
- [x] 5.3 Update the observation and status sections of `README.md`, and the built-in perception guidance, for the vcs and changes sections and the new notice codes. Advance the internal instruction version to `kehai-4` and document the intentional native opaque-lineage break and existing rewind-or-new-session recovery, without migration or a package-version bump (D10). Rerun the existing changed-instructions native-continuity rejection regression in `test/loop/compaction_budget_test.dart`. Verify that the documented metadata matches what RPC actually materializes.

## 6. Qualify the integrated slice

- [x] 6.1 Run every test file in the map through the official Dart MCP runner, then the pinned analysis and format checks for the changed files. Verify that every row has executed green evidence, and that CI ubuntu + windows passes.
- [x] 6.2 Dogfood with Kehai: run a real multi-step change in a jj repository and a plain git repository, edited by both the agent and the user. Record the admitted vcs/changes sections, the attribution outcomes and the block token estimates. Record the friction-ledger dispositions from D9 and any unsupported steps, together with their roadmap assignments. Verify that the evidence is recorded in the design's apply notes.
- [x] 6.3 Obtain the configured pre-ship review, and successful Linux and native-Windows CI on the delivery head. Address the findings through the installed workflow. No version bump, because releases are disabled.

## 7. Atomic temporary provenance and sparse capture

- [x] 7.1 Write ADR 0018 per D11, superseding only the single-path footprint and literal Git capture command of accepted ADR 0017; update the architecture index.
- [x] 7.2 Add the amendment's mapped consumer-visible regressions and record their pre-fix outcomes in the group-7 commit body and PR qualification receipt. RED-confirm missing behavior; retain honest green conformance outcomes where existing behavior already satisfies a scenario. The legacy recovery regressions use separate call-only and orphan-only fixtures. The call-only fixture has no orphan or foreign record, attribution floor, overflow marker, job or process activity, and links its call from a step before the baseline turn, so only the quiescence index can surface it after resume. Both assert that the recovered call or record still lacks a `temporary` key.
- [x] 7.3 Implement the required production `writeAtomically.beforeWrite` callback and two-path `FileMutation`; publish one complete durable intent before parent/temporary creation, and extend registry, call, orphan, foreign, recovery and frozen attribution with the actual temporary path and legacy uncertainty. Derive untargeted uncertainty per registered run, not deduplicated call id. Accept legacy footprints without a temporary in replay, rewind preservation, finish, recovery, fork and the derived open-key/quiescence-interval indexes without throwing, dropping or inventing a path.
- [x] 7.4 Migrate target-only shared and test-local fixtures that back green rows, including `WriterHeldMutation` and the hand-written call, orphan and foreign records in `test/jobs/recovery_mutation_test.dart`, to complete two-path footprints without changing their green assertions; keep deliberately missing-temporary fixtures for legacy behavior. The direct atomic-write fixture records its real temporary through the production callback, not a no-op.
- [x] 7.5 Fix sparse-checkout private-index staging and pinned jj missing-revision recognition; document Git ≥ 2.34, temporary rows and legacy uncertainty in README.
- [x] 7.6 Run the amendment's mapped and affected test files through the official Dart MCP runner, and the pinned format and analysis checks. Record native Git/jj regression evidence in the group-7 commit body and PR qualification receipt without narrowing assertions.

## 8. Qualify the committed feedback head

- [ ] 8.1 Obtain the configured pre-ship review and successful Linux/native-Windows CI, including the full native suite, on the committed feedback runtime head. Address findings through the configured PR workflow before merge. This head-based gate follows group 7's commit so reviews and CI cover committed code; it is not a behavior deferral.

## Workflow follow-up

- PR #32 is already open. Use automatic Codex review after each push; if no actual current-head report arrives within 20 minutes, request `@codex review` once for that head as `sh1ny`, per the user's explicit override. Merge only after the configured CI and review gates pass.
- The change is already archived. Keep its delta and the canonical main specs identical; do not recreate an active change or re-archive it. Finish through the existing PR with `specwright-finish` (`finish: pr`).
