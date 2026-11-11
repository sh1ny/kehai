# agent-loop Specification

## Purpose
Drives a coding session forward: it turns a user prompt into alternating model requests and tool calls until the model is done, the user interrupts or a visible limit stops it. Every fact it produces is recorded in the session tree.

## Requirements

### Requirement: Exchanges and steps
A user prompt SHALL start one exchange. An exchange runs steps: each step is one model request and is one journal turn. A step that ends with tool calls runs them, then starts the next step. The exchange ends `done` when a step completes without tool calls, `cancelled` on interrupt, or `stopped` or `failed` with a recorded reason. At most one exchange runs at a time.

#### Scenario: Prompt answered after one tool round
- **WHEN** the user submits `list lib`, the model's first step calls `ls` and its second step answers in text
- **THEN** the exchange records two steps on consecutive journal turns, the `ls` call is settled, and the exchange ends `done`

#### Scenario: Prompt while an exchange runs
- **WHEN** a second prompt is submitted while an exchange is running
- **THEN** it is refused with `busy`, nothing is recorded for it, and the running exchange continues

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

### Requirement: Interrupted exchanges are marked in later requests
Every request SHALL hold, right after the items of each exchange recorded `cancelled`, the fixed user note `The previous request was interrupted before it finished. Do not continue it unless asked.`, so the model does not take that exchange's unanswered prompt as still pending.

#### Scenario: Prompt after an interrupt
- **WHEN** the user interrupts an exchange while its reply streams, then submits `hi`
- **THEN** the next request holds the interrupted prompt, then the note `The previous request was interrupted before it finished. Do not continue it unless asked.`, then `hi`, and no partial text of the interrupted step

### Requirement: Tool calls of a step
The tool calls of a completed step SHALL be submitted to the tool runtime together, so independent calls run in parallel within its bounds. The next step starts only when every call of the step is terminal. A call that settles `error`, `denied` or `timeout` is fed back to the model; it does not end the exchange.

#### Scenario: Parallel calls
- **WHEN** a step returns three `read` calls
- **THEN** all three run concurrently, and the next step starts after the last one settles, with all three outputs

#### Scenario: Many calls in one step
- **WHEN** a step returns 128 small calls while the journal's flushes are slowed
- **THEN** every call gets a terminal node: 40 run or queue and settle normally, 88 settle `failed` with `tool busy`. The next request pairs all 128 calls with their outputs, and no `writer busy` error occurs

#### Scenario: Denied call
- **WHEN** the user denies a `bash` call
- **THEN** the call settles `denied`, its envelope is sent in the next step, and the exchange continues

### Requirement: Interrupt
An interrupt SHALL cancel the running exchange: it aborts the provider stream and cancels every pending or running call of the exchange, then records the exchange `cancelled`. Text streamed before the interrupt is kept on the step as partial text and is not sent to the model. Jobs already in the background are untouched.

#### Scenario: Interrupt during a model stream
- **WHEN** the user interrupts while the model is streaming text
- **THEN** the step is recorded `cancelled` with the partial text, no tool call of that step runs, and the exchange ends `cancelled`

#### Scenario: Interrupt while tools run
- **WHEN** the user interrupts while a foreground `bash` call and a permission prompt are open
- **THEN** both calls are recorded `cancelled` with reason `user`, the prompt is withdrawn, and no further step starts

#### Scenario: Interrupt while the step commits
- **WHEN** the user interrupts after a step's stream completed with two `write` calls, while the step's completion record is still being written
- **THEN** both calls are recorded `cancelled` with reason `user` and a stored result, neither file is written, and the exchange ends `cancelled`

#### Scenario: Interrupt when idle
- **WHEN** an interrupt arrives while no exchange runs
- **THEN** nothing is recorded and the reply says no exchange was running

