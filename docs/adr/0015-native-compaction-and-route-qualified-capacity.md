# ADR 0015: Native compaction and route-qualified capacity

Status: accepted
Supersedes: none

## Context

M1 deferred compaction. Repeated ChatGPT-account overflows around 187–228k despite advertised 500k metadata make native continuity and honest route capacity the first M2 contract. Observed Responses compaction is evidence of current behavior, not a documented guarantee for this route or a measurement of its exact window.

This supplements, without rewriting or superseding, the accepted [tree foundation](0001-one-session-tree.md), [central results](0002-central-result-truncation.md), [jobs](0003-unified-job-lifecycle.md), [Dart engine](0004-dart-native-engine-and-clients.md), [journal/RPC](0005-four-field-journal-and-rpc.md), [process boundaries](0006-subscription-auth-workflow-and-process-boundaries.md), [perception](0007-tree-derived-perception-and-rendering.md), [journal v1](0008-journal-format-v1.md), [protocol authority](0009-openai-subscription-credentials-and-protocol-authority.md), [call layout](0010-tool-call-and-job-tree-layout.md), [conversation/RPC v1](0011-conversation-tree-layout-and-rpc-protocol-v1.md), [captured workspace/children](0012-workspace-context-skills-commands-and-subagents.md), [effort inheritance](0013-reasoning-effort-selection-and-inheritance.md) and [package boundaries](0014-reusable-building-blocks-as-separate-packages.md). Their no-compaction clauses describe historical M1 scope, not an M2 prohibition. The [sensorium specification](../sensorium-spec.md) remains unchanged.

The governing contract is [design D1–D6 and resource bounds](../../openspec/changes/context-compaction-and-window-accuracy/design.md), with deltas for [context compaction](../../openspec/changes/context-compaction-and-window-accuracy/specs/context-compaction/spec.md), [agent loop](../../openspec/changes/context-compaction-and-window-accuracy/specs/agent-loop/spec.md), [model provider](../../openspec/changes/context-compaction-and-window-accuracy/specs/model-provider/spec.md) and [turn perception](../../openspec/changes/context-compaction-and-window-accuracy/specs/turn-perception/spec.md). This ADR records the binding contract, not evidence that the remaining implementation groups have shipped.

## Decision

### Inline opaque continuity, journal authority

Native compaction is part of ordinary model steps: typed optional request policy serializes `context_management: [{"type":"compaction","compact_threshold":<threshold>}]` only when enabled. Preserve token-sharing instructions, `additional_tools` first in input, encrypted reasoning include, `store:false`, `stream:true`, and no `previous_response_id`. There is no standalone compact endpoint, background worker, startup probe, local summarizer or new retry path.

Collect explicitly typed compaction items from `response.output_item.done`, retaining complete JSON values and output positions. Do not interpret ciphertext, require Content-Type on successful SSE, or use terminal output arrays as an alternate source. Collect all boundaries, sort indexed events, deduplicate identical identity/position evidence, and fail conflicting copies or invalid identity/encrypted-content shape with sanitized protocol errors. An unindexed compaction cannot establish a trustworthy cut and is rejected. Preserve streaming text and reconcile done-message text without duplicate semantic content. Repeated events still consume the output byte budget.

Store `{type:"compaction", item:<complete JSON>}` entries in the existing completed step output list. Admission records provider, route, model, captured instruction identity (including role/workspace), canonical tool-definition digest, effective policy/provenance, selected boundary identity and any calibration consumption. Completion records capability evidence. A received item is disposable until successful completion is durably appended and guarded publication succeeds. Cancellation, incomplete responses, network/protocol failures, stale callbacks and death before commit never activate a new boundary or run held calls. Four-field journal and RPC remain v1; there is no second transcript, global boundary pointer or capability side store.

### Latest boundary first, then validate all opaque continuity

Select the latest surviving completed boundary in original conversation order **before** checking compatibility. Never search backward for an older compatible cut. Validate that boundary and every opaque reasoning/compaction suffix item's recorded provider, route, model, captured instruction and tool identity against the current request. A mismatch stops before sending; do not resurrect the full prefix or forward cross-lineage ciphertext. Tell the owner to rewind before the incompatible opaque item or start a new session. Changed captured workspace instructions/tools intentionally require this recovery; changing threshold or selecting `off` alone does not invalidate continuity.

Forward the selected complete JSON unchanged and all subsequent eligible items, regenerating top-level instructions/tools and fresh request-only sensorium from captured inputs. JSON values, including encrypted strings, remain identical; transport whitespace/key formatting is not token content. Replay reconstructs the same logical projection, except request-only clock/sensorium. Rewind/fork use existing tree operations: removed steps cease to contribute boundaries/evidence, and sessions without a boundary retain full-history reconstruction. Additive output variants require upgrade-only writing for compacted sessions: old binaries ignoring them are unsafe writers, and supported readers must visibly reject unknown output kinds rather than silently omit continuity. No journal migration is introduced.

