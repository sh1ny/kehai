# Tasks

## Test map

Platform-tagged tests are marked in the test name and run on the platform named:
- `[unix]` tests are skipped on Windows and run on the Linux (WSL) runner;
- `[windows]` tests run on native Windows only.

The loop tests drive the `ExchangeDriver` against a scripted fake `ModelProvider` and a real `SessionWriter` and `ToolRuntime` in a temporary home. Races (interrupt during the step commit, slowed flushes) are made deterministic through the writer's and the driver's pause seams, never through sleeps. Retry delays run on a fake clock. RPC tests run the server over in-memory byte streams; the `process` tests start the real `kehai` executable against `test/support/fake_openai.dart`.

| Requirement | Scenario | Test file | Test name | State |
|---|---|---|---|---|
| agent-loop → Exchanges and steps | Prompt answered after one tool round | test/loop/driver_test.dart | prompt answered after one ls round records two steps on consecutive turns | red |
| agent-loop → Exchanges and steps | Prompt while an exchange runs | test/loop/driver_test.dart | second prompt while running is refused busy and records nothing | red |
| agent-loop → Conversation recorded in the tree | Items in order | test/loop/driver_test.dart | step output commits text, reasoning and calls in output-index order | red |
| agent-loop → Conversation recorded in the tree | Rewind removes the later steps | test/loop/request_builder_test.dart | rewind to an exchange's first turn drops later steps from the request | red |
| agent-loop → Requests rebuilt from the tree | Tool output is the composed envelope | test/loop/request_builder_test.dart | tool output is the stored model text byte for byte | red |
| agent-loop → Requests rebuilt from the tree | Resumed session | test/loop/request_builder_test.dart | resumed session request holds earlier items and cancelled calls' outputs | red |
| agent-loop → Tool calls of a step | Parallel calls | test/loop/driver_test.dart | three read calls overlap and the next step waits for all | red |
| agent-loop → Tool calls of a step | Many calls in one step | test/loop/driver_test.dart | 128 calls under slowed flushes all get terminal nodes and no writer busy | red |
| agent-loop → Tool calls of a step | Denied call | test/loop/driver_test.dart | denied bash call sends its envelope and the exchange continues | red |
| agent-loop → Interrupt | Interrupt during a model stream | test/loop/interrupt_test.dart | interrupt mid-stream records cancelled step with partial text | red |
| agent-loop → Interrupt | Interrupt while tools run | test/loop/interrupt_test.dart | interrupt cancels running bash and withdraws the open prompt | red |
| agent-loop → Interrupt | Interrupt while the step commits | test/loop/interrupt_test.dart | interrupt during the step commit cancels both writes before any effect | red |
| agent-loop → Interrupt | Interrupt when idle | test/loop/interrupt_test.dart | idle interrupt records nothing and replies no exchange running | red |
| agent-loop → Bounded retry of unstarted requests | Rate limit then success | test/loop/retry_test.dart | rate_limited with Retry-After 3 retries once and records 2 attempts | red |
| agent-loop → Bounded retry of unstarted requests | Retries exhausted | test/loop/retry_test.dart | five unsent network failures end failed after 5 attempts | red |
| agent-loop → Bounded retry of unstarted requests | Failure after the body was sent | test/loop/retry_test.dart | server 500 and sent network failures are not repeated | red |
| agent-loop → Bounded retry of unstarted requests | Retry-After too long | test/loop/retry_test.dart | Retry-After 600 is not retried and names the wait | red |
| agent-loop → Context overflow stops the exchange | Estimate over the window | test/loop/driver_test.dart | estimate over a known window stops before sending | red |
| agent-loop → Context overflow stops the exchange | Provider reports overflow | test/loop/driver_test.dart | provider context_overflow stops the exchange without retry | red |
| agent-loop → Step output limit | Endless small deltas | test/loop/driver_test.dart | response_output_limit fails the step with its partial text | red |
| agent-loop → Step output limit | Held calls over the limit | test/loop/driver_test.dart | held calls over 4 MiB fail the step and none runs | red |
| agent-loop → Step output limit | Large but bounded reply | test/loop/driver_test.dart | 3 MiB reply completes whole | red |
| agent-loop → Step limit | Runaway loop | test/loop/driver_test.dart | 200th step's calls settle then the exchange stops at step limit | red |
| agent-loop → Step limit | Normal exchange | test/loop/driver_test.dart | three-step exchange records no step limit | red |
| agent-loop → Resume finalizes unfinished exchanges | Crash mid-step | test/loop/resume_test.dart | killed engine mid-step is finalized cancelled interrupted on reopen | red |
| agent-loop → Resume finalizes unfinished exchanges | Clean session | test/loop/resume_test.dart | reopening a clean session records nothing | red |
| agent-loop → A hung hook cannot stall the exchange | Optional hook hangs | test/loop/hung_hook_test.dart | hung optional read hook is killed and the next step starts | red |
| agent-loop → A hung hook cannot stall the exchange | Deny-class hook hangs | test/loop/hung_hook_test.dart | hung deny bash hook denies the call and the exchange continues | red |
| turn-perception → One request-only sensorium block | Second step of an exchange | test/loop/sensorium_test.dart | only the last request item is a sensorium block and instructions are stable | red |
| turn-perception → One request-only sensorium block | Tree after a step | test/loop/sensorium_test.dart | no tree item contains a sensorium block after a step | red |
| turn-perception → Turn and budget sections | Known window | test/loop/sensorium_test.dart | budget line with a known window shows used, window and percent | red |
| turn-perception → Turn and budget sections | Unknown window | test/loop/sensorium_test.dart | budget line with an unknown window shows ? and no percent | red |
| turn-perception → Context in use | After a step with usage | test/loop/sensorium_test.dart | interleaved outputs of the baseline step are counted once by provenance | red |
| turn-perception → Context in use | Step without usage | test/loop/sensorium_test.dart | cancelled step without usage falls back to the last completed step | red |
| turn-perception → Context in use | Incomplete step then a new prompt | test/loop/sensorium_test.dart | incomplete step's usage is not the baseline and the request is sent | red |
| engine-rpc → NDJSON framing | Valid command | test/rpc/codec_test.dart | one status line gets exactly one reply line | red |
| engine-rpc → NDJSON framing | Bad lines | test/rpc/codec_test.dart | 2 MiB line and unknown command error then status is answered | red |
| engine-rpc → Session opened for the workspace | New session | test/rpc/process_test.dart | rpc starts with hello v1 and a session under the workspace key | red |
| engine-rpc → Session opened for the workspace | Session locked | test/rpc/process_test.dart | resume of a locked session writes fatal naming the holder and exits 1 | red |
| engine-rpc → Session opened for the workspace | Nothing to resume | test/rpc/process_test.dart | resume with no session writes fatal and exits 1 | red |
| engine-rpc → Materialization then ordered updates | Client tree matches the engine | test/rpc/server_test.dart | snapshot plus updates equals the engine tree through one exchange | red |
| engine-rpc → Materialization then ordered updates | Rewind committed | test/rpc/server_test.dart | rewind update is followed by resync and the rewound snapshot | red |
| engine-rpc → Materialization then ordered updates | Offsets after resume | test/rpc/server_test.dart | snapshot offset after a cut torn tail is the cut length | red |
| engine-rpc → Resync of a slow client | Client stops reading | test/rpc/pump_test.dart | stalled reader gets resync and snapshot then converges | red |
| engine-rpc → Resync of a slow client | Repeated overflow while stalled | test/rpc/pump_test.dart | three overflows keep one pending resync with the latest tree | red |
| engine-rpc → Resync of a slow client | Commands while output is stalled | test/rpc/pump_test.dart | 1 MiB of pending replies pauses stdin reading | red |
| engine-rpc → Resync of a slow client | Client keeps up | test/rpc/pump_test.dart | prompt reader never gets resync | red |
| engine-rpc → Ephemeral stream events | Streamed text matches the commit | test/rpc/server_test.dart | two stream events then the committed Hello update | red |
| engine-rpc → Ephemeral stream events | Deltas lost to a resync | test/rpc/server_test.dart | dropped deltas leave the whole text in snapshot or update | red |
| engine-rpc → Commands correlated by request id | Duplicate submit | test/rpc/server_test.dart | duplicate submit reports the recorded state and runs once | red |
| engine-rpc → Commands correlated by request id | Id collision | test/rpc/server_test.dart | reused id with other text is a request id collision | red |
| engine-rpc → Commands correlated by request id | Stale submit | test/rpc/server_test.dart | submit at an older turn is stale and not admitted | red |
| engine-rpc → Interrupt, answer and status | Status after a crash | test/rpc/process_test.dart | status of a request killed mid-exchange is interrupted effect-uncertain | red |
| engine-rpc → Interrupt, answer and status | Unknown request | test/rpc/server_test.dart | status of an unknown id is not-admitted | red |
| engine-rpc → Interrupt, answer and status | Wrong answer | test/rpc/server_test.dart | answer outside the choices errors and the prompt stays open | red |
| engine-rpc → Prompts reach the client | Permission prompt | test/rpc/server_test.dart | non-autoapproved bash sends a permission prompt and allow runs it | red |
| engine-rpc → Prompts reach the client | Prompt withdrawn by interrupt | test/rpc/server_test.dart | interrupt withdraws the open question and a late answer is refused | red |
| engine-rpc → Signals and client loss | Ctrl-C reaches the engine | test/rpc/process_test.dart | [unix] SIGINT to the engine does not stop the exchange | red |
| engine-rpc → Signals and client loss | Client exits mid-exchange | test/rpc/process_test.dart | stdin EOF cancels the foreground bash, releases the lock and exits 0 | red |
| line-client → Client over the engine process | Start | test/client/process_test.dart | kehai --model starts kehai rpc and shows session, model and prompt | red |
| line-client → Client over the engine process | Engine cannot start | test/client/process_test.dart | logged-out start prints the engine fatal and exits 1 | red |
| line-client → Model selection | No model configured | test/client/process_test.dart | no model anywhere fails with the hint and the model list | red |
| line-client → Model selection | Unknown model | test/client/process_test.dart | unlisted model fails naming it and the model list | red |
| line-client → Line input | Continued line | test/client/client_test.dart | backslash continuation submits one joined prompt | red |
| line-client → Line input | Typing during an exchange | test/client/client_test.dart | input while running and no prompt prints busy and submits nothing | red |
| line-client → Streamed text | Live text | test/client/client_test.dart | deltas print as they arrive and the commit reprints nothing | red |
| line-client → Streamed text | Resync mid-text | test/client/client_test.dart | resync mid-text prints only the unseen committed tail | red |
| line-client → One line per tool call | Settled call | test/client/client_test.dart | settled bash call prints one status line | red |
| line-client → One line per tool call | Long command | test/client/client_test.dart | long command line is cut to 160 characters with an ellipsis | red |
| line-client → Answering prompts | Allow a command | test/client/client_test.dart | typing 1 at a permission prompt sends allow for its key | red |
| line-client → Answering prompts | Two permission prompts | test/client/client_test.dart | second prompt is queued and each answer binds to one key | red |
| line-client → Answering prompts | Refused answer keeps the active prompt | test/client/client_test.dart | refused answer keeps the active prompt and the queue | red |
| line-client → Answering prompts | Withdrawal advances the queue | test/client/client_test.dart | withdrawals remove queued keys and advance the active one | red |
| line-client → Answering prompts | Invalid choice | test/client/client_test.dart | invalid choice is refused locally and asked again | red |
| line-client → Ctrl-C | Interrupt a running exchange | test/client/client_test.dart | two Ctrl-C while running send exactly one interrupt | red |
| line-client → Ctrl-C | Engine stuck on exit | test/client/client_test.dart | engine still alive 5 s after stdin closes is killed | red |
| line-client → Native Windows and Linux | Windows console | test/client/process_test.dart | [windows] naïve reaches the backend through client and engine and Ctrl-C interrupts | red |
| line-client → Native Windows and Linux | Non-terminal input | test/client/process_test.dart | piped two lines run in order and exit at end of input | red |
| model-provider → Output positions | Call before text | test/provider/chatgpt_adapter_test.dart | call at index 0 and text at index 1 carry their output indexes | green |
| model-provider → Output positions | Missing index | test/provider/chatgpt_adapter_test.dart | delta without output_index carries no index | green |
| model-provider → Response output limit | Held arguments exceed the limit | test/provider/chatgpt_adapter_test.dart | fifth 1 MiB held call fails response_output_limit and emits no call | green |
| model-provider → Response output limit | Output within the limit | test/provider/chatgpt_adapter_test.dart | 3 MiB text and a 512 KiB call complete normally | green |
| model-provider → Model listing | Models listed | test/provider/models_test.dart | listed models exclude non-list visibility and unsupported | green |
| model-provider → Model listing | Context window reported | test/provider/models_test.dart | context_window is read only when an integer above 1 | green |
| model-provider → Model listing | Models endpoint fails | test/provider/models_test.dart | 503 fails server with no list | green |
| model-provider → Model listing | Oversized models response | test/provider/models_test.dart | body over 4 MiB fails protocol | green |
| tool-permissions → User configuration file | Missing configuration | test/config/config_test.dart | missing config.json uses defaults | green |
| tool-permissions → User configuration file | Invalid configuration | test/config/config_test.dart | unknown key or bad type refuses to start naming the path | green |
| tool-permissions → User configuration file | Model settings | test/config/config_test.dart | model and models contextWindow parse | green |
| tool-permissions → User configuration file | Invalid model settings | test/config/config_test.dart | bad contextWindow or unknown model key refuses naming the path | green |

