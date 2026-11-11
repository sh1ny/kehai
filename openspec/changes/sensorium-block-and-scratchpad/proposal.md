# Proposal

## Why

M2 needs durable agent-owned working memory and bounded per-request perception before the later VCS, client and diagnostics changes. With `context-compaction-and-window-accuracy` merged in PR #30, this second M2 change advances the scratch/handle continuity and sensorium budget/history-fold exit criteria without replacing provider-native compaction.

## What Changes

- Add session-local `scratch_set` and `scratch_del`: verbatim tree-owned text, bounded writes, ordinary journal rewind/fork/resume, and rendering outside compactable conversation history.
- Expand the request-only sensorium into an ordered, bounded projection with current turn/budget, live jobs, scratch and existing compaction notices. Explicitly distinguish empty supported sections from unavailable/not-yet-collected sections.
- Follow ADR 0007: send one self-contained `full` snapshot when removing earlier request blocks would lose unchanged facts; do not invent a delta baseline or modify canonical history. Preserve provider-native opaque items and strict lineage checks.
- Enforce the source section ceilings and folding order, a configurable 1500-token default block ceiling with a calculated safe startup minimum, and visible refusal when immutable content cannot fit. Bound variable workspace/model display visibly without changing canonical data, and preserve route-qualified unknown/estimated budget reporting.
- Capture the exact request observation in a guarded pre-stream merge after request construction and the existing running-step admission, so RPC consumers can inspect what was locally admitted without claiming provider receipt. Its source offset is same-journal diagnostic metadata, not a durable lookup identity; `/sense` UI integration remains the later `nocterm-client` change.

**Scope decision:** the owner selected session-only scratch on 2026-11-11. `scratch_pin` and per-repo project memory remain a later change, consistent with ADR 0001 and the source's learn slice. No external memory store or placeholder tool is introduced.

**Reviewed apply revision:** live process details use tree-owned job state; logs explicitly remain unavailable because published result references appear only at exit. This change adds no live-log producer or tail I/O. Scratch presentation indents every stored line with counted framing, preserving its text without allowing it to impersonate sensorium structure; recovery notices use bounded codes while the existing recovery message remains separate.

**Non-goals:** VCS/attribution collectors and general notices (`vcs-changes-and-notices`), LSP/delta footer, test watch, plan-file parsing, checkpoints, nocterm, plugin collectors, pricing/tokenizer packages, configuration hot reload, approval-policy changes or compaction strategy changes. This change establishes the rendering contract those later changes consume, not their implementations.

## Capabilities

### New Capabilities

- `agent-scratchpad`: bounded session-local key/value working memory, tool mutation semantics and lifecycle preservation.

### Modified Capabilities

- `turn-perception`: ordered self-contained snapshot, honest availability, fixed section/fold ceilings, exact admitted observation and expanded-block accounting.
- `tool-calls`: extend the versioned roster with the two scratch tools while preserving child narrowing and the existing lifecycle/result contract.

## Impact

The implementation touches `lib/src/loop/sensorium.dart`, `request_builder.dart`, `driver.dart`, built-in instructions, core tool registration/runtime and user configuration/bootstrap. It adds no process, dependency, journal opcode or RPC protocol version. Native continuity deliberately remains strict: changing built-in instructions/tool identities requires a new session or rewind before incompatible opaque output, not fallback to older ciphertext.

Existing loop/tool/session tests will exercise consumer-visible behavior; exact two-line/roster-copy assertions will not be re-pinned as implementation tests. Apply must be orchestrated by Kehai, with configured cross-model design and pre-ship review plus both-platform delivery CI/Nightly evidence. This proposal does not claim an apply attempt or any milestone exit has passed.
