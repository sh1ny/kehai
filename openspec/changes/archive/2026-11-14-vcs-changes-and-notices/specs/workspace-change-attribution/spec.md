# Spec Delta

## Purpose

Tells the model which files changed since its previous request, by how many lines, and whether the change is provably its own, provably outside its tools, or unknown, so it re-reads files the user touched instead of clobbering them.

## ADDED Requirements

### Requirement: Content-addressed baseline per admitted request
Each admitted request SHALL record with its observation the effective change baseline: a content-addressed working-copy id (jj commit id or git tree id), backend, capture turn and time, and whether a job was live. A failed collection SHALL carry the previous effective baseline forward unchanged. Recording SHALL NOT change the user's index, refs or working tree.

#### Scenario: Baseline recorded on admission
- **WHEN** a request at turn 13 is admitted in a git repository and collection succeeds
- **THEN** that step's metadata holds a git tree id captured at turn 13 covering tracked and non-ignored untracked files, and the user's index and refs are unchanged

#### Scenario: Collection failed
- **WHEN** collection times out for the request at turn 14 after turn 13 captured a baseline
- **THEN** turn 14's metadata carries turn 13's baseline forward with its original capture turn, and turn 15 diffs against it

#### Scenario: Long run of failures
- **WHEN** 300 consecutive admitted requests fail collection after a baseline was captured
- **THEN** the next successful request still diffs against that carried baseline rather than reporting `no baseline`

### Requirement: Changes since the last baseline
`changes_since_last_turn` SHALL list each file whose content differs between the effective baseline and the newly captured one, with added/removed line counts (`binary` for binary files), up to 12 rows plus an explicit `… +N more`, and the baseline's capture turn. Unchanged files SHALL NOT appear.

#### Scenario: One file edited
- **WHEN** the baseline captured at turn 13 and the current capture differ only in `lib/session/pool.dart` by 12 added and 2 removed lines
- **THEN** the section lists `lib/session/pool.dart +12 -2` since turn 13 and no other file

#### Scenario: Nothing changed
- **WHEN** the current capture equals the effective baseline
- **THEN** the section reads `none`

#### Scenario: First request of a session
- **WHEN** no admitted step carries a baseline
- **THEN** the section reads `unavailable (no baseline)` and this request's capture becomes the baseline

#### Scenario: Baseline lost
- **WHEN** the effective baseline id no longer resolves (pruned object, abandoned jj operation, or a resumed session on another clone)
- **THEN** the section reads `unavailable (baseline lost)`, `notices` carries `baseline_reset`, and the new capture becomes the baseline

#### Scenario: Backend changed
- **WHEN** the effective baseline was captured with git and the current collection uses jj
- **THEN** the section reads `unavailable (baseline lost)` with `baseline_reset` rather than comparing ids across backends

#### Scenario: No admitted observation within the lookup bound
- **WHEN** none of the 256 most recent steps carries an admitted observation
- **THEN** the section reads `unavailable (baseline lost)` with `baseline_reset`, never `no baseline`

### Requirement: Attribution interval
The attribution interval for a request SHALL be the tool calls linked from the responses of steps at turns from the baseline's capture turn up to, but excluding, the current turn, plus jobs live at capture or started by those calls. Calls run in response to the baseline's own request SHALL be inside the interval.

#### Scenario: Edit in response to the baseline request
- **WHEN** turn 13 captured the baseline, its response called `edit` on `lib/a.dart`, and turn 14 is built
- **THEN** that edit is in turn 14's interval and can attribute `lib/a.dart` to the agent

#### Scenario: Shell call in response to the baseline request
- **WHEN** turn 13's response ran `bash`, which changed `lib/b.dart`, and turn 14 is built
- **THEN** the shell call is in the interval and `lib/b.dart` is not reported `by: user`

#### Scenario: Hook run in the interval
- **WHEN** a recorded hook ran for a call in turn 13's response and `lib/c.dart` changed with no matching effect
- **THEN** `lib/c.dart` reads `by: unknown`

#### Scenario: Calls before the baseline
- **WHEN** an `edit` of `lib/a.dart` ran in response to turn 12 and the baseline was captured at turn 13
- **THEN** that edit is outside turn 14's interval and cannot attribute a later change of `lib/a.dart`

