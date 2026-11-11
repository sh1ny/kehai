# Spec Delta

## MODIFIED Requirements

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

## ADDED Requirements

### Requirement: Ordered self-contained perception
Snapshots SHALL follow source order: turn, budget, vcs, changes_since_last_turn, diagnostics, tests, processes, plan, scratch, checkpoints, notices. The default SHALL be `full`, preserving unchanged facts when older blocks are absent, including after compaction/resume/fork/rewind. Supported empty sections SHALL say `none`; unavailable sections SHALL name why. Scratch SHALL preserve all stored text behind counted per-line presentation indentation. Delta-only-since-full SHALL not discard the only available baseline. Live processes SHALL use tree-owned state; logs SHALL explicitly say unavailable because result references publish at exit, without tail I/O or a new live-log producer. Notices SHALL use bounded codes; the existing compaction recovery message SHALL retain its separate request placement.

#### Scenario: Unchanged memory after earlier block removal
- **WHEN** scratch is unchanged across successive requests and the earlier generated block is absent from the new input
- **THEN** the new block is marked `full` and still contains all current scratch text

#### Scenario: Known jobs but unavailable collectors
- **WHEN** a shell job is live but VCS and diagnostics collection are not implemented in this milestone change
- **THEN** processes describes the real tree-owned job, while vcs and diagnostics explicitly say unavailable, not clean or zero errors

#### Scenario: Empty versus failed
- **WHEN** the supported job projection has no live jobs and another supplied collector observation has failed
- **THEN** processes says `none` and the failed section says unavailable with its reason or stale with its last known observation

#### Scenario: Concurrent recovery notices
- **WHEN** compaction recovery and ignored legacy-window notices both apply
- **THEN** both bounded notice codes fit within the notice allocation without duplicating the separate recovery message or refusing composition

### Requirement: Hard perception budget and folding
The block SHALL default to a configurable 1500-token ceiling, using conservative UTF-8-byte/3 accounting. Source section ceilings and fold order SHALL apply with explicit omission counts. Scratch, budget, turn and notices SHALL never be folded. Variable workspace/model presentation SHALL be visibly bounded, and notice codes SHALL be bounded, rather than making ordinary identifiers fail immutable section limits. Overflow of the complete immutable content SHALL fail before provider submission. No content SHALL spill into a second block or be silently cut. Startup SHALL reject ceilings below the calculated safe minimum of 1310 tokens: immutable maxima (30+40+400+80), worst-case folded allocations (40+200+300+40+40+60+60), and 20 framing tokens. Implementation/tests SHALL share these allocations and prove that maximum allowed scratch fits alongside every folded section.

#### Scenario: Folding under pressure
- **WHEN** supported observations exceed the block ceiling but fit after folding
- **THEN** process details fold to counts before VCS paths, then diagnostics, test names, change counts and checkpoints in source order; every omitted item count is explicit and the final block fits

#### Scenario: Immutable content cannot fit
- **WHEN** a direct-composer or legacy-config seam supplies a ceiling smaller than the valid immutable turn/budget/scratch/notices content
- **THEN** no paid request is sent and the user receives a configuration error naming the required and configured sizes without losing scratch

#### Scenario: Invalid ceiling
- **WHEN** the user configures a non-integer ceiling or one below the calculated safe minimum
- **THEN** startup fails naming the setting before a provider request

### Requirement: Exact admitted observation
After the existing running-step admission and request construction, a guarded pre-stream merge SHALL record the exact rendered block, its conservative size, frozen source turn/time and source offset. The offset SHALL be diagnostic only within that journal, invalid after fork/migration, and SHALL NOT be used as a durable identity or lookup key. RPC materialization SHALL expose the stored observation, not recompute what a previous request saw. Failed composition SHALL not claim an observation was sent. Reconnect SHALL recover admitted observations from the tree, and rewind SHALL remove later observations with their steps.

#### Scenario: Inspect admitted step
- **WHEN** a model request is admitted and a client reconnects after it completes
- **THEN** the step metadata exposes exactly the block supplied to that request, including mode and fold markers

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
