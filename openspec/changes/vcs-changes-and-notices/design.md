# Design

## Triage

| Trigger | Applies? | Evidence |
|---|---|---|
| T1 Components (new component, or 3+ with directed relationships) | Yes | New VCS collector module; driver → request builder → collector → external `jj`/`git` processes; edit/write tools feed provenance |
| T2 State (persistent state, caches, 3+ state machine) | Yes | New persisted step metadata (VCS observation + baseline) and call-effect hashes; observation availability `available/stale/unavailable` |
| T3 Concurrency (background work, workers/isolates, async, retries) | Yes | Async external processes under a deadline, killed mid-flight; concurrent user git/jj commands and child engines in the same repo |
| T4 Boundaries (data format, migration, shared interface, IPC, external) | Yes | Journal record shapes (step metadata, call effect), parsing external CLI output, new strict startup keys |
| T5 Volume (grows without a fixed bound) | Yes | Status listings, diffs and changed-file sets scale with the repository; per-step metadata grows with the session |
| T6 Risk (security, money, data loss, unrecoverable user data) | Yes | Runs commands in the user's repository (index/refs must stay untouched); untrusted repository text enters the model block |

TIER: FULL

## Context

The proposal (`proposal.md`) states scope. Current code facts this design relies on:

- `SensoriumSnapshot` already has `vcs`/`changes` slots typed `SensoriumObservation<…>` defaulting to `SensoriumUnavailable(notCollected)` (`lib/src/loop/sensorium.dart:186-213`), with `SensoriumAvailable/Stale/Unavailable` (`:72-97`). `SensoriumVcs` holds only `branch` and `paths` (`:128-133`), `SensoriumChange` has no attribution (`:135-141`), `SensoriumReason` is `{notCollected, failed, timedOut}` (`:72`), `SensoriumNotice` is `{compactionRecovery, legacyWindowIgnored}` (`:183`). Renderers: VCS `:473-487` (12-path `_Preview`), changes `:488-503`, notices `:623-625`, observation framing `_observe` `:583-601`. Caps: vcs 250 (folded 40), changes 200 (folded 200), notices 80 (`:10-69`); safe minimum 1310 is derived from these.
- `RequestBuilder.build` copies the tree and freezes `SensoriumSource(turn, time: clock(), offset)` (`request_builder.dart:277-282`), then builds history and composes. Nothing does external I/O today; the only awaited hook is a test seam (`:292`). Notices come from `:315` and `:349-352`.
- The driver writes the running step (`driver.dart:725-751`), calls `build` (`:755-759`), handles `SensoriumCompositionError` as failed step/stopped exchange (`:760-772`), rechecks ownership/cancellation (`:773`) and admits the observation in the guarded pre-stream merge (`:836-854`). Status builds through the same builder (`:337`).
- Call nodes live at `body/calls/<key>` with `turn: writer.currentTurn` (`tools/runtime.dart:1091-1113`, ADR 0010). `edit`/`write` record only `input.path`; `edit` already computes SHA-256 of content for permission approval (`tools/edit.dart:109-110`); writes go through `atomic_write.dart:72`. No touched-path or content-hash record exists.
- No code runs `git` or `jj` (`git.exe` is only located to find git-bash, `shell/detect.dart:225-233`). Program resolution through absolute PATH entries outside the workspace is `shell/direct_exec.dart:29`; Windows tree kill is `taskkill /PID <pid> /T /F` via absolute `%SystemRoot%` path (`jobs/supervisor.dart:476-482,1083-1092`), POSIX process-group kill (`:1048`).
- `projectRoot` finds the nearest ancestor with `.git` or `.jj` (`workspace/project_root.dart:13-28`), treating both alike.
- Startup config is strict (`config/user_config.dart:448-458,516-533,687-700`); `sensorium` allows only `maxTokens`.
- CI installs the `mise.toml` toolchain (jj 0.46.0 pinned) on `ubuntu-latest` and `windows-latest`; `dart test --exclude-tags slow` on PRs, full suite nightly. Process tests use `*_process_test.dart` plus fixtures; only tag is `slow`.

Constraints: Dart 3.x AOT, no Rust core, no embedded script runtime, no durable session state outside the tree (user workspace/VCS files remain external facts, `architecture.md:118`). ADR 0007: `.jj` first, hashes authoritative, watchers/mtime only hints, baselines in tree nodes, `by: user` = outside recorded tool provenance, partial coverage explicit. ADR 0016: frozen bounded snapshot, fixed caps/folds/minimum, bounded notice codes, admitted observation is local admission. The sensorium spec stays unchanged. This change is built by Kehai (M2 rule).

## Decisions

### D1: A synchronous, deadline-bounded collector inside request building

- **Choice:** the deep module `lib/src/workspace/vcs_collector.dart` exposes `WorkspaceObserver.collect(root, backend, deadline, previous, attribution?) → VcsCollection`. An admitting request supplies attribution input containing latest interval-effect hashes, the engine's shared sequence allocator and frozen `jobsLive`; a filesystem-reader seam is injected into the collector. The result contains the VCS observation, baseline, diff entries, per-path before/after verification samples, a completed-capture indication and a current-collection deadline-expired flag. The collector owns the lock, monotonic budget, pre-hashing, VCS commands and post-verification. A completed capture means the whole command plan has been parsed: current observation, baseline id, status and diff outcome, including explicit no-baseline or lost-baseline outcomes. `RequestBuilder.build` freezes its tree and display clock, derives the interval inputs, awaits the observer, and applies attribution from the returned samples before composition. Status uses the same path and discards the candidate baseline. The observer never writes the journal.
- **Rejected:** a background collector/watcher that keeps a `collectors` subtree current between turns, because it adds a second asynchronous writer path, a periodic worker and watcher semantics that ADR 0007 forbids as authority and ADR 0016 declined; staleness would still need the same deadline logic.
- **Reversal cost:** low — private module behind the observer seam.

### D2: Content-addressed baselines owned by the VCS, not by Kehai