### Captured policy and durable capability evidence

Strict user configuration accepts optional `strategy` and `threshold` under `providers.<provider>.compaction`, `providers.<provider>.routes.<route>.compaction` and `providers.<provider>.routes.<route>.models.<model>.compaction`. Resolve each field independently, model-within-route > route > provider > built-in default. For `openai` / `chatgpt-account`, default strategy is `provider_native` and threshold is **100000**; other routes default `off`. Thresholds must be integers at least **1000**. Strategies are `provider_native`, `local_summary` and `off`; selecting reserved, unimplemented `local_summary`, unknown keys or invalid values fails visibly before a paid request. `off` omits new native policy but preserves compatible existing opaque continuity. No repository/role overrides or live reload are introduced. Record selected policy and provenance at admission even for unsent or failed steps.

Capability is unverified, observed-supported or unsupported, folded from committed surviving evidence for the current lineage and policy. A successful boundary establishes observed-supported, not a route guarantee. A field-specific rejection establishes unsupported immediately. A completed ordinary request at/above threshold without an item also establishes unsupported, using reported input or a labelled conservative input estimate when usage is absent. Below-threshold absence and unrelated failures do not establish unsupported. Stop before another native request on unsupported policy; notify the user and record a deterministic terminal exchange notice available to the model after explicit recovery. Never silently remove the field, switch strategies or resend uncertain paid work.

Resume retains unsupported evidence; an explicitly different policy allows an unverified attempt, while returning to a failed policy reuses its failure. Rewind removes only evidence after its target. Explicit `off` is owner recovery with ordinary overflow guards, not automatic fallback.

Children independently resolve their launched model's policy from the parent's captured validated provider-policy configuration, not mutable rereads or the parent's selected scalar. Pass bounded internal launch JSON (maximum 8 KiB UTF-8, base64-encoded in argv); validate schema and total native command-line size before spawning, failing visibly rather than omitting fields. Keep effort inheritance and the no-nested-agent policy unchanged. Child evidence belongs to its own journal.

### Submission safety and one-shot calibration

For ordinary native submissions, stop locally above **ceil(1.25 × effective threshold)**, a submission safety ceiling, not a claim about context-window capacity. Also enforce known effective windows and the serialized-request cap without silent trimming.

A newly committed boundary with unknown opaque size permits **one calibration submission per boundary**. Exclude the discarded-prefix upper bound from admission arithmetic; require retained non-opaque estimates (instructions, tools, suffix, recovery notes and fresh sensorium) at most half the effective threshold and no greater than a configured route window. Keep the request-byte cap. Explicitly show unknown compacted usage and the calibration exception: it does not bound opaque tokens.

Record consumption at admission before sending. Failure, missing usage, death or policy change never restores that boundary's allowance. Only compatible completed usage or a new committed boundary enables progress. A calibration overflow stops without resend. Missing calibration usage without a newer boundary records `calibration usage unavailable`, preserves observed-supported evidence from the boundary, and stops further same-boundary submission; missing usage alone cannot prove threshold crossing. Large suffixes/results refuse calibration visibly. Thus an obsolete 120k-input/6k-output prefix does not prevent one small calibration, but never licenses unbounded unknown-size requests.

### Tool ordering and recovery across the cut

Compute the cut in original response-item order, not a call/output-interleaved projection; the last compaction in a step wins. Finish the successful step and settle **all** its calls once before any next request. Post-cut calls retain paired function outputs. Results newly produced for calls before that cut were unavailable to the server's boundary: derive deterministic user recovery notes with call id/name and the **verbatim central result envelope**, including handles. Never send orphan function outputs, reinsert omitted calls or reexecute effects. Do not re-inject ordinary outputs wholly before earlier boundaries. Notes derive from terminal tree results, not another persisted transcript.

Close the completion-before-runtime-admission crash gap. Before accepting a prompt on attach and after rewind reconciliation, enumerate **every call position in surviving completed step output**, not just existing runtime nodes. Existing nodes retain job recovery and terminal results. For each missing node append a guarded terminal cancelled call/result with reason `interrupted_before_admission`, central envelope `execution not recorded; not replayed`, and original call key/id/name/input/model reference. Use the current writer turn and source-step reference. Never execute the call or claim an effect occurred; conflicting admission/result metadata stops recovery visibly.