### Requirement: Bounded retry of unstarted requests
A failed model request SHALL be retried only when the failure proves no work started: kind `rate_limited`, or `network` before the body was sent. Up to 4 retries wait 1, 2, 4 and 8 s, or the server's `Retry-After` when it is at most 60 s. Every other failure ends the exchange `failed`. No tool call is retried.

#### Scenario: Rate limit then success
- **WHEN** the first request fails `rate_limited` with `Retry-After: 3` and the retry completes
- **THEN** the step completes after one retry about 3 s later, and the step records 2 attempts

#### Scenario: Retries exhausted
- **WHEN** five consecutive attempts fail `network` before the body was sent
- **THEN** the exchange ends `failed` with `model request failed after 5 attempts: <last failure>`

#### Scenario: Failure after the body was sent
- **WHEN** a request fails `server` with status 500 or `network` after the body was sent
- **THEN** it is not repeated, and the exchange ends `failed` naming the failure

#### Scenario: Retry-After too long
- **WHEN** a `rate_limited` failure asks to wait 600 s
- **THEN** no retry is made, and the exchange ends `failed` naming the wait the server asked for

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

### Requirement: Step output limit
A step's response SHALL be bounded at 4 MiB of output, counted by the provider at ingestion (model-provider, *Response output limit*), including tool-call arguments it still holds. When the provider fails the stream at that limit, the loop records the step `failed` with `step output limit (4 MiB)` and the partial text received. The exchange ends `failed`, and no tool call of that step runs.

#### Scenario: Endless small deltas
- **WHEN** a step streams one million valid 8-byte text deltas
- **THEN** the stream ends once 4 MiB has arrived, the step is `failed` with `step output limit (4 MiB)` and its partial text, and the exchange ends `failed`

#### Scenario: Held calls over the limit
- **WHEN** a response, before completing, streams five complete function calls of 1 MiB of arguments each
- **THEN** the stream fails at the fifth call, no call is emitted or run, and the step is `failed` with `step output limit (4 MiB)`

#### Scenario: Large but bounded reply
- **WHEN** a step streams 3 MiB of text and completes
- **THEN** the step completes with the whole 3 MiB text

### Requirement: Step limit
An exchange SHALL run at most 200 steps. When the 200th step ends with tool calls, the calls run, and the exchange ends `stopped` with reason `step limit (200)` instead of starting another step.

#### Scenario: Runaway loop
- **WHEN** a model keeps calling tools on every step
- **THEN** after the 200th step's calls settle the exchange ends `stopped` with `step limit (200)`, and no 201st request is sent

#### Scenario: Normal exchange
- **WHEN** an exchange finishes in 3 steps
- **THEN** no step limit is recorded

### Requirement: Resume finalizes unfinished exchanges
Opening a session for write SHALL record every exchange still `running` as `cancelled` with reason `interrupted`, and every step still `running` as `cancelled` with reason `interrupted`, before any prompt is accepted. No model request or tool call is repeated.

#### Scenario: Crash mid-step
- **WHEN** the engine process is killed while a step is streaming, and the session is reopened
- **THEN** that step and its exchange are recorded `cancelled` with reason `interrupted`, and no request is sent until the user submits a prompt

#### Scenario: Clean session
- **WHEN** a session whose exchanges all ended is reopened
- **THEN** nothing is recorded on open

### Requirement: A hung hook cannot stall the exchange
A tool call whose pre-tool hook hangs SHALL be resolved by the hook deadline. The exchange continues with that call's result and is never blocked by the hook process.

#### Scenario: Optional hook hangs
- **WHEN** an `optional` hook for `read` never exits and has a 2 s deadline, and the model calls `read`
- **THEN** the hook is killed at about 2 s, the `read` settles `ok` with the hook timeout visible, and the next step starts

#### Scenario: Deny-class hook hangs
- **WHEN** a `deny` hook for `bash` never exits and the model calls `bash`
- **THEN** the call settles `denied` naming the hook timeout, and the exchange continues with the next step

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

