# Proposal

## Why

M2 entry 1 advances the long-change self-hosting and honest-capacity exit criteria: four dogfood overflows at approximately 187–228k tokens (latest approximately 212k) forced manual restarts while the ChatGPT-account route advertised an unqualified 500k window. Kehai needs journal-derived native compaction before the remaining M2 work, without mistaking an observed route behavior for a documented guarantee.

## What Changes

- Opt into server-side Responses compaction through `context_management`, with runtime support detection and visible unsupported status; no standalone compact endpoint.
- Persist encrypted compaction output as opaque, ordered journal-backed conversation items; derive subsequent input from the latest eligible compaction item and its suffix without deleting canonical history.
- Preserve rewind/fork/replay, scratch, result handles, and request/child correlation; isolate provider/route/model lineages.
- Add provider/route/model compaction policy with `provider_native`, `local_summary`, and `off`; implement only `provider_native`, reject selection of the reserved local strategy visibly.
- Default native compaction to 100,000 tokens on the ChatGPT-account route, configurable with a minimum of 1,000; stop safely if compaction cannot be established.
- Qualify window metadata by route and provenance; show unknown or estimated sizes honestly rather than promote generic model metadata to a verified route limit. Reset usage baselines across compaction boundaries.

## Capabilities

### New Capabilities

- `context-compaction`: Native compaction policy, support detection, opaque continuity, lineage and preservation contracts.

### Modified Capabilities

- `model-provider`: Native compaction request/output support, stream item collection, and route-qualified model capacity.
- `agent-loop`: Journal-backed compaction items, compacted request reconstruction, and safe overflow behavior.
- `turn-perception`: Honest window/usage provenance and compaction-aware context accounting.

## Impact

Targets `lib/src/provider/`, `lib/src/loop/`, `lib/src/config/user_config.dart`, RPC/line-client and child-engine wiring, and their tests. Uses the existing Dart 3.x AOT runtime, four-field journal and result store; adds no native dependency, external state store, summary model, scratch tools, pricing registry or broad sensorium implementation. Delivery remains one PR with pre-ship review and Linux/Windows qualification; this planning session stops after design review, before implementation.

## Release Notes

Add native compaction configuration, protocol support, journal-derived continuity and no-effect call recovery. Native submissions now use durable capability evidence, bounded admission and one recorded calibration allowance per boundary. Budgets distinguish estimates, unknown compacted usage and route-qualified capacity; child and RPC/client integration follow in group 6.

### Added
- ADR 0015 defining opaque continuity, lineage validation, captured policy, call recovery and route-qualified capacity.
- Typed compaction policy with per-field provenance, native/off defaults, and explicit reserved-strategy errors.
- Inline native request policy and bounded indexed opaque compaction collection, including headerless SSE and done-message reconciliation.
- Completed opaque output, admission lineage/policy and latest-boundary-first suffix reconstruction with pre-cut verbatim result notes.
- Guarded recovery of every committed call position, including missing runtime admissions, without replaying effects.
- Journal-derived, policy-specific native capability evidence with explicit recovery notices and no silent fallback.
- Bounded native submission and one admission-recorded calibration attempt per boundary, including interruption and partial-usage guards.

### Changed
- ChatGPT-account capacity resolution uses route-qualified estimates; legacy windows remain hints with migration notices, separate from backend metadata.
- Usage baselines require matching lineage/boundary; new compacted projections show unknown total usage without estimating ciphertext.
- Estimated counts, configured windows and percentages are visibly approximate; unknown compacted usage suppresses percentages.
- Compacted sessions require upgrade-only writers; unknown output kinds and incompatible continuity stop visibly.
