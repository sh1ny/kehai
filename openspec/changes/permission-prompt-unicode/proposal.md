# Proposal

## Why

The line client's permission prompt prints only printable ASCII. Every other character is written as `\u{XXXX}`, so a Cyrillic or accented path such as `кафе.txt` reads as `\u{43A}\u{430}\u{444}\u{435}.txt`. The rule came from PR #14's Codex security rounds, which hardened the prompt against invisible and lookalike characters. For anyone who names files in a language other than English, the prompt becomes unreadable. On 2026-10-31 the user chose oh-my-pi's level instead: neutralise terminal controls and show every other character as itself. This change follows up `agent-loop-and-line-client` in M1 (self-hosting skeleton), so the client M1 dogfoods is usable with non-English names.

## What Changes

- The permission prompt's command or path, the `in <cwd>` line and the `-> <target>` line escape only control characters (C0 including tab and carriage return, DEL, C1) and lone surrogates (U+D800 to U+DFFF) as `\u{XXXX}`. A line feed in the command or path still starts a new `  | ` line; in the directory or target it is still written as `\u{A}`.
- Every other character prints as itself, including invisible, blank-looking and lookalike characters. **BREAKING** for the prompt's display only: the ASCII-only escaping is removed.
- A backslash that starts `\u{` is still written as `\u{5C}`, so an escape in the prompt always stands for exactly one character.
- The prompt is still shown whole, never cut.
- A line-client requirement records this rendering, so later reviews have a stated rule to check against.

## Capabilities

### New Capabilities

### Modified Capabilities
- `line-client`: a new requirement, *Permission prompt text*, defines how a permission prompt shows the tool's command or path, its working directory and its resolved target.

## Impact

- `lib/src/client/render.dart`: `exactLines` escapes control characters only.
- `test/client/render_test.dart`, `test/client/client_test.dart`: the ASCII-only expectations (tag characters, variation selector, NBSP, U+2800, Cyrillic) change to show Unicode as itself; control-character, `\u{` and directory line-feed cases stay. New tests cover a line feed in the target, lone high and low surrogates, and a valid supplementary character printed as itself.
- No protocol, engine or permission-gate change. The target binding and the refusal of unresolvable paths from PR #14 are unchanged.
