# ADR 0002: Preserve full results; truncate only at projection

Status: accepted
Accepted: 2026-10-28
Date: 2026-10-28
Supersedes: none

## Context

The adopted [tool-result contract](../sensorium-spec.md#tool-result-contract) locks central truncation. Tool-local cuts destroy evidence and force expensive or unsafe reruns.

## Decision

Tools persist complete accepted stdout/stderr/result bytes as immutable chunks; the tree holds stable descriptors/handles. Only the model-facing composer applies presentation caps, with explicit shown range, total size and paging/search access. TUI rendering may expose more through the same handle. The spec owns envelope statuses, defaults and head/tail rules. Tool lifecycle and envelope status are distinct.

`notrunc` opts out of presentation cuts, not memory/transport/provider limits. Refuse an impossible request explicitly. Backpressure protects ingestion; storage failure cancels execution and produces explicit partial/error, never a success with silently lost bytes. See [resource bounds](../../openspec/architecture.md#resource-bounds-and-failure-visibility).

## Consequences

- **Rejected:** per-tool truncation or inline-only output; neither can recover omitted evidence after execution.
- **Rejected:** separate authoritative result metadata database; ownership must rewind/fork with the tree.
- **Cost:** result persistence, central composition and paging/search handles begin in the first M1 change, not after tools or UI. Preserve fork access where journal invariants require it without expanding M1 into a storage platform.
- **Reversal cost: high.** Lost bytes cannot be reconstructed safely. M1 validates long output, page/search and replay/reference safety; later compaction must preserve handles. Never rerun effects to reconstruct evidence.
