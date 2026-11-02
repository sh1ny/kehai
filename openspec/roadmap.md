# kehai Roadmap

[Strategy](strategy.md) · [Architecture / ADRs](architecture.md) · [Design authority](../docs/sensorium-spec.md) · [Amendment review](architecture-review.md)

## Now: M2 — Dogfood-driven perception and client

**Goal:** Kehai can build its own longer changes without overflow/restart churn, with honest context capacity, useful per-turn perception and a usable native terminal client. Every M2 change is built by Kehai; owner decisions and configured cross-model reviewers remain explicit.

**Bridge already delivered:** `dogfood-first-m2-change` shipped reasoning-effort selection/inheritance in [PR #27](https://github.com/sh1ny/kehai/pull/27). Count it once; do not restart it or create a wrapper PR. [M1 close receipts and caveats](milestones/m1-close.md).

**Exit criteria:**
- Compaction supports long changes without the manual overflow/restart cycle; context-window reporting is qualified for the ChatGPT-account route, with uncertainty explicit rather than an unsupported 500k claim. Scratch, result handles, canonical history and request/child correlation survive compaction/replay. **(agent; real long-change dogfood acceptance: user)**
- Full native Windows tool parity without WSL. **(agent)**
- A 20-turn session uses fewer calls to first edit than OMP on the same task, with no silent truncation. **(user)**
- A 5k-line transcript meets the [renderer budget/fallback experiment](architecture.md#resource-bounds-and-failure-visibility); sensorium budget/history-fold/Windows-attribution checks pass. **(agent)**
- The nocterm client supports `/sense`, explicit multi-line input and multi-line paste without submitting at the first newline. **(agent; interactive usability: user)**
- The friction ledger below has explicit design assignments and verified dispositions; deferrals require an owner decision, not silent omission. **(agent; deferrals: user)**

**Changes** (owner agreed seven entries and this order on 2026-11-02; each requires the previous merged; each aims at one bounded PR):
1. `context-compaction-and-window-accuracy` — journal-derived compaction and route-aware context-window accuracy FIRST. Three entry-6 overflows at roughly 187–228k, despite the UI advertising 500k for `gpt-6.1-sol` on the ChatGPT-account route, made restarts a risk to every later change. These observations are not an exact replacement limit. Preserve scratch/handles and request/child correlation; retain the tree/journal as authority and visibly report unknown/estimated capacity. Do not depend on the later scratchpad tools: define preservation of existing/future scratch representation in the design.
2. `sensorium-block-and-scratchpad` — per-turn sensorium block, `scratch_*` tools and request-only folding per ADR 0007 and the unchanged sensorium specification; integrate with the compaction preservation contract.
3. `vcs-changes-and-notices` — jj-first VCS collector with git fallback, `changes_since_last_turn` and `notices`; explicit Windows coverage/staleness and honest attribution.
4. `nocterm-client` — renderer experiment in week one of this change, release/AOT 5k-line measurement and fallback decision; `/sense`; **multi-line input and multi-line paste are explicit requirements**. Retain a thin client over RPC v1. PTY/VT integration follows the package directions below only where needed.
5. `lsp-diagnostics-and-delta-footer` — LSP client, diagnostics collector and delta footer, with bounded work, visible stale/partial coverage and existing job/tree ownership.
6. `jj-checkpoints` — jj operation restore with git hidden-ref fallback; automatic checkpoints before risky calls. Separate workspace restoration from journal rewind, with honest external-effect limits.
7. `windows-tool-parity-and-m2-qualification` — close remaining native Windows gaps, qualify OMP comparison, sensorium/history-fold/attribution budgets and 5k-line renderer behavior, and verify all assigned friction dispositions. No claim of parity from mocks alone.

**Explicit M2 work to assign in those designs** ([detail and evidence](milestones/m1-close.md#m2-friction-ledger--assignment-required-in-designs)):
- Permissions/config/instructions: “allow for this session”; user-level instruction file; user allow rules scoped to the repo/workspace; config reload without restart; safe handling of chained commands that currently always prompt. Preserve deny policy and reconcile live configuration with ADR 0013's immutable resolved effort/child inheritance. Do not broaden shell-chain autoapproval by assumption.
- Workflow: one blocking watch/wait, backgrounded when needed, instead of repeated `sleep` polling; review Specwright scratch placement/trust/cleanup rather than relying on broad external-directory permissions.
- [#28 timing tests](https://github.com/sh1ny/kehai/issues/28): deadline after child readiness or in-process timing tests; wall clocks as hang guards where appropriate; a process-test tier. Preserve partial-text/timeout/hung-hook contracts.
- Restore `search_tools_test` → “a relative PATH entry is skipped” with `cwd=workspace`, weakened in `325692c`. This coverage restoration is still outstanding.

**Building blocks and integration:** follow [ADR 0014](../docs/adr/0014-reusable-building-blocks-as-separate-packages.md). Extract Kumiko's `packages/process_containment` to its own repo/OpenSpec project before reuse, never copy it; qualify ConPTY/native-asset delivery in Kehai's AOT build. Its Job Objects may replace `taskkill` tree kill only after cleanup behavior is proven. VT parsing is a new pure-Dart `vte`-equivalent plus minimal line buffer, not Kumiko's Rust `alacritty_terminal`. Optional and evidence-gated: tree-sitter C FFI/grammar assets and pure-Dart o200k counting. Create no package until a consuming change needs it. Kumiko eventually runs Kehai as its default harness via `kehai rpc` v1; its containment extraction/runtime adapter requires a separate Kumiko planning change.

**Every design:** use [enforced constraints/process](config.yaml) and [pinned source map](architecture.md#source-reference-map). Dart 3.x AOT, strictly no Rust/embedded runtime, C FFI only where needed; one session tree, central result handling and unified jobs remain locked. Keep `review.cross_model: true` and required pre-ship review. Entry 6's Windows Nightly waiver is a recorded exception, not a future qualification policy.

## Next: M3 — Evidence-led extension and integration breadth

After M2 qualification, choose the next outcome from dogfood evidence: full process-plugin protocol beyond the M1 timeout seam, MCP, additional subscription/provider adapters, pricing/model registry, themes or Kumiko qualification. Preserve tree invariants and native Windows support; no split or promised feature bundle is agreed yet. Re-plan at M2 close rather than prebuilding packages or integrations.

## Later

Daily use instead of OMP remains the adoption measure. Additional OpenAI-compatible/Anthropic/Gemini/Bedrock/LiteLLM routes and non-Dart extension breadth require demonstrated needs, not dates or speculative package work.

## Done: M1 — self-hosting skeleton (2026-11-02)

**Learned:** Kehai delivered a real M2 capability end to end, but context-capacity errors and three manual overflow restarts make compaction the first remaining M2 delivery; permissions, workflow waits and timing-test tiers need explicit follow-up.

**Completed changes** (archives verified on fetched `main`): `session-tree-journal`, `provider-openai-codex`, `core-tools`, `agent-loop-and-line-client`, `skills-agents-commands`, `dogfood-first-m2-change`; permission-prompt Unicode/content/old-text follow-ups also merged.

**Exit results:** owner confirmed Windows subscription login without an API key, secure storage/silent refresh, and doctor account/models **PASS**; real Kehai lifecycle **PASS with caveats**. Agent checks passed for core operations, installed skills/commands/roles, central full-result handling, randomized identical-tree replay and hung-hook isolation. [Receipts](milestones/m1-close.md) distinguish observed tests, owner acceptance and exceptions.

**Caveats retained:** babysitter permission answers/instructions; owner cross-model and Windows Nightly-waiver decisions; KintsugiBot issue comments outside the branch; three restarts with hand-written resume prompts; no compaction. Windows delivery-head Nightly failed twice on different timing tests and was explicitly waived by the owner in #28, not green. Linux Nightly and both-OS delivery PR CI passed; both-OS archive-head PR CI, archive-only and pre-ship gates passed before merge. This is qualified M1 self-hosting acceptance, not unattended operation or completed M2 qualification.
