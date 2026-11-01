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

The engine resolves effort **once at startup**: `--effort` overrides user config,
which otherwise overrides provider default. Repository content cannot supply an
effort default. With neither input, requests omit `reasoning.effort`; selecting
`none` sends the literal wire value `none`. The same selection is used for request
estimates, tool follow-ups and existing permitted retries. Backend rejection is
visible as a provider failure, with no silent downgrade or extra retry.

Internal reviewer agents inherit the parent's resolved effort, even when a role
selects a different model or user config changes before the child starts. Each
child's requests and new steps use the inherited selection. Inherited provider
default remains default; it does not pick up a newly configured effort. The
launcher pins selected values with `--effort` and pins default with the internal
`rpc --child --effort-default` marker. That marker cannot be used outside child
mode or together with `--effort`, and it never bypasses config validation. A
child started directly without the marker follows ordinary flag/config/default
precedence. Child rosters still exclude `agent`; this inheritance contract does
not enable nested agents.

Resume uses the same current flag/config/default precedence, **not** the effort
of an earlier step. Every new step records `effort` at admission, before any
request, including locally stopped steps. A string records the selected input;
explicit `null` records that provider default was requested, not a known internal
backend reasoning level. Completion, failure, cancellation and interrupted-run
recovery retain that value. Replay and fork carry it with the step; rewind removes
it with a removed step. Historical steps missing `effort` remain unchanged: absence
is legacy/unknown evidence, not a backfilled claim of provider default.

An invalid or missing CLI value prints a usage diagnostic to standard error and
exits **64**, before starting the engine or making session/provider changes.
Configuration is validated strictly at engine startup, even when a valid
`--effort` flag is supplied. Explicit JSON `null`, non-string values, empty
strings, unknown names and non-lowercase spellings are errors. Startup refuses
invalid configuration with exit **1**, naming `effort` and the configuration
path, before creating a session or contacting the provider. RPC reports startup
failures as a JSON `fatal` event; the line client prints the failure to standard
error.
