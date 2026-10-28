# ADR 0007: Tree-derived perception with measured presentation choices

Status: accepted
Accepted: 2026-10-28
Date: 2026-10-28
Supersedes: none

## Context

The unchanged [delivery](../sensorium-spec.md#delivery-model), [folding](../sensorium-spec.md#example-rendering-and-token-budget) and [VCS](../sensorium-spec.md#checkpoints-via-jj) contracts govern perception. The amendment narrows M1 delivery, not the locked foundations or source authority. History folding, Windows attribution and renderer thresholds remain reviewed proposals, not tested guarantees.

## Decision

M1 sensorium is only `turn`, `budget` and central truncation/full-result handles. Use exact provider counts when available, otherwise documented conservative estimates; no pricing/model registry is required. Context overflow stops visibly, without M1 compaction. Result handles begin in change 1. Broader VCS/changes/scratch/diagnostics/checkpoints sensorium is M2, on the same tree. Nocterm, compaction, LSP, jj checkpoints and other explicit deferrals are M2+ without an exact M3 promise. The roadmap's entry-6 bridge permits only its selected first M2 capability after the skeleton is ready, not general pull-forward.

For broader M2 perception, keep system content stable and render the current sensorium last in user content. The source mode table's delta-only-since-full rule conflicts with stripping every previous block: unchanged baseline facts disappear. Proposed supplement to its open history-fold question: keep canonical tree/history unchanged; default request-only folding strips previous blocks but emits an honestly marked full snapshot whenever needed facts would otherwise vanish. Do not relabel delta-only content self-contained or rewrite the source spec. Exact section order, fold order/limits, hard ceiling and immutable-section configuration errors remain authoritative. Baseline-preserving delta/retention is an experiment, not the adopted default.

Compare equivalent tasks for retained unchanged VCS/user-change/diagnostic facts and task outcomes, plus tokens and prefix-cache effects. A stable system prefix does not guarantee historical-suffix cache neutrality. Later Windows scans use bounded hashing as authority, watchers only as hints; collector baselines/provenance live in tree nodes, incomplete coverage is explicitly stale/partial, and `by: user` means outside recorded tool provenance rather than authenticated human action. M1 edit-time hashes independently reject stale or moved anchors loudly. Detect `.jj` first when VCS collectors land; external VCS state never substitutes for the session tree.

When nocterm work starts, run the proposed [renderer experiment](../../openspec/architecture.md#resource-bounds-and-failure-visibility): visible-viewport work, release/AOT controlled-sink timing and terminal flush reported separately. Consider a one-pass transcript renderer within nocterm only if measurements justify it. No TUI or benchmark implementation is M1 work. Later compaction remains journal-derived, validates lineage/current state, rejects stale work and preserves scratch, result handles and tree-held request/child correlation; snapshots never become primary persistence.

## Consequences

- **Rejected:** broad sensorium/compaction/renderer work as M1 prerequisites; the self-hosting gate needs a small functional skeleton.
- **Rejected:** changing system content every turn or accumulating all perception blocks by default; baseline-preserving retention is only an experiment.
- **Rejected:** mtime/watchers as sole change authority or eager full-transcript layout before measuring; both create false completeness/performance assumptions.
- **Cost:** later hashing may be partial, full fallback increases tokens, and folding experiments must measure retained facts/task outcomes rather than cache claims. No latency result is claimed.
- **Reversal cost: low** for fold settings/renderer internals, **medium** for attribution schema. Later measurements settle defaults without changing locked tree/truncation/job foundations. Apply the shared [per-M1 design contract](../../openspec/architecture.md#decisions-and-per-m1-design-contract).
