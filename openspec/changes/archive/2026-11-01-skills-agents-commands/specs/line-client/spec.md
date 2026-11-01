# Spec Delta

## MODIFIED Requirements

### Requirement: Ctrl-C
Ctrl-C while an exchange runs or a prompt is open SHALL send `interrupt` once and print `interrupting…`; further Ctrl-C until the exchange ends does nothing more. Ctrl-C at an idle prompt exits the client. On exit the client closes the engine's input, waits up to 15 s for it to exit, then kills it. The 15 s exceed an agent job's nominal 13 s shutdown, so an engine that exits in time has ended its child engines; one that takes longer is still killed, and a child it had not ended can survive.

#### Scenario: Interrupt a running exchange
- **WHEN** the user presses Ctrl-C twice while a `bash` call runs
- **THEN** exactly one `interrupt` is sent, the call line shows `cancelled`, and the `> ` prompt returns

#### Scenario: Engine stuck on exit
- **WHEN** the user exits and the engine has not exited 15 s after its input closed
- **THEN** the client kills the engine process and exits

#### Scenario: Engine ending its agents on exit
- **WHEN** the user exits while an agent job runs whose child ignores its soft stop and SIGTERM and has started a job in a session of its own
- **THEN** the engine waits out the 5 s soft stop, terminates the child and that job's process group, and finishes its shutdown in under 15 s, so the client never kills it and neither process survives
