# hook-deadlines Specification

## Purpose
Runs user-configured pre-tool hook processes under a deadline the engine enforces. A hook that hangs, crashes or times out can never block a turn: an optional hook becomes a visible no-op, and a deny-class hook fails closed.

## Requirements

### Requirement: User-configured pre-tool hooks
Hooks SHALL be defined only in the user's Kehai configuration, each with a name, an argv, the tools it applies to, a policy (`optional` or `deny`) and an optional `timeout_ms`. Hooks for a call run after argument validation and before the permission decision, in configuration order, each as a `hook` job. Each receives the call as JSON on stdin and has stdin closed after it.

#### Scenario: Hook sees the call
- **WHEN** a hook configured for `bash` runs before `bash` `ls`
- **THEN** its stdin is one JSON object with the tool, input, workspace root and session id, its job node has kind `hook`, and its output is stored

#### Scenario: Hooks in repository files
- **WHEN** the workspace contains hook definitions in any file
- **THEN** none of them runs

### Requirement: Hook outcome
Exit 0 SHALL let the call continue to the permission decision; it never approves the call. Exit 2 denies the call under either policy, with the hook's stderr as the reason. Any other exit, a crash or a launch failure is ignored for an `optional` hook, with a diag note, and denies under `deny`.

#### Scenario: Deny-class hook refuses
- **WHEN** a `deny` hook exits 2 with stderr `no force pushes`
- **THEN** the call settles `denied` with reason `hook <name>: no force pushes` and no prompt is shown

#### Scenario: Optional hook crashes
- **WHEN** an `optional` hook exits 1
- **THEN** the call proceeds and carries a diag line `[diag hook:<name>] exited 1; ignored`

### Requirement: Engine-enforced hook deadline
Each hook SHALL run under its `timeout_ms`, else the configured default. The engine kills the hook's process tree at the deadline without waiting for it to cooperate. An `optional` hook that timed out is a visible no-op; a `deny` hook that timed out denies. Either way the turn continues within the deadline plus the kill grace.

#### Scenario: Hung optional hook
- **WHEN** the hung-hook fixture, which never exits and ignores SIGTERM, is an `optional` hook with `timeout_ms` 500
- **THEN** the call proceeds within 3 s with a diag line `[diag hook:<name>] timed out after 500 ms; ignored`, and the fixture's process tree is gone

#### Scenario: Hung deny-class hook
- **WHEN** the same fixture is a `deny` hook with `timeout_ms` 500
- **THEN** the call settles `denied` with `hook <name> timed out after 500 ms` within 3 s, and the next call of the turn is not delayed by it

### Requirement: Default hook deadline above shell startup
The default hook deadline SHALL exceed the measured p95 startup of a trivial hook on Linux bash, Git Bash and PowerShell on native Windows by at least 3x. It is never below 2 s, so a healthy hook is not reported as timed out. The measurements are recorded with the default.

#### Scenario: Startup measured and default checked
- **WHEN** the startup benchmark runs a trivial hook 20 times per shell on the qualification hosts
- **THEN** the recorded p95 values times 3 are all below the default deadline, and a trivial hook under the default never times out in the test suite

#### Scenario: Invalid timeout configured
- **WHEN** a hook's `timeout_ms` is 0, negative or above 600,000
- **THEN** loading the configuration fails naming the hook and the allowed range, and no hook runs
