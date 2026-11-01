# ADR 0013: Reasoning effort selection and inheritance

Status: accepted
Supersedes: none

## Context

The `dogfood-first-m2-change` design (D1–D4) adds reasoning effort as a user-selected engine input. It must stay consistent across requests, durable step history and child engines without making old history current policy. This supplements [ADR 0001](0001-one-session-tree.md), [ADR 0008](0008-journal-format-v1.md), [ADR 0011](0011-conversation-tree-layout-and-rpc-protocol-v1.md) and [ADR 0012](0012-workspace-context-skills-commands-and-subagents.md); none is superseded.

## Decision

### Selection is an immutable run input

- The line client and `kehai rpc` accept `--effort <value>`; user `config.json` accepts optional top-level `effort`. Both share the exact lowercase vocabulary `none`, `minimal`, `low`, `medium`, `high`, `xhigh`. This validates syntax, not support by every backend/model.
- Invalid CLI input exits 64 before engine startup. Invalid config effort (including explicit null) refuses startup with a diagnostic naming `effort` and the config path, even when a valid flag would override it.
- Resolve once at engine startup: **flag > user config > null (backend default)**. Resume uses the same rule, with no historical step fallback, backfill or live config reload. Repository content and role frontmatter cannot set effort.
- Pass that same nullable string to the driver, request builder (including estimates) and tool runtime/context. Every request, tool-follow-up step and permitted retry uses it unchanged. A selected string is sent as `reasoning.effort`; null omits that wire field. The string `none` is explicit, not omission. Backend rejection follows the existing visible provider-failure path: no silent downgrade, inferred replacement or new retry behavior.

### Steps record selected input at admission

Every new `body/steps/s-<turn>` node records `effort: <string|null>` beside `model` in its existing single admission `set`, before request construction or streaming. Null is written explicitly: it means backend default was requested, not that the backend's actual internal effort is known. The field survives completion, failure, cancellation, local stops and interrupted-step recovery; lifecycle merges do not replace it.

Replay, rewind and fork preserve or remove effort with its step. Historical steps without the field remain readable and unchanged. New steps resolve from the current engine's inputs, never old step values. This is additive body data, with no new journal root, path layout, operation or RPC message contract: the four-field journal format and RPC protocol remain v1. There is no effort side store or session-wide historical default in `meta`.

### Child launch pins inheritance, including null

- Each parent launch supplies exactly one form: `--effort <selected value>` or the internal child-only `--effort-default` flag for inherited null. Store the explicit-default boolean in `ChildSpec` to distinguish inherited null from missing input, without adding a public effort value.
- Refuse `--effort-default` outside `--child` and refuse combining it with `--effort`. It skips config effort selection, not normal config validation. A directly started child without this marker follows ordinary flag/config/default precedence.
- Child requests and new steps use and record the inherited value even if user config changes after the parent starts or a role selects a different model. Inheritance applies recursively to descendants; no per-role effort overrides, environment variable, repository setting, settings side file or new RPC handshake is introduced. Existing child sessions remain readable.

## Consequences

- **Rejected:** a mandatory Kehai effort default or history fallback; either silently changes current user policy. Backend default remains opaque.
- **Rejected:** omitting child argv for inherited null; a later config edit could silently change child selection. Explicit argv pins both selected values and default intent.
- **Rejected:** completion-only recording or a session-wide effort field; neither preserves the selected input for failed/unsent steps across runs and rewind.
- **Cost:** one nullable scalar per run and new step, plus one scalar option or default marker per child launch. Existing storage, retry and job limits remain authoritative.
- **Reversal cost: medium.** Extending syntax is cheap, but changing precedence, stored field meaning or the internal child argv contract requires explicit compatibility handling. A future live-change command or role override needs a separate decision.
