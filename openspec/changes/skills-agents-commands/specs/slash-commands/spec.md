# Spec Delta

## Purpose

Lets the user start an installed workflow by typing `/name args`: command definitions under `.claude/commands/` and user-invocable skills are expanded by the engine into the prompt the model receives, with the typed command kept on record.

## ADDED Requirements

### Requirement: Command definitions
A command SHALL be a `.md` file under `<project root>/.claude/commands/`, named by its path relative to that directory without `.md`, with `/` replaced by `:` (`opsx/propose.md` is `opsx:propose`). Optional YAML frontmatter is removed from its body. A file whose frontmatter does not parse is not a command and is recorded as a problem.

#### Scenario: Namespaced command
- **WHEN** `.claude/commands/opsx/propose.md` exists with frontmatter `name: "OPSX: Propose"`
- **THEN** the command `opsx:propose` exists and its body is the text after the frontmatter

#### Scenario: Broken frontmatter
- **WHEN** `.claude/commands/opsx/bad.md` starts with `---` and has no closing `---`
- **THEN** `opsx:bad` does not exist and a problem names the file

### Requirement: Skills as commands
Every skill SHALL also be a command of its own name unless its frontmatter sets `user-invocable: false`. When a command file and a skill share a name, the command file is used and the skill is recorded as shadowed for `/` use.

#### Scenario: User-invocable skill
- **WHEN** the user submits `/specwright-roadmap next`
- **THEN** the prompt the model receives is the `specwright-roadmap` skill loaded with arguments `next`, exactly as the `skill` tool returns it

#### Scenario: Skill not user-invocable
- **WHEN** the user submits `/specwright-commit` and that skill sets `user-invocable: false`
- **THEN** the submit is refused with `specwright-commit is not a user command`, and nothing is admitted

### Requirement: Expansion at submit
A submitted prompt whose first character is `/` followed by a command name SHALL be expanded before admission: the rest of the first line, trimmed, and every following line are the arguments. A prompt starting `//` is sent with the first `/` removed and not expanded. An unknown name is refused with `unknown command /<name>` and nothing is admitted.

#### Scenario: Command expanded
- **WHEN** the user submits `/opsx:propose add-dark-mode`
- **THEN** the exchange's user item holds `opsx/propose.md`'s body followed by `ARGUMENTS: add-dark-mode`

#### Scenario: Unknown command
- **WHEN** the user submits `/usr/bin/env`
- **THEN** the reply is `error` with `unknown command /usr/bin/env; start with // to send it as text`, and no exchange starts

#### Scenario: Escaped slash
- **WHEN** the user submits `//usr/bin/env is missing`
- **THEN** the model receives `/usr/bin/env is missing` unchanged

### Requirement: Command recorded on the exchange
An expanded exchange SHALL record `command`: the name, the arguments, the source file relative to the project root and the SHA-256 of the expanded text. The request id's fingerprint covers the typed text, so a duplicate submit reports the recorded exchange and is not expanded again.

#### Scenario: Recorded expansion
- **WHEN** `/opsx:apply` is expanded and admitted
- **THEN** the exchange node holds `command` with name `opsx:apply`, empty arguments, source `.claude/commands/opsx/apply.md` and the digest of the user item's text

#### Scenario: Definition changed before a duplicate
- **WHEN** `opsx/apply.md` is edited and the client resends the same request id and text
- **THEN** the reply reports the recorded exchange, and the user item keeps the text expanded the first time

### Requirement: Repository commands carry no permission
A command's or skill's frontmatter keys such as `allowed-tools` SHALL NOT change which calls are approved, autoapproved or prompted. Only the user's configuration and `--yolo` do.

#### Scenario: allowed-tools ignored for approval
- **WHEN** `/opsx:propose` (frontmatter `allowed-tools: Bash(openspec:*)`) runs and the model calls `bash` with `openspec new change x`
- **THEN** the call is prompted exactly as it would be without that frontmatter
