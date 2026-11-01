# Review

## Metadata

- **Round:** 3 — second Required Change 1 re-check only; no new full review.
- **Prior round:** Round 3’s amendment-only review and first re-check returned `APPROVE_WITH_CHANGES` with changes unapplied. The first re-check accepted most corrections but left cumulative successful descendant probes and post-drain waits outstanding. Round 2 findings and their verified corrections remain closed.
- **Reviewer:** Codex, read-only re-check; no participation in authoring the reviewed artifacts.
- **Review baseline:** `openspec/changes/skills-agents-commands/review.md`, also saved as `C:/Users/bgshi/AppData/Local/Temp/sac-review-round3b.md`.
- **Earlier baselines:** `C:/Users/bgshi/AppData/Local/Temp/sac-review-round3.md`, `C:/Users/bgshi/AppData/Local/Temp/sac-review-round2.md` and `C:/Users/bgshi/AppData/Local/Temp/sac-review-recheck2-out.md`, as recorded in the retained review.
- **Reviewed:** D11’s shutdown budget; the line-client delta; ADR 0012’s shutdown qualification; the two cited tests and line-client Test map rows; supervisor timing defaults, close, cancellation, termination, descendant discovery, probes, drain and handoff completion; client exit grace and kill timer; job recovery.
- **Applicable skill material consulted:** `.claude/skills/dart-build-cli-app/SKILL.md`. Earlier consultation of `.claude/skills/dart-use-path-package/SKILL.md` is retained as historical metadata.
- **Review template:** Obtained with `mise exec -- openspec instructions review --change skills-agents-commands --json`, using process-scoped mise configuration trust.
- **Validation:** Source and test inspection only. Tests were not executed; the process-cleanup test is POSIX-only.
- **Changes made:** None. File contents were treated as data.
- **Scope:** Only A1 / Required Change 1 was re-checked. Every earlier verified item remains verified.

## Findings

### Critical (blocking)

None. Earlier acceptance of corrections to blocking findings is retained.

### Moderate

**A1 — D11 did not substantiate its stated shutdown budget. Verified; closed.**

The revised D11 correctly distinguishes a nominal shutdown allowance from a proven upper bound.

The implementation supports the stated timing components:

- `JobTimings` defaults are 5 s soft stop, 2 s termination grace, 1 s probe, 2 s drain and 250 ms close settle (`supervisor.dart:436-442`).
- `close()` starts cancellation for every live job before awaiting their completed handoffs (`supervisor.dart:738-752`). Shutdowns overlap rather than consuming those waits serially across jobs.
- `_terminate()` shares the soft-stop window between the channel request and waiting for process exit. It discovers descendant groups before terminating the child, then signals descendant groups together (`supervisor.dart:988-1037`).
- Each remaining descendant group receives its own probe, with a fresh stopwatch. Successful probes can therefore accumulate; returning at the first failed probe does not impose a shared deadline (`supervisor.dart:1031-1034`, `1123-1128`).
- `_drain()` follows process exit. After its initial drain timeout and the pipe-completion-or-termination wait, open pipes can incur `closeSettle`, then a one-second cancellation timeout for each unfinished reader, followed by outstanding writes (`supervisor.dart:948-954`, `1237-1253`).

D11 now expressly accounts for both previously omitted paths. It describes descendant termination as the grace period plus individual probes, identifies up to one second per slow descendant group, and names the additional close-settle and reader-cancellation waits.

The nominal 13 s figure is accepted under its stated assumptions: killed groups vanish promptly and pipes close with their processes. It is a conservative allowance for the identified path, not a claim that every shutdown consumes exactly 13 s or that all supported paths fit within it. Slow groups, held pipes and untimed work remain outside that figure.

The line-client delta and ADR consistently qualify the 15 s grace as an allowance. The client defaults to 15 s and still kills an engine exceeding its grace (`client.dart:42`, `677-685`). D11, the delta and ADR acknowledge that a child not yet ended can survive this kill. Recovery settles or orphans records and does not signal surviving processes.

The concrete supervisor test retains meaningful coverage of the nominal scenario: real default timings, a child ignoring its soft stop and SIGTERM, a job in its own session, `supervisor.close()`, elapsed time at least the soft-stop duration and below the client’s default grace, and verification that the separate-session job is gone. `JobHarness.create()` defaults to `const JobTimings()`.

The client arithmetic test now explicitly describes the nominal path and excludes slow-to-die groups and held pipes. Its 13 s calculation supports the allowance comparison; it does not purport to prove a universal bound. The Test map references both tests.

**M1 — Unknown-window skill delivery contradicted the composer and overflow contracts. Previously verified; closed.**

Earlier verification is retained: D6 requires the composer’s null-capacity change, preserves known-capacity enforcement and the skill-file bound, and separates known-window overflow prevention from unknown-window delivery and provider-reported overflow.

**M4 — Typed agent results were not included in the specified crash-safe handoff. Previously verified; closed.**

Earlier verification of the post-intent handoff is retained, including typed-result descriptors, agent metadata, publication, registration/retry, settlement, recovery and rewind/orphan disposition.

