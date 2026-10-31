# Tasks

## Test map

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| tool-permissions → Edit prompts show the lines they remove | Replace and delete show the old lines | test/permissions/gate_test.dart | an edit prompt carries the lines it removes | red |
| tool-permissions → Edit prompts show the lines they remove | Line numbers past the end | test/permissions/gate_test.dart | an operation past the end has no old lines | red |
| tool-permissions → Edit prompts show the lines they remove | Overlapping operations | test/permissions/gate_test.dart | overlapping operations send no old lines | red |
| tool-permissions → Edit prompts show the lines they remove | File not readable as text | test/permissions/gate_test.dart | a file edit cannot read sends no old lines | red |
| tool-permissions → Edit approval is bound to the file shown | File changed after approval | test/tools/edit_tool_test.dart | an edit of a file changed after approval is refused | red |
| tool-permissions → Edit approval is bound to the file shown | Unchanged file | test/permissions/gate_test.dart | an allowed edit records the hash of the file shown | red |
| line-client → Permission prompt body | Short write | test/client/client_test.dart | a write prompt shows the content | green |
| line-client → Permission prompt body | Empty write | test/client/render_test.dart | an empty write shows no lines | green |
| line-client → Permission prompt body | Carriage return in written content | test/client/render_test.dart | a carriage return in written content stays on its line | green |
| line-client → Permission prompt body | Edit operations | test/client/render_test.dart | edit operations show their ranges and text | red |
| line-client → Permission prompt body | Edit without old lines | test/client/render_test.dart | an edit without old lines shows only its text | red |
| line-client → Permission prompt body | Edit text with a trailing line feed | test/client/render_test.dart | edit text keeps the empty line after a trailing line feed | red |
| line-client → Permission prompt body | Empty edit text | test/client/render_test.dart | empty edit text is one empty line | red |
| line-client → Permission prompt body | Carriage return in edit text | test/client/render_test.dart | a carriage return splits edit text | red |
| line-client → Permission prompt body | Control character in an old line | test/client/render_test.dart | old lines are escaped | red |
| line-client → Permission prompt preview | Long write is previewed | test/client/client_test.dart | a long write is previewed in 20 lines | green |
| line-client → Permission prompt preview | One line left out | test/client/client_test.dart | one line left out is named in the singular | red |
| line-client → Permission prompt preview | Show the whole body | test/client/client_test.dart | v shows the whole body and answers nothing | green |
| line-client → Permission prompt preview | v where nothing was left out | test/client/client_test.dart | v is refused when nothing was left out | green |

Rows marked green are existing tests for scenarios this change leaves as they were.

## 1. Old lines and the approval binding in the engine

- [ ] 1.1 In `test/permissions/gate_test.dart`, add an `edit prompts` group with the gate tests in the test map. The unreadable case covers a missing file, invalid UTF-8 and a file over `maxEditBytes`. Also add `CRLF and CR lines are split as edit splits them` and `a byte order mark is not part of the first old line`, and in `test/tools/edit_tool_test.dart` add the test from the test map plus `an edit with the approved hash applies`. Run `mise exec -- dart test -j 1 test/permissions/gate_test.dart test/tools/edit_tool_test.dart` and verify that the new tests fail on the missing `old`, `sha256` and refusal.
- [ ] 1.2 In `lib/src/tools/edit.dart`, expose the line splitting `edit` uses as one shared function. It returns the lines of file bytes as strings, or null when they are not valid UTF-8, and `_Lines` stays the one implementation. Add the `fileChangedRefusal` text, and refuse with status `denied` when the permission record's `sha256` differs from the hash of the bytes read, before planning. In `lib/src/permissions/gate.dart`, have `_ask` read the target of an `edit` (a file up to `maxEditBytes`), add `old` per design D1 (no `old` for overlapping `replace`/`delete` ranges), and add `sha256` to the allow record. Verify that the group-1 tests and the whole of both files pass.

## 2. Old and new lines in the line client

- [ ] 2.1 In `test/client/render_test.dart`, change the edit tests to the `  + ` text lines and `old` inputs of the test map, and add `an edit without old lines shows only its text`, `old lines are escaped`, and `an old entry that is not a list of strings shows no old lines`. In `test/client/client_test.dart`, add `one line left out is named in the singular`. Run `mise exec -- dart test -j 1 test/client/render_test.dart test/client/client_test.dart` and verify that the changed and new tests fail.
- [ ] 2.2 In `lib/src/client/render.dart`, show each edit operation's `old` lines as `  - ` and its text as `  + ` (design D3), and keep `  | ` for write content. In `lib/src/client/client.dart`, write `1 more line` for one. Verify that both test files pass in full.

## 3. Integration checks

- [ ] 3.1 Run `mise exec -- dart analyze` and `mise exec -- dart format --output=none --set-exit-if-changed lib test`; both exit 0.

## Workflow follow-up

- Pre-ship review, PR, Codex review, archive and agent merge per `openspec/specwright.yaml`. The full test suite runs on CI.
