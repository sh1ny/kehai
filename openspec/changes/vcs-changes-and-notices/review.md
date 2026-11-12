# Review

## Metadata

- **Round:** 20. The last valid review was round 19: APPROVE, no required changes.
- **Reviewer:** cross-model CLI (claude)
- **Scope:** I checked only two things:
  - the user-approved `targetAfterSeq` boundary for unresolved attempts;
  - the derived quiescence-turn/step-link index that group 4 needs.

  This was not a broad audit. I ran no tests, builds, linters or formatters, implemented nothing and ticked no tasks. The boundary and index source isn't implemented yet, so I only checked whether it can be built on the current source.
- **Files actually read:**
  - `openspec/changes/vcs-changes-and-notices/review.md` (round 19, all of it)
  - `design.md:38-67` (D2–D5, including the D4 sections **Unresolved-attempt boundary** and **Derived interval index**), `:155-188` (persisted shapes, State & Ownership), `:250-317` (ledger, risks, ADRs, apply notes)
  - `specs/workspace-change-attribution/spec.md:85-124` and `:265-315`
  - `tasks.md:1-75` (test map) and `:140-189` (groups 3 and 4)
  - `docs/adr/0017-vcs-observation-baselines-and-provenance-attribution.md:36-85`
  - `.dart_tool/vcs-review-skills/codebase-design.md`
  - Source: `lib/src/session/writer.dart:300-528` (`applyGuarded`, `recordMutationEffect`, `finishMutation`), `lib/src/tools/runtime.dart:839-942` (`_recordMutationTarget`, `_recordMutationEffect`, `_trackMutationRun`), `lib/src/tools/edit.dart:60-139`, `lib/src/tools/write.dart` (all of it)
  - Greps of the change directory for `targetAfterSeq|quiescedTurn|quiescence`, and of `lib/src` for the mutation/lock call sites

## Findings

### The ordering proof holds against the current source

1. **Target, rename and effect run under one lock.** `edit.dart:82` and `write.dart:33` enter `PathLocks.run(target, …)` before calling `mutation.target(target)` (`edit.dart:129`, `write.dart:52`). They then do the rename and await `mutation.effect` while still holding the lock. So for one lock key, the accepted target append, the rename and the effect commit all happen inside one lock span.

   This matters because the opposite order would break the rule. If the target were recorded before taking the lock, the earlier holder's effect could commit with a sequence above the waiter's boundary, and then the waiter's cancelled rename would land after it. That would produce a false `agent`. The current order rules this out.

2. **The boundary can be read in the existing target append.** `_recordMutationTarget` (`runtime.dart:851-875`) already decides inside `applyGuarded`, whose `build` gets a `GuardedRead` over acknowledged state at the queue head (`writer.dart:370-398`). Reading `meta/vcs/seqHigh` there and adding `targetAfterSeq` to the same `{'target': …}` merge needs:
   - no new queue operation;
   - no reservation (no `sequence.reserve()`);
   - no extra flush.

   It is also the same build that already calls `mutations.publish`, so registry publication and the boundary come from one queue-head decision.

3. **An earlier committed effect is at or below a later target's boundary.** `recordMutationEffect` (`writer.dart:427-452`) runs as a single queue `action`: it raises the counter from durable `seqHigh`, reserves, appends `meta/vcs {seqHigh: seq}`, then appends the effect. No other queue decision can run between those two appends. So any target decided later reads `seqHigh ≥ e`, and `e > boundary` is false, which blocks the proof. That is the required outcome for the "successful B, then cancelled A, then user restores B" case.

4. **An effect committed after a target decision is above its boundary.** That later effect raises the counter from durable `seqHigh`, which is at least the boundary, and then reserves above it. The in-memory counter running ahead because of unused capture reservations only makes the gap bigger. It can never make the effect's sequence equal to or below the boundary. Within one lock key, any effect committed after T's target decision belongs to a later lock holder, so its rename came after T's. "Effect sequence greater than the boundary" therefore means "mutated after T", and the "cancelled A, then successful B" case can read `agent`.

5. **Zero-when-absent is sound.** Every effect raises `seqHigh` before committing, and fork copies `meta`. So an absent counter means no sequenced effect exists in this lineage, and any later effect reserves at least 1. A rewind never lowers `seqHigh` (meta is rewind-exempt).

6. **Missing means unestablished.** This is stated the same way in D4 (`design.md:56`), the ADR (`:46`) and the requirement (`spec.md:302`), and scenario `spec.md:312-314` covers it. Calls recorded under group 3's target-only append fall into this conservative case, which is acceptable.

7. **The existing masks still win.** D4 `:56` and ADR `:46` keep open/orphan/foreign, floor/overflow and case-alias uncertainty above effect proof.
   - **Superseded attempts:** a new attempt on the same node overwrites `targetAfterSeq`, but supersession already preserves an orphan record for the old run, so that run stays masked.
   - **Case variants:** these keep separate lock tails, so the per-key proof doesn't hold for them. They are already forced to `unknown` by the case-alias rule.

