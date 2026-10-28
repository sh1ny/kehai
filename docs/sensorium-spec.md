# Sensorium Spec — Agent Perception Layer for the Dart Coding Harness

Oct 28, 2026 · @Nikolay Bochev

## Purpose and principles

The sensorium is the layer of the harness that decides what the agent perceives each turn, instead of leaving perception to whatever tool calls the model happens to make. Today a coding agent spends its first 5–10 calls rediscovering state the harness already knows (VCS status, failing tests, diagnostics, what the last turn changed). The sensorium hands that over as structured input and keeps it current.

Design principles:

1. **Push state, don't make the agent pull it.** Anything the harness can know cheaply is delivered before the first token of the turn.
2. **Deltas over dumps.** After turn 1 the agent sees what changed since its last observation, not the whole world again.
3. **Never lie by omission.** Every truncation, failure or stale value is marked as such. Silent cuts are the single worst failure mode.
4. **Agent-owned memory is sacred.** The scratchpad is never summarized, rewritten or dropped by compaction.
5. **Hard token ceiling.** The whole sensorium block fits a fixed budget (default 1,500 tokens, configurable); anything over is folded, never spilled.
6. **Model-agnostic.** Plain text with light structure. No provider-specific features (no cache-control hints, no system-prompt tricks) required to work, though they can be used to make it cheaper.
7. **Visible to the user.** The user can open the current sensorium in the TUI (`/sense`) and see exactly what the agent sees. No hidden channel.

