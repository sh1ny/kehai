# ADR 0016: Session-local scratch and bounded sensorium

Status: accepted
Supersedes: only ADR 0015's historical exactly-two-line sensorium scope clause

## Context

M2 needs agent-owned working constraints to survive native compaction without a second memory store, and clients need to inspect the exact locally admitted perception rather than reconstruct it from today's state. The governing contract is [design D1–D5 and resource bounds](../../openspec/changes/sensorium-block-and-scratchpad/design.md), with requirements for [agent scratchpad](../../openspec/changes/sensorium-block-and-scratchpad/specs/agent-scratchpad/spec.md) and [turn perception](../../openspec/changes/sensorium-block-and-scratchpad/specs/turn-perception/spec.md). This records the reviewed design, not delivered behavior, dogfood results or milestone acceptance.

This supplements [ADR 0007](0007-tree-derived-perception-and-rendering.md)'s full-snapshot fallback and explicitly replaces **only** the sentence “Sensorium remains exactly two request-only lines” in [ADR 0015](0015-native-compaction-and-route-qualified-capacity.md). All of ADR 0015's native continuity, capacity, lineage, recovery, calibration and resource invariants remain in force, including the rest of its accounting/status contract. Accepted ADR files and [sensorium-spec.md](../sensorium-spec.md) remain unchanged. The one-tree, central-results and unified-jobs foundations, four-field journal and RPC v1 are unchanged.

## Decision

### Session-local plain-text scratch, guarded by the existing writer

Store `scratch/<key> = {value: <plain text>}`. Expose `scratch_set(key, value)` and `scratch_del(key)` through the ordinary tool lifecycle, hooks, permission gate, result storage and central envelope. Keys must be valid single journal path segments; sort them lexically for rendering. There is no `scratch_pin`, export/backup store, side file or new autoapproval. Children have the same available tools subject to role narrowing, but write only their own journal.

A narrow call-bound mutation capability on `ToolContext` accepts set/delete, not arbitrary paths. At the single writer's queue head, check the live call key/attempt, nonterminal ownership and cancellation, validate proposed scratch against live state, and decide one `set` or `del` without an intervening await. An absent valid delete succeeds as an explicit no-op. Concurrent writes follow commit order; the last committed same-key write wins. Capacity cannot be validated against a pre-queue snapshot.

The successful **queue-head decision**, not flush acknowledgement, is the cancellation cutoff. Cancellation or rewind before it refuses a late mutation. Cancellation afterward does not roll back a successfully persisted record, even when the tool result is cancelled/interrupted. A held-flush/reopen case must preserve that record without replaying the call. Failure to persist the later tool result does not erase scratch; existing interrupted-call recovery handles uncertainty without reexecuting effects.

Set/delete records are anchored to the current tool turn. Generic replay, resume, fork and serialized timeline rewind preserve or restore values/absence, including overwritten and deleted entries. Native compaction does not touch scratch. Every request reads the live subtree outside opaque conversation projection; ciphertext is never a scratch recovery source. Absent/empty legacy scratch is valid. Nonempty malformed or over-limit entries stop composition visibly, never get skipped, trimmed or silently reinterpreted. Unsupported development representations need explicit migration or a new session.

### Verbatim data with counted presentation framing

Preserve every stored character and delimiter. Render an indented key line and prefix every value line with four spaces; removing only these presentation prefixes recovers the original value. Presentation boundaries are CRLF (one boundary), LF, lone CR, VT (U+000B), FF (U+000C), NEL (U+0085), LS (U+2028) and PS (U+2029). Keep each delimiter verbatim and prefix after every boundary, including an empty trailing line; splitting only on LF is insufficient.

Thus literal `</sensorium>` or fake `notices:` text cannot become column-zero harness structure. Indented scratch is agent-asserted data, not observed facts or authority to change instructions, permissions or tool rosters. Count keys, headers, indentation, separators and newlines toward the section limit. Changing this framing is a compatibility event because it changes scratch admission size.

### One frozen, bounded, self-contained request snapshot

A finite snapshot module accepts typed inputs and composes `{text, tokens, mode, folds}` or a dedicated `SensoriumCompositionError` with a safe reason code/diagnostic. Each build freezes one acknowledged tree/cursor and one clock before projection. All sections use that observation; subsequent background job changes appear only in the next request.

