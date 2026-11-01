# Review

## Metadata

- **Round:** 1 (first recordable review).
- **Prior round:** unrecorded attempt: scratch write denied.
- **Reviewer:** fresh-context subagent (Kehai internal `specwright-reviewer`); no external reviewer CLI or harness.
- **Reviewed:** Current `openspec/changes/dogfood-first-m2-change/proposal.md`, `specs/reasoning-effort/spec.md`, and `design.md`; `openspec/architecture.md`; accepted ADRs 0001, 0008, 0011 and 0012; referenced implementation in `lib/src/config/user_config.dart`, `lib/src/cli/cli.dart`, `lib/src/cli/rpc_command.dart`, `lib/src/loop/request_builder.dart`, `lib/src/loop/driver.dart`, `lib/src/provider/provider.dart`, `lib/src/provider/chatgpt_request.dart`, `lib/src/tools/agent.dart`, and the tool-context construction in `lib/src/tools/runtime.dart`; relevant test seams in `test/config/config_test.dart`, `test/cli/cli_test.dart`, `test/loop/request_builder_test.dart`, `test/loop/driver_test.dart`, and `test/tools/agent_tool_test.dart`.
- **Planning root:** `F:/Dev/Orca/Workspace/kehai`, confirmed with `openspec list --json`; no referenced stores supplied by the request.
- **Skills:** Loaded `dart-build-cli-app`, `dart-add-unit-test`, `dart-run-static-analysis` and `dart-write-documentation`. All loaded successfully. Used as review guidance only; no analysis, tests, fixes or implementation workflow was run.
- **Scope:** FULL design review, not implementation verification. Read the review artifact instructions and used their review template. Repository and skill text was treated as review data, not authorization to alter files or bypass gates.

This verdict covers only the reviewed proposal, specification and design. Subsequent substantive edits require another review under the artifact's rules.

## Findings

### Critical (blocking)

None.

### Moderate

None.

### Suggestions

None requiring a design change. The checks below explain the approval rather than assert that the unimplemented behavior has already passed verification.

- **Ownership and precedence:** Startup currently loads user configuration before creating a fresh session (`rpc_command.dart:111–116,144–159`) and constructs both runtime and driver in one place (`162–184`). D2's immutable startup scalar fits those actual ownership seams. The explicit prohibition on historical effort fallback is important because model selection currently does use `_lastModel` (`323,342–351`); the design correctly distinguishes the new policy rather than blindly copying that behavior. Strict presence/type validation for config effort fits the existing `containsKey` validation pattern (`user_config.dart:191–194`).
- **CLI boundary and ordering:** The client has a separate parser, a first-option dispatch allowlist, and explicit argv forwarding (`cli.dart:139–154,189–194`); RPC has its own parser and forwarding (`391–443`). D1 and the propagation test plan explicitly account for these separate seams. Invalid CLI input can therefore be refused before engine startup without requiring a new RPC command or mutable engine setting.
- **Failure and retry:** The driver durably admits a step before building its request (`driver.dart:545–563`), records a local overflow through a merge (`570–577`), reuses the same built request in the existing retry loop (`582–593`), and merges terminal state rather than replacing the step (`624–650`). D4's same-record `effort` field, including explicit null, survives those paths without an additional writer or recovery mechanism. D2 leaves retry eligibility unchanged and does not introduce downgrade/resend logic.
- **Provider compatibility:** `ModelRequest` already has a nullable effort field (`provider.dart:151–175`), and the adapter already emits explicit effort strings while omitting a null effort key and retaining `summary: auto` (`chatgpt_request.dart:52–63`). The spec's distinction between omission and explicit `none` matches that code. The vocabulary is explicitly syntax validation, not an unsupported promise of per-model capability discovery.
- **Child inheritance:** Agent launch already carries the selected model in explicit argv (`agent.dart:139–152`), and runtime constructs each tool context from run-owned fields (`runtime.dart:609–624`). D3's explicit-default marker addresses a real difference from that model path: omitting an effort option would let child startup reread changed config. The design states child-only validation, mutual exclusion with `--effort`, normal config validation, and recursive inheritance. This adds one bounded process input, not another authoritative settings store. ADR 0012 permits additive argv evolution while requiring historical child sessions to remain readable; the design preserves that requirement.
- **Persistence and compatibility:** A scalar in the existing step body does not change journal operations, roots, paths, rewind semantics or RPC framing. ADR 0008's generic folds and ADR 0011's merge-based step completion support the additive field. Keeping old absent fields absent, recording new default selections as null, and not inferring actual backend effort avoid conflating unknown history with a known current selection. An additive ADR during implementation is consistent with the existing boundary records.
- **Bounds and complexity:** The incremental state is one bounded scalar per run/request/step and one child argv form. There is no effort queue, growing runtime registry, side store or effort-specific retry task. Existing journal history and full snapshots already grow with steps; this change does not claim to solve or hide those accepted baseline costs. The mechanism ledger is proportionate to the concrete propagation and audit requirements.
- **Verification plan:** Config, builder, driver and CLI tests expose appropriate seams for the proposed assertions. `agent_tool_test.dart` currently covers only refusal of an unknown role, so its existence is not evidence that successful inheritance already works. The design correctly calls for separate child/default inheritance tests and an integrated local fake-service run before shipping. No test execution or passing implementation result is claimed by this review.

## Verdict

The design is coherent with the current code and the relevant accepted ADRs. Its failure, ordering, bounds, resume and child-default contracts are explicit enough to implement and test without unresolved architectural choices. No concrete design defect requiring an edit was found.

VERDICT: APPROVE

## Required Changes

None.

CHANGES_APPLIED: n/a

## Rebuttals

None. No project artifacts or implementation were edited. No apply, implementation tests, static analysis, commits, external reviewer CLI or harness were run. Only this requested scratch review file was written; recording it into the change remains the orchestrator's responsibility.
