## Test map

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| workspace-context: Project root and applicable AGENTS.md files | Workspace below the project root | test/workspace/agents_md_test.dart | applicable AGENTS.md files run from the project root to the workspace | red |
| workspace-context: Project root and applicable AGENTS.md files | No repository and no file | test/workspace/agents_md_test.dart | without .git or .jj the workspace is the root and nothing applies | red |
| workspace-context: Project root and applicable AGENTS.md files | Unreadable file | test/workspace/agents_md_test.dart | an unreadable or non-UTF-8 AGENTS.md is left out with a problem | red |
| workspace-context: Automatic reads stay inside the project | File inside the project | test/workspace/containment_test.dart | a regular file inside the root is read | red |
| workspace-context: Automatic reads stay inside the project | Link to a file outside the project | test/workspace/containment_test.dart | a link or junction outside the root is not read and records outside the project root | red |
| workspace-context: Automatic reads stay inside the project | Link to credentials | test/workspace/containment_test.dart | a link to a Kehai credential file is refused as credential file | red |
| workspace-context: Budget follows the instructions | Same instructions | test/loop/request_builder_test.dart | baseline is reused when the instructions identity matches | red |
| workspace-context: Budget follows the instructions | Larger instructions push over the window | test/loop/context_test.dart | grown AGENTS.md stops the next exchange on overflow before sending | red |
| workspace-context: Bounded instruction files | Oversized file | test/workspace/agents_md_test.dart | a 50 KiB AGENTS.md is cut at a line within 32 KiB with the note | red |
| workspace-context: Bounded instruction files | Deep workspace | test/workspace/agents_md_test.dart | only the 8 files nearest the workspace apply and the rest are named | red |
| workspace-context: Context captured once per content | Unchanged context | test/loop/context_test.dart | two exchanges with unchanged files share one stored context | red |
| workspace-context: Context captured once per content | File edited between exchanges | test/loop/context_test.dart | an edit during exchange 1 gives exchange 2 a new key and keeps exchange 1's | red |
| workspace-context: Context captured once per content | Rewind keeps referenced context | test/loop/context_test.dart | rewind before exchange 2 keeps exchange 1's context and instructions | red |
| workspace-context: Context captured once per content | Rewind past the first use | test/loop/context_test.dart | rewind before the first use removes the context and the next exchange stores it again | red |
| workspace-context: Instructions built from the captured context | Cache-stable instructions | test/loop/context_test.dart | requests with one context key carry byte-identical instructions | red |
| workspace-context: Instructions built from the captured context | Catalog over its bound | test/workspace/context_text_test.dart | 80 skills list 64 with descriptions and 16 by name | red |
| skills: Skill discovery | Installed skills found | test/workspace/skills_test.dart | a valid SKILL.md becomes a skill with its directory as base | red |
| skills: Skill discovery | Invalid frontmatter | test/workspace/skills_test.dart | missing frontmatter, mismatched name or empty description is a problem | red |
| skills: Skill discovery | Directory without SKILL.md | test/workspace/skills_test.dart | files and folders without SKILL.md are skipped silently | red |
| skills: Skill precedence | Same skill in both roots | test/workspace/skills_test.dart | the .claude copy wins and the .agents copy is shadowed | red |
| skills: Skill precedence | Model invocation disabled | test/tools/skill_tool_test.dart | disable-model-invocation refuses the model's load | red |
| skills: Skill tool | Skill loaded with arguments | test/tools/skill_tool_test.dart | skill result has the base directory line, body and ARGUMENTS line | red |
| skills: Skill tool | Command loaded by the model | test/tools/skill_tool_test.dart | skill resolves opsx:propose as a command | red |
| skills: Skill tool | Unknown name | test/tools/skill_tool_test.dart | an unknown name lists up to five close names | red |
| skills: Path and argument substitution | Skill directory substituted | test/workspace/substitution_test.dart | CLAUDE_SKILL_DIR becomes the forward-slash base and shell variables stay | red |
| skills: Path and argument substitution | Empty arguments | test/workspace/substitution_test.dart | $ARGUMENTS with no args becomes empty and no ARGUMENTS line is added | red |
| skills: Skills delivered whole | Large skill loaded whole | test/tools/skill_tool_test.dart | a 55 KiB skill is delivered with no truncation line | red |
| skills: Skills delivered whole | Over the file bound | test/tools/skill_tool_test.dart | a 300 KiB SKILL.md is refused with the read hint | red |
| skills: Skills delivered whole | Over the context capacity | test/tools/skill_tool_test.dart | a skill over the remaining capacity settles error uncut | red |
| skills: Skills delivered whole | Whole skill plus parallel results over a known window | test/loop/context_test.dart | parallel results after a whole skill stop the next step before sending | red |
| skills: Skills delivered whole | Unknown window | test/tools/skill_tool_test.dart | with an unknown window a skill is delivered whole and the request is sent | red |
| skills: Skills delivered whole | Skill directory outside the project | test/workspace/containment_test.dart | a junctioned skill folder outside the root is not a skill | red |
| skills: Inventory in doctor | Healthy workspace | test/qualification/installed_workflow_test.dart | doctor lists every installed command, skill and role with only shadowed problems | red |
| skills: Inventory in doctor | Broken skill reported | test/cli/doctor_inventory_test.dart | a broken SKILL.md is listed under problems and doctor's exit code is unchanged | red |
| slash-commands: Command definitions | Namespaced command | test/workspace/commands_test.dart | opsx/propose.md is the command opsx:propose without its frontmatter | red |
| slash-commands: Command definitions | Broken frontmatter | test/workspace/commands_test.dart | an unclosed frontmatter is not a command and is a problem | red |
| slash-commands: Skills as commands | User-invocable skill | test/loop/commands_test.dart | /specwright-roadmap next expands to the skill load text | red |
| slash-commands: Skills as commands | Skill not user-invocable | test/loop/commands_test.dart | user-invocable false refuses the submit with nothing admitted | red |
| slash-commands: Expansion at submit | Command expanded | test/loop/commands_test.dart | /opsx:propose add-dark-mode becomes the body plus ARGUMENTS | red |
| slash-commands: Expansion at submit | Unknown command | test/rpc/server_test.dart | an unknown /command is refused with the // hint and no exchange | red |
| slash-commands: Expansion at submit | Escaped slash | test/loop/commands_test.dart | a leading // sends the text with one slash removed | red |
| slash-commands: Command recorded on the exchange | Recorded expansion | test/loop/commands_test.dart | the exchange records command name, args, source and digest | red |
| slash-commands: Command recorded on the exchange | Definition changed before a duplicate | test/loop/commands_test.dart | a duplicate submit after the file changed reports the first expansion | red |
| slash-commands: Repository commands carry no permission | allowed-tools ignored for approval | test/permissions/repository_frontmatter_test.dart | allowed-tools does not autoapprove a bash call | red |
| subagents: Agent roles | Installed roles | test/workspace/roles_test.dart | a role file gives name, model, tools and body | red |
| subagents: Agent roles | Invalid role file | test/workspace/roles_test.dart | a role without description is a problem | red |
| subagents: Role tools narrowed and mapped | Reviewer tools | test/workspace/roles_test.dart | reviewer tools map to the ten Kehai tools | red |
| subagents: Role tools narrowed and mapped | Unknown tool name | test/workspace/roles_test.dart | WebFetch is ignored and recorded as unmapped | red |
| subagents: Role tools narrowed and mapped | Out-of-roster call in the child | test/rpc/child_mode_test.dart | a reviewer child's edit call fails as unknown tool | red |
| subagents: Role model selection | Inherited model | test/jobs/agent_job_test.dart | inherit runs the child on the parent's model | red |
| subagents: Role model selection | Configured alias | test/jobs/agent_job_test.dart | a configured alias picks its slug | red |
| subagents: Role model selection | Unmapped alias | test/jobs/agent_job_test.dart | an unmapped alias uses the parent's model with a note | red |
| subagents: Agent tool | Foreground agent | test/jobs/agent_job_test.dart | a foreground agent call settles with the typed result | red |
| subagents: Agent tool | Background agent | test/jobs/agent_job_test.dart | a background agent returns its id and job wait returns the result | red |
| subagents: Agent tool | Unknown role | test/tools/agent_tool_test.dart | an unknown role fails listing the roles and starts nothing | red |
| subagents: Child engine | Child session linked | test/rpc/child_mode_test.dart | the child session lives under the parent and records its lineage | red |
| subagents: Child engine | Role file changed after the child ran | test/rpc/child_mode_test.dart | a rebuilt child request carries the role text captured at start | red |
| subagents: Child engine | Child cannot start | test/jobs/agent_job_test.dart | a child fatal before its exchange fails the job with that message | red |
| subagents: Parent follows the child's state | Large committed response | test/jobs/agent_run_test.dart | a 3 MiB committed response reaches the typed result | red |
| subagents: Parent follows the child's state | Terminal update dropped by resync | test/jobs/agent_run_test.dart | an end seen only in a resync snapshot ends the job | red |
| subagents: Parent follows the child's state | Malformed child output | test/jobs/agent_run_test.dart | a non-JSON line fails the job with child protocol error | red |
| subagents: Typed agent result | Done | test/jobs/agent_run_test.dart | a done child gives the header line and its final text | red |
| subagents: Typed agent result | Child exchange failed | test/jobs/agent_run_test.dart | a child stopped on overflow gives status failed with its reason | red |
| subagents: Child prompts relayed | Permission relayed | test/rpc/relay_test.dart | a child permission prompt reaches the client with its agent and allow runs it | red |
| subagents: Child prompts relayed | Prompt withdrawn on cancel | test/rpc/relay_test.dart | interrupting a foreground child withdraws its prompt | red |
| subagents: Child prompts relayed | Background child's prompt survives an unrelated interrupt | test/rpc/relay_test.dart | a background child's prompt stays answerable across an interrupt | red |
| subagents: Bounded agent jobs | Fifth agent refused | test/jobs/agent_job_test.dart | a fifth live agent is refused until one ends | red |
| subagents: Bounded agent jobs | Shared job bound | test/jobs/agent_job_test.dart | agents count toward the sixteen-job bound | red |
| subagents: Agent cancellation and deadline | Interrupt during a child | test/jobs/agent_job_test.dart | interrupt soft-stops the child and records cancelled | red |
| subagents: Agent cancellation and deadline | Deadline | test/jobs/agent_job_test.dart | a child past its deadline ends with status timeout and its text so far | red |
| subagents: Agent jobs on resume | Crash after the handoff intent | test/jobs/agent_resume_test.dart | resume after the intent settles the job with a resolvable result | red |
| subagents: Agent jobs on resume | Crash before the handoff intent | test/jobs/agent_resume_test.dart | resume before the intent cancels the job with the interrupted text | red |
| subagents: Agent jobs on resume | Typed result written but no intent | test/jobs/agent_resume_test.dart | an uncommitted result spool is discarded and counted | red |
| subagents: Agent jobs on resume | Engine crashed during a child | test/jobs/agent_resume_test.dart | a running agent job is finalized interrupted and never relaunched | red |
| subagents: Child progress shown | Progress lines | test/client/render_test.dart | agent stream events print as indented role lines | red |
| subagents: Child progress shown | Slow client | test/rpc/pump_test.dart | agent stream events are droppable like other stream events | red |
| tool-calls: Fixed versioned tool roster | Roster exposed as tool specs | test/tools/runtime_test.dart | specs list the thirteen tools with versioned names and JSON schemas | red |
| tool-calls: Fixed versioned tool roster | Unknown tool | test/tools/runtime_test.dart | unknown tool settles failed with envelope error and a stored result | green |
| tool-calls: Fixed versioned tool roster | Child roster | test/rpc/child_mode_test.dart | a child without role tools offers twelve tools and refuses agent | red |
| job-supervisor: One job node shape | Shell job recorded | test/jobs/supervisor_test.dart | echo hi job node holds no pid and resolves its outputs | green |
| job-supervisor: One job node shape | Launch failure | test/jobs/supervisor_test.dart | vanished shell fails the job pending to failed and clears its launch record | green |
| job-supervisor: One job node shape | Agent job recorded | test/jobs/agent_job_test.dart | an agent job node records kind, agent fields and a result reference | red |
| job-supervisor: One job node shape | Agent job read with job | test/tools/job_tool_test.dart | job wait and output on an agent job return the typed result | red |
| agent-loop: Requests rebuilt from the tree | Tool output is the composed envelope | test/loop/request_builder_test.dart | tool output is the stored model text byte for byte | green |
| agent-loop: Requests rebuilt from the tree | Resumed session | test/loop/request_builder_test.dart | resumed session request holds earlier items and cancelled calls' | green |
| agent-loop: Requests rebuilt from the tree | Instructions from the exchange's context | test/loop/context_test.dart | a step uses the context captured at its exchange start | red |
| agent-loop: Requests rebuilt from the tree | Session from before this change | test/loop/context_test.dart | a pre-change session captures context for its next exchange | red |
| engine-rpc: Prompts reach the client | Permission prompt | test/rpc/server_test.dart | non-autoapproved bash sends a permission prompt and allow runs it | green |
| engine-rpc: Prompts reach the client | Prompt withdrawn by interrupt | test/rpc/server_test.dart | interrupt withdraws the open question and a late answer is refused | green |
| engine-rpc: Prompts reach the client | Relayed child prompt | test/rpc/relay_test.dart | a relayed prompt names its agent with a session-unique key | red |
| engine-rpc: Child engine mode | Child started | test/rpc/child_mode_test.dart | child mode hello names protocol 1, the child session and model | red |
| engine-rpc: Child engine mode | Unknown role in child mode | test/rpc/child_mode_test.dart | child mode with an unknown role is fatal and creates no session | red |
| tool-permissions: User configuration file | Missing configuration | test/config/config_test.dart | missing config.json uses defaults | red |
| tool-permissions: User configuration file | Invalid configuration | test/config/config_test.dart | unknown key or bad type refuses to start naming the path | green |
| tool-permissions: User configuration file | Model settings | test/config/config_test.dart | model and models contextWindow parse | green |
| tool-permissions: User configuration file | Invalid model settings | test/config/config_test.dart | bad contextWindow or unknown model key refuses naming the path | green |
| tool-permissions: User configuration file | Agent model aliases | test/config/config_test.dart | agents.models aliases parse | red |
| tool-permissions: User configuration file | Invalid agent settings | test/config/config_test.dart | bad agents settings refuse naming the path | red |
| tool-permissions: Repository content never widens approval | Role lists Bash | test/permissions/repository_frontmatter_test.dart | a child's bash call is prompted like the parent's | red |
| tool-permissions: Repository content never widens approval | Yolo not inherited from repository | test/permissions/repository_frontmatter_test.dart | a child of a non-yolo parent is not yolo whatever the role says | red |

