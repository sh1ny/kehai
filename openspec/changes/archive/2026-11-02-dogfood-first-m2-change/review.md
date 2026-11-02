# Review

## Metadata

- **Round:** 4.
- **Prior round:** Round 3 approved with changes; Required Change M1 reconciled the remaining review-routing policy contradictions.
- **Reviewer:** Fresh-context isolated Codex reviewer; model and reasoning level not independently verified.
- **Reviewed:** Current proposal, reasoning-effort spec, FULL-tier design, tasks and round-3 review; refreshed instructions/template; `AGENTS.md`; `openspec/config.yaml`, `openspec/roadmap.md`, `openspec/specwright.yaml`, `openspec/architecture.md`; ADR 0013; relevant CLI, RPC startup, request-builder, driver, child-launch and engine-command boundaries; requested test-source boundaries; CI and Nightly workflows; policy amendment commit `d9aca34159ce908f9e046a6233336b07efd42245`.
- **Review guidance:** Installed `.agents/skills/{dart-build-cli-app,dart-add-unit-test,dart-use-path-package,dart-write-documentation}/SKILL.md`, plus reviewer workflow instructions.
- **Scope:** Independent recheck of M1 and coherence with owner-approved D5, proposal and tasks. Read-only inspection; no tests, formatting, analysis, fixes, writes, authenticated operations or pub-cache access.

This verdict covers only the reviewed contents. Subsequent proposal/spec/design edits invalidate it except application of Required Changes or edits confined to proposal Release Notes.

## Findings

### Critical (blocking)

None.

### Moderate

None outstanding. Round-3 M1 is fully applied.

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. **M1 — Applied and independently rechecked.** Both `openspec/config.yaml`’s dogfood design rule and `openspec/roadmap.md`’s M1 entry 6 now:
   - Retain Kehai as lifecycle orchestrator.
   - Permit configured external reviewer CLIs through validated Specwright routing.
   - Retain repository-wide cross-model review and required pre-ship review.
   - Describe earlier internal-only reviews as historical delivery-only evidence.
   - Require successful Linux/Windows delivery PR CI and manually dispatched delivery-head Nightly before archive/merge.

The current text matches commit `d9aca34159ce908f9e046a6233336b07efd42245` and is coherent with amended D5, the proposal, tasks, `AGENTS.md`, and `review.cross_model: true` / `review.preship: true`. No further edit is required for M1.

CHANGES_APPLIED: yes

## Rebuttals

**M1: fixed; accepted by reviewer.** The two active policy sources no longer instruct future continuations to disable cross-model review or prohibit external reviewer CLIs launched by Kehai.

The inspected feature boundaries remain coherent with the design: startup resolves one immutable nullable effort, request construction and step admission use it, and child argv pins either the selected value or inherited provider default. This policy amendment introduces no additional runtime mechanism.

CI excludes slow tests; manually dispatchable Nightly runs the unfiltered suite on Linux and Windows. Workflow inspection establishes available qualification paths only. This design recheck establishes no successful CI/Nightly receipt, final-head pre-ship pass, archive, merge or Nikolay’s user-verified milestone acceptance.