### Requirement: Attribution from recorded provenance
A listed file SHALL read `by: agent` only when the interval's latest successful edit/write effect for that path hashes equal to the file's bytes both before and after the capture, with size and modification stamp unchanged across it. Otherwise `by: unknown` when the path has an effect in the interval or process-running activity (shell call, hook run, child agent, job) occurred; otherwise `by: user`. Stamps only ever downgrade to `unknown`.

#### Scenario: Agent edit
- **WHEN** the agent's `edit` of `lib/a.dart` succeeded in the interval and the file hashes equal to that effect before and after the capture with an unchanged stamp
- **THEN** the row reads `by: agent`

#### Scenario: User edit with no agent activity
- **WHEN** `lib/auth/login.dart` changed in the interval and no call in the interval touched it and no process-running activity occurred
- **THEN** the row reads `by: user`, and `notices` carries `user_edits`

#### Scenario: File rewritten around the capture
- **WHEN** the agent wrote content B to `lib/a.dart`, a write of C is captured, and the file is restored to B before the post-capture hash
- **THEN** the modification stamp differs across the capture and the row reads `by: unknown`, not `by: agent`

#### Scenario: Content differs from the agent's effect
- **WHEN** the agent edited `lib/a.dart` in the interval and the file's content no longer equals that effect, with no process-running activity
- **THEN** the row reads `by: unknown`, because the agent's own write and a later edit cannot be separated

#### Scenario: Change during a shell command
- **WHEN** `lib/b.dart` changed in an interval where a `bash` call ran and no effect exists for it
- **THEN** the row reads `by: unknown`, never `by: agent` or `by: user`

#### Scenario: Line-ending conversion on Windows
- **WHEN** on native Windows with `core.autocrlf=true` the agent writes CRLF content and nothing else touches the file
- **THEN** the row reads `by: agent`, because attribution compares the bytes on disk, not the converted repository blob

### Requirement: Unresolved mutations are uncertain provenance
An `edit` or `write` call in the attribution interval whose recorded mutation target has no recorded successful effect (pending, running, cancelled, failed after starting, or interrupted by a restart) SHALL make that path read `by: unknown`, never `by: user`, unless a later successful effect for the same path in the interval proves `by: agent`.

#### Scenario: Cancelled during rename
- **WHEN** an `edit` of `lib/a.dart` is cancelled while its atomic rename is in progress, the rename completes, and the next request is built
- **THEN** `lib/a.dart` reads `by: unknown`

#### Scenario: Restart after rename
- **WHEN** the engine dies after a `write` of `lib/b.dart` renamed its file but before the effect was recorded, and the session resumes
- **THEN** the first request after resume lists `lib/b.dart` as `by: unknown`, not `by: user`

#### Scenario: Later successful edit of the same path
- **WHEN** a cancelled `edit` of `lib/a.dart` is followed in the interval by a successful `edit` whose effect matches the captured bytes
- **THEN** the row reads `by: agent`

### Requirement: Mutation targets are recorded before mutation
Before changing the filesystem, `edit` and `write` SHALL durably record the resolved repo-relative target (after following symlinks in the path and its parents) on their call; effects and unresolved mutations SHALL match rows by that target. An interval `edit`/`write` without a recorded target SHALL count as process-running activity.

#### Scenario: Successful write through a symlink
- **WHEN** the agent writes `alias.dart`, a symlink to `lib/a.dart`, and nothing else touches `lib/a.dart`
- **THEN** the row for `lib/a.dart` reads `by: agent`

#### Scenario: Interrupted write through a symlink
- **WHEN** a `write` of `alias.dart` → `lib/a.dart` renames its content and the engine dies before recording the effect
- **THEN** after resume the row for `lib/a.dart` reads `by: unknown`, not `by: user`

#### Scenario: Symlink retargeted before resume
- **WHEN** after that interrupted write the user points `alias.dart` at `lib/b.dart` before the session resumes
- **THEN** the row for `lib/a.dart` still reads `by: unknown`, because the recorded target, not the current link, is used

#### Scenario: Symlinked parent directory
- **WHEN** the agent edits `gen/x.dart` where `gen` is a symlink to `lib/generated` and the edit is cancelled after its rename
- **THEN** the row for `lib/generated/x.dart` reads `by: unknown`

#### Scenario: Call without a recorded target
- **WHEN** an interval `edit` was interrupted before its target could be recorded and an unrelated file changed with no other activity
- **THEN** that file reads `by: unknown`, not `by: user`

