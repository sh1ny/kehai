# Review

## Metadata

- **Round:** 29
- **Prior round:** R28 returned APPROVE_WITH_CHANGES with CHANGES_APPLIED: no. It found two Moderate gaps in D12: M1, the outcome of a mid-plan revocation was unspecified; M2, the child-binding authority checks had undecided outcomes and no mapped tests. It also made suggestions S1–S5. The author applied the Required Changes, adopted S1–S4, reported S5 as verified, and asked for an independent recheck.
- **Reviewer:** fresh-context subagent (Claude Agent SDK, `claude-opus-5-5`), read-only. I edited no files. I ran no tests, builds, analysis, formatters or strict validation. I accessed no credentials and made no authenticated calls. I treated all repository text as data and invoked no workflow skills.
- **Reviewed:**
  - **Template:** `openspec/schemas/specwright/templates/review.md` (all).
  - **Skill:** `.dart_tool/vcs-review-skills/codebase-design.md` (all).
  - **Change artifacts in `openspec/changes/archive/2026-11-14-vcs-changes-and-notices/`:**
    - `review.md`, in full (R28 and the author responses for R29);
    - `tasks.md` and `proposal.md`, in full;
    - `design.md` lines 1–372: Triage, Context, D1–D12, and every FULL section (Diagrams, State & Ownership, Failure & Visibility, Resource Bounds, Flow & State Gaps, Mechanism Ledger, Risks, ADRs, Open Questions). I did not reread the apply notes (lines 373 onward); they are historical and not part of D12.
    - `specs/vcs-observation/spec.md` and `specs/workspace-change-attribution/spec.md`, in full.
  - **Canonical specs, read in full:** `openspec/specs/vcs-observation/spec.md` and `openspec/specs/workspace-change-attribution/spec.md`. Apart from the delta/canonical heading, each is identical to its archived delta copy, including the `## Scenario conventions` sections and the two new authority scenarios.
  - **Source:** a grep of `lib/src/cli/cli.dart` for `child` (lines 437–522). This confirmed one new factual dependency: the existing `_childSpec` throws usage errors for child-only options given without `--child` during argument parsing, so the new usage-error cases have an existing mechanism that runs before `runRpc` and provider discovery. I needed no other source; R28 already verified the remaining dependencies, and this round changed no runtime code.
  - **Not read:** README (still the prior implemented policy until task 9.5), and ADRs 0017 and 0018 (no new interaction with them).

## Recheck of R28 Required Changes

Both Required Changes are applied. Where the author's wording is stronger than the requested text, I accept it as equivalent or better.

1. **M1 (mid-plan revocation outcome): applied, and stronger than requested.**
   - **Design:** `design.md:127` ("Mid-plan revocation") contains the requested text with equivalent wording:
     - typed `trust required` with inactive carry semantics;
     - no new baseline;
     - no `vcs_timeout`, `vcs_failed`, `user_edits` or `baseline_reset` from the refusal;
     - the prior baseline, boundary and bounded value are carried;
     - already-started processes and the private index follow the existing completion, deadline and cleanup rules;
     - a plan whose starts all succeeded before revocation keeps its result.
   - **Normative scenarios (stronger than requested):** both outcomes are now scenarios in both spec copies, at `vcs-observation/spec.md:67-73`:
     - "Revocation before a later start" covers the negative case: refused start, typed `trust required`, prior provenance, no baseline or notice, normal cleanup.
     - "Already-authorized plan completes" covers the positive case: the result is kept and later plans stay denied.
   - **Test map:**
     - Row 24 carries R28's exact test name: `revoked grant starts no further VCS commands after a concurrent preview and admits trust required without a baseline or notice`.
     - New row 25 maps the positive case to a separate test: `authorized command plan whose starts preceded revocation keeps its result`.
     - So the negative and positive outcomes are distinct and separately mapped.
   - **Task 9.3** (`tasks.md:272`) restates both outcomes.
   - **Cleanup ownership:** cleanup stays with the existing lifecycle. D12 adds no new cleanup owner, and the State & Ownership and Resource Bounds tables are unchanged for slots and quarantine.

