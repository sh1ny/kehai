# ADR 0017: VCS observation baselines and provenance attribution

Status: accepted
Supersedes: none; supplements ADRs 0007, 0010 and 0016

## Context

M2 needs repository state on every request and honest attribution of changes since the previous admitted capture. The governing contract is [vcs-changes-and-notices design D1–D9](../../openspec/changes/vcs-changes-and-notices/design.md), with requirements for [VCS observation](../../openspec/changes/vcs-changes-and-notices/specs/vcs-observation/spec.md), [workspace change attribution](../../openspec/changes/vcs-changes-and-notices/specs/workspace-change-attribution/spec.md) and [turn perception](../../openspec/changes/vcs-changes-and-notices/specs/turn-perception/spec.md). This records the reviewed architecture, not implementation or qualification evidence.

The one-tree journal, central results, unified jobs, native continuity and RPC v1 remain unchanged. The sensorium specification and accepted predecessor ADRs remain unchanged. Hashes are authoritative; timestamps and watchers never prove authorship. `by: user` means outside this session's recorded provenance, not verified human identity.

## Decision

### One observer, serialized within an engine

A deep module at `workspace/vcs_collector.dart` exposes collection behind an injected `WorkspaceObserver`. Request building copies the acknowledged tree and freezes the clock before awaiting collection and composition. Status uses the same observer but discards its capture; the observer never writes the journal. There is no background collector, watcher, plugin registry or periodic refresh.

Observe the nearest ancestor containing `.jj` or `.git`, preferring jj when both exist. Strict startup `vcs.backend` accepts `auto` (default), `jj`, `git` and `none`. Disabled observation starts no process and marks both sections unavailable. Repository-relative paths use `/`, including on native Windows; a workspace below the repository root still observes that whole repository. Nested repositories and submodules are not recursively collected.

### Content-addressed captures without changing user staging

For jj, ordinary working-copy snapshotting supplies `@`'s commit id as the baseline. Read-only follow-ups use `--ignore-working-copy`; retain the change id, first description line, parent, status counts, conflicts and operation id. Verify pinned jj 0.46.0 per-file stat templates in a disposable repository; bounded `--git` diff parsing is the alternative if those templates are unavailable.

For git, create a fresh private index copy from the user's current index for every collection, then run `git add -A` and `git write-tree` with `GIT_INDEX_FILE` set to that copy. This preserves current tracked-file membership, including force-added ignored files and files removed from staging with `rm --cached`. The capture covers tracked and non-ignored untracked content. Compare tree ids with `git diff --numstat -z`; support an unborn HEAD and binary deltas. Retain HEAD, branch or detached state, parent, counts and conflicts.

Observation never writes the user's index, refs, bookmarks, HEAD or working-tree files. jj may add ordinary snapshot operations; git may add unreferenced blob/tree objects that git's own prune eventually removes. No Kehai object pruning or alternate content store is introduced.

Use a fixed command plan, with an argv allowlist test: no fetch, push, pull, clone, checkout, switch, restore or smudge. Repository-configured clean filters and fsmonitor may run under the deadline, as for status-equivalent reads; do not emulate or disable them. Set `GIT_OPTIONAL_LOCKS=0` and `GIT_TERMINAL_PROMPT=0`, with no pager or color. Unsafe unattended repository filters can be excluded with `vcs.backend: none`. Resolve executables using `resolveProgram`, accepting only absolute PATH entries outside the workspace.

### Admitted metadata owns baselines and last-known values

The existing guarded pre-stream merge admits `sensorium.vcs = {state, reason?, observed: {time, turn}, value, baseline?}` beside the exact rendered text, token estimate, mode, folds and source. A baseline contains backend, content id, capture turn/time, monotonic `seq` and `jobsLive`. This is local admission, never proof of provider receipt.

A successful collection records its new capture. A failure carries the previous effective baseline unchanged, including its original capture turn, and the last-known observation and its age. The latest admitted observation therefore remains sufficient after arbitrarily many consecutive failures. Search backward through at most 256 steps, skipping only steps without an admitted observation. Exhaustion means baseline lost, never no baseline.

