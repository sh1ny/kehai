# Design

## Triage

| Trigger | Applies? | Evidence |
|---|---|---|
| T1 Components (new component, or 3+ with directed relationships) | No | The line client's prompt display (`lib/src/client/client.dart:549-589`) and answer handling (`client.dart:208-243`) change; a render helper is added to `lib/src/client/render.dart`. |
| T2 State (persistent state, caches, 3+ state machine) | No | No new state: the body is computed from the active prompt's input when shown. The prompt queue (`_prompts`) is unchanged. |
| T3 Concurrency (background work, workers/isolates, async, retries) | No | `v` is handled synchronously at input, like a refused answer. |
| T4 Boundaries (data format, migration, shared interface, IPC, external) | No | The `prompt` event already carries the call's whole input (engine-rpc *Permission prompt*); no protocol change. |
| T5 Volume (grows without a fixed bound) | Yes | Content and edit text grow with the call. Nothing caps a `prompt` event: the 1 MiB `maxLineBytes` (`lib/src/rpc/protocol.dart:11`) limits commands into the engine, not events out of it (ADR 0011), and the write and edit schemas set no length. The preview shows 20 lines unless `v`. |
| T6 Risk (security, money, data loss, unrecoverable user data) | Yes | The prompt is what the user approves a file write from. |

TIER: FULL

## Context

The permission prompt shows the tool and one argument (`argumentText`, `render.dart:24-31`), plus `in <cwd>` and `-> <target>` (`client.dart:566-579`). Text is escaped by `exactLines` (`render.dart:56-75`, line-client *Permission prompt text*). `write` takes `path` and `content`; `edit` takes `path`, `anchors` and `ops`, each op being `replace` (`start`, `end`, `text`), `insert` (`after`, `text`) or `delete` (`start`, `end`) (`lib/src/tools/roster.dart:72-114`). Every `write` and `edit` prompts unless `--yolo` (tool-permissions *Ask otherwise, or explicit yolo*), so the prompt shows on almost every change. Answers are `1`/`y`/`allow` and `2`/`n`/`deny` (`client.dart:22-23`, `208-226`).

oh-my-pi, at `2e23dffe598636817a9bab407cf55e6f9e9a8f82`, shows a write's content cut to 2,000 characters (`packages/coding-agent/src/tools/write.ts:592`, `approval.ts:261`, `647-651`) in a dialog that folds details to 8 rows with a key to expand them (`packages/tui/src/overlays/approval-dialog.ts:131-143`, `render-utils.ts:105`). For other tools it shows the arguments as formatted JSON (`approval.ts:653-711`).

M1 constraints hold: Dart 3.x AOT, no Rust core, no embedded script runtime, and no durable session state outside the tree. Sensorium and truncation are untouched. Nocterm, compaction, LSP, jj checkpoints, the plugin protocol, MCP, Anthropic OAuth, the pricing registry and themes stay deferred to M2+. The line client runs on native Windows without WSL, as now. Kehai apply attempt: applied with Claude Code; Specwright inside Kehai needs entry 5, so the attempt is recorded as unsupported.

## Decisions

### D1: Preview 20 body lines, `v` prints the whole body

- **Choice:** the body (the content line and content lines, or each operation and its text lines) is shown up to 20 lines. If more remain, `  … <m> more lines; v shows all` follows. `v` or `view` at that prompt prints the whole body, then the choice line and `answer> `, and sends nothing. At a prompt with nothing left out, `v` is refused as any other non-answer is. The refusal names `v` only when the body was cut: `answer 1 (allow), 2 (deny) or v (show all)`.
- **Rejected:** always showing the whole body, because most writes are whole files of hundreds of lines, and every write prompts. The choice line would scroll away from what was asked. Also rejected: cutting at a character count as OMP does (2,000), because a line count keeps whole lines and its `more lines` count is exact.
- **Reversal cost:** low. The limit is one constant and `v` is one input case.

### D2: Edit operations as given, no old text

