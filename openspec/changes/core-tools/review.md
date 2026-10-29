# Review

## Metadata

- **Round:** 11 (re-check)
- **Prior rounds:** rounds 1-9 REVISE (C1, C2, M1-M18, S1, all resolved per round 10); round 10 REVISE: M19 unbounded pipe wait; round 11 APPROVE_WITH_CHANGES: M20 timing and handoff conditions (all codex)
- **Reviewer:** cross-model CLI (codex)
- **Reviewed:** Only the two round-11 Required Changes against D8’s “Exit” bullets “Bounded drain,” “Forced close,” “Bound” and “Natural exit with a forced close” in `openspec/changes/core-tools/design.md`.

## Findings

### Critical (blocking)

None.

### Moderate

**M20. Resolved.**

[“Bounded drain”](F:/Dev/Orca/Workspace/kehai/openspec/changes/core-tools/design.md:198) explicitly starts D10 termination after the initial 2-second drain, overlaps the second 2-second drain with termination’s grace, force-closes remaining readers at that interval’s end, and permits only the documented probe afterward. Cancellation and deadline reuse their running termination sequence without another grace period.

[“Natural exit with a forced close”](F:/Dev/Orca/Workspace/kehai/openspec/changes/core-tools/design.md:201) permits handoff once process exit is observed and each pipe has either reached EOF or completed forced reader closure. It explicitly preserves incomplete flags and cleanup uncertainty through handoff. Both Required Changes are applied.

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

None remaining.

CHANGES_APPLIED: yes

## Rebuttals

- **M20’s timing concern is addressed:** the second drain overlaps D10’s grace, making the stated bound achievable.
- **M20’s handoff concern is addressed:** completed forced reader closure satisfies the pipe condition, with incomplete flags and cleanup uncertainty preserved.