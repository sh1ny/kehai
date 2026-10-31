# Design

## Triage

| Trigger | Applies? | Evidence |
|---|---|---|
| T1 Components (new component, or 3+ with directed relationships) | No | Existing parts change: the gate's prompt input and record (`lib/src/permissions/gate.dart:224-290`), `edit`'s mutation check (`lib/src/tools/edit.dart:40-80`), and the client body (`lib/src/client/render.dart` `promptBody`). |
| T2 State (persistent state, caches, 3+ state machine) | Yes | The permission record, which the runtime merges into the call node (`lib/src/tools/runtime.dart:560-565`), and so into the journal, gains `sha256`. |
| T3 Concurrency (background work, workers/isolates, async, retries) | Yes | The file can change between the gate's read, the answer and the edit. Parallel calls can edit the same file while a prompt is open (tool-calls *Bounded parallel calls*). |
| T4 Boundaries (data format, migration, shared interface, IPC, external) | Yes | The `prompt` event's input gains `old` (engine-rpc *Prompts reach the client*, ADR 0011). The field is optional and additive. |
| T5 Volume (grows without a fixed bound) | Yes | `old` grows with the lines an edit removes, up to a whole file of 16 MiB (`maxEditBytes`, `edit.dart:24`). |
| T6 Risk (security, money, data loss, unrecoverable user data) | Yes | The prompt is what the user approves a file change from. |

TIER: FULL

## Context

The `edit` prompt shows each operation and its new text (line-client *Permission prompt body*), but not the lines a `replace` or `delete` removes. The client holds no files (ADR 0004), so #21 needs the engine. The gate already resolves the edit's target (`_target`, `gate.dart:212-216`) and records it on allow, and `edit` refuses a target that moved (`movedDenial`, `lib/src/tools/file_access.dart:89-99`). `edit` reads the whole file (16 MiB limit), checks UTF-8, skips a BOM and splits lines at CRLF, CR and LF (`_Lines`, `edit.dart:170-222`). It writes only if the file is unchanged since its own `stat` (`writeAtomically`, `unchangedSince`). The block anchors are 4 hex digits (`edit.dart:29`), so they catch accidental staleness but cannot bind an approval: a 16-bit hash is cheap to collide.

oh-my-pi, at `2e23dffe598636817a9bab407cf55e6f9e9a8f82`, shows only `File: <path>` (and moves) in an edit's approval details (`packages/coding-agent/src/edit/index.ts:432-441`), although its edit input is itself a patch with `-` and `+` lines. Kehai's edit names line numbers instead, so the removed lines are not in the input and have to be read from the file.

M1 constraints hold: Dart 3.x AOT, no Rust core, no embedded script runtime, and no durable session state outside the tree. Sensorium and truncation are untouched. Nocterm, compaction, LSP, jj checkpoints, the plugin protocol, MCP, Anthropic OAuth, the pricing registry and themes stay deferred to M2+. The line client runs on native Windows without WSL, as now. Kehai apply attempt: applied with Claude Code. Specwright inside Kehai needs entry 5, so the attempt is recorded as unsupported.

## Decisions

### D1: The gate reads the file and sends `old`

- **Choice:** when the gate opens an `edit` prompt, it reads the resolved target once. A file it cannot read as `edit` would (missing, a directory, over 16 MiB, not UTF-8) gives no `old`. Otherwise `old` has one entry per op in `ops` order: the removed lines for a `replace` or `delete` whose `start` and `end` are integers with `1 <= start <= end <= line count`, and null for anything else. When the line ranges of two `replace` or `delete` operations overlap, there is no `old` at all: the removed lines of disjoint ranges are at most the file's lines, so `old` stays within the 16 MiB read, whatever the number of operations. `edit` rejects overlapping operations before any effect (`_overlap`, `edit.dart:447-472`), so leaving out `old` there hides no line the edit could remove. The lines come from the same splitting `edit` uses. `_Lines` is reused through a shared function in `edit.dart`, not copied, so the prompt shows exactly the lines `edit` removes. The model's `ops` are not changed.
- **Rejected:** a diff of the whole result, because it needs the edit's full validation and application in the gate, which then has two implementations of `edit`. Also rejected: putting old lines inside each op, because the prompt input would then differ from what the model sent in the field the tool reads.
- **Reversal cost:** low. `old` is optional, and a client that ignores it shows what it shows now.

### D2: Approval is bound to the bytes read

- **Choice:** on allow, the record carries `sha256`, the hex SHA-256 of the bytes the gate read (`package:crypto`, already a dependency). `edit` reads the file as now and, before planning, refuses with status `denied` and `the file changed after it was approved; ask again` when the record has `sha256` and the bytes hash differently. So the lines `edit` removes are the lines the user saw, in the bytes `edit` read. Between that read and the rename, only the existing `unchangedSince` check applies, which compares size and modification time (`lib/src/tools/atomic_write.dart:113-121`). A writer outside Kehai that keeps both can still slip a change through in that window, as it can for every `edit` and `write` today. Closing that window needs file locking, which no platform Kehai runs on offers for every writer. Without `sha256` (the file was unreadable at the prompt, or the call was allowed by a rule or `--yolo`), `edit` behaves as now.
- **Rejected:** checking the old lines only, because the line numbers the user saw would no longer point at the same lines after a change above them. Also rejected: trusting the block anchors, because they are 16-bit (Context).
- **Reversal cost:** low. One record field and one check.

