# Tasks

## Test map

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| line-client → Permission prompt text | Non-ASCII path | test/client/client_test.dart | a non-ASCII path is shown as itself | green |
| line-client → Permission prompt text | Terminal control in a command | test/client/client_test.dart | a terminal control in a command is shown escaped | green (already escaped; re-run) |
| line-client → Permission prompt text | Text that looks like an escape | test/client/client_test.dart | a backslash that looks like an escape is escaped itself | green (existing; re-run) |
| line-client → Permission prompt text | Multi-line command | test/client/client_test.dart | a newline in a command is shown as its own line | green (existing; re-run) |
| line-client → Permission prompt text | Line feed in a directory or target | test/client/client_test.dart | the directory a command runs in is shown with it; a line feed in the resolved target is written as an escape | green (existing behaviour; re-run) |
| line-client → Permission prompt text | Lone surrogate | test/client/render_test.dart | lone surrogates are escaped | green (already escaped; re-run) |

Extra tests, no scenario row: `invisible, bidi and blank characters are shown as themselves` (client_test, now green) and `a supplementary character is printed as itself` (render_test, now green). They replace the ASCII-only tests `control and bidi characters are shown escaped`, `tag, variation selector and odd space characters are shown escaped` and `every character beyond ASCII is shown escaped`.

## 1. Render the permission prompt with Unicode as itself

- [x] 1.1 In `test/client/client_test.dart` (group `Permission prompt shows exactly what runs`), replace the three ASCII-only tests named above with: `a non-ASCII path is shown as itself` (`write` `кафе.txt` → `permission: write кафе.txt`); `invisible, bidi and blank characters are shown as themselves` (U+E007F, U+FE0F, U+00A0, U+2800, U+202E printed as-is); `a terminal control in a command is shown escaped` (the spec's `echo a` ESC `[2Jb` → `permission: bash echo a\u{1B}[2Jb`, plus CR and U+0085 escaped); `a line feed in the resolved target is written as an escape` (`-> out/a\u{A}b`). In `test/client/render_test.dart` add `lone surrogates are escaped` (U+D800 → `\u{D800}`, U+DC00 → `\u{DC00}`) and `a supplementary character is printed as itself` (U+1F600). Run `mise exec -- dart test -j 1 test/client/render_test.dart test/client/client_test.dart` and verify that exactly the red rows and the two red extra tests fail, each on an escaped non-ASCII character.
- [x] 1.2 In `lib/src/client/render.dart`, make `exactLines` escape only C0, DEL, C1 and lone surrogates (U+D800 to U+DFFF), plus the backslash that starts `\u{`, and update its doc comment and the comment in `client.dart` `_showActive` if it mentions ASCII. Verify that the same command passes in full, and flip the red rows green.

## 2. Integration checks

- [x] 2.1 Run `mise exec -- dart analyze` and `mise exec -- dart format --output=none --set-exit-if-changed lib test`; both exit 0.

## Workflow follow-up

- Pre-ship review, PR, Codex review, archive and agent merge per `openspec/specwright.yaml`.
- Full test suite runs on GitHub Actions (CI-first testing).
