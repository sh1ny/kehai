# Spec Delta

## ADDED Requirements

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

## MODIFIED Requirements

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
