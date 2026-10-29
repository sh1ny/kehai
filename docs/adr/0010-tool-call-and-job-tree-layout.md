# ADR 0010: Tool-call and job tree layout

Status: accepted
Accepted: 2026-10-29
Date: 2026-10-29
Supersedes: none

## Context

[ADR 0003](0003-unified-job-lifecycle.md) puts every tool call and process under one supervised lifecycle, with a generic rewind reconciler and resume finalization, and [ADR 0001](0001-one-session-tree.md) keeps all of that state in the session tree. [ADR 0008](0008-journal-format-v1.md) fixes the v1 roots, the path alphabet, the `meta`-exempt rewind and the result-handle contract, but not where calls and jobs live. The `core-tools` change settles it ([design](../../openspec/changes/core-tools/design.md), D2, D4, D8, D9 and D11). Changes 4 and 5 read this layout (the loop's message chain references call keys; subagents are jobs), and moving it later needs a journal migration, so it is recorded here. No new root is added, so the journal format stays v1.

## Decision

### Call nodes: `body/calls/<key>`

- **Key:** `c-` plus the first 12 lowercase hex digits of SHA-256 over the UTF-8 provider call id. Any provider id therefore becomes a valid ADR 0008 path segment; the node's `callId` field keeps the provider id exactly, and the call's output pairs with that id.
- **Fields:** `{tool, version, callId, attempt, input, status, permission?, hooks?, diag?, envelope?, summary?, result?, reason?}`.
  - `status` moves `pending` → `running` → `settled`, `failed` or `cancelled`, or from `pending` straight to `failed` or `cancelled`. A terminal status never changes.
  - `input` is recorded with `pending`, so a crash after admission still shows what was asked.
  - `result` is `{handle, complete}`. Every terminal node carries an envelope status and a stored result, except a call whose result storage itself failed: that node is `failed` with `reason: "storage: <error>"`, `accepted: <bytes>` and no `result`.
  - `permission` records the gate's decision (rule label, prompt answer or yolo grant) before the call runs.
- The registry is flat. It is not nested under each turn's message, so resume and the reconciler find every call without walking message structure.

### Job nodes: `jobs/<id>`

- **Id:** `j-` plus 8 random hex digits.
- **Shape:** one shape for every process the engine starts: `kind` (`shell` or `hook`), `cmd`, `cwd`, `shell` (`null` for argv-direct jobs such as `rg`), `call` (the owning call key), `launch` (a fresh random token per launch), `state` (`pending`, `running`, `settled`, `failed` or `cancelled`), `started`, `ended`, `exit`, `signal` intent, `spool` (its temporary output file names), `cleanup`, `reason`, and the `stdout`, `stderr` and `output` result references `{handle, complete}`. A stream recovered with no bytes on disk has no reference; it is listed in `absent` instead, never stored as an empty success.
- **No PIDs.** The node never holds a process id or OS handle. Process handles are ephemeral runtime capabilities; PID reuse makes a stored PID unsafe.

Both `body` and `jobs` are turn-anchored v1 roots, so rewind and fork cover calls and jobs with no new code.

### Rewind-exempt session records in `meta`

- **`meta/handoffs/<launch>`: launch record and intent.** Appended (guarded: absent) at a job's admission, before its `pending` node and before any spool file exists: `{job, session, spools: {<stream>: <name>}}`. At exit the supervisor seals each stream and merges the **intent** `{streams: {<stream>: {spool, sha256, bytes, lines, complete}}, outcome}`. `complete` is stored per stream and never derived later; cancellation, deadline, interruption and adoption on resume always store `false`. `session` is `meta/session` when written, so a fork child that inherited the record recognises it as foreign. The record lives until the job's settle, or until its output mapping has moved to `meta/orphans`; it is then deleted under the cleanup guard.
- **`meta/orphans/<id>`: rewind casualties.** A job killed because rewind removed or superseded its node gets `{cmd, rewoundTo, cleanup}`, plus `outputs/<launch>`: one entry per stream with its spool name, its hash when known and its disposition (`published`, `spooled` or `absent`). Every writer uses `merge`, or a `set` below its own subkey such as `outputs/<launch>`, so the kill record and the output mapping never overwrite each other.

`meta` is rewind-exempt (ADR 0008), so a job's spool names are durable for its whole life, and a kill that rewind caused stays visible after the rewind.

### Guarded append

All runtime and supervisor updates to `body/calls/*`, `jobs/*` and `meta/handoffs/*` go through `SessionWriter.applyGuarded(build)`. `build` runs inside the writer's queue-head `decide` and returns the record or a refusal; a refusal appends nothing. There is still one writer.

- **Ownership guard,** for every call and job transition: the node exists, its `attempt` or `launch` equals the caller's, and its status is not terminal. Otherwise the answer is `stale`. A `stale` answer for a live process obliges the supervisor to terminate it and record the orphan when the node is gone.
- **Launch record guard:** the record is absent. **Intent guard:** the record exists without `streams`, and the job node exists with this `launch` and is non-terminal.
- **Cleanup guard,** for deleting `meta/handoffs/<launch>`: the record exists, and the job node is terminal with this `launch`, or absent, or carries another `launch`. In the absent or superseded case, `meta/orphans/<id>/outputs/<launch>` must already hold the record's stream mapping. A non-terminal job with this `launch` is refused `unsettled`. An absent record completes as done with nothing appended.
- **Descriptor check,** for every record that installs a result reference (call results, job stream references, `job output` snapshots, resume's synthetic results): the record is refused `descriptors missing`, listing the handles, unless every referenced handle has its descriptor under `results/` at the queue head. `applyGuarded` scans the record's value for references itself, so no caller can skip it.
- **Retry:** on `descriptors missing` the caller registers the listed descriptors again (`recordResult`, idempotent) and retries the same record under the same guard. `stale` ends the retries. A rewind that keeps the owner but drops a descriptor therefore delays a reference; it never installs an unknown handle.

### Block-anchor contract

- `read` renders `N:TEXT` lines; the first line of every 16-line block, aligned at line 1, renders `N#HHHH:TEXT`.
- `HHHH` is xxHash32 with seed 0 over the block's text, keeping the low 16 bits as 4 uppercase hex digits. The text is the block's lines with a leading BOM removed (byte 0 of the file only), CRLF and CR read as line ends, trailing spaces, tabs and CRs stripped from each line, joined with `\n`. Line numbers are not hashed.
- `edit` names the anchor of every block it touches and is rejected whole when any named block no longer hashes the same or a touched block is unnamed. Nothing is remapped or kept in a side store.
- The hash and normalization follow oh-my-pi's hashline at `d94bdfa1bb25e50cf90fb57fefb1863e5aef86fc`, applied per block instead of per file. The block size, the hash and the hash width are a contract with the model's habits and with change 5's prompts: changing any of them is a tool version bump.

## Consequences

- Changes 4 and 5 address calls by key and processes by job id, and never by PID.
- Moving these paths later needs a journal migration under ADR 0008's rule. M1 sessions are development data, so such a migration would be small.
- `meta/orphans` grows with rewinds times live jobs. It stays small beside `body`; compaction is M2.
- A 16-bit block hash collides on a real change with probability 1/65,536 per changed block. This is accepted as upstream accepts it per file; an observed collision in dogfood would move the anchor to 6 hex digits as a tool version bump.
