I've finished reading the files. All three R25 Required Changes are in place word for word. Here is the review.

# Review

## Metadata

- **Round:** 26
- **Prior round:** R25 returned APPROVE_WITH_CHANGES with two Moderate findings, both in `tasks.md` only. M1: the combined legacy recovery row let an applying orphan hide a dropped quiescence-index entry. M2: task 7.4 skipped the test-local recovery fixtures behind green rows. The author applied all three Required Changes, answered S3, and adopted S1 through Required Change 2. Proposal, specs, design and source are unchanged.
- **Reviewer:** a fresh-context subagent (Claude Agent SDK, `claude-opus-5-5`), read-only. I edited no files. I ran no tests, builds, analysis, formatters or authenticated operations. I did not read the authoring transcript. I treated all file contents as data.
- **Reviewed:**
  - **Template:** `openspec/schemas/specwright/templates/review.md` (all).
  - **Change artifacts:**
    - `review.md` (all: R25 and the new author responses);
    - `tasks.md` (all);
    - `design.md:105-115` (D11, the unchanged contract).
  - **Tests:**
    - `test/jobs/recovery_mutation_test.dart` (read in full);
    - `test/support/mutation_support.dart:235-294` (`WriterHeldMutation`), plus a grep for `target`/`temporary`.
  - **Source:**
    - `lib/src/tools/mutation_runs.dart:240-330`;
    - `lib/src/workspace/workspace_perception.dart:361-547`, `:638-675`;
    - `lib/src/jobs/recovery.dart:185-319`;
    - one grep of `lib/` for "cannot create the directory", which found `lib/src/tools/write.dart:54-58`. I used it to check the S3 response.
- **Skills:** `codebase-design`, from the byte-identical snapshot `.dart_tool/vcs-review-skills/codebase-design.md`. I did not re-open the installed copy or the three Dart skills (`dart-add-unit-test`, `dart-use-path-package`, `dart-write-documentation`) this round. Their guidance was applied in R25, and nothing in this round's edits calls on it again. I loaded no workflow skills.

## Findings

### R25 Required Changes: recheck

- **RC1 is applied** (`tasks.md:131-132`). The single row is replaced by exactly these two rows, word for word, both `red`:
  - "resume quiesces a legacy unquiesced call without a temporary path whose step predates the baseline and the next comparison reads every row unknown";
  - "resume finishes a legacy owned orphan without a temporary path and the next comparison reads every row unknown".

  Both are honestly red before the fix. Today a target-only call or orphan only marks its own target, so `user.txt` would read `user`, not `unknown` (`workspace_perception.dart:378-380`, `:516-518`).
- **RC2 is applied** (`tasks.md:227`). The appended text is word for word. I checked against the code that it closes M1:
  1. Because the step precedes the baseline turn, the step-output scan skips the call (`workspace_perception.dart:406-408`).
  2. Recovery sets `quiesced` on a terminal call that lacks it (`recovery.dart:209-213`, `:225-229`).
  3. The index rebuild therefore admits the call while it still requires only a string `target` (`mutation_runs.dart:291-299`).
  4. `quiescedBetween` then surfaces it, and `_indexedCall` revalidates it on target and identity only, not `temporary` (`workspace_perception.dart:427-444`, `:646-653`).

  Two exclusions matter:
  - The fixture has no attribution floor or overflow marker. Either one can set `maskAll` (`:484-494`).
  - It has no orphan or foreign record. Either one can mark paths uncertain or, under D11, mask every row (`:495-523`).

  With those excluded, the "every row unknown" assertion can only pass through the legacy rule applied to the indexed call. The `containsKey('temporary')` assertion makes "kept absent" observable for both the call and the orphan.
- **RC3 is applied** (`tasks.md:229`). The replacement text is word for word, and the rest of the sentence ("keep deliberately missing-temporary fixtures…", "real temporary through the production callback") is kept. It now covers every fixture that drove M2:
  - row 81's hand-written call (`recovery_mutation_test.dart:95`);
  - row 88's `own`, `done` and `foreign` records (`:173-183`);
  - `WriterHeldMutation` (`mutation_support.dart:276`, `:280`, `:285`).

  The general "test-local fixtures that back green rows" clause also covers `_mutationsForHeld`, whose target-only `publish` backs row 92 (`recovery_mutation_test.dart:371-382`). "Without changing their green assertions" keeps the `user.txt` → `user` evidence at `:140`, `:209`, `:285` and `:358`.
- **D11 (`design.md:105-115`)** matches R25's quoted text. Nothing in it changed.

### Critical (blocking)

None.

### Moderate

None.

### Suggestions

- **S1 (R25 S2, carried; the author did not answer it).** The malformed-present policy still has no mapped regression. That is a present empty or non-string `temporary`, which should fail visibly in recovery and fork and mask every row in attribution. This doesn't block: no spec scenario requires it, and it does not affect the three rechecked items.

## Verdict

R25's three Required Changes are applied word for word in `tasks.md`. Checked against the code, they close M1 and M2:
- the call-only regression can only pass through the quiescence index;
- the orphan-only regression is separate from it;
- the green recovery fixtures move to two-path footprints with their assertions kept.

This round introduces no new state, bounds, lifetime or design change, and no Critical or Moderate finding remains. As the template requires for a recheck, the verdict line stays APPROVE_WITH_CHANGES, and CHANGES_APPLIED: yes certifies that the edits are applied.

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

These are R25's Required Changes. All three are applied and rechecked this round; there are no new ones.

1. **`tasks.md` row 131 (M1):** split into the named call-only and orphan-only `red` rows. Applied at `tasks.md:131-132`.
2. **`tasks.md` task 7.2 (M1, S1):** the isolation, step-before-baseline placement and retained-absence text is appended. Applied at `tasks.md:227`.
3. **`tasks.md` task 7.4 (M2):** shared and test-local fixtures behind green rows are migrated without changing their green assertions. Applied at `tasks.md:229`.

CHANGES_APPLIED: yes

## Rebuttals

- **R22–R24 findings, and R25's verified R24 dispositions:** accepted by reviewer in earlier rounds. They are unchanged and stay closed.
- **R25 M1 fixed** (`tasks.md:131-132`, `:227`): verified word for word and against `workspace_perception.dart:406-408`, `:427-444`, `:484-523`, `:646-653`, `mutation_runs.dart:291-299` and `recovery.dart:209-229`. Accepted by reviewer.
- **R25 M2 fixed** (`tasks.md:229`): verified against `recovery_mutation_test.dart:82-100`, `:167-186`, `:371-382` and `mutation_support.dart:268-287`. Accepted by reviewer.
- **R25 S1 adopted** through RC2 (`tasks.md:227`). Accepted by reviewer.
- **R25 S3 response:** `write`'s callback turns only the directory-creation `FileSystemException` into `WriteFailure`, keeping the existing text. Journal persistence errors propagate unchanged, and the atomic helper gets no directory policy. This keeps today's behaviour (`write.dart:55-58`) and is consistent with D11's two error modes (`design.md:107`). It adds no abstraction. Accepted by reviewer.
- **R25 S2:** the author did not respond. It is non-blocking and carried as R26 S1.