- **Choice:** jj: the first command snapshots the working copy (ordinary jj behaviour); the baseline is `@`'s commit id. Diff is `jj diff --from <prev> --to <cur>` with a per-file stat template (`DiffStatEntry.lines_added/lines_removed/status_char`, verified against pinned 0.46.0 in a disposable repo during apply). Git: each collection copies the user's current index into a fresh private file in an engine-run temp directory (the copy keeps git's stat cache, so `add` stays fast, and tracked-file membership always follows the user's repository), then runs `git add -A` and `git write-tree` with `GIT_INDEX_FILE` pointing at that copy, giving a tree id covering tracked and non-ignored untracked files; diff is `git diff --numstat -z <prevTree> <curTree>`. Unreferenced objects stay in the user's object store until git's normal prune. The user's index, refs, HEAD and files are never written. **Filter policy:** Kehai invokes no fetch/push/pull/clone/checkout/switch/restore/smudge (enforced by a fixed command plan and an argv allowlist test); clean filters and fsmonitor configured by the repository run exactly as they would for the user's own `git status`, and only under the collection deadline, which kills their process tree. A repository whose filters are unsafe to run unattended is excluded with `vcs.backend: none`. Kehai does not emulate or disable filters, because that would make the captured tree disagree with the repository's own content semantics.
- **Rejected:** a Kehai-owned per-file hash map plus stored previous contents (in the result store) to compute line deltas, because it needs our own ignore-rule engine, stores copies of user files in session payloads with unbounded growth, and duplicates what both VCSs already do content-addressed. Also rejected: `git stash create` (uses the real index and excludes untracked files).
- **Reversal cost:** medium — the baseline id format is persisted in step metadata; old sessions would lose only their last baseline (`baseline lost`, D6), never data.

### D3: Baselines and last-known observations live in admitted step metadata

- **Choice:** the guarded pre-stream merge (`driver.dart:836-854`) adds `sensorium.vcs = {state, reason?, observed: {time, turn}, value: <bounded observation>, baseline?: {backend, id, jobsLive}}` beside the existing `text/tokens/mode/folds/source`. A step whose collection failed carries the previous effective baseline (with its original capture turn) and the last-known observation forward, so the effective baseline and the `stale` value are always read from the latest admitted step. The backward scan only skips steps without an admitted observation (failed composition, cancellation before admission), bounded at 256; exhausting it is reported as `baseline lost` with `baseline_reset`, never as `no baseline`. Rewind, fork and resume therefore need no new code path (tree diff semantics), and reconnect reads exactly what was admitted.
- **Rejected:** a separate `collectors/vcs` node overwritten each turn, because it duplicates the per-step observation already being admitted and creates a second copy whose consistency with the step's text must be maintained.
- **Reversal cost:** medium — persisted record shape; additive fields only.

### D4: Attribution from recorded provenance, verified around the capture

