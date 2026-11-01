# Tasks

## Test map

All rows describe new behavior and start `red` as planning intent; no failing tests have been written or run yet. Apply changes each row to `green` only after its named test passes. File names marked new are proposed boundary tests, not existing coverage.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| reasoning-effort → Effort selection and validation | CLI selection | `test/cli/effort_test.dart` (new) | `client and rpc accept effort including leading and equals forms` | red |
| reasoning-effort → Effort selection and validation | Invalid CLI value | `test/cli/effort_test.dart` (new) | `invalid or missing effort exits 64 before engine startup` | red |
| reasoning-effort → Effort selection and validation | Invalid configuration | `test/config/config_test.dart`; `test/cli/effort_test.dart` (new) | `invalid effort names config path even with valid flag` | red |
| reasoning-effort → Effort precedence and default | Flag overrides config | `test/cli/effort_test.dart` (new) | `flag effort overrides user config in rpc startup` | red |
| reasoning-effort → Effort precedence and default | Config alone | `test/cli/effort_test.dart` (new) | `config effort reaches request without flag` | red |
| reasoning-effort → Effort precedence and default | Resume without selection | `test/cli/effort_test.dart` (new) | `resume without effort does not inherit historical selection` | red |
| reasoning-effort → Effort precedence and default | Explicit none | `test/cli/effort_test.dart` (new) | `explicit none reaches wire rather than omission` | red |
| reasoning-effort → Consistent effort on requests | Tool round and safe retry | `test/loop/driver_test.dart` | `tool follow-up and permitted retry keep selected effort` | red |
| reasoning-effort → Consistent effort on requests | Backend rejects selected effort | `test/loop/driver_test.dart` | `invalid request for effort fails without downgrade or resend` | red |
| reasoning-effort → Internal agents inherit effort | Parent override reaches reviewer | `test/jobs/agent_effort_test.dart` (new) | `reviewer child inherits parent override across role model selection` | red |
| reasoning-effort → Internal agents inherit effort | Config changes before launch | `test/jobs/agent_effort_test.dart` (new) | `child inherits provider default despite edited config` | red |
| reasoning-effort → Effort recorded per step | Step persisted and replayed | `test/loop/driver_test.dart` | `each step records selected effort and replay preserves it` | red |
| reasoning-effort → Effort recorded per step | Failure before sending | `test/loop/driver_test.dart` | `local overflow retains explicit null effort without request` | red |
| reasoning-effort → Effort recorded per step | Interrupted step | `test/loop/driver_test.dart` | `resume finalization preserves admitted effort without resend` | red |
| reasoning-effort → Effort recorded per step | Older session | `test/cli/effort_test.dart` (new) | `legacy steps remain unchanged and new steps record current effort` | red |

## 1. Record the approved shared contract

- [x] 1.1 Write additive `docs/adr/0013-reasoning-effort-selection-and-inheritance.md` from approved design D1–D4, including selection/default semantics, additive step field and child argv inheritance; update `openspec/architecture.md` index and relevant boundary text without editing accepted ADRs. Verify the delivered ADR matches the reviewed spec/design, leaves journal/RPC versions unchanged, and `mise run openspec:validate` passes.

## 2. User config and CLI inputs

- [ ] 2.1 Write failing tests for all allowed config values, missing default, explicit null/wrong-type/empty/unknown values, and valid flag with invalid config; extend `test/config/config_test.dart` and add input-boundary cases in `test/cli/effort_test.dart`. Also write failing tests for both CLI parsers, leading `--effort`, `--effort=value`, missing/invalid values, and no session/engine/provider effects on CLI error. Verify each fails for the missing effort feature, not unrelated fixture setup (test-map rows CLI selection, Invalid CLI value, Invalid configuration).
- [ ] 2.2 Implement the shared effort vocabulary/validation and optional `UserConfig.effort`; add `--effort` to both parsers, client dispatch and forwarding, and carry the flag into `runRpc`. Preserve strict config validation even with overrides. Verify the group-2 tests pass and mark only their covered test-map rows green; run `mise run analyze` and document CLI/config syntax, allowed values, omission versus `none`, and invalid-input behavior in the user-facing configuration/CLI documentation.

## 3. Startup resolution, request propagation and step persistence

