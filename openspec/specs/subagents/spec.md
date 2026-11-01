# subagents Specification

## Purpose
Runs installed agent roles (such as Specwright's implementer and reviewer) as supervised child engines with a fresh context, narrowed tools and a typed result, so a workflow can delegate work and review inside Kehai alone.

## Requirements

### Requirement: Agent roles
An agent role SHALL be a `.md` file directly under `<project root>/.claude/agents/` with YAML frontmatter holding `name` (lowercase letters, digits and hyphens, 1-64 characters) and `description`, and optionally `model` and `tools` (comma-separated). The body after the frontmatter is the role's instructions. An invalid file or a duplicate name is not a role and is recorded as a problem.

#### Scenario: Installed roles
- **WHEN** `.claude/agents/specwright-reviewer.md` has `name: specwright-reviewer`, `model: inherit` and `tools: Read, Grep, Glob, Bash, Write, Skill`
- **THEN** a role `specwright-reviewer` exists with those settings and its body as instructions

#### Scenario: Invalid role file
- **WHEN** an agent file has no `description`
- **THEN** it is not a role and a problem names the file and `missing description`

### Requirement: Role tools narrowed and mapped
A role's `tools` SHALL be mapped to Kehai tools: `Read`→`read`, `Grep`→`grep`, `Glob`→`find` and `ls`, `Edit`→`edit`, `Write`→`write`, `Bash`→`bash` and `job`, `Skill`→`skill`, `AskUserQuestion`→`ask`. `read_more` and `search_result` are always offered; `agent` never is. Without `tools`, the child gets every tool but `agent`. Unknown names are ignored and recorded.

#### Scenario: Reviewer tools
- **WHEN** a `specwright-reviewer` child starts
- **THEN** its roster is exactly `read`, `grep`, `find`, `ls`, `bash`, `job`, `write`, `skill`, `read_more` and `search_result`

#### Scenario: Unknown tool name
- **WHEN** a role lists `Read, WebFetch`
- **THEN** the child gets `read`, `read_more` and `search_result`, and the job and the doctor inventory name `WebFetch` as unmapped

#### Scenario: Out-of-roster call in the child
- **WHEN** a reviewer child's model calls `edit`
- **THEN** that call fails with `unknown tool edit` and nothing is edited

### Requirement: Role model selection
A child SHALL use the parent's model when the role's `model` is absent or `inherit`; otherwise the slug configured for that alias under `agents.models` in the user configuration. An alias with no configured slug uses the parent's model, and the typed result and the doctor inventory say so.

#### Scenario: Inherited model
- **WHEN** the parent runs `gpt-6.1-sol` and starts `specwright-reviewer` (`model: inherit`)
- **THEN** the child's steps record model `gpt-6.1-sol`

#### Scenario: Configured alias
- **WHEN** `agents.models` maps `sonnet` to `gpt-6.1-mini` and `specwright-implementer` (`model: sonnet`) starts
- **THEN** the child's steps record model `gpt-6.1-mini`

#### Scenario: Unmapped alias
- **WHEN** no slug is configured for `haiku` and `specwright-implementer-light` starts
- **THEN** the child uses the parent's model and the result says `model haiku is not configured; used <parent model>`

### Requirement: Agent tool
The `agent` tool SHALL take `role`, `prompt`, and optional `description`, `background` and `timeout_s` (1-86,400; default 3,600). It starts one child engine job. In the foreground the call ends when the child ends or its deadline passes; with `background: true` it returns the job id at once and `job` waits for, reads or cancels it.

#### Scenario: Foreground agent
- **WHEN** the model calls `agent` with role `specwright-reviewer` and a review request
- **THEN** the call settles when the child's exchange ends, with the typed result as its output

#### Scenario: Background agent
- **WHEN** the model calls `agent` with `background: true`
- **THEN** the call settles at once with the job id, and `job` with action `wait` later returns the typed result

#### Scenario: Unknown role
- **WHEN** the model calls `agent` with role `general-purpose` and no such role exists
- **THEN** the call fails with `unknown agent role general-purpose; roles: <list>` and no process starts

### Requirement: Child engine
A child SHALL be a separate Kehai engine process in the parent's workspace with its own session, stored under the parent session's directory and recording the parent session and job as lineage. Its instructions are the built-in text, the role's instructions, then the workspace context; the role's name, digest and text are captured in the child's tree with that context. It runs the prompt as its one exchange and ends when that exchange ends.

#### Scenario: Child session linked
- **WHEN** an agent job `j3` of session `S` runs
- **THEN** a session exists under `S`'s directory whose tree records parent `S` and job `j3`, holding the child's whole conversation

#### Scenario: Role file changed after the child ran
- **WHEN** `.claude/agents/specwright-reviewer.md` is edited or deleted after a reviewer child ended
- **THEN** a request rebuilt from that child's tree carries the role text captured at its start

#### Scenario: Child cannot start
- **WHEN** the child engine exits before its first exchange, for example with `fatal` `not logged in`
- **THEN** the job ends `failed` and the call's result is `agent failed to start: not logged in`

### Requirement: Parent follows the child's state
The parent SHALL hold a mirror of the child's tree: it replaces the mirror on every `snapshot` and applies every `update`, and decides the child's exchange end, steps, usage and final text from the mirror, never from stream events. A child output line is accepted up to 64 MiB; a longer line, malformed JSON or a protocol other than 1 ends the job `failed` naming the cause.

#### Scenario: Large committed response
- **WHEN** the child's final assistant text is 3 MiB, committed in one update
- **THEN** the parent accepts it and the typed result holds the whole text before central composition

#### Scenario: Terminal update dropped by resync
- **WHEN** the child's pump drops the update that ends its exchange and sends `resync` and a fresh `snapshot`
- **THEN** the parent replaces its mirror, sees the ended exchange in the snapshot, and the job ends with the child's status without waiting for its deadline

#### Scenario: Malformed child output
- **WHEN** the child writes a line that is not JSON
- **THEN** the job ends `failed` with `child protocol error`, and the child is stopped

### Requirement: Typed agent result
An ended agent job SHALL record `agent`: role, model, child session, `status` (`done`, `failed`, `cancelled` or `timeout`), step count, token usage and any model note. Its typed result, returned by the call and by `job`, is one header line `agent <role> <status> (<steps> steps, session <id>)`, then the child's final assistant text, composed centrally like any result.

#### Scenario: Done
- **WHEN** a reviewer child finishes after 12 steps with final text `VERDICT: APPROVE`
- **THEN** the job records status `done` and 12 steps, and the output is the header line then `VERDICT: APPROVE`

#### Scenario: Child exchange failed
- **WHEN** the child's exchange stops on context overflow
- **THEN** the status is `failed`, and the output names the child's stop reason and holds whatever final text it produced

### Requirement: Child prompts relayed
Each permission prompt or question of a child SHALL reach the parent's answerer as a prompt naming the role and job, and the answer is passed back to the child. A job's open prompts are withdrawn only when that job is cancelled or ends, or the child withdraws them. A child of a parent started with `--yolo` runs with `--yolo`.

#### Scenario: Permission relayed
- **WHEN** an implementer child calls `bash` with `dart test` and it is not autoapproved
- **THEN** the client receives a permission prompt naming role `specwright-implementer` and the command, and `allow` runs it in the child

#### Scenario: Prompt withdrawn on cancel
- **WHEN** the parent is interrupted while a foreground child, cancelled by that interrupt, has a prompt open
- **THEN** the client receives `withdraw` for that prompt, and the child receives no answer

#### Scenario: Background child's prompt survives an unrelated interrupt
- **WHEN** a background reviewer child has a permission prompt open and the user interrupts the parent's running exchange
- **THEN** the background job keeps running, its prompt stays open, and a later `allow` reaches the child

### Requirement: Bounded agent jobs
At most 4 agent jobs SHALL be live at once, and each counts toward the 16-job bound. A call that would start a fifth fails with `too many live agents (4); wait for or cancel one with job`, and no process starts.

#### Scenario: Fifth agent refused
- **WHEN** 4 background agent jobs are running and the model calls `agent`
- **THEN** that call fails with the bound message, and after one ends a new `agent` call starts

#### Scenario: Shared job bound
- **WHEN** 14 shell jobs and 2 agent jobs are live and the model calls `agent`
- **THEN** the call fails with `too many live jobs (16); cancel one with job`

### Requirement: Agent cancellation and deadline
Cancelling an agent job, by interrupt, `job` cancel, rewind or shutdown, SHALL send the child an interrupt, then end its process tree after the supervisor's grace. A child still running at its deadline is ended the same way with status `timeout`. Neither claims that the child's external effects were undone.

#### Scenario: Interrupt during a child
- **WHEN** the user interrupts while a foreground implementer child is running a test
- **THEN** the child's exchange ends `cancelled`, the job records status `cancelled`, and the parent's call settles `cancelled`

#### Scenario: Deadline
- **WHEN** an agent job with `timeout_s` 60 is still running after 60 seconds
- **THEN** the job records status `timeout` and its output holds the child's text so far

### Requirement: Agent jobs on resume
Opening a session SHALL finalize each unfinished agent job as `cancelled` with reason `interrupted` and never start its child again. The child's own session is left as it is.

#### Scenario: Crash after the handoff intent
- **WHEN** the engine dies after an agent job's handoff intent is committed, before or after its streams are published but before it settles, and the session is resumed
- **THEN** the job settles with its child's status, `agent` fields and a `result` reference that resolves, and `job` `wait` returns the typed result

#### Scenario: Crash before the handoff intent
- **WHEN** the engine dies after the child exited but before the handoff intent, and the session is resumed
- **THEN** the job is `cancelled` with reason `interrupted`, and `job` `output` returns `agent <role> cancelled (interrupted before its result was stored; session <id>)`

#### Scenario: Typed result written but no intent
- **WHEN** the engine dies after the typed result was written, complete with a `done` header or partially, but before the handoff intent, and the session is resumed
- **THEN** the job is `cancelled` with reason `interrupted` and no `result` reference, `job` `wait` and `output` return the interrupted text above, the uncommitted result file is deleted, recovery's warning says `1 agent results discarded before their handoff`, and the child session still holds the child's final text

#### Scenario: Engine crashed during a child
- **WHEN** the engine dies while an agent job is running and the session is resumed
- **THEN** the job is `cancelled` with reason `interrupted`, no child process starts, and the child session stays readable

### Requirement: Child progress shown
While a foreground or background agent job runs, the engine SHALL send the client one ephemeral event per child tool call as it settles, naming the role, the tool and its one-line summary. These events are not recorded in the parent's tree, and a client that misses them loses nothing durable.

#### Scenario: Progress lines
- **WHEN** an implementer child runs `read`, `edit` and `bash`
- **THEN** the line client prints three indented lines prefixed with `specwright-implementer`, one per call

#### Scenario: Slow client
- **WHEN** the client is behind and the pump drops ephemeral events
- **THEN** child progress events are dropped like other ephemeral events, and the agent's typed result is still delivered in the tree