Child-process tests (`test/rpc/child_mode_test.dart`, `test/rpc/relay_test.dart`, `test/jobs/agent_job_test.dart`, `test/qualification/`) run the real `kehai` through `engineCommand` against the loopback fake provider (`test/support/fake_openai.dart`). Locally run only single test files with `-j 1`; the full suite runs on GitHub Actions (Linux and Windows).

## 1. ADR and architecture index

- [x] 1.1 Write `docs/adr/0012-workspace-context-skills-commands-and-subagents.md` (`Status: accepted`, today's date, `Supersedes: none`). Per design D3, D4, D7, D8, D9, D11 and D15 it records: context keyed by content under `body/contexts` and the exchange `context` field; `.claude` over `.agents` precedence; command expansion at submit with the exchange `command` field; subagents as child engines over RPC v1 (`rpc --child`, lineage `{parent, job}`, role digest, prompt relay, the `result` stream and its handoff); resolved-path containment of automatic reads; repository frontmatter never widens approval. Add its row to the in-force index in `openspec/architecture.md`. Verify with `mise run openspec:validate` and that the index lists 0012.

## 2. Workspace loaders

- [x] 2.1 Add `package:yaml` to `pubspec.yaml` (`dart pub add yaml` through mise) and write `lib/src/workspace/frontmatter.dart` (D2) and `project_root.dart`. Verify `mise run analyze` is clean.
- [x] 2.2 Write the failing containment tests, then `lib/src/workspace/` read containment (D15) reusing `realPath`, `isInside` and `isCredentialTarget`; on Windows the junction cases create junctions with `mklink /J`, on POSIX symlinks. Turns green: *File inside the project*, *Link to a file outside the project*, *Link to credentials*, *Skill directory outside the project*.
- [x] 2.3 Write the failing tests, then `agents_md.dart` (root-first chain, 32 KiB/8-file bounds, problems). Turns green: *Workspace below the project root*, *No repository and no file*, *Unreadable file*, *Oversized file*, *Deep workspace*.
- [x] 2.4 Write the failing tests, then `skills.dart` (discovery, validation, precedence, shadowed problems) and `substitution.dart`. Turns green: *Installed skills found*, *Invalid frontmatter*, *Directory without SKILL.md*, *Same skill in both roots*, *Skill directory substituted*, *Empty arguments*.
- [x] 2.5 Write the failing tests, then `commands.dart` (namespaced names, frontmatter removal, skills as commands with `user-invocable`) and `roles.dart` (role parsing, tool mapping, unmapped names). Turns green: *Namespaced command*, *Broken frontmatter*, *Installed roles*, *Invalid role file*, *Reviewer tools*, *Unknown tool name*.
- [x] 2.6 Write `inventory.dart` (one `Workspace` value with root, files, skills, commands, roles and problems) and `context_text.dart` (D5 rendering, 64-skill catalog bound). Turns green: *Catalog over its bound*. Verify the group with `dart test test/workspace -j 1` and `mise run analyze`.

## 3. Context capture, instructions and budget

- [ ] 3.1 Write the failing tests in `test/loop/context_test.dart`, then capture at exchange start in `driver.dart` (D4: `body/contexts/<key>` once per content, exchange `context`), and build instructions in `request_builder.dart` from the exchange's context (D5). Bump `instructionsVersion` to `kehai-2` and extend `builtInInstructions` with the skills, agents, tool-name mapping and authority text of D5. Turns green: *Unchanged context*, *File edited between exchanges*, *Rewind keeps referenced context*, *Rewind past the first use*, *Cache-stable instructions*, *Instructions from the exchange's context*, *Session from before this change*.
- [ ] 3.2 Write the failing tests, then record `instructions: {version, context, role}` on each step and use a baseline only when it matches (D16). Turns green: *Same instructions*, *Larger instructions push over the window*. Re-run the unchanged *Tool output is the composed envelope* and *Resumed session* tests (green rows) to confirm they still pass.

## 4. Skill tool and commands

- [ ] 4.1 Write the failing tests, then let `composeResult` accept `notrunc` with a null `capacityTokens` (D6), and add `lib/src/tools/skill.dart` (schema, resolution, size bound, substitution, `notrunc` composition with the calling step's capacity, close-name suggestions, autoapproval through containment). Turns green: *Model invocation disabled*, *Skill loaded with arguments*, *Command loaded by the model*, *Unknown name*, *Large skill loaded whole*, *Over the file bound*, *Over the context capacity*, *Unknown window*, *Whole skill plus parallel results over a known window*.
- [ ] 4.2 Write the failing tests, then expand commands in `Driver.submit` after the known-id check (D7), record `command` on the exchange and refuse unknown or non-user-invocable names before admission; the line client shows the typed command line. Turns green: *User-invocable skill*, *Skill not user-invocable*, *Command expanded*, *Unknown command*, *Escaped slash*, *Recorded expansion*, *Definition changed before a duplicate*.
- [ ] 4.3 Write the failing test, then confirm the gate ignores repository frontmatter. Turns green: *allowed-tools ignored for approval*.

## 5. Configuration and doctor

- [ ] 5.1 Write the failing tests, then parse `agents.models` in `user_config.dart`. Turns green: *Missing configuration* (now also no aliases), *Agent model aliases*, *Invalid agent settings*; re-run the green *Invalid configuration*, *Model settings*, *Invalid model settings* rows.
- [ ] 5.2 Write the failing test, then list the inventory in `kehai doctor` (root, `AGENTS.md` files, skills with root, commands, roles with model and mapped tools, problems; exit code unchanged). Turns green: *Broken skill reported*.

## 6. Child engine and agent jobs

- [ ] 6.1 Write the failing tests, then add `rpc --child` to `rpc_command.dart` (D8: parent dir, job, role, role digest, model, `--yolo`; refuses `--resume`/`--session`; lineage; role captured in the child's context; roster narrowed by D9). Turns green: *Child started*, *Unknown role in child mode*, *Child session linked*, *Role file changed after the child ran*, *Out-of-roster call in the child*, *Child roster*.
- [ ] 6.2 Write the failing tests, then add the supervisor channel and soft stop (D11: stdin kept open, spool-then-channel, 5 s soft stop before termination, per-kind stream set with `result`) and `JobKind.agent`. Re-run the green *Shell job recorded* and *Launch failure* rows.
- [ ] 6.3 Write the failing tests in `test/jobs/agent_run_test.dart`, then `lib/src/jobs/agent_run.dart` (D8: tree mirror replaced on snapshot, end decided from the mirror, 64 MiB line buffer, typed result text). Turns green: *Large committed response*, *Terminal update dropped by resync*, *Malformed child output*, *Done*, *Child exchange failed*.
- [ ] 6.4 Write the failing tests, then `lib/src/tools/agent.dart` and its roster entry (D12 model selection, 4-agent bound inside 16, foreground/background, deadline, `job` wait/output composing `result`). Turns green: *Inherited model*, *Configured alias*, *Unmapped alias*, *Foreground agent*, *Background agent*, *Unknown role*, *Child cannot start*, *Fifth agent refused*, *Shared job bound*, *Interrupt during a child*, *Deadline*, *Agent job recorded*, *Agent job read with job*, *Roster exposed as tool specs*; re-run the green *Unknown tool* row.
- [ ] 6.5 Write the failing tests, then extend recovery (D11: intent streams iterated by name, `result` never adopted before the intent, uncommitted `result` spools deleted and counted as `discarded` in the warning, interrupted text composed from the node). Turns green: *Crash after the handoff intent*, *Crash before the handoff intent*, *Typed result written but no intent*, *Engine crashed during a child*. Verify the group with `dart test test/jobs test/rpc/child_mode_test.dart test/tools -j 1`.

## 7. Prompt relay and progress

- [ ] 7.1 From this group on, first attempt the group inside Kehai (`/opsx:apply skills-agents-commands`, implementer subagent) and record what it could and could not do under **Dogfood record** in `design.md`. Verify the record has an entry for groups 7 and 8.
- [ ] 7.2 Write the failing tests, then relay child prompts through the parent's prompt FIFO (D10: `<job>.<child key>`, `agent` field, withdrawal only with the job's cancellation or end, or the child's withdraw). Turns green: *Permission relayed*, *Prompt withdrawn on cancel*, *Background child's prompt survives an unrelated interrupt*, *Relayed child prompt*, *Role lists Bash*, *Yolo not inherited from repository*; re-run the green *Permission prompt* and *Prompt withdrawn by interrupt* rows.
- [ ] 7.3 Write the failing tests, then emit `stream` kind `agent` per settled child call (D13) and print it indented in the line client, ignoring unknown stream kinds. Turns green: *Progress lines*, *Slow client*.

## 8. Qualification

- [ ] 8.1 Write `test/qualification/installed_workflow_test.dart` over this repository's real `.claude/` and `.agents/` folders: every `/opsx:*` command, every `specwright-*` and `openspec-*` skill and the three roles resolve, substitutions apply, the only problems are shadowed `.agents` copies, and `kehai doctor` lists them. Turns green: *Healthy workspace*.
- [ ] 8.2 Write `test/qualification/workflow_e2e_test.dart` (D14): with the loopback fake provider, `/opsx:apply` expands, the model calls `skill specwright-commit`, then `agent specwright-implementer` (a real child) edits a file after a relayed prompt is answered, then `agent specwright-reviewer` writes a scratch file; both typed results reach the parent. Verify it passes locally with `-j 1` on Windows.
- [ ] 8.3 Live qualification in Kehai on Windows with the ChatGPT login: in a scratch copy of this repository set `review.cross_model: false`, run `review-run.sh select` (route `subagent`) and have Kehai's `specwright-reviewer` role review this change's diff through `review-run.sh record`; record the session ids, the receipt and every gap under **Dogfood record**. The change's configured pre-ship review still runs separately.
- [ ] 8.4 Push the branch and confirm the full suite passes on GitHub Actions (Linux and Windows); record the run in the PR description. Verify with `mise run check` locally (analyze and format only) and the CI conclusion.

## Workflow follow-up

- Pre-ship review, PR and merge follow `specwright-commit`, `specwright-review` and `specwright-pr` (finish: pr).
- After merge, `/specwright-roadmap next` reaches entry 6 (`dogfood-first-m2-change`), which sets `review.cross_model: false` in this repository before it starts.
