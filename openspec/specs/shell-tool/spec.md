# shell-tool Specification

## Purpose
Runs model commands in a real shell detected on the host, with streamed full output, an exit-status envelope, and a foreground budget. A command still running when the budget expires is handed to the job supervisor rather than killed.

## Requirements

### Requirement: Real shell detection
`bash` SHALL run each command with a real shell found when the engine starts: `bash` on Linux and macOS. On native Windows it uses Git Bash when found, else PowerShell 7 (`pwsh`), else Windows PowerShell. The tool description and every result summary name the shell in use. No shell is emulated.

#### Scenario: Windows with Git Bash installed
- **WHEN** the engine starts on Windows with Git for Windows installed
- **THEN** `bash` runs commands through Git Bash's `bash.exe`, and the tool description and result summaries name `git-bash`

#### Scenario: No usable shell
- **WHEN** no supported shell can be found
- **THEN** `bash` is still listed, every call settles `error` with `no shell found; tried <list>`, and the other tools work normally

### Requirement: Command execution and status
A `bash` call SHALL run its command in the workspace root, or in its `cwd` argument, with stdin closed. Exit 0 settles `ok` with summary `exit 0`. Any other exit settles `error` with `exit <code>`, plus the signal when one ended it. A launch failure settles `failed` with the OS error.

#### Scenario: Failing command
- **WHEN** `bash` runs `dart analyze lib/missing.dart` and the command exits 3
- **THEN** the call settles `error` with summary `exit 3` and its stored output holds the analyzer's full text

#### Scenario: Command reads stdin
- **WHEN** a command waits to read stdin
- **THEN** it reads end-of-file at once instead of hanging

### Requirement: Streamed output persistence
A command's stdout and stderr SHALL be persisted as they arrive. The job keeps one stored result per stream. The model reads a combined result in arrival order. Output is held in memory one pipe read at a time, and a process that outputs faster than storage writes is slowed by backpressure, never by dropping bytes.

#### Scenario: Interleaved streams kept in order
- **WHEN** a command writes `a` to stdout, then `b` to stderr, then `c` to stdout, each followed by a newline and a 50 ms pause
- **THEN** the combined result is `a`, `b`, `c` on three lines, the stdout result holds `a` and `c`, and the stderr result holds `b`

#### Scenario: Output larger than memory budgets
- **WHEN** a command writes 200 MiB to stdout
- **THEN** all 200 MiB are stored, and the engine never buffers more than one pipe read per stream

### Requirement: Credential-free child environment
Shell and hook processes SHALL inherit the engine's environment except provider credential variables. Those are any whose name starts with `OPENAI_`, `ANTHROPIC_`, `AZURE_OPENAI_`, `GEMINI_` or `KEHAI_` and contains `KEY`, `TOKEN` or `SECRET`. The user may name exceptions in configuration. Kehai's stored OAuth tokens are never placed in a child environment.

#### Scenario: API key not inherited
- **WHEN** the engine runs with `OPENAI_API_KEY=sk-x` and `GH_TOKEN=g` set, and `bash` runs `env`
- **THEN** the output contains `GH_TOKEN=g` and contains no `OPENAI_API_KEY`

#### Scenario: User passthrough exception
- **WHEN** the configuration lists `OPENAI_API_KEY` as a passthrough exception
- **THEN** that variable is inherited and the call's summary notes `passing OPENAI_API_KEY`

### Requirement: Foreground budget hands off to a job
A `bash` call SHALL wait at most its foreground budget: the `timeout_s` argument (1–600), default 120 s. A command still running then is not killed. The call settles `partial` with the job id and a `job` hint, and the command keeps running as a background job whose output keeps persisting.

#### Scenario: Long command becomes a job
- **WHEN** `bash` runs a command that prints `start`, sleeps 5 s and prints `end`, with `timeout_s` 1
- **THEN** after about 1 s the call settles `partial` with summary `still running as job <id>; use job(<id>)`, and once the command exits the job records state `settled`, exit 0 and an output result containing both `start` and `end`

#### Scenario: Budget out of range
- **WHEN** `bash` is called with `timeout_s` 0 or 601
- **THEN** argument validation rejects the call and no process starts
