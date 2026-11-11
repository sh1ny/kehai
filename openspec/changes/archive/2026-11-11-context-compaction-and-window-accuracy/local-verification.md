# Delivery verification

## Delivery continuation — 2026-11-11

- PR: [#30](https://github.com/sh1ny/kehai/pull/30). Final qualified code/test head:
  `925ff9ac6e311f00f065a8d21f78cab07df75085`. Initial task 7.3 qualification
  was at `1bafce2b5fecd38fa594d7eb4fdae96fae519e05`; the later output-index
  ownership fix below changed production code and was requalified separately.
- The three original review threads were fixed in `cfe3b01` and resolved.
  Claude found an additional uncompacted-history lineage regression; all six
  native-on/off instruction/model/tool cases failed before `4d2c7a8` and passed
  afterward. Request-builder and compaction files passed 64 tests together.
- Targeted provider, usage-budget and real-child job tests passed. The MCP
  transport timed out after 30 seconds during the first four-file run, but its
  persisted JSON reporter completed. One new fixture used an incorrect backend
  code; correcting that fixture yielded all 20 provider tests passing.
- Windows deadline tests now fire the actual supervisor callback after real
  child output is observed. Linux CI then exposed a separate crash-fixture race:
  killing the job before its writer could commit a terminal intent. `a34afea`
  kills the writer first and uses release-marker waits instead of `sleep 30`.
  The existing second-attach regression passed locally on Windows; both-OS
  PR CI subsequently passed at `a34afea`.
  Windows Nightly at that head failed a separate sub-second elapsed assertion
  around the second, cached search call (`2.911042s`, not a probe deadline
  failure). `1bafce2` retains the deadline, process-termination, no-second-probe
  and cached-error checks, with wall clocks used only as generous hang guards.
  All four probe regressions pass locally.
- Claude Opus 5.5 (`claude-opus-5-5`, reported by the Orca structured worker)
  reviewed through Orca. The final code/test review covers `925ff9a`: no P0/P1
  findings, the same four accepted nonblocking P3 notes. The review executed no code or tests. Machine-local
  Specwright receipts record the Claude route; their actual-model field is
  unknown, distinct from the worker's model report.
- Owner explicitly selected Claude-through-Orca instead of the configured
  GitHub Codex gate for this PR and authorized further blocker-fix rounds.
  No review-request comment was posted; existing GitHub automation independently
  reviewed new commits. CI and acceptance gates were not waived.
- Subsequent GitHub feedback exposed conflicting text and compaction identities
  claiming one output index. The regression failed before `925ff9a`; that fix
  rejects contradictory ownership in both arrival orders and unindexed
  reconciliation without publishing a successful compaction boundary.
  The provider file passed all 21 tests after the fix; 49 adapter and 46 loop
  tests passed with the same production source in the preceding combined run.
  Static analysis reported no errors. The feedback thread was resolved.

### Real-provider coding and preservation evidence

Owner authorized an unattended subscription-backed run, not blanket repository
permissions. A real adapter, exchange driver and tool runtime repaired the four
defects in a disposable export of baseline `9b7ec0c`; a custom gate confined
file access to that workspace and exposed no shell or agent tool.

- Model/route: `gpt-6.1-sol`, `openai/chatgpt-account`, effort `medium`;
  controlled native threshold **32000**, not a change to the production default.
- **83 provider requests, three native compaction items and 84 tool calls**.
  Tools remained usable after all three boundaries.
- The external harness cancelled the initial exchange at its 12-minute guard.
  This was not a provider overflow. Explicit continuation completed three
  exchanges; a further real coding exchange fixed a regression found by the
  parent's targeted checks. No automatic overflow resend is claimed.
- The generated-code check initially passed 75 tests and failed one existing
  partial-text assertion. Kehai repaired its implementation without weakening
  that assertion; the affected provider file then passed all 20 tests.
- Reopen reconstructed an identical canonical tree. Protected scratch bytes and
  early handle `r/69ba65aaf0eb` remained byte-identical; the model actually paged
  that handle and reread `PR30-LIVE-SCRATCH-ORBIT-7` after compaction/reopen.
- A real `RpcServer` snapshot, with no new provider submission, reconstructed
  `observed-supported`, `compatible` continuity, an active boundary, unknown
  route capacity and an estimate based on compatible usage.
- Local receipts: `.dart_tool/pr30-live-receipts/`, including the real journal,
  `events.jsonl`, continuation answers and `rpc-compaction-status.json`.

This is a real coding rehearsal, not a claim that Kehai alone authored the
delivery branch, a default-100k threshold qualification or an exact route-capacity
measurement. Live child-process preservation was not exercised by this rehearsal;
the existing deterministic integration and child-launch regressions remain its
separate evidence.

Owner accepted these task 7.3 dogfood receipts and caveats on 2026-11-11 and
authorized spec sync, archive and merge only after current-head CI/Nightly and
final review gates pass. The accepted nonblocking notes are: unproven
near-threshold false-unsupported risk; repeating recovery notices; capability
evidence reset on instruction/tool lineage changes; and possible orphaned test
jobs if a fixture exits before its kill path.

### Current delivery gates

Both operating systems passed on final qualified code/test head
`925ff9ac6e311f00f065a8d21f78cab07df75085`:

- [PR CI 43071837352](https://github.com/sh1ny/kehai/actions/runs/43071837352):
  Linux and Windows checks **SUCCESS**.
- [Manually dispatched Nightly 43072036558](https://github.com/sh1ny/kehai/actions/runs/43072036558):
  Linux and Windows tests **SUCCESS**, verified against that exact head.
- Claude-through-Orca pre-ship gate passed on that exact head. Owner acceptance
  above completes task 7.3; no failed run was waived.

The initial task 7.3 qualification at `1bafce2` also passed both-OS
[PR CI 43064906434](https://github.com/sh1ny/kehai/actions/runs/43064906434)
and [Nightly 43064918767](https://github.com/sh1ny/kehai/actions/runs/43064918767),
before the later feedback fix and its fresh qualification.

The rehearsal workspace and throwaway Dart drivers were removed. Its generated
repair patch is retained at `.dart_tool/pr30-live-receipts/generated-repair.patch`,
alongside the real journal, results and acceptance/status receipts. The archive
commit changes no production code or tests; its head-specific CI/Nightly and
review gates must pass before merge and appear in PR receipts.

## Historical local verification — 2026-11-02

### Scope and publication hold

Local-only verification of 7.1 and 7.2. HEAD remains `e282b47` while group 7 is partial. Per owner instruction, no push, PR lookup/creation, CI dispatch, other GitHub operation, or paid provider probe was performed. The full suite is CI-only and was not run locally. Task 7.3 remains incomplete: required pre-ship review, delivery-head Linux/Windows PR CI, delivery-head Nightly receipts, and owner acceptance from real long-change dogfood are still outstanding. No architecture/delivery acceptance is claimed.

Group-granularity commits require all of group 7 to be complete; this session leaves its files and ticks uncommitted rather than creating a partial group commit. No production source was changed this session.

### Commands and results

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

### Deterministic long-history fixture

`test/loop/compaction_long_history_test.dart` exercises 20 repeated native boundaries followed by committed calls straddling a final cut with missing runtime admission. It checks terminal cancellation without effects, idempotent reopen recovery, identical request projections after journal replay and fork, byte-for-byte synthetic scratch and stored result handles, synthetic request/child correlation metadata, rewind across the final cut, and fork independence. Synthetic correlation metadata is not evidence of a real child/provider dogfood run; launch policy and RPC boundaries are covered separately by the mapped files.

The scale test builds histories with 10, 100 and 1,000 discarded-prefix steps (baseline, 10x and 100x). Three builds at each size instrument result file construction and reads through `IOOverrides`.

| Prefix steps | Metadata steps | Output entries | Builds | Discarded result file attempts | Retained result reads | Elapsed µs (one local sample) |
|---:|---:|---:|---:|---:|---:|---:|
| 10 | 11 | 22 | 3 | 0 | 3 | 2,885 |
| 100 | 101 | 202 | 3 | 0 | 3 | 7,153 |
| 1,000 | 1,001 | 2,002 | 3 | 0 | 3 | 24,589 |

Metadata volume is counted mechanically; elapsed time measures the entire repeated build/metadata-scan workload, not an instrumented production loop iteration counter or a stable performance threshold. Discarded result composition stays absent while retained result reads remain constant. This does not claim constant-time metadata traversal; the implementation still scans/copies metadata.

### Remaining uncertainty

The fixture uses synthetic opaque items, never decrypts or estimates ciphertext, and asserts unknown compacted usage and unknown route capacity. Local deterministic success cannot establish a real route's capacity, native compaction support, calibration safety, or future provider behavior. Existing bounded calibration/unsupported-route scenarios passed, but the residual unknown opaque-size risk and explicit recovery choices remain. Real visible-compaction/status dogfood and delivery CI receipts are still required under 7.3.

### Delegation and cleanup

Read-only reconnaissance agents timed out without a usable report. The implementer created the fixture, then failed on a lost model connection; the parent inspected it and reran all test/check commands reported above. All agent jobs are settled. Process inspection found only pre-existing Dart/MCP processes (started before this session), which were left alone; no test/check shell from this work remains running.
