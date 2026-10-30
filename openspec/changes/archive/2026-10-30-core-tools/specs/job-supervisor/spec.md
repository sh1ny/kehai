# Spec Delta

## Purpose

Owns every process Kehai starts as one kind of job: admission, the foreground budget, streamed output, deadlines and cancellation. It also keeps those jobs consistent with the session tree across rewind, fork and resume, without replaying any external effect.

## ADDED Requirements

### Requirement: One job node shape
Every process the engine starts SHALL be a tree node `jobs/<id>` of one shape: `kind` (`shell` or `hook`), `cmd`, `cwd`, `shell`, `call` (the owning call key), `launch` (a fresh random token), `state` (`pending`, `running`, `settled`, `failed` or `cancelled`), `started`, `ended`, `exit`, `signal` intent, `spool` (its temporary output file names) and the `stdout`, `stderr` and `output` result references. It never holds PIDs or OS handles.

#### Scenario: Shell job recorded
- **WHEN** `bash` runs `echo hi` and it exits 0
- **THEN** `jobs/<id>` records kind `shell`, the command, state `settled`, exit 0 and stdout and output references whose handles resolve to `hi\n`, and no field holds a process id

#### Scenario: Launch failure
- **WHEN** the shell executable disappears between detection and launch
- **THEN** the job goes from `pending` to `failed` with the OS error as reason, and its call settles `failed`

### Requirement: Bounded live jobs
At most 16 jobs SHALL be live (`pending` or `running`) at once, across foreground and background. A call that would start a 17th settles `failed` with `too many live jobs (16); cancel one with job`, and no process starts.

#### Scenario: Background jobs fill the bound
- **WHEN** 16 background jobs are running and `bash` is called again
- **THEN** the call settles `failed` with the bound message, and after one job is cancelled a new `bash` call starts

#### Scenario: Bound frees on exit
- **WHEN** a live job exits while the bound is full
- **THEN** its node becomes `settled` and the live count drops to 15 before the next admission is decided

### Requirement: Job deadline
Every job SHALL have a deadline: the `deadline_s` argument of the call (1–86,400), default 3,600 s. Its wall clock starts at launch and runs whether the job is foreground or background. At the deadline the job is terminated, as cancellation does it, and recorded `cancelled` with reason `deadline`. A foreground call ended this way settles with envelope status `timeout`.

#### Scenario: Background job reaches its deadline
- **WHEN** a job started with `deadline_s` 2 runs `sleep 30`
- **THEN** about 2 s after launch it is terminated and its node records `cancelled` with reason `deadline` and its output so far

#### Scenario: Process ignores termination
- **WHEN** a job that traps SIGTERM reaches its deadline
- **THEN** it is force-killed after a 2 s grace period and its node records the forced kill

### Requirement: Cancellation terminates the process tree
Cancelling a job SHALL first record its `signal` intent, then terminate the process tree: on Linux and macOS, SIGTERM to its process group, and SIGKILL after a 2 s grace; on Windows, a tree kill. The node records `cleanup` `confirmed` only when the platform proves no process remains, else `uncertain` with the reason. No external effect is undone.

#### Scenario: Child processes die with the job
- **WHEN** a job runs a shell that starts two background children, and the job is cancelled on Linux
- **THEN** the shell and both children are gone, and the node records `cancelled` with `cleanup` `confirmed`

#### Scenario: Cleanup cannot be proven
- **WHEN** a job is cancelled on Windows, or a process survives SIGKILL's probe
- **THEN** the node records `cancelled` with `cleanup` `uncertain` and the reason, and the cancel result reports it

### Requirement: Bounded output drain
After a job's direct process exits, or after its cancellation's kill grace, the supervisor SHALL stop waiting for its output pipes within a fixed bound: 2 s, then process-group termination, then 2 s more, then forced closing of the readers. Bytes already received are kept, an affected stream is `complete: false`, and `cleanup` records `uncertain` with the reason. The job then settles and releases its admission slot.

#### Scenario: Escaped descendant holds the output pipe
- **WHEN** a command starts a descendant in a new session that keeps stdout open and sleeps, and the command then exits, or is cancelled, or its node is removed by rewind
- **THEN** within 4 s plus the kill probe of the exit or kill grace, the job is settled or `cancelled` (or its streams are listed under `meta/orphans/<id>`), every byte printed before is in its `stdout` and `output` results with `complete: false`, `cleanup` is `uncertain` naming the held pipe, and a new job can be admitted in its slot

#### Scenario: Hook whose descendant holds the pipe
- **WHEN** a pre-tool hook times out and its escaped descendant keeps the hook's stdout open
- **THEN** the tool call proceeds within the hook deadline guarantee, and the hook job settles within the drain bound and releases its slot

### Requirement: Job tool
`job` SHALL take a job id and an action:
- `status` returns state, exit, runtime and output size;
- `wait` waits up to `timeout_s` (1–600, default 60), then returns status;
- `output` stores the output so far as a result marked incomplete while the job runs, and returns its handle composed with the `bash` cut;
- `cancel` cancels the job.

