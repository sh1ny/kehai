# Apply qualification evidence

## Ownership and sequencing

- Executing orchestrator: Kehai, original RPC session `20261111T202801Z-9e40fe1e`, continued across ordinary transport step limits. The outer harness supplies tool results only.
- Groups 1–4 are committed through `c5acf64bde915bad64a4bf5851e63eecafba2952`; clean tree and task-cover reconciliation confirmed 13 covered tasks, no gaps, duplicates or cross-group trailers before group 5.
- During qualification, the user explicitly authorized a **group-5-only staged ordering exception**: commit verified 5.1/5.2 while 5.3 remains unticked; run configured pre-ship review and ship as `sh1ny`; obtain CI/Nightly receipts; commit 5.3 separately with accurate task coverage; then requalify the final delivery head. No gate is waived. No global setting amendment, archive or merge is authorized.

## 5.1 Integrated verification

Parent-selected and parent-judged actual official Dart MCP action, relayed through the approved restricted ask transport:

```json
{"tool":"run_tests","arguments":{"roots":[{"root":"file:///F:/Dev/Orca/Workspace/kehai","paths":["test/loop","test/rpc","test/session","test/tools/scratch_test.dart","test/tools/runtime_test.dart","test/config/config_test.dart"]}],"arguments":{"reporter":"expanded","concurrency":"1","timeout":"30s"}}}
```

Actual returned result: **`03:29 +404 ~1: All tests passed!`** No failures. The single skip is the existing Unix-only SIGINT case on native Windows, not a waiver of Windows qualification. Full same-run output was retained by the transport. This fresh integrated run covers all surviving test-map cases, including baseline provenance, typed availability/folds, config, driver/RPC, scratch and native session continuity.

Actual official `analyze_files`, roots `lib` and `test`, `applyFixes:false`: **No errors**. Pinned `mise run format:check`: **290 files, zero changes**, exit 0. `mise exec -- openspec validate sensorium-block-and-scratchpad --strict` and `git diff --check`: exit 0.

A read-only implementer audit (`j-16393b63`) identified planned test names that had become groups/families or moved files. The parent corrected the map references to the actual executed cases; no test behavior or acceptance requirement changed. The temporary default/child roster wiring checks were deliberately removed after their actual red/green proof, not recreated as permanent roster-copy tests. Their executed evidence remains in group-2 commit `1f54d39`: scratch plus temporary smoke **32 passed**, config **21**, runtime **23**, child mode **8**. Group-3 commit `8fe77ee` records the parent official **105 passed** composition/config/accounting selection; group-4 commit `c5acf64` records **114 passed** and the preceding broader **404 passed / one platform skip** run.

Every map row now has executed green evidence from this integrated run or the specifically preserved temporary smoke receipt. Production scratch uses `{value: text}`; no pending schema-migration placeholder was accepted. Groups 2–4 each committed their tests and README changes with implementation; group 1 committed its additive ADR/index and reviewed apply receipt.

### Transport and workflow friction

- Tests and analysis used the same configured official server through the user-approved ask relay, not shell Dart tests. Allowed relay actions remain `run_tests`, non-fixing `analyze_files`, and the three approved read-only LSP commands. No dependency installation or `.mcp.json` change occurred.
- Implementer children actually lacked `ask` on their tool surface. The parent performed official red/green calls between tests-only and implementation delegations and judged returned results; child-only claims were not accepted as verification.
- Earlier 30-second transport timeouts had unknown outcomes, not inferred greens. The repaired 600-second client deadline allowed actual reruns after settlement. This qualification run returned an actual result.
- Permission/session allow rules, workspace-scoped rules, configuration reload, shell-chain proof, relative-PATH coverage and timing/process issue #28 remain assigned to `windows-tool-parity-and-m2-qualification` under the reviewed design. No broader approval or external-directory grant was introduced to hide friction. This assignment does not waive this change's gates.

## 5.2 Live dogfood

### Execution and safety

Actual runs used Kehai's production `ExchangeDriver`, `ToolRuntime`, `ResultStore`, `SessionWriter`, ChatGPT-account adapter/refresher and native Windows secure credential backend, with the configured `gpt-6.1-sol` model and unchanged inherited effort. The ignored workspace-only helper added restrictive source/report path checks, denied shell/agent/job mutations, and retained production permissions/hooks. Each of the three scratch writes per lane received its own explicit one-time user approval. No user config, credential copy, external-directory grant or dependency was changed.

The user authorized an isolated **in-memory dogfood-only threshold**. A generation-free measurement (`1794443188651878-3daa77df`) returned retained baseline **7602**, prompt estimate **386**; the parent selected **18824 = 2*(7602+386+400)+2048**, safely above the retained baseline with prompt/scratch allowance. Built-in unmodified threshold remains **100000**. All native admission/calibration guards remained active; this was not a force-compaction command. The selected backend advertised 500000, while the qualified context-window source correctly remained unknown.

The real multi-step change was an ASCII source-review report with exactly `Summary` and `Evidence` headings, first created then factually amended after reopen. Both lanes inspected actual sensorium/driver source through tools, obtained the shortened driver result `r/5e323dc02bd5`, and successfully used `search_result` plus `read_more` on that same full result after reopen. They retained scratch values `format=ASCII only`, `sections=Summary and Evidence headings`, and their lane-specific report target. No scratch constraint was repeated or rewritten in the reopen prompt. The reports distinguish local durable admission from provider receipt and test nonexecution from the real provider-backed review itself.

