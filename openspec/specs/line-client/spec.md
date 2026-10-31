# line-client Specification

## Purpose
Lets a person work with Kehai in a terminal. The interactive `kehai` command starts the engine as `kehai rpc` and renders what it sends: streamed text, one line per tool call, and prompts to answer. It runs on Linux and native Windows.

## Requirements

### Requirement: Client over the engine process
`kehai`, run without a subcommand, SHALL start `kehai rpc` from the same executable as a child process, with the same workspace and its session and model options. It talks to the child only through the RPC protocol. It holds no session state beyond the tree it builds from `snapshot` and `update`. If the engine sends `fatal` or exits, the client prints the cause and exits 1.

#### Scenario: Start
- **WHEN** the user runs `kehai --model gpt-5.5` in a workspace while logged in
- **THEN** a `kehai rpc --model gpt-5.5` child starts, and the client shows the session id, the model and a `> ` prompt

#### Scenario: Engine cannot start
- **WHEN** the user runs `kehai` while not logged in
- **THEN** the client prints the engine's `fatal` message, which names `kehai login openai`, and exits 1

### Requirement: Model selection
The model SHALL be `--model`, else the user configuration's `model`, else the model the resumed session last used. With none of them, startup fails, listing the available model ids and how to set one. A model the backend does not list is refused at startup.

#### Scenario: No model configured
- **WHEN** the user runs `kehai` with no `--model`, no configured model, and no session to resume
- **THEN** startup fails with `no model selected; use --model <id> or set "model" in <config path>` followed by the available model ids

#### Scenario: Unknown model
- **WHEN** the user runs `kehai --model gpt-0`
- **THEN** startup fails with `model gpt-0 is not available` and the list of available ids

### Requirement: Line input
The client SHALL read one prompt per line. A line ending in `\` continues on the next line, and the joined text is submitted without the backslashes. An empty line is ignored. `/exit` or end of input exits the client. Input typed while an exchange runs is refused with a note, unless it answers an open prompt.

#### Scenario: Continued line
- **WHEN** the user types `fix the test\` and then `in lib/a.dart`
- **THEN** one prompt `fix the test\nin lib/a.dart` is submitted

#### Scenario: Typing during an exchange
- **WHEN** the user enters text while an exchange runs and no prompt is open
- **THEN** the client prints `busy: wait for the reply or press Ctrl-C`, and nothing is submitted

### Requirement: Streamed text
Assistant text SHALL be printed as its `stream` deltas arrive. When the step's committed item arrives, the client reprints nothing that already matched. If deltas were lost to a resync, it prints the committed text that was not shown. Reasoning deltas are not shown.

#### Scenario: Live text
- **WHEN** a step streams `Hel` then `lo`
- **THEN** `Hello` appears in two parts before the step completes, and it is not printed again on commit

#### Scenario: Resync mid-text
- **WHEN** a resync drops the deltas after `Hel` and the step commits `Hello world`
- **THEN** the client prints `lo world` once, so the screen reads `Hello world`

### Requirement: One line per tool call
For each tool call reaching a terminal state, the client SHALL print one line: `[<tool> <envelope status>] <summary>: <argument summary>`. The argument summary is the path, pattern or command, cut to fit 160 characters with `…`. A call `cancelled` or `failed` without an envelope shows that status.

#### Scenario: Settled call
- **WHEN** a `bash` call `dart test` settles `ok` with summary `exit 0`
- **THEN** the client prints `[bash ok] exit 0: dart test`

#### Scenario: Long command
- **WHEN** a `bash` command is 400 characters long
- **THEN** its line is at most 160 characters and ends with `…`

### Requirement: Answering prompts
The client SHALL keep one active prompt, by key, and a FIFO of pending ones. An arrival never replaces the active prompt: it is queued and shown as a one-line notice. Input answers only the active prompt, with at most one answer in flight. A refusal keeps the prompt active. Acceptance or `withdraw` removes that key and activates the next. Permission: `1`/`y`/`allow`, `2`/`n`/`deny`; questions: number, choice or allowed text.

#### Scenario: Allow a command
- **WHEN** a permission prompt for `bash` `dart analyze` is shown and the user types `1`
- **THEN** the client sends `answer` `allow` for that key, and the call runs

#### Scenario: Two permission prompts
- **WHEN** permission prompts for `bash` `dart analyze` (key A) and `write` `lib/a.dart` (key B) arrive together while A is active, and the user types `1`, then `2`
- **THEN** B is shown only as `queued: write lib/a.dart`, `1` is sent as `answer` `allow` for A alone, B then becomes active with its own choice menu, and `2` denies B

#### Scenario: Refused answer keeps the active prompt
- **WHEN** an answer to the active key A is refused by the engine while key B is queued
- **THEN** the refusal is shown, A stays active, and B stays queued

#### Scenario: Withdrawal advances the queue
- **WHEN** the queued key B is withdrawn, and then the active key A is withdrawn while key C is queued
- **THEN** B is removed without ever becoming active, and when A is withdrawn C becomes the active prompt

#### Scenario: Invalid choice
- **WHEN** a question offers `1) bash 2) pwsh` without free text and the user types `zsh`
- **THEN** the client shows `answer must be one of: bash, pwsh` and asks again

### Requirement: Ctrl-C
Ctrl-C while an exchange runs or a prompt is open SHALL send `interrupt` once and print `interrupting…`; further Ctrl-C until the exchange ends does nothing more. Ctrl-C at an idle prompt exits the client. On exit the client closes the engine's input, waits up to 5 s for it to exit, then kills it.

#### Scenario: Interrupt a running exchange
- **WHEN** the user presses Ctrl-C twice while a `bash` call runs
- **THEN** exactly one `interrupt` is sent, the call line shows `cancelled`, and the `> ` prompt returns

#### Scenario: Engine stuck on exit
- **WHEN** the user exits and the engine has not exited 5 s after its input closed
- **THEN** the client kills the engine process and exits

### Requirement: Native Windows and Linux
The client and the engine SHALL run on native Windows, without WSL, and on Linux. Text is read and written as UTF-8 on both. On Windows, Ctrl-C reaches the client as a console control event and is handled as on Linux.

#### Scenario: Windows console
- **WHEN** the user runs `kehai` in a Windows Terminal PowerShell session and submits a prompt containing `naïve`
- **THEN** the prompt reaches the model as `naïve`, the reply streams, and Ctrl-C interrupts as on Linux

#### Scenario: Non-terminal input
- **WHEN** standard input is a pipe holding two lines
- **THEN** the client submits the first, waits for its exchange to end, submits the second, then exits at end of input
