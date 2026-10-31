## Metadata

- **Round:** 1 re-check
- **Prior round:** Round 1 found two moderate contract inconsistencies: newline handling contradicted the unchanged client behavior, and the proposal/spec omitted the lone-surrogate exception.
- **Reviewer:** Codex
- **Reviewed:** Round-1 Required Changes only, against the updated proposal, delta line-client spec, design D1, and `_showActive` in `lib/src/client/client.dart`. Required tests checked as artifact commitments; no tests written or run.

## Findings

### Critical

None.

### Moderate

1. **The newline requirement contradicts the unchanged client behavior.**  
   Round-1 finding: the requirement applied multiline rendering to all prompt fields, while `_showActive` renders `cwd` and `target` line feeds as literal `\u{A}`. **Fixed** in the updated artifacts.

2. **The spec omits the design’s lone-surrogate exception.**  
   Round-1 finding: the proposal and delta requirement required lone surrogates to print unchanged, contradicting D1’s escaping requirement. **Fixed** in the updated artifacts.

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. Distinguish newline handling in the proposal, delta requirement and D1; add an assertable scenario for newline-containing `cwd` and `target`; require retaining the directory test and adding the target test. **Applied.** The artifacts specify separate `  | ` lines for command/path and literal `\u{A}` within directory/target lines, matching `_showActive` at lines 555–576. The delta scenario covers both fields, and proposal Impact retains directory coverage and requires a target test.

2. Add lone surrogates U+D800–U+DFFF to the proposal and delta requirement’s escaped exceptions; add a lone-U+D800 scenario; require renderer tests for lone high and low surrogates and an unchanged valid supplementary character. **Applied.** The proposal and delta requirement include the exception, the scenario requires `a\u{D800}b`, and proposal Impact explicitly requires all three test cases.

CHANGES_APPLIED: yes

## Rebuttals

1. **fixed** — Proposal **What Changes** and **Impact**; delta **Permission prompt text** requirement and **Line feed in a directory or target** scenario; design **D1**. These agree with the existing `_showActive` newline behavior.
2. **fixed** — Proposal **What Changes** and **Impact**; delta **Permission prompt text** requirement and **Lone surrogate** scenario. These match D1 and require the named tests during apply.