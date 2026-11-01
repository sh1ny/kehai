# Spec Delta

## Purpose

Lets users select reasoning effort for an engine run and inspect the selected effort of every model step without changing provider-default behavior for existing configurations.

## ADDED Requirements

### Requirement: Effort selection and validation
The line client and `kehai rpc` SHALL accept `--effort <value>`. User `config.json` SHALL accept optional top-level `effort`. Values SHALL be exact lowercase `none`, `minimal`, `low`, `medium`, `high` or `xhigh`. Invalid CLI values SHALL exit 64 before engine startup. An invalid config value, including null, SHALL refuse engine startup with a diagnostic naming `effort` and the config path, even with a valid CLI override.

#### Scenario: CLI selection
- **WHEN** the user starts `kehai --effort high` or `kehai rpc --effort=high` with valid configuration
- **THEN** the engine selects `high`

#### Scenario: Invalid CLI value
- **WHEN** the user passes `--effort HIGH`, `--effort turbo`, an empty value or omits its argument
- **THEN** the command exits 64 naming the invalid or missing effort value, without creating a session or starting a provider request

#### Scenario: Invalid configuration
- **WHEN** config contains `"effort": null`, a non-string, an empty string or an unknown effort, even with `--effort high`
- **THEN** startup fails before a provider request with a diagnostic naming the config path and `effort`

### Requirement: Effort precedence and default
The engine SHALL resolve effort once at startup: CLI, then user config, then provider default. Resume SHALL use the same precedence, not inherit old step effort. Without either input, requests SHALL omit `reasoning.effort`. `none` SHALL be an explicit wire value, not an alias for omission. Repository content SHALL NOT set the effort default.

#### Scenario: Flag overrides config
- **WHEN** user config selects `medium` and the command supplies `--effort high`
- **THEN** the engine uses `high`

#### Scenario: Config alone
- **WHEN** user config selects `low` and no flag is given
- **THEN** the engine uses `low`

#### Scenario: Resume without selection
- **WHEN** a session whose last step recorded `high` is resumed with neither flag nor config effort
- **THEN** new requests omit `reasoning.effort`, and the earlier step retains `high`

#### Scenario: Explicit none
- **WHEN** the resolved effort is `none`
- **THEN** requests contain `"reasoning":{"effort":"none","summary":"auto"}` rather than omitting effort

### Requirement: Consistent effort on requests
Every model request of an engine run SHALL send the resolved effort as `reasoning.effort` when selected, including tool-follow-up steps and permitted retries. Provider-default runs SHALL omit that field throughout. A backend rejection of a selected effort SHALL use the existing visible provider-failure path without silent downgrade or new retry behavior.

#### Scenario: Tool round and safe retry
- **WHEN** effort is `high`, a step makes a tool call, and the following step has one permitted retry
- **THEN** the initial request, tool-follow-up request and retry each send `reasoning.effort` equal to `high`

#### Scenario: Backend rejects selected effort
- **WHEN** the backend rejects a selected effort as `invalid_request`
- **THEN** the step and exchange fail visibly through the existing failure path, with no downgrade or automatic resend

### Requirement: Internal agents inherit effort
An internal agent SHALL inherit its parent's resolved effort at launch, including provider default, independently of role/model selection. A later edit to user config SHALL NOT change that inherited effort. Every child request and new child step SHALL use and record that inherited value. This SHALL apply recursively without introducing per-role effort overrides.

#### Scenario: Parent override reaches reviewer
- **WHEN** a parent with config `low` and CLI effort `high` launches `specwright-reviewer`
- **THEN** child requests send `high` and child steps record `high`, even if the role selects another model

#### Scenario: Config changes before launch
- **WHEN** the parent resolved provider default and user config is subsequently edited to select `high` before an agent launch
- **THEN** the child still omits `reasoning.effort` and records `effort: null`

### Requirement: Effort recorded per step
Every new step SHALL record `effort` as the selected string or explicit null for provider default before any provider request. Completed, failed, cancelled and locally stopped steps SHALL retain it. Replay, fork and rewind SHALL preserve or remove it with its step. Historical steps without the field SHALL remain readable without backfilling or claiming a known backend effort.

#### Scenario: Step persisted and replayed
- **WHEN** an engine using `high` creates two steps and the journal is replayed
- **THEN** both steps contain `effort: high` in the reconstructed tree

#### Scenario: Failure before sending
- **WHEN** provider-default mode creates a step that is stopped locally for context overflow
- **THEN** the stopped step contains `effort: null` although no provider request was sent

#### Scenario: Interrupted step
- **WHEN** an engine dies after admitting a step using `medium` and resume finalizes it as interrupted
- **THEN** the cancelled step still contains `effort: medium` and is not resent

#### Scenario: Older session
- **WHEN** a session with historical steps lacking `effort` is resumed
- **THEN** historical steps remain unchanged and new steps include their own resolved effort or null
