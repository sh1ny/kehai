# ADR 0018: Atomic temporary-path provenance

Status: accepted
Date: 2026-11-14
Supersedes: ADR 0017's single-path mutation footprint and literal Git capture command only; all other ADR 0017 contracts remain in force.

## Context

A cancelled atomic edit/write can still expose its adjacent temporary file to a request or status capture. Recording only the destination incorrectly attributes temporary creation or later removal to the user. The reviewed amendment is [D11](../../openspec/changes/archive/2026-11-14-vcs-changes-and-notices/design.md), with [matching attribution requirements](../../openspec/specs/workspace-change-attribution/spec.md). [ADR 0017](0017-vcs-observation-baselines-and-provenance-attribution.md) remains immutable.

## Decision

Each edit/write run has one immutable destination `target` and one actual `temporary` path. The atomic helper selects the name and awaits its required production `beforeWrite(temporary)` callback before creating/opening it. The caller supplies resolved absolute paths; the runtime publishes both at the accepted writer queue head and durably records both repo-relative paths with the existing `targetAfterSeq` in one intent. Refusal throws `WriteFailure`; persistence errors propagate unchanged. Write's callback retains parent-directory creation after acceptance and a cancellation check; the helper checks cancellation again before opening the temporary. Callback failure precedes temporary ownership and cleanup.

The two paths share the existing open, quiesced, orphan and foreign lifetimes. Preservation compares both and saves the complete footprint before a cut. Finish and recovery retain both with the existing session ownership and finish-sequence rules. Fork copies both without claiming authority to finish the parent's work. Existing run, foreign-record and finished-history limits count records and do not change.

An applying temporary path remains visible as `by: unknown` and never contributes `user_edits`, including removal after an admitted baseline. It receives no destination effect hash, and an independent successful effect cannot override its uncertainty because the destination's lock does not order writes to that temporary. Case-alias uncertainty covers both paths. Filename patterns neither establish provenance nor suppress rows.

Untargeted uncertainty is derived from each registered run's own unpublished footprint, not from a deduplicated call key or tree fallback. An older detached attempt cannot hide a newer untargeted attempt with the same call id. Recovery still uses deduplicated `activeCallKeys`. There is no second registry, capture pin, post-capture provenance reread, extra reservation or additional intent flush.

Absent `temporary` is the legacy encoding. Replay, preservation, finish, recovery, fork and derived open/quiescence indexes retain that absence without inventing a path or dropping the call. Applicable legacy provenance makes every comparison row unknown for only its existing interval or applying lifetime. A legacy call quiesced during recovery remains discoverable at that quiescence turn even when its response predates the baseline. An inherited unfinished legacy foreign record therefore makes the child's comparisons unknown for its existing lifetime, including inherited descendants. A present empty or non-string temporary is malformed: record handlers, recovery and fork fail visibly, while attribution conservatively masks rows. Generic journal-envelope validation is unchanged.

Git observation uses `git add --sparse -A` in the disposable index, allowing non-ignored out-of-cone files without changing user staging or sparse-checkout rules. Git observation requires Git 2.34 or later. Older Git fails collection explicitly through the existing failed/stale and `vcs_failed` behavior; there is no version probe, plain-add fallback or stderr-based availability override.

## Consequences

- One additional persisted path per mutation footprint; no new store, queue, cleanup worker or path-list policy.
- Legacy provenance can conservatively hide user attribution, never the changed rows themselves. Its existing lifetime is not extended.
- The atomic helper remains responsible for its existing rename/failure cleanup; no new sweeper or recovery replay of filesystem effects.
- No tool schema, instruction identity, RPC, journal-operation format or package-version change.
- Qualification covers physical Git/jj temporary creation/removal over successive baselines, ownership refusal, intent-flush and same-id races, rewind/crash/recovery/fork, isolated legacy quiescence indexing and unchanged user index/rules in sparse capture.
