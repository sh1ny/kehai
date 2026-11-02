# Review

## Metadata

- **Round:** 3
- **Tier:** FULL
- **Reviewer:** Codex
- **Scope:** Owner-approved behaviour-change amendment for `context-compaction-and-window-accuracy`, focusing on token-sharing tool ordering and D1/D3.
- **Reviewed:** `AGENTS.md`; proposal, design, existing review, tasks and all four delta specs; `chatgpt_request.dart`; journal-derived request reconstruction, lineage checks, boundary selection and relevant provider/loop tests. Consulted installed Specwright review and Dart unit-testing skills.
- **Verification:** Read-only source and artifact inspection. No files changed, tests executed, external research or paid probes performed. This is design review, not implementation acceptance.

## Findings

### Critical (blocking)

None.

### Moderate

None.

### Suggestions

- Add the amendment’s serializer, settled-call reopen and backend-reset regressions to the task/test map before implementation. The existing green rows describe earlier behaviour and do not establish coverage of this amendment. Include empty tools, an empty retained suffix, and compatible continuity with native policy switched off.

## Verdict

VERDICT: APPROVE

The revised model-provider requirement, its replay scenario, D1, D3 and the persistent-boundary-to-wire diagram consistently specify:

- Non-empty tools produce exactly one `additional_tools` item.
- Compacted input places it immediately after the selected boundary and before the retained suffix.
- Uncompacted input places it first.
- No top-level `tools` is introduced; opaque JSON values, tool definitions, call/result pairing, `tool_choice: auto` and instructions remain unchanged.

The change is feasible within the existing separation between conversation reconstruction and wire serialization. The request builder already selects the latest surviving completed boundary, checks compatibility without falling back to an older boundary, and projects that boundary before its suffix. Tool registration can therefore move at serialization without changing journal authority, lineage identities or stored opaque values.

Insertion at that boundary does not split retained function-call/result pairs. Existing pre-cut result notes, post-cut paired outputs and fresh sensorium remain in their established relative order. Selection must remain driven by surviving continuity, including when policy is explicitly off; disabling new compaction does not remove an existing boundary.

The current serializer still prepends tool registration. That identifies the intended implementation change; it is not a design-review blocker. Existing projection tests exercise boundary selection and pairing, while the provider fixtures offer an offline transport seam for the proposed regression.

The reported tool loss supports the amendment as an owner-approved response to observed failure. The explanation that a boundary resets preceding tool registration remains a hypothesis. A deterministic backend-reset fixture can prove that the revised request re-establishes tools under that model and that the previous ordering fails; it cannot prove live upstream semantics. The design appropriately distinguishes observation from guarantee.

Offline test-first verification is sufficient for this amendment’s implementation work. This approval does not qualify task 7.3, establish delivery acceptance, or substitute for its required receipts and owner acceptance.

## Required Changes

None.

CHANGES_APPLIED: n/a

## Rebuttals

- **Earlier tool-first contract:** The owner explicitly approved changing it for compacted requests. D1/D3 and the normative model-provider delta agree; uncompacted ordering is preserved.
- **Opaque continuity risk:** The amendment changes registration placement without interpreting or rewriting opaque values or relaxing compatibility checks.
- **Need for another paid probe:** None for design approval or the prescribed offline regressions. Live effectiveness remains unverified and must not be inferred from a synthetic backend-reset test.
- **Prior approval:** Round 2 approval does not establish amendment coverage or implementation acceptance. This verdict independently approves the revised design.