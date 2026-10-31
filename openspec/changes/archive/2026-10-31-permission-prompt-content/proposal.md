# Proposal

## Why

A permission prompt for `write` or `edit` shows only the path (#16). The user approves a file write without seeing what will be written: a write's content, or an edit's operations and new text. A prompt-injected model can write a harmless-looking path with harmful content, such as a script a later allowed command runs, and the prompt gives the user nothing to judge it by. Every `write` and `edit` asks for permission (tool-permissions *Ask otherwise, or explicit yolo*), so this is on the path of almost every change kehai makes. It is a follow-up to `agent-loop-and-line-client` in M1 (self-hosting skeleton), done before `skills-agents-commands` so the client M1 dogfoods shows what it asks to approve.

## What Changes

- A `write` prompt shows the content's size, then its lines.
- An `edit` prompt shows each operation as given (`replace lines 12-14`, `insert after line 3`, `delete lines 5-7`), each followed by its new text.
- The shown lines are escaped as the prompt's other text is (line-client *Permission prompt text*).
- At most 20 body lines are shown, then `… N more lines; v shows all`. Typing `v` (or `view`) at that prompt prints the whole body and asks again. It answers nothing.
- The old text an edit replaces or deletes is not shown, since the client does not read files. That needs the engine and is left to a follow-up issue.
- The roadmap lists this change and `permission-prompt-unicode` as follow-ups to entry 4.

## Capabilities

### New Capabilities

### Modified Capabilities
- `line-client`: a new requirement, *Permission prompt body*, defines what a `write` or `edit` prompt shows beyond the path, the 20-line preview and `v`.

## Impact

- `lib/src/client/client.dart` (`_showActive`, `_answer`) and `lib/src/client/render.dart` (the body lines).
- `test/client/client_test.dart`, and `test/client/render_test.dart` for the body rendering.
- `openspec/roadmap.md`: the follow-up entries under entry 4.
- No engine, protocol or permission-gate change. The prompt event already carries the call's whole input.

Fixes #16.
