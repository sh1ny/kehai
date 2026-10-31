# Proposal

## Why

Kehai can read, search, edit, run commands and hold a conversation (changes 1-4), but it cannot run the project's own workflow: it does not see `AGENTS.md`, cannot load a skill, cannot expand `/opsx:propose`, and cannot dispatch the implementer and reviewer subagents that Specwright's apply and review steps need. The change 4 dogfood record lists exactly these as the reason every task group fell back to Claude Code.

This is entry 5 of milestone **M1 — self-hosting skeleton**. It serves the exit criterion *Load `.claude/skills/` and `.agents/skills/`, inject `AGENTS.md`, and call installed `/opsx:*` and `specwright-*` commands* (agent-verified), and it is the last prerequisite of *Complete branch → proposal → … → merge with Kehai as sole agent* (user-verified, entry 6). Without it entry 6 cannot start.

## What Changes

- **Workspace context.** At each exchange the engine reads the applicable `AGENTS.md` files (workspace directory up to the project root) and the skill catalog, captures them in the tree once per distinct content, and sends them in the request instructions after the built-in text. The instructions stay byte-identical while the context is unchanged, so the prompt cache holds.
- **Skills.** `SKILL.md` files under the project's `.claude/skills/` and `.agents/skills/` are discovered and listed to the model by name and description. A new `skill` tool loads one: base directory line, body with `${CLAUDE_SKILL_DIR}` substituted, and the arguments, composed whole (no truncation cut) within the context capacity. Same-name skills resolve to the `.claude/skills/` copy.
- **Commands.** A prompt starting with `/name args` is expanded by the engine at submit: `.claude/commands/**/*.md` definitions (`/opsx:propose` from `opsx/propose.md`) and user-invocable skills (`/specwright-roadmap next`). `$ARGUMENTS` is substituted, or the arguments are appended. The expansion and its source are recorded on the exchange; an unknown command is refused before admission. The model reaches the same definitions through the `skill` tool, so a skill that says "start `/opsx:propose`" works.
- **Subagents.** A new `agent` tool runs a role from `.claude/agents/*.md` (`specwright-implementer`, `specwright-implementer-light`, `specwright-reviewer`) as a unified job: a child `kehai` engine process with its own session linked to the parent job, the role body added to its instructions, its tools narrowed to the role's `tools` list, and its model from the role (`inherit`) or a user-configured alias. It returns a typed result (status, role, model, child session, steps, final text). Child permission prompts and questions are relayed to the user through the parent; interrupt, deadline, rewind and resume follow the job lifecycle.
- **Tool names from other harnesses.** The built-in instructions map Claude Code tool names used by installed skills (`Read`, `Bash`, `Skill`, `Agent`, `AskUserQuestion`, …) to Kehai tools.
- **Policy stays with the user.** Frontmatter such as `allowed-tools` or a role's `tools` can only narrow what a child may call; repository content never autoapproves anything.
- **Inventory.** `kehai doctor` lists the discovered skills, commands and roles, with shadowed duplicates, unmapped tool names and load errors.
- **Qualification.** The installed Specwright workflow is qualified: every installed `/opsx:*` command, `specwright-*` skill and agent role resolves, an end-to-end test drives command → skill → implementer and reviewer subagents, and the apply of this change is attempted inside Kehai with its gaps recorded.

## Capabilities

### New Capabilities
- `workspace-context`: discovery of applicable `AGENTS.md` files and the skill catalog, their capture in the tree and their place in request instructions.
- `skills`: skill discovery, precedence, the `skill` tool, path and argument substitution, size bounds and the doctor inventory.
- `slash-commands`: command definitions, user-invocable skills as commands, expansion at submit and its record on the exchange.
- `subagents`: agent roles, the `agent` tool, the child engine job, tool narrowing, model mapping, prompt relay, the typed result and the child's lifecycle.

### Modified Capabilities
- `tool-calls`: the roster grows to 13 tools (`skill`, `agent`); a child engine offers its role's subset.
- `job-supervisor`: a third job kind `agent`, with its fields in the job node.
- `agent-loop`: request instructions are the built-in text followed by the exchange's captured workspace context.
- `engine-rpc`: submit expands commands and refuses unknown ones; prompts relayed from a child name their agent; a child engine mode.
- `tool-permissions`: an `agents` key in the user configuration; repository frontmatter never widens approval.

## Impact

- **Code:** new `lib/src/workspace/` (context, skills, commands, roles loaders), `lib/src/tools/skill.dart`, `lib/src/tools/agent.dart`, child engine entry in `lib/src/cli/`, changes to `loop/request_builder.dart`, `loop/instructions.dart`, `loop/driver.dart` (submit expansion), `jobs/supervisor.dart` (agent kind), `tools/roster.dart`, `rpc/` (relay, child mode), `config/user_config.dart`, `cli/doctor.dart`, `client/` (child call lines).
- **Dependencies:** `package:yaml` (dart-lang) for frontmatter.
- **Tree layout:** new `body/contexts/<key>`, exchange `context` and `command` fields, job `agent` fields. Additive; existing journals replay unchanged.
- **Workflow:** after this change, entry 6 can run the full Specwright lifecycle in Kehai once `review.cross_model` is set to false there.
