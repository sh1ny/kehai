# ADR 0005: Four-field JSONL journal and local RPC

Status: accepted
Accepted: 2026-10-28
Date: 2026-10-28
Supersedes: none

## Context

Property-patch persistence and one authoritative tree are locked. The user fixes the minimal record shape; one writer needs neither multi-writer merge semantics nor a storage platform. Public storage mistakes are expensive to reverse.

## Decision

Append UTF-8 JSONL records with exactly four fields: `{turn,path,op,value}`. Each record is an atomic append boundary, not an envelope of operations. No mandatory transaction IDs, digests, revision chains, segments or extra record metadata. Store format version, lineage, request correlation and compound-operation admission/completion in tree nodes such as `meta`; derive ordering from log offsets. Validate the property operation and persist referenced immutable result bytes before durable append, then publish/acknowledge it. Result descriptors and handles are part of the first change.

Compound operations span records: tree-held admission/completion must detect interrupted updates, not imply atomic multi-record append. The first change design must settle the minimal operation vocabulary/path identity, torn trailing-record recovery, exact interrupted-compound behavior and rewind/fork operations without UI. Complete invalid records/interior corruption stop writes visibly; never silently skip them. Include an explicit migration script preserving originals and randomized property tests proving replay yields the identical tree. Recovery/migration never executes recorded provider/tool/workspace effects. Elaborate fork resource/UI management is deferred unless required to preserve journal/result-reference invariants.

`kehai rpc` is local NDJSON stdio. M1's line client is a thin projection over initial materialization and ordered committed updates by log offset. Entry 4 settles only the framing/backpressure needed for this client; no network server or generic transaction-transfer protocol is required. Record effectful request admission/outcome in existing tree nodes, scoped to session/lineage. Reject stale inputs and request-ID collisions. Matching duplicates inspect outcomes rather than execute again. Reconnect distinguishes proven not-admitted, pending, terminal, interrupted/effect-uncertain and unavailable; lost acknowledgement never licenses automatic replay. Runtime cursors are not durable truth, and there is no request side database or exactly-once external-effect guarantee.

## Consequences

- **Rejected:** generic JSON Patch/RFC 6902 breadth and CRDT multi-writer merge semantics; use only the minimal operations required by the single tree writer, settled in the first design.
- **Rejected:** transaction-envelope/digest schema, snapshots-primary persistence, SQLite requirements or native-memory-cap architecture that turns M1 into a storage platform. No feature/request side stores.
- **Cost:** own a small operation schema, explicit migration and crash-recovery rules. Per-record atomicity requires honest interrupted-compound detection before accepting more commands.
- **Reversal cost: high.** Random replay, torn/invalid lines, interrupted updates, migration, rewind/fork and result access must establish correctness before durable sessions ship. Later compaction remains journal-derived and retains tree correlation/handles. See [architecture contracts](../../openspec/architecture.md#boundaries-and-contracts) and the shared [per-M1 design contract](../../openspec/architecture.md#decisions-and-per-m1-design-contract).
