# Design

## Triage

| Trigger | Applies? | Evidence |
|---|---|---|
| T1 Components (new component, or 3+ with directed relationships) | No | One test file changes; no component is added or rewired. |
| T2 State (persistent state, caches, 3+ state machine) | No | No product state changes. |
| T3 Concurrency (background work, workers/isolates, async, retries) | No | The test observes the existing foreground-to-job handoff; the runtime is unchanged. |
| T4 Boundaries (data format, migration, shared interface, IPC, external) | No | No format, interface or contract changes. |
| T5 Volume (grows without a fixed bound) | No | Fixed durations only. |
| T6 Risk (security, money, data loss, unrecoverable user data) | No | Test-only. |

TIER: LIGHT

## Context

- `test/shell/bash_tool_test.dart:122-158`: runs `echo start; sleep 4; echo end` with `timeout_s: 1`, then asserts `clock.elapsed < 4 s` (line 142), that the job is still `pending` or `running` (line 143), and later waits for it to settle with `waitFor` (line 147).
- `test/support/job_support.dart:27-29`: `waitFor` polls every 10 ms with a default 20 s limit.
- The nightly Windows run measured 4.38 s for this call (run 41108909672), with every other assertion of the test passing.

## Decisions

### D1: Widen the margin instead of dropping the wall-clock bound

- **Choice:** sleep 15 s, require the call to return within 10 s, and give the final `waitFor` an explicit 60 s limit. The elapsed bound still separates "returned at budget expiry" (about 1 s plus job startup) from "waited for the command" (15 s or more), and the job-state assertion stays as the second proof.
- **Rejected:** removing the elapsed assertion and relying only on the job still being `running`. That assertion is checked after the call returns and is itself timing-dependent, so on its own it says less, and a regression that waited most of the command would pass it.
- **Reversal cost:** low.
