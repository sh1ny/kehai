# Spec Delta

## MODIFIED Requirements

### Requirement: User configuration file
The engine SHALL read its user configuration from `config.json` in the Kehai home. It holds the allow rules, hooks, `rgPath`, environment passthrough, the default `model` id, and `models`: per-model settings keyed by model id, each with an optional `contextWindow` (a positive integer) that overrides the backend's. A missing file means defaults. An unreadable, invalid or unknown-key file stops the engine from starting, naming the file and the first problem. Repository content never changes it.

#### Scenario: Missing configuration
- **WHEN** no `config.json` exists in the Kehai home
- **THEN** the engine starts with no user rules, no hooks, `rg` from `PATH`, no default model and no window overrides

#### Scenario: Invalid configuration
- **WHEN** `config.json` is not valid JSON, or holds an unknown key `allwo`
- **THEN** the engine refuses to start with `<path>: invalid JSON at line <n>` or `<path>: unknown key allwo`, and no tool runs

#### Scenario: Model settings
- **WHEN** `config.json` sets `"model": "gpt-5.5"` and `"models": {"gpt-5.5": {"contextWindow": 200000}}`
- **THEN** the engine defaults to `gpt-5.5` and uses 200,000 tokens as its window, whatever the backend reports

#### Scenario: Invalid model settings
- **WHEN** `models` sets `contextWindow` to `0`, or a model entry holds an unknown key `window`
- **THEN** the engine refuses to start with `<path>: models.gpt-5.5.contextWindow: must be a positive integer` or `<path>: models.gpt-5.5: unknown key window`
