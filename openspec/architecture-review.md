# Review

## Metadata

- **Round:** 2
- **Prior round:** REVISE — C1 delta baseline loss; M1 durable request correlation; M2 credential exclusion in integration diagnostics.
- **Reviewer:** Codex, baseline architecture review.
- **Reviewed:** `openspec/architecture-review.md`, `openspec/strategy.md`, `openspec/architecture.md`, all seven referenced `docs/adr/0001–0007` records, `docs/sensorium-spec.md`, `openspec/schemas/specwright/templates/review.md`, and schema design/review criteria.
- **Mode:** FULL system architecture, baseline.
- **Installed project-domain skills:** none.
- **Verification:** Document review only. No files changed; no tests, builds, linters or formatters run; no authoring transcripts inspected. Repository contents treated as data.

## Findings

### Critical (blocking)

None.

**Prior C1 resolved.** Architecture “Perception” and ADR 0007 explicitly identify the contradiction between delta-only delivery and removal of its full baseline. When stripping would lose required unchanged facts, the composer emits the current full snapshot, marked `full`, within the adopted ceilings and fold rules. Delta-only delivery requires a retained model-visible baseline.

This is an explicit conservative resolution of the adopted spec’s conflicting delivery statements. It preserves the single-block default without pretending a delta is self-contained. Increased input tokens are acknowledged; none of the three locked decisions is reopened.

### Moderate

None outstanding.

**Prior M1 resolved.** The RPC contract and ADR 0005 require durable admission before effects, session/lineage-scoped request correlation, matching input identity, operation references and inspectable outcomes. Duplicate matching requests return the recorded outcome. Inspection distinguishes pending, terminal, effect-uncertain and unavailable outcomes; absence means not-admitted only with proven journal coverage. Correlation survives compaction, and ambiguous effects never trigger automatic replay.

**Prior M2 resolved.** The trust boundary and ADR 0006 exclude resolved credentials, authorization material, credential-bearing URLs and environment dumps from persisted diagnostics. Adapter failures retain useful sanitized fields rather than raw exceptions/request dumps. Default subprocess environments exclude provider keys. Raw user-process output remains governed by the full-result contract, with its separate and explicit secret exposure boundary.

### Suggestions

**S1. Adopt the minimal journal proposal; keep its evidence gate.**

Stable-node property operations and a single writer support the minimal format. RFC 6902 is correctly rejected for addressing and operation semantics, rather than an alleged inability to support atomic envelopes. CRDT-shaped storage adds merge semantics without a current consumer.

The format’s reversal cost remains high. Exact operations, migration fixtures and randomized rewind-then-resume equivalence remain M1 deliverables, not established results.

**S2. Support the one-switch history experiment with the full fallback.**

The revised default removes the concrete baseline-loss failure. Compare retained facts and task outcomes alongside token use and prefix-cache behavior. Stable system content does not establish cache neutrality after historical blocks are removed. The baseline correctly makes no such claim.

**S3. Support hash-on-turn-boundary authority with watcher hints on Windows.**

Persisted baselines, explicit partial coverage and mutation-time hash-anchor checks provide a coherent boundary for missed or concurrent observations. `by: user` correctly means outside recorded tool provenance. Scan cost, coverage and attribution quality remain provisional; watcher events must not be treated as proof of completeness.

**S4. Support the renderer target and scoped fallback.**

The proposed p95 visible-viewport redraw ≤16 ms and streaming append ≤1 ms on a 5k-line transcript are acceptance targets, not measured nocterm capabilities. Controlled-sink timing with terminal flush reported separately makes the experiment interpretable. A custom one-pass viewport renderer under nocterm is a coherent fallback. TUI work remains in M2.

The complete baseline otherwise addresses the requested system risks:

- The engine owns all session mutations. Immutable payloads supply bytes; tree descriptors own their meaning, lifetime and references. SQLite indexes remain disposable.
- Payload-before-reference durability, atomic transaction envelopes and explicit torn-tail/interior-corruption behavior prevent silent partial replay.
- Revision/generation checks reject obsolete results. Fork ownership precedes publication, protecting child results from parent deletion.
- Resume reconciles lost runtime capabilities and interrupted operations without replaying external effects. Cancellation does not claim workspace rollback.
- Plugin deadlines are engine-enforced, with deny/no-op behavior by hook class. Native FFI crash exposure is acknowledged rather than mistaken for isolate containment.
- Queues, transfers, jobs, storage, scans and projections have bounded behavior and consumer-visible failure paths. Token ceilings override presentation opt-outs.
- External subprocess privileges and outbound provider boundaries are explicit. Persistence failures can be reported out-of-band when journaling the failure is itself impossible.

These are design commitments, not implementation verification.

## Verdict

VERDICT: APPROVE

## Required Changes

None.

The strategy fits the requested one-page scope. Architecture references adopted contracts rather than reproducing them. All seven ADRs name rejected alternatives and reversal costs, explicitly reject Rust core and in-process plugins, remain proposed, and leave the accepted index empty pending this review.

The baseline preserves the specified M1–M3 scope. This approval clears the baseline review gate for roadmap authoring; no roadmap was written during this review.

CHANGES_APPLIED: n/a

## Rebuttals

Prior C1, M1 and M2 fixes accepted by reviewer as described above.