8) **One tree, no side stores.** Every piece of session state — messages, tool calls in flight, scratchpad, checkpoints, jobs, collector cache — is a node in one session tree. The sensorium is a *projection* of that tree, never a store beside it. (Added after reading Stencil's omp² postmortem; see §Session model.)

## Session model

The sensorium is only correct if rewind, fork and resume are correct, and those are only correct when there is exactly one source of truth. Pi's journal covered the message tree alone; everything else lived in closures and custom entries, and Stencil counted \~15 lifecycle bugs and found 15 of 17 stateful official extensions broken on rewind or resume. We start from the other end.

**The tree.** A session is one tree, persisted as an append-only journal of property patches (not snapshots). Materializing the tree at any journal point gives the full session. Top-level children:

| Subtree | Holds | Lifetime |
| --- | --- | --- |
| `meta` | model, settings overrides, loaded plugins, tool roster, AGENTS.md hash, project memory pointer | session |
| `body` | the live turn chain: user messages, assistant messages, tool calls with `status`, `input`, `result`, `diag`, `usage` | per turn |
| `scratch` | scratchpad entries, each anchored to the turn that wrote it | until deleted or rewound past |
| `checkpoints` | label, jj op id, turn | session |
| `jobs` | every backgroundable thing (shell, subagent, daemon, over-budget call) as one stdio-shaped job with a signal handle | until exit or rewound past |
| `collectors` | last-known value + timestamp per collector | cache, rebuildable |

**Rewind is a tree diff.** Rewinding to turn N removes every node anchored after N. A removed `jobs` node kills the process; a removed `scratch` entry disappears from the next snapshot; a removed `checkpoints` node is forgotten. No feature gets its own rewind code path. Fork copies the tree at a point; resume materializes it. The tool that writes a scratchpad entry does not know rewind exists.

**Projections.** The sensorium block, the TUI transcript, a Kumiko view, the RPC stream and the test harness are all actors subscribed to the patch stream, rendering the same tree. None of them hold state the tree doesn't. Inspecting a subagent means pointing a view at its subtree.

**Tool calls are state streams.** A call is a node with `status` (`pending` → `running` → `settled` | `cancelled` | `failed`), a `version`, and children `input`, `result`, `diag`, `usage`. Streaming output mutates `result`; a warning adds a `diag` child; settling freezes the final diff. The delta footer (§Diagnostics delta) is just the `diag` child rendered. Every tool is versioned so traces stay comparable across releases.

**Central truncation.** Tools never truncate. The full result lands in the result store and the `result` node carries a handle; the composer that renders the tree *for the model* applies the size cap, once, with the explicit truncation line. `notrunc` is a per-call opt-out. The TUI renders from the same node and can show more than the model sees.

**One job model.** `bash` in background, a subagent, a dev server, a plugin process, a tool that exceeded its blocking budget: all `jobs` nodes with the same shape (`cmd`, `state`, `started`, `signal`, `stdout` handle, `stderr` handle). One blocking budget, enforced in one place. Two agents in one directory can share a job.

## Delivery model

The sensorium is injected as the **last user-role message content before the model's turn**, not into the system prompt. The system prompt stays stable so provider prompt caching works; the sensorium changes every turn and would bust the cache if it lived there.

Turn sequence:

1. User submits a message (or a tool loop continues).
2. Harness runs the **collectors** in parallel (VCS, diagnostics, tests, processes, budget). Each has a hard timeout (default 300 ms); a collector that misses its deadline reports `stale` with the last known value rather than blocking the turn.
3. The **composer** merges collector output into one block, applies the token budget (folding rules in §Example rendering), and prepends it to the pending user content as a fenced `<sensorium>` block.
4. The model responds. Tool calls execute. After each tool call that mutates the workspace (edit, write, bash), the **delta collectors** run again and their output is appended to that tool's result (§Diagnostics delta).
5. At the next model turn the full block is recomputed; the previous one is **removed from history** so only one sensorium exists in context at a time. The agent's reasoning about it stays; the snapshot itself doesn't accumulate.

Two modes:

| Mode | When | Content |
| --- | --- | --- |
| `full` | First turn of a session, after compaction, after `/sense refresh`, or when the delta would be larger than the full block | Everything in §Snapshot schema |
| `delta` | Every other turn | Only fields whose value changed since the last `full`, plus the always-present header (turn, budget, scratchpad pointer) |

The sensorium is **read-only to the model** except for the scratchpad and checkpoint sections, which the agent writes through dedicated tools (`scratch_set`, `scratch_del`, `checkpoint`). Everything else is observed, never asserted by the agent.

Collectors are plugins. The core ships `vcs`, `diagnostics`, `tests`, `processes`, `budget`, `plan`. A plugin (out-of-process, NDJSON) can register additional collectors; each declares a name, a token ceiling, and a refresh trigger (`every_turn`, `on_mutation`, `on_demand`).

## The per-turn snapshot

The snapshot has a fixed section order so the model learns where to look. Sections are omitted entirely when empty in `delta` mode; in `full` mode an empty section shows as a single `none` line.

| Section | Collector | Fields | Token ceiling |
| --- | --- | --- | --- |
| `turn` | core | turn number, mode (`full`/`delta`), wall-clock time, cwd | 30 |
| `budget` | budget | context used / max, est. cost this session, turns since last compaction | 40 |
| `vcs` | vcs | backend (`jj`/`git`), current change id and description, parent, working-copy status (M/A/D counts + up to 12 paths), conflicted files, operation id (jj) or HEAD sha (git) | 250 |
| `changes_since_last_turn` | vcs | per file: path, +/- line counts, `by: agent` or `by: user` (user edits detected by mtime outside tool calls) | 200 |
| `diagnostics` | diagnostics | per LSP server: error count, warning count, up to 10 errors as `path:line: message` (truncated at 120 chars each) | 300 |
| `tests` | tests | last run: pass/fail/skip counts, when, up to 8 failing test names; `stale` flag if source changed since | 150 |
| `processes` | processes | every live jobs node: id, kind (shell/subagent/daemon/plugin), command (truncated), state, age, last 2 log lines | 150 |
| `plan` | plan | path of the active plan file, current step id and title, steps done / total | 60 |
| `scratch` | core | the agent's scratchpad, verbatim (§Scratchpad) | 400 (hard) |
| `checkpoints` | vcs | up to 5 most recent: id, label, age | 60 |
| `notices` | any | one-line facts the harness wants the agent to know: a collector timed out, a tool was disabled, the user edited files mid-turn, compaction happened | 80 |

Field rules:

- Paths are repo-relative. Never absolute.
- Counts always carry units (`12 files`, `3 errors`, `41k/200k tokens`).
- Timestamps are relative (`2m ago`, `turn 14`), never ISO strings; the model doesn't need the date, it needs recency.
- Anything cut by a ceiling ends with `… +N more` so the count is never hidden.
- A collector that failed reports `vcs: unavailable (jj not found)` rather than vanishing.

`changes_since_last_turn` with `by: user` is the field no current harness has and the one that prevents the most damage: the agent learns the user touched `lib/auth.dart` while it was thinking, and re-reads before editing instead of clobbering.

## Diagnostics and test delta

After every mutating tool call, the result the model receives ends with a `delta` footer computed by the harness. The agent never has to ask "did that break anything?" — the answer rides with the edit.

```text
[edit ok] lib/auth/session.dart  +14 -3  anchors verified
--- delta ---
diagnostics: +2 errors, -1 error
  + lib/auth/session.dart:41: The argument type 'String?' can't be assigned to 'String'
  + lib/auth/session.dart:58: Undefined name 'refreshToken'
  - lib/auth/login.dart:12: (resolved) Unused import
tests: not run since change (run `test` or enable watch)
vcs: working copy now M 3 files
```

Rules:

- **Settle window.** LSP diagnostics arrive asynchronously. The harness waits up to 800 ms (configurable per language) for the server to republish after a change, then reports what it has and marks `diagnostics: settling` if the server was still busy. A late result is folded into the next turn's `notices`.
- **Attribution.** Only diagnostics in files touched by this tool call, or whose error set changed, appear in the delta. Repo-wide counts live in the snapshot, not the footer.
- **Signed lines.** `+` introduced, `-` resolved. A diagnostic that merely moved line numbers is not reported.
- **Tests are opt-in to auto-run.** `tests.watch: true` in config runs the affected test files (by import graph where the language tooling supports it; otherwise the whole suite under a time cap) after each mutation and reports flips only: `tests: 1 newly failing (auth_test: refresh expired token), 2 newly passing`. Without watch, the footer says the results are stale.
- **Budget.** The footer is capped at 200 tokens. Overflow folds to counts with `… +N more; see /sense`.

The same delta mechanism feeds `changes_since_last_turn`: the harness keeps a per-file mtime + hash map, so edits by the user or an external tool between turns are detected and attributed to `user`.

Why this matters more than raw LSP access: giving the agent an `lsp_diagnostics` tool means it has to decide to call it, spend a turn, and remember to do so after every edit. Pushing the delta makes correctness checking free and constant.

## Tool result contract

Every tool result follows one envelope, so the model can trust the shape regardless of which tool ran.

```text
[<tool> <status>] <one-line summary>
<body>
[truncated: showing lines 1–400 of 2,310; handle r/7f3a; read_more(r/7f3a, from=401)]
--- delta ---            (only after mutating tools)
...
```

Status is one of `ok`, `error`, `partial`, `denied`, `timeout`. Errors carry the actual stderr or exception, not a paraphrase.

**Handles.** Every result is stored whole in the session's result store and the tool-call node carries a handle. Tools never truncate; the composer that renders the tree for the model applies the cap (default 8k tokens for `bash`, 400 lines for `read`), once, in one place. `notrunc: true` on a call opts out. The model can:

- `read_more(handle, from, lines)` — page through
- `search_result(handle, pattern)` — grep inside the stored output without re-running
- `summarize_result(handle)` — ask a cheap side model for a summary (optional, off by default)

Handles survive compaction: a compacted transcript keeps `[bash ok] ran test suite → r/7f3a (2,310 lines, 14 failures)`, and the agent can still page into it. Stored results expire with the session unless pinned.

**Truncation is always explicit** and always says three things: what range you got, how big the whole is, and how to get the rest. A result that fits in full carries no truncation line at all, so the absence of the line is meaningful.

**Head + tail for logs.** For `bash` output that overflows, the default cut is first 60% + last 40%, with a `[… 1,710 lines omitted …]` marker, because errors cluster at the end and context at the start.

**Structured where it's cheap.** `read` returns line-numbered text with hash anchors every N lines (Hashline-compatible), so edits can target by content. `grep`/`find` return `path:line: text` only. No JSON wrapping of plain text results; JSON is reserved for tools whose output is naturally structured (`lsp_references`, `test_results`, subagent returns).

**Typed subagent returns.** A subagent is launched with a return schema; its final answer is validated against it and delivered as JSON, with free-text reasoning available via a handle rather than inline. A subagent that fails to conform returns `partial` with the validation errors, never a prose blob the parent has to parse.

## Agent scratchpad

The scratchpad is a small key/value store the agent owns, rendered verbatim into every snapshot and **never touched by compaction**. Each entry is a node in the session tree's scratch subtree, anchored to the turn that wrote it, so rewinding past that turn removes it with no special handling. It exists because the things an agent loses when the transcript is summarized are exactly the things it most needs: decisions made, approaches ruled out, the user's exact wording of a constraint, where it was in a multi-step task.

Tools:

| Tool | Effect |
| --- | --- |
| `scratch_set(key, value)` | Create or overwrite. Value is plain text, max 80 tokens. |
| `scratch_del(key)` | Remove. |
| `scratch_pin(key)` | Mark as surviving session end, into the per-repo project memory (§below). |

Limits: 400 tokens total (hard), at most 20 keys. When a `scratch_set` would exceed the budget the call is refused with the current size, and the agent must drop or shorten something. The harness never trims it silently.

Conventions the system prompt suggests (not enforced):

```text
goal:       <one line, the user's words>
constraint: <things the user said not to do>
ruled_out:  <approach> because <reason>
decided:    <decision> (turn N)
next:       <the step after the current one>
flaky:      <test or command that fails intermittently>
```

Rendering in the snapshot:

```text
scratch (6 keys, 212/400 tok):
  goal:       migrate session store from sqlite to postgres, keep API identical
  constraint: user said no new deps besides postgres driver
  ruled_out:  dual-write shim — user rejected, too much surface (turn 4)
  decided:    schema in migrations/0007, not inline (turn 9)
  next:       port SessionRepo tests, then wire DI
  flaky:      test/integration/pool_test.dart times out under load
```

**Per-repo project memory** is the pinned subset plus harness-maintained facts, stored at `.harness/memory.md` in the repo (or `~/.harness/projects/<hash>/` when the repo must stay clean). It is loaded into the first `full` snapshot of every session under `memory:` and is plain Markdown the user can read and edit. Typical contents: build quirks, env vars needed, known flaky tests, the user's standing preferences for this repo. The harness adds nothing to it without the agent's `scratch_pin` or the user's explicit edit.

What the scratchpad is **not**: a plan file (that is `plan`, a separate section with its own file), a transcript, or a place for tool output. The 80-token value cap enforces this.

## Checkpoints via jj

Checkpoints give the agent cheap, named restore points it can roll back to itself. jj makes this nearly free: every mutation already lands in the operation log, and the working copy is a commit, so a checkpoint is a checkpoints node in the session tree holding a label and an operation id. Session rewind and workspace restore are therefore two separate operations the agent can combine: rewind the conversation without touching files, restore files without losing the conversation, or both.

Tools:

| Tool | jj behind it | Notes |
| --- | --- | --- |
| `checkpoint(label)` | `jj op log -n1` → store `(op_id, label, turn)` | Also auto-created before any tool call flagged `risky` (multi-file edit, `bash` matching a destructive pattern) |
| `restore(id)` | `jj op restore <op_id>` | Restores working copy *and* repo state; the agent's transcript is untouched, so it keeps what it learned |
| `diff_since(id)` | `jj diff --from <change at op>` | What changed since a checkpoint, as a unified diff via handle |
| `checkpoints()` | read store | Same list the snapshot shows |

Rules:

- A `restore` appends a `notices` line and forces the next snapshot to `full` mode, since the world just changed under the agent.
- Checkpoints created by the agent are visible to the user in the TUI (`/checkpoints`) and the user can restore too. Both parties see the same list.
- Auto-checkpoints are ring-buffered (default 20). Named ones persist for the session.
- The agent is told in the system prompt that a checkpoint costs nothing and that experimenting then restoring is preferred over reasoning about whether a change is safe. This is the behavioural payoff: fearless edits.

**git fallback.** In a git repo the harness uses a hidden ref namespace (`refs/harness/checkpoints/<id>`) pointing at a commit of the working tree plus index, created with a temporary index file so the user's staging area is untouched. `restore` checks that tree out. It works, but it is slower, cannot capture the operation history, and interacts badly with the user's own stash or rebase in progress. The spec treats jj as the first-class path and git as best-effort.

**Colocated repos.** Most jj users run `jj git init --colocate`; the harness detects `.jj/` first and uses jj even when `.git/` is present. The user can force a backend with `vcs.backend` in config.

The snapshot's `vcs` section always shows the current jj operation id. Combined with `restore`, this means the agent can cite exactly where it was: "before restore: op 7c1e; after: op 5a90".

## Budget and cost visibility

The agent sees its own resource position every turn, so it can trade depth for cost deliberately instead of blindly over- or under-reading.

```text
budget: 41k/200k ctx (20%) · turn 14 · $0.87 session · compaction at 160k · ~9 turns at current rate
```

Fields:

- **Context used / max**, with percentage. Computed from the provider's reported usage on the last response plus a local estimate for content added since.
- **Turns since compaction** and the **compaction threshold**, so the agent knows when its transcript is about to be summarized and can move anything important into the scratchpad first. The harness also emits a `notices` line two turns before threshold: `compaction in ~2 turns; pin what matters`.
- **Session cost** in the provider's currency, from the provider's token prices in the model registry; `~` prefix when prices are unknown (local models, LiteLLM routes without pricing metadata).
- **Rate projection**: turns remaining at the average tokens-per-turn of the last 5 turns. Rough on purpose.

The agent cannot change the budget, but the system prompt tells it how to respond: under 50% context, read generously; over 75%, prefer `search_result` over `read_more`, prefer handles over inline, and pin scratchpad entries. These are hints, not enforced policy.

The user sees the same numbers in the TUI status bar, so there is never a disagreement about what the session has cost.

## Example rendering and token budget

A `full` snapshot, mid-task, in a jj repo with Dart LSP running. This is roughly 420 tokens.

```text
<sensorium turn=14 mode=full>
budget: 41k/200k ctx (20%) · $0.87 · compaction at 160k · ~9 turns left
cwd: ~/src/harness   plan: .harness/plan.md step 3/7 "port SessionRepo tests"

vcs: jj @ kxqtm "wip: postgres session store" (parent: main) op 7c1e
  working copy: M 3  A 1  D 0
    M lib/session/repo.dart (+88 -41)
    M lib/session/pool.dart (+12 -2)
    M test/session/repo_test.dart (+30 -0)
    A migrations/0007_sessions.sql
  conflicts: none

changes_since_last_turn:
  lib/session/pool.dart  +12 -2   by: agent (turn 13)
  lib/auth/login.dart    +3 -3    by: user  ← re-read before editing

diagnostics: dart 2 errors, 5 warnings
  lib/session/repo.dart:41: The argument type 'String?' can't be assigned to 'String'
  lib/session/repo.dart:58: Undefined name 'refreshToken'

tests: last run turn 11 · stale (source changed) · 142 pass 3 fail 0 skip
  fail: SessionRepo.load returns null for expired
  fail: SessionRepo.save upserts
  fail: pool reuses connection

processes:
  p/1  docker compose up postgres   running 6m
    | postgres  | database system is ready to accept connections

scratch (6 keys, 212/400 tok):
  goal:       migrate session store from sqlite to postgres, keep API identical
  constraint: no new deps besides postgres driver
  ruled_out:  dual-write shim — user rejected (turn 4)
  decided:    schema in migrations/0007, not inline (turn 9)
  next:       port SessionRepo tests, then wire DI
  flaky:      test/integration/pool_test.dart times out under load

checkpoints: c3 "before repo rewrite" 4m · c2 auto 9m · c1 "session start" 22m
notices: none
</sensorium>
```

The same turn in `delta` mode would be about 120 tokens: header, budget, `changes_since_last_turn`, the two new diagnostics, and the scratchpad (always present).

Folding order when the block exceeds its ceiling (default 1,500 tokens), applied until it fits:

1. `processes` log lines → counts only
2. `vcs` file list → counts only
3. `diagnostics` → first 3 + `… +N more`
4. `tests` failing names → count only
5. `changes_since_last_turn` → paths only, no line counts
6. `checkpoints` → most recent only

`scratch`, `budget`, `turn` and `notices` are never folded. If they alone exceed the ceiling, that is a configuration error the harness reports to the user.

The tag is XML-ish for one reason: every current frontier model treats angle-bracket tags as reliable section boundaries, and it is trivial for the harness to strip the previous turn's block from history by matching it.

## v1 cut and open questions

Three decisions are locked before any code, because they are cheap now and ruinous to retrofit: **one session tree** (§Session model), **central truncation**, **one job model**. Everything below builds on them. Ship in three slices, each independently useful.

| Slice | Includes | Why first |
| --- | --- | --- |
| **v0 — skeleton** | Session tree + patch journal, materialize/rewind/fork/resume, result store with handles, central truncation, `jobs` model, RPC patch stream. No TUI yet: a test harness and a dumb line client. | This is the part that can't be retrofitted. Validate rewind correctness with property tests before a single UI line exists. |
| **v1 — observe** | nocterm client as a projection, `turn`, `budget`, `vcs` (jj + git), `changes_since_last_turn`, scratchpad as tree nodes, tool-result envelope | Pure Dart, no LSP; already better than any shipping harness on silent truncation and lost context |
| **v2 — react** | `diagnostics` collector + `diag` children + delta footer, checkpoints, `notices`, speculative compaction (start \~10% before limit from a journal snapshot, splice if still valid), `dyn`-style long-tail tool discovery inside bash so the permanent roster stays fixed | Needs the LSP client and PTY work the harness needs anyway |
| **v3 — learn** | `tests` watch with import-graph targeting, per-repo project memory, plugin collectors, typed subagent returns, renderer profiling pass on 5k-line transcripts | Depends on plugin protocol and subagent design settling |

Open questions, to settle before v1 code:

- [ ] **Where exactly does the block go for providers that cache by prefix?** Last user message is cache-neutral for Anthropic and OpenAI; verify Gemini and Bedrock behave the same.
- [ ] **Does stripping the previous snapshot from history confuse models?** Model each history entry as a fold `fn(entry, req) -> req` (the UI keeps full history, the request gets the folded view) so the experiment is a one-line change either way. Needs an A/B on a task set.
- [ ] **Patch journal format.** Property patches over a tree — own format vs. JSON Patch (RFC 6902) vs. something CRDT-shaped for the later collab story. Lean: own minimal format now, keep patches small enough that migration is a script.
- [ ] **Rewind semantics for jobs with side effects.** Removing a `jobs` node kills the process; it does not un-write files. Document that session rewind and workspace restore are separate and that the TUI offers "rewind both" as the default.
- [ ] **`by: user` detection on Windows.** mtime resolution and watchers differ; hash-on-turn-boundary is slower on large repos. Decide: `package:watcher` vs. hash vs. both.
- [ ] **Scratchpad size.** 400 tokens is a guess. Instrument real sessions and tune.
- [ ] **Should the user be able to write to the scratchpad?** Lean: yes, entries show `by: user`.
- [ ] **Auto-checkpoint `risky` heuristics.** Short configurable denylist, log every trigger.
- [ ] **Shell: real PTY vs. in-process interpreter.** Stencil wrote an in-process bash with coreutils to get Windows-without-WSL and capability-at-write approval. That is a very large build; v1 uses a real shell and PTY, with the in-process interpreter as a v3+ option only if Windows adoption demands it.
- [ ] **Renderer budget.** Decide an explicit target now (e.g. full redraw of a 5k-line transcript under 16 ms, streaming append under 1 ms) and test nocterm against it in week one. If it fails, the fallback is a custom one-pass renderer under nocterm's component model, not a framework swap.
- [ ] **Name.** `sensorium` is accurate but unusual. Keep it for the spec; decide the user-facing name with the TUI.