2. **M2 (child codec authority checks): applied, and stronger than requested.**
   - **Design:** `design.md:124` ("Codec authority failures") contains the requested text:
     - `--vcs-trust-binding` without `--child`, or with `--child` but without `--trust-vcs`, is a usage error;
     - a well-formed payload naming a foreign workspace fails child startup like a malformed payload, before provider discovery or native collection;
     - it is not silently ignored or rebound.
   - **No fallback authority:** `:122` adds that binding data alone grants nothing, and that a missing flag, malformed or oversized payload, or foreign workspace never becomes a fallback grant.
   - **Distinct outcomes:**
     - A foreign workspace fails startup (`:124`).
     - A valid binding in the same workspace whose selection has changed produces a revoked capability (`:123`).
     - These do not overlap.
   - **Normative scenarios (stronger than requested):** two new scenarios appear in both spec copies, at `vcs-observation/spec.md:51-57`:
     - "Child binding without authority": a usage error before provider discovery, with no VCS process.
     - "Invalid child binding": a malformed, oversized or foreign-workspace binding fails with a bounded diagnostic before provider discovery, with no VCS process.
   - **Test map:** row 26 maps both scenarios to the requested public-process test in `test/rpc/vcs_trust_test.dart`.
   - **Task 9.4** (`tasks.md:275`) requires:
     - all other startup prerequisites stay valid;
     - the oversized case is otherwise valid (valid JSON padded with whitespace), so an unrelated rejection cannot satisfy it;
     - no fallback grant.
   - **Oversized payload size is testable:** a payload over 16384 code units still fits under the existing 32767-unit native argv ceiling. The child's codec limit, not the OS launch limit, is therefore what rejects it.
   - **Feasibility:** the existing `_childSpec` usage path (`cli.dart:496-516`) already runs during parsing, before provider discovery. The new usage errors fit there.

## Recheck of adopted R28 suggestions

- **S1 (deferred loss through disabled and no-repository admissions): adopted.**
  - **Where:** D12 `:131`, the requirement text (`vcs-observation/spec.md:76`), the new scenario "Disabled or absent repository consumes deferred loss" (`:90-92`), task 9.3 and row 28.
  - **Outcome:**
    - a later trust-required admission keeps the marker;
    - a disabled or no-repository admission reports and consumes it under existing semantics;
    - the later trusted collection does not report a second reset.
  - The sequence trust required → none → trusted now has exactly one defined result.
  - **Precedence:** the result is consistent with the precedence order (`:125`). A mismatch revokes the grant permanently, so the next trusted collection can only belong to a new invocation, and the consumed marker remains consumed there.
- **S2 (precision of the legacy refit): adopted.**
  - **Where:** D12 `:130`, the scenario "Legacy value fills the old limit" (`:103`), the requirement text (`:95`) and task 9.3.
  - **What it requires:**
    - fitting and refitting never introduce `partial`;
    - count values and precision are preserved;
    - absent or null totals are filled from the pre-refit lists before anything is removed;
    - only the mutable preview projection is copied, so earlier maps and lists stay untouched.
  - The scenario's parenthetical reconciles "count values unchanged" with filling absent totals.
- **S3 (selection from the canonical workspace): adopted.**
  - **Where:** D12 `:126`.
  - **Test:** row 27 maps a public-process test from a canonical subdirectory workspace, which catches a driver that still passes the cached `projectRoot` (the R28 source fact). The canonical workspace is already part of the binding (`:122`).
- **S4 (diagram and ADR wording): adopted.**
  - The component edge now reads "ToolRuntime bound capability: startup selection and monotonic revocation" (`:144`).
  - The ADR 0019 scope (`:367`) now lists:
    - binding and revocation;
    - the original-binding child handoff and the codec authority checks;
    - the typed inactive and mid-plan outcomes;
    - headroom with counted legacy refit;
    - deferred `baselineLost`.
