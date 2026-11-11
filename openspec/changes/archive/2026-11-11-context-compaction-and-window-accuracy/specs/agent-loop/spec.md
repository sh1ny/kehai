# Spec Delta

## MODIFIED Requirements

### Requirement: Conversation recorded in the tree
The user prompt, assistant text, opaque reasoning and compaction items and each tool call's position SHALL be recorded as ordered conversation items under `body`, in the step's journal turn. Each step records its model, state, stop reason, usage and any failure. No conversation fact lives outside the tree.

#### Scenario: Items in order
- **WHEN** a step streams text `Reading.`, then a reasoning item, then two tool calls
- **THEN** the tree holds, after the user item, an assistant item `Reading.`, the opaque reasoning item unchanged and two call items naming their call keys, in that order

#### Scenario: Rewind removes the later steps
- **WHEN** the session is rewound to the journal turn of an exchange's first step
- **THEN** the items, steps and calls of later turns are gone from the tree, and the next request is built without them

#### Scenario: Compaction committed with completion
- **WHEN** a response successfully completes with compaction items
- **THEN** the completed step records each complete opaque JSON item in response order and its request lineage; replay needs no external compaction cache

#### Scenario: Crash before completion commit
- **WHEN** the stream completes but the step completion is not durably committed before the engine dies
- **THEN** resume finalizes the step interrupted and no compaction boundary from that step is active

### Requirement: Requests rebuilt from the tree
Requests SHALL rebuild from the tree: instructions (fixed built-in text, child role instructions if any, then captured workspace context), ordered conversation and each stored call result's centrally composed output. Opaque reasoning and compaction items SHALL remain unchanged; calls without terminal states SHALL NOT be sent. Conversation SHALL use the latest committed compaction item and its suffix after boundary/suffix-lineage validation, or full history without a boundary.

#### Scenario: Tool output is the composed envelope
- **WHEN** a `bash` call produced 50,000 lines and the next step is built
- **THEN** that call's output in the request is exactly the composer's envelope for its stored result, with the truncation line and handle, and no other text

#### Scenario: Resumed session
- **WHEN** a session whose last exchange was interrupted is reopened and the user submits a new prompt
- **THEN** the request holds every surviving projected item and the composed output of every finalized call, including those finalized as `cancelled`

#### Scenario: Instructions from the exchange's context
- **WHEN** a step of exchange 2 is built after `AGENTS.md` changed on disk during that exchange
- **THEN** its instructions hold the `AGENTS.md` text captured when exchange 2 started, not the current file

#### Scenario: Session from before this change
- **WHEN** a session whose exchanges record no context key is resumed and its next request is built
- **THEN** a context is captured for the new exchange, and the earlier items are sent unchanged

#### Scenario: Boundary in a tool step
- **WHEN** a completed response contains calls on both sides of a compaction item
- **THEN** every call executes at most once, the next input has no orphan call/output pairs, post-boundary pairs are retained, and terminal outputs from pre-boundary calls are sent once as explicit recovery notes keyed by call id rather than orphan function outputs

#### Scenario: Incompatible boundary
- **WHEN** a surviving boundary belongs to a different provider, route, model or captured instruction/tool identity
- **THEN** no request is sent and the user receives an incompatible-continuity stop with rewind/new-session guidance

### Requirement: Context overflow stops the exchange
Before each request, the loop SHALL compare context in use to the model window; over it, no request is sent. This or provider `context_overflow` SHALL end the exchange `stopped` with reason `context overflow`, known used/window sizes and rewind/new-session guidance. Canonical history SHALL remain intact. Native compaction SHALL follow its policy before overflow, respect window/request-byte caps and never use a local summary or automatic overflow resend.

#### Scenario: Estimate over the window
- **WHEN** the context in use is estimated at 280k tokens for a model whose window is 272k
- **THEN** no request is sent and the exchange stops with `context overflow: ~280k of 272k tokens; rewind or start a new session`

#### Scenario: Provider reports overflow
- **WHEN** the window is unknown and the provider fails the request with `context_overflow`
- **THEN** the exchange stops `stopped` with reason `context overflow`, and the failure is not retried

#### Scenario: Compaction missing at safety threshold
- **WHEN** native policy cannot establish compaction at its threshold
- **THEN** the exchange stops visibly before the next request rather than growing toward a known overflow or silently switching strategies

## ADDED Requirements

### Requirement: Every committed call has a recoverable outcome
Before a new request, all call positions in surviving completed steps SHALL have terminal outcomes. Attach and rewind reconciliation SHALL include calls without runtime nodes, recording guarded cancelled results with reason `interrupted_before_admission` and envelope `execution not recorded; not replayed`, never executing effects. Existing outcomes SHALL be preserved; conflicting metadata SHALL stop recovery visibly. Removed source steps SHALL NOT be reconstructed.

#### Scenario: Normal settlement across the cut
- **WHEN** a completed response has calls before and after its compaction item and runtime admission succeeds
- **THEN** every call settles once, the pre-cut outcome appears in a recovery note, and the post-cut outcome remains a paired function output

#### Scenario: Death before any runtime admission
- **WHEN** the engine dies after completed step output commits but before the first call is admitted
- **THEN** reopen records a cancelled outcome for every missing call position without executing them, and pre-cut notes/post-cut pairs include the cancellation envelopes

#### Scenario: Partial admission and repeated reopen
- **WHEN** the engine dies after some calls are admitted, then recovery is itself interrupted and repeated
- **THEN** existing effects/outcomes are never replayed or overwritten, admitted nodes use existing recovery, and each remaining missing position receives at most one terminal cancellation node

#### Scenario: Rewind after recovery
- **WHEN** rewind removes recovery nodes while retaining their source completed step, or removes the source step itself
- **THEN** retained source positions are reconciled deterministically without effects and removed source positions are never reconstructed
