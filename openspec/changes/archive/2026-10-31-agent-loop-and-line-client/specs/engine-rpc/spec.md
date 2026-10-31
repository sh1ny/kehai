# Spec Delta

## Purpose

Gives clients one local way to reach the engine: `kehai rpc`, newline-delimited JSON over standard input and output. Clients render the committed session tree and send commands; the engine owns the session.

## ADDED Requirements

### Requirement: NDJSON framing
`kehai rpc` SHALL read one JSON object per line from standard input and write one JSON object per line to standard output, UTF-8, each with a string `type`. An input line over 1 MiB, invalid JSON, or an unknown or malformed command gets an `error` reply naming the problem. The line is discarded and the connection stays open. Standard error carries only diagnostics.

#### Scenario: Valid command
- **WHEN** the client writes `{"type":"status","id":"r1"}` followed by a newline
- **THEN** the engine writes exactly one `reply` line for `r1`

#### Scenario: Bad lines
- **WHEN** the client writes a 2 MiB line, then `{"type":"sumbit"}`, then a valid `status` command
- **THEN** the engine replies `error` with `line too long (limit 1 MiB)`, then `error` with `unknown command sumbit`, then answers the `status`

### Requirement: Session opened for the workspace
`kehai rpc` SHALL open one session for its workspace before reading commands. It creates a new session, or with `--resume` reopens the workspace's latest one, or with `--session <id>` a named one. It holds the session's single writer until exit. Sessions live under the Kehai home, in a directory keyed by the canonical workspace path. Any failure to start is one `fatal` line naming the cause, then exit code 1.

#### Scenario: New session
- **WHEN** `kehai rpc` starts in a workspace with a model configured and the user logged in
- **THEN** its first line is `hello` naming the protocol version 1, the session id, the workspace and the model, and a new session directory exists under the workspace's key

#### Scenario: Session locked
- **WHEN** `kehai rpc --resume` starts while another engine holds that session
- **THEN** it writes `fatal` with `session locked` naming the holder, and exits 1 without writing to the session

#### Scenario: Nothing to resume
- **WHEN** `kehai rpc --resume` starts in a workspace that has no session
- **THEN** it writes `fatal` with `no session to resume for this workspace` and exits 1

### Requirement: Materialization then ordered updates
After `hello`, the engine SHALL send one `snapshot` holding the acknowledged tree and its log offset. Then, for each committed record in log order, it sends one `update` with the record and its offset. A client that applies the updates to the snapshot holds the engine's tree.

#### Scenario: Client tree matches the engine
- **WHEN** a client applies every `update` after the `snapshot` through one whole exchange
- **THEN** its tree equals the engine's acknowledged tree at the last offset received

#### Scenario: Rewind committed
- **WHEN** a `rewind` record is committed
- **THEN** the client receives its `update`, then `resync` and a `snapshot` of the rewound tree

#### Scenario: Offsets after resume
- **WHEN** a resumed session's torn tail was cut on open
- **THEN** the snapshot's offset is the cut journal's length, and the client takes no earlier offset as valid

### Requirement: Resync of a slow client
The engine SHALL bound what it holds for the client. When the client reads too slowly it drops pending `update` and `stream` events, keeps at most one pending `resync` and `snapshot`, and sends them with the current offset. It never skips an update silently. While its replies are backed up, it stops reading commands.

#### Scenario: Client stops reading
- **WHEN** the client stops reading standard output while a command writes thousands of records, then reads again
- **THEN** it receives `resync` followed by a `snapshot`, and applying later updates to that snapshot gives the engine's tree

#### Scenario: Repeated overflow while stalled
- **WHEN** the client stays stalled while the engine overflows its output bound three times
- **THEN** only one `resync` and one `snapshot` are pending, holding the latest tree

#### Scenario: Commands while output is stalled
- **WHEN** the client stops reading and keeps writing `status` commands
- **THEN** the engine stops reading input once 1 MiB of replies is pending, and the client's writes block instead of the engine's memory growing

