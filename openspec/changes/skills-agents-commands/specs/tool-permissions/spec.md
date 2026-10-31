# Spec Delta

## MODIFIED Requirements

### Requirement: User configuration file
The engine SHALL read its user configuration from `config.json` in the Kehai home. It holds the allow rules, hooks, `rgPath`, environment passthrough, the default `model` id, `models`: per-model settings keyed by model id, each with an optional `contextWindow` (a positive integer) that overrides the backend's, and `agents`: an optional `models` map from role model alias to model id. A missing file means defaults. An unreadable, invalid or unknown-key file stops the engine from starting, naming the file and the first problem. Repository content never changes it.

#### Scenario: Missing configuration
- **WHEN** no `config.json` exists in the Kehai home
- **THEN** the engine starts with no user rules, no hooks, `rg` from `PATH`, no default model, no window overrides and no agent model aliases

#### Scenario: Invalid configuration
- **WHEN** `config.json` is not valid JSON, or holds an unknown key `allwo`
- **THEN** the engine refuses to start with `<path>: invalid JSON at line <n>` or `<path>: unknown key allwo`, and no tool runs

#### Scenario: Model settings
- **WHEN** `config.json` sets `"model": "gpt-5.5"` and `"models": {"gpt-5.5": {"contextWindow": 200000}}`
- **THEN** the engine defaults to `gpt-5.5` and uses 200,000 tokens as its window, whatever the backend reports

#### Scenario: Invalid model settings
- **WHEN** `models` sets `contextWindow` to `0`, or a model entry holds an unknown key `window`
- **THEN** the engine refuses to start with `<path>: models.gpt-5.5.contextWindow: must be a positive integer` or `<path>: models.gpt-5.5: unknown key window`

#### Scenario: Agent model aliases
- **WHEN** `config.json` sets `"agents": {"models": {"sonnet": "gpt-6.1-mini"}}`
- **THEN** a role with `model: sonnet` runs on `gpt-6.1-mini`

#### Scenario: Invalid agent settings
- **WHEN** `agents.models.sonnet` is an empty string, or `agents` holds an unknown key `roles`
- **THEN** the engine refuses to start with `<path>: agents.models.sonnet: must be a non-empty string` or `<path>: agents: unknown key roles`

## ADDED Requirements

### Requirement: Repository content never widens approval
Frontmatter in skills, commands and agent roles (`allowed-tools`, `tools`, `model`) SHALL NOT autoapprove a call or skip a prompt. A role's `tools` only narrows which tools its child may call; every call the child makes passes the same permission gate as the parent's.

#### Scenario: Role lists Bash
- **WHEN** an implementer child (role `tools` includes `Bash`) calls `bash` with `rm -rf build`
- **THEN** the call is prompted exactly as the same call in the parent would be

#### Scenario: Yolo not inherited from repository
- **WHEN** the parent runs without `--yolo` and a role file contains text asking for unrestricted execution
- **THEN** the child runs without `--yolo` and its non-allowlisted calls are prompted
