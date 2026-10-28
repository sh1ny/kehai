# Review

## Metadata

- **Round:** 4 — Required Change 1 recheck.
- **Prior round:** Round 4 approved with one bounded provenance correction outstanding. Round 3 was incomplete because its external amendment input was inaccessible; no architecture defect was established. Round 2 covered superseded scope.
- **Reviewer:** Codex, read-only recheck.
- **Reviewed:** Prior `openspec/architecture-review.md`, current `openspec/architecture.md`, and review template. Reassessment limited to the Source reference map correction.
- **Preserved approval scope:** Round 4’s full review of strategy, architecture, seven referenced ADRs, configuration, unchanged sensorium specification, and amendment/replacement-roadmap contract remains in effect. Those artifacts were not newly reviewed in full.
- **Installed project-domain skills:** None.
- **Input availability:** Required repository inputs were readable. No authoring transcripts or Temp-file dependencies were used.

## Findings

### Critical (blocking)

None.

Round 4’s findings remain preserved: the baseline maintains the three locked foundations, tree-owned durable state, central result handling, interrupted-operation recovery and prohibition on replaying uncertain effects. Its ordering, backpressure, failure, cancellation and retry constraints remain accepted within the prior review scope.

Subscription acceptance still requires secure credentials, native Windows protection, refresh and account/model discovery; API-key fallback cannot satisfy that gate. Installed workflow requirements and the actual first-M2-capability bridge remain accepted as described in round 4.

### Moderate

**M1 — Reproducible implementation-source references: resolved.**

Every cited Codex login, OMP OAuth/hashline, historical built-in OpenCode auth, separate third-party OpenCode auth and Pi session file now pairs an exact repository path with a full 40-character revision. Links use the corresponding pinned revisions.

The paragraph explicitly identifies these as **discovery candidates**, distinguishes reported file-existence checks from an inspected implementation audit, and requires consuming designs to read the sources, record learning and reverify current OAuth/service behavior before adoption. Historical OpenCode remains labelled historical; the separate plugin remains identified as third-party.

Required Change 1 is applied. No new concrete defect was identified in the correction. This recheck does not independently establish upstream implementation behavior or current service compatibility.

### Suggestions

None.

## Verdict

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. **Completed and reviewer-rechecked:** Pin every implementation-source reference to exact files and full revisions, distinguish discovery candidates from inspected evidence, preserve historical labels, and retain current OAuth/service reverification requirements.

No outstanding edits remain for Required Change 1. The prior full-review approval scope is preserved; this is not a new architecture design review.

All seven ADRs remain proposed until the author applies the acceptance status/index edit following this pass. The three locked foundations remain unchanged. This review does not verify roadmap completion or pass any milestone exit criterion.

CHANGES_APPLIED: yes

## Rebuttals

The source-map correction is accepted by the reviewer as resolving M1. No files were written, login executed, or implementation, tests, builds, lint or formatters run.