### Requirement: Open mutations stay uncertain across baselines
An `edit` or `write` whose tool work may still change its target after the call settled (cancelled while running) SHALL stay open until its work is recorded as finished. An open mutation's target SHALL read `by: unknown` in every request regardless of interval; once finished, the call belongs to the interval containing that record's turn. Resume SHALL close mutations left open by a dead engine.

#### Scenario: Rename finishes after the next baseline
- **WHEN** a `write` of `lib/a.dart` is cancelled at turn 13 while its rename is held, turn 14 captures and admits a baseline, and the rename is then released before turn 15
- **THEN** turn 15 lists `lib/a.dart` as `by: unknown`, and `user_edits` is not raised for it

#### Scenario: Open mutation still pending
- **WHEN** the held rename has not finished when turn 15 is built
- **THEN** the call is still open and any change of `lib/a.dart` reads `by: unknown`

#### Scenario: Engine dies with an open mutation
- **WHEN** the engine dies while a cancelled write's rename is held and the session resumes
- **THEN** resume records the mutation finished at the resume turn, and the first request after resume treats it as part of its interval

#### Scenario: Late work fails without changing the file
- **WHEN** a cancelled write's late work fails before renaming and its finish is recorded
- **THEN** the call no longer keeps `lib/a.dart` open, and a later unrelated change of `lib/a.dart` with no other activity reads `by: user`

### Requirement: Late finish records cannot touch removed or replaced calls
Recording that a mutation finished SHALL succeed only when the call node still exists with the same attempt; a terminal status is allowed. An absent or superseded call SHALL be refused without creating or changing any node, and the set of open mutations SHALL be derived from the current tree after rewind or resume.

#### Scenario: Call removed by rewind before the late finish
- **WHEN** a cancelled `write`'s rename is held, the session is rewound past that call, and the rename is then released
- **THEN** no `body/calls/<key>` node is created, and the target stays uncertain through the orphaned-mutation record instead (see "Removed live mutations stay uncertain")

#### Scenario: Call replaced before the late finish
- **WHEN** after that rewind the same call id is admitted again as a new attempt that is still running, and the old held rename is then released
- **THEN** the new attempt is not marked finished and its target stays open

### Requirement: Removed live mutations stay uncertain
A live `edit`/`write` target lost by rewind or supersession SHALL survive in rewind-exempt `meta`. Rewind SHALL durably preserve it before the cut in the same writer operation; invalid rewinds SHALL append nothing. Baselines SHALL carry unique capture sequences. Records SHALL apply while unfinished or when the baseline predates their finish, making targets `by: unknown` without `user_edits`. Records SHALL NOT be deleted on release.

#### Scenario: Held rename across a rewind and two later captures
- **WHEN** a `write` of `lib/a.dart` reaches a held rename, the session is rewound past that call, turn 14 captures and admits a baseline, the rename is released before turn 15, turn 15 captures and admits a baseline, and turn 16 is built with no other activity
- **THEN** turns 14 and 15 list any change of `lib/a.dart` as `by: unknown`, no request raises `user_edits` for it, and turn 16, whose baseline was captured after the finish, reports no row for the rename

#### Scenario: Rename lands during the capture
- **WHEN** the orphaned rename finishes while turn 15's collection is already running
- **THEN** turn 15's baseline counts as captured before the finish, and the change still reads `by: unknown` in turn 16

#### Scenario: Rewind past the baseline that captured the rename
- **WHEN** after turn 16 the session is rewound to before turn 15's admission, restoring turn 14's baseline, and the next request is built
- **THEN** the restored baseline was captured before the finish, so the record applies again and `lib/a.dart` reads `by: unknown` without `user_edits`

#### Scenario: Engine dies with an orphaned mutation
- **WHEN** the engine dies while an orphaned rename is held, and the session resumes after the rename may have landed
- **THEN** resume marks the record finished, the first request after resume lists any change of the target as `by: unknown` without `user_edits`, and baselines captured after resume no longer apply it

#### Scenario: Orphaned records overflow
- **WHEN** a 65th finished orphaned-mutation record is written
- **THEN** the oldest finished record is evicted and the attribution floor rises to its finish sequence, and every comparison against a baseline captured before the floor reads all rows `by: unknown` without `user_edits`, including after any later rewind

