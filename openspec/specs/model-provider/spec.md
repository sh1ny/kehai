# model-provider Specification

## Purpose
Gives the engine one normalized way to stream a model turn: text, tool calls, usage, stop reason and typed failures. It hides provider wire formats, and ships the ChatGPT plan backend (the Responses API under Sign in with ChatGPT token sharing) as the first implementation.

## Requirements

### Requirement: Normalized turn stream
A provider SHALL turn one model request into an ordered event stream that ends with exactly one terminal event, `completed` or `failed`. Only `completed` is success. The request holds the model id, instructions, conversation items, tool definitions and optional reasoning effort. Non-terminal events are text deltas, reasoning-summary deltas, complete tool calls, opaque reasoning items and usage.

#### Scenario: Text answer
- **WHEN** the backend streams two text deltas and then completes
- **THEN** the stream yields both text deltas in order, one usage event, then `completed` with stop reason `end_turn`, and then closes

#### Scenario: Stream ends early
- **WHEN** the connection closes before the backend sends a completion event
- **THEN** the stream ends with `failed` of kind `protocol`, saying the stream ended before completion, and no `completed` event is emitted

### Requirement: Complete tool calls
A tool call SHALL be emitted as one event with the call id, tool name and its arguments as a JSON string, never as fragments. Tool calls SHALL be held until the backend reports successful completion, then emitted just before usage and `completed` with stop reason `tool_use`. A turn that ends in `failed` SHALL emit no tool call. Malformed arguments are passed through as received, for the caller to reject.

#### Scenario: Two parallel tool calls
- **WHEN** the backend emits two function calls in one response and completes
- **THEN** the stream yields two tool-call events with distinct call ids and their full argument strings, then `completed` with stop reason `tool_use`

#### Scenario: Tool result round trip
- **WHEN** the next request includes each tool call and its output, keyed by the same call id
- **THEN** the backend request carries each call and its output paired by that call id

#### Scenario: Tool call then connection drop
- **WHEN** the backend finishes a function-call item and the connection then drops before completion
- **THEN** no tool-call event is emitted, and the stream ends with `failed` of kind `network`

#### Scenario: Malformed arguments
- **WHEN** a function call's arguments are not valid JSON
- **THEN** the tool-call event carries the argument string unchanged, and the stream continues

### Requirement: Incomplete response
A backend response that ends incomplete SHALL end the stream with usage and then `failed` of kind `incomplete`, carrying the backend's reason as a validated code. It SHALL NOT end with `completed`. Text already streamed stays emitted; held tool calls are dropped.

#### Scenario: Incomplete after text
- **WHEN** the backend streams text deltas and then reports the response incomplete with reason `max_output_tokens`
- **THEN** the stream yields the deltas, one usage event, then `failed` of kind `incomplete` with code `max_output_tokens`, and no `completed`

#### Scenario: Incomplete after a tool call
- **WHEN** the backend finishes a function-call item and then reports the response incomplete
- **THEN** no tool-call event is emitted, and the stream ends with usage and `failed` of kind `incomplete`

### Requirement: Opaque reasoning continuity
Reasoning items the backend returns for continuity SHALL be emitted as opaque items. When such an item is sent back in a later request's conversation items, it SHALL be forwarded unchanged. Kehai SHALL NOT interpret or alter it.

#### Scenario: Reasoning passed back
- **WHEN** a response contains an encrypted reasoning item, and the next request includes that item
- **THEN** the next backend request contains the item byte-identical to what was received

#### Scenario: No reasoning returned
- **WHEN** a response contains no reasoning item
- **THEN** no opaque reasoning event is emitted, and the turn completes normally

### Requirement: Usage and token estimate
Each completed or incomplete turn SHALL emit one usage event with input, cached-input, output and reasoning token counts as the backend reports them. A provider SHALL also offer a conservative token estimate for a request before it is sent, documented and never lower than the request's UTF-8 byte length divided by 3, rounded up.

#### Scenario: Usage reported
- **WHEN** the completion event reports 1200 input tokens of which 800 cached, 300 output tokens and 120 reasoning tokens
- **THEN** the usage event carries input 1200, cached 800, output 300 and reasoning 120

#### Scenario: Usage absent
- **WHEN** the completion event carries no usage
- **THEN** the usage event is emitted with every count marked unknown, not zero

#### Scenario: Estimate before sending
- **WHEN** a request whose serialized content is 9,000 UTF-8 bytes is estimated
- **THEN** the estimate is at least 3,000 tokens

### Requirement: Typed sanitized failures
Every failure SHALL be one of these kinds: `reauth_required`, `usage_limit`, `rate_limited`, `not_permitted`, `context_overflow`, `invalid_request`, `server`, `network`, `idle_timeout`, `cancelled`, `incomplete`, `protocol`.

Each carries the HTTP status, and the validated code and parameter when known, and a Kehai-composed message of at most 500 characters (credential-store *Locally composed failure text*). It SHALL NOT carry server message text, bodies, headers or credentials.