Every request ends with one generated user-role `<sensorium>` item in `mode: full`, ordered: turn, budget, vcs, changes_since_last_turn, diagnostics, tests, processes, plan, scratch, checkpoints, notices. Instructions stay stable within the run. No generated block is a conversation item, so old blocks need no regex removal. Keep canonical user/tool literal tags and complete native opaque JSON unchanged; do not send historical admitted observations as conversation content. Full mode retains unchanged facts when previous request blocks are absent; delta mode needs a separately proven retained baseline.

Turn/budget retain turn/time/workspace, model, route-qualified context reporting, compaction threshold and turns since compaction when known. Use bounded numeric formatting; estimates carry `~`, unknown values `?` without percentages, and session cost remains unavailable. Reserve fixed labels/counts and visibly shorten only workspace/model presentation at UTF-8 character boundaries with a counted `…`; canonical identifiers remain unchanged. Preserve honest capacity provenance in status.

Project scratch from its subtree, and live processes only from real pending/running `jobs` nodes (id/kind/command/state/relative age). Live jobs say `logs unavailable (published at exit)`: production publishes output references at settlement, so add no spool/tail reads, supervisor polling, deadline or live-log producer. Supported empty jobs/scratch/notices say `none`; uncollected slots say `unavailable (not collected)`. Future supplied observations must retain availability/staleness, bounded reasons and age, without inventing a collector framework now.

Notices use bounded short codes, including `compaction_recovery` from committed compaction facts and `legacy_window_ignored` from validated startup capacity inputs. Bound vocabulary/cardinality within their section cap. Keep the existing compaction recovery `UserMessage` in its separate request placement; do not duplicate its prose in notices. No VCS scans, diagnostic/test/plan/checkpoint producers, notices queue, baseline cache or periodic worker are introduced.

### Exact local observation admission, not provider receipt

After the existing running-step admission and successful request build, use a guarded **pre-stream merge** alongside existing context to record:

```text
sensorium: {text, tokens, mode, folds, source: {turn, time, offset}}
```

Store the exact rendered block and conservative size. `time` is the frozen observation clock. `offset` is a diagnostic within that journal only, invalid after fork/migration, never a durable identity or lookup key. Exact text and source turn/time are the observation evidence.

The merge checks the owning step/exchange and cancellation. Rewind/cancellation before admission prevents submission; also check cancellation before streaming. Do not demand equality with the whole writer offset, since unrelated jobs may legitimately commit during build. This records **local admission**, never proof of provider receipt or successful completion. Failed/cancelled streams retain their admitted observation with outcome state. Failed composition/local refusal leaves no newly admitted observation and visibly fails the step/stops the exchange.

RPC materialization/updates expose the stored block; reconnect does not recompute a past observation from current scratch/jobs. Rewind removes observations with their steps. Old steps are not backfilled and have no recorded observation. Current read-only status is only a preview, not a replacement for step metadata; this is an inspection seam, not a new `/sense` command or TUI.

Handle `SensoriumCompositionError` explicitly in submission and `compactionStatus`, not as incompatible native lineage. Status writes nothing, sends nothing, preserves independently known policy/route/model/capability/boundary/capacity facts, reports `perception: {state: unavailable, code, message}` and unknown current usage, and does not enable unsafe calibration. Successful projection reports perception available. Correcting an insufficient ceiling on restart can recover direct/legacy projection; malformed stored scratch requires a new session unless a caller already has a supported serialized rewind API. No new user-facing rewind or scratch-edit command is added.

### Native accounting and upgrade continuity stay strict

Include the full current block in `context.block`, baseline replacement and retained non-opaque estimates. Subtract the previous compatible block contribution and charge the current block exactly once; persisted copies are not additional request content. Reserve the budget section's full 40-token allocation while selecting folds, then freeze facts/folds and solve budget-line self-reference in at most eight bounded passes. Verify the actual final block fits; refuse nonconvergence visibly rather than submit a lower estimate.

