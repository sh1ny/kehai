# Tasks

## Test map

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| agent-loop → Conversation recorded in the tree | Items in order | `test/loop/driver_test.dart` | `Conversation recorded in the tree step output commits text, reasoning and calls in output-index order` | green |
| agent-loop → Conversation recorded in the tree | Rewind removes the later steps | `test/loop/request_builder_test.dart` | `rewind to an exchange's first turn drops later steps from the request` | green |
| agent-loop → Conversation recorded in the tree | Compaction committed with completion | `test/loop/compaction_test.dart` | `agent-loop: Compaction committed with completion` | green |
| agent-loop → Conversation recorded in the tree | Crash before completion commit | `test/loop/compaction_test.dart` | `agent-loop: Crash before completion commit` | green |
| agent-loop → Requests rebuilt from the tree | Tool output is the composed envelope | `test/loop/request_builder_test.dart` | `tool output is the stored model text byte for byte` | green |
| agent-loop → Requests rebuilt from the tree | Resumed session | `test/loop/request_builder_test.dart` | `resumed session request holds earlier items and cancelled calls' outputs` | green |
| agent-loop → Requests rebuilt from the tree | Instructions from the exchange's context | `test/loop/context_test.dart` | `Instructions built from the captured context a step uses the context captured at its exchange start` | green |
| agent-loop → Requests rebuilt from the tree | Session from before this change | `test/loop/context_test.dart` | `Instructions built from the captured context a pre-change session captures context for its next exchange` | green |
| agent-loop → Requests rebuilt from the tree | Boundary in a tool step | `test/loop/compaction_test.dart` | `agent-loop: Boundary in a tool step` | green |
| agent-loop → Requests rebuilt from the tree | Incompatible boundary | `test/loop/compaction_test.dart` | `agent-loop: Incompatible boundary` | green |
| agent-loop → Context overflow stops the exchange | Estimate over the window | `test/loop/driver_test.dart` | `Context overflow estimate over a known window stops before sending` | green |
| agent-loop → Context overflow stops the exchange | Provider reports overflow | `test/loop/driver_test.dart` | `Context overflow provider context_overflow stops the exchange without retry` | green |
| agent-loop → Context overflow stops the exchange | Compaction missing at safety threshold | `test/loop/compaction_test.dart` | `agent-loop: Compaction missing at safety threshold` | green |
| agent-loop → Every committed call has a recoverable outcome | Normal settlement across the cut | `test/loop/compaction_test.dart` | `agent-loop: Normal settlement across the cut` | green |
| agent-loop → Every committed call has a recoverable outcome | Death before any runtime admission | `test/loop/compaction_test.dart` | `agent-loop: Death before any runtime admission` | green |
| agent-loop → Every committed call has a recoverable outcome | Partial admission and repeated reopen | `test/loop/compaction_test.dart` | `agent-loop: Partial admission and repeated reopen` | green |
| agent-loop → Every committed call has a recoverable outcome | Rewind after recovery | `test/loop/compaction_test.dart` | `agent-loop: Rewind after recovery` | green |
| context-compaction → Route and model compaction policy | Model override | `test/config/compaction_config_test.dart` | `context-compaction: Model override` | green |
| context-compaction → Route and model compaction policy | Invalid or reserved configuration | `test/config/compaction_config_test.dart` | `context-compaction: Invalid or reserved configuration` | green |
| context-compaction → Route and model compaction policy | Explicit off | `test/config/compaction_config_test.dart` | `context-compaction: Explicit off` | green |
| context-compaction → Visible runtime capability detection | Observed support | `test/loop/compaction_test.dart` | `context-compaction: Observed support` | green |
| context-compaction → Visible runtime capability detection | Threshold request silently ignored | `test/loop/compaction_test.dart` | `context-compaction: Threshold request silently ignored` | green |
| context-compaction → Visible runtime capability detection | Field rejected | `test/loop/compaction_test.dart` | `context-compaction: Field rejected` | green |
| context-compaction → Visible runtime capability detection | Below threshold or inconclusive | `test/loop/compaction_test.dart` | `context-compaction: Below threshold or inconclusive` | green |
| context-compaction → Native boundary and lineage | Two compaction items | `test/loop/compaction_test.dart` | `context-compaction: Two compaction items` | green |
| context-compaction → Native boundary and lineage | Rewind across boundary | `test/loop/compaction_test.dart` | `context-compaction: Rewind across boundary` | green |
| context-compaction → Native boundary and lineage | Changed model or instructions | `test/loop/compaction_test.dart` | `context-compaction: Changed model or instructions` | green |
| context-compaction → Preserved state and safe absence | Replay and fork after compaction | `test/loop/compaction_test.dart` | `context-compaction: Replay and fork after compaction` | green |
| context-compaction → Preserved state and safe absence | Unsupported policy stays explicit | `test/loop/compaction_test.dart` | `context-compaction: Unsupported policy stays explicit` | green |
| context-compaction → Preserved state and safe absence | Mixed lineage history | `test/loop/compaction_test.dart` | `context-compaction: Mixed lineage history` | green |
| context-compaction → Bounded native submission and calibration | Successful calibration despite old large usage | `test/loop/compaction_test.dart` | `context-compaction: Successful calibration despite old large usage` | green |
| context-compaction → Bounded native submission and calibration | Ordinary or suffix admission refuses | `test/loop/compaction_test.dart` | `context-compaction: Ordinary or suffix admission refuses` | green |
| context-compaction → Bounded native submission and calibration | Calibration has no usage or dies | `test/loop/compaction_test.dart` | `context-compaction: Calibration has no usage or dies` | green |
| context-compaction → Durable capability evidence | Estimate-based missing compaction | `test/loop/compaction_test.dart` | `context-compaction: Estimate-based missing compaction` | green |
| context-compaction → Durable capability evidence | Resume and policy change | `test/loop/compaction_test.dart` | `context-compaction: Resume and policy change` | green |
| context-compaction → Durable capability evidence | Rewind removes evidence | `test/loop/compaction_test.dart` | `context-compaction: Rewind removes evidence` | green |
| context-compaction → Captured child policy selection | Different child model and later config edit | `test/tools/agent_compaction_test.dart` | `context-compaction: Different child model and later config edit` | green |
| context-compaction → Captured child policy selection | Invalid launch payload | `test/tools/agent_compaction_test.dart` | `context-compaction: Invalid launch payload` | green |
| context-compaction → Reconstructed visible compaction status | Reconnect after observed compaction | `test/rpc/compaction_status_test.dart` | `context-compaction: Reconnect after observed compaction` | green |
| context-compaction → Reconstructed visible compaction status | Recovery after unsupported route | `test/rpc/compaction_status_test.dart` | `context-compaction: Recovery after unsupported route` | green |
| model-provider → Normalized turn stream | Text answer | `test/provider/chatgpt_adapter_test.dart` | `normalized stream text deltas then usage then completed end_turn` | green |
| model-provider → Normalized turn stream | Stream ends early | `test/provider/chatgpt_adapter_test.dart` | `normalized stream early close ends with protocol failure` | green |
| model-provider → Token-sharing request rules | Token-sharing body | `test/provider/chatgpt_adapter_test.dart` | `plan backend body follows token-sharing rules with allowlisted keys` | green |
| model-provider → Token-sharing request rules | Compacted token-sharing body | `test/provider/compaction_test.dart` | `model-provider: Compacted token-sharing body` | green |
| model-provider → Token-sharing request rules | Tools re-established after a replayed boundary | `test/provider/compaction_test.dart` | `model-provider: Tools re-established after a replayed boundary` | green |
| Amendment regression | Backend clears registration at boundary | `test/provider/compaction_test.dart` | `offline backend resets tool registration at compaction` | green |
| Amendment regression | Settled call and journal reopen | `test/loop/compaction_test.dart` | `tools survive settled-call compaction reconstruction and reopen` | green |
| model-provider → Model listing | Models listed | `test/provider/models_test.dart` | `listed models exclude non-list visibility and unsupported` | green |
| model-provider → Model listing | Context window reported | `test/provider/models_test.dart` | `context_window is read only when an integer above 1` | green |
| model-provider → Model listing | Models endpoint fails | `test/provider/models_test.dart` | `503 fails server with no list` | green |
| model-provider → Model listing | Oversized models response | `test/provider/models_test.dart` | `body over 4 MiB fails protocol` | green |
| model-provider → Model listing | Generic metadata is not route capacity | `test/provider/compaction_test.dart` | `model-provider: Generic metadata is not route capacity` | green |
| model-provider → Opaque compaction stream continuity | Headerless completion with empty output | `test/provider/compaction_test.dart` | `model-provider: Headerless completion with empty output` | green |
| model-provider → Opaque compaction stream continuity | Compaction before interrupted stream | `test/provider/compaction_test.dart` | `model-provider: Compaction before interrupted stream` | green |
| model-provider → Opaque compaction stream continuity | Duplicate or conflicting item | `test/provider/compaction_test.dart` | `model-provider: Duplicate or conflicting item` | green |
| model-provider → Route-qualified capacity configuration | Qualified window | `test/config/compaction_config_test.dart` | `model-provider: Qualified window` | green |
| model-provider → Route-qualified capacity configuration | Legacy misleading window | `test/config/compaction_config_test.dart` | `model-provider: Legacy misleading window` | green |
| model-provider → Route-qualified capacity configuration | Invalid qualified capacity | `test/config/compaction_config_test.dart` | `model-provider: Invalid qualified capacity` | green |
| turn-perception → Turn and budget sections | Known window | `test/loop/compaction_budget_test.dart` | `turn-perception: Known window` | green |
| turn-perception → Turn and budget sections | Unknown window | `test/loop/sensorium_test.dart` | `Turn and budget sections budget line with an unknown window shows ? and no percent` | green |
| turn-perception → Turn and budget sections | Estimated window | `test/loop/compaction_budget_test.dart` | `turn-perception: Estimated window` | green |
| turn-perception → Turn and budget sections | Unqualified metadata | `test/loop/compaction_budget_test.dart` | `turn-perception: Unqualified metadata` | green |
| turn-perception → Context in use | After a step with usage | `test/loop/sensorium_test.dart` | `Context in use interleaved outputs of the baseline step are counted once by provenance` | green |
| turn-perception → Context in use | Step without usage | `test/loop/sensorium_test.dart` | `Context in use cancelled step without usage falls back to the last completed step` | green |
| turn-perception → Context in use | Incomplete step then a new prompt | `test/loop/sensorium_test.dart` | `Context in use incomplete step's usage is not the baseline and the request is sent` | green |
| turn-perception → Context in use | First request after compaction | `test/loop/compaction_budget_test.dart` | `turn-perception: First request after compaction` | green |
| turn-perception → Context in use | Usage after compaction | `test/loop/compaction_budget_test.dart` | `turn-perception: Usage after compaction` | green |
| turn-perception → Context in use | Unknown used context with configured window | `test/loop/compaction_budget_test.dart` | `turn-perception: Unknown used context with configured window` | green |

