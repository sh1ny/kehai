# Proposal

## Why

Every later Kehai feature writes session state, and [ADR 0001](../../../docs/adr/0001-one-session-tree.md), [ADR 0002](../../../docs/adr/0002-central-result-truncation.md) and [ADR 0005](../../../docs/adr/0005-four-field-journal-and-rpc.md) lock that state to one tree persisted as a four-field journal, with full results kept behind handles. Getting these wrong after tools, providers and clients depend on them is the most expensive reversal in the project, so they come first, before any other code exists.

This is change 1 of 6 in milestone **M1 — self-hosting skeleton** ([roadmap](../../roadmap.md)). It advances the exit criterion *"Every tool result uses central truncation/full-result handles, never tool-local cuts; property tests replay random journals to identical trees."* It also gives later changes the foundation they need: provider usage and turns (change 2), tool results and jobs (change 3), and the RPC projection (change 4).

## What Changes

- New Dart package at the repository root (`pubspec.yaml`, `lib/`, `test/`, `tool/`). This is the first code in the repo; nothing is replaced.
- **Session tree and journal:** an append-only UTF-8 JSONL journal where each record has exactly `{turn,path,op,value}`. A minimal operation vocabulary (`set`, `merge`, `del`, `rewind`) and validated slash-separated path identity. The engine is the single writer, enforced by an exclusive session lock. Each record is validated, durably appended and only then published.
- **Materialize and replay:** deterministic materialization of the tree from the journal. Torn trailing records are recovered by preserving their bytes and then truncating them. Complete invalid records and interior corruption stop writes visibly. Nothing is ever silently skipped.
- **Rewind and fork, journal-only, no UI:** rewind is one appended record that restores every turn-anchored subtree to the end of an earlier turn. `meta` (format, lineage, request correlation) survives rewind. Fork creates a child session whose origin record holds the parent tree at a point. The child copies the result bytes it references, so it stays readable after the parent is deleted.
- **Request admission and outcome correlation** in `meta`, so a duplicate request after rewind or reconnect sees its recorded outcome instead of executing again. On open, a recovery pass finalizes unfinished requests as `interrupted` before any new command is accepted.
- **Full-result store and handles:** result bytes are streamed into immutable, content-addressed files beside the journal before their descriptor record is appended. The tree holds descriptors and handles (`r/<id>`).
- **Central truncation:** a single composer function renders the result envelope (`[<tool> <status>] …`) with an explicit truncation line, head+tail cuts for logs and line caps for reads. Paging (`read_more`) and search (`search_result`) run over stored bytes. `notrunc` cannot exceed a stated capacity. No other code may cut results.
- **Migration script:** `tool/migrate_journal.dart` rewrites a journal through registered record migrations. It keeps the original, writes atomically and never executes effects.
- **Property tests:** randomized operation histories (including rewinds, requests, results and forks) must replay to the identical tree. They are checked against a naive reference model, and cover torn-tail and corruption cases. Each failure reports its seed so it can be reproduced.

Out of scope: job supervisor and rewind reconciler (change 3); tools (change 3); RPC, agent loop and line client (change 4); provider and auth (change 2). Also out: turn/budget rendering beyond the result envelope; nocterm, compaction, LSP and jj checkpoints (M2+); fork resource or UI management.

## Capabilities

### New Capabilities
- `session-journal`: the four-field record format, operation vocabulary, path identity, single-writer durable append, torn-tail recovery, corruption handling and explicit migration.
- `session-tree`: deterministic materialization, journal-only rewind and fork, request admission/outcome correlation that survives rewind, and open-time recovery of interrupted requests.
- `result-store`: immutable full-result bytes, tree-held descriptors and handles, central truncation with an explicit envelope, and paging/search over stored results.

### Modified Capabilities
None. There are no existing specs.

## Impact

- **Code:** new Dart package `kehai` (Dart 3.13 per `mise.toml`), `lib/src/session/`, `lib/src/results/`, `tool/migrate_journal.dart` and tests under `test/`.
- **Dependencies:** `crypto` (SHA-256) and `path`; dev dependencies `test` and `lints`. Versions are resolved with `dart pub add` during apply. No native assets, FFI or embedded runtime.
- **On-disk format:** introduces the session directory layout and journal format version 1. Later changes depend on it; a change to it requires a migration.
- **Tooling:** `mise run check` (format, analyze, test) becomes meaningful for the first time.