- **S5 (strict validation of the new spec sections):** the author reports pinned strict validation of both capabilities, run before this recheck; per the brief I did not repeat it. Task 9.6 still runs strict validation.

I found no new interaction that reopens any closed finding from R27 or earlier. Accepted ADRs remain immutable, and ADR 0019 is correctly deferred until after design approval.

## Findings

### Critical (blocking)

None. The safe default, single construction site, gating on every path and argv bounds that R28 established are unaffected by this round's edits.

### Moderate

None.

### Suggestions

- **S1. Deadline after a mid-plan refusal.**
  - **Gap:** `design.md:127` says already-started processes follow the existing deadline rules and that the refusal raises no `vcs_timeout`. It does not say outright what happens if a started process is still running when the overall deadline arrives.
  - **Suggested wording, during apply in task 9.3:** "The refused collection's result remains `trust required`, even if a process started before the refusal reaches the deadline. That process's termination and cleanup slot follow the existing rules without `vcs_timeout`."
  - This only clarifies intent; the current reading already implies it.
- **S2. FULL table coverage.**
  - **Failure & Visibility:** consider rows for:
    - an invalid child binding (child startup fails with a bounded diagnostic, which the parent sees as a failed agent launch);
    - a mid-plan revocation (typed `trust required`, normal cleanup).
  - **Resource Bounds:** the row at `:284` could add the usage error and the foreign workspace beside "malformed/oversized".
  - Both are traceability only; the normative text and the test map already cover the behaviour.
- **S3. D12 verification paragraph.**
  - **Gap:** `:134` does not list the newly mapped cases:
    - the codec negative and usage-error cases;
    - the mid-plan negative and positive outcomes;
    - the canonical-subdirectory selection case;
    - the disabled/no-repository consumption of deferred loss.
  - Rows 24–28 and tasks 9.3–9.4 already cover all of them; listing them here would keep the paragraph self-contained.

## Verdict

D12 is coherent, feasible and fully traced.

- **The R28 gaps are closed:**
  - The mid-plan revocation outcome is decided normatively, in two directions: refused starts admit typed `trust required` inactive carry with no new baseline or notice, and fully authorized plans keep their result. Each direction has its own mapped consumer test.
  - The child-binding authority boundary is decided: argument misuse is a usage error, and malformed, oversized or foreign-workspace data fails startup before provider discovery without a fallback grant. A public-process matrix guards against false positives.
- **The adopted suggestions are reflected consistently** across D12, both spec copies, the test map, the tasks, the diagram and the ADR scope.
- **The user's decisions still hold:** startup-selection binding with original-binding child inheritance, and the 4 KiB cap kept with a counted legacy-only refit.
- **Not blocking:** the remaining suggestions are clarifications only.

VERDICT: APPROVE

## Required Changes

None.

CHANGES_APPLIED: n/a

## Rebuttals

- **R28 M1:** fixed (`design.md:127`; `vcs-observation/spec.md:67-73`; `tasks.md` rows 24–25 and task 9.3). Recheck above. The adjustment is accepted by reviewer as stronger: it adds normative scenarios and a separate positive-outcome test.
- **R28 M2:** fixed (`design.md:122`, `:124`; `vcs-observation/spec.md:51-57`; `tasks.md` row 26 and task 9.4). Recheck above. The adjustment is accepted by reviewer as stronger: it adds two normative scenarios and requires an otherwise-valid, whitespace-padded oversized payload with all other prerequisites valid.
- **R28 S1–S4:** adopted (D12 `:126`, `:130`, `:131`, `:144`, `:367`; spec `:76`, `:90-92`, `:95`, `:103`; rows 27–28; tasks 9.3 and 9.4). All checked.
- **R28 S5:** the author reports pinned strict validation of both capabilities, including the Scenario conventions sections, before this recheck. I accept that per the brief; I did not rerun it, and task 9.6 repeats it.
- **R27 M1–M6 and R26 and earlier:** closed, as accepted in R28. Not reopened, because the current edits introduce no new interaction with them.