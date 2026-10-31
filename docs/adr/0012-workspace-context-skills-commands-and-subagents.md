# ADR 0012: Workspace context, skills, commands and child-engine subagents

Status: accepted
Accepted: 2026-10-31
Date: 2026-10-31
Supersedes: none

## Context

[ADR 0006](0006-subscription-auth-workflow-and-process-boundaries.md) puts the project's workflow (skills, `AGENTS.md`, commands, typed roles) inside Kehai and keeps repository text from becoming policy. The `skills-agents-commands` change builds that workflow layer ([design](../../openspec/changes/skills-agents-commands/design.md), D3, D4, D7, D8, D9, D11 and D15). Its tree fields, its precedence rule and the parent-child protocol are read by later changes and by every client, so they are recorded here. Everything is additive to [ADR 0010](0010-tool-call-and-job-tree-layout.md) and [ADR 0011](0011-conversation-tree-layout-and-rpc-protocol-v1.md); the journal format stays v1 ([ADR 0008](0008-journal-format-v1.md)).

## Decision

### Workspace context keyed by content: `body/contexts/<key>`

- At exchange start, after admission and before the first step, the engine loads the workspace (applicable `AGENTS.md` files, skill catalog and, in a child, its role) and renders the context text. `key = sha256(text)[0:16]`.
- If `body/contexts/<key>` is absent, one `set` stores `{text, files: [{path, bytes, truncated}], skills, problems}`. The exchange's `merge` then records `context: <key>`. Both carry the exchange's turn.
- Requests are built from the exchange's stored context, never from the files, so they are rebuildable and byte-identical (cache-stable) while the content is unchanged.
- The context lives under `body`, not `meta`: a rewind removes a context only together with the first exchange that stored it, and every exchange sharing its key is later, so no live exchange loses its context. Exchanges written before this ADR have no `context` and are never rebuilt with the new instructions.
- Each step records `instructions: {version, context, role}`. A completed step's usage is a budget baseline only for a request with the same triple.

### Discovery and precedence

- The project root is the nearest directory upward from the workspace holding `.git` or `.jj`, else the workspace.
- Skills come from `.claude/skills/` then `.agents/skills/`. On a name clash the `.claude` copy wins and the other is reported as shadowed. Commands come from `.claude/commands/**/*.md` (`opsx/propose.md` is `opsx:propose`) and win over a same-name skill for `/` use. Roles come from `.claude/agents/*.md`.

### Command expansion at submit: the exchange `command` field

- `submit` checks the request id first; a known id returns its recorded outcome, unexpanded.
- For a new id, a leading `/name args` is expanded before admission. Unknown or not user-invocable names are refused with no record; `//` sends the text with one slash removed.
- The admitted exchange's `merge` records `command: {name, args, source, sha256}`, and the user item holds the expanded text. The fingerprint stays over the typed text. Expansion lives in the engine, so every client shares it.

### Subagents are child engines over RPC protocol v1

- An `agent` call starts a supervisor job of kind `agent` whose process is the same `kehai` run as `rpc --child --parent <session dir> --job <id> --role <name> --role-digest <sha256> --model <slug> [--yolo]`. `--resume` and `--session` are refused in child mode.
- The child session lives under `<parent session dir>/agents/<child session id>/` with `meta/lineage = {parent: <session>, job: <id>}`. A role file whose digest differs from `--role-digest` is `fatal role changed`. The role's name, digest and body are part of the child's captured context.
- The parent is a complete RPC v1 client of the child: it keeps a mirror of the child tree that every `snapshot` replaces and every `update` advances, and decides the end only from the mirror. Output lines are buffered up to 64 MiB.
- Child prompts are relayed into the parent's prompt FIFO with key `<job id>.<child key>` and an `agent: {role, job}` field; answers go back with the child key. A relayed prompt is withdrawn by the child, by the job's cancellation or by its end.
- The job's stdin stays open as the protocol channel; stdout is spooled before it is acted on. Cancellation and the deadline soft-stop the child (`interrupt`, then stdin closed, up to 5 s) before the supervisor's termination.
- The typed result is a fourth stream of agent jobs, `result`, carried through the crash-safe handoff like `stdout`, `stderr` and `output`. The intent's `streams` and `outcome` hold it and the terminal `agent` fields. Before the intent, recovery never adopts `result`; a surviving `result` spool is deleted and counted as `discarded`, and the job settles `cancelled`/`interrupted` without relaunching the child.

### Automatic reads stay inside the project

Every file the engine opens without a tool call (`AGENTS.md`, `SKILL.md`, command and role files) is resolved through links and junctions, must lie inside the resolved project root and must not be a Kehai credential file. Otherwise nothing is read and a problem is recorded. Discovery applies the same check to skill and command directories.

### Repository frontmatter never widens approval

`allowed-tools`, a role's `tools` and every other frontmatter key never autoapprove anything. A role's `tools` only narrows a child's roster. The child's gate is built from the user's configuration, and `--yolo` is passed only when the parent runs with it.

## Consequences

- Later changes address workspace context by key and commands by the exchange `command` field. Moving them needs a journal migration under ADR 0008.
- Context copies grow with distinct content (one per edit of an instruction file). This is visible in session size; dedupe across keys is not built.
- Child sessions are kept beside the parent session and never deleted automatically.
- A change to the child command line or lineage form must keep older child sessions readable.
