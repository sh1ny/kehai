# tool-calls Specification

## Purpose
Runs every model tool call through one lifecycle: a validated call node in the session tree, full output kept in the result store, and one centrally composed result for the model. Tools never cut their own output.

## Requirements

### Requirement: Fixed versioned tool roster
The engine SHALL offer the model a fixed roster: `read`, `edit`, `write`, `bash`, `grep`, `find`, `ls`, `ask`, `job`, `read_more` and `search_result`. Each tool has a name, a description, a JSON Schema for its arguments and an integer version. The version is recorded on every call node. A call naming any other tool is not run.

#### Scenario: Roster exposed as tool specs
- **WHEN** the engine lists its tools for a provider request
- **THEN** it returns exactly those 11 tools, each with a non-empty description, an object schema and a version of at least 1

#### Scenario: Unknown tool
- **WHEN** the model calls a tool named `rm_rf`
- **THEN** the call node goes from `pending` to `failed` with envelope status `error` and the result `unknown tool rm_rf`, and nothing runs

### Requirement: Arguments validated before anything runs
A call's arguments SHALL be parsed as a JSON object and checked against the tool's schema before any hook, permission prompt or effect. That covers required fields, types, enumerations and numeric ranges. An invalid call goes from `pending` to `failed` with envelope status `error`. Its result names every violated field.

#### Scenario: Valid arguments proceed
- **WHEN** `read` is called with `{"path":"lib/kehai.dart"}`
- **THEN** validation passes and the call proceeds to hooks and permissions

#### Scenario: Malformed or invalid arguments
- **WHEN** `read` is called with arguments `{"path":` (not JSON), or with `{"path":3,"limit":-1}`
- **THEN** the call fails with envelope status `error` and `arguments are not a JSON object`, or with a result naming both `path` (expected string) and `limit` (minimum 1), and no hook, prompt or file access happens

### Requirement: Call node lifecycle in the tree
Each call SHALL be a tree node `body/calls/<key>` holding the tool, version, provider call id, input, `status` and, once settled, `result` `{handle, complete}`, the envelope status and summary. `status` moves `pending` → `running` → `settled`, `failed` or `cancelled`, or from `pending` straight to `failed` or `cancelled`. Every terminal node carries an envelope status and a stored result, except when result storage itself failed. A terminal status never changes.

#### Scenario: Successful call records its lifecycle
- **WHEN** a `read` call runs to completion
- **THEN** the journal records the node `pending`, then `running`, then `settled` with envelope status `ok` and a `result` whose handle resolves through the tree, in that order

#### Scenario: Provider call id unsafe as a path segment
- **WHEN** the provider's call id is `call/7 x` and contains characters outside the path segment alphabet
- **THEN** the node key is a derived safe key, the node's `callId` field holds `call/7 x` exactly, and the call's output pairs with `call/7 x`

#### Scenario: Cancelled call still answers the model
- **WHEN** a running `bash` call is cancelled after printing 3 lines
- **THEN** the node reads `cancelled` with envelope status `error`, summary `cancelled: user`, and a result reference with `complete: false` holding the 3 lines

#### Scenario: Terminal status is final
- **WHEN** a late completion arrives for a call already `cancelled`
- **THEN** the node stays `cancelled` and no record changes it

### Requirement: Full output stored, composed only centrally
Every tool SHALL stream its whole output into the result store; no tool shortens, samples or drops output bytes. The model sees each call only as the envelope the central composer renders from the stored result, with that tool's default cap and `notrunc` rules. Diagnostics, such as hook notes, follow as `[diag <source>] <text>` lines. Any record that references a stored result, from a call or a job, is appended only while that result's descriptor is in the tree.

#### Scenario: Large output stored whole, cut once
- **WHEN** `bash` prints 10,000 lines
- **THEN** the stored result holds all 10,000 lines, the model-facing text is the composer's head-and-tail cut with its truncation line, and `read_more` on the handle returns lines beyond the cut

#### Scenario: Rewind between storing a result and settling
- **WHEN** a call admitted in turn 3 stores its result in turn 5, its settle is paused, the session is rewound to turn 4 (which keeps the call), and the settle resumes
- **THEN** the call settles only after its result descriptor is registered again, and its result handle resolves and is copied by a fork

#### Scenario: Storage fails while output streams
- **WHEN** the result store reports a storage failure partway through a call's output and the session writer is still usable
- **THEN** the call stops its producer and is recorded `failed` with `reason` `storage: <error>`, the bytes accepted and no `result`. The model text is `[<tool> error] storage failure: <error>; <n> bytes accepted, not stored` with no handle, and no `ok` status is recorded

#### Scenario: Journal unusable
- **WHEN** the session writer is broken when a call would record its outcome
- **THEN** nothing more is appended, the run fails with the writer's storage error, and the runtime admits no further call

### Requirement: Bounded parallel calls
Independent calls submitted together SHALL run concurrently, up to 8 running at once. Further calls wait in arrival order in a queue of at most 32. A call that finds the queue full settles `failed` with `tool busy`. Results are recorded per call as each settles, not in submission order.

#### Scenario: Parallel calls overlap
- **WHEN** three `bash` calls that each sleep 1 s are submitted together
- **THEN** all three are `running` at the same time and all settle within 2 s of submission

#### Scenario: Admission over the bound
- **WHEN** 41 calls are submitted at once while none has finished
- **THEN** 8 are `running`, 32 are `pending`, the 41st settles `failed` with `tool busy`, and the queued calls start in arrival order as running ones settle

### Requirement: Turn cancellation
Cancelling a turn SHALL cancel every `pending` or `running` call of that turn. Each is recorded `cancelled` with reason `user`. A process it was running in the foreground is terminated through the job supervisor. Jobs already moved to the background by an earlier settled call are not cancelled.

#### Scenario: Ctrl-C cancels running and queued calls
- **WHEN** a turn has one `running` `bash` call and one `pending` call, and the turn is cancelled
- **THEN** both nodes become `cancelled` with reason `user`, the running process is terminated, and the cancel returns only after both records are committed

#### Scenario: Cancellation after settlement
- **WHEN** a turn is cancelled after all of its calls have settled
- **THEN** no call node changes and the cancel reports 0 calls cancelled
