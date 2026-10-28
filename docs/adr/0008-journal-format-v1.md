# ADR 0008: Journal format v1: operations, paths, rewind and result handles

Status: accepted
Accepted: 2026-10-28
Date: 2026-10-28
Supersedes: none

## Context

[ADR 0005](0005-four-field-journal-and-rpc.md) fixes the record shape `{turn,path,op,value}` and leaves the operation vocabulary, path identity, torn-tail recovery, rewind/fork and request anchoring to the first change. The `session-tree-journal` change settles them ([design](../../openspec/changes/session-tree-journal/design.md), decisions D2–D10). They are the on-disk format every later change writes, so they are recorded here. Changing any of them is a format bump with a migration.

## Decision

### Operation vocabulary

Exactly four ops: `set` (replace the value at a path, creating missing parent maps), `merge` (set keys on a map, creating it when absent), `del` (remove an existing path and its subtree) and `rewind` (restore turn-anchored state to the end of an earlier turn). Atomic multi-field updates are one `set` or `merge` at the common ancestor. No JSON Patch, no begin/commit markers.

### Path grammar and root set

A path is 1–32 `/`-separated segments; each segment is 1–128 characters from `A-Z a-z 0-9 _ . : -`, so no escaping exists. The first segment is one of the v1 roots: `meta`, `body`, `scratch`, `checkpoints`, `jobs`, `collectors`, `results`. The empty path is the root and is valid only for the origin record and `rewind`.

### Origin record

Every journal begins with exactly one root `set` holding the whole initial tree, including `meta/format` (1), `meta/session` and `meta/lineage` (`{"parent":null}` for a new session). Its turn is the first turn: 0 for a new session, the fork point for a fork. No later record targets the empty path except `rewind`.

### Turn rule

A record's `turn` equals the current turn or the current turn plus one. Any other turn is `invalid turn`. The end-of-turn state is the tree after that turn's last record.

### `meta`-exempt timeline rewind

Records touching `meta` form the meta fold, which is never rewound. All other records form the timeline. `rewind K` (origin turn ≤ K < current turn) cuts the timeline after the last record with `turn ≤ K` and rebuilds the non-`meta` subtrees by replaying it; the current turn becomes K. Live operation and materialization use the same algorithm. History is never edited. `meta` holds only session-lifetime facts (format, session, lineage, requests, settings); turn-anchored facts never go there.

### `meta/requests` anchoring

`meta/requests/<id>` holds `{fingerprint, state, turn, outcome?, reason?}`. Admission is one serialized writer operation: a new id is recorded `admitted`; the same fingerprint returns the recorded node and appends nothing; a different fingerprint is `request id collision`. Because `meta` is exempt from rewind, correlation survives rewind. Opening for write finalizes every `admitted` request as `interrupted` with reason `effect-uncertain` before accepting commands.

### Newline commit marker and torn-tail policy

The terminating `\n` marks a record committed. A final line without it is torn, even if it is valid JSON. Read-only materialization ignores it and reports its size; opening for write copies it to `recovery/torn-<offset>-<utc>.bin`, flushes, then truncates the journal to the last newline. A newline-terminated line that fails parsing, schema validation or application stops both modes, naming line, offset and reason, and leaves the file unmodified. No per-record checksums.

### Result descriptors and handles

Result bytes live in immutable content-addressed files `results/<sha256>`, written and flushed before any record references them. The descriptor at tree path `results/<id>` (`<id>` = first 12 hex digits of the SHA-256) is `{handle:"r/<id>", sha256, bytes, lines}`: facts about the bytes only. Completion belongs to the occurrence: each result reference records `{handle, complete}`. Handles resolve only through the current tree. An existing descriptor with a different hash is `handle collision`.

### Copy-on-fork with current `meta`

Fork at turn K is a writer operation over acknowledged state. The child's non-`meta` subtrees are the end-of-turn-K values; its `meta` is the parent's current `meta` with only `meta/session`, `meta/lineage` (`{parent, parentTurn: K}`) and `meta/requests` (`{}`) replaced. Referenced result files are copied and SHA-256 verified into a temporary directory that is renamed into place. The child never references the parent's files, and the parent is never written.

### Single-writer gate/owner protocol

The session directory holds `session.owner` (`{pid, nonce, startedUtc}`, always renamed into place), `session.lock` (an OS lock used only as a foreign-liveness probe) and the transient `session.gate` (exclusive create, held for milliseconds). Every claim, takeover and release runs under the gate. Under the gate, an absent owner is claimed and locked; an owner naming this process is refused with `session locked`; a foreign owner is taken over only if the OS lock can be acquired. Release closes the lock handle first, then deletes the owner record under the gate only if its pid and nonce match. A gate that cannot be acquired within 2 s, including an empty one, is refused with a message naming the pid (or `pid unknown`) and the file to remove.

### `observed` disk reads

Read-only materialization does not take the lock. While a writer is active its result is `observed`, not acknowledged, because a line can be on disk before or despite a failed flush. Fork and RPC take acknowledged state from the writer's in-memory folds.

### Migration contract

The format version lives in `meta/format`. Opening an older format fails with `format <n> requires migration` naming `tool/migrate_journal.dart`; a newer one fails with `format <n> is newer than this kehai`. The migration tool claims the session through the owner protocol, recovers a torn tail as above, applies registered pure `n → n+1` record transformations, writes `journal.jsonl.migrating`, then renames the original to the byte-identical `journal.v<n>.jsonl` backup and the new file to `journal.jsonl`. It never executes recorded effects and never runs on open.

## Consequences

- **Accepted limitation:** on macOS, Dart's `flush()` calls `fsync`, which does not force a drive-cache flush (no `F_FULLFSYNC`). macOS is not an M1 platform; a macOS target must revisit durability.
- **Accepted limitation:** Dart has no directory fsync, so on Linux power loss can lose a renamed result file or a new directory entry. The failure is visible (`result bytes missing for r/<id>`).
- **Cost:** rewind replays the live timeline (O(records)); in-memory timeline grows with session length until an index is needed.
- **Reversal cost: high.** Any change to the vocabulary, paths, rewind semantics, handle format or descriptor shape is a format bump with a registered migration.
