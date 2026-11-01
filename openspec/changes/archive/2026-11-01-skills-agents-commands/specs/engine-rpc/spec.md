# Spec Delta

## MODIFIED Requirements

### Requirement: Prompts reach the client
Each permission prompt and `ask` question SHALL be sent as one `prompt` event with its key, kind, tool and input. A prompt relayed from a child engine also names its `agent`: the role and the job id. Each one that closes without an answer is sent as `withdraw` with its key. A client that attaches to the session is the answerer.

#### Scenario: Permission prompt
- **WHEN** the model calls `bash` with `rm -rf build` and the command is not autoapproved
- **THEN** the client receives a `prompt` of kind `permission` for that call, and `answer` `allow` runs it

#### Scenario: Prompt withdrawn by interrupt
- **WHEN** the exchange is interrupted while a question is open
- **THEN** the client receives `withdraw` for its key, and a later `answer` for it replies `question withdrawn`

#### Scenario: Relayed child prompt
- **WHEN** a `specwright-implementer` child of job `j2` asks permission for `bash`
- **THEN** the client receives one `prompt` whose `agent` is `{"role":"specwright-implementer","job":"j2"}`, with a key unique in the parent session

## ADDED Requirements

### Requirement: Child engine mode
`kehai rpc` SHALL accept a child mode, used only by the agent job, that creates a new session under a given parent session directory with a given role and model, records the lineage, and speaks protocol version 1 over stdio. Child mode refuses `--resume` and `--session`, and a missing or unknown role is `fatal` before any session is created.

#### Scenario: Child started
- **WHEN** the agent job starts a child for role `specwright-reviewer`
- **THEN** the child's `hello` names protocol 1, the new child session id, the workspace and the child's model

#### Scenario: Unknown role in child mode
- **WHEN** child mode is started with role `nope`
- **THEN** it writes `fatal` with `unknown agent role nope`, exits 1 and creates no session
