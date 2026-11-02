# M1 close receipts — 2026-11-02

## Delivery and acceptance

All six M1 entries are archived on `main`: `session-tree-journal`, `provider-openai-codex`, `core-tools`, `agent-loop-and-line-client`, `skills-agents-commands`, and `dogfood-first-m2-change`. The permission-prompt Unicode/content/old-text follow-ups are also archived. The current close checked fetched `origin/main` at `5e58cac3840a3efdcc192979750cd83bc4016800`; there were no active changes.

Entry 6 delivered reasoning-effort selection/inheritance, [PR #27](https://github.com/sh1ny/kehai/pull/27), archive head `e7aca44c979e3aefbbc042b1a23efd92e8bf19bf`, merge `5e58cac3840a3efdcc192979750cd83bc4016800`. Count it once as the first M2 bridge delivery; do not restart it or create a wrapper change.

The owner explicitly confirmed on 2026-11-02:

- **PASS, Windows:** `kehai login openai` completed subscription OAuth without an API key, securely stored credentials and refreshed without prompting.
- **PASS, Windows:** `kehai doctor` showed the account and models.
- **PASS with caveats:** the real entry-6 branch → proposal/specs/design/tasks → implementation/commits → reviews → archive → merge lifecycle was orchestrated by Kehai. The owner accepted configured external reviewer CLIs, not a claim that every review ran inside the internal agent tool.

Acceptance caveats (not erased by the close): Kehai wrote the branch code/commits/reviews/archive/merge. The babysitter answered permission prompts and gave instructions. The owner decided cross-model review re-enablement and the Windows Nightly waiver. The babysitter posted issue comments on #26/#28 as KintsugiBot outside the branch. Three context overflows required restarts with hand-written resume prompts; there was no compaction. This is qualified self-hosting acceptance, not unattended operation or proof of M2 reliability.

## Delivery qualification and explicit exception

- Delivery head `233841b949f8b306231bfbaba3b34255bd2395b5`: PR CI run `41366021763` passed on Linux and Windows; Linux Nightly in `41366388973` passed.
- Windows delivery-head Nightly failed initially on `hung_hook_test` (7.48 s versus a <5 s assertion); its one failed-job rerun passed that test but failed two agent-job partial-text deadline tests before child work progressed (0 steps / 0 provider requests).
- **Owner waiver:** Windows Nightly run `41366388973` on `233841b`, recorded in [#28](https://github.com/sh1ny/kehai/issues/28#issuecomment-6567247172), accepted CPU-bound JIT startup inside a 15 s wall-clock deadline. It is not a green Nightly receipt or a weakened future gate. No further Nightly rerun was requested.
- Archive-only check and required pre-ship gate passed for `e7aca44`; PR CI passed on both OSes on that archive head. A quiet readiness wait found no actionable feedback; merge was at that exact head. [PR qualification note](https://github.com/sh1ny/kehai/pull/27#issuecomment-6567292529).

## Agent-verifiable close checks

On Windows at the merged code head, before planning edits:

- `mise run analyze`: no issues.
- `mise exec -- dart test test/property/replay_property_test.dart -j 1`: 4 passed, including randomized identical-tree replay and corruption handling.
- `mise exec -- dart test test/tools/central_truncation_test.dart -j 1`: 2 passed, full bytes stored centrally and no tool/job-local cuts.
- `mise exec -- dart test test/qualification/installed_workflow_test.dart -j 1`: 1 passed; installed skills/commands/roles are inventoried from `.claude` and `.agents`.
- `mise exec -- dart test test/qualification/workflow_e2e_test.dart -j 1`: 1 passed; installed apply loads commit skill, real implementer/reviewer return typed results after relayed approvals.
- `mise exec -- dart test test/tools/edit_tool_test.dart -j 1`: 14 passed, including stale/moved anchors and approval binding.
- `mise exec -- dart test test/loop/hung_hook_test.dart -j 1`: 2 passed; optional hung hook is killed and deny hook cannot block the exchange. This isolated pass does not revoke the Nightly waiver or resolve #28.
- Read, write, grep/find and structured ask were exercised by Kehai during entry 6 and this close. Dart tests/analysis ran through bash. Pinned jj initialized and inspected a disposable Git-backed jj repository successfully; this checkout remains Git-only. The initial `jj status` refusal here was a repository-type mismatch, not a reason to initialize jj in the project.

No full local suite was run: the full suite is left to CI. These are bounded agent checks plus owner acceptance, not a claim that all platforms or all test cases were requalified at close.

## M2 friction ledger — assignment required in designs

The owner agreed seven M2 entries, compaction first: every remaining change will itself be built by Kehai, so another overflow/restart cycle is a delivery risk. These observations are explicit work to allocate in those designs, not new implementation shipped by the close:

- **Context:** 3 overflows around 187–228k while the UI advertised 500k for `gpt-6.1-sol` on the ChatGPT-account route. The advertised window was wrong for that route; the observations are not a newly established exact limit. Fix route-aware window accuracy and compaction first, preserving scratch/result handles and canonical history. Expose unknown/estimated capacity honestly.
- **Permissions/config/instructions:** add an “allow for this session” answer, a user-level instruction file, user allow rules scoped to the repo/workspace, and config reload without restart. Chained commands currently always prompt; improve safe workflow/approval behavior without treating chains as implicitly safe. Preserve user control and deny policy; a live config design must explicitly reconcile ADR 0013's immutable resolved effort and child inheritance rather than silently changing an active run.
- **Workflow:** prefer one blocking watch/wait (background job if needed) over repeated `sleep` polling and prompt/context consumption. Specwright scratch files outside the repo also caused friction; decide their placement/trust/cleanup in the relevant design rather than broadening approval by accident.
- **Test follow-ups, [#28](https://github.com/sh1ny/kehai/issues/28):** deadline-after-child-readiness or in-process timing tests; wall clocks only as hang guards where appropriate; a distinct process-test tier. Preserve timeout, partial-text and hung-hook isolation contracts; do not weaken assertions to hide failures.
- **Coverage restoration:** restore `test/tools/search_tools_test.dart` → “a relative PATH entry is skipped” with `cwd=workspace`, lost in `325692c`. The weakened coverage was explicitly deferred, not fixed or accepted as permanent.

## Planning-only scope

This close implements [#26](https://github.com/sh1ny/kehai/issues/26)'s planning decisions: reusable-package principle/ADR, M2 order and building-block directions, and Kumiko's eventual default-harness use via `kehai rpc` v1. Kumiko needs its own planning change for containment extraction and runtime adapter. No package, compactor, collector, UI, PTY integration or Kumiko change is implemented here. #26 closes only when these planning edits land; #28 and the relative-PATH follow-up remain implementation work.
