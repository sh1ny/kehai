# tool-permissions Specification

## Purpose
Decides whether each tool call may run: built-in read-only calls and calls the user allowlisted run without a prompt, credential files are never exposed, and everything else asks unless the user chose `--yolo`. Every decision is recorded in the session tree.

## Requirements

### Requirement: Built-in read-only allowlist
A call SHALL run without a prompt when it is one of:
- `read`, `grep`, `find` or `ls` whose resolved paths are inside the workspace root;
- `read_more` or `search_result`;
- `job` with action `status` or `output`;
- `ask`, whose question is itself the prompt to the user, so a headless `ask` settles `error` with `no user attached` (user-ask) rather than `denied`;
- a `bash` command proven read-only.

Symbolic links are resolved before the workspace check.

#### Scenario: Read inside the workspace
- **WHEN** `read` targets `lib/kehai.dart` in the workspace
- **THEN** it runs without a prompt and its node records `permission` `{decision: allow, by: builtin}`

#### Scenario: Path escapes the workspace
- **WHEN** `read` targets `../other/secret.txt`, or a workspace symlink that resolves outside the workspace
- **THEN** the call is not autoapproved and goes to the prompt

### Requirement: Whole-command read-only proof
A `bash` command SHALL be proven read-only only when it is one simple command with no `;`, `&`, `|`, `<`, `>`, `(`, `)`, `$`, backquote, newline, `~`, glob character, assignment or backslash outside single quotes. Its program must be `pwd`, `ls`, `cat`, `head`, `tail`, `wc` or `rg`, with only that program's listed options. Every path operand, attached or separate, must resolve inside the workspace from the effective `cwd`. PowerShell commands are never proven.

#### Scenario: Plain read-only command
- **WHEN** `bash` runs `rg -n TODO lib` under Git Bash
- **THEN** it runs without a prompt with `permission` `{decision: allow, by: builtin, rule: "rg"}`

#### Scenario: Mixed or substituted command
- **WHEN** `bash` runs `cat README.md; rm -rf build`, `cat $(ls)`, `ls > out.txt`, `rg --pre ./x foo` or `cat ../../.ssh/id_rsa`
- **THEN** none is autoapproved and each goes to the prompt

#### Scenario: Path hidden in an option or the working directory
- **WHEN** `bash` runs `rg -f/etc/passwd x`, `rg --file=../list x`, `rg --unknown-flag x`, or `cat notes.txt` with `cwd` `../other`
- **THEN** none is autoapproved, because an option operand, an unlisted option or the effective working directory leaves the workspace or is unproven

### Requirement: Autoapproved commands run without shell startup
A command run because it was autoapproved SHALL be executed directly as its proven argv, with no shell. Its program resolves only through absolute `PATH` entries outside the workspace. Its environment has no `BASH_ENV`, `ENV`, `BASH_FUNC_*`, `SHELLOPTS`, `BASHOPTS` or `RIPGREP_CONFIG_PATH`, and `rg` gets `--no-config`. No startup file or imported function runs.

#### Scenario: Repository startup script
- **WHEN** the engine runs with `BASH_ENV` naming a workspace script that creates `pwned.txt`, and the autoapproved command `pwd` runs
- **THEN** `pwd` prints the working directory and `pwned.txt` does not exist afterwards

#### Scenario: Program shadowed in the workspace
- **WHEN** `PATH` begins with `.` or a workspace directory holding an executable named `cat`, and the model runs `cat README.md`
- **THEN** the workspace `cat` is not run: the program resolves to the first absolute `PATH` entry outside the workspace, or the call goes to the prompt when none exists

### Requirement: User-owned allowlist
Allow rules beyond the built-in list SHALL come only from the user configuration file. A rule names a tool, or `bash` with an argv prefix (`["jj","status"]`). Such a rule matches only a command that passes the whole-command proof's shape rules. No repository file, skill, tool output or model text can add, widen or apply a rule.

#### Scenario: Allowlisted jj status
- **WHEN** the configuration allows `bash` argv prefix `["jj","status"]` and the model runs `jj status --no-pager`
- **THEN** it runs without a prompt with `permission` `{decision: allow, by: user, rule: "bash:jj status"}`