The final pre-intent correction remains accepted:

- D11 excludes `result` from pre-intent adoption, whether partial or sealed.
- Recovery settles the job as cancelled/interrupted, records `result` in `absent`, and neither publishes nor references it.
- A surviving result spool is deleted and counted through `discarded`, with warning text `<n> agent results discarded before their handoff`.
- D11 distinguishes this reporting from `_leftovers()`, which excludes dot-prefixed spool files.
- Both `job wait` and `output` return interrupted text including the child-session identifier; the child is never relaunched.

The retained scenario covers complete and partial result files, deletion, no result reference, interrupted output through both interfaces, and the discarded-result count.

### Suggestions

**S2 — Relayed-prompt bound and cancellation qualification. Previously verified; closed.**

Earlier verification of the 32-prompt bound and the foreground-child qualification in “Prompt withdrawn on cancel” is retained.

**Amendment consistency and testability — verified.**

The delta preserves the interrupt scenario, specifies the 15 s stuck-engine behavior, and retains the concrete stubborn-child scenario with a job in its own session. D11, the delta, ADR and arithmetic-test explanation consistently treat the timing as a qualified allowance.

The tests cover the identified ordinary shutdown scenario and the default-duration comparison. They do not establish a universal shutdown bound, and the revised explanation no longer requires them to.

The earlier conclusion about historical 5 s references is retained: the main line-client specification is the baseline replaced by this delta, archived artifacts remain historical, and other 5 s soft-stop references concern a different timer.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

Required Change 1 is correctly applied and verified. Both remaining timing gaps are addressed, and the documentation and test explanation consistently qualify the shutdown allowance. All earlier finding closures remain accepted.

## Required Changes

1. **Correct and substantiate the shutdown budget in D11, then align the delta and ADR with it. Verified; complete.**
   - Account for cumulative successful descendant probes, each with its own one-second deadline.
   - Account for additional `closeSettle` and reader-cancellation waits after the initial drain timeout.
   - Describe 13 s as a nominal allowance under explicit assumptions, rather than the complete timed shutdown bound.
   - Align the delta, ADR and arithmetic-test explanation with that distinction.
   - Retain the 15 s stuck-engine behavior, over-budget survivor qualification, recovery limitation and concrete default-timing shutdown test.

2. **Historical Required Change 1 / M1 — verified; retained.**
   - Unknown-capacity `notrunc` composition is explicitly permitted while preserving the skill-file bound.
   - Known-capacity rejection and the distinction between prechecked and provider-reported overflow remain accepted.

3. **Historical Required Change 2 / M4 — verified; retained.**
   - Typed-result descriptors and terminal metadata are included throughout the recoverable handoff.
   - Publication, registration/retry, settlement, recovery and rewind/orphan disposition remain accepted.
   - Pre-intent surviving result spools are deleted and accurately reported through `discarded`, without relaunching the child.

CHANGES_APPLIED: yes

## Rebuttals

- **Required Change 1 / A1 → shutdown budget:** **Verified; accepted by reviewer.** D11 now accounts for cumulative successful descendant probes and the close-settle and reader-cancellation waits after drain. It explicitly limits 13 s to a nominal path with prompt group disappearance and pipe closure, and describes 15 s as an allowance rather than a proven bound. The delta, ADR and client arithmetic-test explanation align. The accepted over-budget behavior, survivor qualification, recovery limitation and concrete POSIX default-timing shutdown test are retained.

- **Historical Required Change 1 / M1 → D6 and skills scenarios:** Verified; accepted by reviewer. Earlier verification retained without reopening.

- **Historical Required Change 2 / M4 → post-intent handoff:** Verified; accepted by reviewer. Earlier verification of descriptors, metadata, publication, registration/retry, settlement, recovery and orphan disposition retained.

- **Historical Required Change 2 / M4 → pre-intent surviving result:** Verified; accepted by reviewer. D11 requires deleting the uncommitted result spool and reporting it through `discarded`, independently of `_leftovers()`. The matching scenario covers partial and sealed results, deletion, no result reference, interrupted output from both job interfaces, and one discarded agent result.

- **S2 → prompt cancellation and Resource Bounds:** Verified; accepted by reviewer. Earlier verification retained.

- **C1 → D8 and “Parent follows the child’s state”:** Prior Round 2 acceptance retained. Snapshot replacement, terminal-state reconciliation and the distinct output-line bound remain closed.

- **C2 → D15 and containment scenarios:** Prior Round 2 acceptance retained. Read-time resolved-root containment and credential refusal remain closed.

- **M1 → D16 baseline accounting:** Prior Round 2 acceptance retained. Instructions-identity invalidation remains closed.

- **M2 → D10 and background-child scenario:** Prior Round 2 acceptance retained. Foreground cancellation and background-prompt preservation remain closed.

- **M3 → D4 and child-engine requirement:** Prior Round 2 acceptance retained. Captured role identity and text remain closed.

- **S1 → proposal Impact and design Context:** Prior Round 2 acceptance retained. Context layout and installed-skill inventory remain closed.