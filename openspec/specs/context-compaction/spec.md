# context-compaction Specification

## Purpose

Keeps long coding sessions usable through provider-native compaction while the journal remains the authority for continuity, recovery and preserved agent state.

## Requirements

### Requirement: Route and model compaction policy
Compaction policy SHALL resolve from model-within-route, route, provider, then built-in defaults. Strategies are `provider_native`, `local_summary` and `off`; only native is implemented. Selecting `local_summary` SHALL fail configuration visibly. The ChatGPT-account default SHALL be native with threshold 100000. Thresholds SHALL be integers at least 1000. Other routes default off. Invalid policies SHALL fail before a paid request.

#### Scenario: Model override
- **WHEN** a provider threshold is 100000 and its route's selected model overrides it to 80000
- **THEN** the effective threshold is 80000 and its source is available in status

#### Scenario: Invalid or reserved configuration
- **WHEN** the selected strategy is `local_summary`, the threshold is 999, or a policy has an unknown key
- **THEN** configuration fails naming the exact setting and no model request is sent

#### Scenario: Explicit off
- **WHEN** the selected route is configured `off`
- **THEN** requests omit `context_management`, no new compaction is sought, and existing compatible opaque continuity remains usable

### Requirement: Visible runtime capability detection
Native support SHALL be tracked per provider/route/model as unverified, observed-supported or unsupported. Acceptance alone SHALL NOT prove support. A completed request at or above its effective threshold with no compaction item, or a rejection identifying `context_management`, SHALL mark support unsupported and notify user and model. Unrelated failures SHALL NOT prove unsupported. No capability failure SHALL silently switch strategies or resend a possibly admitted request.

#### Scenario: Observed support
- **WHEN** a native-enabled response completes with a valid compaction item
- **THEN** status becomes observed-supported and identifies the route and model, without claiming a documented route guarantee

#### Scenario: Threshold request silently ignored
- **WHEN** a completed native-enabled request has reported input usage at or above the threshold and returns no compaction item
- **THEN** status becomes unsupported with reason `no compaction item at threshold`, the result remains recorded, and the exchange stops before another model request

#### Scenario: Field rejected
- **WHEN** an error identifies unsupported `context_management`
- **THEN** status becomes unsupported, the error is visible, and no retry omitting the field is sent

#### Scenario: Below threshold or inconclusive
- **WHEN** no compaction item arrives below threshold, or the stream fails before completion
- **THEN** absence alone does not mark the route unsupported; no successful compaction is recorded

### Requirement: Native boundary and lineage
Requests SHALL select the latest committed completed compaction item before checking compatibility, then retain its suffix. Provider, route, model and captured instruction/tool identity SHALL match for the boundary and every opaque suffix item. Mismatch SHALL stop visibly: no older-boundary fallback, cross-lineage ciphertext or silent prefix resurrection. Canonical history SHALL remain intact.

#### Scenario: Two compaction items
- **WHEN** a completed response holds compaction A, message READY and compaction B
- **THEN** subsequent conversation input begins at B, omits A and READY, and retains every later item

#### Scenario: Rewind across boundary
- **WHEN** rewind removes the turn containing B
- **THEN** replay chooses the latest surviving boundary and validates compatibility, or uses full surviving history if no boundary exists, without restoring removed items

#### Scenario: Changed model or instructions
- **WHEN** the selected model or captured instruction/tool identity differs from a surviving compaction boundary
- **THEN** the request stops with an incompatible-continuity message naming rewind-before-boundary or new-session recovery, and no opaque item is sent to the new lineage

### Requirement: Preserved state and safe absence
Compaction SHALL NOT mutate scratch, full results, handles, canonical history, request admission/outcomes or child/job correlation. Scratch SHALL remain verbatim agent-owned state, including future tree scratch representations. Result access SHALL remain available by stable handle. If support is unsupported, further native requests SHALL stop visibly until the owner explicitly changes policy or starts a new capability attempt.

#### Scenario: Replay and fork after compaction
- **WHEN** a compacted session is replayed or forked
- **THEN** surviving scratch is byte-equivalent, stored handles still resolve, and duplicate request/child identities retain their recorded outcomes without executing effects again

#### Scenario: Unsupported policy stays explicit
- **WHEN** another step is requested with the same unsupported native policy
- **THEN** no request is sent and the user is told the unsupported reason and explicit recovery choices, not silently switched to off or local summary

