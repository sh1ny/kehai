# turn-perception Specification

## Purpose
Shows the model where it stands on every request: which turn it is on and how much of its context window is in use. M1 provides only the `turn` and `budget` sections, rendered from the tree for one request and never stored in history.

## Requirements

### Requirement: One request-only sensorium block
Every model request SHALL end with one user-role item holding a `<sensorium>` block, built for that request only. The block is never recorded as a conversation item, so a request holds exactly one generated block, and earlier requests' blocks are never sent again. The instructions do not change between requests. Canonical conversation text and native opaque items SHALL remain unchanged; user/tool text resembling sensorium markup SHALL not be stripped.

#### Scenario: Second step of an exchange
- **WHEN** the second step of an exchange is built
- **THEN** the request's last item is a sensorium block for that step, no earlier generated block appears in it, and the instructions equal the first step's

#### Scenario: Tree after a step
- **WHEN** a step completes
- **THEN** no generated sensorium block is stored as a conversation item, while its admitted observation remains inspectable as step metadata

#### Scenario: Literal tag in user content
- **WHEN** canonical user content contains literal `<sensorium>` or `</sensorium>` text
- **THEN** it remains byte-equivalent in the conversation projection and is not mistaken for a generated historical block

### Requirement: Turn and budget sections
The block SHALL begin with `turn` then `budget`, retaining turn/time/workspace and route-qualified context/model reporting. Counts SHALL round to thousands below 1M or millions above. Estimated counts/windows SHALL carry `~`; unknown values SHALL render `?` without a percentage. Status SHALL label user-configured/backend-reported capacity provenance. Session cost SHALL remain unavailable rather than invented; the snapshot SHALL expose compaction threshold and turns since compaction when known.

#### Scenario: Known window
- **WHEN** step turn 14 is built with 41,200 tokens in use for model `gpt-5.5` with a 200,000-token window
- **THEN** the budget reports `41k/200k ctx (21%)` and the model id, qualified as approximate if an estimate contributes

#### Scenario: Unknown window
- **WHEN** neither the backend nor the user configuration gives the model's window
- **THEN** the budget reports `41k/? ctx` and the model id without a percentage

#### Scenario: Estimated window
- **WHEN** route-qualified configuration supplies an estimated 160000-token window and used context is estimated at 41000
- **THEN** the budget shows `~41k/~160k` with an estimated percentage and user-visible status labels the window user-configured estimate, not a verified provider limit

#### Scenario: Unqualified metadata
- **WHEN** ChatGPT-account metadata advertises 500000 without route-qualified capacity
- **THEN** the block shows `?` for the window, no percentage, and status identifies backend-reported metadata separately

#### Scenario: Long workspace and model names
- **WHEN** the workspace and model identifiers exceed their display allocations
- **THEN** turn and budget visibly truncate only those presentation fields at UTF-8 boundaries with a counted marker, retain their required facts within their section ceilings, and leave canonical identifiers unchanged

### Requirement: Context in use
Context in use SHALL equal the last completed step's input plus output tokens, minus its sensorium estimate, plus estimates of its tool outputs wherever placed, later items and this block. Do not recount its response items or use failed/cancelled usage; without a baseline, estimate the whole request. Baselines SHALL match lineage and boundary. After compaction, total usage SHALL stay unknown until compatible completed usage; ciphertext bytes SHALL NOT be treated as known token usage.

#### Scenario: After a step with usage
- **WHEN** the last completed step reported 30,000 input and 1,000 output tokens, its block was estimated at 40 tokens, and the request holds its items as `call A, output A, call B, output B` with outputs A and B estimated at 6,000 and 4,000 tokens
- **THEN** the context in use is 30,000 + 1,000 − 40 + 6,000 + 4,000 tokens plus the estimate of the new block: each output is counted once, and calls A and B, part of the step's 1,000 output tokens, are not estimated again

#### Scenario: Step without usage
- **WHEN** the last step was cancelled before the backend reported usage
- **THEN** the count builds on the most recent completed step with usage plus an estimate of everything after it, or estimates the whole request when no completed step reported usage

