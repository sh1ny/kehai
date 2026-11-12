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
A live `edit`/`write` call removed by rewind or superseded SHALL leave its target in a rewind-exempt `meta` record. Baselines SHALL carry a capture sequence number that never repeats. A record SHALL apply while unfinished or when the compared baseline was captured before it finished; its target then reads `by: unknown` without `user_edits`. Records SHALL NOT be deleted on release.

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

### Requirement: Forks do not finish the parent's mutations
Orphaned-mutation records SHALL name their owning session. Forking SHALL copy every mutation open in the parent at fork time, own or inherited, into the child as a foreign record. Recovery SHALL finish only records owned by its session. Foreign records SHALL apply to every comparison in the child, at most 16 per session; beyond that, one overflow marker SHALL make every change row `by: unknown`.

#### Scenario: Parent rename held through child recovery
- **WHEN** a parent `write` of `lib/a.dart` holds its rename, the session is forked, the child resumes, captures and admits a baseline, the parent's rename is then released, and the child builds its next request
- **THEN** the child's recovery does not finish the parent's record or mark the inherited call finished on its behalf, and the child lists `lib/a.dart` as `by: unknown` without `user_edits`

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
Attribution hashing SHALL run asynchronously inside the collection deadline, only for paths with an effect in the interval: at most 64 paths of at most 4 MiB each. At most 64 attribution reads SHALL be outstanding per engine, abandoned ones included; at that limit no new read starts. A path not hashed in time, at the limit or beyond the bounds SHALL read `by: unknown`.

#### Scenario: Oversized file
- **WHEN** the agent wrote a 20 MiB file in the interval and it changed
- **THEN** it is listed with `by: unknown` and its content is not hashed

#### Scenario: Read never completes
- **WHEN** the read of a path with an agent effect never completes
- **THEN** the request is built at the deadline, that row reads `by: unknown`, and the read's result is ignored if it arrives later

#### Scenario: More than 64 effect paths
- **WHEN** 100 agent-written files changed in the interval
- **THEN** at most 64 are hashed, the rest read `by: unknown`, and the listing shows at most 12 rows with `… +88 more`

#### Scenario: Reads that never complete across many requests
- **WHEN** every attribution read stalls forever and 100 requests are built
- **THEN** no more than 64 attribution reads are outstanding at any time, every request is built by its deadline, and affected rows read `by: unknown`
