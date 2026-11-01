# skills Specification

## Purpose
Lets the model and the user use the skills installed in the project (`SKILL.md` folders under `.claude/skills/` and `.agents/skills/`), loading each one whole with its paths resolved, so installed workflows such as Specwright run unchanged.

## Requirements

### Requirement: Skill discovery
A skill SHALL be a directory directly under `<project root>/.claude/skills/` or `<project root>/.agents/skills/` holding `SKILL.md` with YAML frontmatter that has a `name` and a `description`. The `name` must be 1-64 characters of lowercase letters, digits and hyphens and equal the directory name; the description must be 1-1,024 characters. Other entries are skipped with a recorded problem.

#### Scenario: Installed skills found
- **WHEN** `.claude/skills/specwright-roadmap/SKILL.md` has `name: specwright-roadmap` and a description
- **THEN** a skill `specwright-roadmap` is available with that description and its directory as base directory

#### Scenario: Invalid frontmatter
- **WHEN** a `SKILL.md` has no frontmatter, a `name` that differs from its directory, or an empty description
- **THEN** that directory is not a skill, and a problem names its path and the reason

#### Scenario: Directory without SKILL.md
- **WHEN** `.agents/skills/` holds a file `LICENSE.dart` and a directory with no `SKILL.md`
- **THEN** neither is a skill and neither is reported as a problem

### Requirement: Skill precedence
When both roots hold a skill of the same name, the `.claude/skills/` one SHALL be used and the other is recorded as shadowed. A skill whose frontmatter sets `disable-model-invocation: true` is left out of the catalog and cannot be loaded by the model.

#### Scenario: Same skill in both roots
- **WHEN** `openspec-propose` exists in `.claude/skills/` and, with different text, in `.agents/skills/`
- **THEN** loading `openspec-propose` returns the `.claude/skills/` text, and the inventory lists the `.agents/skills/` copy as shadowed

#### Scenario: Model invocation disabled
- **WHEN** a skill sets `disable-model-invocation: true` and the model calls `skill` with its name
- **THEN** the call settles with envelope status `error` and `skill <name> cannot be loaded by the model`

### Requirement: Skill tool
The `skill` tool SHALL take a `name` and optional `args`, and resolve the name as a skill or as a command (`opsx:propose`). Its result is `Base directory for this skill: <dir>`, a blank line, the body after the frontmatter with substitutions applied, then `ARGUMENTS: <args>` when args are given and the body has no `$ARGUMENTS`. A command result omits the base directory line.

#### Scenario: Skill loaded with arguments
- **WHEN** the model calls `skill` with `{"name":"specwright-roadmap","args":"next"}`
- **THEN** the result begins `Base directory for this skill: <project root>/.claude/skills/specwright-roadmap`, holds the body, and ends `ARGUMENTS: next`

#### Scenario: Command loaded by the model
- **WHEN** the model calls `skill` with `{"name":"opsx:propose","args":"add-thing"}`
- **THEN** the result is the expanded `.claude/commands/opsx/propose.md` body with `add-thing` as its arguments

#### Scenario: Unknown name
- **WHEN** the model calls `skill` with `{"name":"no-such-skill"}`
- **THEN** the call settles with envelope status `error` and `unknown skill or command no-such-skill`, listing up to 5 closest names

### Requirement: Path and argument substitution
In a loaded skill or command body, every `${CLAUDE_SKILL_DIR}` SHALL be replaced by the skill's base directory written with forward slashes, and every `$ARGUMENTS` by the arguments. No other text is changed: shell variables such as `$HOME` or `${BASH_SOURCE}` stay as written.

#### Scenario: Skill directory substituted
- **WHEN** a skill at `F:\work\.claude\skills\specwright-pr` contains `${CLAUDE_SKILL_DIR}/scripts/` and `$HOME`
- **THEN** the loaded body contains `F:/work/.claude/skills/specwright-pr/scripts/` and `$HOME` unchanged

#### Scenario: Empty arguments
- **WHEN** a command body contains `$ARGUMENTS` and is invoked with no arguments
- **THEN** each `$ARGUMENTS` becomes the empty string and no `ARGUMENTS:` line is appended

### Requirement: Skills delivered whole
A loaded skill or command SHALL be composed with no truncation cut. A file over 256 KiB, or a result whose estimate exceeds the window minus the context in use recorded for the calling step, settles with envelope status `error` naming the size and the limit, and its file stays readable with `read`. With an unknown window only the file bound applies.

#### Scenario: Large skill loaded whole
- **WHEN** a 55 KiB `SKILL.md` is loaded with ample context left
- **THEN** the model receives every line of its body and no truncation line or handle

#### Scenario: Over the file bound
- **WHEN** a `SKILL.md` is 300 KiB
- **THEN** the call settles with `skill file is 300 KiB, over the 256 KiB limit; read <path> instead`

#### Scenario: Over the context capacity
- **WHEN** a skill's estimate exceeds the context left in the window
- **THEN** the call settles with envelope status `error` naming the estimate and the remaining capacity, and nothing is truncated

#### Scenario: Whole skill plus parallel results over a known window
- **WHEN** the window is known, a skill fits, but parallel calls of the same step push the next request over the window
- **THEN** the skill is delivered whole, and the next step stops with the context-overflow message before any provider request is sent

#### Scenario: Unknown window
- **WHEN** the model's window is unknown and a 55 KiB skill is loaded
- **THEN** the skill is delivered whole, the next request is sent, and an overflow the provider reports is handled as the agent loop's context-overflow stop

#### Scenario: Skill directory outside the project
- **WHEN** `.claude/skills/x` is a junction to a folder outside the project root
- **THEN** `x` is not a skill and loading it fails with `unknown skill or command x`; doctor names the path as outside the project root

### Requirement: Inventory in doctor
`kehai doctor` SHALL list, for the current workspace, the project root, the applicable `AGENTS.md` files, each skill with its root, each command, each agent role with its model and mapped tools, and every recorded problem: invalid files, shadowed copies and unmapped tool names. Problems do not make doctor fail.

#### Scenario: Healthy workspace
- **WHEN** `kehai doctor` runs in this repository
- **THEN** it lists every `specwright-*` and `openspec-*` skill, every `/opsx:*` command and the three `specwright-*` roles, with no problem other than shadowed `.agents/skills/` copies

#### Scenario: Broken skill reported
- **WHEN** one `SKILL.md` has invalid YAML frontmatter
- **THEN** doctor lists that path under problems with the parse error's line, lists the other skills, and exits with the same status as without it
