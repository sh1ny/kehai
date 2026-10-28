# kehai Strategy

## Purpose
An MIT, open-source, CLI-first coding-agent harness in Dart. OMP (oh-my-pi) feature parity is the long-term bar, not the first release checklist. Design from the agent's perspective: the harness controls the **sensorium**, what the model perceives each turn, as well as what the user sees. Adopt [sensorium-spec.md](../docs/sensorium-spec.md) as design authority; its three locked decisions are foundational, not candidates for reconsideration.

## Users
- **Primary:** Nikolay, a solo developer/SRE working evenings, using jj on native Windows and Linux without WSL. Prefer correctness and small, one-PR increments over breadth.
- **Secondary:** existing pi/OMP/OpenCode CLI users who need plugins unable to crash the UI and sessions that rewind, fork and resume correctly.
- **Later:** Kumiko, a separate Flutter orchestration app, consuming the same headless engine's RPC patch stream, not a second engine or a GUI in this repo.

## Boundaries
Dart 3.x; engine / nocterm tui / cli packages; native AOT releases for Linux x64/arm64, macOS and Windows. No Rust core; C FFI for native integration, real shells/PTY (ConPTY on Windows), bundled ripgrep. jj first-class, git best-effort. Three extension tiers: data (skills, AGENTS.md, prompts, themes), supervised process plugins, core fork; no arbitrary plugin widgets or embedded script runtime. Own thin Anthropic/OpenAI-compatible/Gemini/Bedrock adapters, LiteLLM for others; Claude/Copilot subscription OAuth is later, not M1.

Every session fact belongs to one tree; journal, full-result payloads and rebuildable indexes do not create parallel session authorities. Plugins cannot hold the turn/UI hostage. Stable system prompt; bounded per-turn perception with explicit folding/truncation. Local, user-owned, plain, deletable journals can contain source and secrets present in source/tool output; configured provider credentials belong only in OS keychain/environment files, never journaled. No automatic uploads: model requests go only to the configured provider/proxy; local plugins/tools remain user-installed code, not a security sandbox.

**Not planned:** browser/desktop control, DAP, collaboration/relay, in-process shell interpreter, IPython, image generation, TypeScript-extension compatibility, a GUI, hosted services, telemetry or kehai accounts.

## Success measures
- **M1:** property tests prove materialize/rewind/fork/resume, including randomized rewind-then-resume equivalence against journal replay, with zero feature-specific rewind code; a real Anthropic coding turn works through a line-mode RPC client. No TUI.
- **M2:** Nikolay completes a 20-turn coding session on this repo, with fewer tool calls to first edit than OMP on the same task, no silent truncation, and a 5k-line transcript within the reviewed renderer budget.
- **M3:** one external non-Dart plugin runs tools and hooks; killing it mid-hook leaves the session usable. Diagnostics, checkpoints and speculative compaction preserve the tree invariants.
- **Later adoption:** Nikolay uses kehai daily instead of OMP for his projects.

## Assumptions
Milestones are evidence gates, not calendar promises. M1 targets native Windows and Linux; the release architecture also supports macOS, with its qualification before claiming that release. API-key Anthropic access is available for the user-run live M1 demonstration. No existing CLI sessions/extensions are imported. The latest brief sets milestone scope where the spec's historical slice labels differ; the spec retains authority over its contracts. Architecture review evaluates journal encoding, history-fold experiments, Windows change detection and renderer thresholds; those recommendations do not reopen the locked decisions.
