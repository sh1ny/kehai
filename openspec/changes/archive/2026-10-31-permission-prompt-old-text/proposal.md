# Proposal

## Why

An `edit` permission prompt shows each operation's line range and its new text, but not the lines it replaces or deletes (#21). The user approves `replace lines 3-4` without seeing what lines 3 and 4 hold, so a harmful edit can pass as a harmless one: deleting a check, or replacing a line the user would never agree to lose. The line client holds no files, so the engine has to send those lines. This is the last prompt follow-up to `agent-loop-and-line-client` in M1 (self-hosting skeleton), done before `skills-agents-commands`.

The preview also says `  … 1 more lines; v shows all` when one line is left out.

## What Changes

- When the gate opens an `edit` prompt, it reads the file the edit acts on and adds `old` to the prompt input: for each operation, the lines a `replace` or `delete` removes, as the file holds them now.
- Allowing the prompt binds the edit to that file. The permission record carries the SHA-256 of the bytes read, and `edit` refuses with `the file changed after it was approved; ask again` when the file differs at mutation time.
- The client shows removed lines as `  - ` and new text as `  + ` under each operation. Write content keeps `  | `.
- The preview says `  … 1 more line; v shows all` for one line.
- The roadmap lists this change with the other follow-ups to entry 4.

## Capabilities

### New Capabilities

### Modified Capabilities
- `tool-permissions`: two new requirements. *Edit prompts show the lines they remove*: the gate sends the old lines. *Edit approval is bound to the file shown*: `edit` refuses a file that changed after it was approved.
- `line-client`: *Permission prompt body* shows an edit's old lines as `  - ` and its new text as `  + `. *Permission prompt preview* says `1 more line` for one.

## Impact

- `lib/src/permissions/gate.dart` (reading the file and the record), `lib/src/tools/edit.dart` (refusing a changed file), `lib/src/client/render.dart` and `lib/src/client/client.dart` (showing the lines and the wording).
- Tests in `test/permissions/`, `test/tools/` and `test/client/`.
- Protocol: an `edit` prompt's input gains an optional `old` field. A client that ignores it shows what it shows now. No command or event is added.
- `openspec/roadmap.md`: this change joins the follow-ups under entry 4.

Fixes #21.
