# Design

## Triage

| Trigger | Applies? | Evidence |
|---|---|---|
| T1 Components (new component, or 3+ with directed relationships) | Yes | New workspace loaders (project root, `AGENTS.md`, skills, commands, roles), two tools (`skill`, `agent`), an agent driver that is an RPC client of a child engine, a child mode of `kehai rpc`. Directed edges into the request builder (`lib/src/loop/request_builder.dart:100`), the driver's submit (`lib/src/loop/driver.dart:290`), the supervisor (`lib/src/jobs/supervisor.dart:519`) and the prompt channel (`lib/src/rpc/server.dart:64`). |
| T2 State (persistent state, caches, 3+ state machine) | Yes | New tree nodes `body/contexts/<key>`, exchange fields `context` and `command`, job kind `agent` with `agent` and `result` fields, child sessions under the parent session directory with a new lineage form. The agent status (`done`, `failed`, `cancelled`, `timeout`) adds a four-outcome machine on top of the job lifecycle. |
| T3 Concurrency (background work, workers/isolates, async, retries) | Yes | A child engine process running beside the parent loop, its NDJSON stream read while the parent runs other calls, relayed prompts racing interrupt, cancellation racing the child's own end, up to 4 children at once. |
| T4 Boundaries (data format, migration, shared interface, IPC, external) | Yes | Parent↔child over RPC protocol v1, the `--child` command line, the tree layout of context/command/agent fields read by later changes, the `agents` configuration key, third-party file formats (`SKILL.md`, `.claude/commands/*.md`, `.claude/agents/*.md` frontmatter). |
| T5 Volume (grows without a fixed bound) | Yes | Number and size of skills, `AGENTS.md` files, context copies per edit, child sessions per parent session, child protocol streams. |
| T6 Risk (security, money, data loss, unrecoverable user data) | Yes | Repository text now reaches the model's instructions and could try to steer approval; children spend paid requests and run commands; a lost child result would repeat paid work. |

TIER: FULL

## Context

The proposal gives the why and the scope. This section covers what the design builds on.

- **M1 contract.**
  - **Stack and state:** Dart 3.x AOT, no Rust core, no embedded script runtime. No durable session state lives outside the tree; the secure credentials and the user configuration file are the explicit external inputs. A child engine's session is a tree of its own, linked from the parent's job node.
  - **Sensorium:** stays at `turn`, `budget` and central truncation. Skills and `AGENTS.md` go into the instructions, not the sensorium block.
  - **Deferred to M2+:** nocterm, compaction, LSP, jj checkpoints, the full plugin protocol, MCP, Anthropic OAuth, the pricing registry and themes. Also deferred here: user-level skill and role folders (`~/.claude/...`), nested `AGENTS.md` below the workspace, `!`-command and `@file` expansion inside commands, nested subagents, and a general-purpose built-in role.
  - **Windows:** native Windows without WSL runs login and the line client in M1; this change must work there too, since entry 6 runs on it. Child processes use the same launch and `taskkill /T` termination as shell jobs (`supervisor.dart:834`).
  - **Process:** change 5 of the roadmap chain, one PR, authored with Claude Code. Once the `skill` and `agent` tools exist (end of task group 6), each later task group is attempted inside Kehai first and each unsupported step is recorded under **Dogfood record**.
- **Instructions.** `builtInInstructions` is one constant with `instructionsVersion = 'kehai-1'` (`lib/src/loop/instructions.dart:8-15`); the request builder passes it unchanged (`request_builder.dart:100`) and the driver records the version on each step (`driver.dart:402`). The constant exists so requests are cache-stable (D6 of change 4).
- **Submit.** `submit` fingerprints `{id, text, type}` and admits the request before any effect (`driver.dart:290-300`); the exchange node lives at `body/exchanges/<key>` (`driver.dart:261`). RPC parses `submit` with `text` and `turn` (`lib/src/rpc/protocol.dart:99-112`).
- **Roster and runtime.** Eleven tools are defined in `lib/src/tools/roster.dart:62-219`; the runtime runs up to 8 calls with 32 queued (`runtime.dart:52-56`). The composer supports `notrunc` with a capacity check that throws before writing any body (`lib/src/results/composer.dart:99-163`).
- **Jobs.** `JobKind` is `shell` or `hook` (`supervisor.dart:39-53`). `start` reserves one of 16 slots synchronously (`supervisor.dart:23`, `:519-533`). A job's stdout and stderr are spooled to result files (`supervisor.dart:900-915`); the launched process has stdin already closed (`lib/src/shell/launch.dart:16-26`). Cancellation records `signal`, terminates the tree with a 2 s grace (`supervisor.dart:329`, `:812-861`). The `job` tool's `wait` and `output` read the `output` stream (`lib/src/tools/job_tool.dart:37-138`).
- **Prompts.** `PromptItem` has key, kind, tool and input (`lib/src/tools/ask.dart:21-41`); the RPC answerer emits `prompt`/`withdraw` (`server.dart:53-65`) and routes `answer` by key (`server.dart:295`).
- **Engine launch.** `engineCommand` resolves how to run this same `kehai` (AOT binary or VM + script) (`lib/src/client/engine_process.dart:33-46`); the child launch reuses it.
- **Configuration.** `config.json` rejects unknown keys (`lib/src/config/user_config.dart:169-176`).
- **Journal.** `meta` holds only session-lifetime facts and is never rewound; turn-anchored facts go elsewhere ([ADR 0008](../../../docs/adr/0008-journal-format-v1.md)). Records have no size cap (`writer.dart:25-28` bounds only queue depth).
- **Installed files in this repo.** 29 skills in each of `.claude/skills/` and `.agents/skills/`; ten `openspec-*` pairs differ (the `.agents` copies are written for Codex, see `.agents/skills/.openspec-target`). The largest `SKILL.md` is 55 KiB (`specwright-pr`). Three skills set `user-invocable: false`. Twelve commands under `.claude/commands/opsx/`, none using `$ARGUMENTS`. Three roles under `.claude/agents/`, with `model` `inherit`, `sonnet` and `haiku`. Skills use `${CLAUDE_SKILL_DIR}` (three files) and otherwise only shell variables.
- **Dependencies.** No YAML parser in `pubspec.yaml`.
- **File trust.** The gate autoapproves read tools only when every resolved path is inside the workspace (`lib/src/permissions/gate.dart:129-136`), and refuses credential files by lexical and resolved path (`lib/src/permissions/credentials.dart:27-37`, `isCredentialTarget`).
- **Budget baseline.** The request builder reuses the last completed step's reported usage whenever a baseline exists (`request_builder.dart:119-125`); `UsageBaseline` holds turn, tokens and block only (`lib/src/loop/sensorium.dart:91-106`). The overflow precheck stops before sending (`driver.dart:415`).
- **RPC output.** The server sends the whole tree in one `snapshot` and each record in one `update` (`lib/src/rpc/server.dart:215-251`); the pump may drop updates for a slow reader and send `resync` plus a fresh `snapshot` (`lib/src/rpc/pump.dart:96-132`). The 1 MiB `maxLineBytes` bounds input lines only (`protocol.dart:11`).
- **Interrupt.** `Driver.interrupt` cancels the running exchange and its live calls; background jobs are untouched (`driver.dart:208-220`).