### Actual run receipts (UTC)

All five live jobs settled with exit **0**, every exchange terminal state `done`, and explicit idle/finish/closed receipts; no provider process was left running. Raw safe events, private journals and helper stay ignored under `.dart_tool/sensorium-dogfood/`; no private journal, credential or opaque item payload is published.

| Lane / phase | Run id | Provider sends | Block estimates | Closed |
|---|---|---:|---:|---|
| A initial | `1794443221891675-5f94b05c` | 14 | 134–177 | 2026-11-12T00:31:39.837978Z |
| A reopened | `1794443603425396-e7a494ff` | 6 | 180–181 | 2026-11-12T00:35:17.828564Z |
| B initial | `1794443649741361-c2805187` | 12 | 134–177 | 2026-11-12T00:39:56.860585Z |
| B reopened | `1794444034974214-91474d53` | 6 | 177–181 | 2026-11-12T00:42:51.343057Z |
| B post-boundary reopened | `1794444198914567-fa0a36e8` | 4 | 181 | 2026-11-12T00:44:10.334920Z |

A committed native boundary **`s-00000014:0:cmp_045af87c25693403016af508b08a0887d2a933c2f6fd771024`**. Its first post-reopen request (turn 15) selected that boundary with one opaque item, retained **8183**, block **180**, total usage **unknown**, and all scratch constraints in the actual final request item. Fresh input usage **11614** then restored compatible usage; the boundary itself was not counted as a usage measurement.

B initially stopped below threshold with no boundary (that absence was not called success). Its reopened turn 15 crossed the threshold and committed **`s-00000015:0:cmp_0c1470ab055e4805016af50b0f1a9087d281f68d3854455598`**. Turn 16 used one opaque item, retained **9285**, block **180**, total usage **unknown**; fresh input usage **12850** followed. A further actual process reopen selected that same boundary at turn 19, one opaque item, retained **13019**, block **181**, compatible estimated usage **15267** from the already completed usage baseline. Full-result search/read-more remained successful. Both lanes ended compatible with `observed-supported`, no native stop/recovery notice. Every recorded request's admitted observation equalled its actual final item; scratch in each request matched the then-current materialized scratch, with all three values retained after the three approved writes and through every later follow-up/reopen.

### Provider input / cached-input measurements

Arrays are per provider send in the phase order above, not local token estimates:

- A initial input: `[4894,4948,5008,5086,8831,12572,12862,15840,16311,17019,17069,17132,18008,20615]`; cached: `[0,0,0,0,0,0,0,0,3200,0,0,0,3200,0]`.
- A reopened input: `[11614,11755,12330,13223,13747,15249]`; cached: `[0,3200,0,0,0,0]`.
- B initial input: `[4894,4948,5008,5086,8832,12573,12920,16108,16423,17178,17254,18223]`; cached: `[0,0,0,0,0,0,0,0,0,0,0,0]`.
- B reopened input: `[18529,18668,21300,12850,13355,14887]`; cached: `[3200,3200,3200,3200,0,3200]`.
- B post-boundary reopened input: `[15160,15268,15843,16956]`; cached: `[0,6656,3200,6656]`.

These are two equivalent **full-observation** task outcomes, not a legacy/minimal-mode comparison or cache-neutrality benchmark. Both produced an accurate, ASCII-only two-heading report, retained the target and constraints through compaction/reopen, and reused the original full result successfully. A final report: **4833 bytes**, SHA-256 `78632babd6107c69da2527c0c68068489da7257037d82802075ab9d1b9d3ea46`; B: **5046 bytes**, SHA-256 `367d2227c523e8f2b457f98af568c88ef2752007104ea7dae7a298a0390ccee1`. Exact prose, send counts and boundary timing differed, as expected for live generation. Cached-input counts varied; no cache neutrality, cost saving, task-quality superiority or known context capacity is inferred.

### Additional observed friction

- The ignored helper's first actual compile failed on a missing `Workspace` import despite an earlier no-errors analysis response for that ignored file. No generation occurred in that failed invocation. The parent traced the declaration, added the correct import, then obtained the actual successful measurement before live work. The analysis response was not accepted as compile/test proof.
- Atomic replacement of the ignored control file did not reliably trigger the native Windows watcher. The parent inspected current run/sequence/prompt state, then appended a newline to trigger a modify event for the same already-written sequence; the helper consumed sequences once. No uncertain operation or approval was replayed, and no duplicate provider job was launched across continuation boundaries.
- A denied lane-A directory listing and initial missing-report reads were retained as ordinary tool outcomes, not permission-expansion prompts. Scope stayed restricted. These native Windows tooling/transport-control limitations join the existing `windows-tool-parity-and-m2-qualification` follow-up; they do not waive this slice's actual qualification gates.

## 5.3 Delivery gates

Pending. No pre-ship, delivery PR CI, Nightly, archive, merge or release evidence is claimed here. The old M1 Nightly waiver is not evidence for this change. Exact delivery-head receipts and final-head requalification remain required.
