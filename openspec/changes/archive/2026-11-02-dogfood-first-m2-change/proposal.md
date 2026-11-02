# Proposal

## Why

Kehai's provider can send reasoning effort, but the running agent cannot select it or record which setting a step used. This is roadmap M1 entry 6, the authorized first M2 delivery: a small real capability whose complete lifecycle in Kehai advances the user-verified branch → proposal → specs → design → tasks → apply → commit → finish → merge criterion, counted once in M2.

## What Changes

- Add `--effort <value>` to the line client and `kehai rpc`, and an optional top-level `"effort"` default in the user-owned `config.json`.
- Resolve CLI over user config; with neither set, retain the provider's default (omit `reasoning.effort`). Use the same resolution on resume, without silently inheriting an earlier step's setting.
- Send the selected value on every model request, including tool-follow-up steps, safe retries and internal agent requests. Internal agents inherit the parent's resolved effort.
- Record `effort` on every new step, including explicit `null` for provider default; retain historical steps unchanged.
- Keep the full delivery lifecycle in Kehai. Initial design and pre-ship reviews used Kehai's fresh-context `specwright-reviewer` as a delivery-only dogfood choice, not a repository-wide policy. Restore `review.cross_model: true`; Kehai may launch configured external reviewer CLIs through validated Specwright routing. Obtain fresh design approval for this amendment and a fresh final-head pre-ship review before shipping. Record observed dogfood friction without expanding the reasoning-effort feature scope.

## Capabilities

### New Capabilities

- `reasoning-effort`: user selection, precedence, validation, request propagation, child inheritance and auditable per-step effort.

### Modified Capabilities

None. `model-provider` already accepts optional reasoning effort; this adds the user-facing selection contract around it. Existing agent-loop, RPC and subagent requirements remain in force.

## Impact

CLI parsers/forwarding, user config, RPC engine startup, request builder and exchange driver, tool runtime and agent launch arguments; additive `effort` step data. Tests cover config/CLI errors, precedence/resume, multi-step/retry requests, child inheritance and replay compatibility. No new package, auth flow, service endpoint, RPC command, journal format or side store.

Out of scope: per-model capability discovery or automatic effort downgrade, per-role effort overrides, live `/effort` commands, model changes, pricing, broader sensorium, nocterm, compaction, LSP, MCP and other M2 features. This planning run does not pass the user-verified lifecycle criterion; only the actual merged delivery can do so.
