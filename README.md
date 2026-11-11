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

## Session-local scratch

The model can call `scratch_set` with `{"key":"goal","value":"Keep RPC v1 unchanged"}`
and `scratch_del` with `{"key":"goal"}`. Set overwrites the current value
verbatim; delete of an already absent key succeeds and explicitly reports a no-op.
Keys are single journal path segments: **1–128 ASCII characters** from
`A-Z a-z 0-9 _ . : -` (no slash, backslash, whitespace or Unicode key characters).
An empty value is valid. Unknown argument fields are refused.

Scratch holds at most **20 keys**, **80 estimated tokens per value** and
**400 estimated tokens for the complete rendered scratch section**. These are
conservative `ceil(UTF-8 bytes / 3)` counts, not provider-tokenizer measurements.
The section count includes `scratch:`, lexically sorted key lines, separators,
newlines and presentation indentation, so legal keys/values can still exceed the
section cap. A refused write identifies the limit and current/proposed sizes,
leaving every existing entry unchanged. Values are never trimmed or summarized.

Stored entries are `scratch/<key> = {"value": "plain text"}`. Presentation puts
each key on a two-space-indented line and prefixes every value line with four
spaces. CRLF is one boundary; LF, lone CR, VT, FF, NEL, LS and PS are also
boundaries. Every original delimiter survives, including a trailing empty line's
prefix. Literal tags and labels remain scratch data, never permissions or
instructions. Unsupported nonempty stored representations are errors, not silently
converted values.

Both tools use the normal validation → hooks → permission gate → execution →
central stored-result path. They are **not automatically approved**. In headless
mode, calls without an applicable allow rule are denied. To explicitly allow
these session mutations, the user can add supported rules to `config.json`:

```json
{
  "allow": [
    { "tool": "scratch_set" },
    { "tool": "scratch_del" }
  ]
}
```

A configured hook can select them with the ordinary schema, for example
`{"name":"scratch-policy","argv":["policy-check"],"tools":["scratch_set","scratch_del"],"policy":"deny"}`
as an entry in `hooks`. This requires an installed user-chosen `policy-check`
program; the example does not install or execute one. Allow rules do not bypass
hooks. These are user startup settings, not repository-granted permissions.

The single writer checks call ownership, cancellation and live capacity together
at the **queue-head mutation decision**, without an intervening await. Cancellation
or rewind before that decision prevents a late mutation. Once the decision passes,
a successfully persisted mutation is not rolled back even if cancellation arrives
during flush and the tool result ends cancelled. Reopen never reexecutes uncertain
scratch calls. Concurrent writes follow commit order; the last committed write to
the same key wins. Ordinary serialized rewind restores the prior value or absence.

Scratch is **session-only**, journal-derived and turn-anchored: replay, fork and
rewind use normal tree semantics; native compaction does not modify it. A permitted
child writes only its own independent journal, subject to its role's tool subset;
children still cannot call `agent`. There is no `scratch_pin`, cross-session pinning,
export store, backup file or scratch-specific recovery authority.

## Full request sensorium

Every request ends with one generated, request-only `<sensorium>` user message.
It is composed from one frozen acknowledged tree and one clock reading, after
canonical conversation projection; it is not journal history. Literal tags in
prompts, tool output, scratch and opaque provider items are never searched out or
rewritten. The eleven sections always appear in this order: `turn`, `budget`,
`vcs`, `changes_since_last_turn`, `diagnostics`, `tests`, `processes`, `plan`,
`scratch`, `checkpoints`, `notices`.

`turn` reports full mode, local time and the workspace name. `budget` reports
context use/window and percentage when known, model, unavailable session cost
(`cost ?`), and independently known compaction threshold/turns since compaction.
`?` is unknown, and `~` marks estimates, including a route-qualified configured
window. These display estimates do not grant permission or establish provider
capacity. Long workspace/model display names are shortened at UTF-8 boundaries
with a counted `…`; canonical identities remain unchanged.

Currently the builder supplies live pending/running jobs, scratch, and the finite
notice codes `compaction_recovery` and `legacy_window_ignored` when applicable.
Jobs show bounded id/kind/command/state/age previews and total omissions. Logs are
**unavailable until published at exit**; composing never opens a job's spool.
Supported empty jobs, scratch and notices say `none`. VCS, changes, diagnostics,
tests, plan and checkpoints say `unavailable (not collected)` in the current
builder: there are no new collectors or plugin registrations. The finite composer
also supports explicitly supplied available or stale observations, with bounded
`failed`, `timeout` or `not collected` reasons and stale age.

