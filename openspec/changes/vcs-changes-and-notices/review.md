# Review

## Metadata

- **Round:** 19. This retries round 18, which was rejected only for invalid output metadata and recorded no pass. The last valid review is round 17: APPROVE_WITH_CHANGES with one required change, N1.
- **Reviewer:** cross-model CLI (claude)
- **Scope:** this recheck covers round-17 N1 only. It checks whether the conservative case-alias rule is consistent with the durable effect ordering approved earlier. I ran no tests, builds, linters or formatters, implemented nothing and ticked no tasks. The effect-sequence implementation isn't claimed yet, so I didn't assess it.
- **Files actually read:**
  - `.dart_tool/vcs-design-review-round18.md` (all of it)
  - `openspec/changes/vcs-changes-and-notices/review.md` (round 17, all of it)
  - `design.md:40-69` (D3–D5, including D4 **Durable effect order** and **Case-alias uncertainty**)
  - `design.md:250-312` (mechanism ledger, risks, ADRs, apply notes)
  - `specs/workspace-change-attribution/spec.md:270-300`
  - `tasks.md:1-12`, `:55-62` (map rows) and `:140-184` (groups 3 and 4)
  - `docs/adr/0017-vcs-observation-baselines-and-provenance-attribution.md` (all of it, focusing on `:38-48` and `:72-78`)
  - `.dart_tool/vcs-review-skills/codebase-design.md`
  - Greps of the change directory for case/alias/lowercase wording, and of `proposal.md` for case-sensitivity wording (no matches)
- **Source:** I didn't re-read any source this round. The `PathLocks.run` scope, its lock key (`file_access.dart:74`) and the awaited effect commit were verified in round 17. The artifacts say that behaviour stays unchanged.

## Findings

### Round-17 N1 recheck

**N1. Resolved by the conservative rule the user chose.** Round 17 offered two fixes. The artifacts adopt the second one, "case-variant targets read `unknown`", and broaden it beyond what round 17 asked for.

**1. The rule is stated the same way everywhere:**
- D4 **Case-alias uncertainty** (`design.md:55`)
- ADR 0017 (`:44`)
- the requirement "Case-variant targets are uncertain" (`spec.md:290-291`)

All three compare each row's raw repo-relative spelling with interval mutation targets and with applying open, orphan and foreign targets. If different spellings are equal after lowercasing, the row reads `unknown`, contributes no `user_edits` and overrides successful-effect proof. None of the three introduces a volume probe, a new persisted field or a change to lock equality.

**2. Both round-17 harms are closed:**
- **macOS: two lock tails for one file.** Same-step writes to `New.txt` and `new.txt` can interleave because they take different lock tails. The two targets are equal after lowercasing, so any row matching either spelling reads `unknown`. Effect order is never used for them, so the interleaving can't produce a false `agent` (`spec.md:293-295`).
- **Windows: exact-key grouping.** Before, grouping effects by exact spelling could leave a row seeing only one spelling's effect. Now a row whose spelling differs from any relevant target reads `unknown`. That includes a row with only one recorded target (`spec.md:297-299`, `design.md:55`, ADR `:44`). An exact-key miss therefore can't fall through to `user` and raise `user_edits` either.

**3. The ordering invariant is qualified consistently.** Each artifact limits it to unambiguous spellings:
- D4 says rename order equals sequence order "for an unambiguous resolved-target key" and "Highest sequence is latest outside case-alias ambiguity" (`design.md:54`).
- ADR 0017 says the same (`:42`).
- The requirement says "For unambiguous target spellings, path locks SHALL cover…" (`spec.md:280`).

Same-spelling targets still share one lock key on every platform, so the round-17 verification of the lock still holds for them. Two places do not repeat the qualifier: "Highest sequence SHALL define latest" (`spec.md:280`) and "A later successful effect may prove agent attribution…" (ADR `:78`). Both are explicitly overridden by "SHALL override successful-effect proof" (`spec.md:291`) and by ADR `:44`. So there is no contradiction, only some redundancy you could tighten (S1).

**4. Applying the rule on every platform is deliberate and stated.** D4, the ADR and the requirement all say the rule applies to case-distinct paths on case-sensitive filesystems ("even on case-sensitive filesystems", `spec.md:291`). Apply note `design.md:311` records that the user chose this. This stays conservative: such rows read `unknown`, never a wrong `agent` or `user`.

**5. Tests and tasks cover the requirement:**
- Map row `tasks.md:60` maps the case-variant writes scenario to `mutation_provenance_test.dart`.
- Map row `tasks.md:61` maps the differently-cased row scenario to `attribution_test.dart`.
- Task 3.2 RED-confirms the case-variant regression and says case-variant targets are "unestablished order, not agent proof" (`tasks.md:152`).
- Task 4.1 adds the final label assertions in the mapped files (`tasks.md:165`).
- Task 4.2 applies the rule across interval and applying open, orphan and foreign targets. It checks both scenarios and confirms that unrelated user rows still raise `user_edits` (`tasks.md:176`). That keeps the rule from swallowing ordinary user attribution.

**6. Ledger and ADR list are updated.** Ledger row `design.md:264` names the harm (a hidden user restoration even with durable effect order). The ADR is in sync at `:44`.

I found no concrete contradiction between D4, ADR 0017, the requirement, its scenarios, the map rows and the group 3/4 tasks.

### Critical (blocking)

None.

### Moderate

None.

### Suggestions

Optional and non-blocking:

- **S1.** Two sentences could repeat the qualifier directly: `spec.md:280`'s "Highest sequence SHALL define latest" could add "for unambiguous target spellings", and ADR `:78`'s later-effect clause could add "subject to case-alias ambiguity". The override at `spec.md:291` and ADR `:44` already makes the meaning unambiguous.
- **S2.** Lowercase comparison doesn't catch every filesystem alias:
  - **macOS:** APFS ignores Unicode normalization, so NFC and NFD spellings of `café.txt` name one file.
  - **Windows:** NTFS uppercases using its own table, so `ſ` (long s) and `s` name one file even though they differ after lowercasing.

  These are outside N1's case-variant scope and need unusual model-typed spellings. If you want "outside case-alias ambiguity" to be literally exhaustive, you could list them as a known residual under Risks. Otherwise, no action is needed.
- **S3.** The "Case-variant mutation targets" scenario specifies a case-insensitive volume, while CI runs on both ubuntu and windows. The rule depends only on spelling, so the expected label is `unknown` on both, and the test can run unguarded. You could state that in the test name or comment, so nobody adds a platform skip that would conflict with task 3.1's no-skip rule.
- **S4.** Round-16 S2–S4 (also listed as round-17 S1) are still optional and not adopted.

## Verdict

N1 is fully addressed. D4, ADR 0017 and the requirement define one conservative case-alias rule. It overrides effect proof, contributes no `user_edits` and covers a row whose spelling differs from a single recorded target. It applies on every platform. Volume probes, new record fields and lock-equality changes are all deliberately ruled out.

The durable-order invariant is limited to unambiguous spellings, where the existing `PathLocks` scope (verified in round 17) still guarantees that rename order and effect-sequence order agree. Both scenarios have mapped tests, task 3.2 RED coverage and task 4.2 label verification, including the check that unrelated user rows still raise `user_edits`. No concrete contradiction remains.

VERDICT: APPROVE

## Required Changes

None.

CHANGES_APPLIED: n/a

## Rebuttals

None. I didn't revisit the volume-aware alternative that round 17 offered and the user rejected; this round's conservative rule fully satisfies round 17's second option.