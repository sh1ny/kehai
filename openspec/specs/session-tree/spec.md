# session-tree Specification

## Purpose

Defines the one authoritative session tree rebuilt from the journal. It covers deterministic replay, journal-only rewind and fork, and request correlation that survives rewind. Resume and recovery never re-execute recorded effects.

## Requirements

### Requirement: Deterministic materialization
Materializing a journal SHALL depend only on its committed records, in order. The same records SHALL always yield the identical tree, and the tree's canonical serialization (sorted map keys, no insignificant whitespace) SHALL be byte-identical. The live tree an engine holds after acknowledged appends SHALL equal the materialization of its journal.

#### Scenario: Random histories replay to identical trees
- **WHEN** a seeded generator produces at least 500 random valid histories (sets, merges, deletes, rewinds, requests, results and forks), each applied through the engine and then materialized from disk twice
- **THEN** for every history, the engine's live tree, both materializations and an independent reference model's tree are equal, and their canonical serializations are byte-identical

#### Scenario: Failing seed is reproducible
- **WHEN** a randomized replay check fails
- **THEN** the failure message names the seed and history index, and rerunning with that seed reproduces the same history

### Requirement: Session origin record
Every journal SHALL begin with one origin record: a `set` at the empty path whose value is the complete initial tree, including `meta/format`, `meta/session` (the session id) and `meta/lineage`. The origin record's turn is the session's first turn: 0 for a new session, the fork point for a fork. No later record may target the empty path except `rewind`.

#### Scenario: New session starts with an origin record
- **WHEN** a new session is created
- **THEN** its journal holds exactly one line, a `set` at path `""` with turn 0, whose value contains `meta/format` equal to the current version and `meta/lineage` equal to `{"parent":null}`

#### Scenario: Missing or repeated origin is rejected
- **WHEN** a journal's first line is not a root `set`, or a later line is a root `set`
- **THEN** materialization fails with `invalid origin` naming the line, and the session cannot be opened for write

### Requirement: Turn anchoring
Each record's `turn` SHALL equal the session's current turn or the current turn plus one, which starts a new turn. A record with any other turn is rejected. The state at the end of a turn is the tree after that turn's last record.

#### Scenario: Turns advance by one
- **WHEN** the current turn is 3 and the engine appends a record with turn 4
- **THEN** the append succeeds and the current turn becomes 4

#### Scenario: Skipped or past turn is rejected
- **WHEN** the current turn is 3 and a record with turn 5 or turn 2 is submitted
- **THEN** it fails with `invalid turn` naming the expected turns 3 or 4, and nothing is appended

### Requirement: Journal-only rewind
Rewind to turn K SHALL be one appended `rewind` record whose value is K, with K at least the origin turn and less than the current turn. Every top-level subtree except `meta` takes its value at the end of turn K. `meta` keeps its current value. The current turn becomes K. History is never edited. Rewind does not alter workspace files or external effects.

#### Scenario: Rewind removes later turn-anchored state
- **WHEN** turn 2 sets `scratch/goal`, turn 3 sets `body/t3/user`, changes `scratch/goal`, and records request `q1` in `meta/requests`, and then the session is rewound to turn 2
- **THEN** `body/t3` is absent, `scratch/goal` holds its end-of-turn-2 value, `meta/requests/q1` is still present, the current turn is 2, and the journal grew by exactly one `rewind` line with every earlier line unchanged

#### Scenario: Invalid rewind target is rejected
- **WHEN** a rewind targets the current turn, a later turn, a negative turn, or a turn before a fork's origin turn
- **THEN** it fails with `invalid rewind target` naming the allowed range, and nothing is appended

#### Scenario: Rewind survives replay
- **WHEN** a session with two successive rewinds and new turns after each is reopened
- **THEN** the materialized tree equals the engine's tree before closing

### Requirement: Journal-only fork
Fork at turn K (origin turn to current turn) SHALL create a new session from the writer's acknowledged state. Every subtree except `meta` takes its end-of-turn-K value. `meta` is the parent's current `meta` (as rewind keeps it), except `meta/session` (the new id), `meta/lineage` (parent id and K) and `meta/requests` (empty). Referenced result bytes are copied into the child first. The parent journal is unchanged.

#### Scenario: Fork is independent of the parent
- **WHEN** a session is forked at turn 2, the child appends turn 3, and the parent directory is then deleted
- **THEN** the child materializes with the parent's end-of-turn-2 state plus its own turn 3, every result handle in the child still pages its full bytes, and the parent's journal was byte-identical before deletion

#### Scenario: Fork keeps current session settings
- **WHEN** turn 4 changes `meta/settings/model` from `a` to `b` and the session is then forked at turn 2
- **THEN** the child's `meta/settings/model` is `b`, its `body` holds no node written after turn 2, its `meta/session` differs from the parent's, and its `meta/requests` is empty

#### Scenario: Fork failure leaves no child
- **WHEN** copying a referenced result fails during fork (for example the parent's result file is missing)
- **THEN** fork fails naming the missing handle, no child session directory remains, and the parent is unchanged

### Requirement: Request admission and outcome correlation
An effectful request SHALL be admitted by one serialized conditional operation that records `meta/requests/<id>` (fingerprint, state `admitted`) before any effect. It tells the caller whether it newly admitted the request. A known id with the same fingerprint returns the recorded state and outcome, appending nothing. A different fingerprint is a collision. Outcomes are recorded on the same node. These records survive rewind.

#### Scenario: Duplicate after rewind is not re-executed
- **WHEN** request `q1` was admitted and completed in turn 3, the session is rewound to turn 2, and `q1` arrives again with the same fingerprint
- **THEN** the engine returns state `completed` with the recorded outcome, runs no effect for it, and appends no record

#### Scenario: Simultaneous duplicate admissions
- **WHEN** two callers concurrently admit `q2` with the same fingerprint
- **THEN** exactly one is told it newly admitted `q2`, the other receives the existing `admitted` state without permission to execute, and the journal holds exactly one admission record for `q2`

#### Scenario: Request id collision
- **WHEN** a request arrives with an id already recorded under a different fingerprint, including concurrently with that id's first admission
- **THEN** it is rejected with `request id collision` naming the id, and nothing is appended for it

### Requirement: Resume finalizes interrupted requests
Opening a session for write SHALL find every request whose state is `admitted` before accepting any command. It records each one as `interrupted` with reason `effect-uncertain`, and reports the count. It never re-executes a recorded request, tool or provider call.

#### Scenario: Admitted request becomes interrupted
- **WHEN** a session is closed abruptly after admitting `q7` with no outcome, and is reopened for write
- **THEN** before the open returns, `meta/requests/q7` has state `interrupted` and reason `effect-uncertain`, the open result reports 1 interrupted request, and a later duplicate of `q7` returns `interrupted` without executing

#### Scenario: Recovery append fails
- **WHEN** appending the `interrupted` finalization fails because of a storage error
- **THEN** the open fails with that storage error and the session accepts no commands
