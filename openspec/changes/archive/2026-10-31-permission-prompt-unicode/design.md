# Design

## Triage

| Trigger | Applies? | Evidence |
|---|---|---|
| T1 Components (new component, or 3+ with directed relationships) | No | One function in `lib/src/client/render.dart` changes; its one caller (`lib/src/client/client.dart:555-576`) keeps its shape. |
| T2 State (persistent state, caches, 3+ state machine) | No | Rendering is a pure function of the prompt input; nothing is stored. |
| T3 Concurrency (background work, workers/isolates, async, retries) | No | Synchronous string rendering. |
| T4 Boundaries (data format, migration, shared interface, IPC, external) | No | The RPC `prompt` event and the engine are unchanged; only terminal output changes. |
| T5 Volume (grows without a fixed bound) | No | Linear in the prompt text, as now (`test/client/render_test.dart:15-23`). |
| T6 Risk (security, money, data loss, unrecoverable user data) | Yes | The prompt is what the user approves a command from. This change lets invisible, bidi and lookalike characters reach the screen. |

TIER: FULL

## Context

`exactLines` (`lib/src/client/render.dart:57-76`) splits the prompt text at line feeds and escapes every character outside U+0020..U+007E, and every backslash that starts `\u{`, as `\u{XXXX}`. The client uses it for the command or path, the `in <cwd>` line and the `-> <target>` line (`lib/src/client/client.dart:555-578`). Assistant text already goes through `modelText` (`render.dart:40-48`), which escapes C0, DEL and C1 except line feed and tab, and prints Unicode as itself.

oh-my-pi, at `2e23dffe598636817a9bab407cf55e6f9e9a8f82`, sanitises its approval dialog with `sanitizeText` (`packages/utils/src/sanitize-text.ts:21-40`). It removes ANSI sequences and C0 except tab and line feed, plus DEL and C1, and drops lone surrogates. It serialises tool arguments to JSON first, so a control character inside a value shows as `\n` or `\u001b` (`packages/coding-agent/src/tools/approval.ts:653-667`). Every other character, invisible and bidi ones included, prints as itself. Why kehai moves to that level, and the user's decision, are in `proposal.md`.

