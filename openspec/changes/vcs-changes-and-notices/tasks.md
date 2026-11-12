# Tasks

## Test map

`red` means new or changed behaviour awaiting executed green evidence. `green` rows ride along unchanged inside the MODIFIED turn-perception requirement and already pass; their task re-runs them. Files marked **new** are planned. Deadline, cancellation and held-rename cases use in-process fakes with controllable completion (a fake process runner, a held atomic-write rename, explicit barriers); no sleeps or wall-clock assertions (#28). Real `git`/`jj` process tests assert outcomes only and carry the `slow` tag when they spawn many processes. Run Dart tests through the official Dart MCP tool, one file at a time locally; the full suite runs on CI (ubuntu + windows).

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| vcs-observation → Backend detection prefers jj | Colocated repository | `test/workspace/vcs_backend_test.dart` (new) | colocated .jj and .git selects jj | red |
| vcs-observation → Backend detection prefers jj | Plain git repository | `test/workspace/vcs_backend_test.dart` (new) | .git without .jj selects git | red |
| vcs-observation → Backend detection prefers jj | No repository | `test/workspace/vcs_backend_test.dart` (new) | no repository reads unavailable (no repository) | red |
| vcs-observation → Backend detection prefers jj | Invalid backend setting | `test/config/config_test.dart` | invalid vcs.backend refuses configuration | red |
| vcs-observation → Backend detection prefers jj | Observation disabled | `test/workspace/vcs_backend_test.dart` (new) | vcs.backend none starts no process and reads disabled | red |
| vcs-observation → Working-copy state is reported | Dirty jj working copy | `test/workspace/vcs_real_test.dart` (new) | real jj working copy renders change, description, parent and counts | red |
| vcs-observation → Working-copy state is reported | Many changed paths | `test/loop/sensorium_composition_test.dart` | vcs section lists 12 paths then … +N more | red |
| vcs-observation → Working-copy state is reported | Conflicted files | `test/workspace/vcs_collector_test.dart` (new) | conflicted paths are listed for jj and git | red |
| vcs-observation → Working-copy state is reported | Unborn git branch | `test/workspace/vcs_real_test.dart` (new) | real git unborn branch reports branch without HEAD id | red |
| vcs-observation → Collection is bounded by a deadline | Collection within deadline | `test/workspace/vcs_collector_test.dart` (new) | completed fake collection returns available | red |
| vcs-observation → Collection is bounded by a deadline | Deadline exceeded with an earlier observation | `test/workspace/vcs_collector_test.dart` (new) | held fake process at deadline yields stale with timeout and earlier value | red |
| vcs-observation → Collection is bounded by a deadline | Deadline exceeded without an earlier observation | `test/workspace/vcs_collector_test.dart` (new) | held fake process at deadline yields unavailable (timeout) | red |
| vcs-observation → Collection is bounded by a deadline | Invalid deadline | `test/config/config_test.dart` | sensorium.collectorDeadlineMs outside 100–10000 refuses configuration | red |
| vcs-observation → Failures are named, never clean | jj not installed | `test/workspace/vcs_collector_test.dart` (new) | missing executable reads unavailable (jj not found) and (git not found) | red |
| vcs-observation → Failures are named, never clean | Command fails | `test/workspace/vcs_collector_test.dart` (new) | non-zero exit reads failed with clipped stderr reason | red |
| vcs-observation → Failures are named, never clean | Output exceeds the read bound | `test/workspace/vcs_collector_test.dart` (new) | oversized output marks partial, never clean | red |
| vcs-observation → Observation does not alter the user's repository state | Git index untouched | `test/workspace/vcs_real_test.dart` (new) | git collection leaves .git/index bytes and refs unchanged | red |
| vcs-observation → Observation does not alter the user's repository state | Concurrent user git command | `test/workspace/vcs_real_test.dart` (new) | collection takes no index.lock and user git add succeeds | red |
| vcs-observation → Observation does not alter the user's repository state | Configured clean filter hangs | `test/workspace/vcs_collector_test.dart` (new) | hanging clean filter is bounded by the deadline and terminated | red |
| vcs-observation → Observation does not alter the user's repository state | Remote-touching subcommands never run | `test/workspace/vcs_collector_test.dart` (new) | recorded argv stays within the allowlist for jj and git | red |
| vcs-observation → Collections in one engine are serialized | Status during a request build | `test/workspace/vcs_collector_test.dart` (new) | status preview waits on the engine lock behind a build | red |
| vcs-observation → Collections in one engine are serialized | Wait exceeds the deadline | `test/workspace/vcs_collector_test.dart` (new) | lock wait past deadline returns stale without starting a process | red |
| vcs-observation → Collections in one engine are serialized | Ignored file becomes tracked | `test/workspace/vcs_real_test.dart` (new) | fresh private index sees a force-added ignored file | red |
| vcs-observation → Collections in one engine are serialized | File untracked by the user | `test/workspace/vcs_real_test.dart` (new) | fresh private index follows git rm --cached | red |
| vcs-observation → Timed-out collections are isolated | Termination cannot be verified | `test/workspace/vcs_cleanup_test.dart` (new) | unverifiable termination holds its slot until engine exit | red |
| vcs-observation → Timed-out collections are isolated | Termination stalls | `test/workspace/vcs_cleanup_test.dart` (new) | stalled termination returns at deadline and keeps the slot | red |
| vcs-observation → Timed-out collections are isolated | Cleanup limit reached with git | `test/workspace/vcs_cleanup_test.dart` (new) | 16 held git slots read cleanup pending and resume after release | red |
| vcs-observation → Timed-out collections are isolated | Repeated jj timeouts with termination that never completes | `test/workspace/vcs_cleanup_test.dart` (new) | 100 jj timeouts never exceed 16 slots and every build meets its deadline | red |
| vcs-observation → Repository text cannot forge block structure | Description with a fake closing tag | `test/loop/sensorium_test.dart` | vcs description with closing tag is escaped and indented | red |
| vcs-observation → Repository text cannot forge block structure | Path with a newline | `test/loop/sensorium_test.dart` | path with newline renders escaped on one row | red |
| workspace-change-attribution → Content-addressed baseline per admitted request | Baseline recorded on admission | `test/loop/attribution_test.dart` (new) | admitted step metadata carries backend, id, seq and jobsLive | red |
| workspace-change-attribution → Content-addressed baseline per admitted request | Collection failed | `test/loop/attribution_test.dart` (new) | failed collection carries the previous baseline forward | red |
| workspace-change-attribution → Content-addressed baseline per admitted request | Long run of failures | `test/loop/attribution_test.dart` (new) | 300 failed collections still find the carried baseline | red |
| workspace-change-attribution → Changes since the last baseline | One file edited | `test/workspace/vcs_real_test.dart` (new) | real jj and git diff report one edited file with counts | red |
| workspace-change-attribution → Changes since the last baseline | Nothing changed | `test/loop/attribution_test.dart` (new) | unchanged baseline renders changes none | red |
| workspace-change-attribution → Changes since the last baseline | First request of a session | `test/loop/attribution_test.dart` (new) | first request reads unavailable (no baseline) | red |
| workspace-change-attribution → Changes since the last baseline | Baseline lost | `test/loop/attribution_test.dart` (new) | unresolvable baseline id reads baseline lost and raises baseline_reset | red |
| workspace-change-attribution → Changes since the last baseline | Backend changed | `test/loop/attribution_test.dart` (new) | backend switch reads baseline lost | red |
| workspace-change-attribution → Changes since the last baseline | No admitted observation within the lookup bound | `test/loop/attribution_test.dart` (new) | 256 non-admitted steps exhaust the lookup and reset | red |
| workspace-change-attribution → Attribution interval | Edit in response to the baseline request | `test/loop/attribution_test.dart` (new) | edit linked from the baseline step output is in the interval | red |
| workspace-change-attribution → Attribution interval | Shell call in response to the baseline request | `test/loop/attribution_test.dart` (new) | bash in the baseline step makes rows unknown | red |
| workspace-change-attribution → Attribution interval | Hook run in the interval | `test/loop/attribution_test.dart` (new) | call with recorded hook run makes rows unknown | red |
| workspace-change-attribution → Attribution interval | Calls before the baseline | `test/loop/attribution_test.dart` (new) | calls before the capture turn are ignored | red |
| workspace-change-attribution → Attribution from recorded provenance | Agent edit | `test/loop/attribution_test.dart` (new) | matching pre and post hashes read by agent | red |
| workspace-change-attribution → Attribution from recorded provenance | User edit with no agent activity | `test/loop/attribution_test.dart` (new) | change with no interval activity reads by user and raises user_edits | red |
| workspace-change-attribution → Attribution from recorded provenance | File rewritten around the capture | `test/loop/attribution_test.dart` (new) | pre/post hash mismatch reads unknown | red |
| workspace-change-attribution → Attribution from recorded provenance | Content differs from the agent's effect | `test/loop/attribution_test.dart` (new) | bytes differing from effect read unknown | red |
| workspace-change-attribution → Attribution from recorded provenance | Change during a shell command | `test/loop/attribution_test.dart` (new) | interval bash makes unmatched rows unknown | red |
| workspace-change-attribution → Attribution from recorded provenance | Line-ending conversion on Windows | `test/workspace/vcs_real_test.dart` (new) | autocrlf true agent write still reads by agent | red |
| workspace-change-attribution → Unresolved mutations are uncertain provenance | Cancelled during rename | `test/tools/cancelled_mutation_test.dart` | cancelled write with held rename reads unknown | red |
| workspace-change-attribution → Unresolved mutations are uncertain provenance | Restart after rename | `test/loop/attribution_test.dart` (new) | interrupted write after restart reads unknown | red |
| workspace-change-attribution → Unresolved mutations are uncertain provenance | Later successful edit of the same path | `test/loop/attribution_test.dart` (new) | latest effect decides after an unresolved earlier write | red |
| workspace-change-attribution → Mutation targets are recorded before mutation | Successful write through a symlink | `test/tools/mutation_provenance_test.dart` (new) | target records the resolved symlink destination | red |
| workspace-change-attribution → Mutation targets are recorded before mutation | Interrupted write through a symlink | `test/tools/mutation_provenance_test.dart` (new) | target is recorded before the rename starts | red |
| workspace-change-attribution → Mutation targets are recorded before mutation | Symlink retargeted before resume | `test/tools/mutation_provenance_test.dart` (new) | retargeted symlink does not redirect provenance | red |
| workspace-change-attribution → Mutation targets are recorded before mutation | Symlinked parent directory | `test/tools/mutation_provenance_test.dart` (new) | symlinked parent resolves to the real repo path | red |
| workspace-change-attribution → Mutation targets are recorded before mutation | Call without a recorded target | `test/loop/attribution_test.dart` (new) | edit without target counts as process-running activity | red |
| workspace-change-attribution → Open mutations stay uncertain across baselines | Rename finishes after the next baseline | `test/tools/cancelled_mutation_test.dart` | rename released after next baseline reads unknown without user_edits | red |
| workspace-change-attribution → Open mutations stay uncertain across baselines | Open mutation still pending | `test/tools/cancelled_mutation_test.dart` | unquiesced call keeps its target unknown | red |
| workspace-change-attribution → Open mutations stay uncertain across baselines | Engine dies with an open mutation | `test/jobs/recovery_mutation_test.dart` (new) | resume records quiesced at the resume turn | red |
| workspace-change-attribution → Open mutations stay uncertain across baselines | Late work fails without changing the file | `test/tools/cancelled_mutation_test.dart` | failed late work closes the target | red |
| workspace-change-attribution → Late finish records cannot touch removed or replaced calls | Call removed by rewind before the late finish | `test/tools/cancelled_mutation_test.dart` | late finish after rewind creates no call node and leaves an orphan record | red |
| workspace-change-attribution → Late finish records cannot touch removed or replaced calls | Call replaced before the late finish | `test/tools/cancelled_mutation_test.dart` | late finish does not close a re-admitted attempt | red |
| workspace-change-attribution → Removed live mutations stay uncertain | Held rename across a rewind and two later captures | `test/tools/orphaned_mutation_test.dart` (new) | rewound held rename stays unknown through two captures | red |
| workspace-change-attribution → Removed live mutations stay uncertain | Rename lands during the capture | `test/tools/orphaned_mutation_test.dart` (new) | finish during collection keeps the record applying next turn | red |
| workspace-change-attribution → Removed live mutations stay uncertain | Rewind past the baseline that captured the rename | `test/tools/orphaned_mutation_test.dart` (new) | restored older baseline re-applies the finished record | red |
| workspace-change-attribution → Removed live mutations stay uncertain | Engine dies with an orphaned mutation | `test/jobs/recovery_mutation_test.dart` (new) | recovery finishes own orphan records with a fresh seq | red |
| workspace-change-attribution → Removed live mutations stay uncertain | Orphaned records overflow | `test/tools/orphaned_mutation_test.dart` (new) | 65th finished record evicts oldest and raises the floor | red |
| workspace-change-attribution → Removed live mutations stay uncertain | Request built before the orphan record is written | `test/tools/orphaned_mutation_test.dart` (new) | build frozen before orphan append keeps held rename unknown | red |
| workspace-change-attribution → Forks do not finish the parent's mutations | Parent rename held through child recovery | `test/session/fork_mutation_test.dart` (new) | child recovery leaves the parent's held rename foreign and unknown | red |
| workspace-change-attribution → Forks do not finish the parent's mutations | Parent mutation after the fork | `test/session/fork_mutation_test.dart` (new) | parent write after the fork is outside child provenance | red |
| workspace-change-attribution → Forks do not finish the parent's mutations | Foreign records overflow | `test/session/fork_mutation_test.dart` (new) | more than 16 foreign records set the overflow marker | red |
| workspace-change-attribution → Forks do not finish the parent's mutations | Fork between rewind and orphan record | `test/session/fork_mutation_test.dart` (new) | fork before orphan append copies the live run as foreign | red |
| workspace-change-attribution → Unfinished mutations are bounded | Repeated cancellations on a stalled filesystem | `test/tools/cancelled_mutation_test.dart` | 40 cancelled writes keep 16 unfinished and refuse the rest untouched | red |
| workspace-change-attribution → Unfinished mutations are bounded | Capacity returns | `test/tools/cancelled_mutation_test.dart` | finished held rename admits the next write | red |
| workspace-change-attribution → Baselines follow the session tree | Rewind | `test/loop/attribution_test.dart` (new) | rewind restores the earlier baseline | red |
| workspace-change-attribution → Baselines follow the session tree | Resume after engine restart | `test/loop/attribution_test.dart` (new) | resume reads the baseline from the journal | red |
| workspace-change-attribution → Attribution work is bounded | Oversized file | `test/loop/attribution_test.dart` (new) | file over 4 MiB reads unknown without hashing | red |
| workspace-change-attribution → Attribution work is bounded | Read never completes | `test/loop/attribution_test.dart` (new) | held read is abandoned at the deadline and the row reads unknown | red |
| workspace-change-attribution → Attribution work is bounded | More than 64 effect paths | `test/loop/attribution_test.dart` (new) | paths beyond 64 read unknown | red |
| workspace-change-attribution → Attribution work is bounded | Reads that never complete across many requests | `test/loop/attribution_test.dart` (new) | abandoned reads never exceed 64 engine-wide | red |
| turn-perception → Ordered self-contained perception | Unchanged memory after earlier block removal | `test/loop/sensorium_test.dart` | full follow-up retains unchanged scratch facts | green |
| turn-perception → Ordered self-contained perception | Known jobs but unavailable collectors | `test/loop/sensorium_test.dart` | real live job with collected vcs and unavailable diagnostics | red |
| turn-perception → Ordered self-contained perception | Unchanged VCS facts every request | `test/loop/sensorium_test.dart` | unchanged working copy keeps full vcs and changes none | red |
| turn-perception → Ordered self-contained perception | Empty versus failed | `test/loop/sensorium_composition_test.dart` | typed supplied observations preserve section order and availability | green |
| turn-perception → Ordered self-contained perception | Concurrent recovery notices | `test/loop/sensorium_test.dart` | both notice codes fit while recovery message stays separate | green |
| turn-perception → Bounded notice vocabulary | Every code at once | `test/loop/sensorium_composition_test.dart` | all six notice codes fit 80 tokens in fixed order | red |
| turn-perception → Bounded notice vocabulary | No notice applies | `test/loop/sensorium_composition_test.dart` | no notice condition renders notices none | red |
| turn-perception → Bounded notice vocabulary | Repeated condition | `test/loop/attribution_test.dart` (new) | two user rows raise user_edits once | red |
| turn-perception → Collected observations are admitted, not recomputed | Reconnect after the working copy changed | `test/rpc/sensorium_test.dart` | reconnect shows the admitted vcs observation and baseline | red |
| turn-perception → Collected observations are admitted, not recomputed | Status preview | `test/rpc/sensorium_test.dart` | status collects a preview without journal bytes or baseline | red |

## 1. Record the architecture

- [ ] 1.1 Write ADR 0017 *VCS observation baselines and provenance attribution* as listed in design.md ADRs. It covers:
  - content-addressed baselines in step metadata, with `seq` and carry-forward;
  - the private git index and the filter policy;
  - the `target`, `effect.sha256` and identity-guarded `quiesced` call fields;
  - open mutations, plus session-owned orphaned-mutation records with the attribution floor and foreign copies at fork;
  - the unfinished-mutation cap and the step-output interval;
  - pre/post-capture verification and the attribution rules;
  - the serialized deadline contract and backend-independent cleanup slots.

  Update the ADR index in `openspec/architecture.md`, and the perception paragraph that says VCS producers are later work. Also record the apply attempt that Kehai orchestrates, and its unsupported steps, in the design's apply notes (D9). Verify that the ADR agrees with D1–D9 and that `openspec validate vcs-changes-and-notices --strict` passes.

## 2. Collect VCS observations

- [ ] 2.1 Write failing tests for the `vcs_backend_test`, `vcs_collector_test`, `vcs_cleanup_test` and config rows, plus the vcs rows in `sensorium_test`/`sensorium_composition_test` (many paths, forged tags, newline paths). Use a fake process runner with held completion, held termination and recorded argv. Verify that each test fails for the missing behaviour, not because of a fixture or import error.
- [ ] 2.2 Implement backend detection and the strict startup keys `vcs.backend` (`auto`/`jj`/`git`/`none`) and `sensorium.collectorDeadlineMs` (100–10000, default 300; the first collection of a run gets at least 3000 ms) in `config/user_config.dart`. Then implement the collector:
  - an engine lock;
  - one deadline per collection, with termination issued and not awaited;
  - 16 cleanup slots;
  - a private git index copy per collection, quarantined with its slot;
  - `GIT_OPTIONAL_LOCKS=0` and `GIT_TERMINAL_PROMPT=0`;
  - the argv allowlist;
  - `resolveProgram`;
  - bounded output and stderr.

  Extend `SensoriumVcs`/`SensoriumReason` and render the vcs section with escaping, indentation and clipping (D6, D8). Verify that the group-2 rows turn green, and that `sensoriumWithBudget` still finds `\nvcs:` after budget.
- [ ] 2.3 Add `test/workspace/vcs_real_test.dart`, running real jj 0.46.0 and git in disposable repositories, for the rows mapped to it, including autocrlf and the unborn branch. Tag it `slow` where it spawns many processes. Settle the open question about the jj diff template here: use `-T` stats, or fall back to `--git` parsing within the same bounds. Verify these rows pass on native Windows locally and on CI ubuntu + windows. Add a collector test that skips a relative `PATH` (D9).
- [ ] 2.4 Document the `vcs.backend` and `collectorDeadlineMs` settings, the backends, the filter policy (clean filters and fsmonitor run as for `git status`; no fetch, push or checkout) and the `unavailable`/`stale` reasons in `README.md`. Verify that the examples parse under the strict config tests.

## 3. Record mutation provenance

- [ ] 3.1 Write failing tests for the provenance rows in `mutation_provenance_test`, `cancelled_mutation_test`, `orphaned_mutation_test`, `fork_mutation_test` and `recovery_mutation_test`. Use a held atomic-write rename, real session writers, rewind and fork, and deterministic barriers. Verify that each test fails for the missing behaviour.
- [ ] 3.2 Implement the call fields on `edit` and `write`:
  - a `target` record (repo-relative realPath) under the ownership guard before mutating;
  - `effect: {sha256}` on success;
  - `quiesced: true` under the identity guard when the future finishes;
  - an engine-wide cap of 16 unfinished runs, refused before mutating.

  Derive the open-mutation set after resume and after every rewind, and extend the recovery walk to terminal cancelled `edit`/`write` calls without `quiesced`. Verify that the provenance, open-mutation, late-finish and cap rows turn green.
- [ ] 3.3 Implement the orphaned-mutation records:
  - `meta/orphanedMutations/<runId> = {target, session}` at rewind or supersession, or when the identity guard refuses;
  - `finishedSeq` on finish, or from recovery for records this session owns;
  - the `meta/vcs/seqHigh` counter and the `attributionFloor` eviction past 64 finished records;
  - foreign copies at fork inside the parent's writer (`session/writer.dart`), including the fork's live-run provider, at most 16, then `foreignOverflow`.

  Verify that the orphaned-mutation and fork rows turn green, and that journal replay of the meta fold is unchanged for sessions without these keys.
- [ ] 3.4 Document in `README.md` how cancelled, rewound and forked writes are attributed, and the error at the 16-run cap. Verify that the wording matches the spec scenarios.

## 4. Baselines and attribution

- [ ] 4.1 Write failing `test/loop/attribution_test.dart` cases for the baseline, interval, attribution, rewind/resume, bound and repeated-condition rows. Use fake collectors and a held file reader, plus real tool calls recorded through the writer. Verify that each test fails for the missing behaviour.
- [ ] 4.2 Implement the step-metadata shape `sensorium.vcs = {state, reason?, observed, value, baseline?:{backend, id, seq, jobsLive}}`. Then add:
  - carry-forward on failure;
  - the backward scan, skipping only non-admitted steps, up to 256;
  - the interval over step `call` output entries;
  - pre/post-capture hashing with size/stamp checks;
  - the agent/user/unknown rules, including open, orphaned and foreign records and the floor;
  - 64 paths of 4 MiB each, with 64 outstanding reads engine-wide and reads abandoned at the deadline.

  Extend `SensoriumChange` and render `changes_since_last_turn` with folds. Verify that the group-4 rows and the row mapped to `vcs_real_test` (one file edited) turn green.
- [ ] 4.3 Document in `README.md` what `changes_since_last_turn` means, the meaning of `by: agent/user/unknown`, and the baseline reset. Verify that it agrees with ADR 0017.

## 5. Notices, admission and status

- [ ] 5.1 Write failing tests for the notices rows (all six codes, none) and for the turn-perception rows: known jobs with collected vcs, unchanged VCS facts, reconnect, and status preview. Use the real writer and RPC framing, and compare journal bytes before and after status. Verify that each test fails for the missing behaviour.
- [ ] 5.2 Implement:
  - the `vcs_timeout`, `vcs_failed`, `user_edits` and `baseline_reset` notice codes, in fixed order after the existing two, with `… +N more`;
  - a synchronous `WorkspaceObserver` call inside `RequestBuilder.build`, with the observation admitted by the guarded pre-stream merge;
  - a read-only status preview under the same lock and deadline.

  Verify that the group-5 rows turn green and that the three ride-along `green` rows still pass.
- [ ] 5.3 Update the observation and status sections of `README.md`, and the built-in perception guidance, for the vcs and changes sections and the new notice codes. Verify that the documented metadata matches what RPC actually materializes.

## 6. Qualify the integrated slice

- [ ] 6.1 Run every test file in the map through the official Dart MCP runner, then the pinned analysis and format checks for the changed files. Verify that every row has executed green evidence, and that CI ubuntu + windows passes.
- [ ] 6.2 Dogfood with Kehai: run a real multi-step change in a jj repository and a plain git repository, edited by both the agent and the user. Record the admitted vcs/changes sections, the attribution outcomes and the block token estimates. Record the friction-ledger dispositions from D9 and any unsupported steps, together with their roadmap assignments. Verify that the evidence is recorded in the design's apply notes.
- [ ] 6.3 Obtain the configured pre-ship review, and successful Linux and native-Windows CI on the delivery head. Address the findings through the installed workflow. No version bump, because releases are disabled.

## Workflow follow-up

- Ship the PR with `specwright-pr`, request `@codex review` as `sh1ny`, and merge once CI is green and the review is resolved.
- Archive with `/opsx:archive`, then run `specwright-finish` (`finish: pr`).
