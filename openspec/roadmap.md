# kehai Roadmap

[Strategy](strategy.md) · [Architecture / ADRs](architecture.md) · [Design authority](../docs/sensorium-spec.md) · [Amendment review](architecture-review.md)

## Now: M1 — self-hosting skeleton

**Goal: Kehai builds Kehai.** Run `kehai` in this repo with ChatGPT/Codex subscription authentication and the installed Specwright skills; use it to plan, implement, commit and merge the first real M2 change. Primitive is fine; functional is required. This is dogfooding, not feature breadth. No implementation change has started; no exit criterion is passed here.

**Exit criteria:**
- `kehai login openai` completes subscription OAuth **without an API key**, stores/refreshes tokens silently using the OS keychain or `~/.kehai/auth.json` with Unix `0600` (Windows: secure keychain), and `kehai doctor` shows account and model list. **(user)**
- Read files, hash-anchor edit, run `dart test`, `dart analyze` and `jj` through bash, grep/find the tree, and ask a structured question. **(agent)**
- Load `.claude/skills/` and `.agents/skills/`, inject `AGENTS.md`, and call installed `/opsx:*` and `specwright-*` commands. **(agent)**
- Complete **branch → proposal → specs → design → tasks → apply → commit → finish → merge**, with Kehai as sole agent, delivering the first actual M2 change. **(user)**
- Every tool result uses central truncation/full-result handles, never tool-local cuts; property tests replay random journals to identical trees. **(agent)**
- A hung hook process (test fixture) cannot block turn progress. **(agent)**

**Changes** (one PR each; each requires the previous merged):
1. `session-tree-journal` — one tree; append-only JSONL `{turn,path,op,value}`, migration script, materialize/replay/property tests, journal-only rewind/fork without UI, full-result store/handles.
2. `provider-openai-codex` — stream/count/usage/tool-call interface and subscription OAuth. Source-citing design verifies PKCE, redirect port/scopes, token-valid endpoint, refresh/expiry, upstream breakage/reversal cost and API-key fallback. OpenAI/Anthropic API-key adapters only if genuinely free from the interface; otherwise M2. Fallback does not pass subscription acceptance.
3. `core-tools` — numbered/hash-tagged read every N lines, edit loudly rejecting moved/stale anchors, write, real-shell bash (Git Bash/PowerShell detected on Windows; blocking budget → jobs), rg grep, find, ls, structured ask. Short read-only autoapprove allowlist plus a user-owned allowlist in user configuration (never repository content), so the Specwright workflow's routine `jj`/`gh` calls need not prompt each time; otherwise ask; explicit `--yolo`. All results centrally composed; minimal hook-timeout seam only.
   Also owns the unified job supervisor (admission, foreground budget, streaming persistence, cancellation, deadlines), the generic reconciler that cancels jobs removed by rewind, and resume finalization of live jobs. Its tests prove cancellation, crash recovery, stale callbacks and rewind of running jobs without claiming external rollback.
4. `agent-loop-and-line-client` — parallel tools, Ctrl-C, bounded retry/backoff, clear context-overflow stop; readline, streamed output, one-line tool display; thin client over `kehai rpc` NDJSON stdio. No nocterm or compaction.
   Follow-ups, before entry 5: `permission-prompt-unicode` (prompt text shown as Unicode, control characters escaped; #19), `permission-prompt-content` (write content and edit operations on the prompt; #16) and `permission-prompt-old-text` (the lines an edit removes, bound to the file shown; #21).
5. `skills-agents-commands` — skills/AGENTS/commands, existing command definitions/arguments/path substitutions, minimal typed-return job-backed implementer/reviewer subagents; qualify the installed full Specwright workflow.
6. `dogfood-first-m2-change` — select one small M2 capability from observed gaps; Nikolay performs its real lifecycle entirely in Kehai and merges its PR. Its design records friction to seed M2, not a planning-only rehearsal. Before it starts, set `review.cross_model: false` in `openspec/specwright.yaml` (or add a Kehai review route) so design and pre-ship reviews use Kehai's `specwright-reviewer` role rather than launching the Codex or Claude CLI.

**Bridge:** entry 6 is authorized before M1 promotion, but is already the first M2 delivery. Count its merged PR once; carry its receipt into M2, never restart it or create a wrapper PR. Entries 1–5 ship only `turn`, `budget` and truncation; entry 6 permits only its selected M2 capability.

**Every design:** follow [enforced constraints/process](config.yaml) and [pinned source map](architecture.md#source-reference-map). Dart 3.x AOT, no Rust/embedded runtime, tree-only session state. Most M1 uses Claude Code; from entry 4 attempt apply inside Kehai and record gaps (entry 4 after its earliest runnable loop; Specwright commands and subagents arrive in entry 5, so entry 4 is expected to record those steps as unsupported). Windows login/line client must work without WSL in M1.

## Next: M2 — Dogfood-driven perception and client

Carry the bridge delivery forward; split remaining work only at M1 close using recorded friction. Add nocterm, broader sensorium (`vcs`, changes, scratchpad, diagnostics, checkpoints), compaction, LSP and jj checkpoints. **Exit:** full Windows tool parity (agent); a 20-turn session with fewer calls to first edit than OMP on the same task and no silent truncation (user); 5k-line transcript within the [reviewed renderer budget/fallback](architecture.md#resource-bounds-and-failure-visibility), plus sensorium budget/history-fold/Windows-attribution checks (agent).

## Later

- **M2+ as evidence warrants:** full plugin protocol beyond the M1 timeout proof, MCP, Anthropic/Copilot OAuth, pricing model registry, themes, additional OpenAI-compatible/Anthropic/Gemini/Bedrock/LiteLLM routes and Kumiko qualification. No dates or further change splits.