Repeated attach is idempotent. If rewind removes recovery nodes but retains their source step, reconstruct the same no-effect outcomes; removed source steps reconstruct nothing. Normal runtime still owns live admissions, and rewind reconciliation skips registered live keys. No boundary can be used until all referenced calls have terminal outcomes, including recovered pre-cut notes and post-cut cancellation pairs.

### Qualified capacity and honest accounting

Keep backend-reported metadata separate from effective route capacity. On ChatGPT-account, only validated positive-integer `providers.openai.routes.chatgpt-account.models.<id>.contextWindow` supplies effective capacity, labelled **user-configured estimate**. Generic model metadata, including `gpt-6.1-sol`'s 500k, is not an effective guard. Legacy top-level `models.<id>.contextWindow` stays parseable as an unqualified hint with a visible migration notice to the qualified path. Invalid qualified settings refuse startup. Preserve other routes' existing behavior; neither observed overflows nor the safety ceiling invent an exact replacement window.

Usage baselines must match instruction identity, request lineage and selected boundary. A new boundary invalidates pre-boundary usage: compacted total use is **unknown** until a completed request using that projection reports compatible usage. Display estimated retained non-opaque content separately; never count encrypted bytes as tokens or subtract an invented per-item prefix allocation from aggregate usage. Compatible completed input-plus-output usage resumes normal uncovered-item accounting; a newer boundary needs fresh calibration. Even a configured window cannot make unknown opaque size a trustworthy total or percentage.

Sensorium remains exactly two request-only lines. Mark estimated counts/windows/percentages approximate with `~`; show unknown sizes as `?` without percentages. RPC materialization and line-client status expose provider/route/model, policy/provenance, capability state/reason, selected boundary id (not contents), capacity provenance and budget quality. Reconnect rebuilds from tree evidence and current validated inputs. Notices/logs/status never expose ciphertext or raw server text.

### Preservation, bounds and implementation scope

Only provider conversation projection is cut. Canonical history, scratch nodes/files, result descriptors/chunks/pins/full bytes and handles, request admission/outcome correlation and child/job state remain untouched. Future scratch rendering reads the live scratch subtree verbatim outside the compactable transcript in the request-only snapshot, never from ciphertext. Synthetic scratch nodes can test this seam without adding scratch tools. Existing result APIs preserve handle access; opaque continuity does not guarantee recall of every historic identifier, and no unbounded handle catalog is injected.

Existing limits remain authoritative; compaction raises none:

| Resource | Bound and behavior |
|---|---|
| SSE event / held arguments / sanitized error read | 8 MiB / 8 MiB / 64 KiB; existing protocol rejection and bounded reads; provider idle deadline 300 s |
| Aggregate response collector, including encrypted items and identity table | 4 MiB; abort without publishing new boundary or held calls; repeated events consume the budget |
| Serialized request, including ciphertext, notes and tools | 1 MiB; visible local context-overflow stop, never silent trimming |
| Submission work | One active exchange/request per engine; ordinary ceiling and one-per-boundary calibration; existing child supervisor bounds and deadlines |
| Boundary/capability lookup | No persistent cache; linear surviving-step scan, cancellable build; no new quadratic full-prefix recomposition after selecting the cut |
| Canonical journal/results | Session-lifetime growth; existing disk errors, no compaction GC or storage bound claim |
| Scratch/results transfer | Existing scratch/result limits and central truncation; required new pre-cut envelopes only, not all result bytes; final request cap |
| Child policy launch | 8 KiB JSON plus total native argv validation; reject before spawn, existing startup deadline |
| Status/notices | Scalar provenance/status/reasons, sanitized error cap 500 characters; no per-event accumulation or ciphertext |

At 10x/100x input, reject at byte limits instead of proportional allocation; historical metadata scans still grow linearly and require performance fixtures. Native Responses adaptation remains Kehai policy code, not independent reusable infrastructure requiring a package under ADR 0014.

## Consequences

- **Rejected:** standalone paid compaction, background/probe work, local summaries, silent fallback/retry, destructive history pruning, authoritative summary/capability caches, ciphertext inspection and invented exact capacity. They add authority, uncertainty or scope without evidence.
- **Trade-offs:** conservative guards can refuse viable requests; unknown opaque size remains a calibration risk. Strict instruction/tool lineage can require rewind or a new session after edits. Storage still grows, and compacted sessions require upgraded writers. Native retention is not a semantic-losslessness promise.
- **Reversal cost: medium** for additive stored variants, lineage/policy semantics, child payloads and status fields. Threshold tuning/presentation are cheaper; deleting canonical history would be high cost and is forbidden. Future compatibility relaxations, tokenizers, scratch tools or alternative strategies need separate evidence and design.