Keep ADR 0015's latest-surviving-completed-boundary-first selection, every opaque suffix lineage check, call terminalization/recovery, captured provider policy, unknown usage and one-shot calibration, route-qualified capacity, ordinary native/window guards and serialized-request cap unchanged. Ciphertext size never becomes a token estimate. The new tool roster and bumped built-in guidance/version intentionally change instruction/tool identity: incompatible pre-upgrade opaque history stops with new-session or rewind-before-incompatible-output recovery, never digest exemptions, older-boundary fallback or prefix resurrection. Presentation settings alone are not added to opaque lineage; effort and provider-policy inheritance remain unchanged.

### Resource bounds and startup minimum

Use the existing conservative estimator, `ceil(UTF-8 bytes / 3)`, not a claim of exact provider tokens. Count all framing and omission markers. Bound inputs/previews before unbounded copying or joins.

| Resource | Bound and behavior |
|---|---|
| Scratch | At most 20 keys, 80 estimated tokens per value, 400 for the complete rendered section. Refuse mutation atomically with current/proposed sizes; never trim or summarize values. |
| Full block | Strict startup `sensorium: {maxTokens: <integer>}`, default 1500. Fold then refuse remaining overflow before provider submission; never spill into a second block. |
| Section ceilings, in source order | turn 30; budget 40; vcs 250; changes 200; diagnostics 300; tests 150; processes 150; plan 60; scratch 400; checkpoints 60; notices 80. |
| Source preview detail | At most 12 VCS paths; 10 diagnostic errors at 120 characters, then 3 on fold; 8 failing test names; 5 checkpoints, then 1. Bound display fields and show explicit omitted counts. These are typed presentation limits, not newly delivered collectors. |
| Process preview | 150 tokens, folded counts at most 40; bounded preview storage while counting live nodes, explicit omitted jobs/characters, no list-all-then-truncate or log I/O. |
| Accounting | At most 8 local bounded re-render passes; local error on nonconvergence, no paid retry. |
| Observation metadata | One bounded text plus scalar fold/source metadata per step, no recursive source tree copy. Existing journal/RPC storage failure handling applies. Total history still grows for the session lifetime; no GC/storage-size guarantee. |
| Composition/status errors | At most 500 characters, reason code and entry key or required/configured sizes, never raw scratch values or ciphertext; bound at error creation. |
| Existing runtime/native requests | Existing tool/job/output/RPC/provider limits and deadlines unchanged. No added queue, timer, retry, cache or worker. |

Fold only in this order: process details → counts; VCS paths → counts; diagnostics → first 3 plus omitted count; test failures → count; changes → paths without line counts; checkpoints → most recent. Preserve availability/reasons/omission markers. Never fold turn, budget, scratch or notices; never silently cut scratch or block content.

Resolve configuration once per engine run, not from repository settings or hot reload; reject non-integers, unknown keys and ceilings below the calculated safe minimum **1310**. This is immutable maxima (30+40+400+80 = 550), plus worst-case folded allocations (vcs 40, changes 200, diagnostics 300, tests 40, processes 40, plan 60, checkpoints 60 = 740), plus 20 framing/separator tokens. The framing reserve covers at most 60 UTF-8 bytes; sections count their own labels/internal newlines. Shared allocation constants and tests must prove that maximum admitted scratch fits with every folded section, so a valid scratch write cannot strand the model solely through a too-small configured ceiling. Direct-composer test seams still refuse insufficient ceilings or invalid stored content. Children follow existing startup configuration behavior; historical observations retain actual text/size, not a mutable config pointer.

## Consequences

- **Rejected:** side-store memory, scratch replay/reexecution, raw writer access for unrelated tools, baseline-losing deltas, canonical-history surgery, collector frameworks without producers, live-log I/O without published references, completion-only observations and historical recomputation.
- **Trade-offs:** full snapshots spend tokens and bounded metadata duplicates text across steps; native compaction is projection-only, not journal GC. Conservative counting may refuse otherwise viable content. Strict roster/instruction lineage can require a new session after upgrade.
- **Evidence:** compare equivalent multi-step tasks for retained constraints/task outcomes, block/input tokens and available cached-input usage during apply. A stable system prefix does not prove cache neutrality. This ADR claims no executed new-behavior tests, live/native/cache evidence or delivery qualification.
- **Reversal cost:** medium for persisted scratch/framing and admitted metadata contracts; low for private renderer/mutator internals and future evidence-led presentation tuning. Destructive canonical-history changes remain prohibited.
