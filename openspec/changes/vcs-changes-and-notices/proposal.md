# Proposal

## Why

Every request's sensorium block still says `vcs: unavailable (not collected)` and `changes_since_last_turn: unavailable (not collected)`. The agent therefore spends its first calls rediscovering working-copy state, and it cannot learn that the user edited a file while it was thinking. That is the clobbering case the [sensorium spec](../../../docs/sensorium-spec.md#the-per-turn-snapshot) calls the most damaging. This change is entry 3 of **M2 — Dogfood-driven perception and client** in [openspec/roadmap.md](../../roadmap.md). It advances these exit criteria:

- *sensorium budget/history-fold/Windows-attribution checks pass*: it adds real VCS and change observations under the existing 1500-token block and fold order, and gives Windows attribution an explicit, tested coverage contract.
- *friction ledger dispositions*: it records which friction items this change carries.

It builds on entry 2, `sensorium-block-and-scratchpad`, which shipped the typed section slots, fold order and admitted-observation metadata, but no producers. It is constrained by ADR 0007 (`.jj` detected first; hashes are authoritative and watchers only hints; baselines live in tree nodes; `by: user` means "outside recorded tool provenance"; coverage gaps are shown explicitly) and by ADR 0016 (frozen bounded snapshot, availability and staleness states, bounded notice codes).

## What Changes

- **VCS observation.** Before each model request, a bounded, deadline-limited collector observes the workspace's repository. It detects jj first, so colocated repos use jj, and falls back to git. A startup `vcs.backend` setting can force `jj`, `git` or `none`. The `vcs` section reports:
  - the backend and the current change id with its first description line (jj), or HEAD and its branch (git);
  - the parent;
  - working-copy M/A/D counts, with up to 12 paths;
  - conflicted files;
  - the jj operation id, or the git HEAD sha.

  A missing tool, a path outside any repository, a VCS capture timeout or a parse failure each render as `unavailable (<reason>)` or `stale (<age>)` with the last known value. None of them render as clean.
