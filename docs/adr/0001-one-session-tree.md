# ADR 0001: One authoritative session tree

Status: accepted
Accepted: 2026-10-28
Date: 2026-10-28
Supersedes: none

## Context

The adopted [session model](../sensorium-spec.md#session-model) locks this decision before code. Rewind/fork/resume must cover messages, scratch, jobs, checkpoints and collector state together. Draft status records the baseline review gate, not permission to reconsider the locked choice.

## Decision

The engine is the sole tree writer, appending minimal property operations as JSONL records exactly `{turn,path,op,value}`. Each record is the atomic append boundary; compound admission/completion belongs in tree state, not an envelope. Sensorium, RPC and all clients are projections. Rewind appends restoration; no feature-specific rewind handlers. Fork preserves lineage and required result access. Resume reconstructs logical state, not external effects. Operational details and the first design's compound-update recovery gate live in [architecture](../../openspec/architecture.md#boundaries-and-contracts).

Result bytes beside the journal are immutable payloads only; handles, ownership, pins and references belong to the tree. Session permissions, requests and child-agent state also belong to the tree, never side databases. Configuration and secure credentials are explicit external inputs/exceptions; runtime OS handles are disposable, not session facts. Later imported project-memory content/hash is tree input, never scratch recovery; pin export remains deferred.

## Consequences

- **Rejected:** a message-only journal plus plugin/job/scratch side stores; rewind would depend on every feature's independent lifecycle code.
- **Rejected:** clients or database indexes holding authoritative session state; reconnect/rebuild would change semantics.
- **Cost:** historical schemas and tree ownership need explicit migration; workers may propose changes but cannot write around the engine.
- **Reversal cost: high.** This is the locked foundation. M1 property tests must prove randomized replay yields the identical tree, rewind/resume and fork/result-reference invariants, including parent-deletion safety where applicable. Elaborate fork resource/UI management is deferred; failures require correcting the implementation, not adding a side store.