An unknown id is an error.

#### Scenario: Follow a backgrounded command
- **WHEN** a command was handed off as job `j1` and the model calls `job` `output` on `j1` while it runs, then `wait` until it exits
- **THEN** `output` returns the lines printed so far with a handle marked `complete: false`, and `wait` returns state `settled` and the exit code

#### Scenario: Unknown or finished job
- **WHEN** `job` `cancel` names an id not in the tree, or a job already `settled`
- **THEN** the first settles `error` with `unknown job <id>`; the second settles `ok` with summary `job <id> already settled` and changes nothing

### Requirement: Generic rewind reconciliation
After every committed rewind, one reconciliation pass SHALL compare live runtime jobs with the rewound tree. A runtime job whose node is gone, or whose node holds a different `launch`, is terminated as cancellation does it. Its cleanup is recorded under `meta/orphans/<id>`. A node restored to `pending` or `running` with no runtime is recorded `cancelled` with reason `rewound`.

#### Scenario: Rewind past a job's start
- **WHEN** a job started in turn 3 is still running and the session is rewound to turn 2
- **THEN** the process is terminated, `jobs/<id>` is absent, and `meta/orphans/<id>` records its command, the rewind turn and its cleanup

#### Scenario: Rewind restores a finished job as running
- **WHEN** a job started in turn 3, settled in turn 5, and the session is rewound to turn 4
- **THEN** the restored node, which reads `running`, is recorded `cancelled` with reason `rewound`, and no process is started

#### Scenario: Rewind leaves a live job's start in place
- **WHEN** a job started in turn 3 is still running and the session is rewound to turn 4
- **THEN** the process keeps running, the node is unchanged, and the job later settles normally

### Requirement: Stale callbacks rejected
Every update from a running job or call SHALL be applied as a guarded append. It is committed only if the target node still exists with the same `launch` token, or call attempt, and a non-terminal state, checked inside the session writer's queue. A failing update is dropped and reported to the caller as stale. It never recreates or changes a node.

#### Scenario: Output arrives after rewind removed the job
- **WHEN** a job's exit is reported after a rewind removed `jobs/<id>`
- **THEN** no record is appended for it, `jobs/<id>` stays absent, and the update returns `stale`

#### Scenario: Race between settle and cancel
- **WHEN** a job's exit and its cancellation are submitted at the same moment
- **THEN** exactly one terminal state is recorded, and the other update returns `stale`

#### Scenario: Stale update from a live process
- **WHEN** any guarded update for a job whose process is still alive returns `stale`
- **THEN** the supervisor terminates that process tree, and records its cleanup under `meta/orphans/<id>` when the job node is gone

### Requirement: Launch ownership
The supervisor SHALL own a job before any asynchronous launch step, holding a runtime reservation under its `launch` token. A rewind or cancellation that finalizes a node while its launch is in progress marks the reservation cancelled. A process that starts after that is terminated at once, and its `running` update is never applied.

#### Scenario: Rewind between pending and process start
- **WHEN** a rewind removes `jobs/<id>` after its `pending` record and before the process has started, and the start then succeeds
- **THEN** the new process tree is terminated within the kill grace, no `running` record is appended, and `meta/orphans/<id>` records it

#### Scenario: Cancel while launching
- **WHEN** a job is cancelled after its `pending` record and before its `running` record
- **THEN** its node is recorded `cancelled` with reason `user`, any process that started is terminated, and the node never reads `running`

### Requirement: Resume finalizes tool and job nodes
Attaching the tool runtime to a session opened for write SHALL first finalize every `pending` or `running` call or job node: `cancelled`/`interrupted`, or `failed` if it had recorded an error. Each call gets a stored result `interrupted: effects uncertain` with `complete: false`. Each job's surviving output spools are kept as `complete: false` results. This precedes any admission. The attach reports the count and warns processes may still run. Nothing is relaunched.

#### Scenario: Crash during a running command
- **WHEN** an engine is killed while a `bash` call and its job are `running`, and the session is reopened and the runtime attached
- **THEN** before the first call is admitted both nodes read `cancelled` with reason `interrupted`, the attach reports 2 finalized nodes with the process warning, and the command is not run again

#### Scenario: Crash before any output existed
- **WHEN** an engine is killed right after a call's `pending` record
- **THEN** after attach the call reads `cancelled`/`interrupted` with envelope status `error` and a result reference with `complete: false` whose text states the call was interrupted with uncertain effects

#### Scenario: Crash with output already spooled
- **WHEN** an engine is killed while a job had written 300 lines of output to its spool
- **THEN** after attach the job's `output` reference resolves to at least the bytes flushed before the crash, marked `complete: false`, and the spool file no longer exists under its temporary name

#### Scenario: Fork child with live jobs
- **WHEN** a session with a running job is forked and the child is opened with the runtime attached
- **THEN** the child's copy of the job node is `cancelled` with reason `interrupted`, the parent's process keeps running, and the parent's node is unchanged

#### Scenario: Finalization append fails
- **WHEN** a storage error stops a finalization record
- **THEN** the attach fails with that error and the runtime admits no call