#### Scenario: Request built before post-rewind reconciliation
- **WHEN** a session is rewound past a `write` of `lib/a.dart` whose rename is held, the next request freezes its tree before post-rewind reconciliation, and the rename lands during that request's capture
- **THEN** `lib/a.dart` reads `by: unknown` and `user_edits` is not raised

#### Scenario: Engine dies after the rewind commit
- **WHEN** the session rewinds past a held `write` of `lib/a.dart`, the engine dies after committing the rewind but before recording the late finish, and the rename lands before resume
- **THEN** replay retains the target in an unfinished orphan record, recovery finishes only its own record with a fresh sequence, and the first comparison against a pre-finish baseline reads `lib/a.dart` as `by: unknown` without `user_edits`

#### Scenario: Engine dies after preservation before the cut
- **WHEN** the writer durably preserves a held mutation's target but the engine dies before appending the rewind
- **THEN** replay retains both the call and orphan record, and resume conservatively retains uncertainty without requiring the rewind to have committed

#### Scenario: Rewind removes the target but retains the call
- **WHEN** a live call exists at the rewind destination but its resolved target was recorded in a later turn
- **THEN** the writer preserves that target before the cut, so a crash after the cut cannot erase its provenance; after the run finishes, its orphan record carries `finishedSeq` even though the call survived, and a baseline captured after the finish no longer applies it

#### Scenario: Preservation does not advance the rewind turn
- **WHEN** a valid rewind needs to preserve a held mutation's target
- **THEN** the preservation records and the once-built, pre-validated rewind carry the original current turn, that rewind commits, and `currentTurn` is unchanged by preservation

### Requirement: Forks do not finish the parent's mutations
Orphaned-mutation records SHALL name their session. Forking SHALL copy every open parent mutation, own or inherited, as a foreign record. Recovery SHALL finish only its own records. It MAY quiesce copied calls but SHALL NOT finish foreign records or infer parent completion. Foreign records SHALL apply to every child comparison. Each child SHALL keep at most 16; overflow SHALL make all change rows `by: unknown`.

#### Scenario: Parent rename held through child recovery
- **WHEN** a parent `write` of `lib/a.dart` holds its rename, the session is forked, the child resumes, captures and admits a baseline, the parent's rename is then released, and the child builds its next request
- **THEN** the child's recovery may mark the copied call node `quiesced`, but does not finish the parent's foreign record, and the child lists `lib/a.dart` as `by: unknown` without `user_edits`

#### Scenario: Fork before post-rewind reconciliation
- **WHEN** the parent is rewound past a held `write` of `lib/a.dart` and forked before post-rewind reconciliation
- **THEN** the child holds a foreign record for `lib/a.dart`, and when the parent's rename lands, the child lists it `by: unknown` without `user_edits`

#### Scenario: Parent mutation after the fork
- **WHEN** the parent starts a new `write` after the fork and it lands while the child runs
- **THEN** the child treats it as outside its recorded provenance, as for any other process

#### Scenario: Foreign records overflow
- **WHEN** a fork would carry more than 16 foreign records
- **THEN** the child keeps 16 and sets the overflow marker, and every change row in the child reads `by: unknown` without `user_edits`

### Requirement: Unfinished mutations are bounded
At most 16 `edit`/`write` tool runs SHALL be unfinished per engine at once, counting runs detached by cancellation until they actually finish. At that limit a new `edit` or `write` SHALL be refused before resolving or mutating anything, with an error naming the unfinished count. Open targets SHALL never be evicted to make room.

#### Scenario: Repeated cancellations on a stalled filesystem
- **WHEN** renames never complete and the agent starts and cancels 40 writes to distinct paths
- **THEN** at most 16 runs are unfinished at any time, writes 17 to 40 are refused with the limit error without touching the filesystem, and all 16 targets stay open

#### Scenario: Capacity returns
- **WHEN** one of the 16 held renames finishes and records its finish
- **THEN** the next `write` is admitted

### Requirement: Baselines follow the session tree
The effective baseline SHALL be read only from admitted step metadata in the session tree. Rewind SHALL drop baselines of removed steps, fork SHALL copy them, and resume SHALL use the latest surviving one. No baseline SHALL be kept in a side store.

#### Scenario: Rewind
- **WHEN** a session is rewound to before turn 10 and the next request is built
- **THEN** changes are computed against the effective baseline of the latest surviving step, not a baseline captured in a removed turn