- **`changes_since_last_turn`.** Each admitted request records a content-addressed working-copy baseline in the session tree: a jj commit id, or a git tree id written through a temporary index that never touches the user's index or refs. The next request diffs against that baseline and reports per-file +/- line counts. Each file is attributed `by: agent` (the agent's own recorded edit/write produced the current content), `by: user` (no recorded tool or job activity of this session explains it) or `by: unknown` (it changed while an agent shell command, hook, job or child agent was running, or the agent's own write was changed again, so the cause cannot be proven). A lost or unreadable baseline, from a pruned object, an abandoned operation or a resume on another clone, renders as `unavailable (baseline lost)` and starts a new baseline. Rewind, fork and resume follow the tree.
- **`notices` producer.** New bounded codes join `compaction_recovery` and `legacy_window_ignored`: a collector timed out or failed, files were edited outside agent provenance (`user_edits`), and the change baseline was reset. Codes are deduplicated, ordered and capped inside the 80-token notice section with an explicit omitted count.
- **Windows coverage.** Attribution and staleness behave identically on native Windows, without WSL: content hashes are authoritative and mtimes only a hint. Process deadlines kill the whole process tree, and paths are always repo-relative with `/` separators. Coverage that is incomplete, such as a truncated status listing or an oversized untracked file, is marked partial, never presented as complete.
- **Untrusted repository text.** Commit descriptions, branch names and paths are untrusted. They are rendered on indented, control-character-escaped, length-bounded lines, so repository content cannot forge harness structure inside the block.
- Diagnostics, tests, plan, checkpoints and the post-edit delta footer stay `unavailable (not collected)`. They belong to entries 5 and 6.

## Capabilities

### New Capabilities

- `vcs-observation`: per-request observation of the workspace repository (backend detection, working-copy state, conflicts, operation/HEAD identity), with deadlines, staleness, failure reasons and bounded, untrusted-text-safe presentation.
- `workspace-change-attribution`: tree-held content-addressed working-copy baselines and the `changes_since_last_turn` section: per-file line deltas since the previous admitted request, attributed to agent, user or unknown from recorded tool and job provenance. Covers baseline loss, rewind/fork/resume and partial-coverage reporting.

### Modified Capabilities

- `turn-perception`: the ordered snapshot now carries collected `vcs` and `changes_since_last_turn` observations instead of fixed `unavailable (not collected)` slots. The bounded `notices` vocabulary grows to cover collector timeouts and failures, user edits and baseline resets, and collected observations appear in the admitted step metadata.

## Impact

- **Code:** `lib/src/loop/sensorium.dart` (typed VCS/changes inputs, notice codes), the request path in `lib/src/loop/driver.dart`/`request_builder.dart` (collection before the frozen snapshot, baseline recording with the admitted observation), a new collector module under `lib/src/workspace/` (process runner use, jj/git parsing), tool-call provenance for edit/write post-content hashes where missing, and `lib/src/config/user_config.dart` (strict `vcs` / collector-deadline startup keys).
- **Session tree:** new collector baseline and last-known-value nodes. This is additive and rebuildable: older sessions without them take a fresh baseline. The journal format and RPC v1 shape are unchanged, apart from new fields in existing step metadata.
- **User repository:** jj observation snapshots the working copy (ordinary jj behaviour, adding operation-log entries). Git observation writes unreferenced tree/blob objects through a temporary index. Neither moves refs, the user's index, HEAD or the working tree.
- **External tools:** `jj` (pinned 0.46.0 in `mise.toml`) and `git` must be on PATH, or the section says unavailable. Tests use disposable repositories, and CI must provide both tools on Linux and Windows.
- **Instructions/tool identity:** built-in perception guidance changes and its internal version becomes `kehai-4`. The instructions digest therefore changes. Existing native opaque history with the old lineage is rejected by the unchanged compatibility guard; recovery is rewind before the incompatible history or a new session. There is no history migration, compatibility fallback or package-version bump. Tool identity is unchanged.

## Release Notes

Add bounded repository observation, admitted change baselines and durable filesystem mutation provenance.

### Added
- Startup `vcs.backend` selection and `sensorium.collectorDeadlineMs`, with explicit disabled, missing-tool, timeout and failure states.
- Serialized jj/git capture, fresh private git indexes, bounded output and quarantined process cleanup without changing the user's index, refs or working tree.
- Resolved edit/write targets, byte hashes and durable effect ordering, with identity-guarded quiescence and a 16-run unfinished-mutation limit.
- Write-ahead preservation of live targets across rewind, session-owned recovery and bounded foreign uncertainty at fork.
- Tree-held baselines and bounded observation values, retained unchanged across collection failures, rewind and resume.
- Per-path agent/user/unknown attribution from ordered effects, frozen uncertainty and bounded pre/post raw-byte verification; case aliases and unresolved effect-order boundaries remain conservative.
- Shared-deadline verification of at most 64 paths of 4 MiB each, retaining completed captures when only post-verification expires.

### Changed
- VCS presentation now supports backend identity, counts, conflicts and bounded paths, with escaped repository text and explicit omissions.
- Full and folded changes retain attribution and the baseline turn; the six finite notice codes render once in fixed order.
- Built-in perception guidance uses internal version `kehai-4`. Its changed instructions digest invalidates prior native opaque lineage; the existing guard requires rewind before incompatible history or a new session, without history migration.
- Admitted requests persist their exact bounded VCS metadata; reconnect preserves it while read-only status estimates use a current capture without journal writes or a new baseline.

### Fixed
- Disabled observation keeps both sections unavailable with reason `disabled`, while preserving the prior provenance boundary.
- Cancelled edit/write futures waiting on a shared path retain their unfinished-run slots until actual completion.
- VCS failure classification uses typed availability signals, never repository stderr, so error text cannot disable observation or invalidate a carried baseline.
- Resume recovery counts only newly finalized calls, not already-terminal calls receiving mutation-quiescence bookkeeping.
- Finished ancestor orphan records expire at their inherited sequence boundary in forked children; unfinished foreign records remain uncertain.
- Changes report diff truncation independently of status truncation and ordinary twelve-row display omissions.
