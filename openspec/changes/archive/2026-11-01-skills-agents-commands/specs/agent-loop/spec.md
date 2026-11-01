# Spec Delta

## MODIFIED Requirements

### Requirement: Requests rebuilt from the tree
Each model request SHALL be built from the current tree: the instructions (the fixed built-in text, then the workspace context captured for the exchange, and in a child engine its role's instructions between the two), the conversation items in order, and each call's output as the central composer renders its stored result. Opaque reasoning items are sent back unchanged. A call without a terminal state is never sent.

#### Scenario: Tool output is the composed envelope
- **WHEN** a `bash` call produced 50,000 lines and the next step is built
- **THEN** that call's output in the request is exactly the composer's envelope for its stored result, with the truncation line and handle, and no other text

#### Scenario: Resumed session
- **WHEN** a session whose last exchange was interrupted is reopened and the user submits a new prompt
- **THEN** the request holds every earlier item and the composed output of every finalized call, including those finalized as `cancelled`

#### Scenario: Instructions from the exchange's context
- **WHEN** a step of exchange 2 is built after `AGENTS.md` changed on disk during that exchange
- **THEN** its instructions hold the `AGENTS.md` text captured when exchange 2 started, not the current file

#### Scenario: Session from before this change
- **WHEN** a session whose exchanges record no context key is resumed and its next request is built
- **THEN** a context is captured for the new exchange, and the earlier items are sent unchanged
