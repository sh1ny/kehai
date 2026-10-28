# kehai Strategy

## Purpose
An MIT, open-source, CLI-first coding-agent harness in Dart. OMP (oh-my-pi) feature parity is the long-term bar, not the first release checklist. Design from the agent's perspective: the harness controls the **sensorium**, what the model perceives each turn, as well as what the user sees. Adopt [sensorium-spec.md](../docs/sensorium-spec.md) as design authority; its three locked decisions are foundational, not candidates for reconsideration.

## Users
- **Primary:** Nikolay, a solo developer/SRE working evenings, using jj on native Windows and Linux without WSL. Prefer correctness and small, one-PR increments over breadth.
- **Secondary:** existing pi/OMP/OpenCode CLI users who need plugins unable to crash the UI and sessions that rewind, fork and resume correctly.
- **Later:** Kumiko, a separate Flutter orchestration app, consuming the same headless engine's RPC patch stream, not a second engine or a GUI in this repo.

## Boundaries
Dart 3.x AOT; engine / cli, with nocterm tui later; target Linux x64/arm64, macOS and native Windows without WSL. No Rust core or embedded script runtime. Real shells, detected/bundled ripgrep; C FFI where needed, not an M1 prerequisite checklist. jj first-class, git best-effort. Data/process/core-fork extension tiers; skills, AGENTS.md, commands and minimal typed subagents enter M1 for Specwright, not arbitrary plugin widgets. First provider: ChatGPT/Codex subscription OAuth, not an API key. Other providers, MCP, themes, pricing registry and Anthropic OAuth are M2+.

Every session fact belongs to one tree; journal/full-result payloads and disposable projections are not parallel authorities. Plugins cannot hold a turn hostage. Stable system prompt; hard-bounded perception and explicit central truncation. M1 sensorium is only turn/budget; broader observations are M2. Journals are local, plain, user-owned and deletable; source/output can contain secrets. Credentials are explicitly external: OS keychain, or `~/.kehai/auth.json` with Unix `0600`; Windows uses its secure keychain, not a false chmod guarantee. Never journal tokens. No automatic uploads beyond the configured provider/proxy; local subprocesses are trusted user code, not sandboxed.

**Not planned:** browser/desktop control, DAP, collaboration/relay, in-process shell interpreter, IPython, image generation, TypeScript-extension compatibility, a GUI, hosted services, telemetry or kehai accounts.

## Success measures
- **M1 — self-hosting skeleton:** Kehai builds Kehai. Nikolay uses only Kehai, authenticated by ChatGPT/Codex subscription, to complete and merge the first real M2 Specwright change. Replay properties, central full-result handles and hung-hook turn isolation pass. No TUI.
- **M2:** full Windows tool parity; broader sensorium/nocterm, a 20-turn session with fewer calls to first edit than OMP on the same task, no silent truncation, and the 5k-line renderer budget.
- **M3 / later:** complete extension/provider breadth when dogfood evidence warrants it; non-Dart plugins and compaction/checkpoint behavior preserve tree invariants.
- **Later adoption:** Nikolay uses kehai daily instead of OMP for his projects.

## Assumptions
Milestones are evidence gates, not dates. M1 requires native Windows login/line client; full Windows tool parity is M2. Most M1 is authored with Claude Code; from change 4, attempt each apply inside Kehai and record gaps. The final dogfood change must use Kehai alone. Designs cite reference source files/revisions, not rederive them. No session/TypeScript-extension import. The amended brief controls delivery scope; the sensorium spec retains contract authority and its three locked foundations. A subscription endpoint change can block M1: an API-key fallback is not a passing substitute.