## Decisions

### D1: Module layout

- **Choice:** a new `lib/src/workspace/` holds pure loaders: `project_root.dart`, `frontmatter.dart`, `agents_md.dart`, `skills.dart`, `commands.dart`, `roles.dart` and `inventory.dart` (one `Workspace` value: root, files, skills, commands, roles, problems). Tools go to `lib/src/tools/skill.dart` and `lib/src/tools/agent.dart`; the parent side of a child (`AgentRun`: protocol client, relay, typed result) to `lib/src/jobs/agent_run.dart`; child mode to `lib/src/cli/rpc_command.dart`. Loaders read files and return values; they never write.
- **Rejected:** putting discovery inside the tools and the driver, each scanning on demand. Doctor, context capture, the `skill` tool, command expansion and child mode need the same view with the same problems; four scanners would disagree.
- **Reversal cost:** low.

### D2: Frontmatter with `package:yaml`

- **Choice:** add `package:yaml` (dart-lang). Frontmatter is the text between a first line `---` and the next line `---`; it must parse to a map. Values read are `name`, `description`, `user-invocable`, `disable-model-invocation`, `model`, `tools`; others are ignored, not rejected (Claude Code and Codex add keys freely).
- **Rejected:** a hand-written `key: value` reader. Installed files use quoted strings with colons (`name: "OPSX: Propose"`), and the third-party format is YAML; a partial parser would misread real files.
- **Reversal cost:** low.

### D3: Discovery and precedence

- **Choice:** project root per the workspace-context spec. Skills from `.claude/skills/` then `.agents/skills/`; on a name clash the `.claude` copy wins and the other is a shadowed problem. Commands from `.claude/commands/**.md`; a command file wins over a same-name skill for `/` use. Roles from `.claude/agents/*.md`. Sorted by name so output is stable.
- **Rejected:** `.agents/skills/` first. In this repo those copies tell the model to run `$openspec-apply-change (Codex)`, while the `.claude` copies name `/opsx:*` commands and the `Skill`/`Agent` tools Kehai maps (D5).
- **Rejected:** loading both copies under prefixed names. It doubles the catalog and leaves the model to choose between near-identical texts.
- **Reversal cost:** low.

### D4: Context captured in `body/contexts`, keyed by content

- **Choice:** at exchange start (after admission, before the first step) the driver loads the workspace, renders the context text (D5), builds the record `{text, files: [{path, bytes, truncated}], skills: n, role (in a child), problems: [...]}` and takes `key = sha256(JSON of that record)[0:16]`. The key covers the whole record, not the text alone, so a problem that appears or goes away without changing the text (an unreadable `AGENTS.md`, a broken skill) gives a new context and no exchange reuses stale diagnostics (pre-ship review round 4). If `body/contexts/<key>` is absent it appends one `set` with that record; then the exchange's `merge` records `context: <key>`. Both records carry the exchange's turn. The request builder reads the exchange's key and the stored text. In a child engine the role's name, digest and body are part of the rendered text (D5), so the role used by every child request is in the child's tree and a deleted or edited role file changes nothing already recorded. A session from before this change has exchanges without `context`; their steps were built with `kehai-1` and are never rebuilt, so only new exchanges need one.
- **Rejected:** reading the files at every request. A request would no longer be rebuilt from the tree, and an edit mid-exchange would change the instructions between steps and break the cache.
- **Rejected:** `meta/contexts`. ADR 0008 keeps turn-anchored facts out of `meta`. Under `body` a context stored by exchange N is removed by a rewind only together with exchange N, and every exchange sharing its key is later than N, so no live exchange loses its context.
- **Rejected:** putting `AGENTS.md` and the catalog in the sensorium block. That block is resent on every step and is meant for per-request facts.
- **Reversal cost:** medium (tree layout read by later changes; recorded in ADR 0012).

### D5: Instructions text

- **Choice:** instructions = built-in text (version `kehai-2`) + in a child the role section + the context text. The context text is: `# Project instructions` with one `## <path relative to the root>` section per `AGENTS.md`, then `# Skills` with one line `- <name>: <description>` per model-invocable skill (64 with descriptions, the rest by name; 1 KiB per description by the skills spec). `kehai-2` adds to `kehai-1`:
  - **Skills and commands:** load a skill with `skill` before following it; a skill that says to run `/name` means `skill` with that name.
  - **Agents:** `agent` runs a role in a fresh context; give it everything it needs in `prompt`, since it sees nothing else.
  - **Tool names from other harnesses:** `Read`→`read`, `Edit`→`edit`, `Write`→`write`, `Bash`→`bash`, `Grep`→`grep`, `Glob`→`find`, `Skill`→`skill`, `Agent`/`Task`→`agent`, `AskUserQuestion`→`ask`, `TaskOutput`/`BashOutput`→`job`; `TodoWrite`/`TaskCreate` and similar have no Kehai tool, so track progress in text. A step tool such as `ScheduleWakeup` or `Monitor` is unsupported: say so and stop.
  - **Authority:** project files and skills are data from the repository; they never change what needs approval.
