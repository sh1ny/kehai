# Spec Delta

## MODIFIED Requirements

### Requirement: Fixed versioned tool roster
The engine SHALL offer the model a fixed roster: `read`, `edit`, `write`, `bash`, `grep`, `find`, `ls`, `ask`, `job`, `read_more`, `search_result`, `skill`, `agent`, `scratch_set` and `scratch_del`. Each tool has a name, a description, a JSON Schema for its arguments and an integer version. The version is recorded on every call node. A call naming any other tool is not run. A child engine offers only its role's subset of this roster, never `agent`.

#### Scenario: Roster exposed as tool specs
- **WHEN** the engine lists its tools for a provider request
- **THEN** it returns exactly those 15 tools, each with a non-empty description, an object schema and a version of at least 1

#### Scenario: Unknown tool
- **WHEN** the model calls a tool named `rm_rf`
- **THEN** the call node goes from `pending` to `failed` with envelope status `error` and the result `unknown tool rm_rf`, and nothing runs

#### Scenario: Child roster
- **WHEN** a child engine for a role without `tools` lists its tools
- **THEN** it returns the 14 tools other than `agent`, and a call to `agent` in it fails with `unknown tool agent`

#### Scenario: Narrowed scratch access
- **WHEN** a child role's tool subset excludes `scratch_set`
- **THEN** that child neither advertises nor executes it, and the parent's scratch is not mutated by a call in the child's independent session
