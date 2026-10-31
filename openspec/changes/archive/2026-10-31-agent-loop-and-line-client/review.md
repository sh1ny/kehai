# Review

## Metadata

- **Round:** 3
- **Prior round:** round 2 REVISE (R2-M1 held-argument bound; R2-M2 writer overflow with many calls; R2-M3 incomplete-step usage baseline)
- **Reviewer:** cross-model CLI (codex)
- **Reviewed:** proposal.md, design.md and all six delta specs for `agent-loop-and-line-client`; roadmap M1/change 4; architecture.md; config.yaml design rules; ADRs 0001–0010; sensorium delivery, snapshot and budget contracts; main session-tree, session-journal, tool-calls, user-ask, model-provider, tool-permissions, result-store and job-supervisor specs; all eleven requested source files; CLI skill. Additional evidence: write.dart and edit.dart.
- **Re-check:** required changes 1 and 2 verified (`openspec/changes/agent-loop-and-line-client/design.md:117`, `:204`, `:339`; `openspec/changes/agent-loop-and-line-client/specs/turn-perception/spec.md:36`, `:39`; `openspec/changes/agent-loop-and-line-client/specs/line-client/spec.md:65`, `:71`, `:75`, `:79`)

## Findings

### Critical (blocking)

None.

### Moderate

**R3-M1 — Context accounting needs to include interleaved tool outputs explicitly.**

D3 builds `call A, output A, call B, output B`, inserting each result immediately after its call (`openspec/changes/agent-loop-and-line-client/design.md:74`). D7 instead estimates “items after u’s output” (`design.md:117`).

These are different boundaries: output A precedes the end of the baseline step’s output. A suffix calculation therefore omits output A; starting earlier and estimating the entire suffix counts call B again. With several large results, the budget can underreport context and miss the pre-flight stop.

The perception scenario assumes both tool outputs follow the response output, so it does not exercise the actual interleaved layout (`openspec/changes/agent-loop-and-line-client/specs/turn-perception/spec.md:39`).

Define the added content by provenance: every tool result answering the baseline step, plus subsequent conversation content, excluding the baseline response items already covered by usage.

**R3-M2 — Concurrent prompts have no defined answer target in the line client.**

The runtime permits eight concurrent calls (`lib/src/tools/runtime.dart:52`), and `PromptChannel` independently opens and delivers each prompt by key (`lib/src/tools/ask.dart:98`, `:104`). The client requires every prompt to appear immediately and accepts an unkeyed `1` or `allow`, but specifies no active prompt, queue or focus rule (`openspec/changes/agent-loop-and-line-client/specs/line-client/spec.md:65`).

Two parallel permission requests can therefore display identical choices without defining which command the next `1` approves. A newly arriving prompt can also replace the question the user was answering. This affects authorization of real effects, not merely presentation.

Specify one active prompt with a stable key, FIFO pending prompts, and advancement rules for accepted answers and withdrawals. Add a scenario covering two concurrent permission prompts and a rejected answer.

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. Amend D7 and the perception **Context in use** requirement to count all tool outputs answering baseline step `u`, wherever D3 places them, plus subsequent conversation items and the current sensorium block. Exclude `u`’s response items from that estimate. Replace the existing two-output scenario with an explicit `call A, output A, call B, output B` case asserting both outputs are counted once.
2. Amend D14 and the line-client **Answering prompts** requirement: maintain one active prompt and a FIFO queue; new arrivals never replace the active key; send at most one answer at a time; rejection retains the active prompt; acceptance or withdrawal removes that key and activates the next pending prompt. Define queued arrivals as notifications rather than additional active choice menus. Add scenarios verifying answer routing with two permission prompts, rejection, and withdrawal.

CHANGES_APPLIED: yes

## Rebuttals

- **R2-M1 — Fixed.** D16 counts held argument bytes inside the adapter and discards calls on overflow (`openspec/changes/agent-loop-and-line-client/design.md:224`); the provider delta specifies the failure and a five-call scenario (`openspec/changes/agent-loop-and-line-client/specs/model-provider/spec.md:17`, `:19`).
- **R2-M2 — Fixed.** D17 routes every engine writer operation through a shared 48-permit gate (`openspec/changes/agent-loop-and-line-client/design.md:230`), below the existing 64-operation refusal (`lib/src/session/writer.dart:701`). Its stated coverage includes runtime, supervisor, driver and server writes.
- **R2-M3 — Fixed.** D7 explicitly excludes failed, incomplete and cancelled steps from the usage baseline (`openspec/changes/agent-loop-and-line-client/design.md:117`); the perception requirement and incomplete-step scenario enforce that choice (`openspec/changes/agent-loop-and-line-client/specs/turn-perception/spec.md:36`, `:46`). R3-M1 concerns the separate accounting of interleaved results.
- **R3-M1 —** Fixed (`openspec/changes/agent-loop-and-line-client/design.md:117`; `openspec/changes/agent-loop-and-line-client/specs/turn-perception/spec.md:36`, `:39`), accepted by reviewer.
- **R3-M2 —** Fixed (`openspec/changes/agent-loop-and-line-client/design.md:204`, `:339`; `openspec/changes/agent-loop-and-line-client/specs/line-client/spec.md:65`, `:71`, `:75`, `:79`), accepted by reviewer.