#### Scenario: Resume after engine restart
- **WHEN** the engine restarts and resumes a session whose last admitted step carries a baseline with no live jobs and no calls after it
- **THEN** the first request after resume reports files edited while the engine was down as `by: user`

### Requirement: Attribution work is bounded
Attribution hashing SHALL be asynchronous within the collection deadline and limited to 64 interval-effect paths of at most 4 MiB each. Pre-capture waiting SHALL use at most one third of the remaining budget after acquiring the collection lock. Unfinished or out-of-bounds paths SHALL read `by: unknown`. At most 64 reads SHALL be outstanding per engine, abandoned reads included; at the limit no new read starts. Late results SHALL be ignored.

#### Scenario: Oversized file
- **WHEN** the agent wrote a 20 MiB file in the interval and it changed
- **THEN** it is listed with `by: unknown` and its content is not hashed

#### Scenario: Read never completes
- **WHEN** the read of a path with an agent effect never completes
- **THEN** the request is built within the overall deadline, that row reads `by: unknown`, and the read's result is ignored if it arrives later

#### Scenario: Pre-capture read never completes
- **WHEN** a pre-capture read stalls after a nonzero wait for the collection lock, and capture and remaining verification can finish before the overall deadline
- **THEN** the pre-capture wait stops within one third of the budget remaining after that lock wait, the section is available with the fresh capture and baseline, the affected row reads `by: unknown`, `vcs_timeout` is absent, and the abandoned read keeps its slot until it settles

#### Scenario: More than 64 effect paths
- **WHEN** 100 agent-written files changed in the interval
- **THEN** at most 64 are hashed, the rest read `by: unknown`, and the listing shows at most 12 rows with `… +88 more`

#### Scenario: Reads that never complete across many requests
- **WHEN** every attribution read stalls forever and 100 requests are built
- **THEN** no more than 64 attribution reads are outstanding at any time, every request is built by its deadline, and affected rows read `by: unknown`

### Requirement: Completed captures survive attribution limits
A completed VCS capture and its baseline SHALL be retained when remaining attribution verification reaches the overall deadline. Rows without the required before/after verification SHALL read `by: unknown`. Overall deadline expiry SHALL raise `vcs_timeout`; the earlier pre-capture wait cutoff alone SHALL NOT.

#### Scenario: Post-capture read never completes
- **WHEN** VCS capture succeeds but a required post-capture read never completes
- **THEN** the request retains the captured VCS value and baseline, the affected row reads `by: unknown`, and overall deadline expiry raises `vcs_timeout` without substituting an older observation

### Requirement: Successful effects have durable order
Successful edit/write effects SHALL record SHA256 and a shared monotonic `seq`. In one guarded queue operation, the writer SHALL reserve it, durably raise `meta/vcs/seqHigh`, then commit the effect. For unambiguous target spellings, path locks SHALL cover mutation through effect commit or failure, making rename and sequence order agree. Cancelled waiters SHALL not mutate. Highest sequence SHALL define latest. Any interval effect missing `seq` SHALL prevent agent proof for its target.

#### Scenario: Concurrent same-path effects
- **WHEN** calls A and B are created in that order in one turn but B's successful effect is recorded before A's
- **THEN** A's effect sequence is higher; verified current bytes matching A may read `by: agent`, while bytes restored to B read `by: unknown`, and resume cannot reuse either committed sequence

#### Scenario: Delayed effect commit on a shared target
- **WHEN** A's rename is visible but its effect commit is held, B targets the same resolved file, and the user restores A's bytes after both calls finish
- **THEN** B cannot rename until A's effect commit completes, B receives the higher effect sequence, and the restored bytes read `by: unknown`

### Requirement: Case-variant targets are uncertain
Attribution SHALL compare each changed row's raw repo-relative path with interval mutation targets and applying open/orphan/foreign targets. Different spellings equal under lowercase comparison SHALL make that row `by: unknown`, even on case-sensitive filesystems. This SHALL override successful-effect proof and SHALL NOT contribute `user_edits`.

#### Scenario: Case-variant mutation targets
- **WHEN** same-step writes target `New.txt` and `new.txt` on a case-insensitive volume, then the user restores the first write's bytes
- **THEN** the affected row reads `by: unknown` without contributing `user_edits`, regardless of effect sequence order