- **Choice:** before touching the filesystem, `edit` and `write` record `target` (the resolved repo-relative path, after `realPath` follows symlinks in the path and its parents, `edit.dart`/`write.dart`) on their call node through the single writer under the call's ownership guard; when they succeed they record `effect: {sha256, seq}` for that target. Rows match by `target`, never by the typed `input.path`, so a later retargeted or removed symlink cannot redirect provenance. An interval `edit`/`write` without a `target` record (interrupted before recording, or a pre-upgrade call) counts as process-running activity. A target outside the repository is not a repository row and is ignored. **Open mutations:** a cancelled `edit`/`write` can keep running after its terminal record (`runtime.dart:678,700` detach `_late`; `atomic_write.dart` lets a started rename complete), and `_late`'s guarded write is refused once the call is final (`runtime.dart:750-763`). So `edit`/`write` additionally record `quiesced: true` through the single writer under an **identity guard** — at the queue head the node must exist with the original `attempt`; terminal status is allowed; an absent or superseded node is refused without creating anything (the tree's merge would otherwise create an absent node, `session/tree.dart:128`) — without changing the terminal state, when their tool future finishes for any reason; recovery records it for every unquiesced edit/write when it reconciles interrupted calls on resume (`jobs/recovery.dart`). A call with a `target` but no `quiesced` record is open: its target reads `unknown` in every request regardless of interval. A quiesced call belongs to the interval containing the turn anchor of its `quiesced` record. Open calls are found from a per-engine set of call keys derived from the tree after resume and after every rewind, unioned with the unfinished-run registry, not by scanning all calls each request. Recovery's walk is extended to terminal cancelled edit/write calls without `quiesced` (it currently skips terminal calls). **Orphaned mutations:** a rewind removes call nodes but cannot stop a started rename (`runtime.dart:474` cancels, `:678` detaches, `atomic_write.dart` lets the rename complete), and the identity guard rightly refuses its finish. So when a rewind removes, or a re-admission supersedes, a call whose edit/write run is live, the runtime writes `meta/orphanedMutations/<runId> = {target, session}` through the single writer, `session` being the owning `meta/session`. `meta` is never rewound (`session/state.dart:151-159,204-209`), and jobs already keep rewind-exempt records there (`meta/orphans`, `meta/handoffs`). If an identity-guard refusal finds no record, it writes one already finished. Every run's finish also checks at the writer queue head for an unfinished orphan record owned by this session and finishes it, whether its quiescence merge was accepted or refused. This includes records the writer preserved for a surviving call. A run whose target record is refused by the ownership guard aborts before mutating, so it needs no record. **Capture sequence, not deletion:** a deletion in `meta` cannot be undone by a rewind, while the baseline that justified it can be, so release is a comparison, never a delete. Every collection that can be admitted takes a capture sequence number `seq` from an engine counter, stored with its baseline (`baseline.seq`). The counter is seeded on start from `meta/vcs/seqHigh`, which is raised durably before a baseline or effect record is admitted and when an orphan record is finished, so a number never repeats across rewind or restart. When an orphaned run's future finishes, the runtime merges `finishedSeq` = the next unallocated number, and raises `seqHigh` to it; recovery does the same on resume, but only for records whose `session` is its own session: the writer's single-writer lock proves only that this session's previous engine is gone. A record **applies** to a comparison against baseline *b* when it has no `finishedSeq` or `b.seq < finishedSeq` — the baseline was captured, or its capture began, before the finish. An applying record's target reads `unknown` and is never a user edit. A rewind that restores an older baseline therefore makes the record apply again by itself. Baselines without `seq` (pre-upgrade) count as `seq` 0. **Forks:** `SessionWriter.fork` copies the parent's `meta` (`session/writer.dart:434-446`) while the parent engine may still be renaming in the same workspace. So the fork, inside the parent's writer, also writes into the child's meta a foreign record `{target, session: parent, foreign: true}` for every mutation open in the parent at that moment: calls with `target` and no `quiesced` anywhere in the parent's current tree (not only the forked prefix), the parent's unfinished own records, and its inherited foreign records. Recovery never finishes foreign records, and they have no `finishedSeq`, so they apply to every comparison in the child. Child recovery may still mark the copied call nodes `quiesced`, because the foreign record now carries the uncertainty. This mirrors the job handoff rule that inherited foreign launches are recognised by their recorded session (`jobs/recovery.dart:479`). Writes the parent starts after the fork are another engine's work, outside this session's recorded provenance, which ADR 0007 defines as `by: user`. Foreign records are retained for the child's life, at most 16 per session; if a fork would carry more, the child keeps 16 and sets `meta/vcs/foreignOverflow`, which makes every change row `unknown` without `user_edits` in that session. **Bound:** live records are within the 16-run cap. Finished records are kept up to 64. Writing a 65th evicts the oldest and raises `meta/vcs/attributionFloor` to its `finishedSeq` (monotonic, never lowered). Every comparison against a baseline with `seq` below the floor reads all rows `unknown` without `user_edits`, because evicted provenance may matter there. This stays true after any later rewind, and is conservative rather than wrong. **Capacity:** an engine-wide counter of unfinished edit/write tool runs (including runs detached by cancellation, `runtime.dart:416-420,678-700`) is capped at 16; at the cap a new edit/write is refused before resolving or mutating, with an error naming the count, and decremented only when the tool future actually finishes. Open targets are never evicted. **Interval:** the calls linked from the `call` output entries of steps at turns `[captureTurn, currentTurn)` (`driver.dart:1205-1217`). Those calls run after their step's admission and are anchored at that step's turn (`driver.dart:953-1006`, `runtime.dart:1097`), so the baseline request's own response is inside the interval and earlier calls are outside. Jobs count when `jobsLive` was true at capture or a job was started by an interval call. **Verification:** before the capture, Kehai reads and hashes each path that has an effect in the interval and records its size and modification stamp; after the capture it repeats this. A row is `agent` only if both hashes equal the latest effect's hash and size and stamp are unchanged, which proves the captured bytes are the agent's bytes, short of a stamp-preserving rewrite. Otherwise: `unknown` if the path has an effect, or an interval `edit`/`write` call targeted it without a recorded successful effect (pending, running, cancelled, failed after starting, interrupted by restart — the atomic rename can complete after cancellation, `atomic_write.dart`, and late completion is rejected by the runtime's ownership guard, `runtime.dart`), or process-running activity occurred (`bash`/`agent` calls, calls with recorded hook runs, interval jobs); else `user`. Stamps only downgrade. Comparing bytes on disk rather than repository blobs keeps `core.autocrlf` and filter conversions out of attribution, so Windows and Linux behave identically.
- **Durable effect order:** calls in one step run concurrently, so call creation and response-output order do not identify the last successful write. Reuse the existing `PathLocks.run` scope in `edit` and `write`: it holds the resolved-target slot through validation, visible rename and the awaited effect commit, or failure/quiescence. Same-key waiters cannot overtake an effect commit; cancelled waiters abort before mutation, and stalled holders remain counted by the 16-run cap. This makes effect sequence order equal visible rename order for an unambiguous resolved-target key. Under the accepted ownership guard, one writer queue operation reserves `effect.seq` from the shared capture/finish allocator, durably raises `meta/vcs/seqHigh`, then commits `effect: {sha256, seq}`. Highest sequence is latest outside case-alias ambiguity. Any interval effect missing a sequence prevents agent proof for that target. The driver likewise raises the high-water mark before admitting a baseline; unused reservations are harmless, but committed sequences are never reused.
- **Case-alias uncertainty:** for each row, compare its raw repo-relative spelling with interval mutation targets and applying open/orphan/foreign targets. If different spellings compare equal after lowercase conversion, that row is `unknown` and does not contribute `user_edits`, regardless of successful-effect proof. This conservative rule applies on every platform, including distinct case-sensitive Linux paths. It covers a differently cased VCS row even with one recorded spelling. Existing lock equality remains unchanged; no volume probes or new record fields are introduced.
- **Unresolved-attempt boundary:** the first accepted target append also records `targetAfterSeq`, the durable `meta/vcs/seqHigh` read at that writer queue head, or zero when that counter is absent. This is a watermark, not a reservation: it adds no sequence allocation or flush. A verified successful effect can override an unresolved interval target only when its `seq` is greater than that target's boundary. Equal/lower sequences, or a missing legacy boundary, leave the row `unknown`; readers never invent zero for a missing boundary. The existing same-target lock makes this a mutation-order proof, while open/orphan/foreign and case-alias masks still win.
- **Derived interval index:** the runtime indexes quiesced mutation keys by their recorded quiescence turn and surviving step-call linkage. It rebuilds from the tree on resume and rewind, and updates a run's entry during durable finish/retirement before the writer queue advances. Keep at most one entry per surviving mutation call. Capture freezes the relevant keys with its tree/time, validates them against that frozen tree and unions the unfinished-run targets. Late quiescence is therefore discoverable without scanning all calls each request. This index is derived lookup state, never baseline or provenance authority.
- **Write-ahead rewind preservation and live reads:** The runtime keeps the same bounded registry of unfinished edit/write runs that the 16-run cap counts. A resolved target is published inside the accepted guarded append's queue-head decision, before its target append can commit; refused targets are not published. Attribution unions these targets with its frozen tree. The writer builds the rewind record once at the current turn, validates it before writing anything, and compares each run's call path, attempt and recorded target with the projected body. For every target that would be lost, it durably preserves the session-owned orphan record before appending that same validated rewind, within the same queue operation. Preservation records carry the rewind record's current turn and cannot advance it. Existing records are retained without clearing `finishedSeq` or appending redundant preservation. This includes a surviving call whose target field would be removed. Ordinary appends and the ordered records share the same append/flush/commit/publish primitive; there is no nested enqueue and no new journal format. At finish, the writer checks for and finishes any owned unfinished orphan regardless of the quiescence guard's outcome, raises `seqHigh`, and retires the registry entry only after the required records are durable and before the queue advances. A crash after preservation but before the cut is conservative; a crash after the cut cannot lose the target. Invalid rewinds append nothing. `SessionWriter.fork` reads the provider inside its own queue decision, deduplicates foreign records by run id, and carries uncertainty even before post-rewind reconciliation.
- **Rejected:** mtime inside a tool-call window (the sensorium spec's sketch), because Windows timestamp and clock behaviour make it unreliable and ADR 0007 makes mtimes hints only. Comparing recorded effects with the snapshot's blob ids, because filter and `core.autocrlf` conversion make the blob differ from the bytes written, and jj exposes no stable per-file content id. A VCS snapshot before and after every mutating call, because it multiplies process launches per call and belongs with entry 5's post-edit delta footer.
- **Reversal cost:** medium — `target` and `effect` are persisted call fields; attribution rules themselves are low cost.

### D5: One deadline per collection, kill the tree, no background continuation

- **Choice:** collections in one engine run are serialized by one async lock. Waiting for it, the pre-capture hashes, all commands and the post-capture hashes share one deadline: `sensorium.collectorDeadlineMs`, default 300 ms per the sensorium spec, range 100–10000; the first collection of an engine run uses `max(deadline, 3000 ms)` to absorb cold caches and the git index copy. Independent commands run in parallel after the snapshot step (jj read-only follow-ups use `--ignore-working-copy`). At the deadline every live command's process tree is killed with the supervisor's existing kill helper, extracted into a shared function rather than copied. Programs resolve through `resolveProgram` (absolute PATH entries outside the workspace). Environment: `GIT_OPTIONAL_LOCKS=0`, `GIT_TERMINAL_PROMPT=0`, no pager, no color. File reads are asynchronous; at the deadline outstanding reads are abandoned (late results ignored) and their rows become `unknown`. At the deadline the collection issues tree termination (the supervisor's kill helper, extracted and shared) and returns without awaiting it; the termination's own outcome is awaited in the background with a bound. Private index files are never reused or unlocked: each collection uses a fresh copy, and a timed-out collection's copy is quarantined until termination is confirmed, or until engine exit when termination is uncertain (Windows `taskkill` reports descendants as unverifiable). **Cleanup slots, backend-independent:** every timed-out collection, jj or git, holds one of 16 engine-wide cleanup slots until its process trees and its termination subprocesses are confirmed gone; a git collection's quarantined index is tied to its slot. With all slots held, no VCS process starts and observation reports `unavailable (cleanup pending)` (or stale with that reason). An unconfirmable termination keeps its slot until engine exit; a bounded background wait that times out does not release a slot. An engine-wide limit of 64 outstanding attribution reads, abandoned reads included, bounds stalled I/O across requests; at the limit no new read starts and rows become `unknown`.
- **Bounded pre-capture wait:** after acquiring the collection lock, compute the remaining effective budget. Wait for pre-capture hashes for at most one third of that remainder, without moving the overall deadline or adding a user setting. Freeze completed pre-hashes at that cutoff; unfinished paths read `unknown`, their late results are ignored, and their read slots remain held until actual I/O settles. Continue the VCS capture with the remaining budget. Post-capture verification need only repeat completed pre-hashes. If capture completed but post-verification reaches the overall deadline, retain that capture and its baseline, use only completed verification results, and mark the other rows `unknown`. Emit `vcs_timeout` on overall deadline expiry, not on the earlier pre-hash cutoff alone. An incomplete VCS capture still uses the ordinary stale/unavailable timeout behavior.
- **Deadline clock:** the overall wait and remaining-budget calculations share one injectable monotonic clock, never the frozen display clock. Deterministic tests advance elapsed time and deadline waits together.
- **Capture boundary and retention:** after acquiring the lock and before pre-hashing, reserve the capture sequence from the supplied shared allocator. Orphan finishes reserve from that same allocator. A retained completed capture is admitted `available`, without a timeout reason; its current result flag supplies `vcs_timeout`. Attribution-only expiry creates no process cleanup lease. Normally completed command resources are disposed; any already-uncertain command cleanup remains quarantined under the existing rules.
- **Rejected:** letting a timed-out collection keep running in the background to refresh a cache for the next turn, because it needs an asynchronous writer and in-flight tracking (T3), and a repeatedly slow repository is better surfaced as visible `stale` + `vcs_timeout` with a configurable deadline. Also rejected: running collectors as supervisor `jobs` nodes, because they would appear in `processes`, churn the journal every request and be model-visible noise.
- **Reversal cost:** low.

### D6: Typed composer inputs, unchanged caps

- **Choice:** extend `SensoriumVcs` (backend, change/commit label, description, parent, counts, paths, conflicts, op/HEAD id, `partial`), `SensoriumChange` (`by`, `binary`, sinceTurn on the section), and `SensoriumReason` (`noRepository`, `disabled`, `notFound(tool)`, `noBaseline`, `baselineLost`). Section caps, fold order and the 1310 safe minimum stay unchanged; folded VCS (`counts only`) still fits 40, folded changes (paths + `by`, no counts) fits 200 by adaptive row count with `… +N more`. `sensoriumWithBudget`'s dependence on `\nvcs:` following budget is kept and covered by tests.
- **Rejected:** a generic collector-plugin registry with self-declared ceilings, because the sensorium spec's plugin collectors are v3 and no out-of-process producer exists.
- **Reversal cost:** low.

### D7: Notices as a fixed ordered code set

- **Choice:** add `vcsTimeout`, `vcsFailed`, `userEdits`, `baselineReset` to `SensoriumNotice`; render each at most once in the fixed order of the turn-perception spec, computed from this request's collection and committed facts only. The 80-token cap holds all six codes (~85 bytes ≈ 29 tokens); an explicit `… +N more` path exists for future growth.
- **Rejected:** a notices queue fed by components between turns (e.g. "late diagnostics"), because no producer needs deferred delivery yet; entry 5 decides that when LSP settle windows exist.
- **Reversal cost:** low.

### D8: Repository text is untrusted data

- **Choice:** one escaping function for paths, branch names and descriptions: C0/C1 controls, DEL and the scratch-framing line boundaries (CRLF, LF, CR, VT, FF, NEL, LS, PS) become `\u{XX}`-style escapes; only the first description line is used; fields are clipped at UTF-8 boundaries with a counted `…`; all such fields render on indented lines. Paths are repo-relative with `/` separators; non-UTF-8 bytes from `-z` output render as escapes.
- **Rejected:** dropping or rejecting entries with suspicious names, because silent omission violates "never lie by omission", and rejection would hide real files.
- **Reversal cost:** low (presentation only).

### D9: Delivery by Kehai and friction-ledger dispositions

- **Choice:** Kehai runs apply for this change (M2 rule); each unsupported step is recorded in this design's apply notes. Friction ledger dispositions: *permissions/config/instructions* — not in scope, assigned to `windows-tool-parity-and-m2-qualification` (unchanged from entry 2); this change adds only strict startup keys, no live reload. *Workflow waits* — no new polling; collector deadlines are single waits. *#28 timing tests* — this change's deadline logic is tested in-process with a fake runner and controllable completion (no wall-clock assertions); real `git`/`jj` process tests assert outcomes only and carry the `slow` tag where they spawn many processes. *Relative-PATH coverage restoration* — assigned to entry 7 (unchanged); this change's own `resolveProgram` use gets a relative-PATH-skipped test for the collector.
- **Rejected:** folding the permissions/config friction items into this change, because they are unrelated to perception and would make the PR unbounded.
- **Reversal cost:** low.

### D10: Updated built-in guidance intentionally changes instruction identity

- **Choice:** task 5.3 updates the built-in perception guidance for collected VCS, baseline-relative changes, attribution uncertainty and the new notice codes. Follow `instructions.dart`'s existing rule and advance its internal version from `kehai-3` to `kehai-4`. The changed instruction bytes change the lineage digest; do not pin or disguise the old digest.
- **Compatibility:** keep the existing native continuity guard unchanged. A selected native compaction boundary or opaque reasoning suffix recorded under incompatible instructions stops before a provider request, with the existing rewind-or-new-session message. No migration, replay shim or fallback to an older compatible boundary is added. Text-only history continues through the existing request rebuilding path.
- **Rejected:** keeping the instruction bytes/version unchanged while dropping the guidance edit, because the user explicitly chose the guidance update and accepted its lineage break. This is not a package-version bump; tool identity, RPC v1 and journal formats remain unchanged. D9's permissions/configuration/instruction-loading friction remains out of scope.
- **Verification:** task 5.3 reruns the existing changed-instructions native-continuity rejection regression alongside its RPC metadata check. Request token estimation includes the new constant instruction text through the existing budget convergence.

## Diagrams (FULL)

Components (T1):

```mermaid
flowchart LR
  D[driver _step] -->|build turn,offset| RB[RequestBuilder]
  RB -->|frozen tree copy| PV[provenance reader: calls/jobs since baseline]
  RB -->|collect root,backend,deadline,previous| OB[WorkspaceObserver / vcs_collector]
  OB -->|spawn, kill tree at deadline| JJ[(jj)]
  OB -->|spawn with GIT_INDEX_FILE copy| GIT[(git)]
  OB -->|bounded SHA-256 of changed files| FS[(workspace files)]
  RB -->|typed vcs/changes/notices| C[composeSensorium]
  D -->|pre-stream merge sensorium.vcs + baseline| W[single writer / journal]
  ED[edit/write tools] -->|target before, effect sha256 + seq after| W
```

Request sequence with deadline (T3):

```mermaid
sequenceDiagram
  participant Dr as Driver
  participant RB as RequestBuilder
  participant Ob as Observer
  participant Fs as Filesystem
  participant W as SessionWriter
  participant V as jj/git
  Dr->>RB: build(tree, turn, offset)
  RB->>RB: copy tree, freeze clock
  RB->>RB: derive baseline, interval and latest effects
  RB->>Ob: collect(previous, effects, shared sequence, jobsLive)
  Ob->>Ob: start overall deadline, acquire lock
  Ob->>Ob: reserve sequence; compute remaining budget
  Ob->>Fs: pre-hash, wait at most remaining / 3
  Fs-->>Ob: completed samples; abandon unfinished reads
  Ob->>V: snapshot and command-plan follow-ups
  V-->>Ob: parsed observation, baseline and diff outcome
  Ob->>Fs: post-verify completed pre-hashes
  alt deadline with incomplete capture
    Ob->>V: kill live process trees
    Ob-->>RB: stale/unavailable; carry earlier baseline
  else deadline after completed capture
    Ob-->>RB: fresh capture + completed samples + deadlineExpired
  else done before overall deadline
    Ob-->>RB: fresh capture + verification samples
  end
  RB->>RB: attribute, compose
  RB-->>Dr: BuiltRequest
  Dr->>Dr: recheck ownership/cancel
  Dr->>W: durably raise seqHigh for candidate baseline
  Dr->>W: guarded pre-stream merge (text + sensorium.vcs)
```

Observation availability (T2):

```mermaid
stateDiagram-v2
  [*] --> Unavailable: no repo / disabled / not found / first timeout
  Unavailable --> Available: collection succeeds
  Available --> Available: collection succeeds
  Available --> Stale: timeout or failure, earlier observation exists
  Stale --> Available: collection succeeds
  Stale --> Stale: further timeouts (age grows)
```

Persisted shapes (T4):

```mermaid
flowchart TB
  S["body/steps/s-N.sensorium"] --> T[text, tokens, mode, folds, source]
  S --> V["vcs: {state, reason?, observed:{time,turn}, value, baseline?:{backend,id,seq,jobsLive}}"]
  K["body/calls/c-…"] --> TG["target: resolved path; targetAfterSeq: durable watermark (before mutation)"]
  K --> E["effect: {sha256, seq}  (edit/write, success only)"]
```

## State & Ownership (FULL)

| State | Owner (sole writer) | Lifetime | Invalidation / rebuild | Authoritative copy |
|---|---|---|---|---|
| `steps/s-N.sensorium.vcs` (observation, baseline id) | Driver pre-stream merge via single writer | Step lifetime; removed by rewind | Never edited; superseded by later steps | Journal |
| `calls/<key>.target`, `targetAfterSeq` | Tool runtime in the first accepted guarded target append, before edit/write mutates; watermark reads durable seqHigh without allocating a number | Call lifetime | Never edited | Journal |
| `calls/<key>.effect` | Writer queue operation on successful edit/write: reserve shared sequence, durably raise seqHigh, then record sha256 and seq | Call lifetime | Never edited | Journal |
| `calls/<key>.quiesced` | Tool runtime when the edit/write future finishes (identity guard: node exists with original attempt; terminal allowed; absent/superseded refused without creation); recovery on resume | Call lifetime | Never edited | Journal |
| Mutation-call indexes | Runtime (in memory) | Engine run | Rebuild open keys, surviving step-call links and quiescence-turn keys on resume/rewind; update finish entries before queue advance; freeze relevant keys with request input | Journal and live unfinished runs |
| Unfinished edit/write run counter | Runtime (in memory) | Engine run | Counts live futures only; a dead engine's runs are closed by recovery | Live futures |
| `meta/orphanedMutations/<runId>` | Writer durably before a rewind loses a live target, in the same queue operation; runtime at supersession or identity-guard refusal; every run's finish checks and finishes its owned record regardless of quiescence-guard outcome; recovery finishes own records | Session (survives rewind and restart); evicted only past 64 finished records | Merge `finishedSeq` and raise `seqHigh`; never deleted on release | Journal (meta, never rewound) |
| Foreign orphaned-mutation records, `meta/vcs/foreignOverflow` | Parent's writer during fork | Child session lifetime | Never finished or deleted; ≤16, else overflow marker | Journal (child meta) |
| `meta/vcs/seqHigh`, `meta/vcs/attributionFloor` | Writer before effect/baseline admission; runtime/recovery on orphan finish; runtime on eviction | Session | Monotonic raises only | Journal (meta, never rewound) |
| `baseline.seq` | Collection (engine counter), stored with the admitted baseline | As step metadata | Never edited | Journal |
| Git temp index copy | Observer (engine run) | One engine run; deleted at shutdown, best effort | Disposable; recreated from the user's index on next run | None (cache) |
| jj snapshot commits / git tree objects | jj / git | Until jj op GC / git prune | Missing id → `baseline lost` + new baseline | The repository |
| User index, refs, working copy | User | External | Never written by Kehai observation | The repository |
| Startup `vcs.backend`, `sensorium.collectorDeadlineMs` | Config loader | Engine run | Restart | `config.json` |

## Failure & Visibility (FULL)

| Component | Fails / dies mid-operation → | Recovery | Retry safe? | Who finds out |
|---|---|---|---|---|
| VCS executable missing | `unavailable (jj not found)` / `(git not found)` | Install tool or set `vcs.backend` | Yes, each request | Model and user (block, `/sense` later, step metadata) |
| Command times out | Process trees killed; `stale`/`unavailable (timeout)`, no baseline | Next request retries; raise deadline | Yes, read-only plus idempotent snapshot | Model (`vcs_timeout`), user via observation |
| Command fails / output unparseable | `stale`/`unavailable (failed)` with bounded reason | Next request retries | Yes | Model (`vcs_failed`), user |
| Killed mid `git add` with private index | That copy may be locked or partly written, and its writer may survive | Copy quarantined, never reused; next collection makes a fresh copy | Yes, each collection is isolated | Nobody needs to; quarantine cap exhaustion is visible as `unavailable (cleanup pending)` |
| Tree termination uncertain or stalled | Possible surviving `git`/`jj` descendants | Request continues at deadline; quarantine held until confirmed or engine exit | n/a | Engine log; model only if the quarantine cap is reached |
| Edit/write interrupted after rename | File changed without a recorded effect | Path reads `unknown` | n/a | Model sees `unknown` |
| Repository clean filter hangs or fails | Killed at deadline / non-zero exit | `stale`/`unavailable`, `vcs_timeout`/`vcs_failed`; user may set `vcs.backend: none` | Yes | Model and user |
| Attribution read stalls | Pre-hash wait stops after one third of remaining budget; post-hash wait stops at overall deadline; late results ignored | Preserve a completed capture/baseline; affected rows `by: unknown` | Yes | Model sees `unknown`; `vcs_timeout` only on overall deadline expiry |
| Killed mid jj snapshot | jj's own op transaction aborts or commits atomically | jj | Yes | jj op log only |
| Baseline id not resolvable | `unavailable (baseline lost)`, `baseline_reset` | New baseline recorded | Yes | Model and user |
| Attribution hash read fails (permissions, file vanished) | Row `by: unknown` | None needed | Yes | Model sees `unknown` |
| Engine crash after collection, before admission | No observation recorded, no baseline | Next request diffs from the older baseline (wider interval) | Yes | Nobody needs to; wider interval is honest |
| Temp dir leak after crash | Small orphan index copy in OS temp | Startup removes this engine's own dir only on clean exit; orphans are bounded by index size | n/a | Logged path in engine log at creation |

## Resource Bounds (FULL)

| Queue / buffer / cache / transfer | Bound | At the bound | Timeout | At 10x / 100x |
|---|---|---|---|---|
| Collection wall time | Deadline 300 ms default (100–10000), first in run ≥3000 ms | Kill live process trees; stale/unavailable if capture is incomplete, otherwise keep capture with unverified rows unknown | Same overall deadline | Large repos time out visibly; user raises deadline |
| Concurrent VCS processes per collection | ≤3 | Fixed command plan | Deadline | Unchanged |
| Process stdout read | 4 MiB per command | Stop reading, kill, mark `partial` | Deadline | Huge untracked sets → partial counts |
| Parsed status / diff entries | 10,000 per command | Stop parsing, counts `≥N partial` | Deadline | Partial, explicit |
| Stderr retained | 2 KiB, reason ≤200 chars in block/metadata | Truncate with `…` | — | Unchanged |
| Files hashed for attribution | Only interval-effect paths: 64 paths, 4 MiB each, at most two reads per path | Unverified rows `by: unknown` | Pre-hash wait ≤ one third of remaining post-lock budget; post-hash wait uses overall deadline | Unknown rows grow; counts explicit |
| Rendered rows | VCS 12 paths, changes 12 rows, section caps 250/200, folded 40/200 | `… +N more` | — | Unchanged |
| Step metadata `vcs.value` (fresh or carried) and baseline | ≤12 paths, ≤12 change rows, fields clipped, ≤4 KiB serialized | Clip with counted markers | — | Per-step growth constant, including carried copies; session growth as ADR 0016 (no GC) |
| Backward scan for latest admitted step | 256 steps (failed collections carry the baseline forward, so only non-admitted steps are skipped) | `baseline lost` + `baseline_reset`, new capture | — | Unchanged |
| Collection lock wait | Deadline of the waiting collection | `stale`/`unavailable (timeout)` without starting a process | Deadline | Status previews queue behind builds, bounded by deadline |
| Cleanup slots (timed-out collections, jj or git, incl. termination subprocesses) | 16 per engine; held until processes are confirmed gone, else until engine exit | No VCS process starts; `unavailable (cleanup pending)` | Deadline per collection | Stalled kills cannot accumulate past 16 collections' processes |
| Git private index copies | One per collection, deleted after it; a timed-out collection's copy is quarantined with its cleanup slot | Bounded by cleanup slots | — | Proportional to index size × held slots |
| Unfinished edit/write runs and open mutations | 16 per engine, detached runs included until they actually finish | New edit/write refused before mutating, error names the count; open targets never evicted | None (a stalled rename is not interruptible); the cap provides backpressure | Repeated cancellation cannot grow pending work or tracked targets past 16 |
| Foreign orphaned-mutation records (per child session) | 16 | Keep 16, set `foreignOverflow`; all rows `unknown` in that session | — | Constant per session |
| Orphaned-mutation records | Live: within the 16-run cap; finished: 64 | Evict the oldest finished record and raise the attribution floor; comparisons against baselines below the floor read all rows `unknown` | — | Meta growth bounded at 16 + 64 records plus two counters |
| Outstanding attribution reads, engine-wide (incl. abandoned) | 64 | No new read; rows `unknown` | Deadline per collection | Stalled filesystem cannot exhaust handles |
| Derived mutation-call indexes | At most one entry per surviving mutation call, plus the existing live-run registry | Rebuild after rewind/resume; no independent history or authority | Engine lifetime | Proportional to existing call history, not a new work queue |
| Background termination outcome waits | One per held cleanup slot, each bounded to 10 s | Wait timeout keeps the slot held (uncertain) | 10 s | Bounded by cleanup slots |
| Git unreferenced objects | Changed/untracked blob+tree objects per request | Git's normal prune | — | Disk use grows during long sessions until prune; recorded as risk |

## Flow & State Gaps (FULL)

- **User runs git/jj concurrently:** git observation uses no optional locks and a private index; a concurrent `git add -A` on our copy cannot collide with the user's `index.lock`. jj concurrent operations are reconciled by jj; a concurrent-operation warning is not a failure.
- **Child engine in the same repo:** each engine has its own temp index and collection; jj may see concurrent snapshots and merges op heads. Parent attribution treats a live child (`agent` call / live job) as process-running activity → `unknown`.
- **Edits between collection and admission:** they appear in the next request's diff; the admitted observation describes the capture moment (`observed.time`), and the calls of the admitted request's response fall into the next interval.
- **Cancellation or rewind during collection:** collection is bounded by the deadline; the existing post-build ownership/cancellation check (`driver.dart:773`) prevents admission, so no baseline is recorded.
- **Status during a running step:** status waits for the engine collection lock within its deadline, then runs its own collection; a jj snapshot from status is a harmless extra op; status records nothing.
- **Fork while the parent holds a rename:** the child carries a foreign record and never finishes it; the target stays `unknown` in the child for its whole life.
- **Late finish after rewind or re-admission:** the identity guard refuses it without creating or changing a node; the open set unions the post-rewind tree with unfinished runs, and the target stays uncertain through its `meta/orphanedMutations` record for every comparison against a baseline captured before the finish, across any number of intervening captures, restarts and rewinds, including a rewind that restores an older baseline.
- **Crash around rewind:** write-ahead preservation is flushed before the cut. Recovery retains and finishes the owning session's orphan whether the crash happened before or after the rewind record; it never needs the dead engine's registry to rediscover that target.
- **Cancelled write that lands after the next baseline:** the call stays open until `quiesced` is recorded, so its target reads `unknown` across any number of intervening captures; after quiescence it belongs to the interval of its `quiesced` turn.
- **Interrupted edit/write:** a call cancelled during its rename or lost to a crash has no effect record; its path reads `unknown` (never `user`) unless a later successful effect proves `agent`.
- **Tracked-set changes by the user:** each collection copies the user's current index, so force-added or untracked files are reflected immediately.
- **File rewritten during the capture:** detected by the pre/post hash and stamp comparison → `unknown`. The one undetected case is a rewrite that restores identical bytes and the original stamp between the two reads.
- **Resume on another machine/clone:** baseline id may not resolve → `baseline lost`. Different absolute workspace path is irrelevant (repo-relative paths).
- **Workspace is a subdirectory of the repo:** observation covers the whole repository; paths remain repo-relative.
- **Nested repositories / submodules:** only the nearest root is observed; submodule internals appear as git reports them (gitlink changes), no recursion.
- **Rename:** reported as delete + add unless the VCS reports a rename in its stat output; counts stay exact.
- **Unborn git HEAD / empty jj repo:** supported; diff against an empty baseline is defined by the first recorded tree.
- **Out-of-order:** none — one collection per build, awaited in order.

## Mechanism Ledger (FULL)

| Mechanism | Built? | Why (harm nobody catches / expensive later) | Evidence that would change the call |
|---|---|---|---|
| Deadline + tree kill | Yes | A hung `git`/`jj` would block every request silently | — |
| Private git temp index | Yes | Using the real index would alter the user's staging (data-loss class) | — |
| Identity guard on `quiesced` | Yes | Without it a late finish resurrects a rewound call or closes a re-admitted one | — |
| Rewind-exempt orphaned-mutation records | Yes | Without them a rewound write that lands after the next baseline is reported as a user edit | — |
| Session-owned orphan records + foreign copies at fork | Yes | Without them child recovery finishes the parent's still-running rename and the child reports it as a user edit | — |
| Capture sequence + monotonic floor instead of release deletion | Yes | A meta deletion is not undone by rewind, so a restored older baseline would report the write as a user edit | — |
| Unfinished-mutation cap (16) | Yes | Detached cancelled runs release their slots, so nothing else bounds them | — |
| `quiesced` record + open-mutation set | Yes | Without it a cancelled write that lands after the next baseline is attributed to the user | — |
| Pre-mutation `target` record | Yes | Without it an interrupted write through a symlink is attributed to the user | — |
| `effect.sha256` on edit/write | Yes | Persisted field; adding later loses attribution for older sessions | — |
| Durable effect sequence under existing resolved-target lock | Yes | Commit order alone could hide a user restoration of older bytes; rename and effect order must agree | — |
| Durable target effect-order boundary | Yes | A later unresolved rename followed by a user restoration could otherwise reuse an older successful effect as agent proof | — |
| Conservative case-alias uncertainty | Yes | Case-variant target spellings can hide a user restoration even with durable effect order | — |
| Untrusted-text escaping | Yes | Forged block structure is a prompt-integrity risk nobody would notice | — |
| Bounded reads/hash caps | Yes | Unbounded output from huge repos would stall or OOM | — |
| Backend-independent cleanup slots (16) | Yes | Without them stalled jj kills accumulate processes across requests | — |
| Fresh private index per collection + quarantine | Yes | A reused copy goes stale on tracked-set changes and may still be written by an uncertain-dead process | Measured copy cost dominating collection time on very large indexes |
| Engine-wide outstanding-read limit | Yes | Abandoned stalled reads would accumulate across requests | — |
| Engine collection lock | Yes | Overlapping status/build collections corrupt the shared private index (status builds through the same builder, `driver.dart:337`) | — |
| Baseline carry-forward on failed collection | Yes | Without it a long failure run silently hides user edits | — |
| Pre/post capture hash + stamp check | Yes | Without it a rewrite during capture is labelled `agent` | — |
| Filter emulation/disabling | No | Would make captures disagree with repository semantics | A real repository whose clean filter has external effects |
| Background continuation / collector cache refresh | No | Visible stale + configurable deadline suffices | Dogfood shows default deadline routinely missed on Windows for typical repos |
| File watcher hints | No | ADR 0007: hints only; VCS snapshot already cheap | Measured collection cost dominating request latency |
| Notices queue | No | No deferred producer exists | Entry 5 LSP settle windows |
| Delta (non-full) mode | No | ADR 0007/0016 keep full default | History-fold experiment results |
| Git object pruning by Kehai | No | Git's own prune handles unreferenced objects | Measured repository growth complaint |
| Cross-backend baseline translation | No | Rare (backend switch); `baseline lost` is honest | — |

## Risks / Trade-offs

- [300 ms default too tight on Windows (process start + snapshot)] → cold-start allowance, parallel follow-ups, configurable deadline; apply measures collection time on Windows CI and the Kehai checkout and records it; changing the default is a constant change.
- [Git object store growth from per-request tree writes] → only changed content creates new blobs; git prune collects them after its grace period; recorded in user docs.
- [jj snapshot side effect adds op-log entries each request] → ordinary jj behaviour; documented; checkpoints (entry 6) rely on these op ids anyway.
- [`by: unknown` frequent while background jobs run] → honest by design; the model still sees the path and line counts.
- [Large untracked files hashed by `git add -A`] → bounded by deadline; jj's own max-new-file-size applies on jj; partial coverage marked.
- [Repository clean filters (e.g. LFS) run during `git add -A`, as for the user's own `git status`] → bounded by deadline; failures surface as `vcs_failed`; `vcs.backend: none` opts out; Kehai itself never invokes remote-touching or smudge commands.
- [Agent-written files are read twice per request] → bounded to interval effect paths and the deadline; rows degrade to `unknown`, never block.

## ADRs

- **In force, constraining this change:** 0001 (one tree), 0002 (central results), 0003 (unified jobs), 0007 (perception, `.jj` first, hash authority, provenance meaning of `by: user`), 0010 (call/job tree layout), 0014 (no new package until needed — collector stays in-package), 0015 (native compaction and its compatibility guard unchanged; D10 intentionally changes instruction identity), 0016 (bounded sensorium, caps, notices, admitted observation).
- **To record during apply:** ADR 0017 *VCS observation baselines and provenance attribution* — content-addressed baselines in admitted step metadata, private git temp index (no user index/ref writes), `target` (pre-mutation, resolved), `effect: {sha256, seq}` and identity-guarded `quiesced` call fields, resolved-target serialization through effect commit, open-mutation semantics, rewind-exempt, session-owned orphaned-mutation records with capture sequence numbers, the attribution floor and foreign copies at fork, and the unfinished-mutation cap, the step-output attribution interval, pre/post-capture verification, attribution rules (`agent`/`user`/`unknown`, stamps only downgrade), baseline carry-forward, the serialized collection deadline contract, backend-independent cleanup slots and the filter policy. Update `openspec/architecture.md`'s ADR index and the perception paragraph that says VCS producers are later work.

## Open Questions

- Exact jj 0.46.0 template expressions for per-file diff stats and conflicted paths are verified in a disposable repo during apply; if the `jj diff -T` stat template is unavailable, parse `--git` output with the same byte/entry bounds. Neither choice changes specs or tasks.

## Apply notes

- The native Windows `build/kehai.exe doctor` check succeeded. It reported an authenticated provider, model `gpt-6.1-sol`, installed OpenSpec commands and implementer roles. These are readiness facts, not implementation evidence.
- Kehai session `20261112T110912Z-abf984d6` admitted a read-only apply-readiness request for this change. It announced task 1.1 and reached a permission prompt for `mise --version && mise ls --current`. The supervising client's attempt stopped at that prompt. No implementation, tests or commits ran through that attempt. The local transcript is `.dart_tool/vcs-apply-attempt.ndjson`; it is not required for session recovery.
- Unsupported steps in that attempt remain explicit. The temporary RPC client did not bridge permission answers, and Kehai's reported tool roster does not expose the official Dart MCP runner. The supervising coding session must supply that runner. This attempt does not satisfy task 6.2's integrated dogfood requirement.
- The user chose to preserve D4 and clarify that child recovery may quiesce copied call nodes while their foreign records remain unfinished. Renewed design-review round 11 found the rewind-to-orphan-record gap. The user approved the unfinished-run registry correction and its two regression scenarios before those artifacts changed.
- Source inspection during apply found that the registry alone did not cover engine death after the rewind commit but before the orphan append. The user approved durable preservation before the cut within the same writer operation, a crash-window recovery regression, and renewed design review.
- Friction dispositions remain D9's assignments. Permissions/config/instructions and broader relative-PATH restoration belong to `windows-tool-parity-and-m2-qualification`. Collector deadline tests use controllable completion rather than timing assertions. No polling loop is added. Real collector timings, admitted block/token evidence and Linux/native-Windows CI results are not yet available.

- The user approved a bounded pre-capture hash wait after a stalled-read conflict was identified: at most one third of the remaining post-lock budget, with one unchanged overall deadline and no new user setting. Incomplete hash results remain uncertain rather than preventing a VCS capture.
- A probe showed identical frozen trees and bytes for different within-turn effect orders, including a user restoring an older effect. The user approved persisting `effect.seq` from the shared allocator with its high-water mark durable before the effect.
- User chose conservative case-alias uncertainty: differently cased target/row spellings read unknown on all platforms rather than adding filesystem capability probes.
- User approved `targetAfterSeq` to distinguish same-turn unsuccessful attempts from successful effects: read the durable shared high-water mark in the accepted target append, without another reservation or flush.
- The user approved updating the built-in perception guidance and advancing its internal version to `kehai-4`, after the conflict with the proposal's prior identity-neutral claim was surfaced. D10 acknowledges that changed instruction bytes invalidate old native opaque lineage under the existing compatibility guard. No history migration, fallback or package-version bump is approved.
- Pre-ship round 2 F1 alleged that cross-drive Windows edit/write fails because `package:path.relative` throws. The pinned dependency documents returning an absolute path instead. A disposable official-MCP consumer test against source `46ba81b6f8cbd91031af10f7c181f6f27f27c91a` used a real F: repository workspace and C: target, ran the actual `ToolRuntime` write and anchored edit, and verified both resulting file contents: one test passed. No runtime-path change or waiver was made. The probe was removed; its local JSON reporter is `.dart_tool/vcs-r3-crossdrive.json`.
- Initial PR CI on `bd4e6378376a2f0deae9d799bcabcb57806f7a95` failed fatal-info analysis on both OSes: [run 43449311868](https://github.com/sh1ny/kehai/actions/runs/43449311868). The official MCP analyzer reported only “No errors”; it did not expose the 30 warning/info diagnostics required by this repository's gate. SDK quick fixes and removal of unused bindings/dead state resolved them without suppressions. The pinned `mise run analyze` now reports “No issues found”; all 226 mapped tests passed through the official MCP runner after the lint corrections.
- Full CI on the same head ([run 43449519617](https://github.com/sh1ny/kehai/actions/runs/43449519617)) exposed a real generic-fork regression and a source-text-test false positive. `forkMutationMeta` now treats ordinary body/call-table values as optional while keeping reserved mutation metadata strict. The exact failing property history (`20260110`, index 9), all six fork-provenance tests and the full-byte/result-composer roster test passed through the official MCP runner. The source-scanning test and its hard-coded allowlist were deleted rather than re-pinned; the consumer-visible truncation test remains. Format checks passed for all 43 changed Dart files; the corrected CLI emitted hello, hot reload succeeded and EOF exited 0.
- That full Linux run also failed the unchanged auth test's `portIsFree(rig.primary)` assertion. The production flow publishes ownership before its deadline checkpoint and awaits `server.close(force: true)` before returning; the fixture chooses and releases ephemeral ports before use and can fall back to a different port. A competing-port race is an inference, not a reproduced auth defect. No auth code or assertion was changed; the next CI head must still pass this test.