### The derived index lifecycle is consistent and feasible

8. **Late quiescence is covered.** `finishMutation` already records `quiescedTurn` (`writer.dart:485`). Indexing calls by that turn is what makes late quiescence findable: a scan of only the interval steps' call outputs would miss a call whose `quiesced` record lands in a later turn. The index sits alongside the open-key set and is rebuilt on resume and rewind (D4 `:57`, ownership row `:178`, ADR `:48`, task 4.2 `tasks.md:177`).

9. **The publish/retire gap is closed.** `finishMutation` appends quiescence and the orphan finish, then calls `retire(_state.get)` synchronously at the end of the same queue action (`writer.dart:524-526`).
   - A capture that freezes the tree while those appends are awaited can see `quiesced: true` before the index entry exists.
   - The unfinished-run registry still holds that run until `retire`, so the frozen union reads its target as open (`unknown`).
   - Updating the index inside that same synchronous `retire` callback leaves no window where a quiesced call is in neither the registry nor the index. S1 below suggests saying this explicitly.

10. **Frozen keys are checked.** Capture checks frozen keys against the frozen tree (attempt and link facts), so stale entries left by a rewind can't add or redirect provenance. Live runs removed by the rewind stay covered by the write-ahead orphan records. The index is described as derived lookup state, never as authority (D4 `:57`, ADR `:48`, ownership row `:178` "Authoritative copy: Journal and live unfinished runs"). That respects D3's rule against side stores.

11. **Design shape.** This is one in-memory structure behind the runtime's existing rebuild/finish seams, with no new authority, setting or format. It adds behaviour without widening any interface callers depend on.

### Artifacts and traceability

12. **All the expected places are updated.** Persisted shape `design.md:166`, ownership rows `:175` and `:178`, ledger `:267`, apply note `:316` and ADR `:46-48` all carry the boundary and index.

13. **The three new scenarios are mapped:**
    - boundary recorded before mutation → `mutation_provenance_test.dart` (`tasks.md:65`)
    - later cancelled rename plus user restoration → `cancelled_mutation_test.dart` (`:66`)
    - missing legacy boundary → `attribution_test.dart` (`:67`)

    The existing later-success row is strengthened to the same turn (`:64`).

14. **The new work lands only in pending group 4.** Task 4.1 (`:168`) and task 4.2 (`:176-177`) pick it up. Completed tasks 3.1–3.4 are unchanged.

15. **The rejected alternative wasn't brought back.** No artifact makes every same-turn mixture read `unknown`. The "Later successful edit" scenario (`spec.md:108-110`) is still satisfiable, so the existing contract hasn't been narrowed.

I found no concrete contradiction or proof gap.

### Critical (blocking)

None.

### Moderate

None.

### Suggestions

Optional and non-blocking:

- **S1.** D4 `:57` and ADR `:48` say the index is updated "during durable finish/retirement before the writer queue advances". You could pin this down as "in the same synchronous step as registry retirement, never after it". Item 9's no-gap argument relies on that ordering, and it is already what `writer.dart:526` makes natural.
- **S2.** `spec.md:98` and ADR `:82` still say "a later successful effect". You could add "(sequence greater than the target's `targetAfterSeq`)" so "later" can't be read as response order or creation order. The new requirement at `spec.md:302` already settles this.
- **S3.** You could say that a non-integer `targetAfterSeq` is treated like a missing one (unestablished). You could also say that a malformed `seqHigh` at the target decision refuses or fails the same way `_mutationCounter` does for effects, rather than reading as zero.
- **S4.** Two "no new record fields" statements (D4 `:55`, ADR `:44`) are scoped to the case-alias rule but now sit next to the new `targetAfterSeq` field. The **Reversal cost** line (`design.md:60`) and the "To record during apply" ADR list (`:298`) don't mention `targetAfterSeq` either. Small wording updates would keep these consistent.
- **S5.** Round-19 S1–S4 are still optional and not adopted.

## Verdict

The user's `targetAfterSeq` design is internally consistent and can be built on the current source:
- The target append already runs inside the same-key `PathLocks` span and inside a queue-head `applyGuarded` decision.
- The effect path raises `seqHigh` and appends the effect within one queue action.
- So "effect sequence greater than the boundary" is exactly "mutated after this attempt's target decision" for an unambiguous key.
- A missing boundary stays unestablished, and the existing masks still win.

The derived quiescence index fixes the late-quiescence lookup gap without becoming an authority. The registry union covers the window between the quiescence publish and retirement. The scenarios, test-map rows and group-4 tasks are complete, and group 3 is untouched.

VERDICT: APPROVE

## Required Changes

None.

CHANGES_APPLIED: n/a

## Rebuttals

None. As instructed, I didn't revisit the rejected alternative of making every same-turn mixture read `unknown`. The approved boundary keeps the existing later-success contract and closes the later-cancelled-rename case.