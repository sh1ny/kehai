# ADR 0007: Tree-derived perception with measured presentation choices

Status: accepted
Accepted: 2026-10-28
Date: 2026-10-28
Supersedes: none

## Context

The adopted [delivery](../sensorium-spec.md#delivery-model), [folding](../sensorium-spec.md#example-rendering-and-token-budget) and [VCS](../sensorium-spec.md#checkpoints-via-jj) contracts govern perception. History folding, Windows attribution and renderer thresholds require explicit proposals rather than untested guarantees.

## Decision

Keep system content stable and render current sensorium last in user content. The adopted mode table's delta-only-since-last-full rule conflicts with removing all previous blocks: unchanged baseline facts disappear from model context. A truly delta-only block is not self-contained. Resolve this conservatively as a supplement to the spec's open history-fold question, distinct from its literal mode table; do not rewrite the source spec.

Canonical tree/journal/history remain unchanged. One request-render fold switch defaults to stripping previous blocks; whenever that would remove unchanged facts needed to interpret the current delta, emit the current full snapshot with an honest `full` marker. Most stripped turns therefore send full snapshots, trading increased per-turn tokens for retained perception. Exact spec section order, fold limits/order, hard ceiling and immutable-section configuration error still apply. Delta delivery remains experimental only with a model-visible full baseline preserved, for example the same switch's retention arm; multiple retained blocks are not the adopted default.

In M2 A/B equivalent tasks, compare missing unchanged VCS, user-change and diagnostic facts and task outcomes, as well as token and prefix-cache metrics. A stable system prompt does not guarantee caching of the historical suffix after earlier blocks are removed; provider-safe hard token measurement and exact folding/configuration errors take precedence over cache claims.

Use bounded hash-on-turn-boundary scans on Windows with watcher hints only. Baselines/provenance are collector nodes; incomplete coverage is stale/partial. Hash anchors revalidate at edits. `by: user` means outside recorded tool provenance, not authenticated human action. Detect `.jj` first, including colocated repos; git checkpoints are best-effort hidden refs, never a replacement session store.

Propose the [architecture renderer experiment](../../openspec/architecture.md#resource-bounds-and-failure-visibility) early M2: visible-viewport work and controlled-sink timing, terminal flush reported separately. If nocterm misses the target, use a custom one-pass transcript renderer inside its component model. Do not implement a TUI in M1. M3 compaction validates snapshot lineage/revision before atomic splice and preserves scratch, handle ownership and request correlation/references in existing `body`/`meta`.

## Consequences

- **Rejected:** changing system prompt each turn or accumulating every sensorium block as the default; loses stable prefix or consumes context. Baseline-preserving retention remains an A/B arm, not an adopted delivery default.
- **Rejected:** mtime/watchers alone; Windows misses would assert false completeness.
- **Rejected:** eagerly rebuilding/layouting the entire transcript or replacing the framework before measuring; viewport work is the intended scalable boundary.
- **Cost:** hashing may yield explicitly partial observations; full fallback increases per-turn tokens; history A/B must measure retained facts/task outcomes and cache suffix invalidation; no latency claim before benchmark.
- **Reversal cost: low** for history-fold setting/renderer internals, **medium** for attribution baseline schema. M2 measurements settle defaults without changing locked tree/truncation/job contracts.
