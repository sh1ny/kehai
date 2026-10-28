# ADR 0003: One job lifecycle and runtime resource owner

Status: accepted
Accepted: 2026-10-28
Date: 2026-10-28
Supersedes: none

## Context

The adopted [session model](../sensorium-spec.md#session-model) locks one stdio-shaped job model for shell work, daemons, plugin processes, over-budget calls and later subagents.

## Decision

A single supervisor owns job admission, foreground blocking budget, streaming persistence, cancellation and deadlines. Logical lifecycle/ownership live in `jobs`; native process/signal handles are ephemeral capabilities, never persisted raw handles. Jobs cannot block engine/UI event loops. A generic reconciler terminates runtime resources removed by tree restoration; no tool-specific rewind handler.

Resume finalizes former live jobs as interrupted/cancelled before accepting commands and resolves unfinished tool nodes accordingly. No automatic replay/relaunch of external effects. Session rewind and workspace restore remain separate; killing a job does not undo files, remote requests or paid provider calls. Platform cleanup limitations are visible, not hidden behind a cancelled label.

## Consequences

- **Rejected:** different background registries and timeout paths per tool/plugin; lifecycle gaps would recur on rewind/resume.
- **Rejected:** resuming a recorded PID or replaying an interrupted command; PIDs can be reused and effects may already have occurred.
- **Cost:** supervisor and immutable output path precede rich clients; runtime maps must reconcile with committed state.
- **Reversal cost: high.** Job schemas and cancellation semantics are shared contracts. M1 must prove cancellation, crash recovery, stale callbacks and rewind of running resources without claiming external rollback.