A first request reports `unavailable (no baseline)`. An unreadable/pruned id, backend switch or exhausted lookup reports `unavailable (baseline lost)`, raises `baseline_reset` and establishes a new baseline. No cross-backend translation is attempted. Rewind, fork and resume read surviving step metadata; no side cache owns a baseline. Cancellation or rewind before guarded admission records no capture, and reconnect reads the admitted observation rather than today's repository.

### Mutation provenance is durable before touching files

Before `edit` or `write` mutates anything, record `target`, the resolved repo-relative path after following symlinks in the path and parents, through the single writer under the call's ownership/cancellation guard. A refused target record aborts before mutation. Match provenance by this recorded target, never by the typed input path or a subsequently retargeted symlink. Targets outside the repository do not match repository rows. On success record `effect: {sha256, seq}` of the bytes written.

Concurrent calls can finish in a different order from their creation or response entries. Existing `PathLocks.run` scopes hold each resolved target through validation, visible rename and the awaited effect commit, or failure/quiescence. A cancelled waiter aborts before mutation; a stalled holder remains counted by the 16-run cap. Thus effect sequence order equals visible rename order for an unambiguous lock key without adding another mutex. The writer reserves each effect sequence from the shared capture/finish allocator, durably raises `meta/vcs/seqHigh`, and records the effect within one guarded queue operation. Highest sequence means latest effect outside case-alias ambiguity. Any interval effect missing a sequence prevents agent proof for its target. Baseline admission also follows a durable high-water raise, so neither rewind nor restart reuses a committed sequence.

Case-variant spellings are deliberately conservative: compare each row's raw repo-relative spelling with interval mutation targets and applying open/orphan/foreign targets. Different spellings equal after lowercase conversion make that row `unknown`, overriding successful-effect proof and contributing no `user_edits`. This includes a differently cased row with one recorded target and distinct case-sensitive Linux paths. Existing lock equality stays unchanged; no volume probe or additional persisted field is required.

The first accepted pre-mutation target append also records `targetAfterSeq`, the durable `meta/vcs/seqHigh` at that queue head, or zero if the counter is absent. It is a watermark, not a sequence reservation, and adds no flush. An unresolved interval target blocks agent proof unless the latest verified same-target effect has a greater sequence. A missing legacy boundary leaves the order unestablished; readers do not substitute zero. This distinguishes a cancelled write followed by a successful one from a later cancelled rename followed by a user restoration of an older effect. Open/orphan/foreign and case-alias uncertainty still override proof.

The runtime maintains a derived index of quiesced mutation keys, their quiescence turns and surviving step-call links. Rebuild it with open keys from the tree on resume and rewind; update it during durable finish/retirement before the writer queue advances. Freeze relevant keys with the request's tree/time and validate against that tree. There is at most one entry per surviving mutation call, no separate authority, and no per-request scan of all calls to discover late quiescence.

When the actual tool future finishes for any reason, record `quiesced: true` under an identity guard at the writer queue head: the call must still exist with the original attempt; terminal states are allowed. An absent or superseded node is refused without creation or modification. Recording quiescence does not change the call's terminal outcome.

A call with a target but no quiesced record stays open across every intervening baseline, even when cancellation detached the still-running rename. Derive the engine's open-call key set from the current tree after resume and every rewind, unioned with the unfinished-run registry. Resume recovery includes terminal cancelled edit/write calls without quiescence; the previous engine's work is no longer live. A quiesced call belongs to the interval containing the quiescence record's turn.

At most 16 edit/write futures may remain unfinished per engine, including detached cancelled runs. Refuse another before resolving or mutating anything, with an error naming the unfinished count. Release capacity only when the actual future finishes; never evict open targets.

### Removed runs leave rewind-exempt, session-owned uncertainty

Before a rewind loses a live mutation's recorded target, the writer durably preserves `meta/orphanedMutations/<runId> = {target, session}` and then appends the rewind within the same queue operation. It builds the rewind record once at the current turn and validates it before either append, so invalid rewinds append nothing. Preservation records use that same turn and cannot invalidate the prepared cut. Existing records are retained without clearing `finishedSeq` or redundant preservation. It compares the projected call path, attempt and target, including a call that survives without its later target field. Both records use the ordinary append/flush/commit/publish path. A crash before the cut is conservative; a crash after it cannot erase the target. Supersession and identity-guard refusal also preserve orphan uncertainty. If late completion finds no record, it creates one already finished.