M1 constraints hold: Dart 3.x AOT, no Rust core, no embedded script runtime, and no durable session state outside the tree. The change touches neither sensorium nor truncation. Nocterm, compaction, LSP, jj checkpoints, the plugin protocol, MCP, Anthropic OAuth, the pricing registry and themes stay deferred to M2+. The line client still runs on native Windows without WSL; output stays UTF-8 there (`lib/src/client/engine_process.dart`, the console code page set in PR #14). Kehai apply attempt: this change is applied with Claude Code. Running it inside Kehai would need the `specwright-*` skills, which arrive in entry 5, so the attempt is recorded as unsupported, as the roadmap expects of entry 4 follow-ups.

## Decisions

### D1: Escape control characters only, as oh-my-pi does

- **Choice:** In the prompt's lines, escape C0 (tab and carriage return included), DEL, C1 and lone surrogates (U+D800..U+DFFF) as `\u{XXXX}`, and print every other character as itself. Line feed handling stays as it is: `exactLines` splits at them, the command or path becomes one `  | ` line per piece (`client.dart:556-565`), and the directory and target join the pieces with `\u{A}` on their one line (`client.dart:569`, `576`). This is OMP's level. OMP removes these characters silently; kehai keeps its visible escape, so a removed character never makes two different commands look the same.
- **Rejected:** a denylist of invisible and blank characters plus a mixed-script check (escape a Cyrillic letter inside a Latin word), because the user chose OMP's level on 2026-10-31. A denylist is also open-ended, as PR #14's rounds 7-8 showed. Also rejected: keeping ASCII-only with a readable second line, because it doubles every non-ASCII prompt.
- **Reversal cost:** low. One predicate in `render.dart` and its tests.

### D2: Keep the escape for a backslash that starts `\u{`

- **Choice:** `\u{` in the input is still shown as `\u{5C}u{`, so every `\u{XXXX}` on screen stands for exactly one escaped character (`render.dart:69-74`).
- **Rejected:** dropping it to match OMP exactly, because then a command holding the literal text `\u{1B}` reads the same as one holding ESC. Keeping it costs nothing for ordinary text.
- **Reversal cost:** low.

### D3: One renderer, not a merge with `modelText`

- **Choice:** keep `exactLines` separate from `modelText`. The prompt escapes tab and carriage return, which assistant text keeps or escapes differently, and only the prompt escapes `\u{`.
- **Rejected:** one shared function with flags, because the two have different contracts (spec *Streamed text* and *Permission prompt text*). Sharing them would couple a reading aid to an approval surface.
- **Reversal cost:** low.

## Diagrams (FULL)

No trigger among T1-T4 applies, so no diagram is needed. The data path is unchanged: `prompt` event → `_showActive` → `exactLines` → terminal.

## State & Ownership (FULL)

| State | Owner (sole writer) | Lifetime | Invalidation / rebuild | Authoritative copy |
|---|---|---|---|---|
| None added | - | - | - | The prompt input in the engine's tree, as before |

## Failure & Visibility (FULL)

| Component | Fails / dies mid-operation → | Recovery | Retry safe? | Who finds out |
|---|---|---|---|---|
| `exactLines` | It is pure and total. A lone surrogate is escaped rather than passed to the UTF-8 encoder. | None needed | Yes | The user sees the escape in the prompt |
| Terminal font lacks a glyph | The character shows as a box or blank | None; it is outside kehai | - | The user, on screen. This is the accepted risk below. |

## Resource Bounds (FULL)

| Queue / buffer / cache / transfer | Bound | At the bound | Timeout | At 10x / 100x |
|---|---|---|---|---|
| Rendered prompt text | At most 10 output characters per input character (`\u{10FFFF}`), as now | The prompt is shown whole (spec) | None | Linear, as now. The 200,000× `\u{` test stays. |

## Flow & State Gaps (FULL)

None. Rendering happens once per active prompt, from the prompt input, and holds no state between prompts.

## Mechanism Ledger (FULL)

| Mechanism | Built? | Why (harm nobody catches / expensive later) | Evidence that would change the call |
|---|---|---|---|
| Escape C0/DEL/C1 | Yes | A terminal control in the prompt can rewrite what the user sees, and only the terminal would notice. | - |
| Escape lone surrogates | Yes | Dart's UTF-8 encoder would turn them into U+FFFD, so two different inputs would look the same. | - |
| Escape `\u{` | Yes | Without it a literal escape text reads the same as an escaped control. | - |
| Escape invisible, bidi and blank characters | No | User decision (proposal). OMP does not do it either. | A real case of a model hiding a command this way during dogfooding. |
| Mixed-script (homoglyph) check | No | Same. | Same. |

## Risks / Trade-offs

- [A bidi override (U+202E) or a zero-width character in a command can make the prompt read differently from what runs] → Accepted by the user decision, as in OMP. The whole command is still shown, multi-line commands are split into `  | ` lines, and terminal controls stay escaped.
- [A lookalike letter makes a different file look like a familiar one] → Accepted. The resolved target line (`-> ...`, `outside the workspace`) still shows where a file tool writes.
- [A later security review asks for the stricter rendering again] → The spec requirement *Permission prompt text* states the rule, so such a finding is answered from the spec.

## ADRs

- **In force, constraining this change:** [0004](../../../docs/adr/0004-dart-native-engine-and-clients.md) (thin client renders what the engine sends) and [0011](../../../docs/adr/0011-conversation-tree-layout-and-rpc-protocol-v1.md) (the `prompt` event is unchanged).
- **To record during apply:** none. The rule is a client rendering choice, bounded by the spec, not a decision that binds other changes.