#### Scenario: Context too long
- **WHEN** the backend rejects a request with code `context_length_exceeded`
- **THEN** the stream ends with `failed` of kind `context_overflow`, carrying that code

#### Scenario: Usage limit reached
- **WHEN** the backend answers with code `subscription_sharing_usage_limit_exceeded` or `subscription_sharing_workplace_individual_usage_limit_exceeded`, in an HTTP error or in a failed-response event after streaming began
- **THEN** the failure kind is `usage_limit`, it carries no retry-after, and its message names the code and points to the ChatGPT usage settings

#### Scenario: Plan usage not permitted
- **WHEN** the backend answers `403` with code `subscription_sharing_user_not_eligible`, `subscription_sharing_route_not_supported`, `chatpass_v2_scope_not_authorized` or `chatpass_v2_invalid_authorization_context`, or `403` with no code
- **THEN** the failure kind is `not_permitted`, its message names the code (or the status), and it is not marked `reauth required`

#### Scenario: Plan usage temporarily unavailable
- **WHEN** the backend answers `503`, with or without code `subscription_sharing_usage_unavailable` or `subscription_sharing_user_unavailable`
- **THEN** the failure kind is `server` with status 503, and stored credentials are unchanged

#### Scenario: Unsupported capability
- **WHEN** the backend answers `400` with code `subscription_sharing_unsupported_capability` and parameter `input[0].tools[0]`
- **THEN** the failure kind is `invalid_request`, carrying that code and parameter

#### Scenario: Rate limited
- **WHEN** the backend answers `429` with a `Retry-After` of 20 seconds
- **THEN** the failure kind is `rate_limited` and it carries a retry-after of 20 seconds

#### Scenario: Unknown server error body
- **WHEN** the backend answers `500` with an HTML body, or any status with a `{"detail": …}` body
- **THEN** the failure kind follows the status, and the message excludes the body and the `detail` text

### Requirement: No automatic resend
The adapter SHALL NOT resend a model request after its body may have reached the backend, except the single `401` refresh-and-repeat defined by provider-auth. Whether to retry any other failure is the caller's decision.

#### Scenario: Connection drops mid-stream
- **WHEN** the connection drops after some text deltas were received
- **THEN** the stream ends with `failed` of kind `network`, and no second request is sent

#### Scenario: Connection refused
- **WHEN** the TCP connection is refused before any byte is sent
- **THEN** the stream ends with `failed` of kind `network`, marked as not sent, and no second request is sent

### Requirement: Cancellation and idle deadline
A cancel signal passed with the request SHALL abort the HTTP request and end the stream with `failed` of kind `cancelled`. A subscriber that stops listening SHALL also abort it, and gets no further event. A response-silence deadline (default 300 s, per provider) SHALL run from sending the request, restart on the headers and on each event, and pause while the subscriber pauses. On expiry the request is aborted, not resent, and the stream ends with `failed` of kind `idle_timeout`.

#### Scenario: Caller cancels
- **WHEN** the caller triggers the request's cancel signal after the first text delta
- **THEN** the HTTP connection is closed, the stream yields `failed` of kind `cancelled` and then closes, and no further delta is emitted

#### Scenario: Subscriber stops listening
- **WHEN** the subscriber cancels its subscription after the first text delta
- **THEN** the HTTP connection is closed, and no further request is sent for that turn

#### Scenario: Backend stalls
- **WHEN** the backend sends one delta and then nothing for longer than the deadline
- **THEN** the stream ends with `failed` of kind `idle_timeout`, and the connection is closed

#### Scenario: Headers withheld
- **WHEN** the backend reads the whole request body and then sends no response headers for longer than the deadline
- **THEN** the stream ends with `failed` of kind `idle_timeout` marked sent, the connection is closed, and the backend received exactly one request

#### Scenario: Headers without events
- **WHEN** the backend sends SSE response headers and then no event for longer than the deadline
- **THEN** the stream ends with `failed` of kind `idle_timeout`, the connection is closed, and the backend received exactly one request

#### Scenario: Paused subscriber is not a stall
- **WHEN** the subscriber pauses the stream for longer than the deadline while the backend has more events, and then resumes
- **THEN** the remaining events are delivered and the turn completes

### Requirement: Bounded stream input
The adapter SHALL bound what it buffers from the backend:
- an SSE event of more than 8 MiB;
- an accumulated tool-call argument string of more than 8 MiB;
- an error body beyond its first 64 KiB.

The first two SHALL end the stream with `failed` of kind `protocol`. For the error body, only the first 64 KiB is read.

#### Scenario: Oversized event
- **WHEN** the backend sends a single SSE event larger than 8 MiB
- **THEN** the stream ends with `failed` of kind `protocol` naming the limit, and memory held for that event is released

#### Scenario: Normal large output
- **WHEN** a response streams 2 MiB of text across many deltas
- **THEN** every delta is emitted, and the turn completes normally

