# Tasks

## Test map

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| line-client → Permission prompt body | Short write | test/client/client_test.dart | a write prompt shows the content | red |
| line-client → Permission prompt body | Empty write | test/client/render_test.dart | an empty write shows no lines | green |
| line-client → Permission prompt body | Carriage return in written content | test/client/render_test.dart | a carriage return in written content stays on its line | green |
| line-client → Permission prompt body | Edit operations | test/client/render_test.dart | edit operations show their ranges and text | green |
| line-client → Permission prompt body | Edit text with a trailing line feed | test/client/render_test.dart | edit text keeps the empty line after a trailing line feed | green |
| line-client → Permission prompt body | Empty edit text | test/client/render_test.dart | empty edit text is one empty line | green |
| line-client → Permission prompt body | Carriage return in edit text | test/client/render_test.dart | a carriage return splits edit text | green |
| line-client → Permission prompt preview | Long write is previewed | test/client/client_test.dart | a long write is previewed in 20 lines | red |
| line-client → Permission prompt preview | Show the whole body | test/client/client_test.dart | v shows the whole body and answers nothing | red |
| line-client → Permission prompt preview | v where nothing was left out | test/client/client_test.dart | v is refused when nothing was left out | red |

## 1. Body lines of write and edit prompts

- [x] 1.1 In `test/client/render_test.dart`, add a `promptBody` group with the render tests in the test map. Also add `a write shows its size and its lines` (the short-write lines, `1 line` singular for one line), and `an unknown tool has no body`. Run `mise exec -- dart test -j 1 test/client/render_test.dart` and verify the new tests fail because `promptBody` does not exist yet.
- [x] 1.2 In `lib/src/client/render.dart`, add `promptBody(tool, input)`. It is a lazy sequence of body lines (a lead, plus optional text escaped when rendered) and comes with `renderBodyLine`.
  - For `write`: a content line with the display-line count (split at line feeds, a final one ending the last line) and the UTF-8 byte length computed without encoding, then one `  | ` line per content line.
  - For `edit`: a header per op (`replace lines a-b:`, `insert after line n:`, `delete lines a-b`, `?` for a number not given), then its text split at CRLF, CR and LF, keeping empty pieces.

  Lines are produced on demand, so counting does not escape them. Verify the group-1 tests pass and flip their rows green.

## 2. Preview and `v` in the line client

- [ ] 2.1 In `test/client/client_test.dart`, add a `Permission prompt body` group with the client tests in the test map:
  - The short write shows the content line and both lines before `1) allow  2) deny`.
  - A 50-line write shows the content line, 19 lines and `  … 31 more lines; v shows all`, and refuses other text with `answer 1 (allow), 2 (deny) or v (show all)`.
  - `v` and `view` print all 50 lines, then the choice line and `answer> `, and send no `answer`.
  - `v` at a short prompt gets `answer 1 (allow) or 2 (deny)` and sends nothing.

  Run `mise exec -- dart test -j 1 test/client/client_test.dart` and verify these fail on the missing body lines.
- [ ] 2.2 In `lib/src/client/client.dart`, have `_showActive` print up to 20 body lines after the target line and count the rest, recording the key of a cut prompt. Have `_answer` handle `v` and `view` for that key before the in-flight check: print the whole body one line at a time, then the choice line and `answer> `. Its refusal names `v` only for a cut prompt. Verify that `mise exec -- dart test -j 1 test/client/client_test.dart test/client/render_test.dart` passes in full, and flip the rows green.

## 3. Integration checks

- [ ] 3.1 Run `mise exec -- dart analyze` and `mise exec -- dart format --output=none --set-exit-if-changed lib test`; both exit 0.

## Workflow follow-up

- File a follow-up issue for engine-side old text in `edit` prompts (design D2).
- Pre-ship review, PR, Codex review, archive and agent merge per `openspec/specwright.yaml`. Full test suite on CI.
