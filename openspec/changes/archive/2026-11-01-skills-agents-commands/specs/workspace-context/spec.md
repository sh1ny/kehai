# Spec Delta

## Purpose

Gives every model request the project's own standing instructions (`AGENTS.md`) and the catalog of installed skills, captured in the session tree so a request can be rebuilt exactly and the prompt cache stays warm.

## ADDED Requirements

### Requirement: Project root and applicable AGENTS.md files
The project root SHALL be the nearest ancestor of the workspace, the workspace included, that holds `.git` or `.jj`; with none it is the workspace. The applicable `AGENTS.md` files are those named exactly `AGENTS.md` in the project root and each directory down to the workspace, ordered root first. Nested `AGENTS.md` files below the workspace are not applicable.

#### Scenario: Workspace below the project root
- **WHEN** the workspace is `<repo>/pkg/app`, `<repo>` holds `.git`, and `AGENTS.md` exists in `<repo>` and `<repo>/pkg/app` but not `<repo>/pkg`
- **THEN** the applicable files are `<repo>/AGENTS.md` then `<repo>/pkg/app/AGENTS.md`

#### Scenario: No repository and no file
- **WHEN** the workspace has no `.git` or `.jj` in it or any ancestor and holds no `AGENTS.md`
- **THEN** the project root is the workspace and no `AGENTS.md` is applicable, and the exchange runs with no project instructions

#### Scenario: Unreadable file
- **WHEN** an applicable `AGENTS.md` cannot be read or is not valid UTF-8
- **THEN** it is left out, and the captured context records a problem naming its path and the cause

### Requirement: Automatic reads stay inside the project
Every read the engine makes without a tool call (`AGENTS.md`, `SKILL.md`, command and role files, at capture, load, expansion or child start) SHALL resolve the file's links, junctions included, and read it only when the resolved path is inside the resolved project root and is not a credential file of the Kehai home. Otherwise nothing is read or stored, and a problem names the path and `outside the project root` or `credential file`.

#### Scenario: File inside the project
- **WHEN** `AGENTS.md` is a regular file in the project root
- **THEN** its text is captured

#### Scenario: Link to a file outside the project
- **WHEN** `<repo>/AGENTS.md` is a symbolic link or junction target outside `<repo>`, such as `~/notes/private.md`
- **THEN** no byte of the target is read or captured, and the context records `AGENTS.md: outside the project root`

#### Scenario: Link to credentials
- **WHEN** `.claude/skills/x/SKILL.md` links to `<Kehai home>/auth.json`
- **THEN** the file is not read, `x` is not a skill, and the problem says `credential file`

### Requirement: Budget follows the instructions
The context in use SHALL be derived from a step's reported usage only when that step's request carried the same instructions identity (built-in version, context key and role) as the request being built. Otherwise the whole request is estimated.

#### Scenario: Same instructions
- **WHEN** exchange 2 has the same context key as exchange 1's last completed step
- **THEN** the context in use starts from that step's reported usage

#### Scenario: Larger instructions push over the window
- **WHEN** a small exchange 1 completes, `AGENTS.md` grows by 30,000 tokens, and exchange 2's estimated request exceeds the window
- **THEN** exchange 2 stops with the context-overflow message before any provider request is sent

### Requirement: Bounded instruction files
Each applicable `AGENTS.md` SHALL be included up to 32 KiB, and at most 8 files are applicable. A file over the bound is included up to the last whole line within it, followed by a line naming the file, its full size and that the rest is readable with `read`.

#### Scenario: Oversized file
- **WHEN** the project root's `AGENTS.md` is 50 KiB
- **THEN** the context holds its lines up to 32 KiB and then `[AGENTS.md truncated at 32 KiB of 50 KiB; read the file for the rest]`

#### Scenario: Deep workspace
- **WHEN** ten directories from the project root to the workspace each hold an `AGENTS.md`
- **THEN** the 8 nearest the workspace are included and a problem names the 2 left out

### Requirement: Context captured once per content
At the start of each exchange the engine SHALL read the applicable `AGENTS.md` files and the skill catalog, store them in the session's conversation under a key derived from their content, unless that content is already stored, and record that key on the exchange. A rewind removes stored context only with the exchange that first stored it. Changing a file mid-exchange does not change that exchange's context.

#### Scenario: Unchanged context
- **WHEN** two exchanges run with no change to any `AGENTS.md` or skill
- **THEN** both exchanges record the same context key and the context is stored once

#### Scenario: File edited between exchanges
- **WHEN** the model edits `AGENTS.md` during exchange 1 and exchange 2 starts
- **THEN** exchange 1 keeps its original context key, exchange 2 records a new key holding the edited text

#### Scenario: Rewind keeps referenced context
- **WHEN** the session is rewound to before exchange 2
- **THEN** exchange 1's context remains readable by its key, and a request rebuilt for exchange 1 holds the same instructions as before

#### Scenario: Rewind past the first use
- **WHEN** exchanges 1 and 2 share one context key and the session is rewound to before exchange 1
- **THEN** that context is gone with both exchanges, and the next exchange stores it again

### Requirement: Instructions built from the captured context
A request's instructions SHALL be the built-in instructions, then the captured `AGENTS.md` files each under a header naming its path relative to the project root, then the skill catalog: one line per skill with its name and description. With identical captured context two requests carry byte-identical instructions.

#### Scenario: Cache-stable instructions
- **WHEN** three steps of one exchange and the first step of the next exchange are built with the same context key
- **THEN** all four requests carry byte-identical instructions

#### Scenario: Catalog over its bound
- **WHEN** 80 skills are installed
- **THEN** the catalog lists the first 64 by name with descriptions and the other 16 by name only, under a line saying their descriptions were left out