- **Choice:** show each op as the model sent it: `replace lines a-b:`, `insert after line n:` or `delete lines a-b`, followed by its `text` split exactly as `edit` splits it (`lib/src/tools/edit.dart:372-376`): at CRLF, CR and LF, keeping empty pieces. So `x` line feed shows two lines, `x` and an empty one, and empty text shows one empty line, as each inserts. Each piece is then escaped, and holds no line break. This differs from write content (D3) because the two tools write differently. A number the op does not give shows as `?`. The `edit` tool refuses an incomplete op later, before any effect. Anchors are not shown: they guard staleness and change nothing written.
- **Rejected:** a diff with the old lines, because the client holds no files. It would need the engine to read the file and send the old text with the prompt, which changes the prompt contract (engine-rpc) and races later edits. That is left to a follow-up issue. Also rejected: showing the ops as JSON as OMP does, because escaped JSON strings are unreadable for multi-line text.
- **Reversal cost:** low on the client. Adding old text later is additive: a new input field the client shows when present.

### D3: Write content in display lines

- **Choice:** the content is written byte for byte, so it splits at line feeds only; a final line feed ends the last line and adds none. The content line gives that display-line count (`1 line` for one) and the UTF-8 byte length. Each line is escaped with `exactLines`, so a carriage return shows as `\u{D}`. The count can differ from the `write` result's line count, which also counts a lone CR and skips a BOM (`LineSegmenter`). For `a\nb\n` both say 2 lines (`test/tools/write_tool_test.dart:31`), but for `a\rb` the prompt says 1 and the result says 2. The prompt counts what it shows.
- **Rejected:** splitting at `\r\n`, `\r` and `\n` as `edit` splits its text, because the prompt then hides which line endings will be written.
- **Reversal cost:** low.

## Diagrams (FULL)

No trigger among T1-T4 applies. The data path is unchanged: `prompt` event → `_showActive` → body lines → terminal; input → `_answer` (`v` → whole body, no `answer` sent).

## State & Ownership (FULL)

| State | Owner (sole writer) | Lifetime | Invalidation / rebuild | Authoritative copy |
|---|---|---|---|---|
| None added | - | - | The body is recomputed from the prompt input each time it is shown | The prompt input from the engine |

## Failure & Visibility (FULL)

| Component | Fails / dies mid-operation → | Recovery | Retry safe? | Who finds out |
|---|---|---|---|---|
| Body rendering | Malformed input (an op that is not an object, a missing number) is shown as given (`?`) rather than throwing. The tool refuses the call later. | None needed | Yes | The user sees the odd op on the prompt |
| `v` with an answer in flight | Prints the body again. It never sends, so it cannot double-answer. | - | Yes | The user |

## Resource Bounds (FULL)

| Queue / buffer / cache / transfer | Bound | At the bound | Timeout | At 10x / 100x |
|---|---|---|---|---|
| Shown body | 20 lines, or the whole body on `v` | `… <m> more lines; v shows all` | None | Unbounded input, accepted: the prompt event already holds the whole call in memory, which the engine produced. The preview escapes only the 20 shown lines. The omitted lines are counted by scanning for line breaks, never escaped. `v` escapes and writes one body line at a time, so its extra memory is one escaped line (up to 10 characters per input character for a single uncapped line). Each `v` is one user action. |

## Flow & State Gaps (FULL)

- A prompt is withdrawn or answered while its body prints: printing is synchronous, so the next prompt's display follows it.
- A queued prompt becomes active: `_showActive` renders its body afresh with the preview.
- `v` at a question prompt (`ask`) is a question answer, as now; only permission prompts treat `v` specially.

## Mechanism Ledger (FULL)

| Mechanism | Built? | Why (harm nobody catches / expensive later) | Evidence that would change the call |
|---|---|---|---|
| 20-line preview with `v` | Yes | Without it, every write floods the terminal and the choice line scrolls away. | Dogfooding shows that 20 is too few or too many. |
| Old text in edit prompts | No | Needs an engine change (D2). Follow-up issue. | - |
| Horizontal cut of long lines | No | The prompt is never cut sideways (*Permission prompt text*); the terminal wraps. | - |
| Pager for `v` | No | The terminal's scrollback serves; M1 has no TUI. | Dogfood friction with very long writes. |

## Risks / Trade-offs

- [The user allows without typing `v`, so lines past the preview go unseen] → The `more lines` count shows that something was left out. As in OMP, reading it is the user's choice.
- [An edit's replace or delete shows line numbers without the old text] → Follow-up issue for engine-side old text; the edit's path and target are shown.

## ADRs

- **In force, constraining this change:** [0004](../../../docs/adr/0004-dart-native-engine-and-clients.md) (thin client renders what the engine sends) and [0011](../../../docs/adr/0011-conversation-tree-layout-and-rpc-protocol-v1.md) (the `prompt` event, unchanged).
- **To record during apply:** none.