Rows initially green are unchanged regressions passed individually on 2026-11-02; implementation groups turn new/changed rows green only after verification. Remaining red rows are planned behavior, not tests already written or executed. Each group reruns relevant green rows without artificial failures. Group 4 verifies the owner-moved unknown-used/boundary baseline foundation in `test/loop/compaction_test.dart`; group 5 adds the remaining turn-perception rendering/integration coverage without claiming new red evidence for that existing foundation. Local validation runs one test file at a time, pinned through mise; the full suite is CI-only per repository guard.

## 1. Record the binding contract

- [x] 1.1 Write the supplemental ADR for native opaque continuity, latest-boundary-first lineage validation, captured policy, route-qualified capacity and call recovery; update architecture's ADR index and M2 behavior. Verify links resolve and accepted ADRs plus `docs/sensorium-spec.md` remain unchanged.

## 2. Policy and qualified capacity

- [x] 2.1 Add failing `test/config/compaction_config_test.dart` cases for the map's Route and model compaction policy and Route-qualified capacity configuration rows; include precedence, partial-field merge, unknown keys, minimum threshold, reserved local strategy and legacy migration. Verify failures name absent/new behavior rather than fixture setup.
- [x] 2.2 Implement strict provider/route/model policy and route-capacity configuration, typed effective policy/provenance, defaults and explicit off semantics. Preserve existing config syntax; document exact JSON examples, legacy hint behavior and reserved local strategy. Verify 2.1 passes, rerun the existing config file, and turn those rows green.