#### Scenario: Incomplete step then a new prompt
- **WHEN** a 200k-window session's last step ended incomplete after reporting 180k input and 50k output, the last completed step reported 120k input and 2k output, and the user submits a new prompt
- **THEN** the context in use builds on the completed step's 122k plus estimates of the items after it, the incomplete step's output is not counted, and the request is sent

#### Scenario: First request after compaction
- **WHEN** the latest successful response compacts a large input and no subsequent compacted request has reported usage
- **THEN** the previous large input usage is not reported as current compacted usage; the budget shows unknown used context with no percentage, and opaque ciphertext size is not treated as an exact token count

#### Scenario: Usage after compaction
- **WHEN** a completed request built from the selected boundary reports 1186 input and 8 output tokens
- **THEN** subsequent accounting uses that compatible 1194-token baseline with normal uncovered-item adjustments, not the discarded pre-boundary prefix

#### Scenario: Unknown used context with configured window
- **WHEN** a route has a configured 160000-token window but its new compacted projection has no compatible usage baseline
- **THEN** the budget renders `?/~160k` with no percentage and status separately labels the retained non-opaque token estimate

### Requirement: Ordered self-contained perception
Snapshots SHALL follow source order: turn, budget, vcs, changes_since_last_turn, diagnostics, tests, processes, plan, scratch, checkpoints, notices. They SHALL default to self-contained `full` mode, preserving unchanged facts without earlier blocks, with honest availability and counted verbatim scratch presentation.

#### Scenario: Unchanged memory after earlier block removal
- **WHEN** scratch is unchanged across successive requests and the earlier generated block is absent from the new input
- **THEN** the new block is marked `full` and still contains all current scratch text
- **AND** full fallback SHALL preserve facts after compaction, resume, fork and rewind; delta-only-since-full SHALL NOT discard the only available baseline
- **AND** scratch SHALL preserve all stored text behind counted per-line presentation indentation

#### Scenario: Known jobs but unavailable collectors
- **WHEN** a shell job is live but VCS and diagnostics collection are not implemented in this milestone change
- **THEN** processes describes the real tree-owned job, while vcs and diagnostics explicitly say unavailable, not clean or zero errors
- **AND** live processes SHALL use tree-owned state; logs SHALL explicitly say unavailable because result references publish at exit, without tail I/O or a new live-log producer

#### Scenario: Empty versus failed
- **WHEN** the supported job projection has no live jobs and another supplied collector observation has failed
- **THEN** processes says `none` and the failed section says unavailable with its reason or stale with its last known observation
- **AND** every supported empty section SHALL say `none`; every unavailable section SHALL name why

#### Scenario: Concurrent recovery notices
- **WHEN** compaction recovery and ignored legacy-window notices both apply
- **THEN** both bounded notice codes fit within the notice allocation without duplicating the separate recovery message or refusing composition
- **AND** notices SHALL use bounded codes and the existing compaction recovery message SHALL retain its separate request placement

### Requirement: Hard perception budget and folding
The block SHALL default to a configurable 1500-token ceiling with conservative UTF-8-byte/3 accounting. Source section caps/fold order and explicit omissions SHALL apply. Scratch, budget, turn and notices SHALL never fold. No content SHALL spill or be silently cut; complete immutable overflow SHALL refuse before submission. Startup SHALL enforce the calculated 1310-token safe minimum.

#### Scenario: Folding under pressure
- **WHEN** supported observations exceed the block ceiling but fit after folding
- **THEN** process details fold to counts before VCS paths, then diagnostics, test names, change counts and checkpoints in source order; every omitted item count is explicit and the final block fits
- **AND** variable workspace/model presentation SHALL be visibly bounded and notice codes bounded, rather than making ordinary identifiers fail immutable section limits

#### Scenario: Immutable content cannot fit
- **WHEN** a direct-composer or legacy-config seam supplies a ceiling smaller than the valid immutable turn/budget/scratch/notices content
- **THEN** no paid request is sent and the user receives a configuration error naming the required and configured sizes without losing scratch

