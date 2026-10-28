# ADR 0006: Subscription auth, workflow and process boundaries

Status: accepted
Accepted: 2026-10-28
Date: 2026-10-28
Supersedes: none

## Context

M1 must actually self-host the installed Specwright workflow using ChatGPT/Codex subscription OAuth, not API keys. A hung hook cannot hold a turn hostage. Any-language process boundaries fit a Dart-native core without embedded runtimes, but local execution is not a sandbox.

## Decision

First provider: ChatGPT/Codex subscription OAuth, with a normalized streaming/count/usage/tool-call interface. `kehai login openai` completes subscription login and `kehai doctor` displays account/model availability. Count may estimate conservatively; no pricing/model registry is required. Entry 2 must study exact source files for Codex Rust login/refresh, oh-my-pi Codex auth and OpenCode Codex auth, pin full revisions, and record verified PKCE/state, redirect port/URI, scopes, subscription-valid endpoint, refresh/expiry, upstream breakage and reversal cost. Do not fabricate parameters now or assume subscription tokens work with standard `/v1` APIs. The [source map](../../openspec/architecture.md#source-reference-map) distinguishes historical built-in OpenCode code from the separate third-party plugin. API-key OpenAI or Anthropic may share the PR only if genuinely free from the interface; otherwise M2. API-key fallback never satisfies subscription acceptance.

Credentials are an explicit external secure boundary: Windows uses a secure OS keychain; Unix may use `~/.kehai/auth.json` mode `0600`. Chmod is not Windows protection. Fail closed if a permitted secure backend is unavailable. Refresh silently until reauthentication is necessary, then expose a useful sanitized error. Exact refresh protocol is source-driven, not prescribed from snippets. Configuration is also external input; permissions, requests, approval outcomes and child state are session-tree facts, not side stores.

Load `.claude/skills/` and `.agents/skills/` `SKILL.md` files, inject applicable `AGENTS.md`, and expose installed `/opsx:*` and `specwright-*` command adapters. Consume existing `.claude/commands/opsx/*.md` definitions/aliases, arguments and skill path substitutions such as `skill-dir`, not only skill markdown. Minimal typed-return subagents run as unified jobs in M1, mapping installed `.claude/agents/specwright-implementer*.md` and `specwright-reviewer.md` roles with usable role/model configuration to the full workflow, not merely loading markdown or promising an unavailable review route. The sole-Kehai dogfood gate must not require another agent harness. Core tools use a short read-only allowlist, ask otherwise, and explicit user `--yolo` override. Shell prefix matching cannot autoapprove substitutions/metacharacters/mixed commands unless the whole command is proven read-only.

M1 hooks are only an independently enforced deadline seam plus hung-process fixture. Optional timeout is a visible safe no-op; minimal deny-class failure denies. A hanging process cannot gate the turn. Hook deny policy is separate from core tool approval, not a broad plugin framework. M2+ may add lazy local process plugins with versioned stdio NDJSON and declarative UI, never arbitrary in-process widgets. Full plugin protocol, MCP, LSP and Anthropic OAuth are deferred; LSP framing must be designed separately from NDJSON when introduced.

Resolved credentials, auth headers, credential-bearing URLs and launch-environment dumps never persist in tree, payloads or logs. Store useful allowlisted/sanitized adapter errors, not raw exception/request dumps. Give secrets only to the adapter and exclude them from default subprocess environments; explicit user environment opt-in carries an exposure caveat. Source/raw user-process stderr may contain secrets and remains subject to full-result persistence: this is not all-output redaction or encryption. Configured provider is the only harness prompt sink; OAuth intentionally uses the verified auth service. No Kehai telemetry/hosted account service or automatic remote discovery. Local plugins/subprocesses have user privileges and may access the network; future remote integrations require separate authorization. Repository/skill/plugin text is untrusted input, not permission-policy authority.

## Consequences

- **Rejected:** API-key-only M1 or fallback counted as subscription success; neither proves the intended user workflow.
- **Rejected:** embedded Dart/TypeScript/QuickJS/Python plugin execution and arbitrary plugin widgets; unnecessary crash/runtime and compatibility surface.
- **Rejected:** broad plugin/MCP/LSP protocol as a prerequisite for the minimal hung-hook guarantee; a deadline must not rely on cooperative cancellation.
- **Cost:** source-driven auth, secure platform storage, secret-safe failures, command adaptation and minimal typed review roles are real M1 work. Broader extension protocols need separate M2+ design.
- **Reversal cost: high** for auth/trust and extension contracts; **medium** for adapter packages. M1 must prove subscription login and a nonblocking hung hook; later plugin capabilities require their own evidence. Apply the shared [per-M1 design contract](../../openspec/architecture.md#decisions-and-per-m1-design-contract).
