# Review

## Metadata

- **Round:** 5 — M1-close strategy/architecture amendment.
- **Prior round:** Round 4 approval/recheck covers the original baseline and source-reference correction, not this amendment.
- **Reviewer:** Codex, read-only baseline review.
- **Reviewed:** `AGENTS.md`; `openspec/specwright.yaml`; `openspec/config.yaml`; strategy and architecture, including their Git diff; proposed ADR 0014 and untracked `openspec/milestones/m1-close.md` directly; current roadmap; prior architecture review; unchanged `docs/sensorium-spec.md`; accepted ADRs 0001–0013; review template.
- **Installed project-domain skills:** None applicable.
- **Evidence limits:** Receipts were assessed as reported evidence. No tests, qualification reruns, network/authenticated calls, edits or implementation were performed. Unrelated `.claude/settings.local.json` is outside scope.

## Findings

### Critical (blocking)

None.

The amendment preserves the three locked foundations: one authoritative session tree, central truncation/full-result handles and unified supervised jobs. Independent package APIs do not acquire session authority, and Kumiko remains a client of the existing engine through RPC v1.

ADR 0014 coherently supplements accepted decisions without editing or superseding them:

- Packages require a demonstrated need and inadequate existing alternatives; they own MIT licensing, metadata, versions and tests, with no Kehai imports or types.
- Workspace incubation uses `packages/<name>`. API stability **or** a second consumer triggers extraction; pub.dev publication remains a separate owner decision.
- The strict no-Rust boundary includes building-block implementations. C FFI remains limited to demonstrated needs; native packaging must be qualified, and existing event-loop/resource constraints remain applicable.
- Kumiko containment is extracted before reuse. Job Objects are a candidate replacement, with cleanup equivalence explicitly unproven. VT parsing is new pure Dart; tree-sitter C FFI and o200k counting remain optional and evidence-gated.
- Compaction precedes later scratchpad tools while preserving scratch, result handles, request correlation and journal authority. This is compatible with ADRs 0001–0007 and 0011–0013.

### Moderate

None requiring changes for this baseline gate.

The receipt distinguishes owner-accepted lifecycle completion from unattended operation: permission assistance, owner decisions, external reviewer routing, overflow restarts and the Windows Nightly waiver remain visible. It does not recast the failed Nightly as green or weaken future qualification requirements.

The friction ledger records future work rather than implemented behavior. In particular, live configuration must reconcile ADR 0013’s immutable effort/inheritance contract; approval improvements retain user control; timing-test changes must preserve isolation guarantees; relative-PATH coverage restoration remains outstanding.

The unchanged roadmap is an intentional staged artifact, not a blocking contradiction here. Its subsequent rewrite must preserve the owner’s exact seven-entry order:

1. Compaction and route-aware context-window accuracy.
2. Sensorium/scratchpad.
3. VCS/changes/notices.
4. Nocterm, including the week-one renderer experiment, `/sense`, multiline input and paste.
5. LSP/diagnostics/delta footer.
6. jj checkpoints/git fallback.
7. Windows parity/qualification.

The overflow observations establish a route-capacity accuracy problem, not an exact replacement context limit.

### Suggestions

Optional wording improvements only:

- In architecture’s historical M1 paragraph, link “recorded at M1 close” directly to `milestones/m1-close.md`.
- When updating the ADR index, clarify that “All seven ADRs accepted on 2026-10-28” refers specifically to ADRs 0001–0007.
- Consider cross-linking the receipt’s “seven M2 entries” statement to the eventual ordered roadmap so its allocation is directly auditable.

## Verdict

VERDICT: APPROVE

## Required Changes

None for the reviewed amendment.

This pass permits ADR 0014 acceptance/status and index edits. It does **not** close M1, approve a still-unwritten roadmap amendment, independently qualify delivery receipts or authorize shipping the planning branch. Kumiko extraction and runtime adaptation still require their separate planning change.

CHANGES_APPLIED: n/a

## Rebuttals

None. No files were changed.