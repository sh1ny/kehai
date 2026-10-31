# Proposal

## Why

Kehai can store a session, stream a model turn and run tools, but nothing yet connects them: no loop feeds tool results back to the model, and no user can talk to the engine. Until both exist Kehai cannot build Kehai, and every later M1 step (skills, subagents, the dogfood change) needs a running loop to attach to. This is also the first change whose own apply can be attempted inside Kehai.

This is change 4 of 6 in milestone **M1 — self-hosting skeleton** ([roadmap](../../roadmap.md)). It advances these exit criteria:

- *Complete branch → proposal → specs → design → tasks → apply → commit → finish → merge with Kehai as sole agent* (user). This change ships the loop and client that criterion runs on; skills, commands and subagents follow in change 5.
- *Every tool result uses central truncation/full-result handles, never tool-local cuts* (agent). The loop sends tool output to the model only as the composer's envelope.
- *A hung hook process cannot block turn progress* (agent). It is proven end to end through a whole loop turn, not just the hook stage.
- The M1 platform rule: *Windows login/line client must work without WSL*.

## What Changes

- **Agent loop** in the engine.
  - **Turn:** one user prompt starts a turn. The loop then alternates model requests and tool calls until the model stops without tool calls, the user interrupts, or the loop stops with a visible reason.
  - **Tree records:** each model request is one journal turn. User messages, assistant text, opaque reasoning items, step usage and stop reasons are recorded in the session tree under `body`, beside the existing `body/calls`. The model request is rebuilt from the tree every time, with tool outputs composed centrally from stored results.
  - **Tool calls:** calls of one model step run through the existing tool runtime, in parallel within its bounds.
- **Ctrl-C.** Interrupting cancels the provider stream and every live call of the turn. The turn ends `cancelled` with what was already committed kept. Background jobs are untouched.
- **Bounded retry with backoff.** Only failures proven not to have started work are retried: rate limits, and connection or setup failures before the request body was sent. Retries use a capped exponential delay, honouring `Retry-After`. Exhaustion is shown. A request that may have reached the backend, and any tool call, is never repeated automatically.
- **Context overflow stops clearly.** Before sending, the loop compares its conservative estimate with the model's context window. Over it, or on a provider `context_overflow` failure, the turn stops and names the numbers and the way out (rewind or a new session). There is no compaction (M2+).
- **M1 perception.** Each model request gets one request-only `<sensorium>` block with the `turn` and `budget` sections (turn number, context used/max with percentage, and the model). The block is never stored in history. Cost is omitted: there is no pricing registry in M1.
- **`kehai rpc`**: local NDJSON over stdio, the only way a client reaches the engine.
  - **Session:** opens a new or resumed session for the workspace and holds its single writer.
  - **Client view:** sends an initial materialization with its log offset, then ordered committed updates, plus ephemeral stream events (text and reasoning deltas, tool display lines).
  - **Commands:** `submit`, `interrupt`, `answer` and `status`. Commands carry request ids. Duplicates report the recorded outcome and do not execute again. A client that falls behind is resynchronized with a fresh materialization.
- **Line client**: `kehai` with no subcommand.
  - **Process:** it starts `kehai rpc` as a child process and renders only what the engine sends.
  - **Input and output:** line input with simple continuation, assistant text streamed as it arrives, and one line per tool call.
  - **Prompts:** permission prompts and `ask` questions arrive as numbered choices or free text. This wires the change 3 answerer to a real user.
  - **Ctrl-C:** interrupts a running turn; at an idle prompt it exits.
  - **Platforms:** runs on native Windows (no WSL) and Linux.
- **Session location and model choice.**
  - **Location:** sessions live under the Kehai home, keyed by the canonical workspace path. `kehai` starts a new session; `--resume` reopens the workspace's latest session and `--session <id>` a given one.
  - **Model:** chosen by `--model` or the configuration's `model`. Neither set fails with the available model list; no default model is guessed.
- **Context window.** Model listing also returns each model's `context_window` when the backend reports it. A user configuration entry may set it for a model the backend does not describe. An unknown window shows as unknown in the budget, and only the provider's own overflow failure stops the turn.
- **Dogfood record.** Once the loop first runs, the rest of this change's apply is attempted inside Kehai. Each step Kehai could not do is recorded in the design. Specwright commands and subagents are expected to be unsupported until change 5.

Out of scope:
- **Change 5:** skills, `AGENTS.md` injection, commands and typed subagents.
- **M2+:**
  - nocterm;
  - compaction;
  - the broader sensorium (`vcs`, changes, scratchpad, diagnostics, checkpoints);
  - LSP and jj checkpoints;
  - rewind/fork UI;
  - pricing;
  - themes;
  - full Windows tool parity.

## Capabilities

### New Capabilities
- `agent-loop`: the turn and step lifecycle, the message chain in the tree, request composition from the tree, parallel tool execution per step, interruption, bounded retry and the context-overflow stop.
- `turn-perception`: the request-only M1 sensorium block (`turn` and `budget`), its token accounting and how it is kept out of history.
- `engine-rpc`: `kehai rpc`. It covers NDJSON framing and size limits, session open/create/resume for a workspace, the initial materialization and ordered updates by log offset, ephemeral stream events, the commands with request correlation and duplicate handling, resync of a slow client, and shutdown on client loss.
- `line-client`: the `kehai` interactive client over `kehai rpc`. It covers line input, streamed output, one-line tool display, permission and question prompts, Ctrl-C behaviour and model selection, on Linux and native Windows.

### Modified Capabilities
- `model-provider`: model listing also returns the model's context window when the backend reports one, every streamed event carries the backend's output index, so a step's text, reasoning and calls can be stored in the response's order, and one response's output, held tool-call arguments included, is bounded at 4 MiB.
- `tool-permissions`: the user configuration file also holds the default `model` and per-model context-window overrides.

## Impact

- **New code:**
  - `lib/src/loop/`: the turn driver, request composition, the retry policy and turn/budget rendering;
  - `lib/src/rpc/`: protocol types, the NDJSON codec and the engine server;
  - `lib/src/client/`: the line client;
  - new `rpc` and default commands in `lib/src/cli/cli.dart`.
- **Changed code:**
  - `ModelInfo` gains an optional context window, and stream events gain an optional output index (`lib/src/provider/provider.dart`, `chatgpt_adapter.dart`);
  - `ToolRuntime.run` takes the exchange's cancel token (`lib/src/tools/runtime.dart`);
  - `UserConfig` gains `model` and `models` keys (`lib/src/config/user_config.dart`).
- **Tree shape:** new turn-anchored nodes under `body` for messages and steps, inside the v1 roots. There is no journal format bump. The layout is recorded in the design and, because changes 5 and 6 read it, in an ADR.
- **Process model:** the client and the engine are two processes of the same executable joined by stdio. On Windows both receive the console Ctrl-C, so the engine ignores the signal and only the client's `interrupt` command cancels.
- **Tests:**
  - a scripted fake provider for loop tests;
  - in-memory stream tests of the RPC server;
  - a process-level test of `kehai rpc` and the client;
  - an end-to-end hung-hook turn.
  
  Linux runs use WSL as already approved. Windows Ctrl-C and line editing get a user-verified manual check.
- **Dependencies:** none expected.
