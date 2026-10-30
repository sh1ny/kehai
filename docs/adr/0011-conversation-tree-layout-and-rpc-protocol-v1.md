# ADR 0011: Conversation tree layout and RPC protocol v1

Status: accepted
Accepted: 2026-10-30
Date: 2026-10-30
Supersedes: none

## Context

[ADR 0001](0001-one-session-tree.md) keeps the whole conversation in the session tree, and [ADR 0010](0010-tool-call-and-job-tree-layout.md) fixes where calls and jobs live. Neither says where the user's prompts and the model's replies live. The `agent-loop-and-line-client` change adds the agent loop and its first client ([design](../../openspec/changes/agent-loop-and-line-client/design.md), D2, D4, D11 and D12). Changes 5 and 6 read the conversation layout, and later clients (nocterm, Kumiko) speak the same protocol as the line client, so both are recorded here. [ADR 0005](0005-four-field-journal-and-rpc.md) already chose a local NDJSON RPC with request admission, stale rejection and resync; this ADR fixes its version 1. No new root is added, so the journal format stays v1.

## Decision

### Exchanges and steps: `body/exchanges/x-<turn>`, `body/steps/s-<turn>`

- **Exchange:** a user prompt opens `body/exchanges/x-<first turn, 8 digits>` with `{request, prompt, state, reason?, first, last?}`. `state` moves `running` → `done`, `cancelled`, `stopped` or `failed`. The exchange and its first step are written at turn `T` = the current turn + 1.
- **Step:** each model request is one step and one journal turn `T`: `body/steps/s-<T, 8 digits>` with `{exchange, model, instructions, state, attempts, stop?, usage?, context?, output?, partial?, failure?, reason?}`. `state` moves `running` → `completed`, `failed` or `cancelled`. `instructions` is the version of the built-in instructions. Each later step of an exchange takes the next turn, so rewind can cut between steps and the turn counter counts model requests.
- **Step commit:** a step ends with one `merge` on its node. On success it carries the state, stop reason, usage and `output`, ordered by the backend's output index: `{type: text, text}`, `{type: reasoning, item}` (the opaque item, unchanged) and `{type: call, call: <key>, callId, name, arguments}`. A step's text and calls therefore commit atomically with its completion. The tool runtime then creates the calls' `body/calls/<key>` nodes in the same turn.
- **Exchange end:** a `merge` on the exchange node, then `complete` on the request with `{exchange, state}`.
- **Requests** are rebuilt from these nodes before every step. A call whose node is absent or not terminal is left out with its output, since the backend rejects an unpaired call. A cancelled or failed step contributes nothing to the request; its `partial` text is display-only.

### The call node's `model` reference

This adds one field to ADR 0010's call fields, which stay in force otherwise. The runtime composes the call's model text (the envelope plus diagnostic lines) before the terminal record, stores it in the result store, and adds `model: {handle, complete: true}` to the terminal `merge` that holds `result`. Every later request sends those bytes unchanged. The descriptor check covers the new reference. A call node without `model` (written before this ADR, or after a storage failure of the model text) is recomposed with its tool's default policy and its recorded `diag`.

### RPC protocol v1

`kehai rpc` speaks protocol version 1: one JSON object per line over standard input and output, UTF-8, each with a string `type`. An input line is at most 1 MiB.

- **Client → engine:** `submit {id, text, turn}`, `interrupt`, `answer {key, text}`, `status {id}`.
- **Engine → client:** `hello {protocol, session, workspace, model, resumed}`, `snapshot {offset, turn, tree}`, `update {offset, record}`, `stream {turn, kind, delta}`, `prompt {item}`, `withdraw {key}`, `reply {to, ok, …}`, `resync`, `error {to?, message}`, `fatal {message}`. `reply.to` is the request id, or the command type for `interrupt` and `answer`.
- **Startup:** `hello` and the first `snapshot` are sent only after resume has finalized every unfinished exchange, so a client never sees a running exchange that no engine owns.
- **Admission:** a `submit` id is 1-128 characters from `A-Z a-z 0-9 _ . : -` and is admitted in `meta/requests` before any effect. A repeated id with the same content reports the recorded state and runs nothing; different content is a collision. `admitted` and `interrupted` requests are never executed again.
- **Staleness** is checked against the journal turn, not the log offset: background job records move the offset constantly, while the turn still rejects a prompt typed against an older exchange.
- **Reliable and droppable output:** `reply`, `error`, `prompt`, `withdraw`, `hello` and `fatal` are never dropped; while more than 1 MiB of them is queued, the engine stops reading standard input. `update` and `stream` are droppable: past 16 MiB queued, or when the writer subscription overflows, they are discarded.
- **Coalesced resync:** after a drop, at most one `resync` + `snapshot` pair is pending. The snapshot is taken from the tree when it is written, so it is always the latest tree and no committed update falls between it and the next `update`. A committed `rewind` is followed by `resync` and a snapshot as well, since a client mirror holds no timeline to fold it into.
- **Stream events** are display hints only; a step's committed `output` is the only record of its text.

## Consequences

- Changes 5 and 6 address conversation content by exchange and step keys, and calls by key, never by array position.
- Moving these paths later needs a journal migration under ADR 0008's rule. M1 sessions are development data, so such a migration would be small.
- A protocol change that breaks a v1 client needs a new version number in `hello`; additive message fields do not.
- The snapshot sends the whole tree. That is accepted for M1; paged snapshots come with compaction (M2+).
