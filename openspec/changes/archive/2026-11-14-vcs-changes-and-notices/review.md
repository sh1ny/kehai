**Review round 21: vcs-changes-and-notices, D10 (instruction guidance and identity amendment)**

## Metadata

- **Round:** 21. The previous review (round 20) approved D1–D9 and the unresolved-attempt boundary/index design. Those decisions are not reopened here.
- **Scope:** only the user-approved D10 contract. That contract updates the built-in perception guidance, advances the internal version from `kehai-3` to `kehai-4`, and accepts that old native opaque lineage will no longer be compatible. It keeps the existing rejection guard and the rewind-or-new-session recovery. There is no migration, fallback, package bump, tool-identity change or RPC/journal change.
- **Mode:** read-only. I ran no tests, builds, lint or formatters, edited nothing and ticked no tasks.
- **Files read:**
  - `openspec/changes/vcs-changes-and-notices/review.md` (round 20 structure and verdict sections)
  - `openspec/changes/vcs-changes-and-notices/proposal.md:35-64` (Impact and Release Notes)
  - `openspec/changes/vcs-changes-and-notices/design.md:85-110` (D9, D10) and `:295-325` (ADRs, apply notes)
  - `openspec/changes/vcs-changes-and-notices/tasks.md:170-205` (end of group 4, group 5, group 6, follow-up)
  - `docs/adr/0017-vcs-observation-baselines-and-provenance-attribution.md:10` (context) and `:100-111` (built-in guidance decision)
  - `.dart_tool/vcs-review-skills/codebase-design.md` (whole file)
  - `lib/src/loop/instructions.dart:1-40` and the `composeInstructions` definition at `:80-89`
  - `lib/src/loop/request_builder.dart:205-249`, `:290-311`, `:535-569`
  - `test/loop/compaction_budget_test.dart:180-260`
  - Repo-wide grep for `kehai-3`, `instructionsVersion` and `_lineage(`

## Findings

### The D10 contract is consistent across all artifacts

- `proposal.md:45` (Impact) and `:63` (Release Notes → Changed) say the same things: version becomes `kehai-4`, the digest changes, old native opaque history is rejected by the unchanged guard, recovery is rewind or a new session, and there is no migration, fallback or package bump. Tool identity is unchanged. The earlier claim that identity would stay unchanged is gone.
- `design.md:95-100` (D10) states the choice, compatibility, rejected alternative and verification. It is cross-referenced from the ADR list (`design.md:304`, 0015 "guard unchanged; D10 intentionally changes instruction identity") and from the apply notes (`design.md:324`, which records the user's approval).
- ADR 0017 `:10` says native continuity compatibility *rules* stay unchanged, while the guidance intentionally changes *identity*. That matches D10. `:104-106` repeats the full contract, including "do not … preserve the old digest or fall back to an older boundary".
- `tasks.md:193` (5.3) covers it all: guidance edit, `kehai-4`, documenting the lineage break and recovery, no migration or package bump, and rerunning the regression.
- D9's permissions/config/instruction-loading friction stays out of scope, both in D10's Rejected paragraph and in the apply notes at `:318`.

### Feasibility against the source holds

- **Version rule:** `instructions.dart:4-8` requires changing `instructionsVersion` whenever `builtInInstructions` changes. D10 follows that rule rather than working around it.
- **Digest input:** `composeInstructions` (`instructions.dart:85-86`) starts from `builtInInstructions`. `RequestBuilder` digests that composed text in `_lineage` (`request_builder.dart:231-235`), both on the build path (`:303-308`) and in `requestLineage` (`:220-228`). Editing the guidance therefore changes `lineage.instructions`, as D10 says. No code change is needed for that to happen.
- **Guard:** `request_builder.dart:546-563` throws `incompatible continuity; rewind before boundary or start a new session` for any compaction or reasoning entry in the selected suffix whose lineage differs, provided there is a boundary or recorded lineage. It does this before composing items, so before any provider request. That matches D10's "stops before a provider request" and "no older-boundary fallback"; the code comment at `:547` says the same. Text-only entries are not checked, which supports "Text-only history continues through the existing request rebuilding path".
- **Regression coverage:** `compaction_budget_test.dart:187-254` changes `AGENTS.md` context bytes. That changes the composed instruction text, and so the same `_lineage` digest that a built-in guidance edit would change. The test asserts `state == 'stopped'`, that the reason contains `incompatible continuity`, and that `changed.requests` is empty (`:250-253`). So the digest-mismatch path D10 depends on is covered without a source-text or bare-constant test.
- **Blast radius of the version bump:** every reference outside `instructions.dart` uses the `instructionsVersion` symbol rather than a literal. That covers `request_builder.dart:298`, `driver.dart:743`, `test/support/loop_support.dart:47`, `compaction_budget_test.dart:275`, `request_builder_test.dart:619` and `driver_test.dart:591`. The only `kehai-3` literal in active code is the constant itself; the other matches are in the change's design docs and archived changes. Advancing to `kehai-4` should not break any existing assertion.
- **Budget:** D10's verification note that the larger constant text goes through the existing budget convergence is consistent with `estimateRequest` estimating the whole request (`request_builder.dart:214`). No new budgeting mechanism is implied.

### Design-vocabulary check (codebase-design)

D10 adds no new seam, adapter or interface. The instruction text and its version stay one module behind `composeInstructions`/`instructionsVersion`, and the guard stays local to `RequestBuilder`. There is no depth or locality concern.

### Critical (blocking)

None.

### Moderate

None.

### Suggestions (optional, not required)

- **S1.** Task 5.3 and D10 call the regression "the existing changed-instructions native-continuity rejection regression". Its actual name is `reuses calibrated usage after context metadata changes` (`compaction_budget_test.dart:187`). Naming it, or citing `:246-253`, would make the 5.3 evidence easy to trace.
- **S2.** Changing `instructionsVersion` also changes the `InstructionsIdentity` passed to `_conversation` (`request_builder.dart:297-301`). Text-only sessions that cross the bump may therefore lose compatible-usage calibration once and fall back to estimates. That is existing behaviour and doesn't conflict with D10. The 5.3 README note could mention it alongside the rewind-or-new-session recovery, but this is not required.
- **S3.** Round-19 S1–S4 are still optional and not adopted (carried forward unchanged).

## Verdict

D10 is consistent across the proposal, design, ADR 0017, the apply notes and task 5.3. It can be implemented with today's code: bump one constant symbol and edit the guidance text. The digest change and the pre-request rejection follow from existing code paths, and an existing regression covers them. Nothing contradicts the user's chosen rollout policy.

VERDICT: APPROVE

## Required Changes

None.

CHANGES_APPLIED: n/a

## Rebuttals

None. No earlier required changes were open for this scope.