#### Scenario: Case-variant row spelling
- **WHEN** a changed row differs only by case from a relevant recorded mutation target
- **THEN** it reads `by: unknown` without contributing `user_edits`, including on a case-sensitive filesystem

### Requirement: Unresolved attempts retain an effect-order boundary
The first accepted target record of a new edit/write attempt SHALL include `targetAfterSeq`: durable `meta/vcs/seqHigh` at that queue head, zero if the counter is absent, without a reservation or extra flush. An unresolved interval target SHALL block agent proof unless the latest verified same-target effect has a greater sequence. A missing boundary SHALL leave the order unestablished and the row `by: unknown`.

#### Scenario: Boundary recorded before mutation
- **WHEN** an edit/write attempt accepts its first target after a successful effect was durably recorded
- **THEN** the target and its boundary are recorded together before mutation, and the boundary is at least that earlier effect's sequence

#### Scenario: Unresolved write after a successful effect
- **WHEN** a successful write is followed in the same turn by a cancelled write whose rename lands and quiesces, then the user restores the successful write's bytes before capture
- **THEN** the row reads `by: unknown`, even though both verification hashes match the older successful effect

#### Scenario: Legacy unresolved target without a boundary
- **WHEN** an unresolved interval target has no recorded boundary and a successful same-target effect matches both verification reads
- **THEN** the row reads `by: unknown`, without substituting zero for the missing boundary

### Requirement: Atomic temporary paths share mutation uncertainty
Each edit/write SHALL publish and durably record its destination, actual atomic temporary path and order boundary together before mutation. The temporary path SHALL remain visible as `by: unknown` through the same open, interval, orphan, recovery and foreign lifetimes, irrespective of successful effects. Missing legacy temporary provenance SHALL make applicable comparisons wholly unknown. Filename patterns SHALL NOT establish ownership or suppress rows.

#### Scenario: Capture while the temporary file exists
- **WHEN** a cancelled edit/write still owns its unignored temporary file while the next request or status preview captures the repository
- **THEN** the temporary-file row reads `by: unknown`, remains visible, and does not raise `user_edits`

#### Scenario: Cleanup after an intervening baseline
- **WHEN** that request admits a baseline containing the temporary file and the old tool then removes it before the following capture
- **THEN** the removal reads `by: unknown` without `user_edits`, even though the destination was unchanged

#### Scenario: Refused pre-mutation intent
- **WHEN** the destination/temporary intent is refused or cannot be persisted
- **THEN** neither the temporary file nor missing parent directories are created and the destination is unchanged

#### Scenario: Capture freezes around intent publication
- **WHEN** a request freezes its attribution input before the atomic intent commits and the temporary file is created during capture
- **THEN** untargeted-run uncertainty or the already-published complete footprint prevents that file from being attributed to the user; no primary-only publication gap exists

#### Scenario: Temporary cleanup after rewind and restart
- **WHEN** rewind loses either path of a live atomic mutation and the engine dies after the cut
- **THEN** replay retains both paths in the same orphan record, recovery finishes only its own record, and comparisons against pre-finish baselines classify temporary creation/removal `by: unknown`, including after restoration of an older baseline

#### Scenario: Parent cleanup after child recovery
- **WHEN** a fork inherits a parent mutation with a live temporary file, the child recovers and captures it, and the parent later removes it
- **THEN** the child's foreign record retains both paths without being finished by child recovery, and the removal reads `by: unknown` without `user_edits`

#### Scenario: Unrelated user file resembles an atomic temporary
- **WHEN** a user changes an unrecorded `.name.kehai-0123abcd` file with no applying provenance or process activity
- **THEN** its row remains visible as `by: user` and raises `user_edits`

#### Scenario: Independent successful write to a temporary path
- **WHEN** another call has a verified successful effect for a path still covered as an atomic temporary in the interval or applying record
- **THEN** the path reads `by: unknown`, because the destination's lock does not order writes to its temporary path

#### Scenario: Legacy footprint lacks a temporary path
- **WHEN** an interval edit/write or applying open/orphan/foreign record has a destination but its legacy `temporary` field is absent
- **THEN** replay, preservation, finish, recovery and fork accept and retain that absence without inventing a path or throwing, and the comparison classifies all rows `by: unknown` without `user_edits` for only the existing interval or applying lifetime
