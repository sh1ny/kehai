# ADR 0001: One authoritative session tree

Status: accepted
Accepted: 2026-10-28
Date: 2026-10-28
Supersedes: none

## Context

The adopted [session model](../sensorium-spec.md#session-model) locks this decision before code. Rewind/fork/resume must cover messages, scratch, jobs, checkpoints and collector state together. Draft status records the baseline review gate, not permission to reconsider the locked choice.

## Decision

The engine is the sole tree writer, serializing atomic versioned transactions into an append-only property-patch journal. Sensorium, RPC and all clients are projections. Rewind appends restoration; no feature-specific rewind handlers. Fork creates a new lineage with deletion-safe ownership of immutable result bytes. Resume reconstructs logical state, not external effects. Operational details live in [architecture](../../openspec/architecture.md#boundaries-and-contracts).

Result bytes beside the journal are immutable payloads only; handles, ownership, pins and references belong to the tree. Optional SQLite indexes are disposable. Imported project-memory content/hash is external input snapshotted in `meta`, never scratch recovery; pin export remains deferred.

## Consequences

- **Rejected:** a message-only journal plus plugin/job/scratch side stores; rewind would depend on every feature's independent lifecycle code.
- **Rejected:** clients or database indexes holding authoritative session state; reconnect/rebuild would change semantics.
- **Cost:** historical schemas and tree ownership need explicit migration; workers may propose changes but cannot write around the engine.
- **Reversal cost: high.** This is the locked foundation. M1 property tests must exercise randomized materialization, rewind-then-resume, fork and parent deletion before UI code; failures require correcting the implementation, not adding a side store.