## 3. Provider request and stream boundary

- [x] 3.1 Add failing `test/provider/compaction_test.dart` cases for compacted token-sharing body, raw-versus-effective model capacity, headerless/empty-terminal streams, interruption and duplicate/conflicting items. Include malformed/unindexed compaction, text-done without deltas, delta/done deduplication and encrypted output caps. Verify each fails for the intended missing native behavior.
- [x] 3.2 Add typed native request policy and opaque compaction item/event; serialize inline context_management and collect indexed output-item-done items without Content-Type/terminal-array assumptions. Preserve existing limits, tool holding, error sanitization and retry rules. Document observed-versus-guaranteed route support. Verify new provider rows pass and rerun green provider/model-listing rows one file at a time; turn implemented rows green.

## 4. Journal projection and complete call recovery

- [x] 4.1 Add failing `test/loop/compaction_test.dart` tests for completed opaque output, crash-before-commit, latest-boundary/suffix selection, mixed-lineage refusal, changed model/instructions, rewind, fork, scratch/handle/correlation preservation and boundary-in-tool-step ordering. Include the minimal unknown-used and boundary-aware baseline foundation moved from group 5 by owner approval, so next-request projection tests neither estimate ciphertext nor reuse pre-boundary usage. Verify new persistence/projection/foundation tests fail before implementation while existing green conversation/request rows remain green.
- [x] 4.2 Implement additive admission lineage/boundary/policy and completed compaction output, latest-boundary-first validation and bounded suffix construction before expensive result composition. Implement pre-cut result notes with verbatim central envelopes and post-cut paired outputs. Include the owner-approved minimal unknown-used and boundary-aware budget foundation: represent unknown compacted usage and match usage baselines to lineage/boundary without ciphertext estimates or obsolete prefix reuse. Leave capability detection, calibration admission, durable evidence and remaining budget rendering/tests in group 5. Document upgrade-only compacted-session writing. Verify 4.1 tests and existing builder/context regressions pass; turn their mapped rows green.
- [x] 4.3 Add failing storage/restart tests for Every committed call has a recoverable outcome: death before any admission, partial admission, interruption during recovery, repeated reopen, rewind and conflicting metadata, covering calls on both sides of a cut. Verify the current admitted-node-only recovery reproduces the missing-position failures without running effects.
- [x] 4.4 Extend attach/rewind reconciliation to enumerate committed call positions, guard terminal cancellation/result reconstruction for missing nodes, preserve existing results/live ownership, and block request construction until terminal coverage. Keep recovery idempotent and no-effect. Document the new cancellation envelope and recovery reason. Verify 4.3 and relevant existing job/recovery files pass individually; turn those rows green.