The startup-only user setting is:

```json
{ "sensorium": { "maxTokens": 1500 } }
```

Absent settings or `{ "sensorium": {} }` use **1500**. `maxTokens` must be an
integer **at least 1310**; null, fractional/string values, scalar sections and
unknown nested keys are errors naming the exact JSON path. The safe minimum is
shared with composition: immutable turn/budget/scratch/notices allocations total
550, all folded source allocations total 740, plus 20 framing tokens. It is not
a repository setting, hot-reloaded policy or captured provider policy.

| Section | Conservative token cap |
| --- | ---: |
| turn / budget | 30 / 40 |
| vcs / changes_since_last_turn | 250 / 200 |
| diagnostics / tests / processes | 300 / 150 / 150 |
| plan / scratch / checkpoints / notices | 60 / 400 / 60 / 80 |

Caps count labels, indentation and omission markers using `ceil(UTF-8 bytes / 3)`.
Source previews admit at most 12 VCS paths, 10 diagnostics (120 characters per
message), 8 failing test names and 5 latest checkpoints. Individual fields are
bounded before assembly; process counting retains only bounded preview storage.
Explicit `… +N more` markers account for omitted entries. If necessary the global
fold order is process counts → VCS counts → three diagnostics plus omissions →
test counts → changed paths without line counts → latest checkpoint plus
omissions. The complete 40-token budget allocation is reserved before selecting
folds, so changing the use estimate cannot change previews. Scratch and notices
are never folded or summarized. Malformed nonempty stored scratch causes a safe,
value-free local composition error instead of hiding or exposing raw data.

Full mode intentionally costs more context than a small status line. Request
accounting replaces the previous block contribution once and solves the new
block's self-reference with a bounded fixed-point calculation; nonconvergence or
an immutable ceiling failure is refused rather than silently undercounted.
Instructions are stable between requests but versioned for this framing change;
this upgrade deliberately changes strict instruction lineage. Full-mode layout
and prompt-cache effects are not claimed to be neutral.

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

Configuration resolution, inline loop policy selection, journal projection,
native admission/evidence, child capture and RPC/client status are available.
Capacity provenance and the legacy migration notice are recorded with each
step's context and exposed in reconstructed status.

### Captured child policy

An agent launch passes only the parent's validated provider/route/model settings,
not the whole configuration or credentials. The child resolves the **launched
model's** policy from that snapshot: a parent on model A at 100,000 can launch
model B at its captured 80,000 even if `config.json` changes before startup.
It does not inherit A's fixed threshold or replace the snapshot with a later
provider-policy reread. Existing non-policy startup configuration validation and
effort inheritance remain unchanged, including inherited provider default.
Children still cannot launch nested agents; observations and calibration
admissions belong only to the child's journal.

The internal `rpc --child` launch requires `--compaction-policy`, a base64-encoded
provider-only JSON object. Both launch and child startup validate its strict
schema and the **8 KiB decoded UTF-8 JSON** maximum. Unknown keys, malformed
encodings, missing snapshots and invalid settings fail visibly as configuration
errors. Before spawning, the parent also bounds the complete native command line
(executable, VM/script arguments, all options, quoting and terminator), using the
Windows 32,767 UTF-16-unit ceiling conservatively on every platform. Oversized
snapshots or argv are refused, never truncated or silently omitted.

### Reconstructed status and explicit recovery

RPC v1 snapshots include a separate scalar `compaction` projection. Additive
`compaction_status` events refresh it after terminal exchanges, with journal
`offset` and `turn`; resync/rewind reconstruct it with the authoritative snapshot.
These projections do not alter the session tree or create a new history cache.
Reconnect uses surviving evidence and current validated model, tool/instruction
identity and captured configuration, not the last step's cached display values.

The line client displays provider/route/model, policy and exact field sources,
capability state/reason, selected boundary identity, continuity compatibility,
capacity provenance, raw backend metadata separately from any legacy hint and
migration notice, and budget quality. Estimated used/retained counts are marked
`~`; unknown compacted usage is `?`, even with a configured window. Status also
shows whether the boundary's one calibration allowance is available or consumed.
No percentage or opaque token estimate is invented. Status contains no encrypted
item JSON, ciphertext or raw server error text. The existing authoritative RPC
`tree` still contains opaque items, just as it contains encrypted reasoning;
this is not a redaction or a change to journal privacy.