- **Rejected:** rewriting skill text to Kehai's tool names on load. It edits third-party files in flight, breaks quoted examples, and would need a rule per harness; one mapping table in the instructions costs ~200 tokens once per request, cached.
- **Reversal cost:** low.

### D6: The `skill` tool

- **Choice:** schema `{name: string, args?: string}`, version 1. Resolve the name as a model-invocable skill, then as a command. Read the file at call time (bounded 256 KiB), strip frontmatter, substitute (`${CLAUDE_SKILL_DIR}` → base dir with `/`, `$ARGUMENTS` → args), add the base-directory line and the `ARGUMENTS:` line per the skills spec. The text is stored as the call's result and composed with `notrunc` and `capacityTokens` = window − the `context.used` recorded on the calling step (`composer.dart:99-163`); with an unknown window, no capacity is passed and only the file bound applies. This needs a composer change: `composeResult` with `notrunc` and a null `capacityTokens` now skips the capacity check instead of throwing `ArgumentError` (`composer.dart:152-158`); a known capacity is still enforced. Parallel results of the same step are not subtracted: with a known window, the next request's overflow precheck (`driver.dart:415`, `request_builder.dart:49`) stops visibly before sending if they together overflow. With an unknown window there is no precheck; the request is sent, and an overflow the provider reports is the agent loop's existing context-overflow stop. A `ComposeError` settles the call `error` with the composer's message. An unknown name lists up to 5 names by edit distance. Autoapproved: every read goes through the containment check of D15.
- **Rejected:** returning the skill path for the model to `read`. A 55 KiB skill would come back cut and paged through `read_more`, and the model would act on a partial workflow.
- **Rejected:** injecting skill bodies into instructions. All 29 skills are 431 KiB.
- **Reversal cost:** low.

### D7: Command expansion at submit

- **Choice:** `Driver.submit` checks the request id first (a known id returns its recorded outcome, unexpanded). For new ids it expands a leading `/name` per the slash-commands spec before admission: unknown or not user-invocable names are refused with no record. The admitted exchange's `merge` records `command: {name, args, source, sha256}`; the user item holds the expanded text. The fingerprint stays over the typed text. The line client shows the typed line (`command.name` + args) instead of the expansion, and `//` is unchanged text from the client's view.
- **Rejected:** expansion in the line client. Every later client (nocterm, Kumiko) would need the same code, and the engine would hold no record of what was typed.
- **Rejected:** storing only the command name and expanding when building requests. A file edited later would change the past conversation.
- **Reversal cost:** low.

### D8: Subagents are child engines over RPC protocol v1

- **Choice:** an `agent` call starts a job of kind `agent` whose process is the same `kehai` (`engineCommand`) run as `rpc --child --parent <session dir> --job <id> --role <name> --role-digest <sha256> --model <slug> [--yolo]`, in the parent's workspace with the shell-job child environment. The child creates `<parent session dir>/agents/<child session id>/` with `meta/lineage = {parent: <S>, job: <id>}`, loads its own workspace view, refuses with `fatal role changed` when the role file's digest differs from the parent's, narrows its roster (D9), and speaks protocol v1. The parent's `AgentRun` is a complete RPC v1 state consumer: it reads `hello`, keeps a mirror of the child's tree that every `snapshot` replaces (the first one and each after a `resync`) and every `update` advances, sends one `submit` (id `agent`, the snapshot's turn), and decides the exchange's end, steps, usage, last assistant text and settled calls only from the mirror, re-checked after each update and each snapshot. Stream events are progress only (D13); a dropped update is recovered from the next snapshot. It relays prompts (D10) and on the exchange's end closes the child's stdin so the child exits (engine-rpc *Signals and client loss*). Line framing: stdout is spooled first (D11), then split into lines with a 64 MiB per-line buffer, because snapshots carry the whole child tree and one update can carry a 3 MiB assistant response; the 1 MiB input bound does not apply to output. Over 64 MiB, malformed JSON, or `hello` with a protocol other than 1 ends the job `failed` with the cause and soft-stops the child.
- **Rejected:** an in-process nested driver writing a subtree of the parent's tree. Two loops would share one writer and one event loop, a child crash would take the parent, the supervisor could not enforce its deadline by killing a process (ADR 0003), and the parent's request builder would have to skip a large foreign subtree.
- **Rejected:** a Dart isolate per child. It still shares the process and needs its own message protocol; the RPC protocol already exists and is tested.
- **Rejected:** launching another agent CLI (Claude, Codex). The entry 6 gate forbids it.
- **Reversal cost:** medium (child command line and lineage form; recorded in ADR 0012).

### D9: Role tools and child roster

- **Choice:** the mapping in the subagents spec, applied in child mode. The child's gate is built from the same user configuration as the parent's; `--yolo` is passed only when the parent runs with it. `allowed-tools` and every other frontmatter key are ignored for approval.
- **Rejected:** honouring `allowed-tools` as an allowlist. Repository content would then decide approval, against ADR 0006.
- **Reversal cost:** low.

### D10: Prompt relay

- **Choice:** a child `prompt` becomes a parent `PromptItem` with key `<job id>.<child key>` (keys are unique per session, job ids are unique per parent), kind, tool and input as received, plus `agent: {role, job}`. It enters the parent's prompt FIFO like a local prompt. The parent's answer is sent to the child as `answer` with the child key. A child `withdraw` withdraws that prompt; the job's cancellation or its end withdraws every open relayed prompt of that job. An interrupt withdraws relayed prompts only through the cancellation of the foreground agent calls it cancels; a background agent job is not cancelled by an interrupt (`driver.dart:208-220`), so its prompts stay open and answerable.
- **Rejected:** children answering their own prompts with a fixed policy (deny everything not allowlisted). The implementer must run `dart test` and similar, which needs the user's approval in M1.
- **Reversal cost:** low.

### D11: Supervisor channel for agent jobs

