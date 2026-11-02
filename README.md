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

## Compaction policy and route capacity configuration

`config.json` accepts strict provider/route/model settings. Each compaction field
resolves independently: model within route > route > provider > built-in. The
built-in `openai` / `chatgpt-account` policy is `provider_native` with threshold
100000; other routes default to `off`. A threshold must be an integer at least
1000, even when strategy is `off`. Omitted fields inherit; explicit `null`, wrong
types and unknown nested keys fail configuration with the full setting path.

```json
{
  "providers": {
    "openai": {
      "compaction": { "threshold": 100000 },
      "routes": {
        "chatgpt-account": {
          "compaction": { "strategy": "provider_native" },
          "models": {
            "gpt-6.1-sol": {
              "compaction": { "threshold": 80000 },
              "contextWindow": 160000
            }
          }
        }
      }
    }
  }
}
```

Here the model's effective threshold is 80000, with the model setting as its
source; strategy inherits from the route. The configuration resolver retains
separate provenance for both fields. `contextWindow` is a positive integer and
is labelled a **user-configured estimate**, not a verified provider limit. Raw
backend metadata remains separate. On the ChatGPT-account route, generic model
metadata (including a 500000 window) cannot establish effective capacity.

To explicitly disable new compaction for the route:

```json
{
  "providers": {
    "openai": {
      "routes": {
        "chatgpt-account": { "compaction": { "strategy": "off" } }
      }
    }
  }
}
```

`off` selects no new compaction; it does not invalidate compatible opaque
continuity already recorded. The exact strategy vocabulary is `provider_native`,
`local_summary`, `off`. `local_summary` is reserved and **fails configuration as
not implemented**, rather than silently falling back. Every configured scope is
validated, even if a more specific field overrides it.

Legacy syntax remains parseable:

```json
{ "models": { "gpt-6.1-sol": { "contextWindow": 500000 } } }
```

For ChatGPT-account this is only an **unqualified hint**, not an effective limit.
The capacity resolver returns a migration notice naming the old setting and
`providers.openai.routes.chatgpt-account.models.gpt-6.1-sol.contextWindow`.
Move the setting to that route-qualified path only with an intentionally chosen
estimate. Without a qualified value, effective capacity is unknown. Other routes
retain legacy override/backend-metadata fallback behavior.

Configuration resolution, inline loop policy selection and journal projection are
available. Capability detection, calibration admission, status/migration-notice
presentation and captured child-policy launch wiring follow in later groups.

### Native provider transport

The provider API accepts an optional typed native policy and sends inline
`context_management: [{"type":"compaction","compact_threshold":100000}]`
when enabled. It retains `store:false`, `stream:true`, top-level instructions,
`additional_tools` first in input, encrypted reasoning inclusion, and no
`previous_response_id`. Opaque compaction items are forwarded as complete JSON.

Compaction on the ChatGPT-account route is **observed, not guaranteed**. An
owner-approved check on 2026-11-02 observed successful compaction and continuity
on `gpt-6.1-sol`; the public token-sharing documentation does not promise route
support. That response had no Content-Type and empty terminal output, so the
adapter collects indexed `response.output_item.done` events instead. It keeps
all compaction items, rejects malformed or conflicting identities/positions
with sanitized errors, and deduplicates identical copies. Done-message text is
used only when that message has no streamed text deltas.

Encrypted items and repeated copies count toward the existing 4 MiB aggregate
output cap; the 8 MiB SSE-event and 1 MiB serialized-request caps are unchanged.
Interrupted or failed responses release no held tool calls. Provider items are
only boundary candidates until the step's ordered output commits successfully.

### Journal continuity and call recovery

Each new step records provider/route/model, captured instruction/tool digests and
resolved policy/provenance at admission. Requests choose the **latest surviving
completed boundary first**, then validate it and every opaque suffix item against
the current lineage. A mismatch stops visibly: rewind before the incompatible
boundary or start a new session. There is no older-compatible-boundary fallback
or automatic resurrection of the full prefix. Policy threshold/off changes alone
do not invalidate compatible continuity.

Only the provider projection is cut; canonical history, scratch, full results,
stable handles and request/child correlation are unchanged. Discarded historical
results are not composed while rebuilding the bounded suffix. Calls in the
boundary-producing response all settle before another request. Post-cut calls
keep paired outputs; pre-cut calls produce deterministic user recovery notes
with their call id/name and **verbatim central result envelope**, including handles.

Attach and rewind also reconcile committed call positions that have no runtime
node. They record terminal cancellations with reason
`interrupted_before_admission`, the original input and source-step/model identity,
and a stored central envelope containing `execution not recorded; not replayed`.
Recovery never executes effects, retains existing results, skips registered live
calls, and stops on conflicting metadata. Repeated/interrupted attach is
idempotent. Rewind reconstructs missing outcomes only if their source step survives.
No request is built while any committed call lacks a terminal outcome.

Compaction invalidates pre-boundary token usage. Until a completed request using
the same lineage and selected boundary reports usage, total used context is `?`
with no percentage, even with a configured window. Ciphertext is not a token
estimate. Compatible completed usage restores the normal baseline; a newer
boundary invalidates it again. The sensorium remains two request-only lines;
remaining estimate labels, capability evidence and calibration guards are not
part of this integration yet.

**Upgrade-only writing:** compacted sessions use additive output variants in the
existing journal format. Older binaries that ignore these variants are not safe
writers for such sessions. This reader fails visibly on an unknown committed
output kind rather than silently dropping continuity.