### Requirement: Crash-safe result handoff
A job SHALL have a launch record under `meta/handoffs`, which rewind never removes, from admission on, naming its spools. Its output then passes from spool to result in this order: an intent added to that record with each stream's descriptor, the rename to the content-addressed name, the descriptor, the terminal record, then the record's removal. Every reference any consumer sees resolves, and every crash point, after a rewind or during attach, leaves each stream reachable or recorded absent.

#### Scenario: Crash during the result handoff
- **WHEN** an engine is killed after a job's handoff intent commits but before any spool is renamed, or after only the `stdout` spool is renamed, or after the spools are renamed but before the descriptors and terminal state are recorded
- **THEN** after attach each of `stdout`, `stderr` and `output` resolves to the bytes the job produced, no reference names a missing file, and no spool remains under its temporary name

#### Scenario: Crash during attach
- **WHEN** attach is killed after it recorded an interrupted job's intent and renamed its spools, but before it registered the descriptors, and the session is opened again
- **THEN** the second attach registers the descriptors and finalizes the job once, and every reference resolves

#### Scenario: Rewind between registration and settling
- **WHEN** a job started in turn 3 exits in turn 5, its handoff is paused after its descriptors are registered, the session is rewound to turn 4, and the handoff then resumes
- **THEN** the job settles with its exit code only after its descriptors are registered again, and every reference resolves and is copied by a fork

#### Scenario: Rewind, then crash, during the handoff
- **WHEN** a job started in turn 3 exits in turn 5, its spools are renamed and its descriptors registered, the session is rewound to turn 4, and the engine is killed before the job settles
- **THEN** after reopen and attach, the job reads `settled` with its exit code, and all three of `stdout`, `stderr` and `output` resolve to the bytes it produced

#### Scenario: Reopen right after settling
- **WHEN** an engine is killed immediately after a job's terminal record, and the session is reopened and the runtime attached
- **THEN** attach only removes the job's leftover `meta/handoffs` entry, records nothing for the job, and its references resolve

#### Scenario: Intent cleanup for every owner state
- **WHEN** a job settles normally; or attach finds an intent whose job is terminal, whose job node is absent, or whose job carries another `launch`; or a clear is repeated after the intent is gone
- **THEN** the intent is removed in each of the first four cases (for an absent or superseded job, only after its stream mapping is recorded under `meta/orphans/<id>`), the repeated clear appends nothing and succeeds, and a following attach finds no intent

#### Scenario: Crash during the orphan transfer
- **WHEN** a rewind removes a job between its intent and its settle, and the engine is killed before the orphan record, after it but before the intent is removed, or during the next attach at either point
- **THEN** after the final attach, `meta/orphans/<id>` lists each stream with its hash and disposition, the files it names exist, and no intent remains. Repeated attaches record the same mapping once.

#### Scenario: Rewind before the intent
- **WHEN** a running job with output in its spools is removed by a rewind before it exits, or after it seals its streams but before its intent is recorded, and the engine is then killed and the session opened twice
- **THEN** `meta/orphans/<id>` lists each stream with its spool name, hash and disposition `spooled`, the spool files still exist, no job node is recreated, and no launch record remains

#### Scenario: Cancel or rewind a running job before its intent
- **WHEN** a job running `sleep 30` has its spools created and its launch record holds no intent, and it is then cancelled, or a rewind removes its node
- **THEN** its process tree is terminated within the kill grace. A cancelled job reads `cancelled` with every stream `complete: false`; a rewound job's streams are listed under `meta/orphans/<id>`. Neither waits for the process to exit by itself

#### Scenario: Rewind between settling and clearing
- **WHEN** a job started in turn 3 settles in turn 5, its handoff is paused before the intent is removed, and the session is rewound to turn 4
- **THEN** the intent is not removed while the job reads `running`; the job is settled again from the intent with its exit code and resolvable references, and only then is the intent removed

#### Scenario: Cancelled or timed-out output stays incomplete after a crash
- **WHEN** a job is cancelled, or reaches its deadline, and its process leaves an exit code, and the engine is killed after the handoff intent commits but before the job settles
- **THEN** after attach the job reads `cancelled` with its reason, and every one of `stdout`, `stderr` and `output` is referenced with `complete: false`, exactly as without the crash

#### Scenario: Fork child inherits a handoff intent
- **WHEN** a session is forked while one of its jobs is between its intent and its settle, and the child is opened with the runtime attached
- **THEN** the child's job reads `cancelled` with reason `interrupted`, its streams are `complete: false` or absent, the child renames no file of the parent, and the parent's handoff completes unaffected

#### Scenario: Consumer during the handoff
- **WHEN** a job's handoff is paused after its intent commits and again after its spools are renamed, and at each pause a subscriber reads `jobs/<id>`, the model calls `job` `status` and `output`, and the session is forked
- **THEN** at each pause the job is still non-terminal with no stream references, every handle that exists resolves, the fork succeeds, and once the handoff completes every reference resolves in the parent
