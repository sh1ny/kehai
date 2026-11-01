# Review

## Metadata

- **Round:** 2 (fresh-context FULL-tier design review and Required Change 1 recheck).
- **Prior round:** Round 1 approved with changes: specify an executable, delivery-revision full-suite GitHub Actions gate, distinct from ordinary PR CI.
- **Reviewer:** Fresh-context Kehai `specwright-reviewer` subagent; model `gpt-6.1-sol`; reasoning level unknown. No external reviewer CLI used.
- **Reviewed:** Current `openspec/changes/dogfood-first-m2-change/{proposal.md,specs/reasoning-effort/spec.md,design.md,tasks.md,review.md}`; `docs/adr/0013-reasoning-effort-selection-and-inheritance.md`; `openspec/architecture.md`; constraining ADRs 0001, 0008, 0011 and 0012; `lib/src/cli/rpc_command.dart:81–256`, `lib/src/loop/driver.dart:529–656`, `lib/src/loop/request_builder.dart:145–224`, `lib/src/tools/agent.dart:1–80,97–208`; `test/client/effort_process_test.dart`; `.github/workflows/{ci.yml,nightly.yml}`; task amendment in commit `810badf0ae2726fefd6255ef863da4881d784864`. Obtained review instructions/template and planning root through pinned `mise exec -- openspec`; context reported no referenced stores or unresolved references.
- **Review guidance:** Loaded all four requested installed `.claude/skills/` guidance skills: `dart-build-cli-app`, `dart-add-unit-test`, `dart-run-static-analysis`, and `dart-write-documentation`. No named skill failed to load. Used for review guidance only.
- **Scope:** Design review/recheck, not pre-ship review or implementation acceptance. Test and quality-check receipts were read, not rerun. No test, analyzer, formatter, fix, commit, authenticated operation, or artifact/code edit was performed. Only this allocated scratch review was written.

This verdict covers only the contents reviewed. Subsequent proposal/spec/design edits outside application of Required Changes (or an edit confined to proposal Release Notes) invalidate it.

## Findings

### Critical (blocking)

None.

### Moderate

None outstanding. Prior finding M1 is resolved by the current task and design evidence.

The workflow distinction is independently confirmed: ordinary CI runs on PRs/main with Linux and Windows matrix jobs, but its test command excludes `slow` (`.github/workflows/ci.yml:5–8,25–26,60–61`). Nightly supports manual dispatch, checks out the selected ref through the existing checkout action, and runs unfiltered `dart test` on both platforms (`.github/workflows/nightly.yml:4–7,19–28,43–44`). Thus the specified manual branch dispatch is an existing executable mechanism, not an assumed PR check or a new workflow dependency.

Current task 5.2 (`tasks.md:48`, amended in `810badf`) now requires both ordinary Linux/Windows PR CI and a manually dispatched Nightly full-suite run against the delivery branch/revision before merge. It requires the full-suite run URL, verified head SHA, both matrix outcomes, and repeat qualification if later changes invalidate the tested revision. It explicitly leaves both gates pending and preserves the local full-suite prohibition and separate single-file `-j 1` policy.

The current design evidence agrees (`design.md:207,231`): ordinary PR CI alone is insufficient; the Nightly checkout SHA must be verified; scheduled default-branch results do not qualify the delivery revision; both remote gates remain pending. No remote run is necessary for this design approval, and none is claimed here.

### Suggestions

None requiring additional design changes or mechanisms.

The reviewed feature design remains coherent with the spec and ADR 0013: startup owns one immutable nullable scalar rather than historical policy; driver admission records explicit effort/null before request construction (`rpc_command.dart:134–147,193–213`; `driver.dart:550–569`); estimates and final requests use the same builder input, and retries reuse the built request (`request_builder.dart:179–185,199–213`; `driver.dart:586–599`). Child argv pins either a selected value or explicit provider-default inheritance rather than reselecting from changed configuration (`agent.dart:50–65`). This adds no second durable writer, side store, effort-specific retry, capability registry, or nested-agent authority. The constant-size propagation and per-step field have clear ownership and bounded incremental cost.

The integration source asserts actual parent/child wire values and replayed step fields, config-edit resistance, role-model independence and exclusion of `agent` from the child's tools (`test/client/effort_process_test.dart:88–181`). This supports the planned qualification seam, not a claim that these tests passed during this review. The evidence correctly keeps fake reviewer execution distinct from design approval, targeted local receipts distinct from full-suite success, and remote/platform/milestone acceptance outstanding.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. **Applied and independently rechecked:** Prior Required Change 1 requested an explicit delivery-revision full-suite Actions gate in task 5.2 and the corresponding design evidence. `tasks.md:48` and `design.md:207,231` now require successful ordinary Linux/Windows PR CI plus manual Nightly full-suite qualification on the delivery revision, with run URL, verified checkout/head SHA, both platform outcomes, and rerun on invalidating changes. Both gates remain pending; local full-suite execution remains prohibited and local test files remain separate `-j 1` calls. This satisfies the prior required edit in full. No additional required design edits remain.

CHANGES_APPLIED: yes

## Rebuttals

Prior M1 / Required Change 1: fixed in the current task and design evidence; accepted by reviewer after checking both descriptions against the actual CI/Nightly workflows. This closes the design condition only. It does not discharge the future remote full-suite gate, pre-ship review, PR/archive/merge gates, or Nikolay's user-verified milestone acceptance.
