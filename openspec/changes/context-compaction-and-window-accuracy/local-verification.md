# Group 7 local verification — 2026-11-02

## Scope and publication hold

Local-only verification of 7.1 and 7.2. HEAD remains `e282b47` while group 7 is partial. Per owner instruction, no push, PR lookup/creation, CI dispatch, other GitHub operation, or paid provider probe was performed. The full suite is CI-only and was not run locally. Task 7.3 remains incomplete: required pre-ship review, delivery-head Linux/Windows PR CI, delivery-head Nightly receipts, and owner acceptance from real long-change dogfood are still outstanding. No architecture/delivery acceptance is claimed.

Group-granularity commits require all of group 7 to be complete; this session leaves its files and ticks uncommitted rather than creating a partial group commit. No production source was changed this session.

## Commands and results

`mise install` confirmed the pinned tools were already installed. Each test below was run separately with the literal command `mise exec -- dart test <file> -j 1`, with stdout/stderr captured in `.dart_tool/group7/`. No command ran the whole suite.

| File | Passing tests |
|---|---:|
| `test/loop/driver_test.dart` | 21 |
| `test/loop/request_builder_test.dart` | 12 |
| `test/loop/compaction_test.dart` | 44 |
| `test/loop/context_test.dart` | 11 |
| `test/config/compaction_config_test.dart` | 6 |
| `test/tools/agent_compaction_test.dart` | 5 |
| `test/rpc/compaction_status_test.dart` | 5 |
| `test/provider/chatgpt_adapter_test.dart` | 49 |
| `test/provider/compaction_test.dart` | 9 |
| `test/provider/models_test.dart` | 9 |
| `test/loop/compaction_budget_test.dart` | 6 |
| `test/loop/sensorium_test.dart` | 10 |
| `test/loop/compaction_long_history_test.dart` (new fixture) | 2 |

The 12 unique map files passed 187 tests; the new fixture passed two additional tests. `python tool/validate_compaction_map.py` passed: all 65 delta-spec scenarios correspond exactly to 65 unique green map rows, and every mapped fully qualified test name appears in a passing single-file execution log. The helper is read-only and performs no test execution or network access.

Additional checks passed:

- `mise run format:check`: 285 Dart files, zero formatting changes.
- `mise run analyze`: no issues, fatal infos enabled.
- `mise run openspec:validate`: all 24 items passed under `--all --strict`.
- `mise run secrets`: no leaks found.
- `git diff --check`: passed; branch changes are scoped source/docs/tests plus this change's planning artifacts. Accepted ADRs and `docs/sensorium-spec.md` are not changed by the branch.

The guard rejected `mise run test -- <file> -j 1` and a shell-loop form using a variable filename before execution. The successful runs instead used explicit literal single-file commands shown above; neither rejection was bypassed with a full-suite command.

## Deterministic long-history fixture

`test/loop/compaction_long_history_test.dart` exercises 20 repeated native boundaries followed by committed calls straddling a final cut with missing runtime admission. It checks terminal cancellation without effects, idempotent reopen recovery, identical request projections after journal replay and fork, byte-for-byte synthetic scratch and stored result handles, synthetic request/child correlation metadata, rewind across the final cut, and fork independence. Synthetic correlation metadata is not evidence of a real child/provider dogfood run; launch policy and RPC boundaries are covered separately by the mapped files.

The scale test builds histories with 10, 100 and 1,000 discarded-prefix steps (baseline, 10x and 100x). Three builds at each size instrument result file construction and reads through `IOOverrides`.

| Prefix steps | Metadata steps | Output entries | Builds | Discarded result file attempts | Retained result reads | Elapsed µs (one local sample) |
|---:|---:|---:|---:|---:|---:|---:|
| 10 | 11 | 22 | 3 | 0 | 3 | 2,885 |
| 100 | 101 | 202 | 3 | 0 | 3 | 7,153 |
| 1,000 | 1,001 | 2,002 | 3 | 0 | 3 | 24,589 |

Metadata volume is counted mechanically; elapsed time measures the entire repeated build/metadata-scan workload, not an instrumented production loop iteration counter or a stable performance threshold. Discarded result composition stays absent while retained result reads remain constant. This does not claim constant-time metadata traversal; the implementation still scans/copies metadata.

## Remaining uncertainty

The fixture uses synthetic opaque items, never decrypts or estimates ciphertext, and asserts unknown compacted usage and unknown route capacity. Local deterministic success cannot establish a real route's capacity, native compaction support, calibration safety, or future provider behavior. Existing bounded calibration/unsupported-route scenarios passed, but the residual unknown opaque-size risk and explicit recovery choices remain. Real visible-compaction/status dogfood and delivery CI receipts are still required under 7.3.

## Delegation and cleanup

Read-only reconnaissance agents timed out without a usable report. The implementer created the fixture, then failed on a lost model connection; the parent inspected it and reran all test/check commands reported above. All agent jobs are settled. Process inspection found only pre-existing Dart/MCP processes (started before this session), which were left alone; no test/check shell from this work remains running.