### D3: The client shows `-` and `+`

- **Choice:** under each edit operation, the old lines are `  - <line>`, followed by the new text as `  + <piece>`. `write` content keeps `  | `, since it has no old side. A `delete` with no `old` entry shows only its header, and a replace with none shows only `+` lines. A non-list `old`, or an entry that is not a list of strings, shows no `-` lines for that op.
- **Rejected:** keeping `  | ` for new text, because in a replace the reader could not tell which lines go and which come.
- **Reversal cost:** low.

### D4: `1 more line`

- **Choice:** the preview's notice is `  … 1 more line; v shows all` when exactly one line is left out.
- **Reversal cost:** none.

## Diagrams (FULL)

```mermaid
sequenceDiagram
  participant M as model call
  participant G as gate
  participant C as client
  participant E as edit
  M->>G: edit {path, anchors, ops}
  G->>G: read target, split lines, sha256
  G->>C: prompt {input + old}
  C-->>G: answer allow
  G->>E: record {decision, by, target, sha256}
  E->>E: read file; sha256 differs? refuse
  E->>E: plan, write if unchanged since stat
```

## State & Ownership (FULL)

| State | Owner (sole writer) | Lifetime | Invalidation / rebuild | Authoritative copy |
|---|---|---|---|---|
| `old` in the prompt input | The gate | While the prompt is open (in memory, sent as an event) | Read again for each prompt | The file on disk |
| `sha256` in the permission record | The gate | The call node in the journal | Never changed; a new call gets a new record | The record |

## Failure & Visibility (FULL)

| Component | Fails / dies mid-operation → | Recovery | Retry safe? | Who finds out |
|---|---|---|---|---|
| Gate read | An unreadable file gives no `old` and no `sha256`; the prompt shows line numbers only, as now | `edit` refuses later for the same reason in nearly every case | Yes | The user sees no `-` lines |
| File changed after approval | `edit` refuses with `denied`, nothing written | The model reads again and calls again; a new prompt shows the new lines | Yes | The model and the user, through the call line |
| Parallel edits of one file | The later edit, approved against the earlier bytes, is refused | As above | Yes | Same |

## Resource Bounds (FULL)

| Queue / buffer / cache / transfer | Bound | At the bound | Timeout | At 10x / 100x |
|---|---|---|---|---|
| Gate file read | 16 MiB, as `edit` | No `old`, no `sha256` | None | The same read `edit` does next; one read per prompt |
| `old` in the event | The lines removed by disjoint ranges, at most the whole file (16 MiB), whatever the number of operations | Overlapping ranges give no `old` (D1) | None | Accepted: one prompt, one user action. The record holds 64 hex characters, not the lines |

## Flow & State Gaps (FULL)

- A prompt waits while another call changes the file: the shown lines are stale, and D2 refuses the edit after allow.
- The file is missing at the prompt and created before the edit runs: there is no `sha256`, so the edit is not bound (D2). This is accepted, because the user saw no old lines and the model named lines in a file that did not exist.
- A rule or `--yolo` allows the call: there is no prompt, no read and no `sha256`.
- An outside writer changes the file after `edit` hashed it, keeping its size and modification time: the edit can still apply over that change (D2). This limit is the same as for every write today.
- On resync, an open prompt is sent again with the same input, `old` included.

## Mechanism Ledger (FULL)

| Mechanism | Built? | Why (harm nobody catches / expensive later) | Evidence that would change the call |
|---|---|---|---|
| SHA-256 binding | Yes | Without it, the user approves lines that are no longer the ones removed. | - |
| Shared line splitting | Yes | A second splitter could show different lines from the ones `edit` removes. | - |
| Cap on `old` | No | Same as `write` content; the preview bounds the display. | Dogfood memory or latency with huge edits |
| Old lines for anchors-only context | No | Not part of the change. | Users asking for surrounding context |

## Risks / Trade-offs

- [Edits in parallel on one file now need a second round] → They mostly fail on stale anchors already. The refusal says to ask again.
- [Reading the file twice per edit] → Up to 16 MiB more I/O per prompted edit, and only when a person is waiting on the prompt anyway.

## ADRs

- **In force, constraining this change:** [0004](../../../docs/adr/0004-dart-native-engine-and-clients.md) (the client renders what the engine sends) and [0011](../../../docs/adr/0011-conversation-tree-layout-and-rpc-protocol-v1.md) (the `prompt` event; an optional input field is additive).
- **To record during apply:** none.