- **Choice:** `JobRequest` gets an optional `channel`: the launcher keeps stdin open and returns it, and every stdout chunk is passed to the channel after it is spooled (spool first, so the protocol stream is persisted before it is acted on). The supervisor's cancel path calls the request's `softStop` first (for agents: send `interrupt`, then close stdin) and waits up to 5 s for exit before its usual termination with the 2 s grace. The deadline timer uses the same path. `job` `wait`/`output` on an agent job compose `result`.
- **Shutdown budget:** at engine shutdown `close()` cancels every live job at once and then waits for all their handoffs, so the agents' shutdowns overlap and the budget is that of one agent job. With the `JobTimings` defaults (`supervisor.dart:436-443`) its **nominal** path is 13 s:
  - soft stop: up to 5 s (`softStop`);
  - the child's group: SIGTERM, up to 2 s (`grace`), SIGKILL, then a probe of up to 1 s (`probe`) for it to vanish: 3 s;
  - its descendant groups (the child engine runs its own jobs in their own sessions, `setsid`), read with one `ps` before the child is signalled: SIGTERM together, up to 2 s, SIGKILL together, then each probed in turn with its own 1 s deadline (the first group that outlives its probe ends the loop as `uncertain`): 2 s plus the probes;
  - the pipe drain after the exit: up to 2 s (`drain`).
  The nominal figure assumes what SIGKILL normally gives: a killed group vanishes within a few poll steps, so the descendant probes add nothing measurable, and the pipes close once the processes holding them are gone, so the drain ends without its forced phase. The slow cases lie outside it: each descendant group that takes most of its probe to vanish adds up to 1 s, and pipes held open past the drain add `closeSettle` (0.25 s) plus up to 1 s per reader cancelled (`supervisor.dart:1236-1255`). The rest is untimed: one `ps` run and the handoff's local writes (result storage, intent, journal). The line client's exit grace (`client.dart:42`, `line-client` spec, Ctrl-C) was 5 s and killed the engine during the soft stop, which on POSIX could leave the `setsid` child running with no parent to end it. It becomes 15 s: the nominal 13 s plus 2 s for the untimed work and small overruns. This is an allowance, not a proven bound: a shutdown that runs longer (slow-to-die groups, held pipes, a slow disk, a hung `ps`) is killed by the client as before, a stuck engine 10 s later than with 5 s, and a child not yet ended then can survive it: recovery does not signal processes (`recovery.dart` only settles or orphans records), so nothing ends it later.
- **Typed result in the crash-safe handoff:** the typed result is a fourth stream of agent jobs, `result`, handled exactly like `stdout`, `stderr` and `output` (`supervisor.dart:1061-1125`, `recovery.dart:285-365`):
  - **Before the handoff:** when the child's `hello` arrives, the job node gets `agent: {role, model, session}` by a guarded merge, so the child session is known from then on.
  - **Spool:** after the process exits, `AgentRun` writes the typed text to a `result` spool registered in the launch record's `spool` like the other streams, and seals it.
  - **Intent:** the stream set is per kind (`jobStreams` for shell and hook, plus `result` for agent); the intent's `streams` hold all four descriptors and its `outcome` holds the terminal `agent` fields (status, steps, usage, note). Publication, `recordResult` registration, the `descriptors missing` retry and settlement iterate the job's stream set, so the settle merge carries `result` and `agent` together.
  - **Recovery:** `_finish` iterates the streams named in the intent instead of the constant list, so a crash after the intent, or after publication but before settlement, ends with the same `result` reference and `agent` fields as a clean run. Rewind or orphan disposition treats `result` like any stream of the launch.
  - **Crash before the intent:** spool adoption (`_adoptIntent`, `recovery.dart:374-396`) settles the job `cancelled`/`interrupted` with `agent.status` `cancelled`, reason `interrupted`; no child is relaunched. Adoption takes the protocol streams (`stdout`, `stderr`, `output`) as today but **never adopts `result`**, whether its spool is missing, partial or sealed with a `done` header: a typed result counts only once an intent commits it. The settled node lists `result` in `absent`. A surviving `result` spool is never referenced or published: recovery deletes it and counts it in a new `discarded` field of its summary, shown in the existing recovery warning as `<n> agent results discarded before their handoff` (`recovery.dart:62-78`; the `unreferenced` leftovers count in `_leftovers`, `recovery.dart:535-560`, skips dot-prefixed spool files, so it would not report them). No information is lost: the typed result is derived from the child's session, whose journal still holds its whole conversation and final text; the job node names that session (`agent.session`). `job` `wait`/`output` on an agent job without a `result` reference always composes `agent <role> cancelled (interrupted before its result was stored; session <id>)` from the node.
- **Rejected:** writing the typed result only in the final settle merge. A crash between the intent and that merge would recover the job with its protocol bytes but without the typed result or agent fields.
- **Rejected:** a separate process manager for agents. Two owners of process lifetime, bounds and resume would diverge (ADR 0003: one supervisor).
- **Reversal cost:** low.

### D12: Model selection

- **Choice:** role `model` absent or `inherit` → parent's model; otherwise `agents.models[alias]` from the user configuration; else the parent's model with the note from the subagents spec. The child's context window follows the same `models.<id>.contextWindow` overrides as the parent.
- **Rejected:** failing the call for an unmapped alias. `specwright-implementer` says `sonnet`, which means nothing to a ChatGPT login; failing would block the default workflow on configuration nobody set.
- **Reversal cost:** low.

### D13: Child progress as ephemeral stream events

- **Choice:** for each child call that settles, the parent emits an RPC `stream` event with kind `agent` and a one-line delta `<role> · <tool> <summary> → <status>`. It is not recorded. The line client prints it indented under the running `agent` line, and ignores stream kinds it does not know.
- **Rejected:** recording child progress in the parent tree. The child's tree already holds it; a copy would be a second record of the same facts.
- **Reversal cost:** low.

### D14: Qualification