## 5. Capability evidence, admission and budget

- [x] 5.1 Add failing loop cases for Visible runtime capability detection, Unsupported policy stays explicit, Bounded native submission and calibration, Durable capability evidence and Compaction missing at safety threshold. Include the 120k-input/6k-output deadlock regression, unknown usage, huge post-cut outputs, durable allowance consumption, policy return, resume and rewind. Verify intended failures before changing admission/evidence logic.
- [x] 5.2 Implement native threshold detection, qualified unsupported evidence, durable policy-specific status, ordinary ceiling and one bounded admission-recorded calibration allowance per boundary. Never retry a possibly admitted request without the field; retain explicit recovery choices. Document safety ceiling versus unknown route capacity and calibration residual risk. Verify 5.1 passes and existing overflow/retry regressions remain green; update mapped rows.
- [x] 5.3 Add failing `test/loop/compaction_budget_test.dart` cases for all remaining red turn-perception rows, including estimate labels, unknown compacted usage with a configured window, first post-boundary request and compatible post-compaction usage. The minimal unknown-used/boundary-aware foundation and its projection tests moved to 4.1–4.2 by owner approval; rerun that coverage without claiming new red evidence for already implemented behavior. Verify remaining rendering/accounting failures before changing that behavior.
- [x] 5.4 Build on the unknown-used and lineage/boundary-aware baseline foundation delivered in 4.2; implement the remaining honest unknown/estimated used/window presentation and budget integration without ciphertext-token estimates or obsolete prefix rejection. Capability detection, calibration admission and durable evidence remain in 5.1–5.2. Keep exactly two request-only sensorium lines. Update budget documentation. Verify 5.3 passes and rerun the green sensorium and group 4 foundation rows individually; turn the remaining mapped rows green.