An unsupported native attempt stops without retrying with the field removed.
The owner must explicitly select `off` or another policy, rewind before the
incompatible/failed history, or start a new session. `off` disables **new** native
compaction, not existing compatible opaque continuity or ordinary overflow
guards. Status retains the lineage-qualified previous native stop after recovery;
the next model request reconstructs the same bounded notice from committed
history and explicitly warns not to assume native compaction succeeded.
Returning to the old failed policy reuses its surviving unsupported evidence.

### Native provider transport

The provider API accepts an optional typed native policy and sends inline
`context_management: [{"type":"compaction","compact_threshold":100000}]`
when enabled. It retains `store:false`, `stream:true`, top-level instructions,
`additional_tools` first in uncompacted input, or immediately after the selected
compaction boundary before its retained suffix. Encrypted reasoning inclusion and
no `previous_response_id` are unchanged. Opaque items remain complete JSON.

Compaction on the ChatGPT-account route is **observed, not guaranteed**. An
owner-approved check on 2026-11-02 observed successful compaction and continuity
on `gpt-6.1-sol`; the public token-sharing documentation does not promise route
support. That response had no Content-Type and empty terminal output, so the
adapter collects indexed `response.output_item.done` events instead. It keeps
all compaction items, rejects malformed or conflicting identities/positions
with sanitized errors, and deduplicates identical copies. Output positions and
index ownership must resolve consistently across live deltas and completed items
before a compaction response can complete; ambiguous output fails without
activating a boundary. Done-message text is used only when that message has no
streamed text deltas.

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

Without a selected boundary, requests retain ordinary full-history replay;
instruction, tool or model changes do not apply the compacted-suffix lineage guard.

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
boundary invalidates it again. Recorded request lineage and boundary determine
usage compatibility; file-metadata changes that leave rendered instructions
unchanged do not discard that usage. The sensorium remains exactly two request-only
lines. Estimated used counts show `~`; route-qualified estimated windows and
percentages are also approximate, for example `~41k/~160k ctx (~26%)`.
Unknown used context or window suppresses the percentage. Raw backend windows
and legacy hints are recorded separately, never promoted to ChatGPT-account
capacity.

**Upgrade-only writing:** compacted sessions use additive output variants in the
existing journal format. Older binaries that ignore these variants are not safe
writers for such sessions. This reader fails visibly on an unknown committed
output kind rather than silently dropping continuity.

### Native capability evidence and admission safety

Capability is **unverified**, **observed-supported**, or **unsupported**, derived
from surviving journal steps for the current request lineage and effective policy.
A completed compaction item proves observed behavior, not guaranteed route
support. At or above the configured threshold, a completed ordinary response
without a compaction item records `no compaction item at threshold` (reported
input) or `estimated input at threshold without compaction` (missing usage with
a conservative estimate). Below-threshold absence, interrupted streams and
unrelated failures are inconclusive. Rejection identifying `context_management`
records unsupported immediately; a bounded message-only HTTP 400 rejection is
reduced to the fixed field signal before raw text is discarded. No request is
retried without that field.

Unsupported policy stops before another native request, across reopen and a
return to that policy. Explicitly choosing a different policy starts unverified;
rewind removes only later evidence. Recovery requires the owner to choose `off`,
a different policy, rewind, or a new session; there is no automatic fallback.
After explicit continuation, the next model request includes a deterministic
notice of the recorded stop reason, without raw server text or ciphertext.

Ordinary native submissions are limited to **ceil(1.25 × threshold)**, as well as
any qualified route window and the existing **1 MiB serialized-request cap**.
This ceiling is local safety policy, not a claim about the route's true capacity.
The default threshold remains **100000**, with minimum **1000**.

A newly committed boundary with unknown opaque size permits **one calibration
attempt**. Estimated retained non-opaque input (instructions, tools, suffix,
result notes and fresh sensorium) must fit both half the threshold and any
qualified window, plus the request-byte cap. The discarded prefix is not an
admission baseline: a 120k-input/6k-output compaction can calibrate with a small
retained request. Large suffix outputs or notes stop locally without trimming.

The boundary's allowance is recorded durably **before sending** and survives
failure, interruption, reopen and policy changes. Calibration is not retried,
even for a nominally unstarted failure. Missing usage without a new boundary
records `calibration usage unavailable`, preserves the observed capability and
stops repeated same-boundary requests; it does not prove threshold crossing.
Compatible completed usage restores ordinary accounting; a new committed
boundary gets its own allowance. Opaque tokens remain unknown during calibration:
there is residual overflow risk, and an overflow stops without resend.