#### Scenario: Repository tries to allowlist
- **WHEN** the workspace contains a `.kehai/config.json` or `.claude/settings.json` listing allow rules for `bash`
- **THEN** those rules are ignored, and a matching command still goes to the prompt

#### Scenario: Prefix rule with appended command
- **WHEN** `["jj","status"]` is allowed and the model runs `jj status && jj git push`
- **THEN** the command is not autoapproved and goes to the prompt

### Requirement: Ask otherwise, or explicit yolo
A call that is not autoapproved SHALL be offered to the answerer as allow or deny before any effect. Allow runs it. Deny settles it with envelope status `denied`. With no answerer attached it is denied with reason `no user attached`. When the user started the engine with `--yolo`, such calls run without a prompt and record `by: yolo`.

#### Scenario: User denies an edit
- **WHEN** `edit` is called and the answerer replies deny
- **THEN** the call settles with envelope status `denied`, the file is untouched, and `permission` records `{decision: deny, by: answer}`

#### Scenario: Yolo run
- **WHEN** the engine was started with `--yolo` and `bash` runs `dart test`
- **THEN** it runs without a prompt and `permission` records `{decision: allow, by: yolo}`

#### Scenario: No answerer, not yolo
- **WHEN** `write` is called with no answerer attached and without `--yolo`
- **THEN** it settles `denied` with `no user attached` and nothing is written

### Requirement: Credential files never exposed
`read`, `edit`, `write`, `grep`, `find` and `ls` SHALL refuse every Kehai credential file: any file directly in the Kehai home whose name starts with `auth.`. That covers the records, `auth.lock` and the backends' temporary files. This applies even under `--yolo` and when allowlisted. Searches exclude the whole name family, whatever exists at enumeration time. Shell commands run with user privileges and are not covered.

#### Scenario: Read the credential file
- **WHEN** `read` targets `<kehai home>/auth.json` under `--yolo`
- **THEN** the call settles `denied` with `credential files are not readable by tools`, and no byte of the file reaches the result store

#### Scenario: Grep that would cover the home
- **WHEN** `grep` searches under the Kehai home directory
- **THEN** the credential files are excluded from the search, and the summary says so

#### Scenario: Search during a credential write
- **WHEN** a credential write is paused after creating `auth.json.<pid>_0.tmp` and `grep` searches the Kehai home for a token substring it contains
- **THEN** no match from the temporary file is returned and none of its bytes reach the result store

### Requirement: User configuration file
The engine SHALL read its user configuration from `config.json` in the Kehai home. It holds the allow rules, hooks, `rgPath`, environment passthrough, the default `model` id, and `models`: per-model settings keyed by model id, each with an optional `contextWindow` (a positive integer) that overrides the backend's. A missing file means defaults. An unreadable, invalid or unknown-key file stops the engine from starting, naming the file and the first problem. Repository content never changes it.

#### Scenario: Missing configuration
- **WHEN** no `config.json` exists in the Kehai home
- **THEN** the engine starts with no user rules, no hooks, `rg` from `PATH`, no default model and no window overrides

#### Scenario: Invalid configuration
- **WHEN** `config.json` is not valid JSON, or holds an unknown key `allwo`
- **THEN** the engine refuses to start with `<path>: invalid JSON at line <n>` or `<path>: unknown key allwo`, and no tool runs

#### Scenario: Model settings
- **WHEN** `config.json` sets `"model": "gpt-5.5"` and `"models": {"gpt-5.5": {"contextWindow": 200000}}`
- **THEN** the engine defaults to `gpt-5.5` and uses 200,000 tokens as its window, whatever the backend reports

#### Scenario: Invalid model settings
- **WHEN** `models` sets `contextWindow` to `0`, or a model entry holds an unknown key `window`
- **THEN** the engine refuses to start with `<path>: models.gpt-5.5.contextWindow: must be a positive integer` or `<path>: models.gpt-5.5: unknown key window`