## 6. Child and user-visible status integration

- [x] 6.1 Add failing `test/tools/agent_compaction_test.dart` cases for captured child policy selection, different models, config edits, invalid/oversized payloads and native argv bounds. Verify actual launch-seam failures before wiring the captured policy payload.
- [x] 6.2 Wire validated captured policy into child launch and child-local resolution/evidence without changing effort inheritance or no-nested-agent policy. Document child policy semantics. Verify 6.1 passes plus existing child/effort regressions individually, including native Windows argv coverage; turn child rows green.
- [x] 6.3 Add failing `test/rpc/compaction_status_test.dart` cases for reconnect after observed compaction and explicit recovery after unsupported route. Exercise RPC materialization/client rendering and model-visible notice reconstruction; verify red failures at those real boundaries.
- [x] 6.4 Expose scalar policy/provenance, capability reason, boundary identity and capacity/budget quality via RPC and line-client projections; derive recovery notices without leaking ciphertext or raw server text. Document status and explicit recovery options. Verify 6.3 passes, existing RPC/client regressions remain green, and turn status rows green.

## 7. Delivery-level verification

- [x] 7.1 Run single-file pinned tests for every map file, check every delta-spec scenario has passing named tests and no red rows remain, and mechanically validate the spec-to-map correspondence. Run mise format:check, analyze, strict OpenSpec validation and secrets checks. Verify only intended source/docs/tests changed and record full-suite execution as CI-only.
- [x] 7.2 Add/run a deterministic long-history integration fixture with repeated native boundaries, result handles, synthetic verbatim scratch, request/child correlation, cancellation, resume, rewind and fork. Verify identical replayed projections and handle access; measure 10x/100x metadata scans and prove discarded prefixes are not repeatedly composed. Keep output bounded and report calibration/capacity uncertainty.
- [x] 7.3 Qualify delivery through the required pre-ship review, one PR, Linux/Windows delivery-head PR CI and manually dispatched delivery-head Nightly. Record receipts and obtain owner acceptance from a real long-change dogfood run with visible compaction/status. No new paid probe without owner approval; no architecture acceptance claim substitutes for those receipts.

## Workflow follow-up

- Archive and finish through the configured PR workflow only after implementation, qualification and acceptance; keep required pre-ship/cross-model reviews enabled. Archive is not a tracked implementation task.