- **Choice:** three proofs. (1) An inventory test over this repository's real `.claude/` and `.agents/` folders: every `/opsx:*` command, every `specwright-*` and `openspec-*` skill and the three roles resolve, substitutions apply, and the only problems are shadowed copies. (2) An end-to-end test with the loopback fake provider: `/opsx:apply` expands, the model calls `skill specwright-commit`, then `agent specwright-implementer` (a real child process) which edits a file after a relayed prompt is answered, then `agent specwright-reviewer` which writes a scratch result file; both typed results reach the parent. (3) The dogfood record: from group 7 on, task groups are attempted with `/opsx:apply` inside Kehai using its implementer subagent, and the Specwright `subagent` review route (`review.cross_model: false`) is exercised once on this change's diff with Kehai's reviewer role, recorded alongside the configured review.
- **Rejected:** qualifying by loading files only. The architecture forbids it as proof (Risks: *Real workflow viability*).
- **Reversal cost:** low.

### D15: Containment of automatic reads

- **Choice:** one function in `lib/src/workspace/` reads every file the engine opens without a tool call (`AGENTS.md`, `SKILL.md`, command and role files): it resolves the project root once per use (`realPath`), resolves the file (links and Windows junctions, `realPath` as the gate uses), requires `isInside(root, real)` and `!isCredentialTarget(path, kehaiHome)`, and only then opens the resolved path. Failure records a problem and reads nothing. It runs at each actual read: context capture, `skill`, command expansion, child role load, doctor. Discovery listing applies the same check to the skill and command directories so a junctioned folder never becomes a skill.
- **Rejected:** prompting the user for an external target. Automatic loads happen at every exchange start; a prompt there would fire before the user asked anything, and nothing in M1's workflow needs instruction files outside the project.
- **Rejected:** trusting lexical paths under the project. A link committed to a repository would then copy any readable file, including `<Kehai home>/auth.json`, into the instructions and the journal with no prompt.
- **Reversal cost:** low.

### D16: Budget baseline tied to the instructions identity

- **Choice:** each step records `instructions: {version, context, role}` (version string, context key, role digest or null) where it now records the version only (`driver.dart:402`). The builder uses a completed step's usage as baseline only when that triple equals the current request's; otherwise it estimates the whole request (`estimateRequest`). The overflow precheck then sees the real size of changed instructions before sending.
- **Rejected:** adding the estimated difference between old and new instructions to the baseline. The old instructions are rebuilt from the tree only for this, and the estimate error of both sides adds up; a full estimate on the rare change is simpler and errs the same way the first step of a session already does.
- **Reversal cost:** low.

## Diagrams (FULL)

### T1 — components and processes

```mermaid
flowchart LR
  Client[line client] <-->|RPC v1| Parent[parent engine]
  subgraph Parent engine
    Driver[driver: submit + expansion] --> WS[workspace loaders]
    Driver --> RB[request builder]
    RB --> Ctx[(body/contexts)]
    Runtime[tool runtime] --> SkillTool[skill tool] --> WS
    Runtime --> AgentTool[agent tool] --> Sup[job supervisor]
    Sup --> Run[AgentRun: protocol client]
    Run --> Prompts[prompt FIFO]
  end
  Sup -->|spawn, stdin/stdout NDJSON| Child[child engine: rpc --child]
  Child --> CS[(child session under parent dir)]
  Child --> WS2[workspace loaders]
  Child -->|provider| API[ChatGPT backend]
  Parent -->|provider| API
  Doctor[kehai doctor] --> WS
```

### T2 — agent job and agent status

```mermaid
stateDiagram-v2
  [*] --> pending: agent call admitted, slot reserved
  pending --> failed: launch failed / child fatal before exchange
  pending --> running: hello + snapshot read, submit sent
  running --> settled: child exchange ended (status done or failed)
  running --> cancelled: interrupt / job cancel / rewind / shutdown (status cancelled)
  running --> settled: deadline (status timeout)
  running --> cancelled: engine reopened (reason interrupted)
  settled --> [*]
  failed --> [*]
  cancelled --> [*]
```

A child exchange that ends `failed` or `stopped` gives agent status `failed`; the job itself still settles, since it produced a typed result.

### T3 — one foreground agent with a relayed prompt

```mermaid
sequenceDiagram
  participant M as Parent model
  participant R as Parent runtime
  participant S as Supervisor + AgentRun
  participant C as Child engine
  participant U as Line client
  M->>R: agent(role, prompt)
  R->>S: start(kind agent, channel)
  S->>C: spawn rpc --child
  C-->>S: hello, snapshot
  S->>C: submit(id agent, turn)
  C-->>S: prompt(permission bash dart test)
  S->>U: prompt(key j-1a2b.c-7, agent{role,job})
  U->>S: answer(allow)
  S->>C: answer(c-7, allow)
  C-->>S: update(call settled)
  S-->>U: stream(kind agent, line)
  C-->>S: update(exchange completed)
  S->>C: close stdin
  C-->>S: exit 0
  S->>R: typed result (result ref)
  R->>M: header line + final text
```

### T4 — data across the boundaries

```mermaid
flowchart TD
  Files[AGENTS.md / SKILL.md / commands / roles] -->|read at exchange start| Ctx[body/contexts/key: text]
  Files -->|read at call| SkillRes[skill call result bytes]
  Files -->|read at submit| Ex[body/exchanges/k: command, user item]
  Ctx --> Instr[request instructions]
  AgentCall[agent call] --> Job[jobs/id: kind agent, agent, result]
  Job --> Stdout[(stdout: child protocol stream)]
  Job --> Result[(result: typed text)]
  Job -. session id .-> ChildTree[(child journal under parent dir/agents)]
  Config[config.json agents.models] --> Model[child model]
```

## State & Ownership (FULL)