The *Missing configuration* row is red because its expectation grows (no default model, no window overrides); the existing test is extended.

## 1. ADR and architecture index

- [x] 1.1 Write `docs/adr/0011-conversation-tree-layout-and-rpc-protocol-v1.md` (`Status: accepted`, today's date, `Supersedes: none`). Per design D2, D4, D11 and D12 it records:
  - `body/exchanges/x-<turn>` and `body/steps/s-<turn>` with their fields, and the one-`merge` step commit ordered by output index;
  - the call node's `model` reference, as an addition to ADR 0010's call fields (0010 stays in force);
  - protocol v1: messages, request-id admission, turn-based staleness, reliable and droppable output, coalesced resync.

  Add its row to the in-force index in `openspec/architecture.md`. Verify with `mise run openspec:validate`, and confirm the index lists 0011.

## 2. Configuration and provider

- [x] 2.1 Extend `test/config/config_test.dart` with the red rows (missing configuration, model settings, invalid model settings). Implement `model` and `models.<id>.contextWindow` in `lib/src/config/user_config.dart`, strict like the other keys. Verify that `config_test.dart` passes and flip the rows green; re-run *Invalid configuration* and confirm it stays green.
- [x] 2.2 Write the failing *Context window reported* row in `test/provider/models_test.dart`. Add the optional `contextWindow` to `ModelInfo` and read `context_window` in the adapter's listing. Verify that `models_test.dart` passes, flip the row green, and confirm the three green listing rows still pass.
- [x] 2.3 Write the failing output-position and response-limit rows in `test/provider/chatgpt_adapter_test.dart`, served through `test/support/fake_openai.dart`. Implement `outputIndex` on `TextDelta`, `ReasoningSummaryDelta`, `OpaqueItem` and `ToolCall` (D15), and the per-response 4 MiB counter with `response_output_limit` (D16). Verify that the adapter tests pass and flip the four rows green.

## 3. Runtime and writer seams

- [x] 3.1 Write failing tests in `test/tools/runtime_test.dart`:
  - `run(call, cancel: token)` links the call to the exchange token, and a call admitted with an already-cancelled token is recorded `pending` → `cancelled` (reason `user`) with a stored result and no hook, prompt or effect;
  - the terminal `merge` carries `model: {handle, complete: true}` whose stored bytes equal the returned model text, including storage-failure and denied calls.

  Implement both in `lib/src/tools/runtime.dart` (D4, D5). Verify that `runtime_test.dart` passes.
- [x] 3.2 Write failing tests in `test/session/write_gate_test.dart`: with flushes paused, 128 concurrent gated operations never exceed 48 in the writer, run in FIFO order and never raise `writer busy`. Implement the engine write gate (D17) and route the runtime, supervisor and (later) driver and server writes through it. Verify that the new file and `mise run test -- test/session test/tools test/jobs` pass.

## 4. Earliest runnable loop

- [ ] 4.1 Write the failing `test/loop/request_builder_test.dart` and `test/loop/sensorium_test.dart` rows, with a clock seam for `HH:MM`. Implement the request builder (D3, including the unpaired-call omission and the D4 fallbacks), the built-in instructions with their version (D6) and the sensorium block with provenance-based context accounting (D7). Verify that both files pass and flip their rows green.
- [ ] 4.2 Write the failing `test/loop/driver_test.dart` rows (exchanges and steps, items in order, tool calls of a step, context overflow, step output limit, step limit). Implement `ExchangeDriver` in `lib/src/loop/` per D2, D5, D9 and D10, without retry. Verify that `driver_test.dart` passes and flip its rows green.
- [ ] 4.3 Write the failing `test/rpc/codec_test.dart` rows and the `test/rpc/server_test.dart` rows for materialization, stream events, request-id commands, prompts and *Unknown request*, *Wrong answer*. Implement `lib/src/rpc/`: the NDJSON codec with the 1 MiB line limit, the protocol v1 types and the server over the driver (D11), with a simple unbounded output pump for now. Verify that both files pass and flip their rows green.
- [ ] 4.4 Write the failing `test/rpc/process_test.dart` rows *New session*, *Session locked* and *Nothing to resume*. Implement `kehai rpc` in `lib/src/cli/`, with session location, `meta/workspace` and `--resume`/`--session` (D13) and model resolution with the startup listing. Verify that the three rows pass and flip them green.
- [ ] 4.5 Write the failing `test/client/client_test.dart` rows for line input, streamed text, one line per tool call and *Allow a command*, against an in-memory engine stream. Then write the `test/client/process_test.dart` rows *Start*, *Engine cannot start*, *No model configured*, *Unknown model* and *Non-terminal input*. Implement `lib/src/client/` and the no-subcommand `kehai` that starts `kehai rpc` (D1), with a single active prompt for now. Verify that these rows pass and flip them green.
- [ ] 4.6 Smoke-run `kehai` in this repository with the ChatGPT plan login on Windows: one prompt that reads a file and runs `dart analyze`. Record the run (model, steps, any failure) as the first entry of design.md's **Dogfood record**. From here on, attempt each task group inside Kehai first and record in the Dogfood record each step it could not do, and why.

## 5. Interrupt, retry and resume

- [ ] 5.1 Write the failing `test/loop/interrupt_test.dart` rows, using the writer pause seam for *Interrupt while the step commits*. Implement interrupt in the driver (token cancel, `cancelTurn`, cancelled step with `partial`, prompt withdrawal). Verify that the file passes and flip its rows green.
- [ ] 5.2 Write the failing `test/loop/retry_test.dart` rows on a fake clock. Implement the D8 policy in the driver (1/2/4/8 s, `Retry-After` up to 60 s, interruptible waits, `attempts`). Verify that the file passes and flip its rows green.
- [ ] 5.3 Write the failing `test/loop/resume_test.dart` rows and `test/rpc/process_test.dart` *Status after a crash*, using a killed engine fixture in `test/fixtures/`. Implement resume finalization after `ToolRuntime.attach`, before `hello`. Verify that the rows pass and flip them green.

## 6. RPC output pump and signals

- [ ] 6.1 Write the failing `test/rpc/pump_test.dart` rows, and the `server_test.dart` rows *Rewind committed*, *Offsets after resume* and *Deltas lost to a resync*. Replace the simple pump with the D12 pump: 16 MiB droppable, 1 MiB reliable with stdin pause, one coalesced `resync` + `snapshot` taken at write time. Verify that the rows pass and flip them green.
- [ ] 6.2 Write the failing `test/rpc/process_test.dart` rows *Ctrl-C reaches the engine* (`[unix]`) and *Client exits mid-exchange*. Implement the engine's ignored `SIGINT` and stdin-EOF shutdown (D14). Verify on Windows and through the WSL runner, and flip the rows green.

## 7. Line client prompts, Ctrl-C and Windows

- [ ] 7.1 Write the failing `client_test.dart` rows *Two permission prompts*, *Refused answer keeps the active prompt*, *Withdrawal advances the queue* and *Invalid choice*. Implement the one-active-prompt FIFO (D14). Verify that the rows pass and flip them green.
- [ ] 7.2 Write the failing `client_test.dart` rows *Interrupt a running exchange* and *Engine stuck on exit*, using a signal seam and a fake engine process. Implement client Ctrl-C and the 5 s kill. Verify that the rows pass and flip them green.
- [ ] 7.3 Write the failing `process_test.dart` row *Windows console*. Implement the console code-page setup and restore with `SetConsoleCP`/`SetConsoleOutputCP` (65001). Verify that the row passes on Windows and flip it green. Then ask the user to run `kehai` in Windows Terminal PowerShell, submit a prompt containing `naïve` and press Ctrl-C during a reply, and record their result in the task notes.

## 8. Hung hooks and acceptance

- [ ] 8.1 Write the failing `test/loop/hung_hook_test.dart` rows, with user config hooks running `test/fixtures/hang_forever.dart` at a 2 s deadline, driven through the real driver and runtime. Verify that both rows pass (the next step starts within 5 s) and flip them green. This serves the exit criterion "A hung hook process (test fixture) cannot block turn progress".
- [ ] 8.2 Run `mise run check` and `mise run openspec:validate` on Windows, and `dart test` through the WSL runner. Verify that every test map row reads `green`.
- [ ] 8.3 Complete design.md's **Dogfood record** with every gap Kehai hit from task group 4 on, including the expected unsupported Specwright commands and subagents.

## Workflow follow-up

- Pre-ship review, PR and merge follow `specwright-commit` and `specwright-pr` once all tasks are done.
- The M1 exit criteria this change serves (the Windows line client without WSL, the hung-hook check end to end, the loop the full lifecycle depends on) are marked passed only at milestone close, from the 7.3, 8.1 and 4.6 evidence.