The engine's bounded unfinished-run registry is authoritative for open targets in attribution and fork. It publishes a resolved target only inside the accepted guarded append's queue-head decision, before its target append can commit. Fork reads its provider inside the writer's queue decision and deduplicates foreign records by run id. The write-ahead meta record, not the registry or a post-rewind callback, preserves uncertainty across engine death.

Every run's finish checks at the writer queue head for an unfinished orphan record owned by this session, whether the call's quiescence merge was accepted or refused. It records `finishedSeq` and raises `seqHigh` for that record, including one preserved for a surviving call. The registry entry is retired only after all required finish records are durable and before the queue advances.

Collections that can be admitted reserve increasing capture sequence numbers from an engine counter seeded from `meta/vcs/seqHigh`. Baseline admission and mutation completion monotonically raise that persisted high-water mark. Finishing an orphan records `finishedSeq` using the next unallocated number; recovery finishes only records owned by its own session. A baseline without a sequence is treated as sequence zero.

An orphan applies while unfinished or when `baseline.seq < finishedSeq`. Reserve the capture sequence before capture work, so a finish during capture still applies to the following comparison. An applying target is unknown, never a user edit. Do not delete on release: restoring an older baseline by rewind must make that record apply again.

Keep at most 64 finished records, in addition to live records bounded by the 16-run limit. Evicting the oldest finished record monotonically raises `meta/vcs/attributionFloor` to its finish sequence. Comparisons against a baseline below that floor classify every row unknown without `user_edits`, including after subsequent rewind.

### Forks retain foreign uncertainty

Inside the parent's serialized `SessionWriter.fork`, copy every mutation open anywhere in the parent's current tree, unfinished own orphan records and inherited foreign records into the child's meta as foreign records naming their owning session. This includes open work beyond an earlier forked prefix. A parent may still finish its rename after the child starts; the child writer's lock gives no authority over that parent engine.

Foreign records have no finish sequence, are never finished by child recovery and apply for the child's entire lifetime. Recovery may quiesce copied call nodes because the foreign record preserves uncertainty. Keep at most 16 foreign records; beyond that set `meta/vcs/foreignOverflow`, making every child change row unknown without `user_edits`. Parent mutations begun after the fork are outside the child's provenance, like any other process.

### Attribution uses the baseline response and capture verification

The interval contains calls linked from step `call` outputs at turns `[baseline.captureTurn, currentTurn)`, plus jobs live at capture or started by those calls. Include the baseline request's own response; exclude earlier responses. Shell calls, child agents, recorded hook runs and relevant jobs count as process-running activity. An interval edit/write without a target also counts as process-running activity.

Before and after capture, asynchronously hash only paths with interval effects, recording byte size and modification stamp. A row is agent-attributed only when both hashes equal the latest successful effect and size/stamp are unchanged. Compare on-disk bytes, not repository blob ids, so autocrlf and clean-filter conversion do not change authorship.

Otherwise classify unknown when an interval effect exists, an unresolved targeted mutation applies, an open/orphaned/foreign mutation applies, the floor/overflow requires uncertainty, or process-running activity occurred. With none of those, classify user and raise `user_edits`. A later successful effect may prove agent attribution after an earlier unresolved interval mutation, but cannot erase still-open or orphaned uncertainty. Stamps only downgrade. A stamp-preserving rewrite restoring identical bytes between reads is not detectable.

### One deadline and bounded cleanup

Serialize all collections in an engine with one lock. Waiting, pre-capture hashes, process execution and post-capture hashes share one overall deadline. After acquiring the lock, pre-capture hashing may wait for at most one third of the remaining budget; unfinished paths become unknown and capture continues without extending the deadline. This is an internal cutoff, not a new user setting. Strict startup `sensorium.collectorDeadlineMs` accepts integers 100–10000, defaults to 300, and the first collection uses at least 3000 ms for cold startup. Independent follow-ups may run in parallel after capture, with at most three VCS processes per collection.

