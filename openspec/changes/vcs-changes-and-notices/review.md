# Review

## Metadata

- **Round:** 14
- **Prior round:** round 13 APPROVE_WITH_CHANGES, CHANGES_APPLIED: no
- **Reviewer:** cross-model CLI (claude)
- **Files actually read:**
  - `openspec/changes/vcs-changes-and-notices/review.md` (round 13, all of it).
  - `design.md:40-239`: D2 tail to D9, the diagrams, State & Ownership (`:155-172`), Failure & Visibility, Resource Bounds, and Flow & State Gaps, including the late-finish (`:223`) and crash-around-rewind (`:224`) edge cases.
  - `specs/workspace-change-attribution/spec.md:160-219`, plus a grep of the file for preservation and finish terms.
  - `tasks.md:60-159`: scenario map rows, groups 1–3 and the start of group 4.
  - `docs/adr/0017-vcs-observation-baselines-and-provenance-attribution.md`, all of it.
  - I did not re-read writer or state source. The M2 check relies on the `state.dart` behaviour that round 13 cited (`:136`, `:159`, `:164`). Nothing in this round's corrections contradicts it.
  - I tried to read the `codebase-design` skill (`C:/Users/bgshi/.agents/skills/codebase-design/SKILL.md`), but it was outside the restricted workspace and I could not read it.
- **Scope:** recheck of round-13 M1 and M2 and the compatible suggestions S1, S2, S4 and S5. This is not a broad audit. I ran no tests, builds, linters or formatters. These are design contracts, not claims that the implementation is complete.

## Findings

### Critical (blocking)

None.

### Moderate

None. Both prior Required Changes are applied correctly.

**M1, finish of writer-preserved records: applied.**
- **D4 (`design.md:53`):** "Every run's finish also checks at the writer queue head for an unfinished orphan record owned by this session and finishes it, whether its quiescence merge was accepted or refused. This includes records the writer preserved for a surviving call."
- **`design.md:54`:** adds that the finish "raises `seqHigh`, and retires the registry entry only after the required records are durable and before the queue advances". This matches the required ordering: the record is retained until it is durable, and retirement is serialized inside the finish's queue operation.
- **State & Ownership row `meta/orphanedMutations/<runId>` (`design.md:165`):** adds "every run's finish checks and finishes its owned record regardless of quiescence-guard outcome".
- **ADR 0017 (`:54`):** carries the same contract, including the surviving-call case and retirement after durability.
- **Spec scenario "Rewind removes the target but retains the call" (`spec.md:200-202`):** now requires the record to carry `finishedSeq` after the run finishes even though the call survived. It also requires that a baseline captured after the finish no longer applies the record. Together these cover the eventual finish and the behaviour of later baselines.
- **Tasks:** map row `tasks.md:81` ("surviving call's preserved record is finished when its run ends", `orphaned_mutation_test.dart`, `red`). The finish bullet of task 3.3 (`:149`) and its verification (`:153`, "finish of a surviving call's preserved record") match.
- **Bound:** "Live: within the 16-run cap" (`design.md:210`, ADR `:60`) holds again. A live record can now outlast its run only until that run's own finish operation, and that operation also retires the registry slot.

**M2, preservation record turn: applied.**
- **D4 (`design.md:54`):** "The writer builds the rewind record once at the current turn, validates it before writing anything … Preservation records carry the rewind record's current turn and cannot advance it."
- **ADR 0017 (`:50`):** says the same, and adds "cannot invalidate the prepared cut".
- **The fix is consistent with the commit semantics round 13 cited.** A `meta` record at `_turn` leaves `_turn` unchanged, so the rewind validated beforehand still passes `_validateRewind`'s exact-turn check.
- **New spec scenario "Preservation does not advance the rewind turn" (`spec.md:204-206`):** asserts that the once-built, pre-validated rewind commits and that `currentTurn` is unchanged.
- **Tasks:** map row `tasks.md:82`. The first bullet of task 3.3 (`:147`) and its verification (`:153`) both name this.

### Suggestions

The compatible clarifications are present and consistent:

- **S1, idempotent preservation:** applied at `design.md:54` ("Existing records are retained without clearing `finishedSeq` or appending redundant preservation"), ADR `:50` and task 3.3 (`:147`).
- **S2, guarded publication:** applied at `design.md:54` ("published inside the accepted guarded append's queue-head decision … refused targets are not published") and ADR `:52`.
- **S4, fork run-id deduplication:** applied at `design.md:54` and ADR `:52`.
- **S5, tree/registry union:** applied at `design.md:53` ("unioned with the unfinished-run registry"), `:163`, `:223` and ADR `:44`.

Optional, non-blocking:

- **S6. State what happens to the registry when the finish write cannot be appended.** Retirement waits for the finish records to be durable. A finish that meets a broken or closing writer therefore keeps its registry entry, and with it a cap slot, until the engine exits. That is conservative and consistent with "Open targets are never evicted" and with recovery finishing own records on resume. One clause in D4 or Failure & Visibility would stop an implementer from releasing the slot on a failed append.
- **S7. Wording consistency.** `design.md:53` still says "When an orphaned run's future finishes, the runtime merges `finishedSeq`". The State & Ownership row for `seqHigh` (`:167`) says "runtime/recovery on record finish". Both remain accurate because the runtime submits through the writer's queue head. Adding "through the writer's finish operation" in either place would match `:54`.
- **S8. Round-13 S3, the double replay,** remains open. It is an acceptable O(timeline) cost.

## Verdict

M1 and M2 are applied in D4, State & Ownership, ADR 0017, the spec scenarios, the scenario map and task 3.3, and are verified there:

- Every finish now finishes its own unfinished orphan in the writer's queue operation, whatever the quiescence guard decides. It raises `seqHigh` and retires the registry entry only after the records are durable and before the queue advances.
- Preservation records are stamped with the turn of a once-built, pre-validated rewind. That rewind is required to commit with `currentTurn` unchanged.

The compatible clarifications (S1, S2, S4 and S5) are consistent with the existing contracts. They introduce no new mechanism or journal format, and no exception to specified behaviour.

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

None outstanding. The round-13 Required Changes 1 (M1) and 2 (M2) are correctly applied. S6–S8 are optional.

CHANGES_APPLIED: yes

## Rebuttals

None.