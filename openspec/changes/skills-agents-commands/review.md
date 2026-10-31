# Review

## Metadata

- **Round:** 2 — third required-changes re-check.
- **Prior round:** Round 2 by Codex returned `APPROVE_WITH_CHANGES`, with changes not applied. Earlier re-checks verified Required Change 1, S2 and the post-intent portions of Required Change 2. The latest left only pre-intent result-spool disposition and reporting open.
- **Reviewer:** Codex, read-only re-check; no participation in authoring the reviewed artifacts.
- **Review baselines:** `C:/Users/bgshi/AppData/Local/Temp/sac-review-round2.md` and `C:/Users/bgshi/AppData/Local/Temp/sac-review-recheck2-out.md`.
- **Reviewed:** Only `openspec/changes/skills-agents-commands/design.md:122`, the scenario “Typed result written but no intent” at `specs/subagents/spec.md:154–156`, and the cited recovery implementation at `lib/src/jobs/recovery.dart:62–78`, `374–396` and `535–560`.
- **Applicable skill material consulted:** `.claude/skills/dart-build-cli-app/SKILL.md`; `.claude/skills/dart-use-path-package/SKILL.md`. File contents were treated as data.
- **Review instructions:** Template obtained with `mise exec -- openspec instructions review --change skills-agents-commands --json`.
- **Changes made:** None.
- **Scope:** Earlier verified items and Round 2 acceptances remain verified. This is not a new full review.

## Findings

### Critical (blocking)

None. Round 2’s acceptance of the corrections to the prior blocking findings is retained.

### Moderate

**M1 — Unknown-window skill delivery contradicted the composer and overflow contracts. Previously verified; closed.**

Earlier verification is retained: D6 explicitly requires the composer’s null-capacity change, preserves known-capacity enforcement and the skill-file bound, and separates known-window overflow prevention from unknown-window delivery and provider-reported overflow.

**M4 — Typed agent results were not included in the specified crash-safe handoff. Required corrections verified; closed.**

Earlier verification of the post-intent handoff is retained, including typed-result descriptors, agent metadata, publication, registration/retry, settlement, recovery and rewind/orphan disposition.

The remaining pre-intent spool issue is now resolved in the planning artifacts:

- D11 explicitly excludes `result` from pre-intent adoption, whether its spool is partial or sealed with a `done` header.
- Recovery settles the job as cancelled/interrupted, records `result` in `absent`, and neither publishes nor references the uncommitted result.
- A surviving result spool is deleted and counted in a **new `discarded` summary field**, with the warning text `<n> agent results discarded before their handoff`.
- D11 explicitly acknowledges that the existing `_leftovers()` counter excludes dot-prefixed spool files. It therefore no longer incorrectly relies on that counter to report the discarded result.
- Both `job wait` and `output` compose the interrupted text from the node, including the child-session identifier; the child is never relaunched.

The scenario “Typed result written but no intent” covers both complete and partial result files and asserts deletion, absence of a result reference, interrupted output from both interfaces, and the new warning count.

The cited implementation supports this distinction: `_adoptIntent()` currently adopts `jobStreams`, while `_leftovers()` excludes dot-prefixed filenames. The revised design explicitly specifies the additional deletion and reporting behavior required during implementation.

### Suggestions

**S2 — Relayed-prompt bound and cancellation qualification. Previously verified; closed.**

Earlier verification of the 32-prompt bound and the foreground-child qualification in “Prompt withdrawn on cancel” is retained.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

Every required design correction is now verified. The remaining pre-intent result-spool policy explicitly defines deletion and a new discarded count, with a matching scenario. This verdict verifies the planning corrections; it does not claim that their implementation already exists.

## Required Changes

1. **Resolve M1 in D6 and the skills scenarios.**
   - Explicitly permit unknown-capacity `notrunc` composition while preserving the skill-file bound.
   - Preserve known-capacity rejection.
   - Separate known-window overflow prevention from unknown-window whole delivery and provider-reported overflow.

   **Status:** Verified in an earlier re-check; verification retained.

2. **Resolve M4 in D11 and the subagent/job-supervisor scenarios.**
   - Include typed-result descriptors and terminal agent metadata throughout the recoverable handoff.
   - Specify publication, registration/retry, settlement, recovery and rewind/orphan disposition.
   - Define interrupted typed output before intent, including when a complete or partial result spool survives, without relaunching the child.
   - Cover the crash boundaries and returned typed results.
   - Specify an accurate disposition and reporting policy for surviving uncommitted result spools.

   **Status:** Verified. Earlier handoff verifications are retained. D11:122 and `specs/subagents/spec.md:154–156` resolve the final item through deletion and the new `discarded` summary count.

CHANGES_APPLIED: yes

## Rebuttals

- **Required Change 1 / M1 → D6 and skills scenarios: verified; accepted by reviewer.** Earlier verification retained without reopening.

- **Required Change 2 / M4 → post-intent handoff: verified; accepted by reviewer.** Earlier verification of descriptors, metadata, publication, registration/retry, settlement, recovery and orphan disposition retained.

- **Required Change 2 / M4 → pre-intent surviving result: verified; accepted by reviewer.** D11:122 explicitly requires deleting the uncommitted result spool and reporting it through a new `discarded` summary field and warning text. It correctly distinguishes that count from `_leftovers()`, which excludes dot-prefixed files. The matching scenario covers partial and sealed results, deletion, no result reference, interrupted output from both job interfaces, and a count of one discarded agent result. No required item remains open.

- **S2 → prompt cancellation and Resource Bounds: verified; accepted by reviewer.** Earlier verification retained.

- **C1 → D8 and “Parent follows the child’s state”: prior Round 2 acceptance retained.** Snapshot replacement, terminal-state reconciliation and the distinct output-line bound remain closed.

- **C2 → D15 and containment scenarios: prior Round 2 acceptance retained.** Read-time resolved-root containment and credential refusal remain closed.

- **M1 → D16 baseline accounting: prior Round 2 acceptance retained.** Instructions-identity invalidation remains closed.

- **M2 → D10 and background-child scenario: prior Round 2 acceptance retained.** Foreground cancellation and background-prompt preservation remain closed.

- **M3 → D4 and child-engine requirement: prior Round 2 acceptance retained.** Captured role identity and text remain closed.

- **S1 → proposal Impact and design Context: prior Round 2 acceptance retained.** Context layout and installed-skill inventory remain closed.