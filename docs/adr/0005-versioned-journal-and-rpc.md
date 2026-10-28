# ADR 0005: Minimal versioned atomic journal and local RPC

Status: accepted
Accepted: 2026-10-28
Date: 2026-10-28
Supersedes: none

## Context

Property-patch persistence is locked; its encoding remains a reviewed proposal. The engine has one writer, so multi-writer merge semantics provide no current benefit. Public wire/storage mistakes are expensive to reverse.

## Decision

Propose versioned UTF-8 NDJSON atomic transaction envelopes: lineage, transaction ID, base/result revision, stable-node property operations and integrity digest. Persist immutable referenced bytes before durable transaction append, then publish/acknowledge. Exact v1 operations, limits and migration fixtures must settle in M1 before schema implementation.

Incomplete final lines are uncommitted; preserve them and continue a new segment from the last valid revision. Interior corruption, complete invalid lines or broken revision chains stop writes visibly. Versioned migrations preserve originals and never execute recorded effects.

Local stdio RPC is separately versioned: initial materialization at a revision followed race-free by ordered committed patches. Commands carry expected revision/request ID; bounded subscriptions use resync rather than dropped patches. Before effectful execution, commit admission in existing `body`/`meta`: request ID scoped to session/lineage, command type and matching input identity, resulting node/operation references and status. Reject ID collisions or mismatching commands; matching duplicates inspect the recorded outcome rather than execute again. No separate request database.

Reconnect inspection derives correlation from tree/journal, reporting `not-admitted` only with proven coverage of the queried session/lineage and log scope; otherwise `admitted/pending`, `completed/failed/cancelled`, or `interrupted/effect-uncertain` if external effects cannot be established. A lost external acknowledgement never permits automatic replay; this is not exactly-once external execution. Bounded-history compaction preserves correlation/references in `body`/`meta`; if retained history cannot establish an outcome, report `unavailable`, never guess absence. Cursors are runtime capabilities, not durable truth. See [architecture contracts](../../openspec/architecture.md#boundaries-and-contracts).

## Consequences

- **Rejected:** JSON Patch/RFC 6902 as the journal; generic array/path addressing does not fit stable-node lifecycle operations and adds unnecessary operation surface. It can be wrapped in versioned atomic envelopes; that is not the reason for rejection.
- **Rejected:** CRDT log; offline multi-writer merge/collaboration is out of scope and conflicts with the deliberately serialized engine.
- **Rejected:** snapshots or SQLite as primary session storage; neither is the adopted append-only property journal.
- **Cost:** own a small schema, validators and migrations. RPC NDJSON must not be reused as LSP framing.
- **Reversal cost: high.** Randomized replay, torn-line/corruption, schema migration and slow-client/resync fixtures must establish the format before durable sessions ship.
