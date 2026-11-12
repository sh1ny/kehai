# Review

## Metadata

- **Round:** 12
- **Prior round:** round 11 APPROVE_WITH_CHANGES
- **Reviewer:** cross-model CLI (claude)
- **Files read:** `openspec/changes/vcs-changes-and-notices/review.md` (round 11); `design.md` D4 (`:51-57`), the State & Ownership row "Open-mutation key set" (`:163`), and Apply notes (`:284-290`); `specs/workspace-change-attribution/spec.md:170-214`; `tasks.md:70-149`; `docs/adr/0017-vcs-observation-baselines-and-provenance-attribution.md:40-59`. I also grepped `lib/src/jobs/supervisor.dart` to check the cited lines `:770` and `:812-836`. Scope: only the six Required Changes from round 11. This is not a broad audit. I ran no tests, builds or linters.

## Findings

### Critical (blocking)

None.

### Moderate

None. All six Required Changes from round 11 are present and say what was required:

1. **D4 registry correction:** done. It is the new bullet **Rewind-to-record gap** (`design.md:54`). It keeps the required wording: an in-memory registry of unfinished edit/write runs, the same set the 16-run cap counts; registry targets are open whatever the tree says; `SessionWriter.fork` takes a provider of those targets, calls it inside its queue decision and writes a foreign record for each; and the window is cited as `supervisor.dart:770,812-836`. The cited lines are still correct: `:770` is the rewind `_requestPass`, `:812` is `_reconcile` and `:835` is `afterReconcile`. The text is a separate bullet after the **Choice** paragraph, not inline after the "`meta/orphans`, `meta/handoffs`" sentence. It still sits inside D4 and means the same, so the placement does not matter.
2. **State & Ownership row:** done. The "Invalidation / rebuild" cell (`design.md:163`) matches the required text word for word, and the source column now includes "live unfinished runs".
3. **Spec scenario "Request built before the orphan record is written":** done, under "Removed live mutations stay uncertain" (`spec.md:188-190`), worded as required.
4. **Spec scenario "Fork between rewind and orphan record":** done, under "Forks do not finish the parent's mutations" (`spec.md:199-201`), worded as required.
5. **Tasks test map and task 3.3:** done. `tasks.md:77` maps to `test/tools/orphaned_mutation_test.dart` / "build frozen before orphan append keeps held rename unknown" / `red`. `tasks.md:81` maps to `test/session/fork_mutation_test.dart` / "fork before orphan append copies the live run as foreign" / `red`. Task 3.3's fork bullet now includes "the fork's live-run provider" (`tasks.md:145`).
6. **ADR 0017 draft:** done. The section "Removed runs leave rewind-exempt, session-owned uncertainty" (`0017:52`) now says the registry is authoritative for open targets in attribution and fork, including the gap before an orphan record is appended. It also says meta records persist the uncertainty across restart and baseline rewind. It adds one more sentence, that fork reads its provider inside the writer's queue decision. That matches D4.

**Apply notes:** `design.md:286-290` record readiness checks, a read-only apply attempt that stopped at a permission prompt, and the steps it could not support. They say that no implementation, tests or commits ran, and that task 6.2 is not satisfied. They do not claim any implementation or qualification. They also record that the user approved the round-11 correction before the artifacts changed.

### Suggestions

**S1. Make the older "derived from the tree" wording refer to the registry.** D4's **Choice** paragraph (`design.md:53`) still says "Open calls are found from a per-engine set of call keys derived from the tree after resume and after every rewind". ADR 0017 (`:44`) says the same: "Derive the engine's open-call key set from the current tree…". The new bullet and ADR `:52` override both, and the State & Ownership row has the union, so this is not a defect. Adding "unioned with the unfinished-run registry" to those two sentences during apply or ADR finalisation would mean a reader cannot take the tree-only sentence as the whole rule.

The round-11 suggestions S1 (foreign records never expire) and S2 (meta records copied verbatim at fork, and the Resource Bounds count) were optional and are not rechecked here.

## Verdict

All six Required Changes from round 11 are present and correct in the current files. Nothing new blocks approval.

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

None outstanding. All six round-11 Required Changes are applied.

CHANGES_APPLIED: yes

## Rebuttals

None.