#### Scenario: Mixed lineage history
- **WHEN** an older boundary matches the requested model but a newer boundary or opaque suffix item belongs to another lineage
- **THEN** no request is sent, an incompatible-continuity stop is visible, and the older matching boundary is not used as a fallback

### Requirement: Bounded native submission and calibration
Ordinary native submissions SHALL stop above ceil(1.25 times threshold). Unknown-size committed boundaries SHALL permit one calibration attempt with retained non-opaque estimates at most half the threshold, within route-window and request-byte caps. Calibration use SHALL be recorded before sending and survive restart/policy changes for that boundary. Until compatible usage or a new boundary exists, another request SHALL stop. Unknown opaque size SHALL remain explicit.

#### Scenario: Successful calibration despite old large usage
- **WHEN** a permitted 120000-input/6000-output response compacts at threshold 100000 and retained non-opaque input is estimated at 5000 tokens
- **THEN** one bounded calibration request is admitted despite the obsolete 126000-token prefix count, and compatible completed usage enables ordinary accounting

#### Scenario: Ordinary or suffix admission refuses
- **WHEN** ordinary input exceeds its safety ceiling, or a post-cut tool result makes calibration's retained-content estimate exceed half the threshold or the serialized request cap
- **THEN** no request is sent and the local stop names the violated cap without dropping content

#### Scenario: Calibration has no usage or dies
- **WHEN** a calibration attempt reports no usage and no new boundary, fails, or is interrupted after admission
- **THEN** its allowance remains consumed across reopen and policy changes, another same-boundary request stops visibly, and missing usage alone is not misreported as proof of unsupported compaction

### Requirement: Durable capability evidence
Support evidence SHALL be journal-derived for the selected lineage and policy. Unsupported native policy SHALL remain blocked across resume; an explicit different policy SHALL start unverified, and returning to a failed policy SHALL retain its failure. Rewind SHALL remove only later evidence. Ordinary completed requests missing usage SHALL use conservative input estimates for threshold-absence detection and SHALL label estimate-based reasons.

#### Scenario: Estimate-based missing compaction
- **WHEN** an ordinary completed native request has no usage or compaction and its conservative input estimate reaches threshold
- **THEN** unsupported evidence records `estimated input at threshold without compaction`, and the user and model receive that qualified reason

#### Scenario: Resume and policy change
- **WHEN** policy A is unsupported, the engine reopens, the owner explicitly chooses policy B, then returns to A
- **THEN** A remains blocked on reopen and return, while B begins unverified; no automatic fallback request occurs

#### Scenario: Rewind removes evidence
- **WHEN** rewind removes A's unsupported observation but retains an earlier successful native observation
- **THEN** replay reconstructs the surviving observed-supported state and no removed failure remains authoritative

### Requirement: Captured child policy selection
Each child SHALL resolve its own provider/route/model policy from the parent's captured validated configuration, not mutable rereads. Existing effort inheritance SHALL remain unchanged. Internal policy payloads SHALL be bounded at 8 KiB JSON with native argv size validation; invalid or oversized payloads SHALL refuse launch visibly. Child evidence SHALL remain local to the child journal.

#### Scenario: Different child model and later config edit
- **WHEN** a parent captures model A at threshold 100000 and model B at 80000, config changes on disk, and it launches a model B child
- **THEN** the child records and uses 80000 from the captured configuration, not A's threshold or the changed file

#### Scenario: Invalid launch payload
- **WHEN** the captured policy payload exceeds its size bound, has unknown fields, or makes native argv too large
- **THEN** launch fails before spawning with a typed configuration error and no paid request

### Requirement: Reconstructed visible compaction status
User-visible status SHALL expose current provider/route/model, policy and source, capability state/reason, boundary identity without ciphertext, and capacity/budget quality. Reconnect SHALL reconstruct status from the tree and current validated input. After explicit recovery, the model SHALL receive the recorded unsupported/stop reason as a deterministic notice, not just a log line.

#### Scenario: Reconnect after observed compaction
- **WHEN** a client reconnects after a completed compaction
- **THEN** materialization exposes observed-supported, the selected boundary id and capacity provenance without encrypted content

#### Scenario: Recovery after unsupported route
- **WHEN** an unsupported attempt stops and the owner explicitly selects off to continue
- **THEN** status retains the qualified failure reason and the next model request receives a notice describing that failed attempt; nothing silently reports native success