### Requirement: ChatGPT plan backend
The first provider SHALL send turns to `POST https://api.openai.com/v1/responses` as SSE, with the stored plan access token as a bearer token. It SHALL NOT call `chatgpt.com/backend-api`, or use an API key. A serialized request body larger than 1 MiB SHALL fail locally, before any request is sent.

#### Scenario: Request shape
- **WHEN** a turn is sent
- **THEN** the HTTP request is `POST /v1/responses` on `api.openai.com`, with a bearer token, `Accept: text/event-stream` and a body with `stream: true` and `store: false`

#### Scenario: No subscription credentials
- **WHEN** a turn is requested while no token set is stored and the registration, if any, is not marked plan usage disabled
- **THEN** no HTTP request is sent, and the stream ends with `failed` of kind `reauth_required`, naming `kehai login openai`

#### Scenario: Plan usage disabled
- **WHEN** a turn is requested while the registration is marked plan usage disabled
- **THEN** no HTTP request is sent, and the stream ends with `failed` of kind `not_permitted`, naming `kehai login openai --enable-plan-usage`

#### Scenario: Request too large
- **WHEN** a turn's serialized request body exceeds 1 MiB
- **THEN** no HTTP request is sent, and the stream ends with `failed` of kind `context_overflow` naming the 1 MiB limit

### Requirement: Token-sharing request rules
Every request SHALL follow OpenAI's token-sharing rules: `store: false` and `stream: true`; the whole conversation in `input`, with no `previous_response_id`; top-level `instructions`, never a system message item; function tools only in an `additional_tools` input item first in `input`, never top-level `tools`; and encrypted reasoning content requested. It SHALL omit every field those rules reject (listed in the scenario below).

#### Scenario: Token-sharing body
- **WHEN** a turn with instructions, three earlier conversation items and one tool is sent
- **THEN** the body carries top-level `instructions`, an `input` whose first item is `additional_tools` holding one `function` tool followed by the three items, and `include` with `reasoning.encrypted_content`, and has no top-level `tools`, no `previous_response_id`, no system item, and none of `background`, `conversation`, `max_output_tokens`, `max_tool_calls`, `metadata`, `moderation`, `multi_agent`, `prompt`, `prompt_cache_retention`, `safety_identifier`, `temperature`, `top_logprobs`, `top_p`, `truncation` or `user`

### Requirement: Model listing
The provider SHALL list models from `GET https://api.openai.com/v1/models` with the plan access token. For each model it returns the slug as id, the display name, and the context window from `context_window` when that is an integer greater than 1, otherwise no window. It omits models whose `visibility` is not `list`, and models marked `supported_in_api: false`. It SHALL read at most 4 MiB of the response before decoding; a larger response fails with kind `protocol`.

#### Scenario: Models listed
- **WHEN** the endpoint returns three models, one of them with visibility `hide`
- **THEN** the list contains the two listed models' ids and display names

#### Scenario: Context window reported
- **WHEN** a listed model has `context_window` 272000 and another has none, or `0`, or a string
- **THEN** the first model's window is 272000 and the second has no window, and neither is dropped from the list

#### Scenario: Models endpoint fails
- **WHEN** the models endpoint returns `503`
- **THEN** listing fails with kind `server`, status 503, and no cached or invented list is returned

#### Scenario: Oversized models response
- **WHEN** the models endpoint streams a body larger than 4 MiB
- **THEN** reading stops at the limit, the connection is closed, and listing fails with kind `protocol` naming the 4 MiB limit

### Requirement: Output positions
Every text delta, reasoning summary delta, opaque item and tool call SHALL carry the backend's output index of the output item it belongs to, so a caller can restore the response's item order. Tool calls are still held until successful completion. An event without an output index carries none and sorts after all indexed items of the response, in arrival order.

#### Scenario: Call before text
- **WHEN** a response holds a function call at output index 0 and a message at index 1 whose text streams before completion
- **THEN** the text deltas carry index 1, the tool call emitted on completion carries index 0, and ordering by index puts the call first

#### Scenario: Missing index
- **WHEN** a text delta event has no `output_index`
- **THEN** the delta carries no index, and ordering places it after the indexed items

### Requirement: Response output limit
The adapter SHALL count, per response, the bytes of text deltas, reasoning summary deltas, opaque items and held tool-call arguments as each arrives. When the total exceeds 4 MiB it aborts the request and ends the stream with `failed` of kind `protocol` and code `response_output_limit`. Held calls are discarded and never emitted. Usage is not emitted.

#### Scenario: Held arguments exceed the limit
- **WHEN** a response holds four complete calls of 1 MiB of arguments each and then a fifth arrives
- **THEN** the stream ends with `failed` of kind `protocol` and code `response_output_limit`, and no tool call is emitted

#### Scenario: Output within the limit
- **WHEN** a response streams 3 MiB of text and one call with 512 KiB of arguments, then completes
- **THEN** every delta and the call are emitted, and the stream ends `completed`