#### Scenario: Client keeps up
- **WHEN** the client reads promptly
- **THEN** it never receives `resync`

### Requirement: Ephemeral stream events
While a step streams, the engine SHALL send `stream` events with the step's journal turn and a text delta, kind `text` or `reasoning`. They are display hints, not session state. A step's committed items are the only record of its text.

#### Scenario: Streamed text matches the commit
- **WHEN** a step streams `Hel` and `lo` and completes
- **THEN** the client receives two `stream` events, then an `update` committing the assistant item `Hello`

#### Scenario: Deltas lost to a resync
- **WHEN** a resync drops stream events of a step that then completes
- **THEN** the step's text is in the snapshot or a later update, whole

### Requirement: Commands correlated by request id
`submit` (prompt text and the last journal turn the client saw) SHALL carry a request id of 1–128 characters from `A-Z a-z 0-9 _ . : -`. It is admitted in `meta/requests` before any effect. A repeated id with the same content reports the recorded state and is not executed again. Different content is a collision. A stale turn is refused.

#### Scenario: Duplicate submit
- **WHEN** the client sends `submit` id `r7` twice with the same text
- **THEN** one exchange runs, and the second reply reports `r7`'s recorded state without starting another

#### Scenario: Id collision
- **WHEN** a `submit` reuses id `r7` with different text
- **THEN** the reply is `error` with `request id collision`, and nothing runs

#### Scenario: Stale submit
- **WHEN** a `submit` names journal turn 4 while the session is at turn 6
- **THEN** the reply is `error` with `stale: session is at turn 6`, and nothing is admitted

### Requirement: Interrupt, answer and status
`interrupt` SHALL cancel the running exchange and reply with whether one was running. `answer` replies to an open `prompt` by its key; a refused answer returns the refusal and the prompt stays open. `status` reports a request id as `not-admitted`, `admitted`, `completed`, `failed` or `interrupted`, with any recorded outcome or reason. A request that is `admitted` or `interrupted` is never executed again by the engine.

#### Scenario: Status after a crash
- **WHEN** an engine died mid-exchange for request `r9`, and a new engine on the resumed session gets `status` for `r9`
- **THEN** the reply is `interrupted` with reason `effect-uncertain`, and `r9` is not executed again

#### Scenario: Unknown request
- **WHEN** `status` names an id that was never submitted
- **THEN** the reply is `not-admitted`

#### Scenario: Wrong answer
- **WHEN** `answer` replies `c` to a question offering `a` and `b`
- **THEN** the reply is `error` with `answer must be one of: a, b`, and the `prompt` stays open

### Requirement: Prompts reach the client
Each permission prompt and `ask` question SHALL be sent as one `prompt` event with its key, kind, tool and input. Each one that closes without an answer is sent as `withdraw` with its key. A client that attaches to the session is the answerer.

#### Scenario: Permission prompt
- **WHEN** the model calls `bash` with `rm -rf build` and the command is not autoapproved
- **THEN** the client receives a `prompt` of kind `permission` for that call, and `answer` `allow` runs it

#### Scenario: Prompt withdrawn by interrupt
- **WHEN** the exchange is interrupted while a question is open
- **THEN** the client receives `withdraw` for its key, and a later `answer` for it replies `question withdrawn`

### Requirement: Signals and client loss
The engine SHALL NOT end or cancel work when it receives SIGINT, since a terminal delivers Ctrl-C to both processes; only `interrupt` cancels. When standard input closes, the engine cancels the running exchange and every live call with reason `shutdown`, closes the session, and exits 0.

#### Scenario: Ctrl-C reaches the engine
- **WHEN** the engine process receives SIGINT while an exchange runs
- **THEN** the exchange keeps running until the client sends `interrupt`

#### Scenario: Client exits mid-exchange
- **WHEN** standard input closes while a `bash` call runs in the foreground
- **THEN** the call is recorded `cancelled` with reason `shutdown`, the exchange `cancelled`, the session lock is released, and the engine exits 0
