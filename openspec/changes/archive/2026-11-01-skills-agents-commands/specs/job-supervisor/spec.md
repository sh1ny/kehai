# Spec Delta

## MODIFIED Requirements

### Requirement: One job node shape
Every process the engine starts SHALL be a tree node `jobs/<id>` of one shape: `kind` (`shell`, `hook` or `agent`), `cmd`, `cwd`, `shell`, `call` (the owning call key), `launch` (a fresh token), `state` (`pending`, `running`, `settled`, `failed`, `cancelled`), `started`, `ended`, `exit`, `signal`, `spool` and the `stdout`, `stderr` and `output` references. It never holds PIDs or OS handles.

#### Scenario: Shell job recorded
- **WHEN** `bash` runs `echo hi` and it exits 0
- **THEN** `jobs/<id>` records kind `shell`, the command, state `settled`, exit 0 and stdout and output references whose handles resolve to `hi\n`, and no field holds a process id

#### Scenario: Launch failure
- **WHEN** the shell executable disappears between detection and launch
- **THEN** the job goes from `pending` to `failed` with the OS error as reason, and its call settles `failed`

## ADDED Requirements

### Requirement: Agent job fields
An `agent` job SHALL also record `agent` (role, model, child session, status, steps, usage, note) and a `result` reference to its typed result text; its `stdout` is the child's protocol stream.

#### Scenario: Agent job recorded
- **WHEN** `agent` runs role `specwright-reviewer` and the child finishes
- **THEN** `jobs/<id>` records kind `agent`, `cmd` naming the role, state `settled`, an `agent` field with status `done` and the child session id, and a `result` reference resolving to the typed result text, and no field holds a process id

#### Scenario: Agent job read with job
- **WHEN** `job` with action `wait` or `output` names a settled agent job
- **THEN** it returns the composed typed result text, not the child's protocol stream