#### Scenario: Invalid ceiling
- **WHEN** the user configures a non-integer ceiling or one below the calculated safe minimum
- **THEN** startup fails naming the setting before a provider request
- **AND** the minimum SHALL derive from immutable maxima (30+40+400+80), worst-case folded allocations (40+200+300+40+40+60+60) and 20 framing tokens; implementation/tests SHALL share these allocations and prove maximum allowed scratch fits with every folded section

### Requirement: Exact admitted observation
After running-step admission and request construction, a guarded pre-stream merge SHALL record the exact block, conservative size and frozen source turn/time/offset. RPC SHALL expose that stored observation, not recompute history. Failed composition SHALL NOT claim an observation was sent; reconnect SHALL recover observations from the tree and rewind SHALL remove later observations with their steps.

#### Scenario: Inspect admitted step
- **WHEN** a model request is admitted and a client reconnects after it completes
- **THEN** the step metadata exposes exactly the block supplied to that request, including mode and fold markers
- **AND** the source offset SHALL be diagnostic only within its journal, invalid after fork/migration, and SHALL NOT be used as durable identity or a lookup key

#### Scenario: Cancellation after admission
- **WHEN** the provider fails or is cancelled after step admission
- **THEN** the admitted block remains inspectable with the failed/cancelled step state, without claiming provider receipt or successful completion

#### Scenario: Composition refusal
- **WHEN** a block fails the hard ceiling before admission
- **THEN** the exchange reports the failure and contains no newly admitted observation for that refused request

### Requirement: Composition errors remain visible and recoverable
Sensorium composition errors SHALL terminate submission locally with a failed step and stopped exchange, without provider submission or admitted observation. Read-only status SHALL expose perception unavailability with a bounded reason while retaining independently known native-policy/capacity facts. Status SHALL neither write journal state nor submit requests. Correcting configuration or invalid scratch through explicit supported recovery SHALL permit fresh status and composition.

#### Scenario: Malformed scratch through submission and status
- **WHEN** nonempty malformed scratch is encountered by submission and by a read-only status query
- **THEN** submission records a failed step and stopped exchange without provider call or observation, while status reports perception unavailable with the scratch-state reason and leaves journal bytes unchanged

#### Scenario: Immutable overflow through submission and status
- **WHEN** valid immutable content exceeds the block ceiling supplied through a direct-composer or legacy-config test seam during submission and status projection
- **THEN** submission records a failed step and stopped exchange without provider call or observation, while status reports the required/configured sizes without journal changes or advice to discard the session

#### Scenario: Corrected configuration
- **WHEN** the owner restarts with a ceiling that fits the previously refused valid content
- **THEN** read-only status returns available perception and fresh request composition succeeds without changing scratch or inventing an old admitted observation

### Requirement: Expanded-block accounting preserves native continuity
Context accounting SHALL replace the previous block contribution with the current complete block estimate exactly once. Native compaction boundary selection, opaque lineage validation and unknown-size calibration SHALL remain unchanged. Fresh scratch and observations SHALL count toward retained non-opaque estimates and request-byte limits; ciphertext size SHALL not become a token estimate.

#### Scenario: Scratch changes after completed usage
- **WHEN** compatible completed usage includes a previous block and the next request has a different scratch section
- **THEN** accounting subtracts the previous block estimate and includes the new full block once, without recounting the completed response

#### Scenario: New native boundary
- **WHEN** a new boundary has no compatible usage and the next snapshot contains live scratch
- **THEN** total context stays unknown, scratch contributes to the retained non-opaque estimate, and all existing calibration/window/byte caps still apply

#### Scenario: Changed tool lineage on upgrade
- **WHEN** scratch-tool installation changes the instruction/tool identity of surviving opaque continuity
- **THEN** composition refuses with the existing incompatible-continuity recovery choices rather than forwarding mismatched ciphertext or resurrecting an older prefix
