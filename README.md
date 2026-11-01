# Kehai

Kehai is a headless coding-agent engine with a line client and a newline-delimited
JSON RPC interface.

## Reasoning-effort inputs

Both the line client and RPC command accept an optional `--effort` value:

```sh
kehai --effort high
kehai --effort=high
kehai rpc --effort high
kehai rpc --effort=high
```

The exact, case-sensitive values are `none`, `minimal`, `low`, `medium`, `high`
and `xhigh`. The line client forwards the selection to its RPC engine.

The user configuration file is `config.json` inside `KEHAI_HOME`, or inside
`~/.kehai` by default (`USERPROFILE/.kehai` on Windows). It accepts an optional
top-level `effort` string using the same vocabulary:

```json
{
  "model": "your-model-id",
  "effort": "medium"
}
```

A missing file or omitted `effort` key leaves the configured selection unset
(`null`, meaning provider default). The string `none` is an explicit selection;
it is not an alias for omission. These values describe selectable inputs, not a
promise that every model supports every level.

An invalid or missing CLI value prints a usage diagnostic to standard error and
exits **64**, before starting the engine or making session/provider changes.
Configuration is validated strictly at engine startup, even when a valid
`--effort` flag is supplied. Explicit JSON `null`, non-string values, empty
strings, unknown names and non-lowercase spellings are errors. Startup refuses
invalid configuration with exit **1**, naming `effort` and the configuration
path, before creating a session or contacting the provider. RPC reports startup
failures as a JSON `fatal` event; the line client prints the failure to standard
error.