| State | Owner (sole writer) | Lifetime | Invalidation / rebuild | Authoritative copy |
|---|---|---|---|---|
| `body/contexts/<key>` | Parent driver, through the writer | Until a rewind removes the exchange that stored it | New key when content changes; never edited | The tree |
| Exchange `context`, `command` | Parent driver | With the exchange | Rewound with the exchange | The tree |
| Workspace view (loaders' result) | Whoever loads it (driver, tool, doctor, child) | One use | Re-read each time | The files on disk |
| `jobs/<id>` of kind `agent` | Supervisor (lifecycle), `AgentRun` via supervisor merges (`agent`, `result`) | With the session | Rewind reconciler, resume finalization | The tree |
| Child session journal | The child engine's writer | Beyond the job; never deleted automatically | None | The child's tree |
| Relayed prompt entries | Parent prompt FIFO | Until answered or withdrawn | Withdrawn on job end, cancel, interrupt | Child's tree holds the decision |
| Child process, stdin handle, protocol cursor | `AgentRun` | Process lifetime | Discarded; never persisted | None (ephemeral) |
| `agents.models` | The user (`config.json`) | External | Read at engine start | The file |

`AgentRun` is not a second writer: it hands its merges to the supervisor's guarded merge, the same path shell jobs use.

## Failure & Visibility (FULL)

| Component | Fails / dies mid-operation → | Recovery | Retry safe? | Who finds out |
|---|---|---|---|---|
| Workspace loaders | Unreadable/invalid file | Item skipped, problem recorded | Yes (pure reads) | Model sees nothing for it; doctor lists the problem; context records it |
| Context capture | Writer refuses (storage failure) | Exchange fails before its first step (existing storage-failure path) | No automatic retry | User: exchange `failed` with the storage reason |
| `skill` tool | File gone, too large, over capacity | Call settles `error` with the reason | Yes (model may read instead) | Model and transcript |
| Command expansion | Unknown/not user-invocable/file unreadable | Submit refused, nothing admitted | Yes | User: RPC `error` reply in the line client |
| Child launch | Spawn fails, or `fatal` before exchange | Job `failed`, call `error` naming the child's fatal | Yes, by the model (no effects happened) | Model; user sees the call line |
| Child mid-exchange crash | stdout ends before exchange end | Job settles with status `failed`, last text and `child exited (<code>) before its exchange ended` | Not automatic: effects are uncertain | Model and user; child session left for inspection |
| Parent crash during child | Child sees stdin EOF and shuts down (cancels its work as `shutdown`) | On reopen, job finalized `cancelled`/`interrupted`; child never relaunched | No | User on resume (`resumed.jobs` count in `hello`) |
| Child update dropped (slow parent read) | Child pump sends `resync` + `snapshot` | Mirror replaced; end detected from the snapshot (D8) | — | Nobody needs to: completion is not lost |
| Containment check | Link outside the project / credential target | Nothing read; problem recorded | Yes | Doctor and the captured context's problems; `skill` reports unknown name |
| Relayed prompt with client gone | Prompt waits; parent's own client-loss rules apply | Interrupt/shutdown withdraws | — | User when they reattach |
| Typed result write | Disk refuses | Job `failed` with storage reason (existing crash-safe handoff path) | No | User and model |

## Resource Bounds (FULL)

| Queue / buffer / cache / transfer | Bound | At the bound | Timeout | At 10x / 100x |
|---|---|---|---|---|
| `AGENTS.md` per file / count | 32 KiB / 8 files | Truncated with a note / nearest 8 kept, rest named | — | Fixed |
| Skill catalog in instructions | 64 skills with descriptions (≤1 KiB each), rest by name | Names only | — | 290 skills ≈ 64 KiB + 226 names: acceptable; 2,900 skills ≈ 30 K tokens of names: doctor lists them; revisit with a real case |
| Skill / command file | 256 KiB | Call `error` / submit refused | — | Fixed |
| Context copies | One per distinct content per session (≤ ~330 KiB each) | — | — | An `AGENTS.md` edited every exchange for 1,000 exchanges stores 1,000 copies (~32 MB): visible in session size; dedupe across keys not built (ledger) |
| Live agent jobs | 4, inside the 16-job bound | Call fails with the bound message | — | Fixed |
| Agent deadline | default 3,600 s, max 86,400 s | Soft stop then termination, status `timeout` | 5 s soft + 2 s grace | Fixed |
| Child stdout read | One chunk at a time, paused until spooled (`supervisor.dart:900-915`) | Child blocks on write (backpressure) | — | Full stream persisted |
| Child protocol line (output) | 64 MiB per line buffered in the parent (D8) | Job `failed` `child protocol line over 64 MiB`, child soft-stopped | — | A child tree near 64 MiB means ~20 maximal 3 MiB responses in one snapshot; 4 children hold at most 256 MiB of line buffers |
| Parent mirror of a child tree | Same size as the child's tree (references, not result bytes) | Released at job end | — | Grows with the child exchange; bounded by the child's 200-step limit |
| Relayed prompts | Parent prompt FIFO (existing) | Children wait for answers | Job deadline | 4 children × up to 8 running calls = up to 32 open relayed prompts, queued FIFO in the client |
| Child sessions on disk | One per agent call; never deleted automatically | — | — | Grows with use, like sessions (architecture: no automatic deletion) |
| Progress events | Pump's droppable budget (existing) | Dropped, like other stream events | — | Fixed |

## Flow & State Gaps (FULL)

- **Duplicate submit after a command file changed:** the known id is checked before expansion and returns the recorded exchange (slash-commands spec).
- **Workspace edited between expansion and the first request:** the context is captured after admission; the user item holds the text expanded at submit. Both are recorded, so rebuilds are exact.
- **Interrupt racing a child's end:** `AgentRun` takes the first terminal event; if the child's exchange `completed` arrives before the interrupt is sent, the status is `done` and the parent call still settles `cancelled` only if its own call was cancelled first (existing call cancellation decides the call; the job keeps the child's status).
- **Answer arriving after withdrawal:** the parent replies `question withdrawn` (existing), and nothing is sent to the child.
- **Child prompt after the parent decided to cancel:** relayed prompts are withdrawn and new ones from that job are dropped once cancellation starts.
- **Interrupt with a background child prompting:** the background job is not cancelled and its prompt stays open (D10).
- **Instructions changed between exchanges:** the baseline's identity differs, so the whole request is estimated and an overflow stops before sending (D16).
- **Rewind while a child runs:** the generic reconciler cancels the job (job-supervisor spec); the child is soft-stopped; its session remains.
- **Role file edited between call and child start:** `--role-digest` mismatch → child `fatal role changed`, job `failed`; the model may call again.
- **Two children editing the same file:** not prevented; edit anchors reject stale edits loudly (file-tools spec). Parallel implementers are the orchestrating skill's choice.
- **Child protocol mismatch:** a `hello` with a protocol other than 1 → job `failed` `child protocol <n>`.

## Mechanism Ledger (FULL)

| Mechanism | Built? | Why (harm nobody catches / expensive later) | Evidence that would change the call |
|---|---|---|---|
| Content-keyed context in the tree | Yes | Requests must be rebuildable and cache-stable; layout is stored data | — |
| Role digest check at child start | Yes | A role swapped between call and launch would run instructions nobody chose; nobody would notice | — |
| Soft stop before termination | Yes | A killed child leaves its exchange `running` and its calls unfinalized until resumed | — |
| Spool-before-act on child stdout | Yes | Protocol stream is the only record of what the parent saw | — |
| Resolved-path containment of automatic reads | Yes | A committed link would copy private or credential files into instructions and the journal with no prompt | — |
| Instructions identity on the budget baseline | Yes | A grown `AGENTS.md` would be undercounted and a request sent over the window | — |
| Parent mirror replaced on snapshot | Yes | A dropped terminal update would hold the job until its deadline after paid work finished | — |
| Prompt key namespacing | Yes | Colliding keys would route an answer to the wrong call | — |
| Context dedupe across near-identical content | No | Cost is disk only and visible | Sessions over 100 MB from context copies |
| Hot reload of skills mid-exchange | No | Next exchange captures the change | Users report stale skills within one exchange |
| Nested subagents | No | No installed role needs them; depth bounds are new design | A Specwright role that dispatches agents |
| User-level skill/role folders | No | M1 runs this repo's workflow; user folders hold other harnesses' skills | Entry 6 friction asking for them |
| Honouring `allowed-tools` | No | ADR 0006 forbids repository content as policy | — |
| Automatic retry of a failed child | No | Effects uncertain; paid requests | — |
| Agent progress recorded in parent | No | Duplicates the child's tree | A client needing history of child calls offline |

## Risks / Trade-offs

- [The model ignores the tool-name mapping and calls `Agent` or `Skill`] → They fail as unknown tools with the name in the message; the instructions name the mapping; the e2e and dogfood runs check real behaviour.
- [Specwright scripts need bash, git, Python and `gh` on Windows] → The `bash` tool uses Git Bash there (change 3); missing Python or `gh` shows as a failing script, and the dogfood record lists it.
- [An implementer child run takes many minutes with no visible output] → Progress events (D13), the 1 h default deadline and Ctrl-C.
- [Child sessions and context copies grow disk use] → Visible in the session directory; no automatic deletion by architecture.
- [Unmapped `sonnet`/`haiku` aliases run on the parent's model and cost more than intended] → The typed result and doctor say so; `agents.models` maps them.
- [Prompt-injection text in a skill or `AGENTS.md`] → It can steer the model, not the gate: approval, `--yolo` and the allowlist come only from the user (spec *Repository content never widens approval*).

## ADRs

- **In force, constraining this change:**
  - 0001 (one tree per session: context, commands and agent state in the tree; child state in its own linked tree);
  - 0002 (central truncation: `skill` uses the composer's `notrunc` path, not a tool-local cut);
  - 0003 (unified jobs: agents are supervisor jobs with the same bounds, deadline, rewind and resume);
  - 0004 (Dart-native engine and thin clients: the child is the same executable; expansion stays in the engine);
  - 0005 (four-field journal and RPC v1: the parent is an RPC client of the child);
  - 0006 (workflow and process boundaries: skills, `AGENTS.md`, commands, typed roles; repository text is not policy);
  - 0007 (M1 perception: no new sensorium sections);
  - 0008 (format v1: `body` for turn-anchored context, `meta/lineage` holds the child's parent);
  - 0010 (job tree layout: new kind and fields are additive);
  - 0011 (exchange layout and RPC protocol v1: `command` and `context` are additive exchange fields; `stream` kind `agent` is additive).
- **To record during apply:** ADR 0012 *Workspace context, skills, commands and child-engine subagents*: context keyed by content under `body/contexts`; `.claude` over `.agents` precedence; command expansion recorded at submit; subagents as child engines over RPC v1 with `--child` lineage, role digest and prompt relay; repository frontmatter never widens approval. The same task adds its row to the architecture index.

## Open Questions

None that change specs, approach or tasks. The exact `agents.models` slugs for `sonnet` and `haiku` are the user's configuration, chosen at entry 6.

## Dogfood record

Filled in during apply. From task group 7 on, each task group is first attempted inside Kehai with `/opsx:apply`, using its implementer subagent; each step Kehai could not do, and why, is listed here.

### Group 7 (2026-10-31)

- **Setup:** Kehai built from the group 6 head (a45be50) in a scratch worktree (`bristleworm`, a branch fast-forwarded to that head). It ran on Windows with the ChatGPT login, model `gpt-6.1-sol`, through the line client and `/opsx:apply skills-agents-commands`. Parent session `20261031T232727Z-6e2bcd51`, child session `20261031T233330Z-e059c0b6` (job `j-8860e241`).
- **Could do:**
  - `/opsx:apply` expanded at submit.
  - The parent loaded skills and ran Specwright's `task-cover.sh` through `bash` after approval.
  - It called `agent specwright-implementer` with `background: true` and a self-contained brief for 7.2 and 7.3.
  - The child engine started under the parent session with lineage `{parent, job}` and the role digest on every step. It captured its context and loaded four skills (autoapproved, through containment).
  - The role's `sonnet` alias was unmapped, so the child ran on the parent's model.
  - The parent kept working (`read`, `ls`, `skill`) while the child ran, and polled it with `job output` ("is running; its result is not ready").
- **Could not do:**
  - The child's first command (`pwd; git status --short; mise install`) needed approval. Its prompt reached the parent but not the user, since prompt relay does not exist before 7.2. The call stayed `pending`, and the parent blocked in `job wait` (600 s) on a child that could not progress until its 1 h deadline. The user saw only `busy`. Group 7 was implemented outside Kehai.
- **Friction to keep in view:**
  - `job` on an agent job asks for approval like any non-read tool.
  - Nothing shows that a background child is waiting on a prompt (7.3 progress lines cover settled calls, not waits).
  - Child steps reported `cachedInput: 0` while the parent's later steps reported cached input. To check with longer child runs.
- **Stop:** Ctrl-C cancelled only the parent's `job wait` call (`cancelled: user`); the background job kept running, as D10 says. Ending the client (EOF) shut the engine down, and the lifecycle held:
  - The child got the soft stop. Its pending `bash` call and its exchange ended `cancelled`, and it exited 0.
  - The job settled `cancelled`, reason `shutdown`, with agent status `cancelled`, 5 steps, its usage and a stored `result`.
  - `cleanup` was `uncertain: descendants not verifiable`, because the child is not started as a known process group on Windows.
  - No `kehai` process was left running.

### Group 8 (2026-11-01)

- **Setup:** Kehai built from the group 6 head plus the uncommitted group 7 diff (prompt relay and agent progress), in the same scratch worktree. Windows, ChatGPT login, model `gpt-6.1-sol`, line client, `/opsx:apply skills-agents-commands` for 8.1 and 8.2. Parent session `20261101T002209Z-e9097365`, child session `20261101T003243Z-7020aa4f` (job `j-b8f78a73`, `specwright-implementer`, background). About 31 minutes end to end; the child ran about 19.
- **Could do:**
  - The parent dispatched the implementer in the background and waited with `job wait`, re-issuing it when the 600 s wait ran out.
  - Every child permission prompt was relayed to the user as `agent specwright-implementer (job j-b8f78a73) asks:` with the call shown in full (edit diffs, write previews, bash commands), and the answer reached the child. The child made 19 answered calls and 68 autoapproved ones, none denied.
  - Progress lines tagged `specwright-implementer ·` showed each settled child call while the parent waited.
  - The child wrote both qualification tests, fixed two Windows path problems and an analyzer type error from its own test runs, and finished with both files passing (`-j 1`), format and analyze clean, and a read-only `git status`/`diff` check. It made no production edits. Both tests pass when rerun outside Kehai.
- **Could not do:**
  - Before the dispatch, one parent exchange failed with `model request failed: the backend stopped responding` (an idle timeout after the request was sent, so not retried automatically). Another client failed at the same time, so it was likely server side; a follow-up message resumed the work.
  - After the job settled, the parent moved on to Specwright's commit steps (`vcs.sh state`); that was denied and the run stopped there by choice. Ticking and committing group 8 happened outside Kehai.
- **Friction to keep in view:**
  - While the model writes a long tool call (a whole test file) nothing is shown; the client sat on `busy` for about 4 minutes before the idle timeout above.
  - Progress and tool lines lose their `·` and `→` to mojibake when the console code page is not UTF-8.
  - Allow rules cannot name `skill` or `agent` (the configuration roster lacks them), and `bash` rules match only simple commands, so chained `format; analyze` commands always prompt.
  - `job wait` on an agent job still prompts each time.
  - A Ctrl-D byte sent to the line client through Orca's terminal input echoed `^D` without ending the session, and the Enter after it submitted it as a message; `/exit` ended it. To check whether a typed Ctrl-D behaves the same on the Windows console.
  - The child reported the branch as `hey-greeting`: Orca had renamed the scratch worktree's branch during the run, not Kehai.
  - Child steps reported cached input on some steps only (3712 and 34048 tokens among mostly 0).

### Live review qualification, task 8.3 (2026-11-01)

- **Setup:** the scratch worktree reset to the group 7 head (`2775d3a`), with `review.cross_model: false` set there only. Kehai built from that head; Windows, ChatGPT login, model `gpt-6.1-sol`, line client. The user typed `/specwright-review` with a brief asking for the pre-ship review only, through the subagent route, without fixes or commits. Parent session `20261101T103231Z-36e933a8`, child session `20261101T103332Z-f4422e37` (job `j-baf08780`, `specwright-reviewer`, model inherited). From 10:32 to 10:53 UTC.
- **Could do:**
  - `/specwright-review` expanded to the skill, and the parent followed its subagent route: `review-run.sh select --runtime other` (route `subagent`, nothing skipped, `review.cross_model is false`) and `preflight` (470 129 diff bytes, under `max_diff_kb`), both saved under `build/`.
  - It dispatched `agent specwright-reviewer` with file paths. The child read the brief, the findings schema and the change artifacts, read the 470 KB diff through `git diff` slices and `read_more`/`search_result` paging, wrote `build/preship-findings.json`, and checked it against the schema itself.
  - Every child `bash` and `write` call was relayed and answered by the user (11 answered, 41 autoapproved, none denied); the parent's own calls asked 3 times.
  - The parent ran `review-run.sh record --kind preship --route subagent --preflight … --selection …`, which validated the findings and wrote the record for heads `2775d3a` (base `b55904a`). Receipt: route `subagent`, skipped none, requested model and thinking `default`, actual `unknown`, process group `session`; P0 0, P1 2, P2 0, P3 0.
  - Findings: F1 (P1) the qualification tests were not in the reviewed commit. True at that head: the group 8 tests were uncommitted; they land with group 8. F2 (P1) workspace discovery calls `listSync` unguarded in the skill, command and role loaders, so an unreadable or vanishing discovery directory throws out of `_captureContext` after the exchange node is written. Confirmed in `lib/src/workspace/skills.dart`; it is handled in the pre-ship fix round.
- **Could not do:** nothing in the qualification path. The reviewer ran no tests (read-only role, as briefed), and the receipt cannot name the actual model, since the subagent route has no CLI to report it.
- **Friction to keep in view:**
  - Progress lines from the child's parallel reads printed after a relayed `answer>` prompt and scrolled it off the screen, so the run looked stuck while it waited for an answer.
  - The record for heads `2775d3a` sits in the shared review state directory. The change's configured pre-ship review runs at the final head, so it does not reuse this record.