The collector seam accepts latest interval-effect hashes, the shared allocator and frozen `jobsLive`, and returns per-path verification, a completed-capture indication and a current deadline-expired flag. It owns all verification phases inside the lock and budget. Completed capture means the whole command plan is parsed: observation, baseline id, status and diff outcome, including explicit no/lost-baseline outcomes. Reserve capture sequence after acquiring the lock and before pre-hashing. Use one injectable monotonic clock for elapsed time and waits, not the frozen display time. Retained completed captures are available without a timeout reason; only the current result flag supplies the timeout notice. Attribution-only expiry adds no process cleanup lease, while existing uncertain-command quarantine remains intact.

At deadline issue whole-process-tree termination using the shared supervisor kill helper, then return without awaiting termination. A timed-out collection holds one of 16 engine-wide cleanup slots shared by git and jj until all processes, including termination subprocesses, are confirmed gone. Quarantine its private index with the slot: never reuse, unlock or read it. Background termination outcome waits are bounded to 10 seconds; uncertainty or a stalled kill retains the slot until engine exit. At 16 held slots start no process and report cleanup pending. Dispose private indexes after confirmed completion; engine shutdown performs best-effort cleanup.

Bound stdout to 4 MiB and parsed entries to 10,000 per command. Truncation reports partial counts as at least the observed number, never exact clean state. Retain at most 2 KiB stderr and a clipped reason of at most 200 characters. Missing tools, no repository, disabled observation, timeout and failure are explicit unavailable states, or stale with the earlier value and original age; they never mean zero changes.

Hash at most 64 effect paths of at most 4 MiB each, and repeat only completed pre-hashes after capture. At most 64 reads may remain outstanding engine-wide, abandoned reads included; at the limit start no new read. Ignore results after their phase is abandoned and retain their slots until I/O settles. If post-verification reaches the overall deadline, keep the completed VCS capture and baseline and classify unverified rows unknown. Overall deadline expiry emits `vcs_timeout`; the earlier pre-hash cutoff alone does not.

### Bounded presentation and notices

Extend the existing typed sensorium observations, not a collector registry. VCS reports identity, parent, M/A/D counts, conflict counts/paths and operation/HEAD identity. Changes report baseline turn, per-file added/removed lines or binary, and agent/user/unknown attribution. Show at most 12 paths or rows with an explicit omitted count. Keep serialized observation values and baseline within 4 KiB, including carried values.

Keep existing section caps, fold order and the safe minimum of 1310 tokens: VCS 250 tokens (folded counts-only 40), changes 200 (folded paths plus attribution), notices 80. Adapt row counts to fit and preserve `\nvcs:` immediately after budget. Escape controls, DEL, C1 and all presentation line separators in untrusted paths, branch names and descriptions; use only the first description line. Render untrusted fields indented and clip at UTF-8 boundaries with a counted marker. Non-UTF-8 path bytes remain visible as escapes, never silently omitted.

Deduplicate notices in fixed order: `compaction_recovery`, `legacy_window_ignored`, `vcs_timeout`, `vcs_failed`, `user_edits`, `baseline_reset`. Cap with an explicit omitted count rather than refusing composition. Compute codes from this collection and committed facts, with no pending-notices queue. Diagnostics, tests, plan, checkpoints and post-edit delta producers remain out of scope.

## Alternatives and consequences

- No separate baseline/hash-content store, shared reusable private index, watcher authority, background refresh, filter emulation, cross-backend translation or Kehai object pruning. These duplicate repository semantics or introduce extra mutable authority.
- Git captures grow the unreferenced object store until normal prune; jj captures may grow its operation log. Deadline failures and partial coverage remain visible rather than being disguised as clean.
- A live shell/job or foreign mutation can conservatively classify many changes unknown. This is preferable to falsely blaming the user or claiming agent authorship.
- Frozen observations describe capture time; edits after capture appear in the next comparison. Pre-admission cancellation leaves the older baseline effective.
- Test deadlines and held mutations with deterministic barriers, not sleeps or wall-clock assertions. Qualify real pinned jj/git in disposable repositories on Linux and native Windows.
- Kehai orchestrates the apply attempt. Record unsupported steps, real dogfood evidence, collector timing and friction-ledger dispositions in the change design's apply notes. Permissions/config/instructions friction and broader relative-PATH restoration stay assigned to `windows-tool-parity-and-m2-qualification`; this collector still tests skipped relative PATH entries. No new package, polling loop or version bump is introduced.
