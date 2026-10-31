# turn-perception Specification

## Purpose
Shows the model where it stands on every request: which turn it is on and how much of its context window is in use. M1 provides only the `turn` and `budget` sections, rendered from the tree for one request and never stored in history.

## Requirements

### Requirement: One request-only sensorium block
Every model request SHALL end with one user-role item holding a `<sensorium>` block, built for that request only. The block is never recorded as a conversation item, so a request holds exactly one block, and earlier requests' blocks are never sent again. The instructions do not change between requests.

#### Scenario: Second step of an exchange
- **WHEN** the second step of an exchange is built
- **THEN** the request's last item is a sensorium block for that step, no earlier block appears in it, and the instructions equal the first step's

#### Scenario: Tree after a step
- **WHEN** a step completes
- **THEN** no conversation item in the tree contains `<sensorium>`

### Requirement: Turn and budget sections
The block SHALL hold exactly two lines, in this order:
- `turn: <journal turn> · full · <HH:MM local> · cwd <workspace name>`
- `budget: <used>/<window> ctx (<percent>%) · model <id>`

Token counts render as `41k` (thousands, rounded) below a million and `1.2M` above. Cost is not shown.

#### Scenario: Known window
- **WHEN** step turn 14 is built with 41,200 tokens in use for model `gpt-5.5` with a 200,000-token window
- **THEN** the block's budget line is `budget: 41k/200k ctx (21%) · model gpt-5.5`

#### Scenario: Unknown window
- **WHEN** neither the backend nor the user configuration gives the model's window
- **THEN** the budget line is `budget: 41k/? ctx · model gpt-5.5` and holds no percentage

### Requirement: Context in use
The context in use SHALL be the last completed step `u`'s input plus output tokens, minus the estimate of `u`'s sensorium block, plus estimates of every tool output answering `u` (wherever the request places it), every later item, and this request's block. `u`'s response items are excluded from the estimate. Failed or cancelled steps' usage is never used. Without `u` it estimates the whole request.

#### Scenario: After a step with usage
- **WHEN** the last completed step reported 30,000 input and 1,000 output tokens, its block was estimated at 40 tokens, and the request holds its items as `call A, output A, call B, output B` with outputs A and B estimated at 6,000 and 4,000 tokens
- **THEN** the context in use is 30,000 + 1,000 − 40 + 6,000 + 4,000 tokens plus the estimate of the new block: each output is counted once, and calls A and B, part of the step's 1,000 output tokens, are not estimated again

#### Scenario: Step without usage
- **WHEN** the last step was cancelled before the backend reported usage
- **THEN** the count builds on the most recent completed step with usage plus an estimate of everything after it, or estimates the whole request when no completed step reported usage

#### Scenario: Incomplete step then a new prompt
- **WHEN** a 200k-window session's last step ended incomplete after reporting 180k input and 50k output, the last completed step reported 120k input and 2k output, and the user submits a new prompt
- **THEN** the context in use builds on the completed step's 122k plus estimates of the items after it, the incomplete step's output is not counted, and the request is sent
