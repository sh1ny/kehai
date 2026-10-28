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
- **Cost:** disk consumption, paging and fork ownership must be designed in M1; compaction retains handles.
- **Reversal cost: high.** Lost bytes cannot be reconstructed safely. Validate long output, page/search, compaction preservation and fork deletion safety; do not benchmark correctness by rerunning effects.
