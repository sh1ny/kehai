# ADR 0019: VCS repository trust

Status: accepted
Date: 2026-11-14
Supersedes: ADR 0017's unattended default/opt-out configured-program policy only; ADRs 0017 and 0018 otherwise remain in force and immutable.

## Context

Automatic Git/jj observation can execute repository-configured programs before any tool permission prompt. Hook suppression does not prevent clean/process filters or fsmonitor programs from running. A deadline cannot prevent their initial effects. The user approved the security-policy amendment in [D12](../../openspec/changes/archive/2026-11-14-vcs-changes-and-notices/design.md), independently approved by FULL review R29.

## Decision

Automatic native VCS observation defaults to untrusted. Only explicit `kehai --trust-vcs`, `kehai rpc --trust-vcs` or a programmatic startup grant authorizes it. Config, environment, roles, session history, replay and `--yolo` cannot grant trust. A new invocation, including resume, defaults to denied.

The capability binds the canonical workspace and startup repository root, marker kind and selected backend. Marker-only checks resolve from the canonical workspace. An observed selection mismatch permanently revokes that engine's grant, even if the original markers return. Managed children inherit the original binding and check it independently, not a fresh binding. The hidden child payload is closed, versioned and limited to 16384 UTF-16 code units under the existing total native argv ceiling. Data without child mode or explicit trust is a usage error; malformed, oversized or foreign-workspace data fails startup before provider discovery, without a fallback grant.

Gate both backends before the timer, collection lock, sequence reservation, native process/probe or pre-hash work. Recheck queued plans after the lock and revocation before each native start. A refused later start returns typed `trust required`, no new admitted baseline or refusal-related VCS notice, and carries prior provenance. Already-started work retains existing completion/deadline/quarantine ownership; the result remains trust-required if its old process later reaches the deadline. A plan whose starts all preceded revocation keeps its result.

Without trust in a selected repository, both sections read `unavailable (trust required)`, never a current/stale carried value. Preserve the prior effective baseline and observed boundary without advancing attribution. Fresh metadata reserves the largest carried envelope within 4 KiB. A legacy preview alone may refit with counted omissions; count values/precision, baseline, boundary and typed reason remain, and earlier admissions never change. Preview fitting does not introduce `partial`; missing totals are established before removal.

A trust-required admission with known lookup loss and no baseline carries `baselineLost: true` without a reset notice. Later trust-required admissions retain it. The next trusted collection uses existing loss handling; disabled/no-repository admissions instead report and consume the loss under their existing semantics. Loss is never inferred again from a reason string.

Trusted collection keeps native content semantics, private indexes, hook suppression, command allowlisting and bounded cleanup. Any program Git/jj configuration causes the fixed plan to start runs as the user, without a sandbox. Trust covers later configuration, attributes and Git-gitfile edits within the binding; allowing those edits can enable execution at the next collection. Binding checks, deadlines and revocation do not undo already-triggered credential, filesystem or network effects.

## Consequences

- VCS change detection, attribution and `user_edits` notices are off by default. Other tool permissions remain unchanged.
- One bound capability per engine, shared by its native collector and call contexts; no trust store, journal authority, prompt-driven grant or new runtime RPC command.
- Existing baselines survive untrusted gaps. Selection changes require a new explicit invocation rather than silent re-binding.
- No instruction-identity, tool-schema, RPC-v1 wire, journal-operation, package-version, section-cap, fold-order or notice-code change. Existing Git 2.34 minimum and sparse-aware capture remain unchanged.
