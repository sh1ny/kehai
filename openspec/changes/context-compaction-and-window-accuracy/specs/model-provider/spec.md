# Spec Delta

## MODIFIED Requirements

### Requirement: Normalized turn stream
A provider SHALL turn one model request into an ordered event stream that ends with exactly one terminal event, `completed` or `failed`. Only `completed` is success. The request holds the model id, instructions, conversation items, tool definitions optional reasoning effort and optional native compaction policy. Non-terminal events are text deltas, reasoning-summary deltas, complete tool calls, opaque reasoning items, opaque compaction items and usage.

#### Scenario: Text answer
- **WHEN** the backend streams two text deltas and then completes
- **THEN** the stream yields both text deltas in order, one usage event, then `completed` with stop reason `end_turn`, and then closes

#### Scenario: Stream ends early
- **WHEN** the connection closes before the backend sends a completion event
- **THEN** the stream ends with `failed` of kind `protocol`, saying the stream ended before completion, and no `completed` event is emitted

### Requirement: Token-sharing request rules
Every request SHALL follow OpenAI's token-sharing rules: `store: false` and `stream: true`; the complete current conversation projection in `input` (latest eligible compaction item and its suffix when compacted), with no `previous_response_id`; top-level `instructions`, never a system message item; function tools only in a single `additional_tools` input item when tools are non-empty, never top-level `tools`; and encrypted reasoning content requested. On requests containing a selected compaction item, `additional_tools` SHALL appear immediately after that item and before the retained suffix; on uncompacted requests it SHALL be first in `input`. Opaque item contents, call/result pairing, `tool_choice: auto` and instructions SHALL remain unchanged. It SHALL omit every field those rules reject (listed in the scenario below).

#### Scenario: Token-sharing body
- **WHEN** an uncompacted turn with instructions, three earlier conversation items and one tool is sent
- **THEN** the body carries top-level `instructions`, an `input` whose first item is `additional_tools` holding one `function` tool followed by the three items, and `include` with `reasoning.encrypted_content`, and has no top-level `tools`, no `previous_response_id`, no system item, and none of `background`, `conversation`, `max_output_tokens`, `max_tool_calls`, `metadata`, `moderation`, `multi_agent`, `prompt`, `prompt_cache_retention`, `safety_identifier`, `temperature`, `top_logprobs`, `top_p`, `truncation` or `user`

#### Scenario: Compacted token-sharing body
- **WHEN** native compaction is enabled with threshold 100000
- **THEN** the body also carries `context_management: [{"type":"compaction","compact_threshold":100000}]`, while retaining all other token-sharing rules and no `previous_response_id`

#### Scenario: Tools re-established after a replayed boundary
- **WHEN** a request with non-empty tools replays the selected opaque compaction item and a retained suffix, including a settled function call and its result
- **THEN** `input` contains the unchanged compaction item, immediately followed by exactly one `additional_tools` item with the current tool definitions, then the unchanged retained suffix with its call/result pairing; top-level instructions and `tool_choice: auto` are unchanged and no top-level `tools` key is sent
- **AND** reconstructing the same request after journal reopen preserves this ordering, so a backend that resets tool registration at the compaction item receives the tools again before the suffix

### Requirement: Model listing
The provider SHALL list models from `GET https://api.openai.com/v1/models` with the plan access token. For each model it returns the slug as id, the display name, and the context window from `context_window` when that is an integer greater than 1, otherwise no window. This value SHALL be labelled backend-reported metadata, not a verified route limit. The ChatGPT-account route SHALL expose its effective window as unknown unless route-qualified configuration supplies it. It omits models whose `visibility` is not `list`, and models marked `supported_in_api: false`. It SHALL read at most 4 MiB of the response before decoding; a larger response fails with kind `protocol`.

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

#### Scenario: Generic metadata is not route capacity
- **WHEN** the models endpoint reports 500000 for `gpt-6.1-sol` on the ChatGPT-account route and no route-qualified override exists
- **THEN** raw metadata remains backend-reported, effective capacity is unknown, and no 500k effective-window claim is presented

## ADDED Requirements

### Requirement: Opaque compaction stream continuity
The adapter SHALL collect compaction items from `response.output_item.done` with their output positions, preserving complete JSON values without interpreting encrypted content. It SHALL parse SSE without requiring Content-Type or terminal output arrays. Compaction items SHALL count toward existing output limits and be usable only after successful completion. Identical repeated items SHALL be deduplicated; conflicting copies SHALL fail with a sanitized protocol error.

#### Scenario: Headerless completion with empty output
- **WHEN** a successful SSE response has no Content-Type header, emits compaction/message/compaction through output-item-done events, and has an empty `response.completed.output`
- **THEN** both opaque compaction items are collected in their output positions without requiring a terminal output array

#### Scenario: Compaction before interrupted stream
- **WHEN** an output-item-done event contains a compaction item but the response ends incomplete or disconnects
- **THEN** no new active compaction boundary is published and no held tool call runs

#### Scenario: Duplicate or conflicting item
- **WHEN** a compaction item is repeated with the same identity and identical JSON, or with conflicting JSON
- **THEN** an identical duplicate is retained once and a conflict fails the response with a sanitized protocol failure

### Requirement: Route-qualified capacity configuration
Effective ChatGPT-account capacity SHALL come only from validated `providers.openai.routes.chatgpt-account.models.<id>.contextWindow` configuration and SHALL be labelled a user-configured estimate. Legacy model-only overrides SHALL remain parseable as unqualified hints with a visible migration notice, not effective route limits. Invalid route-qualified values SHALL refuse startup before requests.

#### Scenario: Qualified window
- **WHEN** the selected model has route-qualified contextWindow 160000
- **THEN** effective capacity is 160000 with source `user-configured estimate`, separate from generic backend metadata

#### Scenario: Legacy misleading window
- **WHEN** only legacy `models.gpt-6.1-sol.contextWindow` is 500000 on the ChatGPT-account route
- **THEN** effective capacity remains unknown, no 500k guard or percentage is used, and status tells the user the route-qualified migration path

#### Scenario: Invalid qualified capacity
- **WHEN** the route-qualified contextWindow is non-integer, non-positive or under an unknown setting
- **THEN** startup refuses with the config path and no provider request
