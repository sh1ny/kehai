# kehai Roadmap

[Strategy](strategy.md) · [Architecture / ADRs](architecture.md) · [Design authority](../docs/sensorium-spec.md) · [Baseline approval](architecture-review.md)

## Now: M1 — Headless walking skeleton

**Outcome:** a real Anthropic coding turn through a dumb line-mode RPC client, with durable, rewindable/forkable sessions, inspectable full results and supervised native jobs. **No TUI.**

**Exit criteria** (evidence recorded at milestone close, not claimed here):
- Seeded property tests generate valid sessions with every supported tree subtree and mixed patches; materialization equals reference replay. Rewind at random retained turns, persist/resume and compare with original journal replay at that point; replay the recorded continuation and recover the same final tree without repeating external effects. Forks evolve independently; deleting a parent preserves fork result handles. No feature-specific rewind code. (agent)
- Exercise torn-tail recovery, interior corruption refusal, storage failure, stale callbacks, running-job rewind, interrupted resume and RPC reconnect/correlation; no automatic effect replay or silent partial state. (agent)
- Core `read`, hash-anchor `edit`, `write`, `bash`, `grep`, `find`, `ls` work through RPC; stale anchors reject; long stdout/stderr remain pageable/searchable through handles with explicit central cuts and bounded `notrunc` failure. (agent)
- Native Windows without WSL and Linux smoke runs cover detected installed shells, PTY/ConPTY, bundled rg, job cancellation and line-client resume. A live configured Anthropic session reads, edits and runs a command; credentials never enter harness diagnostics/journal. AOT release packaging accounts for native assets. (agent)

**Changes** (one PR each; every entry requires the previous entry merged):
1. `establish-session-tree-journal` — engine/cli package boundary, typed tree, minimal versioned atomic patch transactions, durable append/materialization and journal-format fixtures.
2. `extend-journal-to-rewind-fork-resume` — generic tree restoration, fork lineage, restart semantics and randomized replay equivalence first, before any UI or feature-specific state handling.
3. `extend-session-with-result-handles` — immutable full-result payloads, tree-owned lifetime/fork safety, envelope, paging/search and central model rendering/truncation.
4. `extend-session-with-native-jobs` — one supervisor and blocking budget, bounded streams, real-shell discovery, PTY/ConPTY, cancellation and generic resource reconciliation.
5. `extend-session-with-core-tools` — all seven core tools, hash-anchor mutation safety and bundled ripgrep, using the established result/job contracts.
6. `complete-session-with-anthropic-rpc-loop` — normalized Anthropic streaming, credential boundary, ordered RPC snapshot/patch subscription, durable command correlation and dumb line client; demonstrate the complete walking skeleton and close M1 evidence.

## Next: M2 — Perception through a projection client

Nocterm projects the same engine tree; add multiline input and Markdown/code rendering, sensorium v1 (`turn`, `budget`, jj-first/git-best-effort `vcs`, `changes_since_last_turn` including `by: user`, tree scratchpad). **Exit:** Nikolay completes a 20-turn real coding session on this repo with fewer tool calls to first edit than OMP on the same task, recording task/model/tool conditions and no silent truncation (user); the hard sensorium ceiling/fold order, baseline-preserving history-fold A/B and bounded Windows hash attribution are exercised (agent). Early M2, qualify a 5k-line transcript against [renderer targets/fallback](architecture.md#resource-bounds-and-failure-visibility): p95 viewport redraw ≤16 ms, append ≤1 ms, declared Windows/Linux AOT conditions and terminal flush reported separately (agent). No M2 change split before M1 close.

## Later

- **M3 — Reactive, extensible engine:** diagnostics collector/LSP delta footer, checkpoints, notices, snapshot-based speculative compaction, plugin protocol v1 hooks/tools/commands and more providers; exit: a non-Dart plugin runs hooks/tools, is killed mid-hook, and the session remains usable (agent).
- **Beyond M3:** Claude/Copilot subscription OAuth, data-tier extensions, MCP tool integration, plugin collectors, typed subagents/project-memory features and Kumiko RPC qualification toward OMP parity; plan only after prior evidence, no dates or change split.
