# Review

## Metadata

- **Round:** 2, with three rechecks. The third is a lossless-repair recheck after an editorial-only fix for strict validation.
- **Prior history (condensed):**
  - Round 1 (Codex CLI) approved with changes. It resolved the queue-head cancellation cutoff and handling of `SensoriumCompositionError`. Later apply-evidence edits voided that verdict.
  - Round 2 (Claude CLI 2.1.319, actual model `claude-opus-5-5`, receipt at `design.md:238`) re-reviewed the whole design. It returned approve-with-changes, changes not applied, with one Critical, five Moderates and six Suggestions. The user authorized the resolution bundle.
  - The first recheck resolved Required Changes 1, 2, 3 and 6. It left 4 (line terminators) and 5 (relay allowlist) narrowly open.
  - The second recheck, scoped to 4 and 5, resolved both. Its result was approve-with-changes, changes applied.
- **This recheck's scope:** the user authorized a lossless mechanical repair. Four requirement bodies exceeded strict validation's 500-character limit. Their detailed SHALL clauses were moved, unchanged, into AND assertions of existing scenarios, and the summaries were shortened. No behavior change and no waiver. This recheck confirms two things:
  - every earlier normative contract is still present;
  - all six round 2 Required Changes are still addressed.
- **Reviewer:** Claude (Opus 5.5), cross-model design reviewer, read-only. No files edited, nothing implemented, and no tests, analysis, dogfood or CI run. The runner records this recheck's receipt.
- **Method and limitation:**
  - This session had only read/search file tools: no shell and no git. I could not run `git diff -- openspec/changes/sensorium-block-and-scratchpad/specs` or read the HEAD blobs directly.
  - Instead I checked the current spec deltas line by line against three references, each still matching HEAD (or this review's record of it):
    1. `design.md`, which is not modified in the working tree, so it still matches HEAD. It is the normative source each spec clause mirrors.
    2. `tasks.md`, also unmodified. Its test map names every requirement and scenario.
    3. This review's own record of the HEAD spec content: the requirement text and line citations in the earlier recheck sections.
  - I also checked the MODIFIED requirements against `openspec/specs/turn-perception/spec.md`.
- **Files read:**
  - `review.md`
  - `specs/agent-scratchpad/spec.md`
  - `specs/turn-perception/spec.md`
  - `design.md`
  - `tasks.md` (test map)
  - `openspec/specs/turn-perception/spec.md`
  - `.claude/skills/specwright-review/SKILL.md`
- **Out of scope:** the working tree also has a modified `openspec/architecture.md` and an untracked `docs/adr/0016-session-local-scratch-and-bounded-sensorium.md`. Neither is part of the spec-only repair, and neither was reviewed here. This review claims nothing about them.

## Findings

The round 2 findings (Critical 1, Moderates 1–5, Suggestions 1–6) and the first recheck's suggestions are summarized here. Earlier versions of this file have them in full.

- **Critical 1:** hard immutable-section ceilings could refuse every request.
- **Moderate 1:** no live source for job log tails.
- **Moderate 2:** `source.offset` was stored as durable identity.
- **Moderate 3:** multiline scratch could impersonate harness sections.
- **Moderate 4:** the MCP ask relay bypassed the permission gate.
- **Moderate 5:** scratch admission ignored the block ceiling.
- **Open, non-blocking suggestions:**
  - record the budget fixed-point convergence argument;
  - consider content-addressed observation storage;
  - define or drop the "legacy-config seam";
  - correct the `legacy_window_ignored` source wording, which `design.md:44` now addresses;
  - add model-facing framing guidance in task 3.4.

### This recheck: no new findings

**Contract preservation, agent-scratchpad:**

- **Bounded verbatim scratch writes.** The body (`:10`) keeps every earlier contract:
  - session-local plain-text `scratch_set`/`scratch_del`;
  - single journal-segment keys;
  - 20 keys / 80 tokens / 400 tokens with ceil(bytes/3);
  - refusal that reports current/proposed sizes without mutation;
  - no trimming or summarizing;
  - counted indentation that keeps stored text off column zero.

  The relocated clauses are present verbatim in substance:
  - section accounting covers the header, keys, separators, newlines and presentation indentation (`:19`, Capacity refusal AND);
  - keys sit on indented key lines, every value line gets a four-space prefix, and removing only the prefixes recovers every character and newline (`:28`);
  - the full boundary set (CRLF as one boundary, LF, lone CR, VT, FF, NEL, LS, PS), with each delimiter kept verbatim and a prefix after every boundary, including an empty trailing line (`:29`).

  These match D1 (`design.md:33-34`).
- **Serialized scratch mutation** and **Tree-native scratch continuity**: the bodies are under the limit. Every scenario and contract is intact (queue-head cutoff, no rollback after the cutoff, explicit no-op delete, rewind/fork/compaction continuity, visible refusal of invalid stored scratch).

**Contract preservation, turn-perception:**

- **One request-only sensorium block** and **Turn and budget sections** (MODIFIED): the full-text replacements are intact against the main spec. Kept:
  - provenance labelling;
  - `~` and `?` rules;
  - no invented cost;
  - compaction threshold and turns-since-compaction;
  - the long-identifier scenario (`:39-41`).
- **Ordered self-contained perception:**
  - The body keeps source order, the `full` default, honest availability and counted verbatim scratch.
  - Relocated assertions:
    - full fallback across compaction/resume/fork/rewind, with no baseline-losing delta (`:51`);
    - per-line indentation (`:52`);
    - tree-owned processes, and logs unavailable because references publish at exit, with no tail I/O or producer (`:57`);
    - `none` vs named-unavailable (`:62`);
    - bounded notice codes, with the recovery message keeping its separate placement (`:67`).
- **Hard perception budget and folding:**
  - The body keeps:
    - the 1500 default;
    - byte/3 accounting;
    - source caps, fold order and explicit omissions;
    - the four never-folded sections;
    - no spill and no silent cut;
    - refusal only on overflow of the complete immutable content;
    - the 1310 startup minimum (`:70`).
  - Relocated: bounded workspace/model presentation and notice codes (`:75`), and the minimum's derivation, 30+40+400+80, 40+200+300+40+40+60+60 and 20 framing, with shared allocations and the maximum-scratch fit proof (`:84`). This matches `design.md:179-181`.
- **Exact admitted observation:**
  - The body keeps the guarded pre-stream merge after admission/build, the exact block, the size and the frozen turn/time/offset. It also keeps RPC exposure without recomputation, no observation on failed composition, and recovery on reconnect and rewind (`:87`).
  - Relocated: the offset is diagnostic only within its journal, invalid after fork/migration, and never an identity or lookup key (`:92`).
- **Composition errors remain visible and recoverable** and **Expanded-block accounting preserves native continuity**: unchanged in substance.
- **Names:** every requirement and scenario name still matches the `tasks.md` test map (rows 9–40), so the mapping still holds.

**Required Changes still addressed:**

| # | Status | Where |
|---|---|---|
| 1 | Addressed | Complete-immutable-only refusal at `turn-perception:70`; visible counted truncation at `:41` and `:75`; bounded notice codes with separate recovery placement at `:66-67` |
| 2 | Addressed | No tail I/O, logs unavailable (published at exit) at `turn-perception:57`; `design.md:45`, `160` and `174` unchanged |
| 3 | Addressed | Diagnostic-only offset at `turn-perception:87` and `:92`; `design.md:46` and `60` |
| 4 | Addressed | Indentation, prefix recovery and the full boundary set at `agent-scratchpad:25-29`; D1 at `design.md:33-34`; test-map row 19 unchanged |
| 5 | Addressed | Unaffected by the spec diff: the exact relay allowlist and refusals stay in the unmodified `design.md:235` and `tasks.md` task 5.1 |
| 6 | Addressed | 1310 minimum and derivation at `turn-perception:70` and `:82-84`; `design.md:70` and `179-181` |

**Non-blocking observation:** several unconditional SHALL clauses now sit as AND assertions under narrower scenarios. Examples are the section-accounting rule under Capacity refusal (`agent-scratchpad:19`) and the logs rule under Known jobs (`turn-perception:57`). Each is worded unconditionally, and D1/D2 restate it as a general rule, so none is narrowed. When syncing the main specs, keep them as general rules, not scenario-conditional ones. This is not a prerequisite.

## Verdict

The repair is lossless as far as the method above can show. Every normative clause from the over-length bodies is still present in an existing scenario's AND assertion, worded as an unconditional SHALL. The shortened summaries drop no contract. No requirement or scenario was added, removed or renamed, and no behavior changed. All six round 2 Required Changes are still addressed.

The one limitation: I could not run a literal git diff against HEAD. I verified against the unmodified design and tasks and against this review's recorded HEAD content.

This review claims no executed tests, analysis, dogfood, CI or delivery gates. Every test-map row except the recorded carried-forward green rows stays red until apply. The open suggestions remain optional and do not gate tasks.

VERDICT: APPROVE_WITH_CHANGES

## Required Changes

1. **Resolve Critical 1.** Resolved in the first recheck. Still addressed after the repair (`turn-perception:41`, `:66-67`, `:70`, `:75`).
2. **Resolve Moderate 1.** Resolved in the first recheck. Still addressed (`turn-perception:57`).
3. **Resolve Moderate 2.** Resolved in the first recheck. Still addressed (`turn-perception:87`, `:92`).
4. **Resolve Moderate 3.** Resolved in the second recheck. Still addressed; the boundary clause moved from the requirement body to `agent-scratchpad:29`, alongside `:25-28`.
5. **Resolve Moderate 4.** Resolved in the second recheck. Not touched by the spec repair (`design.md:235`, `tasks.md:78`).
6. **Resolve Moderate 5.** Resolved in the first recheck. Still addressed (`turn-perception:70`, `:82-84`).

CHANGES_APPLIED: yes

## Rebuttals

None. The author has not rebutted anything in round 2 or any recheck. This repair is editorial only and contests no finding. Round 1's resolved Moderates (cancellation cutoff, composition-error consumers) were not re-raised, and the repair does not touch them. Moderate 1 intentionally overrode round 1's tail-deadline Suggestion, and that resolution stands.