- [ ] 3.1 Write failing tests in `test/cli/effort_test.dart` using isolated user home and a local fake service for flag-over-config, config-only, default omission, explicit `none`, resume without historical fallback and legacy steps; assert actual request JSON and materialized step data. Verify failures correspond to the test-map rows Flag overrides config, Config alone, Resume without selection, Explicit none, Older session.
- [ ] 3.2 Write failing builder/driver tests for selected/default request values (including estimate requests), tool-follow-up and existing safe retry, invalid-request failure without downgrade/resend, admission-time effort, replay, local overflow with explicit null and interrupted recovery without resend. Include generic fork/rewind preservation/removal checks for the additive field. Verify the remaining driver-owned test-map rows fail for missing propagation or recording, using existing writer/provider seams rather than real paid requests.
- [ ] 3.3 Resolve effort once in RPC startup per design D2; pass it to `ExchangeDriver`, `RequestBuilder` and request construction, and record `effort` (including null) in the single step-admission set. Preserve old steps, completion/recovery merges, retry eligibility and the existing provider serializer. Verify group-3 tests pass, request values equal admitted step values, replay/fork/rewind preserve expected trees, and mark the corresponding test-map rows green. Run `mise run analyze`; document precedence, resume behavior and the meaning of recorded null beside the user-facing option/config documentation.

## 4. Internal-agent inheritance

- [ ] 4.1 Write failing tests across runtime/tool-context and real child process boundaries: selected value forwarded to a reviewer using a different mapped model; inherited provider default despite a config edit before launch; recursive inheritance; explicit selected effort despite changed child config; direct child fallback without an inherited-default marker; invalid config still refused; internal default flag refused outside child mode or combined with explicit effort. Use `test/tools/agent_tool_test.dart`, CLI cases and new `test/jobs/agent_effort_test.dart` with isolated role/home/session fixtures and a local fake service. Verify both Internal agents inherit effort map rows fail for missing inheritance.
- [ ] 4.2 Thread resolved effort through `ToolRuntime` and `ToolContext`; pass explicit child `--effort` or the child-only inherited-default marker, add its validated `ChildSpec` input and child startup resolution, and retain normal config validation. Verify group-4 tests pass, child wire values and persisted steps agree, descendants inherit the same selection, and mark both child rows green. Run `mise run analyze`; document the internal launch contract in the new ADR and public inheritance behavior in user-facing documentation, keeping role/model mapping and permission policy unchanged.

## 5. Integration qualification and dogfood receipts

- [ ] 5.1 Add and run a local fake-service end-to-end regression that launches the line client with `--effort high`, executes a tool-follow-up and an internal reviewer child, and checks parent/child request JSON and replayed steps; also cover a provider-default run. Verify it passes on native Windows without WSL and Linux where available, with unavailable platforms explicitly recorded as unverified rather than passed; ensure the changed feature's existing platform CI coverage is exercised.
- [ ] 5.2 Run `mise run check`, `mise run openspec:validate` and `mise run secrets` as separate single-command calls; verify each succeeds and every test-map row is green. Record Kehai apply attempt, actual test/platform receipts and unsupported steps or `none observed` in the design's dogfood evidence section. A design edit voids its current approval: obtain and validate a fresh internal design review covering the updated artifacts before declaring the group complete. Do not claim Nikolay's user-verified milestone acceptance.

## Workflow follow-up

- Planning artifacts are complete only; explicit apply authorization is still required. During apply, `specwright-commit` commits completed groups, not this planning workflow.
- Keep `review.cross_model: false` and `review.preship: true`. Run and record the required Kehai-internal pre-ship review after implementation commits; no external reviewer CLI substitutes for it.
- Ship one real delivery PR through the configured `sh1ny`-fenced GitHub workflow; follow required review/CI gates, archive and finish before merge. Read the PR author and never request `sh1ny` review on a `sh1ny` PR.
- Preserve review/PR/archive/merge receipts and remaining friction. If adding receipts edits reviewed proposal/spec/design, obtain a new design review as required rather than reusing an invalidated approval.
- Count the merged bridge delivery once in M2; do not create a wrapper PR or mark user-verified M1 exit criteria passed on Nikolay's behalf.
